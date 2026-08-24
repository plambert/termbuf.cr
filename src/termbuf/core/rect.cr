module TermBuf
  # A rectangle of cells, in buffer coordinates with the origin at the top
  # left. Widths and heights are never negative; a zero in either makes the
  # rectangle empty.
  struct Rect
    # Column of the left edge.
    getter x : Int32

    # Row of the top edge.
    getter y : Int32

    # Columns across.
    getter width : Int32

    # Rows down.
    getter height : Int32

    def initialize(@x : Int32, @y : Int32, @width : Int32, @height : Int32)
      raise ArgumentError.new "rectangle width #{@width} is negative" if @width < 0
      raise ArgumentError.new "rectangle height #{@height} is negative" if @height < 0
    end

    # The rectangle covering a whole *width* by *height* grid.
    def self.full(width : Int32, height : Int32) : Rect
      new 0, 0, width, height
    end

    # Column of the rightmost cell. Meaningless for an empty rectangle.
    def right : Int32
      @x + @width - 1
    end

    # Row of the bottom cell. Meaningless for an empty rectangle.
    def bottom : Int32
      @y + @height - 1
    end

    # Whether the rectangle covers no cells.
    def empty? : Bool
      @width.zero? || @height.zero?
    end

    # Whether (*x*, *y*) falls inside.
    def contains?(x : Int32, y : Int32) : Bool
      @x <= x < @x + @width && @y <= y < @y + @height
    end

    # Whether *other* falls entirely inside. An empty rectangle is contained
    # by anything.
    def contains?(other : Rect) : Bool
      return true if other.empty?
      return false if empty?

      @x <= other.x && @y <= other.y && other.right <= right && other.bottom <= bottom
    end

    # The overlap of two rectangles, empty when they do not meet.
    def intersect(other : Rect) : Rect
      left = Math.max @x, other.x
      top = Math.max @y, other.y
      new_right = Math.min @x + @width, other.x + other.width
      new_bottom = Math.min @y + @height, other.y + other.height

      return Rect.new left, top, 0, 0 if new_right <= left || new_bottom <= top

      Rect.new left, top, new_right - left, new_bottom - top
    end

    # Yields each row index from the top edge down.
    def each_row(& : Int32 ->) : Nil
      return if empty?

      @y.upto(bottom) { |row| yield row }
    end

    def to_s(io : IO) : Nil
      io << "Rect(" << @x << ", " << @y << ", " << @width << 'x' << @height << ')'
    end
  end
end
