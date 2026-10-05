require "../input"

module TermBuf
  # Stability: internal
  #
  # A read from the terminal that gives up at a deadline, for the probes,
  # which ask questions some terminals never answer.
  #
  # A file descriptor takes the deadline as `IO#read_timeout`. A Windows
  # console ignores that and would wait for a keystroke, so there the read
  # goes through `Input::Console`, which waits on the console with a timeout.
  # An in-memory stream returns straight away and needs neither.
  #
  # Leaves `read_timeout` set; the probes put back what they found.
  class TimedRead
    # What a console read made that did not fit in the caller's buffer.
    @leftover = Bytes.empty

    {% if flag?(:win32) %}
      @console : Input::Console?
    {% end %}

    def initialize(@input : IO)
      {% if flag?(:win32) %}
        @console = Input::Console.for? @input
      {% end %}
    end

    # Reads into *buffer*. Answers how many bytes, zero when nothing that
    # reads as bytes arrived yet, or `nil` once the deadline has passed or
    # there is nothing left to read.
    def read(buffer : Bytes, deadline : Time::Instant) : Int32?
      return take(buffer) unless @leftover.empty?

      remaining = deadline - Time.instant
      return if remaining <= Time::Span.zero

      {% if flag?(:win32) %}
        if console = @console
          batch = console.read remaining
          return unless batch

          @leftover = batch.bytes
          return take buffer
        end
      {% end %}

      input = @input
      input.read_timeout = remaining if input.responds_to? :read_timeout=

      count = input.read buffer
      count.zero? ? nil : count
    rescue IO::TimeoutError
      nil
    rescue IO::Error
      nil
    end

    # Moves as much of the leftover into *buffer* as fits.
    private def take(buffer : Bytes) : Int32
      count = Math.min(@leftover.size, buffer.size)
      @leftover[0, count].copy_to buffer
      @leftover = @leftover[count..]
      count
    end
  end
end
