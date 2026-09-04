require "../terminal/event"
require "./decoder"
require "./patterns"
require "./reader"

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

      # Whether the fibres are running.
      getter? started : Bool = false

      # Whether the events channel has been closed.
      getter? closed : Bool = false

      def initialize(io : IO, blocking : Bool)
        @reader = Reader.new io, blocking
        @events = Channel(Event).new CAPACITY
        @patterns = Patterns.new
        @decoder = Decoder.new
        @preloaded = Bytes.empty
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

      # Sends *event* without decoding anything, for what the driver has to say
      # on its own account.
      def inject(event : Event) : Nil
        @events.send event
      rescue Channel::ClosedError
        # Nobody is listening any more.
      end

      # Stops delivering events.
      #
      # The reader is left where it is, blocked on a device only the owner of
      # that device can close; it ends when the device does. Nothing it reads
      # after this reaches anyone.
      def close : Nil
        return if @closed
        @closed = true

        @events.close rescue nil
      end

      # ------------------------------------------------------------ dispatch

      private def dispatch : Nil
        decoder = @decoder
        inbound = @reader.inbound

        unless @preloaded.empty?
          decoder.feed(@preloaded) { |event| inject event }
          @preloaded = Bytes.empty
        end

        running = true

        while running
          # Every deadline is the decoder's: something is being held back, and
          # this is how long it is worth holding it for. With nothing held
          # there is nothing to wake up for, and an idle application costs
          # nothing.
          deadline = decoder.read_deadline

          if deadline
            select
            when message = inbound.receive?
              running = consume message, decoder
            when timeout deadline
              decoder.tick { |event| inject event }
            end
          else
            running = consume inbound.receive?, decoder
          end
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
          decoder.feed(message) { |event| inject event }
          true
        end
      end
    end
  end
end
