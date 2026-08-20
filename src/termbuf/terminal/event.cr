require "../caps/screen_size"

module TermBuf
  # What the terminal tells the application about, delivered over one channel.
  #
  # These are values rather than a class hierarchy, so a `case` over them is
  # exhaustive and the compiler catches a handler that forgets one.
  module Events
    # The window changed size. The buffer has already been resized to match
    # and everything marked for redraw by the time this arrives.
    record Resize, size : ScreenSize

    # Bytes from the keyboard that are not a reply to anything. Until the
    # decoder lands these arrive raw; afterwards they arrive as keys.
    record Input, bytes : Bytes

    # A complete escape sequence the terminal sent, which is to say an answer
    # to something that was asked of it.
    record Response, bytes : Bytes

    # Something was wrong but not worth stopping for — a capability override
    # naming something unknown, most likely.
    #
    # These never go to stderr. The screen belongs to the application, and
    # writing to it from underneath would corrupt the display.
    record Warning, message : String

    # Something failed. The driver keeps going; the application decides.
    record Failure, error : Exception

    # Input has ended, or the terminal is shutting down. Nothing follows.
    record Closed
  end

  alias Event = Events::Resize | Events::Input | Events::Response |
                Events::Warning | Events::Failure | Events::Closed
end
