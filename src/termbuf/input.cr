require "./input/key"
require "./input/scanner"
require "./input/patterns"
require "./input/decoder"
require "./input/timers"
require "./input/reader"
require "./input/stream"

module TermBuf
  # The input side of a terminal: the bytes it sends, turned into events.
  #
  # `Input::Stream` is the one to reach for. Give it the device and it gives
  # back a channel of events: `Events::Key` for a keystroke, `Events::Paste`
  # for what arrived between bracketed paste markers, and whatever a registered
  # `Input::Pattern` makes of a reply the application asked for.
  #
  # `Input::Reader` reads, `Decoder` decodes, `Input::SequenceScanner` splits
  # the byte stream into complete escape sequences, and `Input::Patterns` says
  # which of those are replies rather than keys. `Input::Timers` puts wake-ups
  # in the same queue as the bytes, which is how `Events::Timer` arrives in
  # order with everything else. Every one of them is usable on its own.
  module Input
  end
end
