require "./style_table"

module TermBuf
  # One cell of the terminal grid.
  #
  # Sixteen bytes, fixed size, with no reference to anything on the heap, so a
  # `Grid` is one flat `Slice(Cell)` and a row is a `Slice` view into it.
  #
  # A wide character occupies two cells: the first carries the character with
  # `width` two, and the second is a continuation with `width` zero. Neither
  # half is ever written without the other; `Grid` enforces that.
  struct Cell
    # The cell's character, or `'\0'` when this cell continues a wide one.
    # When `cluster` is set, this is the cluster's first code point and the
    # full text lives in the pool.
    getter char : Char

    # `ClusterPool` id for a multi code point grapheme cluster, or
    # `ClusterPool::NONE` when `char` says everything.
    getter cluster : UInt32

    # Id into the buffer's `StyleTable`.
    getter style : StyleId

    # Cells this character occupies: zero for a continuation, one for a narrow
    # character, two for a wide one.
    getter width : UInt8

    def initialize(@char : Char,
                   @style : StyleId = StyleTable::DEFAULT,
                   @width : UInt8 = 1_u8,
                   @cluster : UInt32 = ClusterPool::NONE)
    end

    # An empty cell carrying *style*, which is what a cleared or scrolled-away
    # part of the screen holds.
    def self.blank(style : StyleId = StyleTable::DEFAULT) : Cell
      new ' ', style, 1_u8
    end

    # The second half of a wide character.
    def self.continuation(style : StyleId = StyleTable::DEFAULT) : Cell
      new '\0', style, 0_u8
    end

    # Whether this is the right half of a wide character.
    def continuation? : Bool
      @width.zero?
    end

    # Whether this is the left half of a wide character.
    def wide? : Bool
      @width == 2
    end

    # Whether the cell holds a space and nothing else, ignoring its style.
    def blank? : Bool
      @char == ' ' && @cluster == ClusterPool::NONE
    end

    # The text this cell paints, resolving a cluster id through *pool*. Falls
    # back to the base character if *pool* does not know the cluster, so that
    # rendering a grid against the wrong pool degrades rather than raising.
    def text(pool : ClusterPool) : String
      return "" if continuation?
      return @char.to_s if @cluster == ClusterPool::NONE

      pool[@cluster]? || @char.to_s
    end

    def to_s(io : IO) : Nil
      if continuation?
        io << "Cell(continuation)"
      else
        io << "Cell(" << @char.inspect << ", style=" << @style
        io << ", cluster=" << @cluster unless @cluster == ClusterPool::NONE
        io << ", wide" if wide?
        io << ')'
      end
    end
  end
end
