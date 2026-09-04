require "./input/key"
require "./input/scanner"
require "./input/patterns"
require "./input/decoder"
require "./input/signals"
require "./input/stage"
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
  # order with everything else, and `Input::Signals` puts signals on it too, so
  # that a resize or an interrupt is ordered against the keystrokes around it.
  # `Input::Stage` is the last thing an event passes: a chain the driver and
  # the application both put translations in, walked between the dispatcher
  # and the channel.
  #
  # Every one of them is usable on its own.
  module Input
  end
end
