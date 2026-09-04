require "base64"
require "./caps/capability"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # The system clipboard, written through the terminal with OSC 52.
  #
  # The terminal is the only thing in the picture with a connection to the
  # window system, so a program on the far end of an ssh session sets the
  # clipboard of the machine the human is sitting at rather than the one it is
  # running on. That is the whole appeal, and it is why terminals treat it
  # carefully: many ship with clipboard writes off, and this shard cannot tell
  # a refusal from a success, since nothing is sent back either way.
  #
  #     terminal.clipboard.copy "the selected text"
  #     terminal.clipboard.copy "a middle-click paste", :primary
  #
  # Everything here is gated on `Capability::Osc52Clipboard`. Without it
  # `#copy` writes nothing at all rather than putting a sequence on the wire
  # that a terminal without the feature would print as text.
  #
  # ### How much will fit
  #
  # Nothing here chunks or splits, because there is nothing to chunk into: OSC
  # 52 carries one payload and the limit on it belongs to the terminal, not to
  # the protocol. Kitty defaults to refusing anything over 512KiB, xterm's
  # limit is smaller still and depends on how it was built, and a multiplexer
  # in between adds a limit of its own. A terminal over the limit truncates or
  # drops the write silently, so a caller moving more than a few kilobytes
  # should not expect it to arrive, and cannot find out that it did not.
  class Clipboard
    OSC = "\e]"
    ST  = "\e\\"

    # Which selection a copy lands in.
    enum Target
      # The clipboard proper, what a paste command reads.
      Clipboard

      # The X11 primary selection, what a middle click pastes. Terminals off
      # X11 usually map it onto the clipboard or ignore it.
      Primary

      # The letter OSC 52 names this selection by.
      def code : Char
        case self
        in .clipboard? then 'c'
        in .primary?   then 'p'
        end
      end
    end

    # What the terminal can do, which for everything here means one flag.
    getter capabilities : Capabilities

    def initialize(@capabilities : Capabilities, &@sink : Bytes -> Nil)
    end

    # Whether the terminal will take any of this.
    def available? : Bool
      @capabilities.includes? Capability::Osc52Clipboard
    end

    # Puts *text* on the system clipboard, or on the primary selection.
    #
    # The text goes out as base64 of its UTF-8 bytes, which is what OSC 52
    # carries: the sequence ends at a `ST` and arbitrary text would otherwise
    # be able to end it early. Does nothing without
    # `Capability::Osc52Clipboard`.
    def copy(text : String, target : Target = Target::Clipboard) : Nil
      return unless available?

      encoded = Base64.strict_encode text
      @sink.call "#{OSC}52;#{target.code};#{encoded}#{ST}".to_slice
    end
  end
end
