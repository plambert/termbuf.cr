require "../spec_helper"

private alias Policy = TermBuf::Unicode::WidthPolicy

# Answers as a terminal with the given policy would give them: one cursor
# position report per sample, at the column that policy predicts.
private def replies(policy : Policy, count : Int32 = TermBuf::WidthProbe::SAMPLES.size) : String
  String.build do |io|
    TermBuf::WidthProbe::SAMPLES.first(count).each do |sample|
      io << "\e[1;" << TermBuf::Unicode.string_width(sample.text, policy) + 1 << "R"
    end
  end
end

private def probe(answers : String, base : Policy = Policy::DEFAULT,
                  timeout = 50.milliseconds) : {TermBuf::WidthProbe::Result, String}
  input = IO::Memory.new answers
  output = IO::Memory.new
  result = TermBuf::WidthProbe.new(input, output, timeout).probe base
  {result, output.to_s}
end

Spectator.describe TermBuf::WidthProbe do
  describe "#probe" do
    it "asks for a position report after every sample" do
      _, written = probe replies(Policy::DEFAULT)

      expect(written.scan("\e[6n").size).to eq TermBuf::WidthProbe::SAMPLES.size
    end

    # A sample the terminal measures generously would otherwise push the next
    # one along and spoil the reading after it.
    it "starts every sample at the left margin of its own row" do
      _, written = probe replies(Policy::DEFAULT)

      TermBuf::WidthProbe::SAMPLES.each_with_index do |_, index|
        expect(written).to contain "\e[#{index + 1};1H"
      end
    end

    it "reads back a terminal that agrees with the tables" do
      result, _ = probe replies(Policy::DEFAULT)

      expect(result.answered).to be_true
      expect(result.policy).to eq Policy::DEFAULT
      expect(result.disagreements).to be_empty
    end

    it "notices a terminal that does not collapse joined emoji" do
      wanted = Policy::DEFAULT.with "joined_emoji", false
      result, _ = probe replies(wanted)

      expect(result.policy.joined_emoji?).to be_false
      expect(result.policy).to eq wanted
      expect(result.disagreements).to be_empty
    end

    it "notices a terminal that ignores the emoji variation selector" do
      wanted = Policy::DEFAULT.with "emoji_presentation", false
      result, _ = probe replies(wanted)

      expect(result.policy.emoji_presentation?).to be_false
    end

    it "notices a terminal that gives a spacing mark no cell of its own" do
      wanted = Policy::DEFAULT.with "spacing_marks", false
      result, _ = probe replies(wanted)

      expect(result.policy.spacing_marks?).to be_false
    end

    it "notices a terminal configured for wide ambiguous characters" do
      wanted = Policy::DEFAULT.with "ambiguous_wide", true
      result, _ = probe replies(wanted)

      expect(result.policy.ambiguous).to eq 2
    end

    it "reads several rules off one round of answers" do
      wanted = Policy::DEFAULT
        .with("emoji_presentation", false)
        .with("spacing_marks", false)
        .with("ambiguous_wide", true)
      result, _ = probe replies(wanted)

      expect(result.policy).to eq wanted
    end

    # Terminal.app advances eleven columns for a four-face emoji, which no rule
    # here reaches. Saying so beats modelling it wrong.
    it "reports a measurement no rule explains" do
      answers = String.build do |io|
        TermBuf::WidthProbe::SAMPLES.each do |sample|
          io << (sample.rule == "joined_emoji" ? "\e[1;12R" : "\e[1;#{TermBuf::Unicode.string_width(sample.text) + 1}R")
        end
      end

      result, _ = probe answers
      left = result.disagreements

      expect(left.size).to eq 1
      expect(left.first.measured).to eq 11
      expect(left.first.sample.rule).to eq "joined_emoji"
    end

    it "keeps the tables when the terminal answers nothing" do
      result, _ = probe ""

      expect(result.answered).to be_false
      expect(result.policy).to eq Policy::DEFAULT
    end

    it "keeps a rule whose sample went unanswered" do
      result, _ = probe replies(Policy::DEFAULT, count: 2)

      expect(result.answered).to be_true
      expect(result.policy).to eq Policy::DEFAULT
    end

    # Someone typing while the application starts should not lose what they
    # typed.
    it "hands back keystrokes that arrived while it was asking" do
      answers = replies(Policy::DEFAULT).sub("\e[1;2R", "q\e[1;2R")
      result, _ = probe answers

      expect(String.new(result.input)).to eq "q"
    end
  end

  describe ".run" do
    it "clears the samples off the screen afterwards" do
      input = IO::Memory.new replies(Policy::DEFAULT)
      output = IO::Memory.new
      TermBuf::WidthProbe.run input, output, timeout: 50.milliseconds

      expect(output.to_s.ends_with? "\e[H\e[2J").to be_true
    end
  end
end

Spectator.describe TermBuf::Unicode::WidthOverrides do
  describe ".apply" do
    it "changes nothing when the variable is unset" do
      result = described_class.apply Policy::DEFAULT, nil

      expect(result.policy).to eq Policy::DEFAULT
      expect(result.probe).to be_true
      expect(result.warnings).to be_empty
    end

    it "turns rules off and on by name" do
      result = described_class.apply Policy::DEFAULT, "-joined_emoji,+ambiguous_wide"

      expect(result.policy.joined_emoji?).to be_false
      expect(result.policy.ambiguous).to eq 2
    end

    it "overrides what was measured" do
      measured = Policy::DEFAULT.with "spacing_marks", false
      result = described_class.apply measured, "+spacing_marks"

      expect(result.policy.spacing_marks?).to be_true
    end

    it "reports an unknown rule rather than raising on it" do
      result = described_class.apply Policy::DEFAULT, "+nonsense"

      expect(result.policy).to eq Policy::DEFAULT
      expect(result.warnings.size).to eq 1
    end
  end

  describe ".probe?" do
    it "says no only when the variable says off" do
      expect(described_class.probe? nil).to be_true
      expect(described_class.probe? "+ambiguous_wide").to be_true
      expect(described_class.probe? "off").to be_false
      expect(described_class.probe? "off,+ambiguous_wide").to be_false
    end
  end
end

Spectator.describe TermBuf::Unicode::WidthPolicy do
  it "measures a cluster by the rules it carries" do
    family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"

    expect(TermBuf::Unicode.string_width(family, Policy::DEFAULT)).to eq 2
    expect(TermBuf::Unicode.string_width(family, Policy::DEFAULT.with("joined_emoji", false))).to eq 8
  end

  it "lays a regional indicator pair end to end when told to" do
    flag = "\u{1F1FA}\u{1F1F8}"

    expect(TermBuf::Unicode.string_width(flag, Policy::DEFAULT)).to eq 2
    expect(TermBuf::Unicode.string_width(flag, Policy::DEFAULT.with("regional_indicators", false))).to eq 4
  end

  it "refuses an ambiguous width that is neither one nor two" do
    expect { Policy.new ambiguous: 3 }.to raise_error ArgumentError
  end

  it "prints the rules it carries" do
    expect(Policy::DEFAULT.to_s).to contain "+joined_emoji"
    expect(Policy::DEFAULT.with("joined_emoji", false).to_s).to contain "-joined_emoji"
  end
end
