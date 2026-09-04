module TermBuf
  module Input
    # The fibre that reads the terminal and nothing else.
    #
    # It does no decoding, which is the point: a read from a real device blocks
    # its thread, so the only thing that should happen on that thread is the
    # read. What comes back goes onto a channel and someone else's fibre makes
    # sense of it.
    class Reader
      # One read's worth. Large enough that a paste arrives in few enough
      # pieces to be cheap, small enough to cost nothing when idle.
      BUFFER_SIZE = 4096

      # Reads waiting to be decoded. Once this fills the reader stops reading,
      # which is the right way round: the kernel's own buffer then applies
      # backpressure to the keyboard rather than memory growing here.
      CAPACITY = 16

      # Input has ended. Nothing follows it on the channel.
      record Eof

      # What arrives from the reader. A union rather than plain `Bytes` so that
      # the end of input is a value like any other, and so that later kinds of
      # wake-up have somewhere to go.
      alias Inbound = Bytes | Eof

      # What has been read, in the order it was read.
      getter inbound : Channel(Inbound)

      # Whether the reader is running.
      getter? started : Bool = false

      @context : Fiber::ExecutionContext::Isolated?

      def initialize(@io : IO, @blocking : Bool)
        @inbound = Channel(Inbound).new CAPACITY
      end

      # Starts reading.
      #
      # A blocking read on a real device needs a thread of its own, or it
      # stalls every fibre sharing one. An in-memory stream returns straight
      # away and does not.
      def start : Nil
        return if @started
        @started = true

        if @blocking
          @context = Fiber::ExecutionContext::Isolated.new("termbuf-input") { run }
        else
          spawn(name: "termbuf-input") { run }
        end
      end

      private def run : Nil
        buffer = Bytes.new BUFFER_SIZE

        loop do
          count = @io.read buffer
          break if count.zero?

          # The buffer is read into again straight away, so what goes on the
          # channel has to be a copy.
          @inbound.send buffer[0, count].dup
        end
      rescue IO::Error
        # The terminal went away, which is an ending like any other.
      rescue Channel::ClosedError
        # Nobody is decoding any more.
      ensure
        @inbound.send Eof.new rescue nil
      end
    end
  end
end
