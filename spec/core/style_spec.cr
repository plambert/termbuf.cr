require "../spec_helper"

private alias Attr = TermBuf::Attributes

Spectator.describe TermBuf::Style do
  describe "defaults" do
    it "starts with everything at the terminal's own settings" do
      style = TermBuf::Style::DEFAULT

      expect(style.foreground.default?).to be_true
      expect(style.background.default?).to be_true
      expect(style.attributes.none?).to be_true
      expect(style.underline.none?).to be_true
      expect(style.link).to eq 0
      expect(style.default?).to be_true
    end
  end

  describe "#copy_with" do
    it "replaces only the named fields" do
      style = TermBuf::Style::DEFAULT.copy_with foreground: TermBuf::Color::RED

      expect(style.foreground).to eq TermBuf::Color::RED
      expect(style.background.default?).to be_true
      expect(style.default?).to be_false
    end
  end

  describe "attribute helpers" do
    it "adds flags without disturbing the others" do
      style = TermBuf::Style::DEFAULT.bold.italic

      expect(style.has?(Attr::Bold)).to be_true
      expect(style.has?(Attr::Italic)).to be_true
      expect(style.has?(Attr::Reverse)).to be_false
    end

    it "removes flags" do
      style = TermBuf::Style::DEFAULT.bold.italic.without Attr::Bold

      expect(style.has?(Attr::Bold)).to be_false
      expect(style.has?(Attr::Italic)).to be_true
    end

    it "picks the blink rate" do
      expect(TermBuf::Style::DEFAULT.blink.has?(Attr::SlowBlink)).to be_true
      expect(TermBuf::Style::DEFAULT.blink(rapid: true).has?(Attr::RapidBlink)).to be_true
    end

    it "sets colours" do
      style = TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED).bg(TermBuf::Color.rgb(1, 2, 3))

      expect(style.foreground).to eq TermBuf::Color::RED
      expect(style.background).to eq TermBuf::Color.rgb(1, 2, 3)
    end
  end

  describe "#underlined" do
    it "carries a style and a colour together" do
      style = TermBuf::Style::DEFAULT.underlined TermBuf::Underline::Curly, TermBuf::Color::RED

      expect(style.underline).to eq TermBuf::Underline::Curly
      expect(style.underline_color).to eq TermBuf::Color::RED
    end

    it "holds one underline style at a time, by construction" do
      style = TermBuf::Style::DEFAULT.underlined(TermBuf::Underline::Double)
        .underlined(TermBuf::Underline::Dotted)

      expect(style.underline).to eq TermBuf::Underline::Dotted
    end
  end

  describe "#ink?" do
    it "is false for a style that paints only its background" do
      expect(TermBuf::Style::DEFAULT.ink?).to be_false
      expect(TermBuf::Style::DEFAULT.bg(TermBuf::Color::BLUE).ink?).to be_false
      expect(TermBuf::Style::DEFAULT.bold.ink?).to be_false
    end

    it "is true once something would show through a blank cell" do
      expect(TermBuf::Style::DEFAULT.underlined.ink?).to be_true
      expect(TermBuf::Style::DEFAULT.reverse.ink?).to be_true
      expect(TermBuf::Style::DEFAULT.strike.ink?).to be_true
      expect(TermBuf::Style::DEFAULT.linked(7_u32).ink?).to be_true
    end
  end

  describe "value semantics" do
    it "compares and hashes by content, which is what interning needs" do
      first = TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED).bold
      second = TermBuf::Style::DEFAULT.bold.fg(TermBuf::Color::RED)

      expect(first).to eq second
      expect(first.hash).to eq second.hash
    end

    it "distinguishes styles that differ anywhere" do
      base = TermBuf::Style::DEFAULT.fg TermBuf::Color::RED

      expect(base).not_to eq base.bold
      expect(base).not_to eq base.bg(TermBuf::Color::BLUE)
      expect(base).not_to eq base.underlined
      expect(base).not_to eq base.linked(1_u32)
    end
  end
end

Spectator.describe TermBuf::StyleTable do
  subject(table) { TermBuf::StyleTable.new }

  it "assigns the default style id zero" do
    expect(table.id(TermBuf::Style::DEFAULT)).to eq TermBuf::StyleTable::DEFAULT
    expect(table[TermBuf::StyleTable::DEFAULT]).to eq TermBuf::Style::DEFAULT
    expect(table.size).to eq 1
  end

  it "hands the same id back for an equal style" do
    style = TermBuf::Style::DEFAULT.fg TermBuf::Color::RED

    first = table.id style
    second = table.id TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED)

    expect(second).to eq first
    expect(table.size).to eq 2
  end

  it "gives different styles different ids" do
    red = table.id TermBuf::Style::DEFAULT.fg(TermBuf::Color::RED)
    blue = table.id TermBuf::Style::DEFAULT.fg(TermBuf::Color::BLUE)

    expect(red).not_to eq blue
    expect(table[red].foreground).to eq TermBuf::Color::RED
    expect(table[blue].foreground).to eq TermBuf::Color::BLUE
  end

  it "reports nothing for an id it never assigned" do
    expect(table[99_u32]?).to be_nil
  end
end

Spectator.describe TermBuf::ClusterPool do
  subject(pool) { TermBuf::ClusterPool.new }

  it "reserves id zero for cells that need no cluster" do
    expect(pool[TermBuf::ClusterPool::NONE]).to eq ""
  end

  it "interns equal clusters to one id" do
    first = pool.id "é"
    second = pool.id "é"

    expect(second).to eq first
    expect(pool.size).to eq 2
    expect(pool[first]).to eq "é"
  end

  it "never assigns the none id to real text" do
    expect(pool.id("x")).not_to eq TermBuf::ClusterPool::NONE
  end
end
