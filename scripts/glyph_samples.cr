# The clusters both instruments measure, kept in one place so the counted width
# and the drawn width are answers about the same list.
#
# `scripts/measure_glyphs.cr` photographs these; `scripts/measure_columns.cr`
# asks the terminal what it charged for them. Neither number predicts the other,
# which is the point of measuring both.

record Sample, text : String, group : String, note : String

# Spread wide enough that a rule fitting all of it is probably the rule.
def samples : Array(Sample)
  list = [] of Sample
  add = ->(text : String, group : String, note : String) do
    list << Sample.new text, group, note
  end

  # The classes a width table already distinguishes, as a control: whatever is
  # measured here has to come out matching the tables or the instrument is
  # wrong.
  add.call "a", "single", "ascii"
  add.call "Ω", "single", "greek"
  add.call "ñ", "single", "latin-1 precomposed"
  add.call "→", "single", "east asian ambiguous"
  add.call "漢", "single", "east asian wide"
  add.call "Ａ", "single", "fullwidth"
  add.call "ｱ", "single", "halfwidth katakana"
  add.call "한", "single", "hangul syllable"
  add.call "█", "single", "block"
  add.call "─", "single", "box drawing"
  add.call "ﷺ", "single", "arabic ligature"

  # Emoji on their own, with and without the presentation property.
  add.call "👍", "emoji", "emoji presentation, wide"
  add.call "⌚", "emoji", "emoji presentation, wide"
  add.call "✅", "emoji", "emoji presentation, wide"
  add.call "☺", "emoji", "text presentation, narrow"
  add.call "❤", "emoji", "text presentation, narrow"
  add.call "🏳", "emoji", "no presentation, narrow"
  add.call "⚑", "emoji", "no presentation, narrow"

  # A variation selector on a base of each width, which is where a pen that
  # moves by less than the glyph is wide first showed up.
  add.call "☺️", "variation", "narrow base + VS16"
  add.call "❤️", "variation", "narrow base + VS16"
  add.call "🏳️", "variation", "narrow base + VS16"
  add.call "⚑️", "variation", "narrow base + VS16"
  add.call "👍️", "variation", "wide base + VS16"
  add.call "⌚️", "variation", "wide base + VS16"
  add.call "☺︎", "variation", "narrow base + VS15"
  add.call "👍︎", "variation", "wide base + VS15"

  # Joined sequences, sorted by the width of what they start with, since that
  # is the rule the singles suggest.
  add.call "👨‍👩", "joined", "wide first, two parts"
  add.call "👨‍👩‍👧", "joined", "wide first, three parts"
  add.call "👨‍👩‍👧‍👦", "joined", "wide first, four parts"
  add.call "👩‍💻", "joined", "wide first, two parts"
  add.call "👩‍🚀", "joined", "wide first, two parts"
  add.call "🏳️‍🌈", "joined", "narrow first, selector, two parts"
  add.call "🏳️‍⚧️", "joined", "narrow first, two selectors"
  add.call "❤️‍🔥", "joined", "narrow first, selector, two parts"
  add.call "👁️‍🗨️", "joined", "narrow first, two selectors"
  add.call "🐻‍❄️", "joined", "wide first, narrow second"
  add.call "a‍b", "joined", "letters either side of a joiner"
  add.call "‍", "joined", "a joiner on its own"

  # Modifiers and enclosures.
  add.call "👍\u{1F3FD}", "modifier", "skin tone"
  add.call "👩\u{1F3FF}‍💻", "modifier", "skin tone inside a joined pair"
  add.call "1⃣", "enclosing", "keycap without a selector"
  add.call "1️⃣", "enclosing", "keycap with a selector"
  add.call "a⃝", "enclosing", "combining enclosing circle"
  add.call "a҈", "enclosing", "combining cyrillic sign"

  # Regional indicators, one at a time, since they pair up on some terminals
  # and not on others.
  add.call "\u{1F1FA}", "flag", "one indicator"
  add.call "\u{1F1FA}\u{1F1F8}", "flag", "two indicators"
  add.call "\u{1F1FA}\u{1F1F8}\u{1F1EF}", "flag", "three indicators"
  add.call "\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}", "flag", "four indicators"
  add.call "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", "flag", "tag sequence"

  # Marks that take a cell of their own, and marks that do not.
  add.call "é", "marks", "one nonspacing mark"
  add.call "é̂", "marks", "two nonspacing marks"
  add.call "é̂̃̄", "marks", "four nonspacing marks"
  add.call "क्ष", "indic", "devanagari conjunct"
  add.call "क्षि", "indic", "conjunct plus a spacing vowel"
  add.call "कि", "indic", "consonant plus a spacing vowel"
  add.call "को", "indic", "consonant plus a two part vowel"
  add.call "நி", "indic", "tamil na plus a vowel"
  add.call "நோ", "indic", "tamil na plus a two part vowel"
  add.call "ক্ষ", "indic", "bengali conjunct"
  add.call "క్ష", "indic", "telugu conjunct"
  add.call "กำ", "thai", "ko kai plus sara am"
  add.call "กำำ", "thai", "ko kai plus two sara am"
  add.call "ก่", "thai", "ko kai plus a tone mark"
  add.call "กิ่", "thai", "ko kai, vowel, tone"
  add.call "ລາ", "lao", "lo loot plus a vowel"

  # Jamo, which compose into a syllable on a terminal that bothers.
  add.call "가", "hangul", "lead and vowel"
  add.call "각", "hangul", "lead, vowel and tail"

  list
end
