require "../caps/screen_size"
require "../input/key"

module TermBuf
  # What the terminal tells the application about, delivered over one channel.
  #
  # These are values rather than a class hierarchy, so a `case` over them is
  # exhaustive and the compiler catches a handler that forgets one.
  module Events
    # The window changed size. The buffer has already been resized to match
    # and everything marked for redraw by the time this arrives.
    record Resize, size : ScreenSize

    # A key press. *bytes* is what the terminal sent to say so, which matters
    # for the sequences the decoder could not name and for anything an
    # application would rather interpret itself.
    record Key, key : ::TermBuf::Key, bytes : Bytes

    # Text that arrived between bracketed paste markers.
    #
    # It is delivered whole rather than as key presses, which is the point of
    # the brackets: pasted text is not typing, and an application that treats
    # it as typing will run its key bindings over whatever was on the
    # clipboard.
    #
    # *complete* is false when the terminal never sent the closing marker and
    # the paste was ended on a stall or a size limit instead. What arrived is
    # still delivered, since it beats nothing, but an application storing it
    # somewhere permanent may want to know it might be half a clipboard.
    record Paste, text : String, complete : Bool

    # A paste has been arriving long enough to be worth saying so on screen,
    # which is what stops a long one looking like a hung application.
    #
    # Repeated as it grows, no more often than the decoder's progress interval.
    # The `Paste` that follows is the signal to take the notice down.
    record Pasting, bytes : Int32, elapsed : Time::Span

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

  # Anything the terminal has to say, in the order it happened.
  alias Event = Events::Resize | Events::Key | Events::Paste |
                Events::Pasting | Events::Response | Events::Warning |
                Events::Failure | Events::Closed
end
