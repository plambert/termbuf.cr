require "../spec_helper"

private alias Cap = TermBuf::Capability

# Replies as the named terminals send them, in the order they arrive. The
# cursor position report is last in every case because it is last in the query
# batch, and it is what tells the prober everyone has finished answering.
private KITTY = "\e[?62;c" \
                "\e[>1;4000;29c" \
                "\eP>|kitty(0.32.2)\e\\" \
                "\eP1+r5463=787465726d2d6b697474790a\e\\" \
                "\e[?2026;2$y" \
                "\e[?2027;2$y" \
                "\e[?1004;2$y" \
                "\e[?1006;2$y" \
                "\e[?2004;2$y" \
                "\e[?0u" \
                "\e_Gi=31;OK\e\\" \
                "\e[1;1R"

private GHOSTTY = "\e[?62;22c" \
                  "\e[>1;1;0c" \
                  "\eP>|ghostty 1.0.1\e\\" \
                  "\e[?2026;2$y" \
                  "\e[?2027;2$y" \
                  "\e[?1004;2$y" \
                  "\e[?1006;2$y" \
                  "\e[?2004;2$y" \
                  "\e[?0u" \
                  "\e_Gi=31;OK\e\\" \
                  "\e[5;10R"

# xterm knows the mouse and paste modes and neither of the newer two, so it is
# the terminal that answers a mode report both ways in the same batch.
private XTERM = "\e[?63;1;2;4;6;9;15;22;29c" \
                "\e[>41;390;0c" \
                "\eP>|XTerm(390)\e\\" \
                "\eP0+r\e\\" \
                "\e[?2026;0$y" \
                "\e[?2027;0$y" \
                "\e[?1004;2$y" \
                "\e[?1006;2$y" \
                "\e[?2004;2$y" \
                "\e[2;5R"

# Terminal.app answers the two device attribute queries and the cursor
# position, and silently ignores everything newer.
private APPLE_TERMINAL = "\e[?1;2c" \
                         "\e[>1;95;0c" \
                         "\e[3;1R"

private def probe(replies : String, base = TermBuf::Capabilities::NONE,
                  timeout = 50.milliseconds) : {TermBuf::Prober::Result, String}
  input = IO::Memory.new replies
  output = IO::Memory.new
  result = TermBuf::Prober.new(input, output, timeout).probe base
  {result, output.to_s}
end

