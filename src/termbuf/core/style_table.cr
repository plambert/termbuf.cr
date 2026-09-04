require "./style"

module TermBuf
  # Identifies an interned `Style`. Zero is always `Style::DEFAULT`.
  alias StyleId = UInt32

  # Stability: internal
  #
  # Interns styles so a `Cell` can carry a four byte id rather than the whole
  # struct.
  #
  # Two cells with equal styles always get the same id, which turns the paint
  # diff's style comparison into an integer compare and lets the encoder cache
  # one SGR byte string per id.
  #
  # The table only grows. An application cycling through distinct styles — an
  # animated colour gradient, say — accumulates entries at roughly 32 bytes
  # each; a hundred thousand of them costs a few megabytes. Real applications
  # use tens.
  class StyleTable
    # The id of `Style::DEFAULT`, which every table assigns first.
    DEFAULT = 0_u32

    @styles : Array(Style)
    @ids : Hash(Style, StyleId)

    def initialize
      @styles = [Style::DEFAULT]
      @ids = {Style::DEFAULT => DEFAULT}
    end

    # The id for *style*, assigning one if this is the first time it is seen.
    def id(style : Style) : StyleId
      @ids.fetch style do
        assigned = @styles.size.to_u32
        @styles << style
        @ids[style] = assigned
        assigned
      end
    end

    # The style *id* refers to.
    def [](id : StyleId) : Style
      @styles[id]
    end

    # The style *id* refers to, or `nil` if it was never assigned.
    def []?(id : StyleId) : Style?
      @styles[id]?
    end

    # Number of distinct styles interned so far.
    def size : Int32
      @styles.size
    end

    # Yields every interned style with its id, in the order they were added.
    def each(& : StyleId, Style ->) : Nil
      @styles.each_with_index { |style, index| yield index.to_u32, style }
    end
  end

  # Stability: internal
  #
  # Interns multi code point grapheme clusters so a `Cell` can carry a four
  # byte id rather than a string reference. Id zero means the cell's own
  # character says everything, which is the case for all but a handful of
  # cells in practice.
  class ClusterPool
    # The id meaning "no cluster; read the cell's character instead".
    NONE = 0_u32

    @texts : Array(String)
    @ids : Hash(String, UInt32)
    @columns : Array(Int32)

    def initialize
      @texts = [""]
      @ids = {"" => NONE}
      @columns = [0]
    end

    # The id for *text*, assigning one if this is the first time it is seen.
    #
    # *policy* settles how many columns a terminal counting per code point
    # would take for it, which is worked out here rather than at every paint;
    # see `#code_point_columns`.
    def id(text : String, policy : Unicode::WidthPolicy = Unicode.policy) : UInt32
      @ids.fetch text do
        assigned = @texts.size.to_u32
        @texts << text
        @columns << Unicode.code_point_columns text, policy
        @ids[text] = assigned
        assigned
      end
    end

    # Columns a terminal that counts them per code point rather than per
    # cluster would take for the cluster *id* refers to.
    #
    # Worked out once, when the cluster was interned, because the paint path
    # asks this of every composed cluster it writes and a terminal with
    # `Quirk::PerCodePointColumns` misplaces the ones where this differs from
    # the width the cell was given.
    def code_point_columns(id : UInt32) : Int32
      @columns[id]
    end

    # The cluster *id* refers to.
    def [](id : UInt32) : String
      @texts[id]
    end

    # The cluster *id* refers to, or `nil` for `NONE`.
    def []?(id : UInt32) : String?
      @texts[id]?
    end

    # How many clusters have been interned.
    def size : Int32
      @texts.size
    end
  end
end
