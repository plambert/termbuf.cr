require "../caps/screen_size"
require "../input"

module TermBuf
  # What the terminal tells the application about, delivered over one channel.
  #
  # Almost all of them come from the input side and are defined there, under
  # `Input::Events`, with a short spelling here for every one of them. This
  # file holds the ones that need the rest of termbuf.
  module Events
    # The window changed size. The buffer has already been resized to match
    # and everything marked for redraw by the time this arrives.
    #
    # *previous* is the size being left. An application that only needs the new
    # geometry can ignore it; one that scales or scrolls to follow the change
    # needs to know which way the window went, and asking the terminal after
    # the fact only ever gives the size it is already at.
    #
    # This one stays on the terminal side because it carries a `ScreenSize`,
    # which the input side knows nothing about. It includes `Input::Event` like
    # the rest and arrives on the same channel.
    record Resize, size : ScreenSize, previous : ScreenSize do
      include Input::Event
    end
  end
end
