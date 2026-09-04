require "../terminal/event"
require "./decoder"
require "./mouse"
require "./patterns"
require "./reader"
require "./signals"
require "./stage"
require "./timers"

module TermBuf
  module Input
    # Everything a terminal has to say, as events.
    #
    # Two fibres. `Reader` reads the device and puts what it read on a channel;
    # a dispatcher takes it off, feeds the decoder, offers each complete escape
    # sequence to the registered `Patterns`, and sends whatever came of it to
    # the application. The split is what lets a blocking read have a thread of
    # its own without the decoder having one too.
    #
    # The dispatcher is the only fibre that ever touches the decoder or asks a
    # pattern about a sequence, so neither needs locking. Registration is the
    # exception, and `Patterns` guards itself for it.
    #
    # Time arrives the same way bytes do. A timer is a fibre that sleeps and
    # then puts a tick on the same channel the reader writes to, so a wake-up
    # takes its place in the queue behind whatever the terminal had already
    # said. The decoder's own escape and paste deadlines are timers like any
    # other; the application's are `#after` and `#cancel`.
    #
    # Between the dispatcher and the channel is `#stages`, a list of `Stage`s
    # every event walks before the application sees it. Keys, patterns' events,
    # timers and signals all go through it; `#inject` does not.
    class Stream
      # Events waiting for the application. Once this fills, decoding stops,
      # and after that reading does: the terminal's own buffer then applies
      # backpressure to the keyboard rather than memory growing here.
      CAPACITY = 256

      # Everything the terminal has to say, in the order it happened.
      getter events : Channel(Event)

      # The sequences the application is interested in. Anything arriving from
      # the terminal that one of them claims becomes whatever it returns;
      # everything else is a key someone pressed.
      getter patterns : Patterns

      # Turns the bytes into events. Reachable so that its deadlines can be
      # adjusted; feeding it from anywhere but the dispatcher is not safe.
      getter decoder : Decoder

      # The wake-ups this stream has armed, the application's and the
      # decoder's alike. `#after` and `#cancel` are the way in.
      getter timers : Timers

      # What the operating system has to say. Its handlers are not installed
      # until something calls `Signals#install`, since traps are process-global
      # and a stream is not necessarily the process.
      getter signals : Signals

      # Whether the fibres are running.
      getter? started : Bool = false

      # Whether the events channel has been closed.
      getter? closed : Bool = false

      # The timer the decoder's current deadline is riding on, if it has one,
      # and when that timer is due. The dispatcher's alone: nothing else reads
      # or writes either of them.
      @deadline : Nonce? = nil
      @deadline_at : Time::Instant? = nil

      # What every event walks before the application sees it. See `#stages`.
      @stages : Array(Stage) = [] of Stage

      def initialize(io : IO, blocking : Bool)
        @reader = Reader.new io, blocking
        @events = Channel(Event).new CAPACITY
        @patterns = Patterns.new
        @decoder = Decoder.new
        @timers = Timers.new @reader.inbound
        @signals = Signals.new @reader.inbound
        @preloaded = Bytes.empty

        watch_the_mouse
      end

      # Watches for SGR mouse reports from the start, so that a terminal
      # reporting the mouse is understood whether or not it was this shard that
      # asked it to.
      #
      # Registered rather than built in because a report is an escape sequence
      # like any other: an application that would rather have the bytes
      # unregisters this and puts its own pattern on `CSI <`.
      #
      # `Mouse.decode` answering `nil` leaves the sequence to the key decoder,
      # which is what should happen to a `CSI <` that is not a report.
      private def watch_the_mouse : Pattern
        @patterns.register(Prefix::CSI, head: "<") do |sequence|
          Mouse.decode sequence
        end
      end

      # Bytes that were read before this stream existed, to be decoded ahead of
      # anything the reader finds.
      #
      # The capability probe reads whatever the terminal sends during its
      # window, and some of that is a key pressed while the application was
      # starting. It belongs at the front of the stream, not nowhere.
      def preload(bytes : Bytes) : Nil
        raise "input has already started" if @started
        return if bytes.empty?

        @preloaded = bytes.dup
      end

      # Starts both fibres.
      def start : Nil
        return if @started
        @started = true

        patterns = @patterns
        @decoder.on_sequence = ->(sequence : Sequence) { patterns.match sequence }

        @reader.start
        spawn(name: "termbuf-dispatch") { dispatch }
      end

      # Asks for an `Events::Timer` in *span* from now, and returns the nonce
      # that will name it.
      #
      # The tick comes down the same channel as the bytes, so it is ordered
      # against them: anything the terminal said before this call is delivered
      # before this timer goes off. What it is not is punctual — it arrives no
      # sooner than *span*, and however much later the application takes to
      # drain the events ahead of it.
      def after(span : Time::Span) : Nonce
        @timers.after span
      end

      # Withdraws the timer *nonce* names. Nothing is delivered for it, even if
      # its fibre had already woken by the time this was called.
      def cancel(nonce : Nonce) : Nil
        @timers.cancel nonce
      end

      # Sends *event* without decoding anything, for what the driver has to say
      # on its own account.
      def inject(event : Event) : Nil
        @events.send event
      rescue Channel::ClosedError
        # Nobody is listening any more.
      end

      # The chain every event walks on its way to the application.
      #
      # Empty by default, which is the useful default: with nothing in it every
      # event goes to the channel as it was made. A driver puts its own
      # translations here — termbuf answers `SIGWINCH` in a stage called
      # `:resize`, which consumes the signal and sends `Events::Resize` in its
      # place — and an application adds, removes or reorders them.
      #
      # The array is swapped rather than mutated: the dispatcher takes a
      # reference to it once per event and walks that, so a chain replaced
      # while an event is half way through it finishes on the chain it started
      # on and the next event uses the new one. Which means reordering is
      # assigning a new array, and mutating the one this returns is a race:
      #
      #     stream.stages = stream.stages.dup.tap do |chain|
      #       chain.unshift my_stage
      #     end
      #
      # `#inject` bypasses the chain entirely, since what the driver has to say
      # on its own account is not something a filter should be able to swallow.
      def stages : Array(Stage)
        @stages
      end

      # :ditto:
      def stages=(stages : Array(Stage)) : Array(Stage)
        @stages = stages
      end

      # Stops delivering events.
      #
      # The reader is left where it is, blocked on a device only the owner of
      # that device can close; it ends when the device does. Nothing it reads
      # after this reaches anyone.
      #
      # Signal handlers go back to the default: they are process-global, and
      # one left pointing at a stream nobody is draining would fill the inbound
      # channel and then block Crystal's signal fibre.
      def close : Nil
        return if @closed
        @closed = true

        @signals.uninstall
        @timers.clear
        @events.close rescue nil
      end

      # ------------------------------------------------------------ dispatch

      private def dispatch : Nil
        decoder = @decoder
        inbound = @reader.inbound

        unless @preloaded.empty?
          decoder.feed(@preloaded) { |event| deliver event }
          @preloaded = Bytes.empty
          rearm decoder
        end

        while consume inbound.receive?, decoder
        end
      ensure
        inject Events::Closed.new
      end

      # Whether there is any point waiting for more.
      private def consume(message : Reader::Inbound?, decoder : Decoder) : Bool
        case message
        in Nil         then false
        in Reader::Eof then false
        in Bytes
          decoder.feed(message) { |event| deliver event }
          rearm decoder
          true
        in Timers::Tick
          fired message.nonce, decoder
          true
        in Signals::Signalled
          signalled message
          true
        end
      end

      # A signal arrived. It becomes an event naming the signal and how many of
      # it have arrived, and what to make of that is the stage chain's to say:
      # termbuf's `:resize` stage swallows `SIGWINCH` and sends a resize
      # instead, and an application that wants the signal raw removes it.
      private def signalled(message : Signals::Signalled) : Nil
        deliver Events::Signal.new message.signal, message.count
      end

      # Walks *event* through the stages and sends whatever comes out.
      #
      # The chain is read once, here, and handed down: an event that is part
      # way through when the application swaps the array finishes on the chain
      # it started on rather than half on each.
      private def deliver(event : Event) : Nil
        stages = @stages
        return inject event if stages.empty?

        advance stages, 0, event
      end

      # Hands *event* to the stage at *index*, or to the channel once the chain
      # is spent. Every `emit` a stage is given calls back in here one step
      # further along, which is what makes emitting twice inject and emitting
      # nothing consume.
      private def advance(stages : Array(Stage), index : Int32, event : Event) : Nil
        return inject event if index >= stages.size

        stages[index].call(event, ->(produced : Event) { advance stages, index + 1, produced })
      end

      # A timer went off. Whether it still means anything is the live set's to
      # say: one cancelled between its sleep ending and this receive is dropped
      # here, which is the half of cancellation a sleeping fibre cannot do.
      private def fired(nonce : Nonce, decoder : Decoder) : Nil
        return unless @timers.claim nonce

        if nonce == @deadline
          disarm
          decoder.tick { |event| deliver event }
          rearm decoder
        else
          deliver Events::Timer.new nonce
        end
      end

      # Puts the decoder's deadline, whatever it is now, on a timer.
      #
      # Every deadline is the decoder's: something is being held back, and this
      # is how long it is worth holding it for. With nothing held there is
      # nothing to wake up for, so nothing is armed and an idle application
      # costs nothing.
      private def rearm(decoder : Decoder) : Nil
        span = decoder.read_deadline
        return disarm unless span

        due = Time.instant + span

        # A timer already armed for no later than the new deadline is left
        # where it is. Waking early costs the decoder a look at the clock and
        # this method another call, where cancelling and arming afresh costs a
        # fibre for every read — and a paste arrives in a thousand reads, each
        # one pushing the stall deadline further out. `Decoder#tick` decides
        # for itself whether anything is due, so an early wake-up is a no-op.
        armed = @deadline_at
        return if @deadline && armed && armed <= due

        disarm
        @deadline = @timers.after span
        @deadline_at = due
      end

      # Forgets the decoder's deadline timer, cancelling it if it has not
      # already gone off.
      private def disarm : Nil
        if nonce = @deadline
          @timers.cancel nonce
        end

        @deadline = nil
        @deadline_at = nil
      end
    end
  end
end
