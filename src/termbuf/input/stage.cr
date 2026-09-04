require "./event"

module TermBuf
  module Input
    # One step in the chain every event walks on its way to the application.
    #
    # A stage is handed the event and an *emit* proc, and what it does with
    # that proc is the whole of its vocabulary:
    #
    # * calling it once passes the event on, or replaces it by emitting a
    #   different one;
    # * not calling it at all consumes the event, and nothing downstream ever
    #   sees it;
    # * calling it more than once injects extra events, in the order emitted.
    #
    # Emitting hands the event to the *next* stage, not back to this one, so a
    # stage that emits what it was given cannot loop.
    #
    #     alias Event = TermBuf::Input::Event
    #
    #     handler = ->(event : Event, emit : Proc(Event, Nil)) do
    #       signal = event.as? TermBuf::Input::Events::Signal
    #
    #       if signal && signal.signal.winch?
    #         # Consumed: something else answers a window change.
    #       else
    #         emit.call event
    #       end
    #     end
    #
    #     resize = TermBuf::Input::Stage.new :resize, handler
    #
    # A proc literal is what a `Stage` holds, so an early exit out of one is
    # `return`; `next` belongs to a block and there is no block here.
    #
    # *name* is for the application's benefit — it is what a stage is found by
    # when a chain is reordered or one of them replaced. Nothing in this shard
    # requires names to be unique.
    record Stage, name : Symbol, handler : Proc(Event, Proc(Event, Nil), Nil) do
      # Runs this stage over *event*, sending whatever it emits to *emit*.
      def call(event : Event, emit : Proc(Event, Nil)) : Nil
        @handler.call event, emit
      end

      def to_s(io : IO) : Nil
        io << "Stage(" << @name << ')'
      end
    end
  end
end
