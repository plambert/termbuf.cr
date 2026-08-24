module TermBuf
  # Which cells have changed since the last paint, tracked as one column span
  # per row.
  #
  # A span rather than a per-cell bitmap because the paint loop walks rows
  # anyway, and rather than a whole-row flag because a status line that changes
  # three characters should not cost a full row of output. The row count lets
  # `#any?` answer without scanning, so a paint with nothing to do is free.
  class Damage
    # How many rows are tracked.
    getter height : Int32

    # Number of rows carrying a span.
    getter rows : Int32 = 0

    @min : Slice(Int32)
    @max : Slice(Int32)

    def initialize(@height : Int32)
      @min = Slice(Int32).new @height, Int32::MAX
      @max = Slice(Int32).new @height, -1
    end

    # Records that the cell at (*x*, *y*) changed.
    def touch(x : Int32, y : Int32) : Nil
      return unless 0 <= y < @height

      if @max[y] < @min[y]
        @rows += 1
        @min[y] = x
        @max[y] = x
        return
      end

      @min[y] = x if x < @min[y]
      @max[y] = x if x > @max[y]
    end

    # Records that columns *from* through *to* of row *y* changed.
    def touch_span(y : Int32, from : Int32, to : Int32) : Nil
      return unless 0 <= y < @height
      return if to < from

      if @max[y] < @min[y]
        @rows += 1
        @min[y] = from
        @max[y] = to
        return
      end

      @min[y] = from if from < @min[y]
      @max[y] = to if to > @max[y]
    end

    # The changed columns of row *y*, or `nil` when the row is clean.
    def span(y : Int32) : Range(Int32, Int32)?
      return unless 0 <= y < @height
      return if @max[y] < @min[y]

      @min[y]..@max[y]
    end

    # Whether row *y* has changed.
    def dirty?(y : Int32) : Bool
      0 <= y < @height && @min[y] <= @max[y]
    end

    # Whether anything at all has changed.
    def dirty? : Bool
      @rows > 0
    end

    # Yields each dirty row and its changed columns, top to bottom.
    def each(& : Int32, Range(Int32, Int32) ->) : Nil
      return unless dirty?

      @height.times do |row|
        next if @max[row] < @min[row]

        yield row, @min[row]..@max[row]
      end
    end

    # Marks every row clean.
    def clear : Nil
      return unless dirty?

      @min.fill Int32::MAX
      @max.fill -1
      @rows = 0
    end

    # Marks every cell of every row as changed.
    def touch_all(width : Int32) : Nil
      return if width <= 0

      @min.fill 0
      @max.fill width - 1
      @rows = @height
    end

    # Resizes to *height* rows, discarding any spans: a resize forces a full
    # repaint, so there is nothing worth carrying over.
    def resize(height : Int32) : Nil
      @height = height
      @min = Slice(Int32).new height, Int32::MAX
      @max = Slice(Int32).new height, -1
      @rows = 0
    end
  end
end
