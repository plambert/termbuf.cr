require "termbuf-input"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # How many cells the terminal is showing. Defined in termbuf-input as
  # `Input::ScreenSize`, because `Events::Resize` carries one and that event
  # starts on the input side.
  alias ScreenSize = Input::ScreenSize

  # Stability: internal
  #
  # Works out how big the terminal is. Defined in termbuf-input as
  # `Input::SizeDetector`, beside the stream that asks it when the window
  # changes size.
  alias SizeDetector = Input::SizeDetector
end
