require "../spec_helper"

private alias Gcb = TermBuf::Unicode::Tables::Gcb
private alias Incb = TermBuf::Unicode::Tables::Incb
private alias Uni = TermBuf::Unicode

Spectator.describe TermBuf::Unicode do
  after_each { Uni.ambiguous_width = 1 }

  describe ".char_width" do
    it "reports one cell for printable ASCII" do
      expect(Uni.char_width('A')).to eq 1
      expect(Uni.char_width(' ')).to eq 1
      expect(Uni.char_width('~')).to eq 1
    end

    it "reports no cells for control characters" do
      expect(Uni.char_width('\u0000')).to eq 0
      expect(Uni.char_width('\n')).to eq 0
      expect(Uni.char_width('\e')).to eq 0
      expect(Uni.char_width('\u007F')).to eq 0
    end

    it "reports no cells for combining marks" do
      expect(Uni.char_width('\u0301')).to eq 0 # combining acute accent
      expect(Uni.char_width('\u0951')).to eq 0 # devanagari stress sign udatta
      expect(Uni.char_width('\u20DD')).to eq 0 # combining enclosing circle
    end

    it "reports no cells for format and default-ignorable characters" do
      expect(Uni.char_width('\u200B')).to eq 0 # zero width space
      expect(Uni.char_width('\u200D')).to eq 0 # zero width joiner
      expect(Uni.char_width('\uFE0F')).to eq 0 # variation selector 16
      expect(Uni.char_width('\u00AD')).to eq 0 # soft hyphen
    end

    it "reports two cells for East Asian Wide and Fullwidth characters" do
      expect(Uni.char_width('漢')).to eq 2
      expect(Uni.char_width('か')).to eq 2
      expect(Uni.char_width('한')).to eq 2
      expect(Uni.char_width('Ａ')).to eq 2 # fullwidth latin capital A
    end

    it "reports two cells for characters with emoji presentation" do
      expect(Uni.char_width('😀')).to eq 2
      expect(Uni.char_width('\u{1F1FA}')).to eq 2 # regional indicator symbol U
    end

    it "reports one cell for pictographs without emoji presentation" do
      expect(Uni.char_width('☀')).to eq 1 # black sun with rays
      expect(Uni.char_width('✂')).to eq 1 # black scissors
    end

    it "reports two cells for unassigned code points in the wide CJK planes" do
      expect(Uni.char_width('\u{2FFFD}')).to eq 2
      expect(Uni.char_width('\u{3FFFD}')).to eq 2
    end

    it "reports one cell for unassigned code points elsewhere" do
      expect(Uni.char_width('\u{50000}')).to eq 1
    end
  end

  describe ".ambiguous_width" do
    it "renders East Asian Ambiguous characters narrow by default" do
      expect(Uni.char_width('±')).to eq 1 # plus-minus sign
      expect(Uni.char_width('α')).to eq 1 # greek small alpha
    end

    it "renders them wide once the setting says so" do
      Uni.ambiguous_width = 2

      expect(Uni.char_width('±')).to eq 2
      expect(Uni.char_width('α')).to eq 2
    end

    it "does not widen ambiguous characters that are combining marks" do
      Uni.ambiguous_width = 2

      expect(Uni.char_width('\u0301')).to eq 0
    end

    it "does not narrow characters that are unconditionally wide" do
      Uni.ambiguous_width = 2

      expect(Uni.char_width('漢')).to eq 2
    end
  end

  describe ".properties" do
    # `FAST_LIMIT` is where the direct-indexed table gives way to the binary
    # search; both sides of that boundary have to resolve correctly.
    it "agrees across the fast table boundary" do
      expect(Uni.char_width('\u0FFF')).to eq 1 # last code point in the fast table
      expect(Uni.char_width('က')).to eq 1      # first code point that is searched
      expect(Uni.char_width('ᄀ')).to eq 2      # hangul choseong kiyeok, searched
    end

    it "resolves the extremes of the code point space" do
      expect(Uni.char_width('\u0000')).to eq 0
      expect(Uni.char_width(Char::MAX)).to eq 1
    end
  end

  describe ".grapheme_class" do
    it "classifies the characters the break rules depend on" do
      expect(Uni.grapheme_class('\r')).to eq Gcb::CR
      expect(Uni.grapheme_class('\n')).to eq Gcb::LF
      expect(Uni.grapheme_class('\u0007')).to eq Gcb::Control
      expect(Uni.grapheme_class('A')).to eq Gcb::Other
      expect(Uni.grapheme_class('\u0301')).to eq Gcb::Extend
      expect(Uni.grapheme_class('\u200D')).to eq Gcb::ZeroWidthJoiner
      expect(Uni.grapheme_class('\u{1F1FA}')).to eq Gcb::RegionalIndicator
      expect(Uni.grapheme_class('\u0600')).to eq Gcb::Prepend
      expect(Uni.grapheme_class('\u0903')).to eq Gcb::SpacingMark
      expect(Uni.grapheme_class('ᄀ')).to eq Gcb::HangulL
      expect(Uni.grapheme_class('\u1160')).to eq Gcb::HangulV
      expect(Uni.grapheme_class('\u11A8')).to eq Gcb::HangulT
    end
  end

  describe ".pictographic?" do
    it "is true for pictographs and false for ordinary text" do
      expect(Uni.pictographic?('😀')).to be_true
      expect(Uni.pictographic?('☀')).to be_true
      expect(Uni.pictographic?('A')).to be_false
      expect(Uni.pictographic?('漢')).to be_false
    end
  end

  describe ".conjunct_class" do
    it "identifies the pieces of an Indic conjunct" do
      expect(Uni.conjunct_class('क')).to eq Incb::Consonant   # devanagari ka
      expect(Uni.conjunct_class('\u094D')).to eq Incb::Linker # devanagari virama
      expect(Uni.conjunct_class('\u0300')).to eq Incb::Extend
      expect(Uni.conjunct_class('A')).to eq Incb::None
    end
  end

  describe ".ambiguous?" do
    it "distinguishes ambiguous characters from settled ones" do
      expect(Uni.ambiguous?('±')).to be_true
      expect(Uni.ambiguous?('A')).to be_false
      expect(Uni.ambiguous?('漢')).to be_false
    end
  end
end
