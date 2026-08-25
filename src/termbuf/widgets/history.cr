module TermBuf
  # Lines entered earlier, and a walk back through them.
  #
  # Off by default and bounded when on. What separates this from an array is
  # the line being typed when the walk starts: it is put aside and restored on
  # the way back down, which is what people expect and what most
  # implementations forget.
  class History
    # How `#previous` chooses what to visit.
    enum Search
      # Every entry, newest first.
      Chronological

      # Only entries beginning with what had been typed when the walk started,
      # which is what a long history makes worth having.
      Prefix
    end

    # How many entries to keep. The oldest go first.
    getter capacity : Int32

    # Which entries `#previous` visits.
    property search : Search

    @entries : Array(String)

    # Where the walk has got to: zero is the line being typed, one is the most
    # recent entry.
    @position = 0

    # The line that was being typed when the walk started.
    @live = ""

    # What `Prefix` is matching, fixed when the walk starts so that recalling
    # an entry does not change what is being searched for.
    @prefix = ""

    def initialize(@capacity : Int32 = 100, @search : Search = Search::Chronological)
      raise ArgumentError.new "history capacity #{@capacity} is not positive" unless @capacity > 0

      @entries = [] of String
    end

    # Newest last, which is the order a history file is written in.
    def entries : Array(String)
      @entries.dup
    end

    # How many entries are held.
    def size : Int32
      @entries.size
    end

    # Whether nothing has been recorded.
    def empty? : Bool
      @entries.empty?
    end

    # Records *entry* and ends any walk in progress.
    #
    # A blank line is not worth recalling, and neither is a line identical to
    # the one before it: a history full of the same command is a history of one
    # command.
    def add(entry : String) : Nil
      reset
      return if entry.blank?
      return if @entries.last? == entry

      @entries << entry
      trim
    end

    # Steps back one entry, given the line currently being typed. Returns what
    # to put in its place, or `nil` when there is nowhere further back.
    def previous(current : String) : String?
      start current
      # Position counts back from the line being typed, so stepping back
      # through the entries counts up.
      step 1
    end

    # Steps forward one entry. Returns what to put in its place, which at the
    # end of the walk is the line that was being typed when it started.
    def next : String?
      return if @position.zero?

      step(-1)
    end

    # Abandons the walk, so the next `#previous` starts from the live line
    # again. Anything that edits the line should do this.
    def reset : Nil
      @position = 0
      @live = ""
      @prefix = ""
    end

    # Whether a walk is under way.
    def walking? : Bool
      @position > 0
    end

    # Forgets everything.
    def clear : Nil
      reset
      @entries.clear
    end

    # ------------------------------------------------------------ storage

    # Writes one entry per line. Where that goes, and whether it goes anywhere,
    # is the application's business: the shard does not decide where a history
    # file lives or what it is called.
    def save(io : IO) : Nil
      @entries.each { |entry| io.puts entry }
    end

    # Reads entries written by `#save`, appending to whatever is already here.
    def load(io : IO) : Nil
      io.each_line do |line|
        next if line.blank?

        @entries << line
      end

      trim
      reset
    end

    private def trim : Nil
      while @entries.size > @capacity
        @entries.shift
      end
    end

    # ------------------------------------------------------------ walking

    private def start(current : String) : Nil
      return if walking?

      @live = current
      @prefix = current
    end

    # Moves *direction* steps through the entries that match, and returns what
    # is there. Position counts back from the live line, so index into
    # `@entries` is from the end.
    private def step(direction : Int32) : String?
      position = @position

      loop do
        position += direction
        return if position < 0
        return @live.tap { @position = 0 } if position.zero?
        return if position > @entries.size

        entry = @entries[@entries.size - position]
        next unless matches? entry

        @position = position
        return entry
      end
    end

    private def matches?(entry : String) : Bool
      return true if @search.chronological?
      return true if @prefix.empty?

      entry.starts_with? @prefix
    end
  end
end
