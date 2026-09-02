require "./spec_helper"

private def stack(capabilities = TermBuf::Capabilities::MODERN,
                  colours = true) : {TermBuf::ColorStack, IO::Memory}
  flags = capabilities.flags
  flags |= TermBuf::Capability::KittyColorStack if colours
  written = IO::Memory.new
  made = TermBuf::ColorStack.new(TermBuf::Capabilities.new(flags)) { |bytes| written.write bytes }
  {made, written}
end

Spectator.describe TermBuf::ColorStack do
  describe "the stack" do
    it "pushes and pops, counting how deep it is" do
      made, written = stack

      made.push
      made.push
      expect(made.depth).to eq 2

      made.pop
      expect(made.depth).to eq 1
      expect(written.to_s).to eq "\e[#P\e[#P\e[#Q"
    end

    # An extra pop would walk off the end of a stack something else was using.
    it "will not pop what it did not push" do
      made, written = stack
      made.pop

      expect(made.depth).to eq 0
      expect(written.to_s).to be_empty
    end

    it "pops everything it pushed" do
      made, written = stack
      3.times { made.push }
      made.pop_all

      expect(made.depth).to eq 0
      expect(written.to_s.scan("\e[#Q").size).to eq 3
    end

    it "puts the colours back however the block ends" do
      made, _ = stack

      expect do
        made.saved { raise "trouble" }
      end.to raise_error "trouble"

      expect(made.depth).to eq 0
    end
  end

  describe "setting colours" do
    it "writes the defaults, the cursor, and the selection" do
      made, written = stack
      made.foreground = TermBuf::Color.rgb 255, 255, 255
      made.background = TermBuf::Color.rgb 20, 30, 40
      made.cursor = TermBuf::Color.rgb 255, 0, 0

      expect(written.to_s).to eq "\e]10;rgb:ff/ff/ff\e\\\e]11;rgb:14/1e/28\e\\\e]12;rgb:ff/00/00\e\\"
    end

    it "writes one entry of the palette" do
      made, written = stack
      made[3] = TermBuf::Color.rgb 255, 128, 0

      expect(written.to_s).to eq "\e]4;3;rgb:ff/80/00\e\\"
    end

    # Naming a palette entry as the value of another one is a loop, so an
    # indexed colour is resolved to its channels first.
    it "resolves an indexed colour to its channels" do
      made, written = stack
      made.background = TermBuf::Color::BRIGHT_WHITE

      expect(written.to_s).to eq "\e]11;rgb:ff/ff/ff\e\\"
    end

    it "refuses a palette index outside the palette" do
      made, _ = stack

      expect { made[256] = TermBuf::Color::RED }.to raise_error ArgumentError
    end

    it "resets the palette and the defaults" do
      made, written = stack
      made.reset

      expect(written.to_s).to contain "\e]104\e\\"
      expect(written.to_s).to contain "\e]110\e\\"
    end
  end

  # Without the stack there is nowhere to put the old values, and a shard that
  # leaves a terminal a different colour than it found it is worse than one
  # that leaves the colours alone.
  describe "a terminal without the colour stack" do
    it "says so" do
      made, _ = stack colours: false

      expect(made.available?).to be_false
    end

    it "writes nothing at all, changes included" do
      made, written = stack colours: false
      made.push
      made.background = TermBuf::Color.rgb 1, 2, 3
      made[0] = TermBuf::Color::RED
      made.reset
      made.pop

      expect(written.to_s).to be_empty
      expect(made.depth).to eq 0
    end
  end
end
