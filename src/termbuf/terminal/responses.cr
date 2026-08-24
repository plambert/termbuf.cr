module TermBuf
  # A reply the application is expecting from the terminal, described by what
  # it starts and ends with.
  #
  # This exists because a reply and a keystroke are not distinguishable by
  # looking at them. An arrow key sends `ESC [ A`; so could a terminal. The
  # only thing that separates them is that the application asked for one and
  # not the other, which is what registering a pattern records.
  struct ResponsePattern
    # What the reply begins with, such as `"\e[?"` for a mode report.
    getter prefix : String

    # What the reply ends with, such as `"$y"`.
    getter terminator : String

    def initialize(@prefix : String, @terminator : String)
      raise ArgumentError.new "a response pattern needs a prefix" if @prefix.empty?
      raise ArgumentError.new "a response pattern needs a terminator" if @terminator.empty?
    end

    # Whether *sequence* has this pattern's prefix and terminator.
    def matches?(sequence : String) : Bool
      return false if sequence.bytesize < @prefix.bytesize + @terminator.bytesize

      sequence.starts_with?(@prefix) && sequence.ends_with?(@terminator)
    end

    def to_s(io : IO) : Nil
      io << "ResponsePattern(" << @prefix.inspect << " … " << @terminator.inspect << ')'
    end
  end

  # The patterns an application is currently waiting on.
  #
  # Empty by default, which is the useful default: with nothing registered
  # every escape sequence arriving from the terminal is something the person
  # at the keyboard pressed.
  #
  # Guarded, because the reader runs on a thread of its own when the terminal
  # is a real device while registration happens wherever the application is.
  class ResponseRegistry
    @patterns : Array(ResponsePattern)

    def initialize
      @mutex = Mutex.new
      @patterns = [] of ResponsePattern
    end

    # Starts expecting *pattern*. Registering the same one twice is harmless.
    def register(pattern : ResponsePattern) : ResponsePattern
      @mutex.synchronize do
        @patterns = @patterns.dup << pattern unless @patterns.includes? pattern
      end

      pattern
    end

    # :ditto:
    def register(prefix : String, terminator : String) : ResponsePattern
      register ResponsePattern.new(prefix, terminator)
    end

    # Stops expecting *pattern*.
    def unregister(pattern : ResponsePattern) : Nil
      @mutex.synchronize { @patterns = @patterns.reject pattern }
    end

    # Stops expecting anything.
    def clear : Nil
      @mutex.synchronize { @patterns = [] of ResponsePattern }
    end

    # Whether *sequence* is one of the replies being waited for.
    def matches?(sequence : String) : Bool
      # Reading the array reference is one operation, and registration
      # replaces it rather than mutating it, so the reader never sees a
      # half-built list and never has to take the lock.
      patterns = @patterns
      return false if patterns.empty?

      patterns.any? &.matches?(sequence)
    end

    # Whether nothing is expected, in which case every sequence is input.
    def empty? : Bool
      @patterns.empty?
    end

    # How many patterns are registered.
    def size : Int32
      @patterns.size
    end
  end
end
