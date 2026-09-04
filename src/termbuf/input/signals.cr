require "./reader"

module TermBuf
  module Input
    # What the operating system has to say, on the same queue as the bytes.
    #
    # A signal handler runs in a fibre of Crystal's own, with the terminal in
    # whatever state the last frame left it and no idea what the application
    # was in the middle of. That is the wrong place to decide anything, so
    # almost nothing is decided there: a delivery is counted, a marker goes on
    # the reader's inbound channel, and the dispatcher turns it into an event
    # in order with everything the terminal had already said.
    #
    # The exception is leaving. A process being killed is not going to drain a
    # channel, so `Mode::Exit` runs its hooks — restoring the terminal, above
    # all — in the handler itself, resets the signal, and re-raises it so the
    # process dies of what it was sent rather than of `exit`.
    #
    # `Signal.trap` is process-global. One `Signals` per process is the shape
    # this expects; a second `#install` replaces the first's handlers, and
    # `#uninstall` puts every signal it traps back to the default. Anything
    # installing traps must uninstall them, specs included.
    class Signals
      # What a delivered signal does.
      enum Mode
        # Run the `#before_exit` hooks, reset the signal, and re-raise it, so
        # the process dies of what it was sent and its exit status says so.
        Exit

        # Deliver an `Events::Signal` and carry on. What the application does
        # about it is the application's business.
        Event

        # Deliver an `Events::Signal`, and `Exit` once `#threshold` of them
        # have arrived. The first press asks, the last one insists.
        WarnThenExit
      end

      # A signal arrived, on its way to the dispatcher.
      #
      # *count* is how many of that signal had been delivered when this one
      # was, counting from one and cleared by `#reset_count`. It is carried
      # rather than looked up on receipt so that a burst of signals produces
      # one event per delivery with the count each of them actually had.
      record Signalled, signal : ::Signal, count : Int32

      # What a signal does when nothing has said otherwise.
      #
      # The three that mean "stop" restore the terminal on the way out. `WINCH`
      # is an event because it is not a shutdown at all, and because the
      # application — or, in this shard, the terminal driver — is the only one
      # who knows what to do about a window that changed size.
      DEFAULT_MODES = {
        ::Signal::TERM  => Mode::Exit,
        ::Signal::INT   => Mode::Exit,
        ::Signal::HUP   => Mode::Exit,
        ::Signal::WINCH => Mode::Event,
      }

      # How many deliveries `Mode::WarnThenExit` takes before it exits, when
      # nothing has said otherwise.
      DEFAULT_THRESHOLD = 2

      # Whether the handlers are installed.
      getter? installed : Bool = false

      # The last thing `Mode::Exit` does, once every `#before_exit` hook has
      # run: reset the signal and send it again, so the process dies of what it
      # was sent rather than of `exit`.
      #
      # Replaceable so that a spec can watch an exit happen without being
      # killed by it. Nothing else has a reason to.
      property terminate : Proc(::Signal, Nil) = ->(signal : ::Signal) do
        signal.reset
        Process.signal signal, Process.pid
      end

      @modes : Hash(::Signal, Mode)
      @thresholds = {} of ::Signal => Int32
      @counts = {} of ::Signal => Int32
      @hooks = {} of ::Signal => Proc(Nil)
      @before_exit = [] of Proc(Nil)

      def initialize(@inbound : Channel(Reader::Inbound))
        @mutex = Mutex.new
        @modes = DEFAULT_MODES.dup
      end

      # ---------------------------------------------------------- the policy

      # What *signal* does when it arrives.
      def mode(signal : ::Signal) : Mode
        @mutex.synchronize { @modes[signal]? || Mode::Exit }
      end

      # Says what *signal* should do when it arrives.
      #
      # A signal named here is trapped, now if the handlers are already
      # installed and by `#install` if they are not. Crystal has no setter
      # taking two arguments, so this is `signals.mode Signal::INT,
      # Mode::WarnThenExit` rather than an assignment.
      def mode(signal : ::Signal, mode : Mode) : Mode
        arm = @mutex.synchronize do
          @modes[signal] = mode
          @installed
        end

        trap signal if arm
        mode
      end

      # How many deliveries of *signal* `Mode::WarnThenExit` waits for.
      def threshold(signal : ::Signal) : Int32
        @mutex.synchronize { @thresholds[signal]? || DEFAULT_THRESHOLD }
      end

      # Sets how many deliveries of *signal* `Mode::WarnThenExit` waits for.
      def threshold(signal : ::Signal, deliveries : Int32) : Int32
        raise ArgumentError.new "threshold #{deliveries} is not positive" unless deliveries > 0

        @mutex.synchronize { @thresholds[signal] = deliveries }
      end

      # How many of *signal* have been delivered since the count was last
      # cleared.
      def count(signal : ::Signal) : Int32
        @mutex.synchronize { @counts[signal]? || 0 }
      end

      # Forgets how many of *signal* have arrived.
      #
      # Repeats need not be contiguous: input arriving between two interrupts
      # does not clear the count, because a person pressing the key twice with
      # a keystroke in between still means it. An application that treats one
      # press as answered — it put up a confirmation and the person dismissed
      # it — says so here.
      def reset_count(signal : ::Signal) : Nil
        @mutex.synchronize { @counts.delete signal }
        nil
      end

      # ----------------------------------------------------------- the hooks

      # Registers something to run before the process dies of a signal.
      #
      # Hooks run in the order they were registered, in the signal handler
      # itself, and each is rescued: one that raises does not stop the ones
      # after it, which is the whole point of a stack of them. This shard
      # registers the terminal's restore.
      def before_exit(&hook : ->) : Nil
        @mutex.synchronize { @before_exit << hook }
        nil
      end

      # Registers a handler for *signal* that runs instead of the modes.
      #
      # For the signals whose answer is neither an event nor an exit —
      # `TSTP` gives the terminal back and stops, `CONT` takes it again and
      # redraws. The hook runs in the signal handler, and the trap is put back
      # afterwards, so a hook that resets its own signal to raise it at the
      # default handler still has a trap when the process comes back.
      def on(signal : ::Signal, &hook : ->) : Nil
        arm = @mutex.synchronize do
          @hooks[signal] = hook
          @installed
        end

        trap signal if arm
        nil
      end

      # ------------------------------------------------------- installing

      # Traps every signal that has a mode or a hook.
      def install : Nil
        signals = [] of ::Signal

        @mutex.synchronize do
          unless @installed
            @installed = true
            signals = registered
          end
        end

        signals.each { |signal| trap signal }
      end

      # Puts every signal this traps back to the default.
      #
      # Process-global state is being handed back, so anything that installs
      # has to get here however it ends.
      def uninstall : Nil
        signals = [] of ::Signal

        @mutex.synchronize do
          if @installed
            @installed = false
            signals = registered
          end
        end

        signals.each &.reset
      end

      # :ditto:
      def reset : Nil
        uninstall
      end

      # Every signal with a mode or a hook. The caller holds the lock.
      private def registered : Array(::Signal)
        (@modes.keys + @hooks.keys).uniq!
      end

      # ------------------------------------------------------------ handling

      private def trap(signal : ::Signal) : Nil
        signal.trap { handle signal }
      end

      # What a delivered signal does. Runs in Crystal's signal fibre.
      private def handle(signal : ::Signal) : Nil
        hook = @mutex.synchronize { @hooks[signal]? }

        if hook
          hook.call
          return
        end

        case mode signal
        in Mode::Exit  then depart signal
        in Mode::Event then deliver signal
        in Mode::WarnThenExit
          depart signal if deliver(signal) >= threshold(signal)
        end
      ensure
        # A hook may have reset its own signal to re-raise it at the default
        # handler, and `Mode::Exit` certainly did. Put the trap back, so a
        # second delivery is handled like the first: a process that comes back
        # from a suspend still gives the terminal up on the next one.
        retrap signal
      end

      # Counts a delivery and puts it on the queue. Returns the count.
      private def deliver(signal : ::Signal) : Int32
        count = @mutex.synchronize { @counts[signal] = (@counts[signal]? || 0) + 1 }

        begin
          @inbound.send Signalled.new(signal, count)
        rescue Channel::ClosedError
          # Nobody is dispatching any more.
        end

        count
      end

      # Gives everything back and dies of the signal.
      private def depart(signal : ::Signal) : Nil
        hooks = @mutex.synchronize { @before_exit.dup }

        hooks.each do |hook|
          hook.call
        rescue
          # One hook failing is no reason to skip the rest: what they are for
          # is giving things back, and the ones after it have their own to
          # give. Nothing is written about it either — the screen belongs to
          # the application, and this is the moment it is being handed back.
        end

        @terminate.call signal
      end

      private def retrap(signal : ::Signal) : Nil
        trap signal if @mutex.synchronize { @installed }
      end
    end
  end
end
