# A hand-check of the things a spec cannot reach.
#
#     crystal run examples/validate.cr
#
# Specs run against a model terminal, which agrees with the encoder by
# construction. The pages here ask a real one instead: what it says it can do,
# whether every cell on the screen is reachable, whether it measures characters
# the way the width tables do, and what a frame costs in bytes.
#
# Number keys or the left and right arrows change page, r redraws everything
# from scratch, q leaves.
require "../src/termbuf"

module Validate
  alias Style = TermBuf::Style
  alias Color = TermBuf::Color
  alias Rect = TermBuf::Rect

  PAGES = %w[caps edges widths colours attrs motion]

  # One line of the width page: something to draw, and what it is.
  #
  # The point of each is that the terminal has to agree with
  # `Unicode.string_width` about it, and the ones near the bottom are where
  # terminals differ from each other.
  SAMPLES = [
    {"a", "U+0061 latin small a"},
    {"Ω", "U+03A9 greek capital omega"},
    {"é", "U+00E9 precomposed e acute"},
    {"é", "U+0065 U+0301 e and combining acute"},
    {"漢", "U+6F22 han character, east asian wide"},
    {"한", "U+D55C hangul syllable"},
    {"ｱ", "U+FF71 halfwidth katakana"},
    {"Ａ", "U+FF21 fullwidth latin a"},
    {"→", "U+2192 arrow, east asian ambiguous"},
    {"█", "U+2588 full block"},
    {"─", "U+2500 box drawing"},
    {"⌚", "U+231A watch, emoji presentation"},
    {"☺", "U+263A smiling face, text presentation"},
    {"☺️", "U+263A U+FE0F, forced to emoji by VS16"},
    {"👍", "U+1F44D thumbs up"},
    {"👨‍👩‍👧‍👦", "family, four faces joined by ZWJ"},
    {"🇺🇸", "U+1F1FA U+1F1F8 regional indicator pair"},
    {"🏳️‍🌈", "rainbow flag, a ZWJ sequence"},
    {"क्षि", "devanagari conjunct plus a spacing vowel sign"},
    {"நி", "tamil na plus a spacing vowel sign"},
    {"กำ", "thai ko kai plus sara am, also spacing"},
    {"ﷺ", "U+FDFA arabic ligature"},
  ]

  # The pages, in the order the number keys select them.
  class Validator
    include TermBuf

    getter terminal : Terminal

    def initialize(@terminal : Terminal)
      @page = 0
      @repaint = true
      @filled = false
      @running = true
      @frame = 0
      @log = 0
      @frozen = false
    end

    def run : Nil
      while @running
        @frame += 1
        draw
        @terminal.paint
        pump
      end
    end

    # ------------------------------------------------------------- the frame

    private def draw : Nil
      @terminal.batch do |screen|
        # Only the motion page carries anything over between frames; the rest
        # redraw the same thing, so clearing them costs nothing in bytes.
        screen.clear if @repaint || !motion?
        @repaint = false

        case PAGES[@page]
        when "edges" then draw_edges screen
        else
          draw_chrome screen
          draw_page screen
        end
      end
    end

    private def draw_page(screen) : Nil
      case PAGES[@page]
      when "caps"    then draw_caps screen
      when "widths"  then draw_widths screen
      when "colours" then draw_colours screen
      when "attrs"   then draw_attrs screen
      when "motion"  then draw_motion screen
      end
    end

    private def motion? : Bool
      PAGES[@page] == "motion"
    end

    private def columns : Int32
      @terminal.size.columns
    end

    private def rows : Int32
      @terminal.size.rows
    end

    # --------------------------------------------------------------- chrome

    private def draw_chrome(screen) : Nil
      screen.fill Rect.new(0, 0, columns, 1), ' ', Style::DEFAULT.reverse
      screen.write 1, 0, "termbuf", Style::DEFAULT.reverse.bold

      # The names cost about sixty columns; below that the numbers alone have
      # to do, since a half-drawn tab bar says less than a full row of digits.
      named = columns >= 70
      column = 10

      PAGES.each_with_index do |name, index|
        label = named ? " #{index + 1} #{name} " : " #{index + 1} "
        style = index == @page ? Style::DEFAULT.bold : Style::DEFAULT.reverse
        screen.write column, 0, label, style
        column += label.size
      end

      screen.write 1, rows - 1, status.ljust(Math.max(columns - 1, 0)), Style::DEFAULT.faint
    end

    private def status : String
      String.build do |io|
        io << @terminal.size << "   frame " << @frame
        io << "   last paint " << @terminal.last_paint_bytes << " B"
        io << "   total " << (@terminal.total_paint_bytes / 1024).round(1) << " kB"
        io << "   [r] redraw  [q] quit"
      end
    end

    # ---------------------------------------------------------------- page 1

    private def draw_caps(screen) : Nil
      row = 2
      accent = Style::DEFAULT.fg Color.indexed(4)

      {"TERM", "TERM_PROGRAM", "COLORTERM", "TERMBUF_CAPS"}.each do |name|
        screen.write 2, row, name.ljust(14), Style::DEFAULT.faint
        screen.write 16, row, ENV[name]? || "unset", accent
        row += 1
      end

      row += 1
      screen.write 2, row, "detected", Style::DEFAULT.bold
      row += 2

      hidden = draw_capability_grid screen, row
      return if hidden.zero?

      screen.write 2, rows - 2, "#{hidden} more need a larger window",
        Style::DEFAULT.faint
    end

    # Returns how many did not fit, since a grid that quietly stops short
    # reads as a terminal with fewer capabilities than it has.
    private def draw_capability_grid(screen, top : Int32) : Int32
      members = Capability.values
      per_column = 24
      lanes = Math.max (columns - 2) // per_column, 1
      available = Math.max rows - top - 2, 1
      height = Math.min Math.max((members.size + lanes - 1) // lanes, 1), available
      shown = 0

      members.each_with_index do |member, index|
        column = 2 + (index // height) * per_column
        row = top + index % height
        next if column + per_column > columns + 2 || row >= rows - 2

        on = @terminal.capabilities.includes? member
        mark = on ? '+' : '-'
        style = on ? Style::DEFAULT.fg(Color.indexed(2)) : Style::DEFAULT.faint

        screen.write column, row, "#{mark} #{member}", style
        shown += 1
      end

      members.size - shown
    end

    # ---------------------------------------------------------------- page 2

    # Every cell of the screen, corners included. If the terminal wraps or
    # scrolls when the bottom right cell is written, the box loses its top row
    # and everything shifts; if it does not, this is a closed rectangle.
    private def draw_edges(screen) : Nil
      return draw_fill screen if @filled

      last_column = columns - 1
      last_row = rows - 1

      screen.write 1, 0, "─" * Math.max(columns - 2, 0)
      screen.write 1, last_row, "─" * Math.max(columns - 2, 0)

      (1...last_row).each do |row|
        screen.write_char 0, row, '│'
        screen.write_char last_column, row, '│'
      end

      screen.write_char 0, 0, '┌'
      screen.write_char last_column, 0, '┐'
      screen.write_char 0, last_row, '└'
      # The one that matters: the last cell of the last row.
      screen.write_char last_column, last_row, '┘'

      draw_rulers screen
      draw_edge_help screen
    end

    # A scale along the top and down the left, so a column or row can be
    # counted rather than guessed at.
    private def draw_rulers(screen) : Nil
      (1...columns - 1).each do |column|
        next unless column % 10 == 0

        screen.write_char column, 0, '┬'
        screen.write column - 1, 1, column.to_s.rjust(3), Style::DEFAULT.faint
      end

      (2...rows - 1).each do |row|
        next unless row % 5 == 0

        screen.write_char 0, row, '├'
        screen.write 1, row, row.to_s.rjust(3), Style::DEFAULT.faint
      end
    end

    private def draw_edge_help(screen) : Nil
      lines = [
        {"the whole screen, edge to edge", Style::DEFAULT.bold},
        {"", Style::DEFAULT},
        {"the box should be closed on all four sides, with #{columns - 1} and", Style::DEFAULT},
        {"#{rows - 1} as the last column and row on the rulers. A missing top", Style::DEFAULT},
        {"edge means writing the bottom right cell scrolled the screen.", Style::DEFAULT},
        {"", Style::DEFAULT},
        {"[f] fill every cell   [r] redraw   [1-6] page   [q] quit", Style::DEFAULT.faint},
      ]

      top = Math.max (rows - lines.size) // 2, 2

      lines.each_with_index do |(text, style), offset|
        next if top + offset >= rows - 1

        screen.write Math.max((columns - 62) // 2, 6), top + offset, text, style
      end
    end

    # Something in every cell, so a cell that never gets painted shows up as a
    # hole. The digit is the column modulo ten, which also makes a shifted row
    # obvious.
    private def draw_fill(screen) : Nil
      rows.times do |row|
        line = String.build do |io|
          columns.times { |column| io << (column % 10) }
        end

        tint = Color.indexed 232 + (row * 23 // Math.max(rows - 1, 1))
        screen.write 0, row, line, Style::DEFAULT.bg(tint).fg(Color.indexed(15))
      end

      screen.write 2, rows // 2, " every cell is written; press f for the box ",
        Style::DEFAULT.reverse.bold
    end

    # ---------------------------------------------------------------- page 3

    # Each row is written as one string, so the painter sends it as one run and
    # the terminal's own idea of how wide the sample is decides where the bar
    # after it lands. Every bar in one straight column means the terminal and
    # the width tables agree.
    private def draw_widths(screen) : Nil
      bar = Math.min columns - 34, 24
      return screen.write 2, 2, "need a wider window", Style::DEFAULT if bar < 12

      screen.write 2, 2, "w  sample#{"." * (bar - 9)}|  every bar should be in this column",
        Style::DEFAULT.bold

      row = 4
      shown = 0

      SAMPLES.each do |(sample, description)|
        break if row >= rows - 3

        width = Unicode.string_width sample
        dots = Math.max bar - 3 - width, 0
        screen.write 2, row, "#{width}  #{sample}#{"." * dots}|  #{description}"

        row += 1
        shown += 1
      end

      note = shown < SAMPLES.size ? "#{SAMPLES.size - shown} more need a taller window; " : ""
      screen.write 2, rows - 2,
        "#{note}terminals differ most on VS16 and ZWJ sequences",
        Style::DEFAULT.faint
    end

    # ---------------------------------------------------------------- page 4

    private def draw_colours(screen) : Nil
      caps = @terminal.capabilities
      row = 2

      screen.write 2, row, "16 colours", Style::DEFAULT.bold
      screen.write 20, row, caps.includes?(Capability::BrightColors) ? "with bright" : "no bright",
        Style::DEFAULT.faint
      row += 1

      16.times do |index|
        screen.write 2 + index * 4, row, index.to_s.rjust(3).ljust(4),
          Style::DEFAULT.bg(Color.indexed(index)).fg(Color.indexed(index < 8 ? 15 : 0))
      end
      row += 2

      screen.write 2, row, "216 colour cube", Style::DEFAULT.bold
      row += 1

      6.times do |band|
        36.times do |offset|
          screen.write_char 2 + offset, row + band, ' ',
            Style::DEFAULT.bg(Color.indexed(16 + band * 36 + offset))
        end
      end
      row += 7

      screen.write 2, row, "greys", Style::DEFAULT.bold
      row += 1

      24.times do |index|
        screen.write_char 2 + index, row, ' ', Style::DEFAULT.bg(Color.indexed(232 + index))
      end
      row += 2

      draw_gradient screen, row
    end

    private def draw_gradient(screen, row : Int32) : Nil
      return if row >= rows - 3

      caps = @terminal.capabilities
      label = caps.includes?(Capability::TrueColor) ? "24 bit" : "24 bit, downgraded"
      screen.write 2, row, "#{label} — should be a smooth sweep", Style::DEFAULT.bold
      row += 1

      span = Math.max columns - 4, 1

      span.times do |offset|
        hue = offset * 360.0 / span
        screen.write_char 2 + offset, row, ' ', Style::DEFAULT.bg(from_hue(hue))
      end

      sample = Color.rgb 200, 40, 90
      screen.write 2, row + 2,
        "rgb(200,40,90) is sent as #{describe_colour sample}", Style::DEFAULT.faint
    end

    # What the encoder will make of *colour* under the capabilities in force.
    private def describe_colour(colour : Color) : String
      caps = @terminal.capabilities
      return colour.to_s if caps.includes? Capability::TrueColor
      return colour.to_indexed256.to_s if caps.includes? Capability::Color256
      return colour.to_indexed16.to_s if caps.includes? Capability::Color16

      "nothing; this terminal has no colour"
    end

    private def from_hue(hue : Float64) : Color
      sector = (hue / 60.0).to_i % 6
      rise = ((hue % 60.0) / 60.0 * 255).to_i
      fall = 255 - rise

      case sector
      when 0 then Color.rgb 255, rise, 0
      when 1 then Color.rgb fall, 255, 0
      when 2 then Color.rgb 0, 255, rise
      when 3 then Color.rgb 0, fall, 255
      when 4 then Color.rgb rise, 0, 255
      else        Color.rgb 255, 0, fall
      end
    end

    # ---------------------------------------------------------------- page 5

    ATTRIBUTES = [
      {"bold", Capability::Bold},
      {"faint", Capability::Faint},
      {"italic", Capability::Italic},
      {"reverse", Capability::Reverse},
      {"strike", Capability::Strike},
      {"conceal", Capability::Conceal},
      {"slow blink", Capability::Blink},
      {"rapid blink", Capability::RapidBlink},
      {"overline", Capability::Overline},
      {"superscript", Capability::Superscript},
      {"subscript", Capability::Superscript},
    ]

    private def draw_attrs(screen) : Nil
      screen.write 2, 2, "attribute      capability   sample", Style::DEFAULT.bold
      row = 4

      ATTRIBUTES.each do |(name, capability)|
        break if row >= rows - 2

        style = attribute_style name
        held = @terminal.capabilities.includes? capability

        screen.write 2, row, name.ljust(15), Style::DEFAULT.faint
        screen.write 17, row, held ? "yes" : "no ",
          held ? Style::DEFAULT : Style::DEFAULT.fg(Color.indexed(1))
        screen.write 30, row, "the quick brown fox", style

        row += 1
      end

      draw_underlines screen, row + 1
    end

    private def attribute_style(name : String) : Style
      case name
      when "bold"        then Style::DEFAULT.bold
      when "faint"       then Style::DEFAULT.faint
      when "italic"      then Style::DEFAULT.italic
      when "reverse"     then Style::DEFAULT.reverse
      when "strike"      then Style::DEFAULT.strike
      when "conceal"     then Style::DEFAULT.conceal
      when "slow blink"  then Style::DEFAULT.blink
      when "rapid blink" then Style::DEFAULT.blink rapid: true
      when "overline"    then Style::DEFAULT.with Attributes::Overline
      when "superscript" then Style::DEFAULT.with Attributes::Superscript
      when "subscript"   then Style::DEFAULT.with Attributes::Subscript
      else                    Style::DEFAULT
      end
    end

    private def draw_underlines(screen, top : Int32) : Nil
      caps = @terminal.capabilities
      extended = caps.includes? Capability::ExtendedUnderline
      coloured = caps.includes? Capability::UnderlineColor

      screen.write 2, top, "underline styles", Style::DEFAULT.bold
      screen.write 20, top,
        extended ? "4:x subparameters" : "no 4:x; all of these degrade to single",
        Style::DEFAULT.faint

      row = top + 1

      Underline.values.reject(&.none?).each_with_index do |kind, index|
        break if row >= rows - 1

        colour = coloured ? Color.indexed(1 + index) : Color.default
        screen.write 2, row, kind.to_s.downcase.ljust(15), Style::DEFAULT.faint
        screen.write 17, row, "the quick brown fox",
          Style::DEFAULT.underlined(kind, colour)

        row += 1
      end
    end

    # ---------------------------------------------------------------- page 6

    # The claim the whole buffer exists to make: a frame costs a diff, not a
    # screenful. A line arrives at the bottom of the box every frame and the
    # rest slides up, which is one scroll and one row if the terminal has
    # DECSTBM and a redraw of the box if it has not. The byte count in the
    # status line is the difference.
    private def draw_motion(screen) : Nil
      # Full width, because DECSTBM sets a top and a bottom margin and
      # nothing else: a region narrower than the screen cannot be scrolled by
      # the terminal and has to be redrawn instead.
      box = Rect.new 0, 4, columns, Math.max(rows - 8, 1)
      return if box.height < 3

      if @repaint || @log.zero?
        screen.fill box, ' '
      end

      screen.write 2, 2, "scrolling region", Style::DEFAULT.bold
      screen.write 20, 2,
        @terminal.capabilities.includes?(Capability::ScrollRegion) ? "DECSTBM available" : "no DECSTBM; expect a redraw",
        Style::DEFAULT.faint

      return draw_motion_help screen if @frozen

      screen.scroll box, 1
      @log += 1

      bottom = box.bottom
      bar = (Math.sin(@log / 6.0) * 0.5 + 0.5) * (box.width - 24)
      screen.write box.x + 2, bottom,
        "#{@log.to_s.rjust(6)}  #{"█" * bar.to_i}",
        Style::DEFAULT.fg(Color.indexed(1 + @log % 6))

      draw_motion_help screen
    end

    private def draw_motion_help(screen) : Nil
      screen.write 2, rows - 3,
        @frozen ? "frozen: the bytes left are the status line, which still changes. [space] to run" : "[space] freeze, and watch the byte count drop to the status line alone",
        Style::DEFAULT.faint
    end

    # ---------------------------------------------------------------- input

    private def pump : Nil
      select
      when event = @terminal.events.receive?
        handle event
      when timeout 50.milliseconds
        # Nothing arrived; the next frame goes out anyway.
      end
    end

    private def handle(event) : Nil
      case event
      in Events::Input   then keys String.new(event.bytes)
      in Events::Resize  then @repaint = true
      in Events::Closed  then @running = false
      in Events::Failure then @running = false
      in Events::Response, Events::Warning
        # Nothing here asks the terminal anything, so neither should happen.
      in Nil
        @running = false
      end
    end

    private def keys(text : String) : Nil
      text.each_char do |key|
        case key
        when 'q'      then @running = false
        when 'r'      then force_repaint
        when 'f'      then @filled = !@filled
        when ' '      then @frozen = !@frozen
        when '1'..'9' then go_to key.to_i - 1
        when 'C'      then go_to @page + 1 # the tail of the right arrow
        when 'D'      then go_to @page - 1 # and of the left
        end
      end
    end

    private def go_to(page : Int32) : Nil
      return unless 0 <= page < PAGES.size
      return if page == @page

      @page = page
      @repaint = true
      @log = 0
    end

    private def force_repaint : Nil
      @repaint = true
      @terminal.paint!
    end
  end
end

TermBuf::Terminal.open do |terminal|
  Validate::Validator.new(terminal).run
end

puts "terminal restored"
