require "../spec_helper"

private alias Prefix = TermBuf::Input::Prefix
private alias Sequence = TermBuf::Input::Sequence

private def sequence(text : String) : Sequence
  Sequence.parse text.to_slice
end

# A pattern that claims everything it is shown, which is what the old prefix
# and terminator registry did.
private def claim(patterns : TermBuf::Input::Patterns, prefix : String,
                  terminator : String) : TermBuf::Input::Pattern
  kind, head = Prefix.split prefix

  patterns.register(kind, head, terminator) do |claimed|
    TermBuf::Events::Response.new claimed.bytes
  end
end

private def claimed?(patterns : TermBuf::Input::Patterns, text : String) : Bool
  !patterns.match(sequence(text)).nil?
end

Spectator.describe TermBuf::Input::Sequence do
  it "splits a control sequence at its introducer" do
    parsed = sequence "\e[?2026;2$y"

    expect(parsed.prefix).to eq Prefix::CSI
    expect(parsed.body).to eq "?2026;2$y"
    expect(parsed.final).to eq 'y'
  end

  it "splits the keypad form" do
    parsed = sequence "\eOA"

    expect(parsed.prefix).to eq Prefix::SS3
    expect(parsed.body).to eq "A"
    expect(parsed.final).to eq 'A'
  end

  # A string sequence ends with `ST` or a bell, which names nothing, so there
  # is no final byte to report.
  it "names no final byte for a string sequence" do
    parsed = sequence "\e_Gi=1;OK\e\\"

    expect(parsed.prefix).to eq Prefix::APC
    expect(parsed.body).to eq "Gi=1;OK\e\\"
    expect(parsed.final).to be_nil
  end

  it "files a device control string and an operating system command apart" do
    expect(sequence("\eP>|ghostty\e\\").prefix).to eq Prefix::DCS
    expect(sequence("\e]11;rgb:00/00/00\a").prefix).to eq Prefix::OSC
  end

  # `ESC` and one byte is the alt form, and its introducer is the escape alone.
  it "treats anything else as an escape and one byte" do
    parsed = sequence "\ea"

    expect(parsed.prefix).to eq Prefix::Other
    expect(parsed.body).to eq "a"
    expect(parsed.final).to eq 'a'
  end
end

Spectator.describe TermBuf::Input::Prefix do
  it "splits a written prefix into an introducer and a head" do
    expect(Prefix.split("\e[")).to eq({Prefix::CSI, ""})
    expect(Prefix.split("\e[?")).to eq({Prefix::CSI, "?"})
    expect(Prefix.split("\e_G")).to eq({Prefix::APC, "G"})
    expect(Prefix.split("\eP")).to eq({Prefix::DCS, ""})
  end

  it "refuses an empty prefix" do
    expect { Prefix.split "" }.to raise_error(ArgumentError)
  end
end

Spectator.describe TermBuf::Input::Patterns do
  subject(patterns) { TermBuf::Input::Patterns.new }

  it "starts empty, so every sequence is a keystroke" do
    expect(patterns.empty?).to be_true
    expect(claimed?(patterns, "\e[A")).to be_false
  end

  it "matches on both ends" do
    claim patterns, "\e[?", "$y"

    expect(claimed?(patterns, "\e[?2026;2$y")).to be_true
    expect(claimed?(patterns, "\e[?2026;2c")).to be_false
    expect(claimed?(patterns, "\e[2026$y")).to be_false
  end

  # The two ends have to fit without overlapping, or `"\e["` would match a
  # pattern whose head and terminator are both `"\e["`.
  it "needs room for both ends" do
    claim patterns, "\e[", "R"
    expect(claimed?(patterns, "\e[R")).to be_true
    expect(claimed?(patterns, "\e[1;1R")).to be_true

    patterns.clear
    claim patterns, "\e[\e[", "\e["
    expect(claimed?(patterns, "\e[\e[")).to be_false
    expect(claimed?(patterns, "\e[\e[x\e[")).to be_true
  end

  it "matches any of several patterns" do
    claim patterns, "\e[?", "$y"
    claim patterns, "\eP", "\e\\"

    expect(claimed?(patterns, "\e[?2026;2$y")).to be_true
    expect(claimed?(patterns, "\eP>|ghostty\e\\")).to be_true
    expect(claimed?(patterns, "\e[A")).to be_false
  end

  it "tells one introducer from another" do
    claim patterns, "\e_G", "\e\\"

    expect(claimed?(patterns, "\e_Gi=1;OK\e\\")).to be_true
    expect(claimed?(patterns, "\eP_Gi=1;OK\e\\")).to be_false
  end

  it "forgets a pattern" do
    pattern = claim patterns, "\e[", "R"
    patterns.unregister pattern

    expect(claimed?(patterns, "\e[1;1R")).to be_false
    expect(patterns.empty?).to be_true
  end

  # Without a terminator a pattern is asking about everything under its
  # introducer, which is what a handler that decides for itself wants.
  it "matches on the head alone when there is no terminator" do
    patterns.register(Prefix::CSI, "<") do |claimed|
      TermBuf::Events::Warning.new claimed.body
    end

    expect(claimed?(patterns, "\e[<0;10;4M")).to be_true
    expect(claimed?(patterns, "\e[<0;10;4m")).to be_true
    expect(claimed?(patterns, "\e[0;10;4M")).to be_false
  end

  it "gives the first pattern that wants a sequence the sequence" do
    patterns.register(Prefix::CSI, terminator: "R") { nil }
    patterns.register(Prefix::CSI, terminator: "R") do |claimed|
      TermBuf::Events::Warning.new claimed.body
    end

    event = patterns.match sequence("\e[1;1R")
    expect(event).to be_a TermBuf::Events::Warning
    expect(event.as(TermBuf::Events::Warning).message).to eq "1;1R"
  end

  it "hands the whole sequence to the handler, introducer included" do
    patterns.register(Prefix::CSI, terminator: "R") do |claimed|
      TermBuf::Events::Response.new claimed.bytes
    end

    event = patterns.match sequence("\e[3;4R")
    expect(String.new(event.as(TermBuf::Events::Response).bytes)).to eq "\e[3;4R"
  end
end
