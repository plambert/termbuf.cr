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

    # The interned hyperlinks a `Style` refers to by id.
    getter links : LinkTable

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
      @links = LinkTable.new
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

    # Interns a hyperlink and returns the id a `Style` carries it by.
    #
    #     style = Style::DEFAULT.linked buffer.link("https://example.com")
    #
    # See `Link` for what *id* groups.
    def link(uri : String, id : String? = nil) : LinkId
      @links.id uri, id
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
    #
    # With a *blend*, the style placed is what it answers for the cell rather
    # than *style* itself. See `#write`.
    def write_char(x : Int32, y : Int32, char : Char, style : Style = Style::DEFAULT,
                   blend : Blend? = nil) : Int32
      columns = Unicode.char_width char, @policy.ambiguous
      return 0 if columns.zero?

      style_id = @styles.id blend ? blended(blend, style, x, y) : style
      @back.place x, y, Cell.new(char, style_id, columns.to_u8), Cell.blank(style_id)
    end

    # Writes *text* starting at (*x*, *y*), one grapheme cluster per cell,
    # stopping at the right edge of the row. Returns the columns consumed.
    #
    # Zero width clusters are skipped: a combining mark with no base character
    # in front of it has nothing to attach to, and a control character is never
    # stored in the buffer.
    #
    # With a *blend*, each cell gets the style the blend answers for it from
    # what is already there and *style* — text over something already painted,
    # a label across a progress bar, without the caller working out where the
    # bar's colours change. `Style::KEEP_BACKGROUND` is that blend. A cluster
    # covering two cells takes the style its first half lands on.
    def write(x : Int32, y : Int32, text : String, style : Style = Style::DEFAULT,
              blend : Blend? = nil) : Int32
      return 0 unless @back.contains? x, y

      style_id = @styles.id style
      blank = Cell.blank style_id
      column = x

      Unicode.each_grapheme text, @policy do |grapheme|
        next if grapheme.width.zero?
        break if column >= @width

        if blend
          style_id = @styles.id blended(blend, style, column, y)
          blank = Cell.blank style_id
        end

        cell = build_cell grapheme, text, style_id
        consumed = @back.place column, y, cell, blank
        break if consumed.zero?

        column += consumed
      end

      column - x
    end

    # What *blend* answers for the cell at (*x*, *y*), which it is given along
    # with the style already there and *style*. Off the grid there is nothing
    # behind to blend with, so *style* stands as it is and the write is dropped
    # further down anyway.
    private def blended(blend : Blend, style : Style, x : Int32, y : Int32) : Style
      cell = @back[x, y]?
      return style unless cell

      blend.call @styles[cell.style], style, x, y
    end

    private def build_cell(grapheme : Unicode::Grapheme, source : String, style : StyleId) : Cell
      if char = grapheme.char
        Cell.new char, style, grapheme.width.to_u8
      else
        text = grapheme.text source
        Cell.new text[0], style, grapheme.width.to_u8, @clusters.id(text, @policy)
      end
    end

    # ------------------------------------------------------------- clearing

    # Sets every cell of *rect* to *char*.
    #
    # With a *blend*, each cell gets the style the blend answers for it rather
    # than *style*, which is what a wash over what is already painted wants: a
    # faded rectangle, or a tint that leaves the colours under it showing. The
    # rectangle is read before any of it is written, so a blend sees the cells
    # as they were rather than as this fill is leaving them.
    def fill(rect : Rect, char : Char = ' ', style : Style = Style::DEFAULT,
             blend : Blend? = nil) : Nil
      columns = Unicode.char_width char, @policy.ambiguous
      raise ArgumentError.new "cannot fill with a zero width character" if columns.zero?
      raise ArgumentError.new "cannot fill with a wide character" if columns == 2

      return fill_blended rect, char, style, blend if blend

      style_id = @styles.id style
      @back.fill rect, Cell.new(char, style_id, 1_u8)
    end

    # `#fill` a cell at a time, which is what a blend needs: the style differs
    # per cell, so there is no one cell to hand `Grid#fill`.
    private def fill_blended(rect : Rect, char : Char, style : Style, blend : Blend) : Nil
      area = rect.intersect bounds
      return if area.empty?

      area.each_row do |row_index|
        ids = Array(StyleId).new(area.width) do |offset|
          @styles.id blended(blend, style, area.x + offset, row_index)
        end

        ids.each_with_index do |style_id, offset|
          @back.place area.x + offset, row_index, Cell.new(char, style_id, 1_u8),
            Cell.blank(style_id)
        end
      end
    end

    # Blanks every cell.
    def clear(style : Style = Style::DEFAULT, blend : Blend? = nil) : Nil
      fill bounds, ' ', style, blend
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

    # Copies cells out of *source*, its top left landing at (*x*, *y*), taking
    # *from* of it or all of it. Whatever falls outside this buffer is cut.
    #
    # For compositing an off-screen panel: draw into a `Buffer` of its own
    # through a `BufferSurface`, then blit it into place. Styles and clusters
    # are interned per buffer, so the ids a source cell carries mean nothing
    # here and are translated on the way in. Stored widths are copied rather
    # than remeasured, so a panel keeps the layout it was drawn with even if
    # the two buffers measure clusters differently.
    #
    # A wide character with only one half inside the copied rectangle arrives
    # as a blank, since half of one cannot be drawn.
    def blit(source : Buffer, x : Int32, y : Int32, from : Rect? = nil) : Nil
      taken = (from || source.bounds).intersect source.bounds
      return if taken.empty?

      placed = Rect.new(x, y, taken.width, taken.height).intersect bounds
      return if placed.empty?

      # What the destination clipped off the left or top comes off the source
      # rectangle too, so the two stay aligned.
      taken = Rect.new taken.x + (placed.x - x), taken.y + (placed.y - y),
        placed.width, placed.height

      copy source, taken, placed
    end

    private def copy(source : Buffer, taken : Rect, placed : Rect) : Nil
      blank = Cell.blank @styles.id(Style::DEFAULT)
      @back.clip_wide placed, blank

      styles = {} of StyleId => StyleId
      clusters = {} of UInt32 => UInt32
      last = placed.width - 1

      placed.height.times do |row|
        placed.width.times do |column|
          cell = source.back[taken.x + column, taken.y + row]
          cell = if orphan? cell, column, last
                   blank
                 else
                   adopt cell, source, styles, clusters
                 end

          @back[placed.x + column, placed.y + row] = cell
        end
      end
    end

    # Whether only one half of a wide character was taken: a continuation at
    # the left edge lost its lead, and a lead at the right edge loses its
    # continuation.
    private def orphan?(cell : Cell, column : Int32, last : Int32) : Bool
      (column.zero? && cell.continuation?) || (column == last && cell.wide?)
    end

    # The same cell, with its style and cluster interned here instead. Both
    # maps are per-blit, so a panel of one style costs one lookup.
    private def adopt(cell : Cell, source : Buffer,
                      styles : Hash(StyleId, StyleId),
                      clusters : Hash(UInt32, UInt32)) : Cell
      style = styles[cell.style] ||= @styles.id source.styles[cell.style]

      cluster = cell.cluster
      unless cluster == ClusterPool::NONE
        cluster = clusters[cell.cluster] ||= @clusters.id source.clusters[cell.cluster], @policy
      end

      Cell.new cell.char, style, cell.width, cluster
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
