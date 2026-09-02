module TermBuf
  # Identifies an interned `Link`. Zero always means no link.
  alias LinkId = UInt32

  # A hyperlink a range of cells carries, as OSC 8 describes one.
  #
  # *id* is the protocol's own grouping parameter, not this shard's. Two ranges
  # sharing one are the same link as far as the terminal is concerned, which is
  # what makes a link wrapped across two rows highlight as a whole rather than
  # as two. Leaving it off tells the terminal to group adjacent cells only.
  struct Link
    # Where the link points.
    getter uri : String

    # The grouping parameter, or `nil` to let the terminal group by adjacency.
    getter id : String?

    def initialize(@uri : String, @id : String? = nil)
      raise ArgumentError.new "a link needs a URI" if @uri.empty?
      raise ArgumentError.new "a link URI cannot contain a semicolon" if @uri.includes? ';'

      if id = @id
        raise ArgumentError.new "a link id cannot contain a semicolon" if id.includes? ';'
        raise ArgumentError.new "a link id cannot contain a colon" if id.includes? ':'
      end
    end

    # The parameter field of the OSC 8 sequence, empty when there is no id.
    def parameters : String
      id = @id
      id ? "id=#{id}" : ""
    end

    def to_s(io : IO) : Nil
      io << "Link(" << @uri
      @id.try { |id| io << " id=" << id }
      io << ')'
    end
  end

  # Interns links so a `Style` can carry a four byte id rather than a string.
  #
  # Guarded, because an application interns a link on whatever fibre it happens
  # to be drawing from while the encoder resolves ids on the one that owns the
  # buffer.
  class LinkTable
    # The id meaning no link, which every table reserves.
    NONE = 0_u32

    @links : Array(Link?)
    @ids : Hash(Link, LinkId)

    def initialize
      @mutex = Mutex.new
      @links = [nil.as(Link?)]
      @ids = {} of Link => LinkId
    end

    # The id for *link*, assigning one if this is the first time it is seen.
    def id(link : Link) : LinkId
      @mutex.synchronize do
        @ids.fetch link do
          assigned = @links.size.to_u32
          @links << link
          @ids[link] = assigned
          assigned
        end
      end
    end

    # :ditto:
    def id(uri : String, id : String? = nil) : LinkId
      self.id Link.new(uri, id)
    end

    # The link *id* refers to, or `nil` for `NONE` and for an id this table
    # never assigned.
    def []?(id : LinkId) : Link?
      @mutex.synchronize { @links[id]? }
    end

    # Number of distinct links interned so far, not counting `NONE`.
    def size : Int32
      @mutex.synchronize { @links.size - 1 }
    end

    # Whether no link has been interned.
    def empty? : Bool
      size.zero?
    end
  end
end
