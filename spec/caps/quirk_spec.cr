require "../spec_helper"

private alias Uni = TermBuf::Unicode

private def quirks(env = {} of String => String) : TermBuf::Quirk
  TermBuf::EnvironmentDetector.quirks env
end

Spectator.describe TermBuf::Quirk do
  describe "detection" do
    it "finds none on a terminal nothing is known about" do
      expect(quirks).to eq TermBuf::Quirk::None
      expect(quirks({"TERM" => "xterm-256color"})).to eq TermBuf::Quirk::None
      expect(quirks({"TERM_PROGRAM" => "ghostty"})).to eq TermBuf::Quirk::None
    end

    it "finds Terminal.app counting columns per code point" do
      found = quirks({"TERM" => "xterm-256color", "TERM_PROGRAM" => "Apple_Terminal"})

      expect(found.per_code_point_columns?).to be_true
    end

    # The same identity rule the capabilities use: a marker left by whatever
    # opened the window says nothing about the terminal reading the output.
    it "does not blame a terminal for a marker it did not set" do
      found = quirks({"TERM_PROGRAM"          => "Apple_Terminal",
                      "GHOSTTY_RESOURCES_DIR" => "/x"})

      expect(found.per_code_point_columns?).to be_true
    end
  end

  describe "TERMBUF_QUIRKS" do
    private def applied(spec : String?, base = TermBuf::Quirk::None)
      TermBuf::QuirkOverrides.apply base, spec
    end

    it "changes nothing when it is unset or empty" do
      expect(applied(nil).quirks).to eq TermBuf::Quirk::None
      expect(applied("", TermBuf::Quirk::PerCodePointColumns).quirks)
        .to eq TermBuf::Quirk::PerCodePointColumns
    end

    it "turns one on by name" do
      expect(applied("per_code_point_columns").quirks.per_code_point_columns?).to be_true
      expect(applied("+per_code_point_columns").quirks.per_code_point_columns?).to be_true
    end

    it "turns one off" do
      result = applied "-per_code_point_columns", TermBuf::Quirk::PerCodePointColumns

      expect(result.quirks.per_code_point_columns?).to be_false
    end

    it "clears the lot" do
      expect(applied("none", TermBuf::Quirk::PerCodePointColumns).quirks)
        .to eq TermBuf::Quirk::None
    end

    it "reports a name it does not know rather than raising" do
      result = applied "+nonsense"

      expect(result.quirks).to eq TermBuf::Quirk::None
      expect(result.warnings.size).to eq 1
      expect(result.warnings.first).to contain "nonsense"
    end
  end
end

# What Terminal.app 470.2 answers, measured by cursor position report. The rule
# has to reproduce every one of these or it is not describing the terminal.
private MEASURED = [
  {"a", 1, "ascii"},
  {"漢", 2, "east asian wide"},
  {"Ａ", 2, "fullwidth"},
  {"한", 2, "hangul"},
  {"→", 1, "east asian ambiguous"},
  {"👍", 2, "emoji, wide on its own"},
  {"⌚", 2, "emoji, wide on its own"},
  {"☺", 1, "text presentation"},
  {"☺️", 1, "variation selector adds nothing"},
  {"❤️", 1, "variation selector adds nothing"},
  {"⌚️", 2, "variation selector on something already wide"},
  {"é", 1, "combining acute"},
  {"á̂̃", 1, "three combining marks"},
  {"👍\u{1F3FD}", 4, "skin tone is a character of its own"},
  {"👨‍👩", 5, "one joiner takes a column"},
  {"👨‍👩‍👧", 8, "two joiners"},
  {"👨‍👩‍👧‍👦", 11, "three joiners"},
  {"👩‍💻", 5, "joined pair"},
  {"🏳️‍🌈", 4, "flag, selector, joiner, rainbow"},
  {"a‍b", 3, "a joiner between two letters"},
  {"‍", 1, "a joiner on its own"},
  {"1⃣", 2, "enclosing keycap takes a column"},
  {"1️⃣", 2, "with the variation selector too"},
  {"a⃝", 2, "enclosing circle"},
  {"a҈", 2, "enclosing cyrillic sign"},
  {"\u{1F1FA}", 1, "one regional indicator"},
  {"🇺🇸", 2, "two regional indicators"},
  {"\u{1F1FA}\u{1F1F8}\u{1F1EF}", 3, "three regional indicators"},
  {"🇺🇸🇯🇵", 4, "four regional indicators"},
  {"क्षि", 3, "devanagari conjunct and vowel sign"},
  {"நி", 2, "tamil na and vowel sign"},
  {"กำ", 2, "thai ko kai and sara am"},
  {"กำำ", 3, "and a second sara am"},
  {"ﷺ", 1, "arabic ligature"},
]

Spectator.describe "Unicode.code_point_columns" do
  it "reproduces every column count measured in Terminal.app" do
    missed = MEASURED.reject { |(text, advance, _)| Uni.code_point_columns(text) == advance }
      .map { |(text, advance, about)| "#{about}: terminal #{advance}, rule #{Uni.code_point_columns(text)}" }

    expect(missed).to be_empty
  end

  it "differs from the cluster width exactly where the terminal misplaces things" do
    drifting = MEASURED.select { |(text, _, _)| Uni.code_point_columns(text) != Uni.string_width(text) }
      .map &.[](0)

    expect(drifting).to contain "👨‍👩‍👧‍👦"
    expect(drifting).to contain "🏳️‍🌈"
    expect(drifting).to contain "क्षि"
    expect(drifting).not_to contain "நி"
    expect(drifting).not_to contain "a"
  end

  it "takes the ambiguous width from the policy it is given" do
    wide = Uni::WidthPolicy::DEFAULT.copy_with ambiguous: 2

    expect(Uni.code_point_columns("→")).to eq 1
    expect(Uni.code_point_columns("→", wide)).to eq 2
  end

  it "counts an enclosing mark but not a nonspacing one" do
    expect(Uni.enclosing_mark?('\u20E3')).to be_true
    expect(Uni.enclosing_mark?('\u20DD')).to be_true
    expect(Uni.enclosing_mark?('\u0301')).to be_false
    expect(Uni.enclosing_mark?('a')).to be_false
    expect(Uni.enclosing_mark?('\uFE0F')).to be_false
  end
end
