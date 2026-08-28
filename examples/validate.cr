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

  PAGES = %w[caps edges widths colours attrs motion keys cursors measured panels field]

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

  # The pages, in the order tab walks them.
  class Validator
    include TermBuf

    getter terminal : Terminal
    @field : Field

    def initialize(@terminal : Terminal)
      @page = 0
      @rebuild = true
      @filled = false
      @running = true
      @frame = 0
      @log = 0
      @frozen = false
      @focused = false
      @presses = [] of String
      @arriving = nil.as(Int32?)
      @entered = [] of String
      @field = self.class.build_field
      @typed = ""
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
      # Whether the page has to be built from nothing, which is a different
      # question from whether the terminal needs sending it again.
      rebuild = @rebuild
      @rebuild = false

      @terminal.batch do |screen|
        # Only the motion page carries anything over between frames; the rest
        # redraw the same thing, so clearing them costs nothing in bytes.
        screen.clear if rebuild || !motion?

        case PAGES[@page]
        when "edges" then draw_edges screen
        else
          draw_chrome screen
          draw_page screen
        end

        draw_arriving screen
      end
    end

    private def draw_page(screen) : Nil
      case PAGES[@page]
      when "caps"     then draw_caps screen
      when "widths"   then draw_widths screen
      when "colours"  then draw_colours screen
      when "attrs"    then draw_attrs screen
      when "motion"   then draw_motion screen
      when "keys"     then draw_keys screen
      when "cursors"  then draw_cursors screen
      when "measured" then draw_measured screen
      when "panels"   then draw_panels screen
      when "field"    then draw_field screen
      end
    end

    private def motion? : Bool
      PAGES[@page] == "motion"
    end

    private def keys? : Bool
      PAGES[@page] == "keys"
    end

    private def field? : Bool
      PAGES[@page] == "field"
    end

    private def cursors? : Bool
      PAGES[@page] == "cursors"
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

      # The names cost about ninety columns. Below that a half-drawn bar says
      # less than naming the page you are on and how far along it is, since
      # tab is the only way to move and the others cannot be reached directly.
      return draw_narrow_tabs screen if columns < 96

      column = 10

      PAGES.each_with_index do |name, index|
        label = " #{name} "
        style = index == @page ? Style::DEFAULT.bold : Style::DEFAULT.reverse
        screen.write column, 0, label, style
        column += label.size
      end

      screen.write 1, rows - 1, status.ljust(Math.max(columns - 1, 0)), Style::DEFAULT.faint
    end

    # *note* once the page has the keyboard, and how to give it the keyboard
    # before that.
    private def focus_note(note : String) : String
      @focused ? note : "press enter to type here"
    end

    # An unbroken line across the terminal, separating a page's sections.
    # Written rather than filled: the light horizontal is East Asian Ambiguous,
    # so on a terminal that draws it two cells wide a fill would refuse it,
    # while a write lays down as many as the row holds.
    private def rule(screen, y : Int32) : Nil
      screen.write 0, y, "─" * columns, Style::DEFAULT.faint
    end

    # What the keyboard does here, which changes with the page and with
    # whether it has been entered.
    private def keys_note : String
      return "[esc] leave the pane  [ctrl-r] redraw" if @focused
      return "[enter] type here  [tab] page  [ctrl-r] redraw  [q] quit" if typeable?

      "[tab]/[shift-tab] page  [ctrl-r] redraw  [q] quit"
    end

    private def draw_narrow_tabs(screen) : Nil
      screen.write 10, 0, " #{PAGES[@page]} ", Style::DEFAULT.bold
      screen.write 12 + PAGES[@page].size, 0, "#{@page + 1} of #{PAGES.size}",
        Style::DEFAULT.reverse
    end

    private def status : String
      String.build do |io|
        io << @terminal.size << "   frame " << @frame
        io << "   last paint " << @terminal.last_paint_bytes << " B"
        io << "   total " << (@terminal.total_paint_bytes / 1024).round(1) << " kB"
        io << "   " << keys_note
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

        screen.write column, row, "#{mark} ", style
        # A capability that draws something draws its own name in it, so a
        # claim the terminal does not honour is one glance away from being
        # spotted: strike-through that renders as plain text says more than a
        # green plus does.
        screen.write column + 2, row, member.to_s, on ? shown_as(member) : style
        shown += 1
      end

      members.size - shown
    end

    # The style *member* turns on, for a capability that changes how text
    # looks. The rest keep the colour that says they were detected.
    private def shown_as(member : Capability) : Style
      found = Style::DEFAULT.fg Color.indexed(2)

      # Conceal is left out of both: a working one draws the name as nothing,
      # which reads as a bug rather than a demonstration. Page 5 shows it
      # beside a label that stays put.
      attributed(member, found) || coloured(member, found) || found
    end

    private def attributed(member : Capability, found : Style) : Style?
      case member
      when .bold?        then found.bold
      when .faint?       then found.faint
      when .italic?      then found.italic
      when .reverse?     then found.reverse
      when .strike?      then found.strike
      when .blink?       then found.blink
      when .rapid_blink? then found.blink rapid: true
      when .overline?    then found.with Attributes::Overline
      when .superscript? then found.with Attributes::Superscript
      end
    end

    private def coloured(member : Capability, found : Style) : Style?
      case member
      when .underline?          then found.underlined
      when .extended_underline? then found.underlined Underline::Curly
      when .underline_color?    then found.underlined Underline::Single, Color.indexed(1)
      when .bright_colors?      then found.fg Color.indexed(10)
      when .color256?           then found.fg Color.indexed(208)
      when .true_color?         then found.fg Color.rgb(255, 140, 0)
      when .osc8_links?         then found.linked 1_u32
      end
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
        {"[f] fill every cell   [ctrl-r] redraw   [tab] page   [q] quit", Style::DEFAULT.faint},
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
      policy = @terminal.widths

      SAMPLES.each do |(sample, description)|
        break if row >= rows - 3

        width = Unicode.string_width sample, policy
        dots = Math.max bar - 3 - width, 0
        screen.write 2, row, "#{width}  #{sample}#{"." * dots}|  #{description}"

        row += 1
        shown += 1
      end

      note = shown < SAMPLES.size ? "#{SAMPLES.size - shown} more need a taller window; " : ""
      # Without the wrapper, since the row is only so wide.
      rules = policy.to_s.lchop("WidthPolicy(").rchop(')')
      screen.write 2, rows - 3, "#{note}measured: #{rules}", Style::DEFAULT.faint
      screen.write 2, rows - 2,
        "a bar out of line: the terminal moved the cursor further than this counted. " \
        "a glyph over its neighbour: it drew wider than it moved.",
        Style::DEFAULT.faint
    end

    # ---------------------------------------------------------------- page 9

    # What the terminal said when it was asked how wide a cluster is, beside
    # what the width tables would have assumed. A row where the two differ is
    # a rule this terminal has its own opinion about; one marked `unexplained`
    # is an opinion no rule here reaches, and clusters like it will be drawn
    # in the wrong place.
    private def draw_measured(screen) : Nil
      readings = @terminal.width_readings

      if readings.empty?
        screen.write 2, 2, "the terminal was not asked", Style::DEFAULT.bold
        screen.write 2, 4, "either it is not a terminal, probing was turned off,",
          Style::DEFAULT.faint
        screen.write 2, 5, "or TERMBUF_WIDTHS=off said not to.", Style::DEFAULT.faint
        return
      end

      screen.write 2, 2, "said  ours  rule                 what of it            sample",
        Style::DEFAULT.bold
      screen.write 2, 3, @terminal.widths.to_s.lchop("WidthPolicy(").rchop(')'),
        Style::DEFAULT.faint

      policy = @terminal.widths
      row = 5

      readings.each do |reading|
        break if row >= rows - 2

        ours = Unicode.string_width reading.sample.text, policy
        said = reading.measured
        # A sample the terminal never answered is not a disagreement, it is a
        # terminal that stopped talking.
        odd = said && said != ours
        style = odd ? Style::DEFAULT.fg(Color.indexed(1)) : Style::DEFAULT

        # The sample goes last, on its own. A cluster this terminal counts
        # differently takes the rest of its row with it, and a table that comes
        # apart is no use for reading which terminal counted what.
        screen.write 2, row, (said || "-").to_s.rjust(4), style
        screen.write 8, row, ours.to_s.rjust(4), style
        screen.write 14, row, (reading.sample.rule || "-"), Style::DEFAULT.faint
        screen.write 35, row, odd ? "no rule reaches this" : "", style
        screen.write 58, row, reading.sample.text

        row += 1
      end
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

      row = draw_one_hue screen, row + 2, span

      sample = Color.rgb 200, 40, 90
      screen.write 2, row + 1,
        "rgb(200,40,90) is sent as #{describe_colour sample}", Style::DEFAULT.faint
    end

    # One hue from black to full, which is what tells 24 bit colour from the
    # palette. A sweep through every hue looks smooth either way at this width,
    # because 256 has enough hues to fake it; a single hue does not, because the
    # cube carries six levels per channel and the steps are unmistakable.
    private def draw_one_hue(screen, row : Int32, span : Int32) : Int32
      return row if row >= rows - 3

      screen.write 2, row, "one hue, black to full — steps here mean it is being quantized",
        Style::DEFAULT.bold
      row += 1

      span.times do |offset|
        level = offset * 255 // Math.max(span - 1, 1)
        shade = Color.rgb level * 40 // 255, level * 110 // 255, level
        screen.write_char 2 + offset, row, ' ', Style::DEFAULT.bg(shade)
      end

      row + 1
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

    # ---------------------------------------------------------------- page 7

    # What the decoder makes of a real keyboard, which is the only place to
    # find out: no two terminals agree on how to report a modified key, and a
    # spec can only check the sequences somebody thought to write down.
    private def draw_keys(screen) : Nil
      caps = @terminal.capabilities
      screen.write 2, 2, "press keys", Style::DEFAULT.bold
      screen.write 20, 2,
        caps.includes?(Capability::BracketedPaste) ? "paste something too" : "no bracketed paste here",
        Style::DEFAULT.faint

      room = Math.max rows - 8, 1

      @presses.last(room).each_with_index do |line, offset|
        screen.write 2, 4 + offset, line
      end

      screen.write 2, rows - 3,
        "everything pressed here is listed, except tab, shift-tab, ctrl-r and q, " \
        "which act. paste to see the notice.",
        Style::DEFAULT.faint
    end

    # ---------------------------------------------------------------- page 8

    # A cursor streaming into a pane, and the terminal's own cursor following
    # it. What a spec cannot check is whether the block ends up where the next
    # character is going to appear, which needs eyes on a real terminal.
    #
    # The pane is redrawn from the text typed so far every frame, so wrapping
    # and scrolling happen afresh each time and only the tail of a long enough
    # paragraph survives — which is what a pane with no scrollback does.
    private def draw_cursors(screen) : Nil
      screen.write 2, 2, "type into the pane", Style::DEFAULT.bold
      screen.write 22, 2, focus_note("the block is the terminal's cursor"),
        Style::DEFAULT.faint

      pane = Rect.new 3, 5, Math.max(columns - 6, 4), Math.max(rows - 12, 2)
      return if pane.height < 2

      draw_pane_border screen, pane
      stream screen, pane
      draw_escape_samples screen, pane.bottom + 3

      screen.write 2, rows - 3,
        "everything but tab and q is typed   [tab] next page   [q] quit",
        Style::DEFAULT.faint
    end

    private def draw_pane_border(screen, pane : Rect) : Nil
      faint = Style::DEFAULT.faint
      width = pane.width

      screen.write pane.x - 1, pane.y - 1, "┌#{"─" * width}┐", faint
      screen.write pane.x - 1, pane.bottom + 1, "└#{"─" * width}┘", faint

      pane.each_row do |row|
        screen.write_char pane.x - 1, row, '│', faint
        screen.write_char pane.right + 1, row, '│', faint
      end
    end

    # The cursor writes into the batch this frame is being built in, so the
    # whole pane reaches the owning fibre as one channel operation like
    # everything else on the page.
    private def stream(screen, pane : Rect) : Nil
      cursor = Cursor.new screen, Region.new(pane)
      cursor.print @typed
      @terminal.hardware_cursor = cursor
    end

    SAMPLE = "plain \e[1mbold\e[0m \e[3;38;5;208mitalic\e[0m \e[4:3mcurly\e[0m"

    private def draw_escape_samples(screen, row : Int32) : Nil
      return if row >= rows - 1

      screen.write 2, row, "scanned", Style::DEFAULT.faint
      sample(screen, row, raw: false).print SAMPLE

      return if row + 1 >= rows - 1

      screen.write 2, row + 1, "raw", Style::DEFAULT.faint
      sample(screen, row + 1, raw: true).print SAMPLE
    end

    # One row, so autowrap comes off: a single row region has nowhere to wrap
    # to and would scroll away what it was showing.
    private def sample(screen, row : Int32, raw : Bool) : Cursor
      bounds = Rect.new 12, row, Math.max(columns - 14, 4), 1
      Cursor.new screen, Region.new(bounds), raw: raw, autowrap: false
    end

    # A paste big enough to take a moment says so, or the application looks
    # hung. The driver does not draw this: the buffer belongs to whoever is
    # using it, and something writing into it uninvited would have to undraw
    # itself and would fight whatever else is painting.
    private def draw_arriving(screen) : Nil
      bytes = @arriving
      return unless bytes

      label = " pasting… #{bytes} bytes "
      width = Math.min label.size + 4, columns
      x = (columns - width) // 2
      y = (rows - 3) // 2
      return if x < 0 || y < 0 || rows < 3

      screen.fill Rect.new(x, y, width, 3), ' ', Style::DEFAULT.reverse
      screen.write x + (width - label.size) // 2, y + 1, label,
        Style::DEFAULT.reverse.bold
    end

    # --------------------------------------------------------------- page 10

    WORDS = %w[amber azure carmine cerulean chartreuse cobalt crimson indigo
      magenta ochre saffron scarlet sienna teal ultramarine vermilion]

    def self.build_field : Field
      editor = Editor.new(
        history: History.new(search: History::Search::Prefix),
        completions: ->(request : Completion::Request) do
          Completion::Result.new WORDS.select(&.starts_with? request.word)
        end)

      Field.new(
        bounds: Rect.new(2, 4, 40, 3),
        editor: editor,
        border: Border.rounded(title: " type here "),
        prompt: Field::Prompt.new("› ", Style::DEFAULT.fg(Color.indexed(4))),
        growth: Field::Growth::Grow,
        max_rows: 8,
        placeholder: "type sc, or c, then tab")
    end

    # Clipping, a view's own style, and a background that varies under text.
    # A row that reads right proves all three: the bar is painted once, the
    # label crosses where its colour changes, and nothing reaches past the
    # panel's border.
    private def draw_panels(screen) : Nil
      screen.write 2, 2, "views: clipping, a base style, backgrounds", Style::DEFAULT.bold

      rule screen, 3
      draw_rows screen
      rule screen, 9
      draw_clipping screen
      rule screen, 16
      draw_bar screen
    end

    # Highlighted rows drawn without repeating the highlight in every column.
    private def draw_rows(screen) : Nil
      width = Math.min columns - 4, 46

      3.times do |index|
        style = index == 1 ? Style::DEFAULT.bg(Color.indexed(24)) : Style::DEFAULT
        row = screen.view Rect.new(2, 4 + index, width, 1), style
        row.clear
        row.write 0, 0, "row #{index}", Style::DEFAULT.bold
        row.write 10, 0, "a second column, faint", Style::DEFAULT.faint
      end

      screen.write 2, 7, "the highlight is on the middle row's view; the two writes",
        Style::DEFAULT.faint
      screen.write 2, 8, "in every row pass only bold and faint, never a background",
        Style::DEFAULT.faint
    end

    # Text cut at a panel's edge, including the two cases a wide glyph makes:
    # one that will not fit the last cell, and one the far edge cuts in half.
    #
    # The interior is filled with dots first, so a cell the clipping left
    # untouched is visible rather than being an indistinguishable blank.
    private def draw_clipping(screen) : Nil
      # Fixed rather than sized to the terminal: the interior has to come to an
      # odd number of cells for a two-cell glyph to be left with nowhere to go.
      box = Rect.new 2, 10, 23, 6
      Border.new(Border::ROUNDED, title: "clipped").draw screen, box

      inside = screen.view Border.inset(box)
      inside.fill inside.bounds, '.', Style::DEFAULT.faint

      inside.write 0, 0, "this line is far longer than the box"
      inside.write 0, 1, WIDE_SAMPLE
      inside.write -1, 2, WIDE_SAMPLE
      draw_orphan inside

      label screen, box, 0, "ascii, cut at the border"
      label screen, box, 1, "the last cell will not hold a wide glyph"
      label screen, box, 2, "one the left edge halves is dropped"
      label screen, box, 3, "a fill blanks a glyph it lands inside"
    end

    # Eleven glyphs of two cells each against a twenty-one cell panel, so one
    # of them has nowhere to go whichever edge the run is pushed against.
    WIDE_SAMPLE = "日本語のテキストです、"

    # A wide glyph already on the row, with a fill landing partway through it.
    private def draw_orphan(inside) : Nil
      inside.write 0, 3, WIDE_SAMPLE
      inside.fill Rect.new(7, 3, 8, 1), ' ', Style::DEFAULT.bg(Color.indexed(24))
    end

    private def label(screen, box : Rect, row : Int32, text : String) : Nil
      screen.write box.right + 3, box.y + 1 + row, text, Style::DEFAULT.faint
    end

    # A label across a bar, taking each cell's colour as it goes. Half filled
    # and the label centred, so the join lands inside a word rather than on a
    # space, where it would be impossible to tell from a bar that simply
    # stopped at the text.
    private def draw_bar(screen) : Nil
      width = Math.min columns - 4, 46
      filled = width // 2
      y = 17

      row = screen.view Rect.new(2, y, width, 1)
      row.fill Rect.new(0, 0, filled, 1), ' ', Style::DEFAULT.bg(Color.indexed(28))
      row.fill Rect.new(filled, 0, width - filled, 1), ' ',
        Style::DEFAULT.bg(Color.indexed(236))

      label = " 50% of #{width} cells "
      row.write Math.max((width - label.size) // 2, 0), 0, label,
        Style::DEFAULT.bold, keep_background: true

      screen.write_char 2 + filled, y + 1, '^', Style::DEFAULT.faint
      screen.write 2, y + 2,
        "the bar ends at the caret; the label crosses it, taking each cell's colour",
        Style::DEFAULT.faint
    end

    # An input field driven from an application's own loop rather than by
    # `Field#run`, which is what most applications with anything else on screen
    # will do.
    private def draw_field(screen) : Nil
      field = @field
      width = Math.min columns - 4, 44
      field.bounds = Rect.new 2, 4, Math.max(width, 8), field.desired_height
      field.draw screen

      x, y = field.cursor_position
      @terminal.cursor.move_to x, y

      screen.write 2, 2, "an input field", Style::DEFAULT.bold
      screen.write 20, 2, focus_note("enter accepts, up walks back"),
        Style::DEFAULT.faint
      screen.write 2, 3, "tab completes a colour name: #{WORDS.first(4).join(", ")}, …",
        Style::DEFAULT.faint

      row = field.bounds.bottom + 2

      @entered.last(Math.max(rows - row - 2, 0)).each_with_index do |line, offset|
        screen.write 4, row + offset, line.inspect, Style::DEFAULT.faint
      end
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
      in Events::Key     then press event.key, event.bytes
      in Events::Resize  then @rebuild = true
      in Events::Closed  then @running = false
      in Events::Failure then @running = false
      in Events::Paste   then pasted event.text, event.complete
      in Events::Pasting then arriving event.bytes
      in Events::Response, Events::Warning
        # Nothing here asks the terminal anything.
      in Nil
        @running = false
      end
    end

    # Two pages want the keyboard for themselves, so they are entered rather
    # than merely visited: nothing on them acts until enter, and escape gives
    # the keyboard back. That is what leaves tab free to mean the same thing
    # everywhere.
    private def press(key : Key, bytes : Bytes) : Nil
      remember key, bytes

      if @focused
        return leave_page if key.is? Key::Name::Escape
        return focused_key key
      end

      browsing_key key
    end

    # What the keys mean on a page that has not been entered, which is every
    # page until enter is pressed on one of the two that take typing.
    private def browsing_key(key : Key) : Nil
      return force_repaint if key.ctrl? && key.character? && key.char == 'r'
      return go_to(key.shift? ? @page - 1 : @page + 1) if key.is? Key::Name::Tab
      return @running = false if key.is? 'q'
      return enter_page if key.is?(Key::Name::Enter) && typeable?

      # The keys page is here to show what arrives, so everything the lines
      # above have not claimed is left alone for it to draw.
      return if keys?

      case key.name
      when .right? then go_to @page + 1
      when .left?  then go_to @page - 1
      else              command key
      end
    end

    private def command(key : Key) : Nil
      return unless key.character?

      case key.char
      when 'f' then @filled = !@filled
      when ' ' then @frozen = !@frozen
      end
    end

    # Whether this page has something to type into.
    private def typeable? : Bool
      field? || cursors?
    end

    private def enter_page : Nil
      @focused = true
      @rebuild = true
    end

    private def leave_page : Nil
      @focused = false
      @rebuild = true
    end

    private def focused_key(key : Key) : Nil
      field? ? field_key(key) : type(key)
    end

    private def type(key : Key) : Nil
      case key.name
      when .enter?     then @typed += "\n"
      when .backspace? then @typed = @typed[0, Math.max(@typed.size - 1, 0)]
      when .character? then @typed += key.char
      end
    end

    # Only what was pressed while the keys page is showing. Recording
    # everywhere filled it with the tab presses that walked here, so arriving
    # meant reading someone else's log before your own.
    private def remember(key : Key, bytes : Bytes) : Nil
      return unless keys?

      note "#{key.to_s.ljust(18)}#{String.new(bytes).inspect}"
    end

    private def note(line : String) : Nil
      @presses << line
      @presses.shift if @presses.size > 64
    end

    # Once the page has been entered the field gets everything, tab included:
    # completion is what tab is for in a text field, and escape has already
    # been taken as the way back out.
    private def field_key(key : Key) : Nil
      case @field.handle key
      in Editor::Outcome::Continue  then nil
      in Editor::Outcome::Accepted  then @entered << @field.editor.accepted
      in Editor::Outcome::Cancelled then @field.text = ""
      in Editor::Outcome::Ended     then @running = false
      end
    end

    private def pasted(text : String, complete : Bool) : Nil
      preview = text.size > 40 ? "#{text[0, 40]}…" : text
      tail = complete ? "" : ", never closed"
      return @field.paste text if field? && @focused

      # Logged on the keys page for the same reason keystrokes are: that is the
      # page showing what arrived.
      note "#{"paste".ljust(18)}#{preview.inspect} (#{text.bytesize} bytes#{tail})" if keys?

      # The notice was drawn over whatever was underneath, and the motion page
      # does not clear between frames.
      @arriving = nil
      @rebuild = true
    end

    private def arriving(bytes : Int32) : Nil
      @arriving = bytes
    end

    private def go_to(page : Int32) : Nil
      return unless 0 <= page < PAGES.size
      return if page == @page

      @page = page
      @rebuild = true
      @log = 0
      # Leaving a page gives its keyboard back, so tab always means the same
      # thing on arrival.
      @focused = false
      # The keys page shows this visit, not the last one.
      @presses.clear if keys?
      field? ? @terminal.hardware_cursor = @terminal.cursor : @terminal.hide_cursor
      # Only one page has anywhere for someone to type, so the terminal's own
      # cursor has no business blinking on the others.
      @terminal.hide_cursor unless cursors?

      # On a terminal that counts a cluster's columns by adding up its code
      # points, a row holding one leaves the screen showing something the
      # buffer has no record of, so the diff skips cells that are wrong and the
      # last page's text is still there.
      #
      # Repainting clears the rows that no longer carry such a cluster, which
      # is most of them. It cannot clear the rest: the rewrite lands at the
      # columns the buffer counted, and on those rows the terminal puts them
      # somewhere else. Every other terminal keeps the diff.
      force_repaint if @terminal.quirks.per_code_point_columns?
    end

    # Sends the screen again without touching what is on it. Whatever scribbled
    # over the terminal, the buffer still knows what should be there, so the
    # scrolling log survives a redraw rather than starting over.
    private def force_repaint : Nil
      @terminal.paint!
    end
  end
end

TermBuf::Terminal.open do |terminal|
  Validate::Validator.new(terminal).run
end

puts "terminal restored"
