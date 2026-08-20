require "../spec_helper"

# Golden byte strings. The round trip spec establishes that a paint is
# *correct*; these establish that it is *short*, which no round trip can see.
# They are meant to be brittle: a change here should be a deliberate decision
# about output size, not something that slips through.
private def encoder(capabilities = TermBuf::Capabilities::MODERN,
                    styles = TermBuf::StyleTable.new,
                    width = 80, height = 24) : TermBuf::Encoder
  TermBuf::Encoder.new styles, capabilities, width, height
end

private def emit(encoder : TermBuf::Encoder, *ops : TermBuf::Op) : String
  encoder.encode ops.to_a
end

Spectator.describe TermBuf::Encoder do
  describe "cursor movement" do
    it "uses an absolute move when the position is unknown" do
      expect(emit(encoder, TermBuf::Ops::MoveTo.new(0, 0))).to eq "\e[1;1H"
    end

    it "emits nothing to stay put" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(4, 2)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(4, 2))).to eq ""
    end

    it "uses a carriage return to reach the left margin" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(9, 0)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(0, 0))).to eq "\r"
    end

    it "leaves the count off a move of one" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(5, 0)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(6, 0))).to eq "\e[C"
    end

    it "uses a relative move forward" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(5, 0)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(10, 0))).to eq "\e[5C"
    end

    it "backspaces rather than emitting a longer relative move" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(6, 0)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(3, 0))).to eq "\b\b\b"
    end

    it "moves vertically when the column is unchanged" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(0, 0)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(0, 5))).to eq "\e[5B"
    end

    it "falls back to an absolute move when both axes change" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(0, 0)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(40, 12))).to eq "\e[13;41H"
    end

    it "tracks the cursor across written text" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(0, 0), TermBuf::Ops::PutText.new("abcde", 5)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(5, 0))).to eq ""
    end

    it "knows the margins home the cursor" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(10, 10), TermBuf::Ops::SetScrollRegion.new(1, 4)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(0, 0))).to eq ""
    end

    it "re-establishes the cursor after passthrough bytes" do
      subject = encoder
      emit subject, TermBuf::Ops::MoveTo.new(3, 3)
      emit subject, TermBuf::Ops::Raw.new("x".to_slice)

      expect(emit(subject, TermBuf::Ops::MoveTo.new(3, 3))).to eq "\e[4;4H"
    end
  end

  describe "style" do
    it "emits a full sequence when nothing is in force" do
      styles = TermBuf::StyleTable.new
      red = styles.id TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED)

      expect(emit(encoder(styles: styles), TermBuf::Ops::SetStyle.new(red))).to eq "\e[0;31m"
    end

    it "emits a delta when it is shorter than starting over" do
      styles = TermBuf::StyleTable.new
      red = styles.id TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED)
      bold_red = styles.id TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED).bold
      subject = encoder styles: styles

      emit subject, TermBuf::Ops::SetStyle.new(red)

      expect(emit(subject, TermBuf::Ops::SetStyle.new(bold_red))).to eq "\e[1m"
    end

    it "emits nothing for a style already in force" do
      styles = TermBuf::StyleTable.new
      red = styles.id TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED)
      subject = encoder styles: styles

      emit subject, TermBuf::Ops::SetStyle.new(red)

      expect(emit(subject, TermBuf::Ops::SetStyle.new(red))).to eq ""
    end

    it "emits nothing for a different style the terminal renders the same way" do
      styles = TermBuf::StyleTable.new
      curly = styles.id TermBuf::Style::DEFAULT.underlined TermBuf::Underline::Curly
      dotted = styles.id TermBuf::Style::DEFAULT.underlined TermBuf::Underline::Dotted
      subject = encoder TermBuf::Capabilities::ANSI, styles

      emit subject, TermBuf::Ops::SetStyle.new(curly)

      expect(emit(subject, TermBuf::Ops::SetStyle.new(dotted))).to eq ""
    end

    # Bold and faint share the single reset 22, so dropping one means turning
    # both off and reasserting the survivor.
    it "turns bold and faint off together, then puts the survivor back" do
      styles = TermBuf::StyleTable.new
      base = TermBuf::Style::DEFAULT.italic.fg TermBuf::Color::RED
      both = styles.id base.bold.faint
      just_faint = styles.id base.faint
      subject = encoder styles: styles

      emit subject, TermBuf::Ops::SetStyle.new(both)

      expect(emit(subject, TermBuf::Ops::SetStyle.new(just_faint))).to eq "\e[22;2m"
    end

    it "starts over when a reset plus everything is shorter than the delta" do
      styles = TermBuf::StyleTable.new
      both = styles.id TermBuf::Style::DEFAULT.bold.faint
      just_faint = styles.id TermBuf::Style::DEFAULT.faint
      subject = encoder styles: styles

      emit subject, TermBuf::Ops::SetStyle.new(both)

      expect(emit(subject, TermBuf::Ops::SetStyle.new(just_faint))).to eq "\e[0;2m"
    end

    it "returns colours to the terminal's default rather than resetting" do
      styles = TermBuf::StyleTable.new
      colored = styles.id TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED).bold
      plain_bold = styles.id TermBuf::Style::DEFAULT.bold
      subject = encoder styles: styles

      emit subject, TermBuf::Ops::SetStyle.new(colored)

      expect(emit(subject, TermBuf::Ops::SetStyle.new(plain_bold))).to eq "\e[39m"
    end

    it "writes the extended underline styles with subparameters" do
      styles = TermBuf::StyleTable.new
      curly = styles.id TermBuf::Style::DEFAULT.underlined(TermBuf::Underline::Curly,
        TermBuf::Color::BLUE)

      expect(emit(encoder(styles: styles), TermBuf::Ops::SetStyle.new(curly)))
        .to eq "\e[0;4:3;58;5;4m"
    end
  end

  describe "colour under a narrower terminal" do
    it "keeps 24 bit colour when the terminal has it" do
      styles = TermBuf::StyleTable.new
      id = styles.id TermBuf::Style::DEFAULT.fg TermBuf::Color.rgb(10, 20, 30)

      expect(emit(encoder(TermBuf::Capabilities::MODERN, styles), TermBuf::Ops::SetStyle.new(id)))
        .to eq "\e[0;38;2;10;20;30m"
    end

    it "drops 24 bit colour into the palette" do
      styles = TermBuf::StyleTable.new
      id = styles.id TermBuf::Style::DEFAULT.fg TermBuf::Color.rgb(10, 20, 30)

      expect(emit(encoder(TermBuf::Capabilities::XTERM, styles), TermBuf::Ops::SetStyle.new(id)))
        .to eq "\e[0;38;5;233m"
    end

    it "drops the palette into the sixteen" do
      styles = TermBuf::StyleTable.new
      id = styles.id TermBuf::Style::DEFAULT.fg TermBuf::Color.rgb(10, 20, 30)

      expect(emit(encoder(TermBuf::Capabilities::ANSI, styles), TermBuf::Ops::SetStyle.new(id)))
        .to eq "\e[0;30m"
    end

    it "drops colour entirely when the terminal has none" do
      styles = TermBuf::StyleTable.new
      id = styles.id TermBuf::Style::DEFAULT.fg TermBuf::Color.rgb(10, 20, 30)

      expect(emit(encoder(TermBuf::Capabilities::NONE, styles), TermBuf::Ops::SetStyle.new(id)))
        .to eq "\e[0m"
    end

    it "uses the aixterm codes for bright colours" do
      styles = TermBuf::StyleTable.new
      id = styles.id TermBuf::Style::DEFAULT.fg TermBuf::Color::BRIGHT_CYAN

      expect(emit(encoder(TermBuf::Capabilities::XTERM, styles), TermBuf::Ops::SetStyle.new(id)))
        .to eq "\e[0;96m"
    end

    it "reaches a bright foreground through bold when they are unavailable" do
      styles = TermBuf::StyleTable.new
      id = styles.id TermBuf::Style::DEFAULT.fg TermBuf::Color::BRIGHT_CYAN

      expect(emit(encoder(TermBuf::Capabilities::ANSI, styles), TermBuf::Ops::SetStyle.new(id)))
        .to eq "\e[0;1;36m"
    end

    it "drops an underline colour the terminal cannot set" do
      styles = TermBuf::StyleTable.new
      id = styles.id TermBuf::Style::DEFAULT.underlined TermBuf::Underline::Curly,
        TermBuf::Color::RED

      expect(emit(encoder(TermBuf::Capabilities::XTERM, styles), TermBuf::Ops::SetStyle.new(id)))
        .to eq "\e[0;4m"
    end
  end

  describe "the rest of the vocabulary" do
    it "writes erases, scrolls, and modes" do
      subject = encoder
      subject.move_to 0, 0, IO::Memory.new

      expect(emit(subject, TermBuf::Ops::EraseInLine.new(TermBuf::Ops::EraseMode::ToEnd)))
        .to eq "\e[K"
      expect(emit(subject, TermBuf::Ops::EraseChars.new(4))).to eq "\e[4X"
      expect(emit(subject, TermBuf::Ops::EraseChars.new(1))).to eq "\e[X"
      expect(emit(subject, TermBuf::Ops::ScrollUp.new(2))).to eq "\e[2S"
      expect(emit(subject, TermBuf::Ops::ScrollUp.new(1))).to eq "\e[S"
      expect(emit(subject, TermBuf::Ops::ScrollDown.new(3))).to eq "\e[3T"
      expect(emit(subject, TermBuf::Ops::SetScrollRegion.new(1, 4))).to eq "\e[2;5r"
      expect(emit(subject, TermBuf::Ops::ResetScrollRegion.new)).to eq "\e[r"
      expect(emit(subject, TermBuf::Ops::SetAutowrap.new(false))).to eq "\e[?7l"
      expect(emit(subject, TermBuf::Ops::SetAutowrap.new(true))).to eq "\e[?7h"
      expect(emit(subject, TermBuf::Ops::SetCursorVisible.new(false))).to eq "\e[?25l"
    end

    it "wraps a frame only when the terminal can synchronize" do
      expect(emit(encoder, TermBuf::Ops::BeginSync.new)).to eq "\e[?2026h"
      expect(emit(encoder(TermBuf::Capabilities::XTERM), TermBuf::Ops::BeginSync.new)).to eq ""
    end
  end
end

Spectator.describe TermBuf::Capabilities do
  it "implies the narrower colour depths" do
    caps = TermBuf::Capabilities.new TermBuf::Capability::TrueColor

    expect(caps.includes?(TermBuf::Capability::Color256)).to be_true
    expect(caps.includes?(TermBuf::Capability::Color16)).to be_true
  end

  it "implies plain underline from the extended forms" do
    caps = TermBuf::Capabilities.new TermBuf::Capability::UnderlineColor

    expect(caps.includes?(TermBuf::Capability::Underline)).to be_true
  end

  it "clears what depended on a capability that is removed" do
    caps = TermBuf::Capabilities::MODERN.without TermBuf::Capability::Color256

    expect(caps.includes?(TermBuf::Capability::TrueColor)).to be_false
    expect(caps.includes?(TermBuf::Capability::Color16)).to be_true
  end

  it "clears every colour depth when the first is removed" do
    caps = TermBuf::Capabilities::MODERN.without TermBuf::Capability::Color16

    expect(caps.includes?(TermBuf::Capability::Color256)).to be_false
    expect(caps.includes?(TermBuf::Capability::TrueColor)).to be_false
  end
end
