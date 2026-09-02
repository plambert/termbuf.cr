require "../spec_helper"

private alias Uni = TermBuf::Unicode

Spectator.describe TermBuf::Unicode do
  describe ".graphemes" do
    it "returns nothing for an empty string" do
      expect(Uni.graphemes("")).to be_empty
    end

    it "splits plain ASCII one character per cluster" do
      expect(Uni.graphemes("hello")).to eq ["h", "e", "l", "l", "o"]
    end

    it "keeps a combining mark with its base character" do
      expect(Uni.graphemes("é")).to eq ["é"]
      expect(Uni.graphemes("aéb")).to eq ["a", "é", "b"]
    end

    it "keeps a run of combining marks with one base character" do
      expect(Uni.graphemes("á̂̃")).to eq ["á̂̃"]
    end

    it "leaves a leading combining mark as its own cluster" do
      expect(Uni.graphemes("́a")).to eq ["́", "a"]
    end

    it "keeps CR LF together but splits LF CR" do
      expect(Uni.graphemes("\r\n")).to eq ["\r\n"]
      expect(Uni.graphemes("\n\r")).to eq ["\n", "\r"]
      expect(Uni.graphemes("a\r\nb")).to eq ["a", "\r\n", "b"]
    end

    it "never attaches anything to a control character" do
      expect(Uni.graphemes("a́")).to eq ["a", "", "́"]
    end

    it "joins emoji sequences across a zero width joiner" do
      family = "\u{1F468}‍\u{1F469}‍\u{1F467}"

      expect(Uni.graphemes(family)).to eq [family]
    end

    it "does not join non-pictographs across a zero width joiner" do
      expect(Uni.graphemes("a‍b")).to eq ["a‍", "b"]
    end

    it "pairs regional indicators into flags" do
      united_states = "\u{1F1FA}\u{1F1F8}"
      germany = "\u{1F1E9}\u{1F1EA}"

      expect(Uni.graphemes(united_states + germany)).to eq [united_states, germany]
    end

    it "leaves an odd regional indicator on its own" do
      expect(Uni.graphemes("\u{1F1FA}\u{1F1F8}\u{1F1E9}"))
        .to eq ["\u{1F1FA}\u{1F1F8}", "\u{1F1E9}"]
    end

    it "does not let a preceding letter change regional indicator pairing" do
      expect(Uni.graphemes("a\u{1F1FA}\u{1F1F8}")).to eq ["a", "\u{1F1FA}\u{1F1F8}"]
    end

    it "assembles Hangul jamo into syllables" do
      expect(Uni.graphemes("각")).to eq ["각"]
    end

    it "keeps an Indic conjunct whole across the virama" do
      # devanagari ka + virama + devanagari ssa, joined by rule GB9c
      expect(Uni.graphemes("क्ष")).to eq ["क्ष"]
    end

    it "attaches a spacing mark to its base" do
      expect(Uni.graphemes("कः")).to eq ["कः"]
    end

    it "attaches a prepend character to what follows" do
      expect(Uni.graphemes("؀क")).to eq ["؀क"]
    end

    it "keeps a variation selector with its base" do
      expect(Uni.graphemes("☀️")).to eq ["☀️"]
    end
  end

  describe ".string_width" do
    it "counts one cell per ASCII character" do
      expect(Uni.string_width("hello")).to eq 5
    end

    it "counts two cells per wide character" do
      expect(Uni.string_width("漢字")).to eq 4
      expect(Uni.string_width("a漢b")).to eq 4
    end

    it "counts a base and its combining marks as one cell" do
      expect(Uni.string_width("é")).to eq 1
      expect(Uni.string_width("á̂̃")).to eq 1
    end

    it "gives a spacing mark a cell of its own" do
      # A spacing mark sits beside its base rather than over it, so unlike a
      # nonspacing mark it adds to the width of the cluster.
      expect(Uni.string_width("\u{0BA8}\u{0BBF}")).to eq 2 # tamil na, vowel sign i
      expect(Uni.string_width("\u{0915}\u{0940}")).to eq 2 # devanagari ka, vowel sign ii
      expect(Uni.string_width("\u{0E01}\u{0E33}")).to eq 2 # thai ko kai, sara am
    end

    it "counts an indic conjunct as two cells" do
      # The consonants ligate into one glyph and both terminals measured give
      # that glyph two columns, whatever the consonant it opens with is worth
      # alone. A spacing vowel after it adds nothing, since two cells is as
      # much as a cluster gets.
      expect(Uni.string_width("\u{0915}\u{094D}\u{0937}")).to eq 2 # devanagari
      expect(Uni.string_width("\u{0915}\u{094D}\u{0937}\u{093F}")).to eq 2
      expect(Uni.string_width("\u{0995}\u{09CD}\u{09B7}")).to eq 2 # bengali
      expect(Uni.string_width("\u{0C15}\u{0C4D}\u{0C37}")).to eq 2 # telugu
    end

    it "keeps a cluster to a pair of cells however many marks it carries" do
      expect(Uni.string_width("\u{0915}\u{093F}\u{0940}")).to eq 2
    end

    it "counts a zero width joiner sequence as one emoji" do
      expect(Uni.string_width("\u{1F468}‍\u{1F469}‍\u{1F467}")).to eq 2
    end

    it "counts a flag as one emoji" do
      expect(Uni.string_width("\u{1F1FA}\u{1F1F8}")).to eq 2
    end

    it "counts nothing for zero width characters" do
      expect(Uni.string_width("​")).to eq 0
      expect(Uni.string_width("")).to eq 0
    end

    it "widens a text pictograph carrying emoji presentation" do
      expect(Uni.string_width("☀")).to eq 1  # sun, text presentation
      expect(Uni.string_width("☀️")).to eq 2 # sun, emoji presentation
    end

    it "narrows an emoji carrying text presentation" do
      expect(Uni.string_width("\u{231A}")).to eq 2         # watch, emoji presentation
      expect(Uni.string_width("\u{231A}\u{FE0E}")).to eq 1 # forced to text
    end

    it "leaves a pictograph alone when it has neither variation selector" do
      expect(Uni.string_width("\u{1F5FA}")).to eq 1 # world map, no default presentation
    end

    it "widens only a base that is an emoji, not merely a pictograph" do
      # `⚑` is Extended_Pictographic and is not an emoji, so a selector asks it
      # for a presentation it has not got. Terminal.app and Ghostty both give it
      # one column; a selector on a base that is an emoji gets two.
      expect(Uni.string_width("\u{2691}\u{FE0F}")).to eq 1
      expect(Uni.string_width("\u{2764}\u{FE0F}")).to eq 2
    end

    it "counts a joined emoji sequence as two cells whatever it opens with" do
      # The weight lifter is East Asian Neutral, so taking the cluster's width
      # from its first code point gave one. Ghostty and kitty draw two, and
      # agree on two for every joined sequence in the survey.
      expect(Uni.string_width("\u{1F3CB}\u{1F3FB}\u{200D}\u{2640}\u{FE0F}")).to eq 2
      expect(Uni.string_width("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}")).to eq 2
    end

    it "leaves a joiner between two letters alone" do
      # Nothing pictographic, so the rule above has no business widening it.
      expect(Uni.string_width("a\u{200D}b")).to eq 2
    end

    it "counts a keycap sequence as two cells" do
      # The digit is an emoji and is not a pictograph, which is why this needs
      # the Emoji property rather than Extended_Pictographic. Both terminals
      # measured give the sequence with the selector two columns.
      expect(Uni.string_width("1\u{FE0F}\u{20E3}")).to eq 2
      expect(Uni.string_width("1\u{20E3}")).to eq 1 # no selector, no keycap
    end
  end

  describe ".each_grapheme" do
    it "reports byte offsets that slice the source string back out" do
      source = "a漢\u{1F1FA}\u{1F1F8}b"
      pieces = [] of String

      Uni.each_grapheme(source) do |grapheme|
        pieces << source.byte_slice(grapheme.start, grapheme.bytesize)
      end

      expect(pieces).to eq ["a", "漢", "\u{1F1FA}\u{1F1F8}", "b"]
    end

    it "reports the single character of a one code point cluster" do
      chars = [] of Char?
      Uni.each_grapheme("ab́") { |grapheme| chars << grapheme.char }

      expect(chars).to eq ['a', nil]
    end

    it "covers the source string exactly once, with no gaps or overlaps" do
      source = "á漢\r\n\u{1F468}‍\u{1F469}z"
      offset = 0

      Uni.each_grapheme(source) do |grapheme|
        expect(grapheme.start).to eq offset
        offset += grapheme.bytesize
      end

      expect(offset).to eq source.bytesize
    end

    it "takes the ASCII fast path without corrupting later break decisions" do
      # The fast path skips the break state machine; the combining mark that
      # follows the ASCII run still has to attach to the character before it.
      expect(Uni.graphemes("abcdé")).to eq ["a", "b", "c", "d", "é"]
      expect(Uni.graphemes("abc\r\n")).to eq ["a", "b", "c", "\r\n"]
      expect(Uni.graphemes("ab\u{1F1FA}\u{1F1F8}")).to eq ["a", "b", "\u{1F1FA}\u{1F1F8}"]
    end
  end
end
