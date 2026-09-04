require "termbuf-input"

module TermBuf
  # The input side of a terminal lives in the `termbuf-input` shard.
  #
  # Everything under `TermBuf::Input` — `Input::Stream`, `Input::Decoder`,
  # `Input::Key`, `Input::Events` and the rest — is defined there, and this
  # file is the require that brings it in plus the short spellings termbuf's
  # own API is written in. Nothing in the input side depends on termbuf, which
  # is what let it move: a program that only wants to read a keyboard can
  # depend on `termbuf-input` alone.
  #
  # `TermBuf::Events::Resize` is the one event that stayed behind, because it
  # carries a `ScreenSize`. It is in `terminal/event.cr` and includes
  # `Input::Event` so that it arrives on the same channel as everything else.
  module Input
  end

  # The input side's names, spelled the short way.
  #
  # `TermBuf::Key` and `TermBuf::Input::Key` are the same type. The long
  # spelling is where the definition is and where it stays; the short one is
  # here so that the input side moving into a namespace, and then out into a
  # shard, cost nothing to anyone using it.
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
