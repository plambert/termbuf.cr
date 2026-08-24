module TermBuf
  # Counts the bytes going to the terminal on their way past.
  #
  # Wrapping rather than buffering keeps the write path one pass: the encoder
  # still writes straight through to the device, and the count is a single
  # addition per write.
  class Meter < IO
    # Bytes since this was last set to zero.
    property bytes : Int32 = 0

    def initialize(@io : IO)
    end

    # Counts *slice* and passes it on.
    def write(slice : Bytes) : Nil
      @bytes += slice.size
      @io.write slice
    end

    # Always raises. A meter sits on the way out only.
    def read(slice : Bytes) : Int32
      raise IO::Error.new "a paint meter is write only"
    end

    # Flushes the stream underneath.
    def flush : Nil
      @io.flush
    end
  end
end
