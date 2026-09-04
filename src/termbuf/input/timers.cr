require "./reader"

module TermBuf
  module Input
    # Names one armed timer. Handed back by `Timers#after`, carried by the
    # `Timers::Tick` that timer produces, and the only thing `Timers#cancel`
    # needs to disarm it.
    alias Nonce = UInt64

    # Wake-ups, delivered down the same channel as the bytes.
    #
    # A timer is a fibre that sleeps and then puts a `Tick` on the reader's
    # inbound channel. Going through that channel rather than a `select` on a
    # timeout is what puts wake-ups in order with everything else the terminal
    # said: a reply that arrived before a timer was armed is dispatched before
    # that timer's tick, every time, because it was on the channel first.
    #
    # Cancellation cannot be atomic with a sleep that has already finished, so
    # it is not tried. A nonce is removed from the live set by `#cancel`, and
    # whoever takes the tick off the channel calls `#claim` to find out whether
    # the nonce is still worth acting on. A timer cancelled while its tick was
    # in flight is dropped on receipt.
    #
    # One fibre per timer. An application arms a handful at a time — a repaint
    # deadline, an idle timeout, the decoder's own escape deadline — and at
    # those volumes a sleeping fibre is cheaper than a heap of them and a
    # thread to service it.
    class Timers
      # A timer went off. Whether it still means anything is `#claim`'s to say.
      record Tick, nonce : Nonce

      # Nonces are unique across the process, so one never names two timers
      # even when an application runs more than one stream.
      @@sequence = Atomic(Nonce).new 0_u64

      # The timers that have not yet been claimed or cancelled. Touched by
      # every timer fibre as well as by whoever arms and claims them, so it is
      # the one piece of state here that needs a lock.
      @live = Set(Nonce).new

      def initialize(@inbound : Channel(Reader::Inbound))
        @mutex = Mutex.new
      end

      # Arms a timer for *span* from now and returns the nonce naming it.
      def after(span : Time::Span) : Nonce
        nonce = @@sequence.add(1_u64) + 1_u64
        @mutex.synchronize { @live << nonce }

        spawn(name: "termbuf-timer-#{nonce}") { run nonce, span }

        nonce
      end

      # Disarms the timer *nonce* names.
      #
      # Safe at any point in that timer's life: before it fires nothing is
      # sent, and after it fires the tick is dropped when it is claimed. What
      # it does not do is stop the fibre, which wakes up to find its nonce gone
      # and ends.
      def cancel(nonce : Nonce) : Nil
        @mutex.synchronize { @live.delete nonce }
      end

      # Takes *nonce* out of the live set, saying whether it was still in it.
      #
      # Called on the receiving end for every tick: false means the timer was
      # cancelled somewhere between its sleep ending and its tick being read,
      # and the tick means nothing. A timer fires once, so claiming it is also
      # what retires it.
      def claim(nonce : Nonce) : Bool
        @mutex.synchronize { @live.delete nonce }
      end

      # Whether *nonce* is still armed.
      def live?(nonce : Nonce) : Bool
        @mutex.synchronize { @live.includes? nonce }
      end

      # How many timers are armed.
      def size : Int32
        @mutex.synchronize { @live.size }
      end

      # Disarms everything, for a stream that is shutting down.
      def clear : Nil
        @mutex.synchronize { @live.clear }
      end

      private def run(nonce : Nonce, span : Time::Span) : Nil
        sleep span

        # Checked before sending as well as on receipt, so that a timer
        # cancelled during its sleep costs nothing downstream. The check on
        # receipt is what covers the rest of the race.
        return unless live? nonce

        @inbound.send Tick.new nonce
      rescue Channel::ClosedError
        # Nobody is dispatching any more.
      end
    end
  end
end
