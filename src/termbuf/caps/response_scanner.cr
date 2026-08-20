module TermBuf
  # Splits a stream of bytes arriving from the terminal into complete escape
  # sequences and everything else.
  #
  # The prober needs this to tell a reply to its own query from a keystroke
  # that happened to arrive at the same moment, and the input decoder needs the
  # same split for the same reason. Bytes that do not form a complete sequence
  # yet are held back rather than guessed at.
  class ResponseScanner
    ESC = 0x1B_u8
    BEL = 0x07_u8

    # What a chunk of bytes looks like, which is all that can be told from the
    # bytes alone. Whether an escape sequence is a reply the application asked
    # for or an arrow key someone pressed is not visible here: both are
    # `Sequence`, and `ResponseRegistry` is what tells them apart.
    enum Kind
      # A complete escape sequence.
      Sequence

      # Ordinary characters.
      Text
    end

    # A sequence longer than this is treated as a stray escape followed by
    # ordinary input. Without a bound, one `ESC` with nothing after it would
    # hold every later byte hostage.
    MAX_SEQUENCE = 1024

    @buffer : IO::Memory

    def initialize
      @buffer = IO::Memory.new
    end

    # Feeds bytes in, yielding each complete chunk that can be classified.
    def feed(chunk : Bytes, & : Kind, Bytes ->) : Nil
      pending = self.pending
      @buffer.clear
      @buffer.write pending
      @buffer.write chunk

      data = @buffer.to_slice
      offset = 0

      while offset < data.size
        consumed = classify(data + offset) { |kind, bytes| yield kind, bytes }
        break if consumed.zero?

        offset += consumed
      end

      remainder = data[offset..]
      @buffer.clear
      @buffer.write remainder
    end

    # Bytes held back because they do not yet form a complete sequence.
    def pending : Bytes
      @buffer.to_slice.dup
    end

    # Discards anything held back.
    def clear : Nil
      @buffer.clear
    end

    # Treats whatever is held back as ordinary text, which is what a timeout
    # means: no more of that sequence is coming.
    def flush(& : Kind, Bytes ->) : Nil
      remainder = pending
      return if remainder.empty?

      @buffer.clear
      yield Kind::Text, remainder
    end

    # Consumes one chunk from the front of *data*, returning how many bytes it
    # took. Zero means the front of *data* is an incomplete sequence.
    private def classify(data : Bytes, & : Kind, Bytes ->) : Int32
      unless data[0] == ESC
        length = 0

        while length < data.size && data[length] != ESC
          length += 1
        end

        yield Kind::Text, data[0, length]
        return length
      end

      length = sequence_length data
      return force_input(data) { |kind, bytes| yield kind, bytes } if length.nil?
      return 0 if length.zero?

      yield Kind::Sequence, data[0, length]
      length
    end

    # An escape that has run past the length any real sequence reaches is not
    # one; hand over the escape byte itself and resume from what follows.
    private def force_input(data : Bytes, & : Kind, Bytes ->) : Int32
      yield Kind::Text, data[0, 1]
      1
    end

    # The length of the sequence at the front of *data*: zero when more bytes
    # are needed, `nil` when it has grown past any plausible sequence.
    private def sequence_length(data : Bytes) : Int32?
      return 0 if data.size < 2
      return if data.size > MAX_SEQUENCE

      case data[1]
      when '['.ord then csi_length data
      when 'O'.ord then data.size < 3 ? 0 : 3
      when ']'.ord then string_length data, terminated_by_bel: true
      when 'P'.ord, '_'.ord, '^'.ord, 'X'.ord
        string_length data, terminated_by_bel: false
      else 2
      end
    end

    # A control sequence runs to the first byte in the final range.
    private def csi_length(data : Bytes) : Int32?
      index = 2

      while index < data.size
        byte = data[index]
        return index + 1 if 0x40 <= byte <= 0x7E

        index += 1
      end

      data.size > MAX_SEQUENCE ? nil : 0
    end

    # A string sequence runs to a string terminator, and for OSC also to a bell.
    private def string_length(data : Bytes, terminated_by_bel : Bool) : Int32?
      index = 2

      while index < data.size
        byte = data[index]
        return index + 1 if terminated_by_bel && byte == BEL
        return index + 2 if byte == ESC && index + 1 < data.size && data[index + 1] == '\\'.ord

        index += 1
      end

      data.size > MAX_SEQUENCE ? nil : 0
    end
  end
end
