module TermBuf
  # Stability: internal
  #
  # An `IO` whose writes go out as `Commands::Quiet`, in order with the frames
  # around them.
  #
  # For the parts of termbuf-input that write to a terminal through an `IO`,
  # such as `Input::Queries`, since anything writing to the device directly
  # would land in the middle of a frame.
  class QuietWriter < IO
    def initialize(&@send : Bytes ->)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new "a QuietWriter is only written to"
    end

    def write(slice : Bytes) : Nil
      return if slice.empty?

      @send.call slice.dup
    end
  end
end
