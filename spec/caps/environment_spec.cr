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

    # Measured against ghostty 1.3.2: XTPUSHCOLORS and XTPOPCOLORS change
    # nothing, and an OSC 11 read back after push, set, and pop gives the value
    # that was set. Claiming the stack leaves the terminal recoloured after the
    # program has gone, which is the failure the gate exists to prevent.
    it "leaves the colour stack off a terminal that ignores it" do
      caps = detect({"TERM" => "xterm-ghostty"})

      expect(caps.includes?(Cap::KittyColorStack)).to be_false
      expect(caps.includes?(Cap::KittyGraphics)).to be_true
    end

    it "keeps the colour stack off however vague TERM is" do
      caps = detect({"TERM" => "xterm-256color", "TERM_PROGRAM" => "ghostty"})

      expect(caps.includes?(Cap::KittyColorStack)).to be_false
    end

    # Measured against kitty 0.48.2: SGR 53 leaves the text unmarked where SGR 4
    # underlines it, and kitty's terminfo declares no overline capability.
    it "leaves the overline off kitty, which does not draw one" do
      caps = detect({"TERM" => "xterm-kitty"})

      expect(caps.includes?(Cap::Overline)).to be_false
      expect(caps.includes?(Cap::Underline)).to be_true
    end

    # SGR 8 leaves the text visible on kitty 0.48.2, and its terminfo declares
    # no `invis` where ghostty's declares one.
    it "leaves conceal off kitty, which shows the text anyway" do
      caps = detect({"TERM" => "xterm-kitty"})

      expect(caps.includes?(Cap::Conceal)).to be_false
      expect(caps.includes?(Cap::Strike)).to be_true
    end

    it "still conceals on ghostty, which hides the text" do
      caps = detect({"TERM" => "xterm-ghostty"})

      expect(caps.includes?(Cap::Conceal)).to be_true
    end

    it "keeps the overline off kitty however vague TERM is" do
      caps = detect({"TERM" => "xterm-256color", "KITTY_WINDOW_ID" => "1"})

      expect(caps.includes?(Cap::Overline)).to be_false
    end

    it "still draws an overline on ghostty, which has one" do
      caps = detect({"TERM" => "xterm-ghostty"})

      expect(caps.includes?(Cap::Overline)).to be_true
    end

    # iTerm2 blinks, behind a per-profile `Blink Allowed` that ships off. A
    # capability is what the terminal can be asked to do, not how this machine
    # is set up, so the flag stays. SGR 6 blinks there at the same rate as SGR
    # 5, which is what the encoder's step down already produces.
    it "keeps blinking for iTerm2, which blinks when it is allowed to" do
      caps = detect({"TERM" => "xterm-256color", "TERM_PROGRAM" => "iTerm.app"})

      expect(caps.includes?(Cap::Blink)).to be_true
      expect(caps.includes?(Cap::RapidBlink)).to be_false
    end

    it "still keeps the colour stack for kitty, whose protocol it is" do
      caps = detect({"TERM" => "xterm-kitty"})

      expect(caps.includes?(Cap::KittyColorStack)).to be_true
    end

    it "keeps blinking off when only the marker variable names the terminal" do
      caps = detect({"TERM" => "xterm-256color", "GHOSTTY_RESOURCES_DIR" => "/opt"})

      expect(caps.includes?(Cap::Blink)).to be_false
    end

    it "still blinks on a terminal that does" do
      expect(detect({"TERM" => "xterm-256color"}).includes?(Cap::Blink)).to be_true
    end

    # Measured in Terminal.app 470.2: a 64 step ramp of one hue comes out
    # smooth, where the palette bands it. 24 bit colour arrived with the
    # version that ships on macOS Tahoe.
    it "gives a current Terminal.app 24 bit colour but no kitty protocol" do
      caps = detect({"TERM"                 => "xterm-256color",
                     "TERM_PROGRAM"         => "Apple_Terminal",
                     "TERM_PROGRAM_VERSION" => "470.2"})

      expect(caps.includes?(Cap::Color256)).to be_true
      expect(caps.includes?(Cap::TrueColor)).to be_true
      expect(caps.includes?(Cap::KittyGraphics)).to be_false
      expect(caps.includes?(Cap::Osc8Links)).to be_false
    end

    it "stops an earlier Terminal.app at the palette" do
      caps = detect({"TERM"                 => "xterm-256color",
                     "TERM_PROGRAM"         => "Apple_Terminal",
                     "TERM_PROGRAM_VERSION" => "455"})

      expect(caps.includes?(Cap::TrueColor)).to be_false
      expect(caps.includes?(Cap::Color256)).to be_true
    end

    it "takes the version at the boundary" do
      below = detect({"TERM_PROGRAM" => "Apple_Terminal", "TERM_PROGRAM_VERSION" => "463.99"})
      at = detect({"TERM_PROGRAM" => "Apple_Terminal", "TERM_PROGRAM_VERSION" => "464"})

      expect(below.includes?(Cap::TrueColor)).to be_false
      expect(at.includes?(Cap::TrueColor)).to be_true
    end

    # Worst case when there is nothing to go on: Terminal.app answers no query
    # that would settle it, so an unreadable version is treated as too old.
    it "assumes the palette when the version says nothing" do
      %w[nonsense].push("").each do |version|
        caps = detect({"TERM_PROGRAM" => "Apple_Terminal", "TERM_PROGRAM_VERSION" => version})

        expect(caps.includes?(Cap::TrueColor)).to be_false
      end

      expect(detect({"TERM_PROGRAM" => "Apple_Terminal"}).includes?(Cap::TrueColor)).to be_false
    end

    it "outranks a COLORTERM inherited from whatever opened the window" do
      caps = detect({"TERM"                 => "xterm-256color",
                     "TERM_PROGRAM"         => "Apple_Terminal",
                     "TERM_PROGRAM_VERSION" => "455",
                     "COLORTERM"            => "truecolor"})

      expect(caps.includes?(Cap::TrueColor)).to be_false
    end

    it "leaves COLORTERM alone for every other terminal" do
      expect(detect({"TERM" => "xterm", "COLORTERM" => "truecolor"}).includes?(Cap::TrueColor))
        .to be_true
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

  # OSC 52 answers nothing on a write, so there is no probe to settle this and
  # the table is all there is. These four document the write and ship it on;
  # xterm supports it and ships it off, which comes to the same thing.
  describe "the clipboard" do
    it "gives OSC 52 to the terminals that write the clipboard" do
      expect(detect({"TERM" => "xterm-kitty"}).includes?(Cap::Osc52Clipboard)).to be_true
      expect(detect({"TERM" => "xterm-ghostty"}).includes?(Cap::Osc52Clipboard)).to be_true
      expect(detect({"TERM" => "wezterm"}).includes?(Cap::Osc52Clipboard)).to be_true
      expect(detect({"TERM" => "foot"}).includes?(Cap::Osc52Clipboard)).to be_true
    end

    it "gives it to the same terminals by the name they call themselves" do
      expect(detect({"TERM_PROGRAM" => "ghostty"}).includes?(Cap::Osc52Clipboard)).to be_true
      expect(detect({"TERM_PROGRAM" => "WezTerm"}).includes?(Cap::Osc52Clipboard)).to be_true
      expect(detect({"KITTY_WINDOW_ID" => "1"}).includes?(Cap::Osc52Clipboard)).to be_true
    end

    it "withholds it from terminals that have not been shown to write" do
      expect(detect({"TERM" => "xterm-256color"}).includes?(Cap::Osc52Clipboard)).to be_false

      apple = detect({"TERM" => "xterm-256color", "TERM_PROGRAM" => "Apple_Terminal",
                      "TERM_PROGRAM_VERSION" => "470.2"})
      expect(apple.includes?(Cap::Osc52Clipboard)).to be_false
    end
  end

  # Starting one terminal from a shell that had another's environment leaves
  # the first one's marker behind. Terminal.app opened from ghostty came back
  # claiming the kitty graphics protocol and 24 bit colour.
  describe "when the terminal names itself" do
    # What Terminal.app 470.2 actually reports when opened from ghostty.
    let(inherited) do
      {"TERM"                  => "xterm-256color",
       "TERM_PROGRAM"          => "Apple_Terminal",
       "TERM_PROGRAM_VERSION"  => "470.2",
       "COLORTERM"             => "truecolor",
       "GHOSTTY_RESOURCES_DIR" => "/Applications/Ghostty.app/Contents/Resources/ghostty"}
    end

    it "ignores a marker left by whatever opened the window" do
      caps = detect inherited

      expect(caps.includes?(Cap::KittyGraphics)).to be_false
      expect(caps.includes?(Cap::KittyColorStack)).to be_false
      expect(caps.includes?(Cap::KittyKeyboard)).to be_false
      expect(caps.includes?(Cap::Osc8Links)).to be_false
      expect(caps.includes?(Cap::SynchronizedOutput)).to be_false
    end

    it "keeps what the named terminal does have" do
      caps = detect inherited

      expect(caps.includes?(Cap::Bold)).to be_true
      expect(caps.includes?(Cap::AltScreen)).to be_true
      expect(caps.includes?(Cap::BracketedPaste)).to be_true
      expect(caps.includes?(Cap::Color256)).to be_true
      # 470.2 is new enough for 24 bit colour; an older one would not be.
      expect(caps.includes?(Cap::TrueColor)).to be_true
    end

    # The 256colour TERM pattern would otherwise put it back.
    it "takes strike-through off Terminal.app whatever TERM says" do
      expect(detect(inherited).includes?(Cap::Strike)).to be_false
      expect(detect({"TERM" => "xterm-256color"}).includes?(Cap::Strike)).to be_true
    end

    # Blink comes off under ghostty. Inheriting ghostty's marker must not take
    # it off a terminal that has it, any more than it adds kitty graphics.
    it "does not carry the other terminal's denials either" do
      expect(detect(inherited).includes?(Cap::Blink)).to be_true
    end

    it "keeps a marker the named terminal set itself" do
      caps = detect({"TERM"                  => "xterm-256color",
                     "TERM_PROGRAM"          => "ghostty",
                     "GHOSTTY_RESOURCES_DIR" => "/x"})

      expect(caps.includes?(Cap::KittyGraphics)).to be_true
      expect(caps.includes?(Cap::Blink)).to be_false
    end

    it "still trusts a marker when nothing names the terminal" do
      caps = detect({"TERM" => "xterm-256color", "GHOSTTY_RESOURCES_DIR" => "/x"})

      expect(caps.includes?(Cap::KittyGraphics)).to be_true
      expect(caps.includes?(Cap::Blink)).to be_false
    end

    it "still trusts a marker when TERM_PROGRAM names nothing it knows" do
      caps = detect({"TERM"         => "xterm-256color",
                     "TERM_PROGRAM" => "something-unheard-of",
                     "WEZTERM_PANE" => "0"})

      expect(caps.includes?(Cap::KittyGraphics)).to be_true
    end

    it "matches a marker to the terminal that names itself, whatever the case" do
      caps = detect({"TERM"         => "xterm-256color",
                     "TERM_PROGRAM" => "WezTerm",
                     "WEZTERM_PANE" => "0"})

      expect(caps.includes?(Cap::KittyGraphics)).to be_true
    end

    it "drops a foreign marker under any named terminal, not only Terminal.app" do
      caps = detect({"TERM"            => "xterm-256color",
                     "TERM_PROGRAM"    => "iTerm.app",
                     "KITTY_WINDOW_ID" => "1"})

      expect(caps.includes?(Cap::KittyGraphics)).to be_false
      expect(caps.includes?(Cap::TrueColor)).to be_true
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
