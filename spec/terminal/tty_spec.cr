require "../spec_helper"

# A tty over two in-memory streams: every escape sequence still goes out, and
# nothing about a real device is needed to read them back.
private def with_tty(&)
  output = IO::Memory.new
  yield TermBuf::Tty.new(IO::Memory.new, output, managed: false), output
end

private ALPHA = TermBuf::Tty::Mode.new "alpha", "\e[?9001h", "\e[?9001l"
private BETA  = TermBuf::Tty::Mode.new "beta", "\e[?9002h", "\e[?9002l"

Spectator.describe TermBuf::Tty do
  describe "#enable" do
    # A mode set before the takeover would be undone by the takeover, so it
    # waits for it instead.
    it "records a mode enabled before the takeover and writes it at the takeover" do
      with_tty do |tty, output|
        tty.enable ALPHA

        expect(output.to_s).to eq ""
        expect(tty.modes).to eq [ALPHA]

        tty.enter TermBuf::Capabilities::NONE

        expect(output.to_s).to contain ALPHA.set
      end
    end

    it "writes a mode enabled after the takeover straight away" do
      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        output.clear
        tty.enable BETA

        expect(output.to_s).to eq BETA.set
      end
    end

    # Not tidiness: the kitty keyboard mode pushes onto a stack the terminal
    # keeps, and a second push against the single pop that leaving sends would
    # leave the keyboard changed after the program has gone.
    it "registers and writes a mode of the same name once" do
      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        output.clear
        tty.enable TermBuf::Tty::KITTY_KEYBOARD
        tty.enable TermBuf::Tty::KITTY_KEYBOARD

        expect(output.to_s.scan(TermBuf::Tty::KITTY_KEYBOARD.set).size).to eq 1
        expect(tty.modes.count { |mode| mode.name == "kitty-keyboard" }).to eq 1
      end
    end

    it "replaces a registration of the same name where it stands" do
      replacement = TermBuf::Tty::Mode.new "alpha", "\e[?9003h", "\e[?9003l"

      with_tty do |tty, _output|
        tty.enable ALPHA
        tty.enable BETA
        tty.enable replacement

        expect(tty.modes).to eq [replacement, BETA]
      end
    end

    # A replacement is not a repeat. The cursor shape is one mode whichever
    # shape it asks for, so a mode of the same name carrying different bytes
    # has to reach the terminal where an identical re-enable must not.
    it "writes a mode of the same name carrying different bytes" do
      replacement = TermBuf::Tty::Mode.new "alpha", "\e[?9003h", "\e[?9003l"

      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        tty.enable ALPHA
        output.clear
        tty.enable replacement

        expect(output.to_s).to eq replacement.set
      end
    end

    # And the reset that goes out is the replacement's, not the one the name
    # was first registered with.
    it "resets a replaced mode with the replacement's own sequence" do
      replacement = TermBuf::Tty::Mode.new "alpha", "\e[?9003h", "\e[?9003l"

      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        tty.enable ALPHA
        tty.enable replacement
        output.clear
        tty.leave

        expect(output.to_s).to contain replacement.reset
        expect(output.to_s).not_to contain ALPHA.reset
      end
    end
  end

  describe "#disable" do
    it "writes the reset and forgets the mode" do
      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        tty.enable ALPHA
        output.clear
        tty.disable ALPHA

        expect(output.to_s).to eq ALPHA.reset
        expect(tty.modes).to be_empty
      end
    end

    it "does nothing to a mode that was never enabled" do
      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        output.clear
        tty.disable ALPHA

        expect(output.to_s).to eq ""
        expect(tty.modes).to be_empty
      end
    end

    it "forgets a mode enabled before the takeover without writing anything" do
      with_tty do |tty, output|
        tty.enable ALPHA
        tty.disable ALPHA
        tty.enter TermBuf::Capabilities::NONE

        expect(output.to_s).not_to contain ALPHA.set
        expect(output.to_s).not_to contain ALPHA.reset
      end
    end
  end

  describe "#leave" do
    # Newest first, since a mode enabled after another may depend on it.
    it "resets the modes in the reverse of the order they were enabled" do
      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        tty.enable ALPHA
        tty.enable BETA
        output.clear
        tty.leave
        written = output.to_s

        expect(written.index!(BETA.reset)).to be < written.index!(ALPHA.reset)
      end
    end

    it "resets each mode once however many times it is called" do
      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        tty.enable ALPHA
        output.clear
        tty.leave
        tty.leave

        expect(output.to_s.scan(ALPHA.reset).size).to eq 1
      end
    end

    # What a suspend and resume does: the shell has had the terminal in
    # between, so everything the program asked for has to be asked for again.
    it "keeps the registrations, so taking the terminal again re-applies them" do
      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::NONE
        tty.enable ALPHA
        tty.enable BETA
        tty.leave
        output.clear
        tty.enter TermBuf::Capabilities::NONE
        written = output.to_s

        expect(written).to contain ALPHA.set
        expect(written).to contain BETA.set
        expect(written.index!(ALPHA.set)).to be < written.index!(BETA.set)
      end
    end

    it "resets bracketed paste, which the takeover registers for itself" do
      with_tty do |tty, output|
        tty.enter TermBuf::Capabilities::MODERN
        expect(output.to_s).to contain TermBuf::Tty::BRACKETED_PASTE.set

        output.clear
        tty.leave

        expect(output.to_s).to contain TermBuf::Tty::BRACKETED_PASTE.reset
      end
    end
  end
end
