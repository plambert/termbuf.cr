require "../spec_helper"

private alias Cap = TermBuf::Capability

private def override(spec : String?,
                     base = TermBuf::Capabilities::XTERM) : TermBuf::CapabilityOverrides::Result
  TermBuf::CapabilityOverrides.apply base, spec
end

Spectator.describe TermBuf::CapabilityOverrides do
  describe "when unset" do
    it "leaves the detected capabilities alone" do
      expect(override(nil).capabilities).to eq TermBuf::Capabilities::XTERM
      expect(override("").capabilities).to eq TermBuf::Capabilities::XTERM
      expect(override("   ").capabilities).to eq TermBuf::Capabilities::XTERM
    end
  end

  describe "turning capabilities on" do
    it "accepts a leading plus" do
      expect(override("+true_color").capabilities.includes?(Cap::TrueColor)).to be_true
    end

    it "accepts a bare name" do
      expect(override("true_color").capabilities.includes?(Cap::TrueColor)).to be_true
    end

    it "accepts the name run together" do
      expect(override("truecolor").capabilities.includes?(Cap::TrueColor)).to be_true
    end

    it "accepts the name as the enum spells it" do
      expect(override("TrueColor").capabilities.includes?(Cap::TrueColor)).to be_true
    end
  end

  describe "turning capabilities off" do
    it "accepts a leading minus" do
      expect(override("-color256").capabilities.includes?(Cap::Color256)).to be_false
    end

    it "leaves everything unmentioned as it was" do
      caps = override("-color256").capabilities

      expect(caps.includes?(Cap::Color16)).to be_true
      expect(caps.includes?(Cap::Italic)).to be_true
    end
  end

  describe "starting points" do
    it "clears everything with none" do
      expect(override("none").capabilities).to eq TermBuf::Capabilities::NONE
    end

    it "sets everything with all" do
      caps = override("all").capabilities

      expect(caps.includes?(Cap::TrueColor)).to be_true
      expect(caps.includes?(Cap::KittyGraphics)).to be_true
    end

    it "applies what follows a starting point" do
      caps = override("none,+color16").capabilities

      expect(caps.includes?(Cap::Color16)).to be_true
      expect(caps.includes?(Cap::Color256)).to be_false
    end

    it "applies a starting point that comes later, discarding what preceded it" do
      caps = override("+true_color,none").capabilities

      expect(caps.includes?(Cap::TrueColor)).to be_false
    end
  end

  describe "separators" do
    it "accepts commas" do
      caps = override("+true_color,-italic").capabilities

      expect(caps.includes?(Cap::TrueColor)).to be_true
      expect(caps.includes?(Cap::Italic)).to be_false
    end

    it "accepts whitespace" do
      caps = override("+true_color -italic").capabilities

      expect(caps.includes?(Cap::TrueColor)).to be_true
      expect(caps.includes?(Cap::Italic)).to be_false
    end

    it "ignores empty fields" do
      expect(override(",,+true_color,,").capabilities.includes?(Cap::TrueColor)).to be_true
    end
  end

  describe "an unknown name" do
    # A typo in an environment variable should not stop an application
    # starting, and it must not be written to a screen that is about to be
    # taken over.
    it "is reported rather than raised on" do
      result = override "+wishful_thinking"

      expect(result.warnings.size).to eq 1
      expect(result.warnings.first).to contain "wishful_thinking"
    end

    it "leaves the rest of the list working" do
      result = override "+wishful_thinking,+true_color"

      expect(result.capabilities.includes?(Cap::TrueColor)).to be_true
      expect(result.warnings.size).to eq 1
    end
  end

  describe "capping" do
    it "adds the narrower colour depths along with the broader one" do
      caps = override("none,+true_color").capabilities

      expect(caps.includes?(Cap::Color256)).to be_true
      expect(caps.includes?(Cap::Color16)).to be_true
    end

    it "removes the broader depths along with the narrower one" do
      caps = override("all,-color256").capabilities

      expect(caps.includes?(Cap::TrueColor)).to be_false
      expect(caps.includes?(Cap::Color16)).to be_true
    end
  end

  describe "reading the variable" do
    it "takes it from the environment by name" do
      result = TermBuf::CapabilityOverrides.apply TermBuf::Capabilities::NONE,
        {"TERMBUF_CAPS" => "+bold"}

      expect(result.capabilities.includes?(Cap::Bold)).to be_true
    end

    it "does nothing when the variable is absent" do
      result = TermBuf::CapabilityOverrides.apply TermBuf::Capabilities::ANSI,
        {} of String => String

      expect(result.capabilities).to eq TermBuf::Capabilities::ANSI
    end
  end
end

Spectator.describe TermBuf::ScreenSize do
  it "falls back to a size every terminal is at least as big as" do
    expect(TermBuf::ScreenSize::DEFAULT.columns).to eq 80
    expect(TermBuf::ScreenSize::DEFAULT.rows).to eq 24
  end

  it "rejects a size that is not positive" do
    expect { TermBuf::ScreenSize.new(0, 24) }.to raise_error(ArgumentError)
    expect { TermBuf::ScreenSize.new(80, -1) }.to raise_error(ArgumentError)
  end

  it "prints as a size" do
    expect(TermBuf::ScreenSize.new(120, 40).to_s).to eq "120x40"
  end
end

Spectator.describe TermBuf::SizeDetector do
  describe ".from_env" do
    it "reads COLUMNS and LINES" do
      size = TermBuf::SizeDetector.from_env({"COLUMNS" => "120", "LINES" => "40"})

      expect(size).to eq TermBuf::ScreenSize.new(120, 40)
    end

    it "needs both to be set" do
      expect(TermBuf::SizeDetector.from_env({"COLUMNS" => "120"})).to be_nil
      expect(TermBuf::SizeDetector.from_env({"LINES" => "40"})).to be_nil
    end

    it "ignores values that are not sizes" do
      expect(TermBuf::SizeDetector.from_env({"COLUMNS" => "wide", "LINES" => "40"})).to be_nil
      expect(TermBuf::SizeDetector.from_env({"COLUMNS" => "0", "LINES" => "40"})).to be_nil
      expect(TermBuf::SizeDetector.from_env({"COLUMNS" => "-1", "LINES" => "40"})).to be_nil
    end
  end

  describe ".detect" do
    it "always comes back with a size" do
      size = TermBuf::SizeDetector.detect env: {} of String => String

      expect(size.columns).to be > 0
      expect(size.rows).to be > 0
    end
  end
end
