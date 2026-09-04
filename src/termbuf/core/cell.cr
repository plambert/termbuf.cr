require "./style_table"

module TermBuf
  # Stability: internal
  #
  # One cell of the terminal grid.
  #
  # Sixteen bytes, fixed size, with no reference to anything on the heap, so a
  # `Grid` is one flat `Slice(Cell)` and a row is a `Slice` view into it.
  #
  # A cluster wider than a column occupies several cells: the first carries the
  # character with `width` set to how many columns it takes, and the rest are
  # continuations with `width` zero. No part of one is ever written without the
  # others; `Grid` enforces that.
  struct Cell
    # The most columns one grapheme cluster may occupy: a lead and up to three
    # continuations.
    #
    # Two is what a cluster costs almost everywhere, and the buffer was built
    # for a pair. iTerm2 3.6.11 advances three for a Devanagari conjunct
    # carrying a spacing vowel sign, so a pair is not enough — see
    # `Unicode::WidthPolicy#conjunct_spacing_adds?`. Four leaves room above the
    # widest reading anyone has measured without letting a bad measurement run
    # away with a row.
    MAX_WIDTH = 4

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
    # character, and up to `MAX_WIDTH` for a cluster the terminal advances
    # further for.
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

    # A cell continuing the cluster to its left.
    def self.continuation(style : StyleId = StyleTable::DEFAULT) : Cell
      new '\0', style, 0_u8
    end

    # Whether this cell continues the cluster to its left.
    def continuation? : Bool
      @width.zero?
    end

    # Whether this cell leads a cluster taking more than its own column.
    def wide? : Bool
      @width > 1
    end

    # Whether this cell's glyph may paint outside the columns it was given.
    #
    # Measured rather than reasoned about. A cluster's ink runs past its own
    # columns often enough to matter: `ﷺ` is charged one column and painted
    # across three, an uncomposed `👨‍👩` is charged two and painted across four,
    # and neither terminal measured repaints the cell it draws over. Every case
    # seen was non-ASCII and no ASCII character in four runs painted outside
    # its cell, which is what keeps the repaint off ordinary text.
    def overhangs? : Bool
      continuation? || @cluster != ClusterPool::NONE || @char.ord > 0x7F
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
        io << ", width=" << @width if wide?
        io << ')'
      end
    end
  end
end
