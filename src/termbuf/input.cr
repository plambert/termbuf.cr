require "./input/key"
require "./input/utf8"
require "./input/event"
require "./input/mouse"
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
  # Everything here is under `TermBuf::Input` and depends on nothing else in
  # termbuf, because it is on its way out: the plan is a `termbuf-input` shard
  # that a terminal library uses rather than contains. A require of
  # `termbuf/input` compiles on its own, and `spec/independence.cr` is what
  # keeps that true.
  #
  # `Input::Stream` is the one to reach for. Give it the device and it gives
  # back a channel of events: `Input::Events::Key` for a keystroke,
  # `Input::Events::Paste` for what arrived between bracketed paste markers,
  # and whatever a registered `Input::Pattern` makes of a reply the application
  # asked for.
  #
  # `Input::Reader` reads, `Input::Decoder` decodes, `Input::SequenceScanner`
  # splits the byte stream into complete escape sequences, and
  # `Input::Patterns` says which of those are replies rather than keys.
  # `Input::Timers` puts wake-ups in the same queue as the bytes, which is how
  # `Input::Events::Timer` arrives in order with everything else, and
  # `Input::Signals` puts signals on it too, so that a resize or an interrupt
  # is ordered against the keystrokes around it. `Input::Mouse` decodes the SGR
  # mouse reports, which a stream watches for from the moment it is built;
  # turning the reporting on is the application's to do, and `Tty::MOUSE_SGR`
  # is how.
  #
  # `Input::Stage` is the last thing an event passes: a chain the driver and
  # the application both put translations in, walked between the dispatcher
  # and the channel.
  #
  # Every one of them is usable on its own.
  module Input
  end

  # The input side's names, spelled the short way.
  #
  # `TermBuf::Key` and `TermBuf::Input::Key` are the same type. The long
  # spelling is where the definition is and where it stays; the short one is
  # here so that moving the input side into a namespace, and then out into a
  # shard, costs nothing to anyone using it.
  alias Key = Input::Key

  # :ditto:
  alias Modifiers = Input::Modifiers

  # :ditto:
  alias Decoder = Input::Decoder

  # :ditto:
  alias Event = Input::Event

  # The input side's events, in the namespace `Events::Resize` joins.
  #
  # `TermBuf::Events` is the whole of what arrives on the channel, which is
  # why termbuf's own terminal side names them this way rather than reaching
  # past the alias.
  module Events
    alias Key = Input::Events::Key
    alias Paste = Input::Events::Paste
    alias Pasting = Input::Events::Pasting
    alias Mouse = Input::Events::Mouse
    alias Response = Input::Events::Response
    alias Timer = Input::Events::Timer
    alias Signal = Input::Events::Signal
    alias Warning = Input::Events::Warning
    alias Failure = Input::Events::Failure
    alias Closed = Input::Events::Closed
  end
end
