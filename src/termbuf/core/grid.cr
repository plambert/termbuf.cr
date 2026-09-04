require "./cell"
require "./damage"
require "./rect"

module TermBuf
  # Stability: internal
  #
  # A rectangular array of cells.
  #
  # Cells live in one flat slice, so a row is a contiguous `Slice` view and
  # scrolling is a run of `memmove`s. Alongside them the grid keeps a hash per
  # row, recomputed lazily, which is what lets the painter recognise a scrolled
  # band without comparing cells.
  #
  # The grid is the only place that knows a cluster can occupy more than one
  # cell, and it never lets those cells get out of step: writing to any of them
  # blanks all of them first.
  class Grid
    # Columns across.
    getter width : Int32

    # Rows down.
    getter height : Int32

    # Which rows have changed, and over what span.
    getter damage : Damage

    @cells : Slice(Cell)
    @hashes : Slice(UInt64)
    @hashed : Slice(Bool)
    @watchers : Array(Damage)

    def initialize(@width : Int32, @height : Int32, blank : Cell = Cell.blank)
      raise ArgumentError.new "grid width #{@width} is not positive" unless @width > 0
      raise ArgumentError.new "grid height #{@height} is not positive" unless @height > 0

      @cells = Slice(Cell).new @width * @height, blank
      @hashes = Slice(UInt64).new @height, 0_u64
      @hashed = Slice(Bool).new @height, false
      @damage = Damage.new @height
      @watchers = [] of Damage
    end

    # Starts marking *damage* alongside the grid's own on every write.
    #
    # One `Sink` is one watcher: each output painting this grid needs its own
    # record of what it has yet to draw, because they paint at different times
    # and one committing must not tell another its rows are clean. There are
    # one or two of these, so marking them is a loop over a short array rather
    # than anything cleverer.
    def watch(damage : Damage) : Nil
      return if @watchers.includes? damage

      @watchers << damage
    end

    # Stops marking *damage*.
    def unwatch(damage : Damage) : Nil
      @watchers.delete damage
    end

    # The cell at (*x*, *y*). Raises if it is off the grid.
    def [](x : Int32, y : Int32) : Cell
      @cells[y * @width + x]
    end

    # The cell at (*x*, *y*), or `nil` if it is off the grid.
    def []?(x : Int32, y : Int32) : Cell?
      return unless contains? x, y

      @cells[y * @width + x]
    end

    # Writes one cell without regard for wide character pairing. Callers that
    # place characters want `#place`; this is for filling, scrolling, and the
    # internals of `#place` itself.
    def []=(x : Int32, y : Int32, cell : Cell) : Nil
      return unless contains? x, y

      index = y * @width + x
      return if @cells[index] == cell

      @cells[index] = cell
      @hashed[y] = false
      @damage.touch x, y
      @watchers.each &.touch(x, y)
    end

    # Whether (*x*, *y*) is on the grid.
    def contains?(x : Int32, y : Int32) : Bool
      0 <= x < @width && 0 <= y < @height
    end

    # The rectangle covering every cell.
    def bounds : Rect
      Rect.full @width, @height
    end

    # The cells of row *y*, as a view into the grid's own storage.
    def row(y : Int32) : Slice(Cell)
      @cells[y * @width, @width]
    end

    # The cells of row *y* within *rect*'s columns.
    def row_span(rect : Rect, y : Int32) : Slice(Cell)
      @cells[y * @width + rect.x, rect.width]
    end

    # The column the cluster covering (*x*, *y*) begins at, which is *x* itself
    # unless that cell is a continuation. Off the grid, *x*.
    def lead_of(x : Int32, y : Int32) : Int32
      return x unless contains? x, y

      column = x
      while column > 0 && self[column, y].continuation?
        column -= 1
      end

      column
    end

    # The columns the cluster covering (*x*, *y*) occupies. A cell that leads
    # nothing covers itself alone, and so does a continuation at the left edge
    # with no lead left to walk to.
    def extent(x : Int32, y : Int32) : Range(Int32, Int32)
      lead = lead_of x, y
      span = Math.max self[lead, y].width.to_i, 1

      lead..(lead + span - 1)
    end

    # Places *cell* at (*x*, *y*), blanking every cell of any cluster it
    # displaces. Returns the columns consumed, or zero when the cluster will
    # not fit before the right edge and nothing was written.
    def place(x : Int32, y : Int32, cell : Cell, blank : Cell = Cell.blank) : Int32
      return 0 unless contains? x, y

      columns = cell.width.to_i
      return 0 if columns.zero?
      return 0 if x + columns > @width

      columns.times { |offset| detach x + offset, y, blank }

      self[x, y] = cell
      (1...columns).each { |offset| self[x + offset, y] = Cell.continuation cell.style }

      columns
    end

    # Blanks every cell of the cluster overlapping column *x*, if one covers
    # more than that column. A cell that leads nothing is left alone.
    #
    # Every cell of it takes *blank*, which for `#place` is the style being
    # written: a terminal erases what it displaces in whatever the current
    # style is, having no memory of what the cell used to be, and this follows
    # it. The rectangle operations want a different answer and use
    # `#clip_wide`.
    def detach(x : Int32, y : Int32, blank : Cell = Cell.blank) : Nil
      return unless contains? x, y

      span = extent x, y
      return if span.size == 1 && !self[x, y].continuation?

      span.each { |column| self[column, y] = blank }
    end

    # Sets every cell of *rect* to *cell*.
    def fill(rect : Rect, cell : Cell) : Nil
      area = rect.intersect bounds
      return if area.empty?

      # The part of a straddling cluster that lies *outside* the rectangle has
      # to be blanked, not filled: it is not part of what the caller asked to
      # paint.
      clip_wide area, Cell.blank(cell.style)

      area.each_row do |row_index|
        area.x.upto(area.right) { |column| self[column, row_index] = cell }
      end
    end

    # Sets every cell of the grid to *cell*.
    def clear(cell : Cell = Cell.blank) : Nil
      fill bounds, cell
    end

    # Moves the contents of *rect* by *lines* rows, positive scrolling up so
    # that content moves toward the top and blank rows appear at the bottom.
    #
    # Each row that leaves the rectangle is yielded before being overwritten.
    # The yielded slice is a view into the grid, valid only until the block
    # returns, so a consumer keeping the row must copy it.
    def scroll(rect : Rect, lines : Int32, blank : Cell = Cell.blank,
               & : Slice(Cell) ->) : Nil
      area = rect.intersect bounds
      return if lines.zero? || area.empty?

      clip_wide area, blank
      count = Math.min lines.abs, area.height

      if lines > 0
        count.times { |offset| yield row_span(area, area.y + offset) }
        (area.height - count).times do |offset|
          move_row area, area.y + offset + count, area.y + offset
        end
        count.times { |offset| fill_row area, area.bottom - offset, blank }
      else
        count.times { |offset| yield row_span(area, area.bottom - offset) }
        (area.height - count).times do |offset|
          move_row area, area.bottom - offset - count, area.bottom - offset
        end
        count.times { |offset| fill_row area, area.y + offset, blank }
      end
    end

    # Scrolls without inspecting the rows that leave.
    def scroll(rect : Rect, lines : Int32, blank : Cell = Cell.blank) : Nil
      scroll(rect, lines, blank) { }
    end

    # Blanks any cluster straddling the left or right edge of *rect*, so that
    # filling or scrolling the rectangle cannot tear one apart.
    #
    # The cells lying outside *rect* keep the style they had and lose only
    # their share of the glyph. A rectangle operation has no business changing
    # how a cell outside it looks, and giving those cells the incoming style
    # would paint the rectangle wider than it is — on the rows where a cluster
    # happens to straddle, and not on the others.
    def clip_wide(rect : Rect, blank : Cell = Cell.blank) : Nil
      return if rect.empty?

      rect.each_row do |row_index|
        clip_edge rect, row_index, rect.x, blank
        clip_edge rect, row_index, rect.right, blank
      end
    end

    # Blanks the cluster covering *column* when its extent leaves *rect*,
    # splitting the difference: the cells inside take *blank*, since the caller
    # is about to paint over them anyway, and the cells outside keep the style
    # the cluster had.
    #
    # A continuation carries its lead's style, so any cell of it answers for
    # all of them.
    private def clip_edge(rect : Rect, y : Int32, column : Int32, blank : Cell) : Nil
      span = extent column, y
      return if span.begin >= rect.x && span.end <= rect.right

      kept = Cell.blank self[span.begin, y].style

      span.each do |current|
        self[current, y] = rect.x <= current <= rect.right ? blank : kept
      end
    end

    # FNV-1a hash of row *y*, recomputed only when the row has been written to
    # since it was last asked for.
    def row_hash(y : Int32) : UInt64
      return @hashes[y] if @hashed[y]

      hash = FNV_OFFSET

      row(y).each do |cell|
        hash = mix hash, cell.char.ord.to_u32
        hash = mix hash, cell.cluster
        hash = mix hash, cell.style
        hash = mix hash, cell.width.to_u32
      end

      @hashes[y] = hash
      @hashed[y] = true
      hash
    end

    # Resizes the grid, keeping whatever content still fits anchored at the top
    # left and filling the rest with *blank*. Every cell is left marked dirty:
    # the terminal's own reflow is not something the buffer can predict, so the
    # next paint has to be a full one.
    def resize(width : Int32, height : Int32, blank : Cell = Cell.blank) : Nil
      raise ArgumentError.new "grid width #{width} is not positive" unless width > 0
      raise ArgumentError.new "grid height #{height} is not positive" unless height > 0
      return if width == @width && height == @height

      cells = Slice(Cell).new width * height, blank
      kept_width = Math.min width, @width
      kept_height = Math.min height, @height

      kept_height.times do |row_index|
        source = @cells[row_index * @width, kept_width]
        cells[row_index * width, kept_width].copy_from source
      end

      @cells = cells
      @width = width
      @height = height
      @hashes = Slice(UInt64).new height, 0_u64
      @hashed = Slice(Bool).new height, false
      @damage.resize height
      @watchers.each &.resize(height)

      # A cluster reaching past the new right edge lost continuations to the
      # narrower grid, so it has to go. Only the last `Cell::MAX_WIDTH - 1`
      # columns can hold such a lead; a continuation in any of them is fine,
      # since its lead is still to its left.
      first = Math.max width - Cell::MAX_WIDTH + 1, 0

      kept_height.times do |row_index|
        (first...width).each do |column|
          cell = self[column, row_index]
          detach column, row_index, blank if column + cell.width > width
        end
      end

      @damage.touch_all width
      @watchers.each &.touch_all(width)
    end

    # Replaces this grid's contents with *other*'s, which must be the same
    # size. Used to bring the front buffer up to date once a paint has been
    # written to the terminal.
    def copy_from(other : Grid) : Nil
      unless other.width == @width && other.height == @height
        raise ArgumentError.new "cannot copy a #{other.width}x#{other.height} grid " \
                                "into a #{@width}x#{@height} one"
      end

      @cells.copy_from other.cells
      @hashed.fill false
      @damage.clear
    end

    # Whether both grids hold the same cells. Damage is not compared: it says
    # what has yet to be painted, not what is on the screen.
    def ==(other : Grid) : Bool
      return false unless other.width == @width && other.height == @height

      @cells == other.cells
    end

    # Renders the grid as text, one line per row, for specs and debugging.
    # Continuation cells contribute nothing, so a wide character appears once.
    def to_text(pool : ClusterPool = ClusterPool.new) : String
      String.build do |io|
        @height.times do |row_index|
          @width.times do |column|
            cell = self[column, row_index]
            next if cell.continuation?

            io << cell.text(pool)
          end

          io << '\n' unless row_index == @height - 1
        end
      end
    end

    protected def cells : Slice(Cell)
      @cells
    end

    private def move_row(rect : Rect, from : Int32, to : Int32) : Nil
      row_span(rect, to).copy_from row_span(rect, from)
      @hashed[to] = false
      @damage.touch_span to, rect.x, rect.right
      @watchers.each &.touch_span(to, rect.x, rect.right)
    end

    private def fill_row(rect : Rect, y : Int32, blank : Cell) : Nil
      row_span(rect, y).fill blank
      @hashed[y] = false
      @damage.touch_span y, rect.x, rect.right
      @watchers.each &.touch_span(y, rect.x, rect.right)
    end

    FNV_OFFSET = 0xCBF29CE484222325_u64
    FNV_PRIME  =      0x100000001B3_u64

    private def mix(hash : UInt64, value : UInt32) : UInt64
      4.times do |shift|
        hash = (hash ^ ((value >> (shift * 8)) & 0xFF)) &* FNV_PRIME
      end

      hash
    end
  end
end
