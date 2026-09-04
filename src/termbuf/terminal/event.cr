require "../caps/screen_size"
require "../input/key"

module TermBuf
  # Anything the terminal has to say, in the order it happened.
  #
  # A marker module every event type includes, rather than a union of the ones
  # this shard happens to define. Channels, signatures and instance variables
  # are typed `Event` and keep working, and a shard that defines an event of
  # its own includes this and can send it down the same channel.
  #
  # Being open, it cannot be `case`d exhaustively: a handler needs an `else`
  # for the event kinds it does not know about.
  module Event
  end

  # What the terminal tells the application about, delivered over one channel.
  #
  # These are values rather than a class hierarchy. Each includes `Event`.
  module Events
    # The window changed size. The buffer has already been resized to match
    # and everything marked for redraw by the time this arrives.
    #
    # *previous* is the size being left. An application that only needs the new
    # geometry can ignore it; one that scales or scrolls to follow the change
    # needs to know which way the window went, and asking the terminal after
    # the fact only ever gives the size it is already at.
    record Resize, size : ScreenSize, previous : ScreenSize do
      include Event
    end

    # A key press. *bytes* is what the terminal sent to say so, which matters
    # for the sequences the decoder could not name and for anything an
    # application would rather interpret itself.
    record Key, key : ::TermBuf::Key, bytes : Bytes do
      include Event
    end

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
    record Paste, text : String, complete : Bool do
      include Event
    end

    # A paste has been arriving long enough to be worth saying so on screen,
    # which is what stops a long one looking like a hung application.
    #
    # Repeated as it grows, no more often than the decoder's progress interval.
    # The `Paste` that follows is the signal to take the notice down.
    record Pasting, bytes : Int32, elapsed : Time::Span do
      include Event
    end

    # A complete escape sequence the terminal sent, which is to say an answer
    # to something that was asked of it.
    record Response, bytes : Bytes do
      include Event
    end

    # Something was wrong but not worth stopping for — a capability override
    # naming something unknown, most likely.
    #
    # These never go to stderr. The screen belongs to the application, and
    # writing to it from underneath would corrupt the display.
    record Warning, message : String do
      include Event
    end

    # Something failed. The driver keeps going; the application decides.
    record Failure, error : Exception do
      include Event
    end

    # Input has ended, or the terminal is shutting down. Nothing follows.
    record Closed do
      include Event
    end
  end
end
