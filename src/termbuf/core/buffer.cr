require "../unicode/grapheme"
require "./grid"
require "./region"
require "./style_table"

module TermBuf
  # A scroll the buffer performed on itself, recorded so the painter can reach
  # for the terminal's own scrolling instead of rediscovering the shift from
  # row hashes. The painter still verifies a hint against those hashes before
  # trusting it.
  struct ScrollHint
    # The rows that moved.
    getter rect : Rect

    # Rows scrolled, positive meaning content moved up.
    getter lines : Int32

    def initialize(@rect : Rect, @lines : Int32)
    end

    def to_s(io : IO) : Nil
      io << "ScrollHint(" << @rect << ", " << @lines << ')'
    end
  end

  # The in-memory terminal screen.
  #
  # Two grids: *back* is what the application has drawn, *front* is what the
  # terminal is believed to be showing. Every write lands in the back grid and
  # marks damage; a paint diffs the two, and `#commit_paint` brings the front
  # grid up to date once the bytes have gone out.
  #
  # A single dirty-flag scheme would be smaller, but it leaves nothing to diff
  # against after a forced repaint or a resize, and nothing for the scroll
  # detector to verify a shift against.
  #
  # Not fibre-safe, and deliberately so: one fibre owns the buffer and every
  # mutation reaches it as a command.
  class Buffer
    # Columns across.
    getter width : Int32

    # Rows down.
    getter height : Int32

    # What the application has drawn.
    getter back : Grid

    # What the terminal is believed to be showing.
    getter front : Grid

    # The interned styles both grids refer to by id.
    getter styles : StyleTable

    # The interned multi code point clusters, for cells a `Char` cannot hold.
    getter clusters : ClusterPool

    # Regions declared with `#region`, in the order they were made.
    getter regions : Array(Region)

    # How clusters are measured. Set by the driver from what the terminal said
    # when it was asked, because how many cells an emoji takes is a question
    # about the terminal rather than about Unicode. See `Unicode::WidthPolicy`.
    #
    # Changing it does not remeasure what is already written: cells carry the
    # width they were placed with. Invalidate and redraw after changing it.
    property policy : Unicode::WidthPolicy = Unicode::WidthPolicy::DEFAULT

    # Scrolls performed since the last paint, oldest first.
    getter scroll_hints : Array(ScrollHint)

    def initialize(@width : Int32, @height : Int32)
      @styles = StyleTable.new
      @clusters = ClusterPool.new
      @back = Grid.new @width, @height
      @front = Grid.new @width, @height
      @regions = [] of Region
      @scroll_hints = [] of ScrollHint
    end

    # The rectangle covering every cell.
    def bounds : Rect
      Rect.full @width, @height
    end

    # What has changed since the last paint.
    def damage : Damage
      @back.damage
    end

    # Whether anything has changed since the last paint.
    def dirty? : Bool
      @back.damage.dirty? || !@scroll_hints.empty?
    end

    # Registers a region. Regions are for scrolling and scrollback; they do not
    # clip writes, and the buffer does not stop them overlapping.
    def region(x : Int32, y : Int32, width : Int32, height : Int32,
               scrollback : Int32 = 0) : Region
      created = Region.new Rect.new(x, y, width, height), scrollback
      @regions << created
      created
    end

    # Declares a region over *bounds*, keeping up to *scrollback* rows of what
    # scrolls off the top.
    def region(bounds : Rect, scrollback : Int32 = 0) : Region
      created = Region.new bounds, scrollback
      @regions << created
      created
    end

    # ------------------------------------------------------------- writing

    # Writes a single character at (*x*, *y*). Returns the columns it consumed:
    # zero if it is zero width, if it is a control character, or if it is wide
    # and the right edge is one column away.
    def write_char(x : Int32, y : Int32, char : Char, style : Style = Style::DEFAULT) : Int32
      columns = Unicode.char_width char, @policy.ambiguous
      return 0 if columns.zero?

      style_id = @styles.id style
      @back.place x, y, Cell.new(char, style_id, columns.to_u8), Cell.blank(style_id)
    end

    # Writes *text* starting at (*x*, *y*), one grapheme cluster per cell,
    # stopping at the right edge of the row. Returns the columns consumed.
    #
    # Zero width clusters are skipped: a combining mark with no base character
    # in front of it has nothing to attach to, and a control character is never
    # stored in the buffer.
    def write(x : Int32, y : Int32, text : String, style : Style = Style::DEFAULT) : Int32
      return 0 unless @back.contains? x, y

      style_id = @styles.id style
      blank = Cell.blank style_id
      column = x

      Unicode.each_grapheme text, @policy do |grapheme|
        next if grapheme.width.zero?
        break if column >= @width

        cell = build_cell grapheme, text, style_id
        consumed = @back.place column, y, cell, blank
        break if consumed.zero?

        column += consumed
      end

      column - x
    end

    private def build_cell(grapheme : Unicode::Grapheme, source : String, style : StyleId) : Cell
      if char = grapheme.char
        Cell.new char, style, grapheme.width.to_u8
      else
        text = grapheme.text source
        Cell.new text[0], style, grapheme.width.to_u8, @clusters.id(text)
      end
    end

    # ------------------------------------------------------------- clearing

    # Sets every cell of *rect* to *char*.
    def fill(rect : Rect, char : Char = ' ', style : Style = Style::DEFAULT) : Nil
      columns = Unicode.char_width char, @policy.ambiguous
      raise ArgumentError.new "cannot fill with a zero width character" if columns.zero?
      raise ArgumentError.new "cannot fill with a wide character" if columns == 2

      style_id = @styles.id style
      @back.fill rect, Cell.new(char, style_id, 1_u8)
    end

    # Blanks every cell.
    def clear(style : Style = Style::DEFAULT) : Nil
      fill bounds, ' ', style
    end

    # ------------------------------------------------------------ scrolling

    # Scrolls *rect* by *lines* rows, positive moving content up. Records a
    # hint for the painter.
    def scroll(rect : Rect, lines : Int32, style : Style = Style::DEFAULT) : Nil
      return if lines.zero?

      area = rect.intersect bounds
      return if area.empty?

      @back.scroll area, lines, Cell.blank(@styles.id style)
      @scroll_hints << ScrollHint.new area, lines
    end

    # Scrolls a region, keeping the rows that leave the top if the region has
    # scrollback capacity.
    def scroll_region(region : Region, lines : Int32, style : Style = Style::DEFAULT) : Nil
      return if lines.zero?

      area = region.bounds.intersect bounds
      return if area.empty?

      blank = Cell.blank @styles.id(style)

      if lines > 0
        @back.scroll(area, lines, blank) { |row| region.push_scrollback row }
      else
        @back.scroll area, lines, blank
      end

      @scroll_hints << ScrollHint.new area, lines
    end

    # ------------------------------------------------------------- lifecycle

    # Resizes both grids, keeping whatever content still fits anchored at the
    # top left. Leaves everything dirty and drops any scroll hints, since the
    # next paint has to redraw the screen outright.
    def resize(width : Int32, height : Int32, style : Style = Style::DEFAULT) : Nil
      return if width == @width && height == @height

      blank = Cell.blank @styles.id(style)
      @back.resize width, height, blank
      @front.resize width, height, blank
      @width = width
      @height = height
      @scroll_hints.clear
      invalidate
    end

    # Marks the whole screen dirty and forgets what the terminal was showing,
    # so the next paint rewrites every cell.
    def invalidate : Nil
      @front.clear Cell.new('￿', StyleTable::DEFAULT, 1_u8)
      @front.damage.clear
      @back.damage.touch_all @width
    end

    # Brings the front grid up to date after a paint has been written out, and
    # clears the damage and scroll hints it was built from.
    def commit_paint : Nil
      @front.copy_from @back
      @back.damage.clear
      @scroll_hints.clear
    end

    # Takes the scroll hints recorded since the last paint, leaving none
    # behind.
    def take_scroll_hints : Array(ScrollHint)
      taken = @scroll_hints
      @scroll_hints = [] of ScrollHint
      taken
    end

    # Whether the two grids agree, which is to say a paint would emit nothing.
    def painted? : Bool
      @back == @front
    end

    # The back grid as text, one line per row, for specs and debugging.
    def to_text : String
      @back.to_text @clusters
    end
  end
end
