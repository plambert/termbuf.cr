require "../spec_helper"

private alias Style = TermBuf::Style
private alias Color = TermBuf::Color
private alias Attrs = TermBuf::Attributes

# The style a sequence leaves in force, starting from *from*.
private def after(text : String, from : Style = Style::DEFAULT) : Style
  TermBuf::SgrScanner.new.scan(text.to_slice, from) { }
end

# The runs of text a scan yields, each with the style it was written in.
private def runs(text : String) : Array({String, Style})
  found = [] of {String, Style}
  TermBuf::SgrScanner.new.scan(text.to_slice, Style::DEFAULT) do |run, style|
    found << {run, style}
  end
  found
end

Spectator.describe TermBuf::SgrScanner do
  describe "attributes" do
    it "sets them" do
      expect(after("\e[1m").has?(Attrs::Bold)).to be_true
      expect(after("\e[3m").has?(Attrs::Italic)).to be_true
      expect(after("\e[7m").has?(Attrs::Reverse)).to be_true
      expect(after("\e[9m").has?(Attrs::Strike)).to be_true
      expect(after("\e[53m").has?(Attrs::Overline)).to be_true
    end

    it "clears them" do
      bold = Style::DEFAULT.bold.italic
      expect(after("\e[22m", bold).has?(Attrs::Bold)).to be_false
      expect(after("\e[22m", bold).has?(Attrs::Italic)).to be_true
      expect(after("\e[23m", bold).has?(Attrs::Italic)).to be_false
    end

    # One code often undoes more than one attribute, since the terminal only
    # ever had one way to say "not emphasised".
    it "clears both of a pair with the one code" do
      both = Style::DEFAULT.bold.faint
      expect(after("\e[22m", both)).to eq Style::DEFAULT

      blinking = Style::DEFAULT.blink.blink(rapid: true)
      expect(after("\e[25m", blinking)).to eq Style::DEFAULT
    end

    it "takes several in one sequence" do
      style = after "\e[1;3;4m"

      expect(style.has?(Attrs::Bold | Attrs::Italic)).to be_true
      expect(style.underline).to eq TermBuf::Underline::Single
    end

    it "resets on a zero, and on nothing at all" do
      loud = Style::DEFAULT.bold.fg Color.indexed(3)

      expect(after("\e[0m", loud)).to eq Style::DEFAULT
      expect(after("\e[m", loud)).to eq Style::DEFAULT
      expect(after("\e[;1m", loud).has?(Attrs::Bold)).to be_true
      expect(after("\e[;1m", loud).foreground).to eq Color.default
    end
  end

  describe "underlines" do
    it "reads the subparameter styles" do
      expect(after("\e[4:3m").underline).to eq TermBuf::Underline::Curly
      expect(after("\e[4:5m").underline).to eq TermBuf::Underline::Dashed
      expect(after("\e[4:0m").underline).to eq TermBuf::Underline::None
      expect(after("\e[21m").underline).to eq TermBuf::Underline::Double
    end

    it "colours them separately" do
      expect(after("\e[58;5;9m").underline_color).to eq Color.indexed(9)
      expect(after("\e[59m", Style::DEFAULT.underlined(color: Color.indexed(1)))
        .underline_color).to eq Color.default
    end
  end

  describe "colours" do
    it "reads the sixteen" do
      expect(after("\e[31m").foreground).to eq Color.indexed(1)
      expect(after("\e[44m").background).to eq Color.indexed(4)
      expect(after("\e[93m").foreground).to eq Color.indexed(11)
      expect(after("\e[105m").background).to eq Color.indexed(13)
      expect(after("\e[39m", Style::DEFAULT.fg(Color.indexed(1))).foreground).to eq Color.default
    end

    it "reads the palette" do
      expect(after("\e[38;5;208m").foreground).to eq Color.indexed(208)
      expect(after("\e[48;5;17m").background).to eq Color.indexed(17)
    end

    it "reads 24 bit colour in both of the forms terminals write" do
      expect(after("\e[38;2;10;20;30m").foreground).to eq Color.rgb(10, 20, 30)
      expect(after("\e[38:2::10:20:30m").foreground).to eq Color.rgb(10, 20, 30)
      expect(after("\e[38:2:10:20:30m").foreground).to eq Color.rgb(10, 20, 30)
    end

    it "carries on with what follows an extended colour" do
      style = after "\e[38;5;9;1m"

      expect(style.foreground).to eq Color.indexed(9)
      expect(style.has?(Attrs::Bold)).to be_true
    end
  end

  describe "text" do
    it "hands back the runs between the sequences" do
      expect(runs("\e[1mAB\e[0mcd").map &.first).to eq ["AB", "cd"]
    end

    it "gives each run the style in force when it was written" do
      found = runs "\e[1mAB\e[0mcd"

      expect(found[0][1].has?(Attrs::Bold)).to be_true
      expect(found[1][1]).to eq Style::DEFAULT
    end

    it "yields nothing for a sequence on its own" do
      expect(runs("\e[1m")).to be_empty
    end
  end

  describe "sequences it cannot use" do
    # A cell holds appearance and a character. Cursor movement and screen
    # clearing address the terminal, and the buffer already has its own idea of
    # both, so these are consumed and dropped rather than fought over.
    it "drops them without putting them in the text" do
      expect(runs("a\e[2Jb\e[H c").map &.first).to eq ["a", "b", " c"]
    end

    it "leaves the style alone" do
      expect(after("\e[2J\e[H\e]0;title\e\\", Style::DEFAULT.bold).has?(Attrs::Bold)).to be_true
    end
  end

  describe "sequences split across writes" do
    it "holds the pieces until the sequence is whole" do
      scanner = TermBuf::SgrScanner.new
      style = Style::DEFAULT
      found = [] of String

      style = scanner.scan("a\e[1".to_slice, style) { |run, _| found << run }
      expect(found).to eq ["a"]
      expect(scanner.pending?).to be_true
      expect(style.has?(Attrs::Bold)).to be_false

      style = scanner.scan("mb".to_slice, style) { |run, _| found << run }
      expect(found).to eq ["a", "b"]
      expect(style.has?(Attrs::Bold)).to be_true
    end
  end

  describe "codes it does not know" do
    it "ignores them rather than raising" do
      expect(after("\e[1;999;3m").has?(Attrs::Bold | Attrs::Italic)).to be_true
    end
  end
end
