require "base64"

require "../image_store"
require "./capability"
require "./environment"
require "./timed_read"
require "../input"

module TermBuf
  # Stability: internal
  #
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

    # What the terminal said, and what arrived while it was saying it.
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

    # How long to wait for the sentinel before giving up on the batch.
    getter timeout : Time::Span

    def initialize(@input : IO, @output : IO, @timeout : Time::Span = DEFAULT_TIMEOUT)
      @scanner = Input::SequenceScanner.new
      @reader = TimedRead.new @input
    end

    # A one pixel RGB image, asked about rather than displayed.
    KITTY_GRAPHICS_QUERY = "\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\"

    # `Tc` and `RGB` are the terminfo capabilities that mean 24 bit colour;
    # asking for them by hex name is how XTGETTCAP works.
    TCAP_QUERY = "\eP+q5463;524742\e\\"

    # DECRQSS for the cursor style: `DCS $ q SP q ST` asks the terminal to
    # report the DECSCUSR setting it is currently in.
    #
    # An experiment, and the only query there is for `Capability::CursorShape`
    # — nothing else this shard can ask answers whether DECSCUSR does
    # anything. A terminal that implements DECRQSS answers `DCS 1 $ r Ps SP q
    # ST` with the shape it is set to, which is evidence it knows the setting
    # exists; `DCS 0 $ r ST` is a terminal that understands the request and
    # refuses this particular one, which is evidence it does not. Terminal.app
    # and kitty answer neither, and silence changes nothing: the terminal's
    # name is still the best that can be done for them.
    CURSOR_STYLE_QUERY = "\eP$q q\e\\"

    # The DEC private modes worth asking about, and the capability each one
    # stands for. `CSI ? Pm $ p` is DECRQM and the reply is DECRPM, which is
    # the only mechanism a terminal offers for saying it does *not* have
    # something; every other query in the batch is silent about what it lacks.
    #
    # Mode 2027 is asked about and never turned on. Enabling it changes how the
    # terminal counts grapheme clusters, and the width probe measures this
    # terminal with the mode off; switching it on afterwards would invalidate
    # every width already established. See `Capability::GraphemeClusters`.
    MODE_CAPABILITIES = {
      2026 => Capability::SynchronizedOutput,
      2027 => Capability::GraphemeClusters,
      1004 => Capability::FocusEvents,
      1006 => Capability::MouseSgr,
      2004 => Capability::BracketedPaste,
    }

    # Which query a mode report answered, for `Result#answered`. A separate
    # table because a symbol cannot be built out of a value at runtime.
    MODE_QUERIES = {
      2026 => :synchronized_output,
      2027 => :grapheme_clusters,
      1004 => :focus_events,
      1006 => :mouse_sgr,
      2004 => :bracketed_paste,
    }

    QUERIES = String.build do |io|
      io << Input::Query::DEVICE_ATTRIBUTES.request
      io << Input::Query::SECONDARY_DEVICE_ATTRIBUTES.request
      io << Input::Query::TERMINAL_NAME.request
      io << TCAP_QUERY # 24 bit colour, asked of terminfo

      # DECRQM for every mode above, in the same write as everything else.
      MODE_CAPABILITIES.each_key { |mode| io << Input::Query.mode(mode).request }

      io << Input::Query::KITTY_KEYBOARD.request
      io << CURSOR_STYLE_QUERY # DECSCUSR, asked with DECRQSS
      io << KITTY_GRAPHICS_QUERY

      # The sentinel, always answered.
      io << Input::Query::CURSOR_POSITION.request
    end

    # Sends the queries and folds whatever comes back into *base*.
    #
    # A mode report for a capability in *distrusted* is recorded as answered
    # and adds nothing: it is the answer of something in the middle rather than
    # of the terminal at the end. A refusal is trusted whatever is in
    # *distrusted*, since nothing forwards a mode it does not know. See
    # `EnvironmentDetector.distrusted`.
    def probe(base : Capabilities, distrusted : Capability = Capability::None) : Result
      @output << QUERIES
      @output.flush

      flags = base.flags
      # A terminal saying it does not recognise a mode outranks whatever put
      # the capability there, its own name included, and the replies do not
      # arrive in an order anything guarantees. So refusals are collected
      # apart and taken off at the end, where their order cannot matter.
      denied = Capability::None
      answered = [] of Symbol
      input = IO::Memory.new
      name = nil.as(String?)
      cursor = nil.as({Int32, Int32}?)

      collect do |kind, bytes|
        if kind.text?
          input.write bytes
          next false
        end

        reading = interpret Input::Sequence.parse(bytes), flags, distrusted
        flags = reading.flags
        denied |= reading.denied

        if query = reading.query
          answered << query
        end
        name ||= reading.name
        cursor ||= reading.cursor
        reading.query == :cursor_position
      end

      Result.new Capabilities.new(flags & ~denied), input.to_slice, answered, name, cursor
    end

    # Reads until the block reports the sentinel has arrived, or the deadline
    # passes. Whatever is still half-arrived at that point is treated as input.
    #
    # The read deadline is put back the way it was found. Leaving one behind
    # would make every later read of that stream give up after a quarter of a
    # second, which reads exactly like the terminal having gone away.
    private def collect(& : Input::SequenceScanner::Kind, Bytes -> Bool) : Nil
      input = @input

      if input.responds_to?(:read_timeout=) && input.responds_to?(:read_timeout)
        previous = input.read_timeout

        begin
          gather { |kind, bytes| yield kind, bytes }
        ensure
          input.read_timeout = previous
        end
      else
        gather { |kind, bytes| yield kind, bytes }
      end
    end

    private def gather(& : Input::SequenceScanner::Kind, Bytes -> Bool) : Nil
      deadline = Time.instant + @timeout
      buffer = Bytes.new 4096
      done = false

      until done || Time.instant >= deadline
        count = @reader.read buffer, deadline
        break if count.nil?
        next if count.zero?

        @scanner.feed buffer[0, count] do |kind, bytes|
          done = true if yield kind, bytes
        end
      end

      @scanner.flush { |kind, bytes| yield kind, bytes }
    end

    # `DCS Ps $ r ... ST`, the DECRPSS reply, where a leading 1 means the
    # request was valid and 0 that it was not. The payload of a valid one is
    # the setting itself, `Ps SP q` for a cursor style, and it is matched
    # rather than read: the shape the terminal happens to be in says nothing
    # about whether it will take a new one.
    CURSOR_STYLE_REPORT = /\A\eP([01])\$r(\d* q)?\e\\\z/

    # What one response told us: the capabilities after folding it in, which
    # query it answered, and anything else it happened to carry.
    private record Reading,
      flags : Capability,
      query : Symbol?,
      name : String? = nil,
      cursor : {Int32, Int32}? = nil,
      # Capabilities the terminal said outright that it does not have.
      denied : Capability = Capability::None

    # The replies termbuf-input decodes are read with `Input::Replies`; the
    # three it does not — kitty graphics, XTGETTCAP and DECRQSS — are read
    # here.
    private def interpret(sequence : Input::Sequence, flags : Capability,
                          distrusted : Capability) : Reading
      if position = Input::Replies.cursor_position sequence
        return Reading.new flags, :cursor_position, cursor: {position.x, position.y}
      end

      if report = Input::Replies.mode_report sequence
        return interpret_decrpm report, flags, distrusted
      end

      if Input::Replies.kitty_keyboard sequence
        return Reading.new flags | Capability::KittyKeyboard, :kitty_keyboard
      end

      response = String.new sequence.bytes

      if response.starts_with? "\e_G"
        return Reading.new interpret_graphics(response, flags), :kitty_graphics
      end

      if response.starts_with?("\eP0+r") || response.starts_with?("\eP1+r")
        return Reading.new interpret_tcap(response, flags), :xtgettcap
      end

      if match = response.match CURSOR_STYLE_REPORT
        return interpret_cursor_style match, flags
      end

      if terminal = Input::Replies.terminal_name sequence
        name = terminal.text
        told = (flags | from_name(name)) & ~EnvironmentDetector.denials(name)
        return Reading.new told, :xtversion, name: name
      end

      if attributes = Input::Replies.device_attributes sequence
        return Reading.new flags, attributes.secondary ? :secondary_attributes : :primary_attributes
      end

      Reading.new flags, nil
    end

    # `CSI ? Pm ; Ps $ y`, the DECRPM reply. A value of 1 means the mode is
    # set, 2 that it is reset, and 3 that it is permanently set; all three say
    # the mode is there. 0 means the terminal does not recognise the mode and 4
    # that it is permanently reset, and both say it is not.
    #
    # A refusal is recorded rather than merely not added. The report is
    # evidence about the terminal actually on the other end, where a name that
    # put the capability there is evidence about the family it belongs to, and
    # the specific answer wins.
    #
    # Unless the thing on the other end is a multiplexer answering for a mode
    # it implements and does not forward, which is what *distrusted* names. The
    # answer is still recorded as answered — it arrived — and the capability is
    # left where the environment put it.
    private def interpret_decrpm(report : Input::Events::ModeReport, flags : Capability,
                                 distrusted : Capability) : Reading
      mode = report.mode
      capability = MODE_CAPABILITIES[mode]?
      return Reading.new flags, nil unless capability

      query = MODE_QUERIES[mode]?

      if report.state.supported?
        return Reading.new flags, query if distrusted.includes? capability

        return Reading.new flags | capability, query
      end

      Reading.new flags, query, denied: capability
    end

    # A DECRQSS reply for the cursor style. `DCS 1 $ r ... ST` is a terminal
    # that knows the setting and reports it; `DCS 0 $ r ST` is one that parsed
    # the request and will not answer this one, which for a setting it would
    # have to implement to report means it does not have it.
    #
    # A refusal is recorded as a denial rather than merely not added, for the
    # reason a DECRPM refusal is: an answer about the terminal actually on the
    # other end outranks the family its name puts it in.
    private def interpret_cursor_style(match : Regex::MatchData,
                                       flags : Capability) : Reading
      return Reading.new flags, :decrqss_cursor_style, denied: Capability::CursorShape unless match[1] == "1"

      Reading.new flags | Capability::CursorShape, :decrqss_cursor_style
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
      # Named the way a real transmission will be, or the answer describes a
      # path the terminal would go on to refuse. See `ImageStore::TEMP_MARKER`.
      path = ImageStore.temp_path
      File.write path, Bytes[0, 0, 0]

      @output << "\e_Gi=32,s=1,v=1,a=q,t=f,f=24;" << Base64.strict_encode(path) << "\e\\"
      @output << Input::Query::CURSOR_POSITION.request
      @output.flush

      supported = false

      collect do |kind, bytes|
        next false unless kind.sequence?

        response = String.new bytes
        supported = true if response.starts_with?("\e_G") && response.includes?("OK")
        !Input::Replies.cursor_position(Input::Sequence.parse(bytes)).nil?
      end

      supported
    ensure
      File.delete? path if path
    end
  end
end
