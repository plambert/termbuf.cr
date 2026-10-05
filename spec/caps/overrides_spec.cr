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

    # Nothing puts these two on: no environment table claims them and no
    # detection ever will for the clipboard, so the variable is the only way in
    # and the names have to work.
    it "accepts a capability nothing detects" do
      expect(override("+grapheme_clusters").capabilities.includes?(Cap::GraphemeClusters))
        .to be_true
      expect(override("+osc52_clipboard").capabilities.includes?(Cap::Osc52Clipboard))
        .to be_true
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
