require "../terminal/event"
require "./scanner"

module TermBuf
  module Input
    # What an escape sequence begins with, which is the only part of it whose
    # meaning is fixed by the standards rather than by whoever wrote the
    # terminal.
    #
    # Everything after the introducer is private to the sequence, so a pattern
    # says which introducer it is interested in and matches the rest by hand.
    enum Prefix
      # `ESC [`, a control sequence.
      CSI

      # `ESC O`, the application keypad form.
      SS3

      # `ESC P`, a device control string.
      DCS

      # `ESC _`, an application programming command, which is where the kitty
      # graphics protocol lives.
      APC

      # `ESC ]`, an operating system command.
      OSC

      # `ESC ^`, a privacy message.
      PM

      # `ESC X`, a start of string.
      SOS

      # `ESC` and one more byte, which is everything else.
      Other

      # How many bytes the introducer takes, which is where the body starts.
      def introducer_size : Int32
        other? ? 1 : 2
      end

      # Whether the sequence runs to a string terminator rather than to a byte
      # in the final range, which is what decides whether `Sequence#final`
      # means anything.
      def string? : Bool
        in? DCS, APC, OSC, PM, SOS
      end

      # What introducer *byte* names, the byte after the escape.
      def self.from_introducer(byte : Char) : Prefix
        case byte
        when '[' then CSI
        when 'O' then SS3
        when 'P' then DCS
        when '_' then APC
        when ']' then OSC
        when '^' then PM
        when 'X' then SOS
        else          Other
        end
      end

      # Splits a written prefix such as `"\e[?"` into the introducer it names
      # and whatever it wants to see straight after it.
      #
      # This is what lets `Terminal#expect_response` keep taking a string: an
      # application that knows what a mode report looks like should not have to
      # know how this shard files it.
      def self.split(prefix : String) : {Prefix, String}
        raise ArgumentError.new "a response pattern needs a prefix" if prefix.empty?
        return {Other, prefix} unless prefix.starts_with? '\e'
        return {Other, ""} if prefix.size == 1

        kind = from_introducer prefix[1]
        kind.other? ? {kind, prefix[1..]} : {kind, prefix[2..]}
      end
    end

    # One complete escape sequence, taken apart far enough to be matched
    # against without every pattern having to parse it again.
    #
    # *bytes* is what arrived, introducer and terminator included, because that
    # is what an application handed a sequence it wants to interpret itself
    # needs. *body* is everything after the introducer, terminator included, so
    # that a pattern's head and tail are matched against the one string.
    record Sequence, bytes : Bytes, prefix : Prefix, body : String, final : Char? do
      # Takes *bytes* apart. Anything that does not begin with an escape and an
      # introducer is `Prefix::Other`, since nothing else can be said about it.
      def self.parse(bytes : Bytes) : Sequence
        kind = if bytes.size >= 2 && bytes[0] == SequenceScanner::ESC
                 Prefix.from_introducer bytes[1].unsafe_chr
               else
                 Prefix::Other
               end

        offset = {kind.introducer_size, bytes.size}.min
        Sequence.new bytes, kind, String.new(bytes[offset..]), final_byte(kind, bytes)
      end

      # The byte that ended the sequence, for the kinds that end with one. A
      # string sequence ends with `ST` or a bell, which names nothing.
      private def self.final_byte(kind : Prefix, bytes : Bytes) : Char?
        return if kind.string? || bytes.empty?

        last = bytes[-1]
        last < 0x80 ? last.unsafe_chr : nil
      end
    end

    # A sequence the application is interested in, and what to make of one.
    #
    # This exists because a reply and a keystroke are not distinguishable by
    # looking at them. An arrow key sends `ESC [ A`; so could a terminal. The
    # only thing that separates them is that the application asked for one and
    # not the other, which is what registering a pattern records.
    #
    # The handler returning `nil` means "not mine after all", so a pattern that
    # can only tell from the body whether it wants a sequence can let it carry
    # on to the next pattern and, failing that, to the key decoder.
    class Pattern
      # Which introducer this is about.
      getter prefix : Prefix

      # What has to come straight after the introducer, such as `"?"` for a
      # mode report or `"<"` for an SGR mouse report. Empty matches anything.
      getter head : String

      # What has to come at the end, such as `"$y"` or `"\e\\"`. `nil` matches
      # anything.
      getter terminator : String?

      def initialize(@prefix : Prefix, @head : String = "",
                     @terminator : String? = nil,
                     &@handler : Sequence -> Event?)
      end

      # Whether *sequence* has this pattern's shape, which is as far as the
      # bytes go; whether it is really this pattern's is up to the handler.
      def matches?(sequence : Sequence) : Bool
        return false unless sequence.prefix == @prefix

        body = sequence.body
        return false unless @head.empty? || body.starts_with? @head

        tail = @terminator
        return true unless tail

        # The two ends have to fit without overlapping, or a head and a
        # terminator that are the same string would both match the one copy.
        return false if body.bytesize < @head.bytesize + tail.bytesize

        body.ends_with? tail
      end

      # What this pattern makes of *sequence*, or `nil` if it turns out not to
      # want it.
      def call(sequence : Sequence) : Event?
        @handler.call sequence
      end

      def to_s(io : IO) : Nil
        io << "Pattern(" << @prefix << ' ' << @head.inspect << " … "
        io << (@terminator.try &.inspect || "*") << ')'
      end
    end

    # The sequences an application is currently interested in.
    #
    # Empty by default, which is the useful default: with nothing registered
    # every escape sequence arriving from the terminal is something the person
    # at the keyboard pressed.
    #
    # Guarded, because registration happens wherever the application is while
    # matching happens on the fibre that owns the decoder.
    class Patterns
      @patterns : Array(Pattern)

      def initialize
        @mutex = Mutex.new
        @patterns = [] of Pattern
      end

      # Starts watching for a sequence with this shape.
      def register(prefix : Prefix, head : String = "",
                   terminator : String? = nil,
                   &handler : Sequence -> Event?) : Pattern
        add Pattern.new(prefix, head, terminator, &handler)
      end

      # :ditto:
      def register(pattern : Pattern) : Pattern
        add pattern
      end

      # Stops watching for *pattern*.
      def unregister(pattern : Pattern) : Nil
        @mutex.synchronize { @patterns = @patterns.reject pattern }
      end

      # Stops watching for anything.
      def clear : Nil
        @mutex.synchronize { @patterns = [] of Pattern }
      end

      # What the first interested pattern makes of *sequence*, or `nil` when
      # none of them wanted it and it is therefore input.
      def match(sequence : Sequence) : Event?
        # Reading the array reference is one operation, and registration
        # replaces it rather than mutating it, so the matcher never sees a
        # half-built list and never has to take the lock.
        patterns = @patterns
        return if patterns.empty?

        patterns.each do |pattern|
          next unless pattern.matches? sequence

          event = pattern.call sequence
          return event if event
        end

        nil
      end

      # Whether nothing is registered, in which case every sequence is input.
      def empty? : Bool
        @patterns.empty?
      end

      # How many patterns are registered.
      def size : Int32
        @patterns.size
      end

      private def add(pattern : Pattern) : Pattern
        @mutex.synchronize do
          @patterns = @patterns.dup << pattern
        end

        pattern
      end
    end
  end
end
