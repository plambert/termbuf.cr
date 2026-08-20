require "../spec_helper"

private alias Kind = TermBuf::ResponseScanner::Kind

# Feeds *chunks* through one scanner and collects what it classified.
private def scan(*chunks : String) : Array({Kind, String})
  scanner = TermBuf::ResponseScanner.new
  result = [] of {Kind, String}

  chunks.each do |chunk|
    scanner.feed(chunk.to_slice) { |kind, bytes| result << {kind, String.new(bytes)} }
  end

  result
end

private def scan_and_flush(*chunks : String) : Array({Kind, String})
  scanner = TermBuf::ResponseScanner.new
  result = [] of {Kind, String}

  chunks.each do |chunk|
    scanner.feed(chunk.to_slice) { |kind, bytes| result << {kind, String.new(bytes)} }
  end

  scanner.flush { |kind, bytes| result << {kind, String.new(bytes)} }
  result
end

Spectator.describe TermBuf::ResponseScanner do
  describe "ordinary input" do
    it "passes plain text through" do
      expect(scan("hello")).to eq [{Kind::Text, "hello"}]
    end

    it "passes control characters through" do
      expect(scan("\r\n\t")).to eq [{Kind::Text, "\r\n\t"}]
    end

    it "yields nothing for nothing" do
      expect(scan("")).to be_empty
    end
  end

  describe "control sequences" do
    it "recognises a cursor position report" do
      expect(scan("\e[12;34R")).to eq [{Kind::Sequence, "\e[12;34R"}]
    end

    it "recognises a sequence with private and intermediate bytes" do
      expect(scan("\e[?2026;2$y")).to eq [{Kind::Sequence, "\e[?2026;2$y"}]
    end

    it "recognises a device attributes reply" do
      expect(scan("\e[?62;22c")).to eq [{Kind::Sequence, "\e[?62;22c"}]
    end

    it "ends a sequence at its first final byte" do
      expect(scan("\e[Ax")).to eq [{Kind::Sequence, "\e[A"}, {Kind::Text, "x"}]
    end
  end

  describe "string sequences" do
    it "recognises a device control string" do
      expect(scan("\eP>|kitty(0.32.2)\e\\"))
        .to eq [{Kind::Sequence, "\eP>|kitty(0.32.2)\e\\"}]
    end

    it "recognises an application programming command" do
      expect(scan("\e_Gi=31;OK\e\\")).to eq [{Kind::Sequence, "\e_Gi=31;OK\e\\"}]
    end

    it "recognises an operating system command ended by a string terminator" do
      expect(scan("\e]11;rgb:1/2/3\e\\")).to eq [{Kind::Sequence, "\e]11;rgb:1/2/3\e\\"}]
    end

    it "recognises an operating system command ended by a bell" do
      expect(scan("\e]11;rgb:1/2/3\a")).to eq [{Kind::Sequence, "\e]11;rgb:1/2/3\a"}]
    end

    it "does not end a device control string at a bell" do
      expect(scan("\ePa\ab\e\\")).to eq [{Kind::Sequence, "\ePa\ab\e\\"}]
    end
  end

  describe "short sequences" do
    it "recognises a single shift three key" do
      expect(scan("\eOP")).to eq [{Kind::Sequence, "\eOP"}]
    end

    it "recognises a two byte escape" do
      expect(scan("\eM")).to eq [{Kind::Sequence, "\eM"}]
    end

    # Two escapes are two presses of the escape key. Reading them as one two
    # byte sequence is how a pair of them turns into a single event.
    it "does not join two escapes into one sequence" do
      expect(scan("\e\e")).to eq [{Kind::Text, "\e"}]
      expect(scan("\e\e[A")).to eq [{Kind::Text, "\e"}, {Kind::Sequence, "\e[A"}]
    end
  end

  describe "mixed streams" do
    it "separates a reply from the keystrokes around it" do
      expect(scan("ab\e[3;4Rcd"))
        .to eq [{Kind::Text, "ab"}, {Kind::Sequence, "\e[3;4R"}, {Kind::Text, "cd"}]
    end

    it "handles several sequences back to back" do
      expect(scan("\e[?62c\e[?2026;2$y\e[1;1R")).to eq [
        {Kind::Sequence, "\e[?62c"},
        {Kind::Sequence, "\e[?2026;2$y"},
        {Kind::Sequence, "\e[1;1R"},
      ]
    end
  end

  describe "sequences split across reads" do
    it "waits for the rest of a control sequence" do
      expect(scan("\e[12", ";34R")).to eq [{Kind::Sequence, "\e[12;34R"}]
    end

    it "waits for the rest of a string sequence" do
      expect(scan("\eP>|kit", "ty\e", "\\")).to eq [{Kind::Sequence, "\eP>|kitty\e\\"}]
    end

    it "waits when only the escape has arrived" do
      expect(scan("\e")).to be_empty
    end

    it "reports whether it is holding anything back" do
      scanner = TermBuf::ResponseScanner.new

      expect(scanner.pending?).to be_false
      scanner.feed("\e[".to_slice) { }
      expect(scanner.pending?).to be_true
      scanner.feed("A".to_slice) { }
      expect(scanner.pending?).to be_false
    end

    it "holds a partial sequence back rather than guessing" do
      scanner = TermBuf::ResponseScanner.new
      seen = [] of String
      scanner.feed("\e[12".to_slice) { |_, bytes| seen << String.new(bytes) }

      expect(seen).to be_empty
      expect(String.new(scanner.pending)).to eq "\e[12"
    end

    it "yields input that arrived before an incomplete sequence" do
      expect(scan("ab\e[")).to eq [{Kind::Text, "ab"}]
    end
  end

  describe "#flush" do
    # A timeout means the rest of the sequence is not coming. What was held
    # back was a lone escape key, or something the terminal never finished.
    it "hands back a partial sequence as ordinary input" do
      expect(scan_and_flush("\e[12")).to eq [{Kind::Text, "\e[12"}]
    end

    it "hands back a lone escape as ordinary input" do
      expect(scan_and_flush("\e")).to eq [{Kind::Text, "\e"}]
    end

    it "has nothing to hand back when everything was complete" do
      expect(scan_and_flush("\e[1;1R")).to eq [{Kind::Sequence, "\e[1;1R"}]
    end
  end

  describe "runaway sequences" do
    # Without a bound, one escape byte with no final byte after it would hold
    # every later keystroke hostage for as long as the session lasted.
    it "gives up on a sequence that never ends and resumes after it" do
      runaway = "\e[" + ("1;" * 800)
      result = scan(runaway)

      expect(result.first[0]).to eq Kind::Text
      expect(result.first[1]).to eq "\e"
    end
  end
end
