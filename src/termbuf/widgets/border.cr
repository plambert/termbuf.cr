require "../core/rect"
require "../core/style"
require "../terminal/command"

module TermBuf
  # A box drawn around something, with an optional title in its top edge.
  #
  # It lives at the widget layer root rather than inside `Field` because
  # anything else drawn in a box wants the same thing.
  struct Border
    # The eight glyphs a box is made of.
    record Glyphs,
      top_left : Char, top : Char, top_right : Char,
      left : Char, right : Char,
      bottom_left : Char, bottom : Char, bottom_right : Char

    PLAIN   = Glyphs.new '┌', '─', '┐', '│', '│', '└', '─', '┘'
    ROUNDED = Glyphs.new '╭', '─', '╮', '│', '│', '╰', '─', '╯'
    HEAVY   = Glyphs.new '┏', '━', '┓', '┃', '┃', '┗', '━', '┛'
    DOUBLE  = Glyphs.new '╔', '═', '╗', '║', '║', '╚', '═', '╝'

    # For a terminal whose font has no box drawing, and for a screen someone
    # is going to copy out of.
    ASCII = Glyphs.new '+', '-', '+', '|', '|', '+', '-', '+'

    # Which characters the box is drawn with.
    getter glyphs : Glyphs

    # What the box itself is drawn in.
    getter style : Style

    # Shown in the top edge, trimmed to fit. `nil` for none.
    getter title : String?

    # What the title is drawn in, which is often not what the box is.
    getter title_style : Style

    def initialize(@glyphs : Glyphs = PLAIN,
                   @style : Style = Style::DEFAULT,
                   @title : String? = nil,
                   @title_style : Style = Style::DEFAULT)
    end

    {% for name in %w[plain rounded heavy double ascii] %}
      # A {{ name.id }} border.
      def self.{{ name.id }}(style : Style = Style::DEFAULT, title : String? = nil,
                             title_style : Style = Style::DEFAULT) : Border
        new {{ name.upcase.id }}, style, title, title_style
      end
    {% end %}

    # A copy carrying a different title.
    def with_title(title : String?) : Border
      Border.new @glyphs, @style, title, @title_style
    end

    # The area inside the box. Empty when *rect* has no room for one.
    def self.inset(rect : Rect) : Rect
      return Rect.new rect.x, rect.y, 0, 0 if rect.width < 3 || rect.height < 3

      Rect.new rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2
    end

    # :ditto:
    def inset(rect : Rect) : Rect
      Border.inset rect
    end

    # Rows and columns a border adds to whatever it surrounds.
    PADDING = 2

    # Draws the box around the edge of *rect*.
    #
    # The last cell written is the bottom right corner, which on a terminal
    # that scrolls rather than holding the wrap would take the top edge with
    # it. The painter turns wrapping off for the duration of a frame, so it
    # does not.
    def draw(screen : Drawing, rect : Rect) : Nil
      return if rect.width < 2 || rect.height < 2

      right = rect.right
      bottom = rect.bottom

      screen.write rect.x + 1, rect.y, @glyphs.top.to_s * (rect.width - 2), @style
      screen.write rect.x + 1, bottom, @glyphs.bottom.to_s * (rect.width - 2), @style

      (rect.y + 1...bottom).each do |row|
        screen.write_char rect.x, row, @glyphs.left, @style
        screen.write_char right, row, @glyphs.right, @style
      end

      screen.write_char rect.x, rect.y, @glyphs.top_left, @style
      screen.write_char right, rect.y, @glyphs.top_right, @style
      screen.write_char rect.x, bottom, @glyphs.bottom_left, @style
      screen.write_char right, bottom, @glyphs.bottom_right, @style

      draw_title screen, rect
    end

    private def draw_title(screen : Drawing, rect : Rect) : Nil
      title = @title
      return unless title && rect.width > 4

      room = rect.width - 4
      shown = Unicode.string_width(title) > room ? trim(title, room) : title
      return if shown.empty?

      screen.write rect.x + 2, rect.y, shown, @title_style
    end

    # Cut to *room* cells, which for a cluster that would straddle the end
    # means leaving it out rather than splitting it.
    private def trim(text : String, room : Int32) : String
      String.build do |io|
        used = 0

        Unicode.each_grapheme text do |grapheme|
          break if used + grapheme.width > room

          io << grapheme.text(text)
          used += grapheme.width
        end
      end
    end
  end
end
