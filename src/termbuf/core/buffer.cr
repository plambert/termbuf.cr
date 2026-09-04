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

    # Where this hint sits in the buffer's log of them. Sinks paint at
    # different times, so a hint cannot be handed over and forgotten: each
    # remembers the serial it read up to, and the log is trimmed to the oldest
    # of those.
    getter serial : Int64

    def initialize(@rect : Rect, @lines : Int32, @serial : Int64 = 0_i64)
    end

    def to_s(io : IO) : Nil
      io << "ScrollHint(" << @rect << ", " << @lines << ')'
    end
  end

  # The in-memory terminal screen.
  #
  # The buffer holds one grid: *back*, what the application has drawn. What a
  # terminal is believed to be showing lives in a `Sink`, one per output, along
  # with the painter and encoder that put it there. Attaching a second sink is
  # what lets the same buffer drive two displays that paint at different times
  # and know different things about what they can do.
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

    # Scrolls no attached sink has consumed yet, oldest first.
    getter scroll_hints : Array(ScrollHint)

    # The outputs painting this buffer.
    getter sinks : Array(Sink)

    # The serial given to the last scroll recorded. A sink that has read up to
    # this has nothing left to catch up on.
    getter scroll_serial : Int64 = 0_i64

    def initialize(@width : Int32, @height : Int32)
      @styles = StyleTable.new
      @clusters = ClusterPool.new
      @links = LinkTable.new
      @back = Grid.new @width, @height
      @regions = [] of Region
      @scroll_hints = [] of ScrollHint
      @sinks = [] of Sink
    end

    # ------------------------------------------------------------- sinks

    # Starts painting this buffer to *sink*. Called by `Sink` itself, so an
    # application builds a sink rather than attaching one.
    def attach(sink : Sink) : Nil
      return if @sinks.includes? sink

      @sinks << sink
      @back.watch sink.damage
    end

    # Stops painting this buffer to *sink*.
    def detach(sink : Sink) : Nil
      return unless @sinks.delete sink

      @back.unwatch sink.damage
      trim_scroll_hints
    end

    # The hints recorded after *serial*, oldest first.
    def scroll_hints_since(serial : Int64) : Array(ScrollHint)
      @scroll_hints.select { |hint| hint.serial > serial }
    end

    # Drops the damage and the hints every attached sink has painted. Called by
    # `Sink#commit`.
    protected def settled : Nil
      trim_scroll_hints
      @back.damage.clear if @sinks.all? &.painted?
    end

    # Forgets the hints no attached sink still has to read. With none attached
    # there is nobody left to read any of them.
    private def trim_scroll_hints : Nil
      oldest = @sinks.min_of?(&.consumed_serial) || @scroll_serial
      @scroll_hints.reject! { |hint| hint.serial <= oldest }
    end

    private def record_scroll(rect : Rect, lines : Int32) : Nil
      @scroll_serial += 1
      @scroll_hints << ScrollHint.new rect, lines, @scroll_serial
    end

    # The rectangle covering every cell.
    def bounds : Rect
      Rect.full @width, @height
    end

    # What no attached sink has painted yet. Each sink keeps its own record as
    # well, since they paint at different moments; this one is cleared once
    # every one of them has caught up.
    def damage : Damage
      @back.damage
    end

    # Whether anything is left for a sink to paint.
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
    # zero if it is zero width, if it is a control character, or if it takes
    # more columns than are left before the right edge.
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
    # covering several cells takes the style its first one lands on.
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
      raise ArgumentError.new "cannot fill with a wide character" if columns > 1

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
      record_scroll area, lines
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

      record_scroll area, lines
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
    # A cluster only partly inside the copied rectangle arrives as a blank,
    # since part of one cannot be drawn.
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

      placed.height.times do |row|
        placed.width.times do |column|
          cell = source.back[taken.x + column, taken.y + row]
          cell = if orphan? source.back, taken, taken.x + column, taken.y + row
                   blank
                 else
                   adopt cell, source, styles, clusters
                 end

          @back[placed.x + column, placed.y + row] = cell
        end
      end
    end

    # Whether the cell at (*x*, *y*) belongs to a cluster the rectangle *taken*
    # does not hold all of: a continuation whose lead was cut off the left, or
    # a lead whose continuations were cut off the right.
    private def orphan?(grid : Grid, taken : Rect, x : Int32, y : Int32) : Bool
      span = grid.extent x, y

      span.begin < taken.x || span.end > taken.right
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

    # Resizes the back grid and every attached sink, keeping whatever content
    # still fits anchored at the top left. Leaves everything dirty and drops
    # any scroll hints, since the next paint has to redraw the screen outright.
    def resize(width : Int32, height : Int32, style : Style = Style::DEFAULT) : Nil
      return if width == @width && height == @height

      blank = Cell.blank @styles.id(style)
      @back.resize width, height, blank
      @width = width
      @height = height
      @scroll_hints.clear
      @sinks.each &.resize(width, height, blank)
      invalidate
    end

    # Marks the whole screen dirty and has every sink forget what its terminal
    # was showing, so the next paint rewrites every cell.
    def invalidate : Nil
      @back.damage.touch_all @width
      @sinks.each &.invalidate
    end

    # The back grid as text, one line per row, for specs and debugging.
    def to_text : String
      @back.to_text @clusters
    end

    # ---------------------------------------------------------------- reading

    # What one cell holds, as `Buffer#hit` answers it.
    #
    # A hit always names the cluster's *lead*: ask about the right half of a
    # wide character and `x` comes back as the left half's column, with `lead`
    # false to say the question was not asked there. That is what a click on a
    # CJK glyph wants — the glyph, not the half of it under the pointer.
    record Hit,
      # The lead cell's column, which is not the column asked about when the
      # cell there continues a cluster.
      x : Int32,
      # The row, which is the row asked about.
      y : Int32,
      # Whether the position asked about was the lead itself.
      lead : Bool,
      # The lead cell.
      cell : Cell,
      # The cluster's text, `" "` for a blank cell.
      text : String

    # What sits at (*x*, *y*), or `nil` when that is off the grid.
    #
    # A continuation resolves to the cluster it belongs to, so the hit's `x`
    # can be to the left of the column asked about and `Hit#lead` says whether
    # it moved. Read from the back grid: what the application has drawn, which
    # is what it wants to reason about, rather than what the terminal is
    # believed to be showing.
    #
    #     hit = buffer.hit column, row
    #     puts hit.text if hit
    #
    # Coordinates are 0-based buffer cells. An SGR mouse report is 1-based and
    # carries its own columns; converting one is the mouse decoder's job, not
    # this method's. Turning a hit into an index within a line editor's text
    # belongs to whoever owns that text, which is the widget shard.
    def hit(x : Int32, y : Int32) : Hit?
      return unless @back.contains? x, y

      column = @back.lead_of x, y
      cell = @back[column, y]

      Hit.new column, y, column == x, cell, cell.text(@clusters)
    end
  end
end
