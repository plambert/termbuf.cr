require "../unicode/grapheme"
require "./response_scanner"

module TermBuf
  # Asks the terminal how wide it thinks a grapheme cluster is.
  #
  # Every sample goes out followed by a cursor position report, and the column
  # that comes back is the terminal's own measurement. One batch, one round
  # trip, and the screen is cleared afterwards.
  #
  # This cannot run with the capability probe. That one happens before the
  # alternate screen is entered, and writing emoji onto the screen the person
  # was looking at would scribble on their shell.
  class WidthProbe
    # Long enough for a terminal on the far end of a slow link, short enough
    # not to be noticed when nothing answers.
    DEFAULT_TIMEOUT = 250.milliseconds

    # One thing to measure, and the rule it settles.
    #
    # Chosen to discriminate rather than to enumerate: there is no point asking
    # about a hundred emoji when every terminal treats them by rule.
    record Sample,
      # What to print.
      text : String,
      # The rule this sample settles, by the name `WidthPolicy` uses, or `nil`
      # for one that only confirms the terminal is answering sensibly.
      rule : String?,
      # What the rule being on predicts, and what being off predicts.
      enabled : Int32,
      disabled : Int32,
      # For diagnostics.
      description : String

    SAMPLES = [
      Sample.new("a", nil, 1, 1, "latin small a"),
      Sample.new("漢", nil, 2, 2, "east asian wide"),
      Sample.new("→", "ambiguous_wide", 2, 1, "east asian ambiguous"),
      Sample.new("☺️", "emoji_presentation", 2, 1, "text pictograph with VS16"),
      Sample.new("👨‍👩‍👧‍👦", "joined_emoji", 2, 8, "four faces joined by ZWJ"),
      Sample.new("🇺🇸", "regional_indicators", 2, 4, "regional indicator pair"),
      Sample.new("நி", "spacing_marks", 2, 1, "tamil na with a spacing vowel sign"),
    ]

    # What one sample turned into.
    record Reading,
      sample : Sample,
      # Columns the terminal advanced, or `nil` if it did not answer.
      measured : Int32?

    # Everything the probe learned.
    record Result,
      policy : Unicode::WidthPolicy,
      readings : Array(Reading),
      # Keystrokes that arrived while the probe was running.
      input : Bytes,
      # Whether the terminal answered at all. When it did not, *policy* is
      # whatever was passed in.
      answered : Bool do
      # Samples the resulting policy still measures differently from the
      # terminal. Terminals reach conclusions this design has no flag for, and
      # naming what is left over beats modelling it wrong.
      def disagreements : Array(Reading)
        readings.select do |reading|
          measured = reading.measured
          next false unless measured

          Unicode.string_width(reading.sample.text, policy) != measured
        end
      end
    end

    # How long to wait for the last answer before giving up on the batch.
    getter timeout : Time::Span

    def initialize(@input : IO, @output : IO, @timeout : Time::Span = DEFAULT_TIMEOUT)
      @scanner = ResponseScanner.new
    end

    CURSOR_POSITION = /\A\e\[(\d+);(\d+)R\z/

    # Measures every sample and folds the answers into *base*.
    def probe(base : Unicode::WidthPolicy = Unicode::WidthPolicy::DEFAULT) : Result
      send
      columns, keystrokes = collect

      readings = SAMPLES.map_with_index { |sample, index| Reading.new sample, columns[index]? }
      answered = readings.any? &.measured

      Result.new infer(base, readings), readings, keystrokes, answered
    end

    # Each sample starts at the left margin of its own row, so a sample the
    # terminal measures generously cannot push the next one off the edge and
    # confuse the reading after it.
    private def send : Nil
      SAMPLES.each_with_index do |sample, index|
        @output << "\e[" << index + 1 << ";1H" << sample.text << "\e[6n"
      end

      @output.flush
    end

    # Reads until every sample has answered or the deadline passes. Anything
    # that is not a cursor position report is a keystroke, and is handed back
    # rather than dropped.
    private def collect : {Array(Int32), Bytes}
      columns = [] of Int32
      keystrokes = IO::Memory.new
      deadline = Time.instant + @timeout
      buffer = Bytes.new 4096

      until columns.size >= SAMPLES.size || Time.instant >= deadline
        count = read buffer, deadline
        break if count.nil?

        @scanner.feed buffer[0, count] do |kind, bytes|
          reply = kind.sequence? ? String.new(bytes).match(CURSOR_POSITION) : nil
          reply ? columns << reply[2].to_i - 1 : keystrokes.write(bytes)
        end
      end

      {columns, keystrokes.to_slice}
    end

    private def read(buffer : Bytes, deadline : Time::Instant) : Int32?
      apply_timeout deadline

      count = @input.read buffer
      count.zero? ? nil : count
    rescue IO::Error
      nil
    end

    private def apply_timeout(deadline : Time::Instant) : Nil
      input = @input
      return unless input.responds_to? :read_timeout=

      remaining = deadline - Time.instant
      input.read_timeout = remaining > Time::Span.zero ? remaining : 1.millisecond
    end

    # Sets each rule from the sample that discriminates it, and leaves alone
    # any rule whose sample went unanswered or came back as neither answer.
    private def infer(base : Unicode::WidthPolicy, readings : Array(Reading)) : Unicode::WidthPolicy
      readings.reduce base do |policy, reading|
        rule = reading.sample.rule
        measured = reading.measured
        next policy unless rule && measured

        case measured
        when reading.sample.enabled  then policy.with rule, true
        when reading.sample.disabled then policy.with rule, false
        else                              policy
        end
      end
    end

    # Puts back whatever read deadline the stream had, and clears the samples
    # off the screen.
    def self.run(input : IO, output : IO,
                 base : Unicode::WidthPolicy = Unicode::WidthPolicy::DEFAULT,
                 timeout : Time::Span = DEFAULT_TIMEOUT) : Result
      previous = input.responds_to?(:read_timeout) ? input.read_timeout : nil

      begin
        new(input, output, timeout).probe base
      ensure
        input.read_timeout = previous if input.responds_to? :read_timeout=
        output << "\e[H\e[2J"
        output.flush
      end
    end
  end
end
