require "../spec_helper"

private alias Cap = TermBuf::Capability

private def detect(env = {} of String => String) : TermBuf::Capabilities
  TermBuf::EnvironmentDetector.detect env
end

Spectator.describe TermBuf::EnvironmentDetector do
  describe "with nothing to go on" do
    it "assumes the terminal can do nothing" do
      expect(detect.flags).to eq Cap::None
    end

    it "assumes the same for a terminal nobody recognises" do
      expect(detect({"TERM" => "some-terminal-from-1987"}).flags).to eq Cap::None
    end

    it "gives a dumb terminal nothing, whatever else is set" do
      caps = detect({"TERM" => "dumb", "COLORTERM" => "truecolor"})

      expect(caps.includes?(Cap::TrueColor)).to be_false
      expect(caps.includes?(Cap::Color16)).to be_false
    end
  end

  describe "from TERM" do
    it "recognises the xterm family" do
      caps = detect({"TERM" => "xterm"})

      expect(caps.includes?(Cap::Color16)).to be_true
      expect(caps.includes?(Cap::Color256)).to be_false
    end

    it "reads a 256 colour suffix" do
      caps = detect({"TERM" => "xterm-256color"})

      expect(caps.includes?(Cap::Color256)).to be_true
      expect(caps.includes?(Cap::TrueColor)).to be_false
    end

    it "recognises kitty and its protocols" do
      caps = detect({"TERM" => "xterm-kitty"})

      expect(caps.includes?(Cap::TrueColor)).to be_true
      expect(caps.includes?(Cap::KittyGraphics)).to be_true
      expect(caps.includes?(Cap::KittyKeyboard)).to be_true
    end

    it "recognises other current terminals" do
      expect(detect({"TERM" => "alacritty"}).includes?(Cap::TrueColor)).to be_true
      expect(detect({"TERM" => "wezterm"}).includes?(Cap::KittyGraphics)).to be_true
      expect(detect({"TERM" => "foot"}).includes?(Cap::TrueColor)).to be_true
    end

    it "gives a plain vt100 no colour at all" do
      caps = detect({"TERM" => "vt100"})

      expect(caps.includes?(Cap::Color16)).to be_false
      expect(caps.includes?(Cap::ScrollRegion)).to be_true
    end
  end

  describe "from TERM_PROGRAM" do
    it "overrides a vaguer TERM" do
      caps = detect({"TERM" => "xterm-256color", "TERM_PROGRAM" => "ghostty"})

      expect(caps.includes?(Cap::TrueColor)).to be_true
      expect(caps.includes?(Cap::KittyGraphics)).to be_true
    end

    it "leaves blinking off a terminal that does not blink" do
      # Ghostty's own terminfo entry declares `blink`, and nothing on screen
      # blinks. Nothing can be asked about this, so the name is all there is.
      caps = detect({"TERM" => "xterm-ghostty"})

      expect(caps.includes?(Cap::Blink)).to be_false
      expect(caps.includes?(Cap::RapidBlink)).to be_false
    end

    it "keeps blinking off however vague TERM is" do
      # Composition is additive, so the xterm entry would otherwise hand back
      # what the ghostty entry left out.
      caps = detect({"TERM" => "xterm-256color", "TERM_PROGRAM" => "ghostty"})

      expect(caps.includes?(Cap::Blink)).to be_false
    end

    it "keeps blinking off when only the marker variable names the terminal" do
      caps = detect({"TERM" => "xterm-256color", "GHOSTTY_RESOURCES_DIR" => "/opt"})

      expect(caps.includes?(Cap::Blink)).to be_false
    end

    it "still blinks on a terminal that does" do
      expect(detect({"TERM" => "xterm-256color"}).includes?(Cap::Blink)).to be_true
    end

    it "stops Terminal.app at the 256 colour palette" do
      caps = detect({"TERM" => "xterm-256color", "TERM_PROGRAM" => "Apple_Terminal"})

      expect(caps.includes?(Cap::Color256)).to be_true
      expect(caps.includes?(Cap::TrueColor)).to be_false
      expect(caps.includes?(Cap::KittyGraphics)).to be_false
    end

    it "matches without regard to case" do
      expect(detect({"TERM_PROGRAM" => "WEZTERM"}).includes?(Cap::KittyGraphics)).to be_true
    end
  end

  describe "from COLORTERM" do
    it "adds 24 bit colour to a terminal that already has some" do
      caps = detect({"TERM" => "xterm-256color", "COLORTERM" => "truecolor"})

      expect(caps.includes?(Cap::TrueColor)).to be_true
    end

    it "accepts the other spelling" do
      expect(detect({"TERM" => "xterm", "COLORTERM" => "24bit"}).includes?(Cap::TrueColor)).to be_true
    end

    it "ignores a value that means nothing" do
      expect(detect({"TERM" => "xterm", "COLORTERM" => "yes"}).includes?(Cap::TrueColor)).to be_false
    end
  end

  describe "from a terminal's own marker variable" do
    it "recognises kitty by its window id" do
      caps = detect({"TERM" => "xterm", "KITTY_WINDOW_ID" => "1"})

      expect(caps.includes?(Cap::KittyGraphics)).to be_true
    end

    it "recognises wezterm by its pane id" do
      expect(detect({"TERM" => "xterm", "WEZTERM_PANE" => "0"}).includes?(Cap::TrueColor)).to be_true
    end

    it "ignores a marker set to nothing" do
      expect(detect({"TERM" => "xterm", "KITTY_WINDOW_ID" => ""}).includes?(Cap::KittyGraphics))
        .to be_false
    end

    it "reads a VTE version" do
      expect(detect({"TERM" => "xterm", "VTE_VERSION" => "6003"}).includes?(Cap::TrueColor)).to be_true
      expect(detect({"TERM" => "xterm", "VTE_VERSION" => "6003"}).includes?(Cap::Osc8Links)).to be_true
      expect(detect({"TERM" => "xterm", "VTE_VERSION" => "3400"}).includes?(Cap::TrueColor)).to be_false
    end
  end

  describe "under a multiplexer" do
    # tmux and screen sit in the middle and swallow what they do not
    # understand. The probe is what establishes whether anything got through.
    it "takes the kitty protocols off" do
      caps = detect({"TERM" => "xterm-kitty", "TMUX" => "/tmp/tmux-501/default,1,0"})

      expect(caps.includes?(Cap::KittyGraphics)).to be_false
      expect(caps.includes?(Cap::KittyKeyboard)).to be_false
      expect(caps.includes?(Cap::SynchronizedOutput)).to be_false
    end

    it "leaves colour alone" do
      caps = detect({"TERM" => "screen-256color", "COLORTERM" => "truecolor", "TMUX" => "/tmp/tmux-501/default,1,0"})

      expect(caps.includes?(Cap::TrueColor)).to be_true
    end

    it "notices screen from TERM alone" do
      caps = detect({"TERM" => "screen", "KITTY_WINDOW_ID" => "1"})

      expect(caps.includes?(Cap::KittyGraphics)).to be_false
    end
  end

  describe "NO_COLOR" do
    it "takes every colour capability off" do
      caps = detect({"TERM" => "xterm-kitty", "COLORTERM" => "truecolor", "NO_COLOR" => "1"})

      expect(caps.includes?(Cap::TrueColor)).to be_false
      expect(caps.includes?(Cap::Color256)).to be_false
      expect(caps.includes?(Cap::Color16)).to be_false
      expect(caps.includes?(Cap::UnderlineColor)).to be_false
    end

    it "leaves everything that is not colour" do
      caps = detect({"TERM" => "xterm-kitty", "NO_COLOR" => "1"})

      expect(caps.includes?(Cap::Bold)).to be_true
      expect(caps.includes?(Cap::ScrollRegion)).to be_true
    end

    it "does nothing when set to nothing, as the convention says" do
      caps = detect({"TERM" => "xterm-256color", "NO_COLOR" => ""})

      expect(caps.includes?(Cap::Color256)).to be_true
    end
  end
end