Spectator.describe TermBuf::Prober do
  describe "the query batch" do
    it "ends with a cursor position report, which every terminal answers" do
      _, queries = probe KITTY

      expect(queries.ends_with?("\e[6n")).to be_true
    end

    it "asks everything in one write" do
      _, queries = probe KITTY

      expect(queries).to contain "\e[c"
      expect(queries).to contain "\e[>c"
      expect(queries).to contain "\e[>0q"
      expect(queries).to contain "\e[?2026$p"
      expect(queries).to contain "\e[?2027$p"
      expect(queries).to contain "\e[?1004$p"
      expect(queries).to contain "\e[?1006$p"
      expect(queries).to contain "\e[?2004$p"
      expect(queries).to contain "\e[?u"
      expect(queries).to contain "\e_G"
    end

    it "asks about every mode it has a capability for" do
      _, queries = probe KITTY

      TermBuf::Prober::MODE_CAPABILITIES.each_key do |mode|
        expect(queries).to contain "\e[?#{mode}$p"
      end
    end

    # Mode 2027 changes how the terminal counts grapheme clusters, and the
    # widths this shard works from were measured with it off.
    it "asks about grapheme clusters without turning the mode on" do
      _, queries = probe KITTY

      expect(queries).not_to contain "\e[?2027h"
    end
  end

  describe "a terminal that answers everything" do
    it "reads kitty's capabilities off its replies" do
      result, _ = probe KITTY

      expect(result.capabilities.includes?(Cap::TrueColor)).to be_true
      expect(result.capabilities.includes?(Cap::SynchronizedOutput)).to be_true
      expect(result.capabilities.includes?(Cap::KittyKeyboard)).to be_true
      expect(result.capabilities.includes?(Cap::KittyGraphics)).to be_true
    end

    it "reads every mode it asked about off the reports" do
      result, _ = probe KITTY

      expect(result.capabilities.includes?(Cap::GraphemeClusters)).to be_true
      expect(result.capabilities.includes?(Cap::FocusEvents)).to be_true
      expect(result.capabilities.includes?(Cap::MouseSgr)).to be_true
      expect(result.capabilities.includes?(Cap::BracketedPaste)).to be_true
    end

    it "records each mode report as its own answered query" do
      result, _ = probe KITTY

      expect(result.answered).to contain :synchronized_output
      expect(result.answered).to contain :grapheme_clusters
      expect(result.answered).to contain :focus_events
      expect(result.answered).to contain :mouse_sgr
      expect(result.answered).to contain :bracketed_paste
    end

    it "reports the name the terminal gave for itself" do
      result, _ = probe KITTY

      expect(result.name).to eq "kitty(0.32.2)"
    end

    it "reads ghostty's capabilities off its replies" do
      result, _ = probe GHOSTTY

      expect(result.name).to eq "ghostty 1.0.1"
      expect(result.capabilities.includes?(Cap::KittyGraphics)).to be_true
      expect(result.capabilities.includes?(Cap::SynchronizedOutput)).to be_true
    end

    it "takes blinking back off when the terminal names itself" do
      # The environment said xterm, which blinks; XTVERSION said ghostty,
      # which does not, and the terminal naming itself is the better evidence.
      result, _ = probe GHOSTTY, base: TermBuf::Capabilities::XTERM

      expect(result.capabilities.includes?(Cap::Blink)).to be_false
    end

    it "records which queries came back" do
      result, _ = probe GHOSTTY

      expect(result.answered).to contain :primary_attributes
      expect(result.answered).to contain :xtversion
      expect(result.answered).to contain :kitty_graphics
      expect(result.answered).to contain :cursor_position
    end

    it "picks the cursor position out of the sentinel for free" do
      result, _ = probe GHOSTTY

      expect(result.cursor).to eq({9, 4})
    end
  end

  describe "a terminal that answers some of it" do
    it "takes a refusal from XTGETTCAP as a refusal" do
      result, _ = probe XTERM

      expect(result.name).to eq "XTerm(390)"
      expect(result.answered).to contain :xtgettcap
      expect(result.capabilities.includes?(Cap::TrueColor)).to be_false
    end

    it "reads a zero from a mode report as unsupported, whichever mode it was" do
      result, _ = probe XTERM

      expect(result.capabilities.includes?(Cap::SynchronizedOutput)).to be_false
      expect(result.capabilities.includes?(Cap::GraphemeClusters)).to be_false
    end

    it "reads a two from a mode report as supported, whichever mode it was" do
      result, _ = probe XTERM

      expect(result.capabilities.includes?(Cap::FocusEvents)).to be_true
      expect(result.capabilities.includes?(Cap::MouseSgr)).to be_true
      expect(result.capabilities.includes?(Cap::BracketedPaste)).to be_true
    end

    it "adds nothing for the queries a terminal ignores" do
      result, _ = probe APPLE_TERMINAL

      expect(result.answered).to contain :primary_attributes
      expect(result.answered).to contain :cursor_position
      expect(result.answered).not_to contain :xtversion
      expect(result.capabilities.includes?(Cap::KittyGraphics)).to be_false
      expect(result.capabilities.includes?(Cap::SynchronizedOutput)).to be_false
    end

    it "leaves what the environment already established alone" do
      base = TermBuf::Capabilities::XTERM
      result, _ = probe APPLE_TERMINAL, base

      expect(result.capabilities.includes?(Cap::Color256)).to be_true
    end
  end

  describe "the mode reports" do
    it "sets grapheme clusters when the terminal has mode 2027" do
      result, _ = probe "\e[?2027;1$y\e[1;1R"

      expect(result.capabilities.includes?(Cap::GraphemeClusters)).to be_true
    end

    it "reads a permanently set mode as supported" do
      result, _ = probe "\e[?2004;3$y\e[1;1R"

      expect(result.capabilities.includes?(Cap::BracketedPaste)).to be_true
    end

    # 4 is permanently reset: the terminal knows the mode by number and will
    # never have it, which is a refusal rather than an admission.
    it "reads a permanently reset mode as unsupported" do
      result, _ = probe "\e[?2004;4$y\e[1;1R", base: TermBuf::Capabilities::MODERN

      expect(result.capabilities.includes?(Cap::BracketedPaste)).to be_false
    end

    # The name says what the family does; the mode report says what this
    # terminal does, and the specific answer wins.
    it "takes a capability back off a terminal that named itself into it" do
      result, _ = probe "\eP>|ghostty 1.0.1\e\\\e[?1006;0$y\e[1;1R"

      expect(result.name).to eq "ghostty 1.0.1"
      expect(result.capabilities.includes?(Cap::MouseSgr)).to be_false
    end

    it "takes it off whichever of the two replies arrived first" do
      result, _ = probe "\e[?1006;0$y\eP>|ghostty 1.0.1\e\\\e[1;1R"

      expect(result.capabilities.includes?(Cap::MouseSgr)).to be_false
    end

    it "takes a capability back off one the environment established" do
      result, _ = probe "\e[?2026;0$y\e[1;1R", base: TermBuf::Capabilities::MODERN

      expect(result.capabilities.includes?(Cap::SynchronizedOutput)).to be_false
    end

    it "ignores a report for a mode it never asked about" do
      result, _ = probe "\e[?1049;2$y\e[1;1R", base: TermBuf::Capabilities::ANSI

      expect(result.capabilities).to eq TermBuf::Capabilities::ANSI
      expect(result.answered).to contain :cursor_position
    end
  end

  describe "a terminal that answers nothing" do
    it "comes back with what it started with" do
      result, _ = probe "", TermBuf::Capabilities::ANSI

      expect(result.capabilities).to eq TermBuf::Capabilities::ANSI
      expect(result.answered).to be_empty
      expect(result.name).to be_nil
    end
  end

  describe "keystrokes arriving mid-probe" do
    # Someone typing while the application starts must not lose what they
    # typed, and their keystrokes must not be mistaken for replies.
    it "hands back what was typed before the replies" do
      result, _ = probe "hi\e[?62;c\e[1;1R"

      expect(String.new(result.input)).to eq "hi"
    end

    it "hands back what was typed between the replies" do
      result, _ = probe "\e[?62;c" + "abc" + "\e[1;1R"

      expect(String.new(result.input)).to eq "abc"
      expect(result.answered).to contain :cursor_position
    end

    it "hands back what was typed after the sentinel" do
      result, _ = probe "\e[?62;c\e[1;1R" + "xyz"

      expect(String.new(result.input)).to eq "xyz"
    end

    it "treats an unfinished sequence as a keystroke once time is up" do
      result, _ = probe "\e[1;1R\e["

      expect(String.new(result.input)).to eq "\e["
    end

    it "keeps a reply that a keystroke was interleaved around" do
      result, _ = probe "a\e[?2026;2$yb\e[1;1R"

      expect(String.new(result.input)).to eq "ab"
      expect(result.capabilities.includes?(Cap::SynchronizedOutput)).to be_true
    end
  end

  describe "a name that is recognised" do
    it "carries the same conclusions the environment variables would have" do
      # Reported by XTVERSION alone, with nothing else in the environment.
      result, _ = probe "\eP>|WezTerm 20240203\e\\\e[1;1R"

      expect(result.capabilities.includes?(Cap::KittyGraphics)).to be_true
      expect(result.capabilities.includes?(Cap::TrueColor)).to be_true
    end

    it "adds nothing for a name nobody knows" do
      result, _ = probe "\eP>|SomeTerminal(1)\e\\\e[1;1R"

      expect(result.name).to eq "SomeTerminal(1)"
      expect(result.capabilities).to eq TermBuf::Capabilities::NONE
    end
  end
