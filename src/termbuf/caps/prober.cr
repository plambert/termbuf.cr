require "base64"

require "./capability"
require "./environment"
require "./response_scanner"

module TermBuf
  # Asks the terminal what it can do, rather than guessing from its name.
  #
  # Every query goes out in one batch, and the last of them is a cursor
  # position report. Every terminal answers that one, so its reply is the
  # signal that everything else which was going to answer already has. The
  # common case therefore costs one round trip rather than the full timeout,
  # and the timeout is only a backstop for a terminal that answers nothing.
  #
  # Bytes arriving during the probe window that are not replies are keystrokes.
  # They are handed back rather than dropped, so a key pressed while the
  # application was starting still reaches it.
  class Prober
    # Long enough for a terminal on the far end of a slow link, short enough
    # not to be noticed when nothing answers.
    DEFAULT_TIMEOUT = 250.milliseconds

    record Result,
      capabilities : Capabilities,
      # Keystrokes that arrived during the probe window.
      input : Bytes,
      # Which queries came back, for diagnostics.
      answered : Array(Symbol),
      # What the terminal called itself, if it said.
      name : String?,
      # Where the cursor was, which the sentinel reports for free.
      cursor : {Int32, Int32}?

    getter timeout : Time::Span

    def initialize(@input : IO, @output : IO, @timeout : Time::Span = DEFAULT_TIMEOUT)
      @scanner = ResponseScanner.new
    end

    # A one pixel RGB image, asked about rather than displayed.
    KITTY_GRAPHICS_QUERY = "\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\"

    # `Tc` and `RGB` are the terminfo capabilities that mean 24 bit colour;
    # asking for them by hex name is how XTGETTCAP works.
    TCAP_QUERY = "\eP+q5463;524742\e\\"

    QUERIES = String.build do |io|
      io << "\e[c"       # primary device attributes
      io << "\e[>c"      # secondary device attributes
      io << "\e[>0q"     # XTVERSION, the terminal's own name
      io << TCAP_QUERY   # 24 bit colour, asked of terminfo
      io << "\e[?2026$p" # synchronized output
      io << "\e[?u"      # kitty keyboard protocol
      io << KITTY_GRAPHICS_QUERY
      io << "\e[6n" # cursor position: the sentinel, always answered
    end

    # Sends the queries and folds whatever comes back into *base*.
    def probe(base : Capabilities) : Result
      @output << QUERIES
      @output.flush

      flags = base.flags
      answered = [] of Symbol
      input = IO::Memory.new
      name = nil.as(String?)
      cursor = nil.as({Int32, Int32}?)

      collect do |kind, bytes|
        if kind.input?
          input.write bytes
          next false
        end

        reading = interpret String.new(bytes), flags
        flags = reading.flags

        if query = reading.query
          answered << query
        end
        name ||= reading.name
        cursor ||= reading.cursor
        reading.query == :cursor_position
      end

      Result.new Capabilities.new(flags), input.to_slice, answered, name, cursor
    end

    # Reads until the block reports the sentinel has arrived, or the deadline
    # passes. Whatever is still half-arrived at that point is treated as input.
    private def collect(& : ResponseScanner::Kind, Bytes -> Bool) : Nil
      deadline = Time.instant + @timeout
      buffer = Bytes.new 4096
      done = false

      until done || Time.instant >= deadline
        count = read_some buffer, deadline
        break if count.nil?
        next if count.zero?

        @scanner.feed buffer[0, count] do |kind, bytes|
          done = true if yield kind, bytes
        end
      end

      @scanner.flush { |kind, bytes| yield kind, bytes }
    end

    # Returns the bytes read, zero if nothing was ready, or `nil` when there is
    # no point asking again.
    private def read_some(buffer : Bytes, deadline : Time::Instant) : Int32?
      apply_read_timeout deadline

      count = @input.read buffer
      count.zero? ? nil : count
    rescue IO::TimeoutError
      nil
    rescue IO::Error
      nil
    end

    # A real terminal blocks until something arrives, so the read needs a
    # deadline of its own; an in-memory stream returns straight away and needs
    # none. Assigning to a local is what lets the compiler narrow the type.
    private def apply_read_timeout(deadline : Time::Instant) : Nil
      input = @input
      return unless input.responds_to? :read_timeout=

      remaining = deadline - Time.instant
      input.read_timeout = remaining > Time::Span.zero ? remaining : 1.millisecond
    end

    CURSOR_POSITION    = /\A\e\[(\d+);(\d+)R\z/
    KITTY_KEYBOARD     = /\A\e\[\?\d*u\z/
    PRIMARY_ATTRIBUTES = /\A\e\[\?[\d;]*c\z/
    TERMINAL_NAME      = /\A\eP>\|(.*)\e\\\z/m

    # What one response told us: the capabilities after folding it in, which
    # query it answered, and anything else it happened to carry.
    private record Reading,
      flags : Capability,
      query : Symbol?,
      name : String? = nil,
      cursor : {Int32, Int32}? = nil

    private def interpret(response : String, flags : Capability) : Reading
      if match = response.match CURSOR_POSITION
        return Reading.new flags, :cursor_position,
          cursor: {match[2].to_i - 1, match[1].to_i - 1}
      end

      if response.starts_with? "\e[?2026;"
        return Reading.new interpret_decrpm(response, flags), :synchronized_output
      end

      if response.matches? KITTY_KEYBOARD
        return Reading.new flags | Capability::KittyKeyboard, :kitty_keyboard
      end

      if response.starts_with? "\e_G"
        return Reading.new interpret_graphics(response, flags), :kitty_graphics
      end

      if response.starts_with?("\eP0+r") || response.starts_with?("\eP1+r")
        return Reading.new interpret_tcap(response, flags), :xtgettcap
      end

      if match = response.match TERMINAL_NAME
        return Reading.new flags | from_name(match[1]), :xtversion, name: match[1]
      end

      return Reading.new flags, :secondary_attributes if response.starts_with? "\e[>"
      return Reading.new flags, :primary_attributes if response.matches? PRIMARY_ATTRIBUTES

      Reading.new flags, nil
    end

    # `CSI ? 2026 ; Ps $ y`, where 1 means set and 2 means reset. Either way the
    # mode exists; 0 and 4 mean it does not.
    private def interpret_decrpm(response : String, flags : Capability) : Capability
      match = response.match(/\A\e\[\?2026;(\d+)\$y\z/)
      return flags unless match
      return flags unless match[1].in? "1", "2", "3"

      flags | Capability::SynchronizedOutput
    end

    # Any reply at all means the terminal parsed the graphics command, which is
    # more than a terminal without the protocol would do.
    private def interpret_graphics(response : String, flags : Capability) : Capability
      return flags unless response.includes? "i=31"

      flags | Capability::KittyGraphics
    end

    # `DCS 1 + r ... ST` is a hit and `DCS 0 + r ... ST` a miss; either answer
    # tells us the terminal understands XTGETTCAP.
    private def interpret_tcap(response : String, flags : Capability) : Capability
      return flags unless response.starts_with? "\eP1+r"

      flags | Capability::TrueColor
    end

    # What the terminal calls itself is the most reliable signal there is, so
    # it carries the same conclusions the environment variables would have.
    private def from_name(name : String) : Capability
      normalized = name.downcase

      EnvironmentDetector::PROGRAM_PATTERNS.each do |(candidate, capability)|
        return capability if normalized.includes? candidate.downcase
      end

      EnvironmentDetector::TERM_PATTERNS.each do |(pattern, capability)|
        return capability if pattern.matches? normalized
      end

      Capability::None
    end

    # Asks whether the terminal will read image data out of a file rather than
    # take it inline. Only worth asking once the graphics protocol is known to
    # be there, and it needs somewhere to write, so it is separate from the
    # main batch.
    def probe_temp_file : Bool
      path = File.tempname "termbuf", ".rgb"
      File.write path, Bytes[0, 0, 0]

      @output << "\e_Gi=32,s=1,v=1,a=q,t=f,f=24;" << Base64.strict_encode(path) << "\e\\"
      @output << "\e[6n"
      @output.flush

      supported = false

      collect do |kind, bytes|
        next false unless kind.response?

        response = String.new bytes
        supported = true if response.starts_with?("\e_G") && response.includes?("OK")
        response.matches? /\A\e\[\d+;\d+R\z/
      end

      supported
    ensure
      File.delete? path if path
    end
  end
end
