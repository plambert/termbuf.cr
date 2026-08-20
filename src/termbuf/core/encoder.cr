require "../caps/capability"
require "./op"
require "./style"
require "./style_table"

module TermBuf
  # Turns paint operations into terminal bytes, as few of them as it can.
  #
  # The encoder carries the state the terminal has: where the cursor is and
  # what style is in force. That is what lets it drop a `MoveTo` that is
  # already true, pick the shortest of the half-dozen ways to move the cursor a
  # few columns, and emit an SGR delta instead of a reset plus everything.
  #
  # It also holds the capability mask, and is the only place a style is
  # narrowed to what the terminal can actually render. Colours are downgraded
  # here rather than at write time, so the buffer keeps full fidelity and a
  # later repaint against a wider mask comes out better.
  class Encoder
    CSI = "\e["

    getter capabilities : Capabilities

    # Where the terminal's cursor is, or `nil` when it is not known and the
    # next move has to be absolute.
    getter cursor_x : Int32?
    getter cursor_y : Int32?

    @styles : StyleTable
    @width : Int32
    @height : Int32
    @current : Style?
    @effective : Hash(StyleId, Style)
    @full_sgr : Hash(StyleId, String)
    @scratch : IO::Memory
    @alternate : IO::Memory

    def initialize(@styles : StyleTable, @capabilities : Capabilities,
                   @width : Int32, @height : Int32)
      @cursor_x = nil
      @cursor_y = nil
      @current = nil
      @effective = {} of StyleId => Style
      @full_sgr = {} of StyleId => String
      @scratch = IO::Memory.new 64
      @alternate = IO::Memory.new 64
    end

    # Forgets what the terminal was showing. The next operation re-establishes
    # the cursor and the style from scratch, which is what a forced repaint
    # needs.
    def reset_state : Nil
      @cursor_x = nil
      @cursor_y = nil
      @current = nil
    end

    def resize(width : Int32, height : Int32) : Nil
      @width = width
      @height = height
      reset_state
    end

    # Replaces the capability mask, discarding the style cache built under the
    # old one.
    def capabilities=(capabilities : Capabilities) : Capabilities
      @capabilities = capabilities
      @effective.clear
      @full_sgr.clear
      @current = nil
      capabilities
    end

    def encode(ops : Array(Op)) : String
      String.build { |io| encode ops, io }
    end

    def encode(ops : Array(Op), io : IO) : Nil
      ops.each { |op| encode_one op, io }
    end

    private def encode_one(op : Op, io : IO) : Nil
      case op
      in Ops::MoveTo            then move_to op.x, op.y, io
      in Ops::SetStyle          then set_style op.style, io
      in Ops::PutText           then put_text op.text, op.columns, io
      in Ops::EraseInLine       then erase_in_line op.mode, io
      in Ops::EraseChars        then erase_chars op.count, io
      in Ops::SetScrollRegion   then set_scroll_region op.top, op.bottom, io
      in Ops::ResetScrollRegion then reset_scroll_region io
      in Ops::ScrollUp          then scroll op.lines, 'S', io
      in Ops::ScrollDown        then scroll op.lines, 'T', io
      in Ops::InsertLines       then edit_lines op.count, 'L', io
      in Ops::DeleteLines       then edit_lines op.count, 'M', io
      in Ops::SetAutowrap       then private_mode "7", op.enabled, io
      in Ops::SetCursorVisible  then private_mode "25", op.visible, io
      in Ops::BeginSync         then sync true, io
      in Ops::EndSync           then sync false, io
      in Ops::Raw               then raw op.bytes, io
      end
    end

    # ------------------------------------------------------------ movement

    # Emits the shortest sequence that puts the cursor at (*x*, *y*).
    def move_to(x : Int32, y : Int32, io : IO) : Nil
      from_x = @cursor_x
      from_y = @cursor_y

      if from_x.nil? || from_y.nil?
        write_cup x, y, io
        return
      end

      return if from_x == x && from_y == y

      if from_y == y
        move_within_row from_x, x, io
      elsif from_x == x
        move_within_column from_y, y, x, io
      else
        move_across from_x, from_y, x, y, io
      end

      @cursor_x = x
      @cursor_y = y
    end

    private def move_within_row(from : Int32, to : Int32, io : IO) : Nil
      delta = to - from

      candidates = {
        carriage_return: to.zero? ? 1 : Int32::MAX,
        backspaces:      delta < 0 ? -delta : Int32::MAX,
        relative:        relative_cost(delta),
        absolute:        column_cost(to),
        full:            cup_cost(to, 0),
      }

      case cheapest candidates
      when :carriage_return then io << '\r'
      when :backspaces      then (from - to).times { io << '\b' }
      when :relative        then write_relative delta, io
      when :absolute        then io << CSI << (to + 1) << 'G'
      else                       write_cup_body to, @cursor_y || 0, io
      end
    end

    private def move_within_column(from : Int32, to : Int32, x : Int32, io : IO) : Nil
      delta = to - from

      if vertical_cost(delta) <= cup_cost(x, to)
        write_vertical delta, io
      else
        write_cup_body x, to, io
      end
    end

    private def move_across(from_x : Int32, from_y : Int32, x : Int32, y : Int32,
                            io : IO) : Nil
      # A carriage return plus a vertical move beats an absolute move whenever
      # the row numbers are large and the target column is the left margin.
      if x.zero? && 1 + vertical_cost(y - from_y) < cup_cost(x, y)
        io << '\r'
        write_vertical y - from_y, io
      else
        write_cup_body x, y, io
      end
    end

    private def write_cup(x : Int32, y : Int32, io : IO) : Nil
      write_cup_body x, y, io
      @cursor_x = x
      @cursor_y = y
    end

    private def write_cup_body(x : Int32, y : Int32, io : IO) : Nil
      io << CSI << (y + 1) << ';' << (x + 1) << 'H'
    end

    private def write_relative(delta : Int32, io : IO) : Nil
      io << CSI
      io << delta.abs unless delta.abs == 1
      io << (delta > 0 ? 'C' : 'D')
    end

    private def write_vertical(delta : Int32, io : IO) : Nil
      io << CSI
      io << delta.abs unless delta.abs == 1
      io << (delta > 0 ? 'B' : 'A')
    end

    # `CSI n C` and friends, where a count of one is the implicit default and
    # costs nothing to leave out.
    private def relative_cost(delta : Int32) : Int32
      return Int32::MAX if delta.zero?

      delta.abs == 1 ? 3 : 3 + digits(delta.abs)
    end

    private def vertical_cost(delta : Int32) : Int32
      relative_cost delta
    end

    private def column_cost(x : Int32) : Int32
      3 + digits(x + 1)
    end

    private def cup_cost(x : Int32, y : Int32) : Int32
      4 + digits(y + 1) + digits(x + 1)
    end

    private def digits(value : Int32) : Int32
      return 1 if value < 10
      return 2 if value < 100
      return 3 if value < 1000

      4
    end

    private def cheapest(candidates) : Symbol
      best = :full
      best_cost = Int32::MAX

      {% for key in %w[carriage_return backspaces relative absolute full] %}
        cost = candidates[:{{ key.id }}]
        if cost < best_cost
          best = :{{ key.id }}
          best_cost = cost
        end
      {% end %}

      best
    end

    # --------------------------------------------------------------- style

    def set_style(id : StyleId, io : IO) : Nil
      target = effective id
      return if @current == target

      full = full_sgr id
      previous = @current

      if previous
        @alternate.clear
        write_sgr_delta previous, target, @alternate

        if @alternate.bytesize < full.bytesize
          io.write @alternate.to_slice
          @current = target
          return
        end
      end

      io << full
      @current = target
    end

    # The style as this terminal can actually render it: unsupported
    # attributes dropped, colours narrowed to the deepest supported space.
    def effective(id : StyleId) : Style
      @effective.fetch id do
        computed = compute_effective @styles[id]
        @effective[id] = computed
        computed
      end
    end

    private def compute_effective(style : Style) : Style
      attributes = style.attributes & supported_attributes
      underline = supported_underline style.underline
      foreground = narrow style.foreground
      background = narrow style.background

      underline_color = if underline.none? || !@capabilities.includes?(Capability::UnderlineColor)
                          Color.default
                        else
                          narrow style.underline_color
                        end

      # Without the aixterm codes a bright foreground becomes its dim
      # counterpart plus bold, which is how terminals reached the bright
      # colours before those codes existed.
      unless @capabilities.includes? Capability::BrightColors
        if foreground.bright?
          foreground = Color.indexed foreground.index - 8
          attributes |= Attributes::Bold if @capabilities.includes? Capability::Bold
        end

        background = Color.indexed background.index - 8 if background.bright?
      end

      Style.new foreground, background, underline_color, attributes, underline, 0_u32
    end

    # Narrows a colour to the deepest space the terminal supports.
    private def narrow(color : Color) : Color
      return color if color.default?
      return Color.default unless @capabilities.includes? Capability::Color16

      if color.rgb?
        return color if @capabilities.includes? Capability::TrueColor

        color = color.to_indexed256
      end

      return color if @capabilities.includes? Capability::Color256

      color.to_indexed16
    end

    private def supported_attributes : Attributes
      mask = Attributes::None
      mask |= Attributes::Bold if @capabilities.includes? Capability::Bold
      mask |= Attributes::Faint if @capabilities.includes? Capability::Faint
      mask |= Attributes::Italic if @capabilities.includes? Capability::Italic
      mask |= Attributes::SlowBlink if @capabilities.includes? Capability::Blink
      mask |= Attributes::RapidBlink if @capabilities.includes? Capability::RapidBlink
      mask |= Attributes::Reverse if @capabilities.includes? Capability::Reverse
      mask |= Attributes::Conceal if @capabilities.includes? Capability::Conceal
      mask |= Attributes::Strike if @capabilities.includes? Capability::Strike
      mask |= Attributes::Overline if @capabilities.includes? Capability::Overline
      mask |= Attributes::Superscript | Attributes::Subscript if @capabilities.includes? Capability::Superscript
      mask
    end

    private def supported_underline(underline : Underline) : Underline
      return Underline::None unless @capabilities.includes? Capability::Underline
      return underline if underline.none? || underline.single?
      return underline if @capabilities.includes? Capability::ExtendedUnderline

      Underline::Single
    end

    private def full_sgr(id : StyleId) : String
      @full_sgr.fetch id do
        built = String.build do |io|
          io << CSI << '0'
          write_style_codes effective(id), io
          io << 'm'
        end

        @full_sgr[id] = built
        built
      end
    end

    private def write_style_codes(style : Style, io : IO) : Nil
      write_attribute_codes style.attributes, io
      write_underline_code style.underline, io
      write_color_code style.foreground, false, io
      write_color_code style.background, true, io
      write_underline_color style.underline_color, io
    end

    private def write_attribute_codes(attributes : Attributes, io : IO) : Nil
      io << ";1" if attributes.includes? Attributes::Bold
      io << ";2" if attributes.includes? Attributes::Faint
      io << ";3" if attributes.includes? Attributes::Italic
      io << ";5" if attributes.includes? Attributes::SlowBlink
      io << ";6" if attributes.includes? Attributes::RapidBlink
      io << ";7" if attributes.includes? Attributes::Reverse
      io << ";8" if attributes.includes? Attributes::Conceal
      io << ";9" if attributes.includes? Attributes::Strike
      io << ";53" if attributes.includes? Attributes::Overline
      io << ";73" if attributes.includes? Attributes::Superscript
      io << ";74" if attributes.includes? Attributes::Subscript
    end

    private def write_underline_code(underline : Underline, io : IO) : Nil
      case underline
      in .none?   then nil
      in .single? then io << ";4"
      in .double? then io << ";4:2"
      in .curly?  then io << ";4:3"
      in .dotted? then io << ";4:4"
      in .dashed? then io << ";4:5"
      end
    end

    private def write_color_code(color : Color, background : Bool, io : IO) : Nil
      return if color.default?

      case color.kind
      in .default? then nil
      in .rgb?
        io << (background ? ";48;2;" : ";38;2;")
        io << color.red << ';' << color.green << ';' << color.blue
      in .indexed?
        index = color.index

        if index < 8
          io << ';' << (background ? 40 + index : 30 + index)
        elsif index < 16
          io << ';' << (background ? 92 + index : 82 + index)
        else
          io << (background ? ";48;5;" : ";38;5;") << index
        end
      end
    end

    private def write_underline_color(color : Color, io : IO) : Nil
      return if color.default?

      case color.kind
      in .default? then nil
      in .rgb?     then io << ";58;2;" << color.red << ';' << color.green << ';' << color.blue
      in .indexed? then io << ";58;5;" << color.index
      end
    end

    # The codes that take the terminal from *from* to *to* without a reset.
    private def write_sgr_delta(from : Style, to : Style, io : IO) : Nil
      @scratch.clear
      write_delta_codes from, to, @scratch
      return if @scratch.bytesize.zero?

      io << CSI
      # The delta always opens with a `;`, which stands in for the leading
      # empty parameter the terminal reads as a no-op.
      io.write @scratch.to_slice[1..]
      io << 'm'
    end

    private def write_delta_codes(from : Style, to : Style, io : IO) : Nil
      write_attribute_delta from.attributes, to.attributes, io
      write_underline_code to.underline, io unless from.underline == to.underline
      io << ";24" if !from.underline.none? && to.underline.none?

      unless from.foreground == to.foreground
        to.foreground.default? ? io << ";39" : write_color_code(to.foreground, false, io)
      end

      unless from.background == to.background
        to.background.default? ? io << ";49" : write_color_code(to.background, true, io)
      end

      unless from.underline_color == to.underline_color
        to.underline_color.default? ? io << ";59" : write_underline_color(to.underline_color, io)
      end
    end

    # Attributes with a reset of their own.
    RESETS = {
      {Attributes::Italic, "23"},
      {Attributes::Reverse, "27"},
      {Attributes::Conceal, "28"},
      {Attributes::Strike, "29"},
      {Attributes::Overline, "55"},
    }

    # Attributes that share a reset with a sibling: turning one off turns the
    # whole group off, so any member that should survive has to be reasserted.
    SHARED_RESETS = {
      {Attributes::Bold | Attributes::Faint, "22"},
      {Attributes::SlowBlink | Attributes::RapidBlink, "25"},
      {Attributes::Superscript | Attributes::Subscript, "75"},
    }

    private def write_attribute_delta(from : Attributes, to : Attributes, io : IO) : Nil
      added = to & ~from
      removed = from & ~to

      SHARED_RESETS.each do |(group, code)|
        next if (removed & group).none?

        io << ';' << code
        added |= to & group
      end

      RESETS.each do |(flag, code)|
        io << ';' << code if removed.includes? flag
      end

      write_attribute_codes added, io
    end

    # ---------------------------------------------------------------- text

    private def put_text(text : String, columns : Int32, io : IO) : Nil
      io << text
      advance columns
    end

    # With wrapping turned off the cursor stops at the right margin instead of
    # moving past it, so the column saturates rather than overflowing.
    private def advance(columns : Int32) : Nil
      current = @cursor_x
      return if current.nil?

      @cursor_x = Math.min current + columns, @width - 1
    end

    # -------------------------------------------------------------- erasing

    private def erase_in_line(mode : Ops::EraseMode, io : IO) : Nil
      io << CSI

      case mode
      in .to_end?   then nil
      in .to_start? then io << '1'
      in .all?      then io << '2'
      end

      io << 'K'
    end

    private def erase_chars(count : Int32, io : IO) : Nil
      return if count <= 0

      io << CSI
      io << count unless count == 1
      io << 'X'
    end

    # ------------------------------------------------------------ scrolling

    private def set_scroll_region(top : Int32, bottom : Int32, io : IO) : Nil
      io << CSI << (top + 1) << ';' << (bottom + 1) << 'r'
      home
    end

    private def reset_scroll_region(io : IO) : Nil
      io << CSI << 'r'
      home
    end

    # Setting or releasing the margins homes the cursor. Forgetting that is a
    # reliable way to paint the next run in the wrong place.
    private def home : Nil
      @cursor_x = 0
      @cursor_y = 0
    end

    private def scroll(lines : Int32, final : Char, io : IO) : Nil
      return if lines <= 0

      io << CSI
      io << lines unless lines == 1
      io << final
    end

    private def edit_lines(count : Int32, final : Char, io : IO) : Nil
      return if count <= 0

      io << CSI
      io << count unless count == 1
      io << final

      # Both IL and DL move the cursor to the left margin.
      @cursor_x = 0
    end

    # ---------------------------------------------------------------- modes

    private def private_mode(number : String, enabled : Bool, io : IO) : Nil
      io << CSI << '?' << number << (enabled ? 'h' : 'l')
    end

    private def sync(begin_frame : Bool, io : IO) : Nil
      return unless @capabilities.includes? Capability::SynchronizedOutput

      private_mode "2026", begin_frame, io
    end

    private def raw(bytes : Bytes, io : IO) : Nil
      io.write bytes
      reset_state
    end
  end
end