end

Spectator.describe TermBuf::CapabilityResolver do
  it "runs the environment, then the probe, then the overrides" do
    env = {"TERM" => "xterm-256color"}
    result = TermBuf::CapabilityResolver.resolve env,
      IO::Memory.new(KITTY), IO::Memory.new, 50.milliseconds

    # The environment alone would have stopped at the 256 colour palette; the
    # probe found more.
    expect(result.capabilities.includes?(Cap::TrueColor)).to be_true
    expect(result.capabilities.includes?(Cap::KittyGraphics)).to be_true
    expect(result.probed).to be_true
    expect(result.name).to eq "kitty(0.32.2)"
  end

  it "lets the override have the last word over the probe" do
    env = {"TERM" => "xterm-256color", "TERMBUF_CAPS" => "-kitty_graphics,-true_color"}
    result = TermBuf::CapabilityResolver.resolve env,
      IO::Memory.new(KITTY), IO::Memory.new, 50.milliseconds

    expect(result.capabilities.includes?(Cap::KittyGraphics)).to be_false
    expect(result.capabilities.includes?(Cap::TrueColor)).to be_false
    expect(result.capabilities.includes?(Cap::Color256)).to be_true
  end

  it "skips the probe when there is nothing to probe" do
    result = TermBuf::CapabilityResolver.resolve({"TERM" => "xterm-256color"})

    expect(result.probed).to be_false
    expect(result.capabilities.includes?(Cap::Color256)).to be_true
    expect(result.input).to be_empty
  end

  it "carries warnings rather than printing them" do
    result = TermBuf::CapabilityResolver.resolve({"TERMBUF_CAPS" => "+nonsense"})

    expect(result.warnings.size).to eq 1
    expect(result.warnings.first).to contain "nonsense"
  end

  it "hands the keystrokes on to whoever reads input next" do
    result = TermBuf::CapabilityResolver.resolve({"TERM" => "xterm"},
      IO::Memory.new("q\e[1;1R"), IO::Memory.new, 50.milliseconds)

    expect(String.new(result.input)).to eq "q"
  end
end
