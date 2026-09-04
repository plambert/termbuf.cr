require "../../src/termbuf"

# A terminal emulator that exists only to check the painter.
#
# It consumes the bytes the encoder produces and maintains its own screen from
# them. Replaying a paint into it and comparing the result against the buffer
# is the only way to establish that a diff is *correct* rather than merely
# plausible: it catches the whole class of optimizations that emit fewer bytes
# and put the wrong thing on screen.
#
# It implements what the encoder can emit and nothing else, and raises on
# anything it does not recognise — an unimplemented sequence is a spec bug, not
# something to skip over.
class ModelTerminal
  # One cell as the terminal sees it: the text painted there and the style it
  # was painted in. Widths are tracked so a wide character occupies two cells,
  # the second empty.
  record ModelCell, text : String, style : TermBuf::Style, width : Int32 do
    def self.blank(style : TermBuf::Style = TermBuf::Style::DEFAULT) : ModelCell
      new " ", style, 1
    end

    def self.continuation(style : TermBuf::Style) : ModelCell
      new "", style, 0
    end

    def continuation? : Bool
      width.zero?
    end
  end

  getter width : Int32
  getter height : Int32
  getter cursor_x = 0
  getter cursor_y = 0
  getter style : TermBuf::Style
  getter? autowrap = true
  getter? cursor_visible = true
  getter? synchronized = false
  getter scroll_top : Int32
  getter scroll_bottom : Int32

  @cells : Array(ModelCell)

  # *policy* has to match the buffer's, or the model measures a cluster
  # differently from the thing it is checking and every later cell on the row
  # disagrees for a reason that has nothing to do with the painter.
  # *links* has to be the table the buffer interns into, or a link the model
  # parses gets an id the buffer never assigned and every linked cell differs.
  def initialize(@width : Int32, @height : Int32,
                 @policy : TermBuf::Unicode::WidthPolicy = TermBuf::Unicode::WidthPolicy::DEFAULT,
                 @links : TermBuf::LinkTable = TermBuf::LinkTable.new)
    @cells = Array(ModelCell).new(@width * @height) { ModelCell.blank }
    @style = TermBuf::Style::DEFAULT
    @scroll_top = 0
    @scroll_bottom = @height - 1
  end

  def [](x : Int32, y : Int32) : ModelCell
    @cells[y * @width + x]
  end

  def []=(x : Int32, y : Int32, cell : ModelCell) : Nil
    @cells[y * @width + x] = cell
  end

  # ------------------------------------------------------------- comparison

  # Where this terminal's screen differs from *buffer*'s back grid, or `nil`
  # when they agree.
  #
  # The comparison goes against the style as *encoder* would render it, not the
  # style the application asked for. A terminal without italics is right to
  # show upright text; what would be wrong is showing the wrong character, or
  # the wrong colour among those it can produce.
  def diff(buffer : TermBuf::Buffer, encoder : TermBuf::Encoder? = nil) : String?
    if buffer.width != @width || buffer.height != @height
      return "size #{@width}x#{@height} does not match buffer #{buffer.width}x#{buffer.height}"
    end

    @height.times do |row|
      @width.times do |column|
        mine = self[column, row]
        theirs = buffer.back[column, row]
        style = encoder ? encoder.effective(theirs.style) : buffer.styles[theirs.style]
        expected = ModelCell.new theirs.text(buffer.clusters), style, theirs.width.to_i

        next if equivalent? mine, expected

        return "cell #{column},#{row}: terminal has #{mine.inspect}, buffer wants #{expected.inspect}"
      end
    end

    nil
  end

  # A cell's style only matters where it shows. Two blanks with different
  # foregrounds are the same blank, and the painter is entitled to leave one
  # where the other was asked for.
  private def equivalent?(mine : ModelCell, theirs : ModelCell) : Bool
    return false unless mine.text == theirs.text && mine.width == theirs.width
    return true if mine.style == theirs.style
    return false unless mine.text == " " || mine.text.empty?

    visible_style(mine.style) == visible_style(theirs.style)
  end

  private def visible_style(style : TermBuf::Style) : TermBuf::Style
    return style if style.ink?

    TermBuf::Style.new background: style.background
  end

  def to_text : String
    String.build do |io|
      @height.times do |row|
        @width.times do |column|
          cell = self[column, row]
          io << cell.text unless cell.continuation?
        end

        io << '\n' unless row == @height - 1
      end
    end
  end

  # ---------------------------------------------------------------- parsing

  def feed(bytes : String) : Nil
    reader = Char::Reader.new bytes
    text = String::Builder.new
    pending = 0

    while reader.pos < bytes.bytesize
      char = reader.current_char

      unless char.in? '\e', '\r', '\b', '\n'
        text << char
        pending += 1
        reader.next_char
        next
      end

      if pending > 0
        write_text text.to_s
        text = String::Builder.new
        pending = 0
      end

      case char
      when '\e'
        reader.next_char
        reader = parse_escape bytes, reader
        next
      when '\r' then @cursor_x = 0
      when '\b' then @cursor_x -= 1 if @cursor_x > 0
      when '\n' then line_feed
      end

      reader.next_char
    end

    write_text text.to_s if pending > 0
  end

  # A terminal decides how much room text takes by grapheme cluster, not by
  # code point: two regional indicators are one flag in one pair of cells, and
  # a combining mark joins the character before it rather than claiming a cell
  # of its own.
  private def write_text(text : String) : Nil
    TermBuf::Unicode.each_grapheme(text, @policy) do |grapheme|
      put_cluster grapheme.text(text), grapheme.width
    end
  end

  private def parse_escape(source : String, reader : Char::Reader) : Char::Reader
    return parse_osc source, reader if reader.current_char == ']'

    unless reader.current_char == '['
      raise "model terminal: unsupported escape #{reader.current_char.inspect}"
    end

    reader.next_char
    private_marker = false

    if reader.current_char == '?'
      private_marker = true
      reader.next_char
    end

    parameters = String::Builder.new

    while reader.pos < source.bytesize && !reader.current_char.ascii_letter?
      parameters << reader.current_char
      reader.next_char
    end

    final = reader.current_char
    reader.next_char
    dispatch parameters.to_s, final, private_marker
    reader
  end

  # An operating system command, which runs to a string terminator rather than
  # to a final byte. Only OSC 8 is modelled; anything else is consumed and
  # ignored, which is what a terminal without it would do.
  private def parse_osc(source : String, reader : Char::Reader) : Char::Reader
    reader.next_char
    body = String::Builder.new

    while reader.pos < source.bytesize
      if reader.current_char == '\e'
        reader.next_char
        break if reader.pos >= source.bytesize || reader.current_char == '\\'

        body << '\e'
        next
      end

      break if reader.current_char == '\a'

      body << reader.current_char
      reader.next_char
    end

    reader.next_char if reader.pos < source.bytesize
    apply_osc body.to_s
    reader
  end

  # `8 ; params ; uri`, where an empty URI closes whatever was open.
  private def apply_osc(body : String) : Nil
    return unless body.starts_with? "8;"

    fields = body[2..].split ';', 2
    uri = fields[1]? || ""
    return @style = @style.linked TermBuf::LinkTable::NONE if uri.empty?

    id = fields[0].split(':').find(&.starts_with? "id=").try &.[3..]
    @style = @style.linked @links.id(uri, id.presence)
  end

  # ameba:disable Metrics/CyclomaticComplexity
  private def dispatch(parameters : String, final : Char, private_marker : Bool) : Nil
    if private_marker
      dispatch_private parameters, final
      return
    end

    # SGR is parsed on its own: its `4:3` style subparameters are not integers.
    if final == 'm'
      apply_sgr parameters
      return
    end

    values = parse_parameters parameters

    case final
    when 'H' then move_to param(values, 1, 1) - 1, param(values, 0, 1) - 1
    when 'A' then move_to @cursor_x, @cursor_y - param(values, 0, 1)
    when 'B' then move_to @cursor_x, @cursor_y + param(values, 0, 1)
    when 'C' then move_to @cursor_x + param(values, 0, 1), @cursor_y
    when 'D' then move_to @cursor_x - param(values, 0, 1), @cursor_y
    when 'G' then move_to param(values, 0, 1) - 1, @cursor_y
    when 'K' then erase_in_line param(values, 0, 0)
    when 'J' then erase_in_display param(values, 0, 0)
    when 'X' then erase_chars param(values, 0, 1)
    when 'S' then scroll_up param(values, 0, 1)
    when 'T' then scroll_down param(values, 0, 1)
    when 'L' then insert_lines param(values, 0, 1)
    when 'M' then delete_lines param(values, 0, 1)
    when 'r' then set_margins values
    when 'n'
      # A cursor position report is a question, not an instruction. Nothing on
      # screen changes; a real terminal would answer, and nothing here reads.
    else raise "model terminal: unsupported CSI #{parameters.inspect} #{final}"
    end
  end

  private def dispatch_private(parameters : String, final : Char) : Nil
    enabled = final == 'h'
    raise "model terminal: unsupported private final #{final}" unless enabled || final == 'l'

    case parameters
    when "7"    then @autowrap = enabled
    when "25"   then @cursor_visible = enabled
    when "2026" then @synchronized = enabled
    when "1000", "1004", "1006", "1049", "2004"
      # The alternate screen, bracketed paste, focus reporting and the two
      # mouse modes change nothing about what a cell holds, which is all this
      # model is for.
    else raise "model terminal: unsupported private mode #{parameters.inspect}"
    end
  end

  private def parse_parameters(text : String) : Array(Int32)
    return [] of Int32 if text.empty?

    text.split(';').map { |field| field.empty? ? 0 : field.to_i }
  end

  private def param(values : Array(Int32), index : Int32, fallback : Int32) : Int32
    value = values[index]?
    return fallback if value.nil? || value.zero?

    value
  end

  # ------------------------------------------------------------- operations

  private def move_to(x : Int32, y : Int32) : Nil
    @cursor_x = x.clamp 0, @width - 1
    @cursor_y = y.clamp 0, @height - 1
  end

  private def put_cluster(text : String, columns : Int32) : Nil
    return if columns.zero?

    if @cursor_x + columns > @width
      return unless autowrap?

      @cursor_x = 0
      line_feed
    end

    detach @cursor_x
    detach @cursor_x + 1 if columns == 2

    self[@cursor_x, @cursor_y] = ModelCell.new text, @style, columns
    self[@cursor_x + 1, @cursor_y] = ModelCell.continuation @style if columns == 2

    @cursor_x += columns
    @cursor_x = @width - 1 if @cursor_x >= @width && !autowrap?
  end

  private def detach(column : Int32) : Nil
    return unless 0 <= column < @width

    cell = self[column, @cursor_y]

    if cell.continuation?
      self[column - 1, @cursor_y] = ModelCell.blank @style if column > 0
      self[column, @cursor_y] = ModelCell.blank @style
    elsif cell.width == 2
      self[column, @cursor_y] = ModelCell.blank @style
      self[column + 1, @cursor_y] = ModelCell.blank @style if column + 1 < @width
    end
  end

  private def line_feed : Nil
    if @cursor_y == @scroll_bottom
      scroll_up 1
    elsif @cursor_y < @height - 1
      @cursor_y += 1
    end
  end

  private def erase_in_line(mode : Int32) : Nil
    range = case mode
            when 0 then @cursor_x...@width
            when 1 then 0..@cursor_x
            else        0...@width
            end

    range.each { |column| self[column, @cursor_y] = erase_cell }
  end

  private def erase_in_display(mode : Int32) : Nil
    raise "model terminal: unsupported ED mode #{mode}" unless mode == 2

    @cells.fill erase_cell
  end

  private def erase_chars(count : Int32) : Nil
    finish = Math.min @cursor_x + count, @width

    (@cursor_x...finish).each { |column| self[column, @cursor_y] = erase_cell }
  end

  # Erasing paints the background in force but never the foreground, so it can
  # never reproduce something like an underline.
  private def erase_cell : ModelCell
    ModelCell.new " ", TermBuf::Style.new(background: @style.background), 1
  end

  private def scroll_up(lines : Int32) : Nil
    shift lines
  end

  private def scroll_down(lines : Int32) : Nil
    shift -lines
  end

  private def insert_lines(count : Int32) : Nil
    return unless @scroll_top <= @cursor_y <= @scroll_bottom

    shift_range @cursor_y, @scroll_bottom, -count
    @cursor_x = 0
  end

  private def delete_lines(count : Int32) : Nil
    return unless @scroll_top <= @cursor_y <= @scroll_bottom

    shift_range @cursor_y, @scroll_bottom, count
    @cursor_x = 0
  end

  private def shift(lines : Int32) : Nil
    shift_range @scroll_top, @scroll_bottom, lines
  end

  private def shift_range(top : Int32, bottom : Int32, lines : Int32) : Nil
    return if lines.zero?

    count = Math.min lines.abs, bottom - top + 1
    rows = (top..bottom).map { |row| (0...@width).map { |column| self[column, row] } }

    (top..bottom).each do |row|
      source = lines > 0 ? row + count : row - count
      replacement = (top <= source <= bottom) ? rows[source - top] : nil

      @width.times do |column|
        self[column, row] = replacement ? replacement[column] : erase_cell
      end
    end
  end

  private def set_margins(values : Array(Int32)) : Nil
    if values.empty? || values.all?(&.zero?)
      @scroll_top = 0
      @scroll_bottom = @height - 1
    else
      @scroll_top = (param(values, 0, 1) - 1).clamp 0, @height - 1
      @scroll_bottom = (param(values, 1, @height) - 1).clamp @scroll_top, @height - 1
    end

    @cursor_x = 0
    @cursor_y = 0
  end

  # --------------------------------------------------------------- graphics

  # ameba:disable Metrics/CyclomaticComplexity
  private def apply_sgr(parameters : String) : Nil
    fields = parameters.empty? ? ["0"] : parameters.split(';')
    index = 0

    while index < fields.size
      field = fields[index]
      index += 1

      # `4:3` and friends arrive as one field with colons inside.
      if field.starts_with?("4:")
        @style = @style.copy_with underline: underline_for(field[2..].to_i)
        next
      end

      code = field.empty? ? 0 : field.to_i

      case code
      when 0
        # A hyperlink is not an SGR attribute and `SGR 0` does not close one.
        # Only OSC 8 opens and closes it, so it survives the reset.
        @style = TermBuf::Style::DEFAULT.linked @style.link
      when 1 then @style = @style.with TermBuf::Attributes::Bold
      when 2 then @style = @style.with TermBuf::Attributes::Faint
      when 3 then @style = @style.with TermBuf::Attributes::Italic
      when 4 then @style = @style.copy_with underline: TermBuf::Underline::Single
      when 5 then @style = @style.with TermBuf::Attributes::SlowBlink
      when 6 then @style = @style.with TermBuf::Attributes::RapidBlink
      when 7 then @style = @style.with TermBuf::Attributes::Reverse
      when 8 then @style = @style.with TermBuf::Attributes::Conceal
      when 9 then @style = @style.with TermBuf::Attributes::Strike
      when 22
        @style = @style.without TermBuf::Attributes::Bold | TermBuf::Attributes::Faint
      when 23 then @style = @style.without TermBuf::Attributes::Italic
      when 24 then @style = @style.copy_with underline: TermBuf::Underline::None
      when 25
        @style = @style.without TermBuf::Attributes::SlowBlink | TermBuf::Attributes::RapidBlink
      when 27 then @style = @style.without TermBuf::Attributes::Reverse
      when 28 then @style = @style.without TermBuf::Attributes::Conceal
      when 29 then @style = @style.without TermBuf::Attributes::Strike
      when 53 then @style = @style.with TermBuf::Attributes::Overline
      when 55 then @style = @style.without TermBuf::Attributes::Overline
      when 73 then @style = @style.with TermBuf::Attributes::Superscript
      when 74 then @style = @style.with TermBuf::Attributes::Subscript
      when 75
        @style = @style.without TermBuf::Attributes::Superscript | TermBuf::Attributes::Subscript
      when 30..37   then @style = @style.fg TermBuf::Color.indexed(code - 30)
      when 40..47   then @style = @style.bg TermBuf::Color.indexed(code - 40)
      when 90..97   then @style = @style.fg TermBuf::Color.indexed(code - 82)
      when 100..107 then @style = @style.bg TermBuf::Color.indexed(code - 92)
      when 39       then @style = @style.fg TermBuf::Color.default
      when 49       then @style = @style.bg TermBuf::Color.default
      when 59       then @style = @style.copy_with underline_color: TermBuf::Color.default
      when 38, 48, 58
        color, index = read_extended_color fields, index
        @style = case code
                 when 38 then @style.fg color
                 when 48 then @style.bg color
                 else         @style.copy_with underline_color: color
                 end
      else raise "model terminal: unsupported SGR code #{code}"
      end
    end
  end

  private def underline_for(code : Int32) : TermBuf::Underline
    case code
    when 0 then TermBuf::Underline::None
    when 1 then TermBuf::Underline::Single
    when 2 then TermBuf::Underline::Double
    when 3 then TermBuf::Underline::Curly
    when 4 then TermBuf::Underline::Dotted
    when 5 then TermBuf::Underline::Dashed
    else        raise "model terminal: unsupported underline style #{code}"
    end
  end

  private def read_extended_color(fields : Array(String),
                                  index : Int32) : {TermBuf::Color, Int32}
    case fields[index]?.try(&.to_i)
    when 5
      {TermBuf::Color.indexed(fields[index + 1].to_i), index + 2}
    when 2
      color = TermBuf::Color.rgb fields[index + 1].to_i, fields[index + 2].to_i,
        fields[index + 3].to_i
      {color, index + 4}
    else
      raise "model terminal: unsupported extended colour form #{fields[index]?.inspect}"
    end
  end
end
