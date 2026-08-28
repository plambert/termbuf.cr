#!/usr/bin/env crystal
#
# Measures what a terminal *draws*, which no escape sequence reports.
#
#     crystal run scripts/measure_glyphs.cr -- tmp/glyphs
#
# `CPR` says how many columns a terminal counts for a cluster. It says nothing
# about how wide the glyph is painted, nor about where the pen lands after it,
# and on some terminals those are three different numbers: Terminal.app counts
# four columns for `🏳️‍🌈`, paints it across two, and moves the pen by one, so
# whatever comes next is drawn on top of the flag.
#
# The only instrument for the other two is the screen. This writes a page of
# samples, has the terminal photograph itself, and moves on to the next page.
# `scripts/read_glyphs.py` reads the columns back out of the pictures.
#
# Each sample takes two rows:
#
#     <cluster><pad spaces>|     the bar says where the pen ended up
#     <cluster>                  nothing follows, so the glyph is intact
#
# Terminal.app draws over a neighbouring cell without repainting it — that is
# why a period lands on top of a flag rather than replacing it — so there both
# measurements could come off the first row. A terminal that repaints a cell
# from its buffer would erase the part of the glyph that overhangs, and the
# first row would then measure the pen rather than the paint. The bare row does
# not depend on which kind it is.
#
# Run it in the terminal being measured, with the font small and the window
# large. It needs permission to record the screen, which it inherits from the
# terminal it is running in — so run it from that terminal rather than from
# somewhere else.
require "../src/termbuf"

# Columns of space between a sample and its bar. It has to clear the widest
# glyph anything might draw, because the reader takes the bar to be the
# rightmost ink on that row -- and a glyph's ink runs past whatever was drawn
# after it, which is how a period ends up sitting inside a flag. An uncomposed
# tag sequence is the longest thing here at seven code points.
PAD = 20

# A staircase of bars at the top of every page: one on each row, each a column
# further along. Consecutive steps give the width of a cell and the height of a
# row at the same time, averaged over the lot, so the geometry comes off the
# picture rather than out of a font metric nobody told us.

# Steps in the staircase. Enough to average over, few enough to leave the page
# mostly samples.
CALIBRATION_STEPS = 6

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

# Writes one page of samples and photographs it.
class Sheet
  getter written = [] of Sample

  def initialize(@terminal : TermBuf::Terminal, @bounds : String, @directory : String)
  end

  # Rows a page can hold: everything below the staircase, less one so a tall
  # glyph on the last row has somewhere to overhang.
  def capacity : Int32
    @terminal.size.rows - CALIBRATION_STEPS - 1
  end

  def draw(page : Array(Sample)) : Nil
    @written = page

    @terminal.batch do |screen|
      screen.clear
      CALIBRATION_STEPS.times { |step| screen.write_char step, step, '|' }

      page.each_with_index do |sample, index|
        row = CALIBRATION_STEPS + index * 2
        screen.write 0, row, "#{sample.text}#{" " * PAD}|"
        screen.write 0, row + 1, sample.text
      end
    end

    @terminal.paint
  end

  def photograph(number : Int32) : String
    path = File.join @directory, "page-#{number.to_s.rjust 2, '0'}.png"
    # Only the terminal's own window, not the screen it happens to be on.
    Process.run "screencapture", ["-x", "-R#{@bounds}", path]
    path
  end
end

# Where the window is, so the picture is of it and nothing else.
def window_bounds : String
  script = <<-APPLESCRIPT
    tell application "Terminal"
      set b to bounds of front window
      return (item 1 of b as text) & "," & (item 2 of b as text) & "," & \
             ((item 3 of b) - (item 1 of b) as text) & "," & \
             ((item 4 of b) - (item 2 of b) as text)
    end tell
    APPLESCRIPT

  output = IO::Memory.new
  Process.run "osascript", ["-e", script], output: output
  output.to_s.strip
end

directory = ARGV[0]? || "tmp/glyphs"
Dir.mkdir_p directory
bounds = window_bounds
abort "cannot find the terminal window; run this inside Terminal.app" if bounds.empty?

pages = [] of Array(Sample)
manifest = [] of String
rows_used = 0

TermBuf::Terminal.open do |terminal|
  sheet = Sheet.new terminal, bounds, directory
  remaining = samples
  page = 0
  rows_used = terminal.size.rows

  # Two rows a sample, so a page holds half what it looks like it might.
  per_page = Math.max sheet.capacity // 2, 1

  while remaining.present?
    taken = remaining[0, per_page]
    remaining = remaining[taken.size..]
    page += 1

    sheet.draw taken
    sleep 400.milliseconds
    sheet.photograph page
    sleep 200.milliseconds

    taken.each_with_index do |sample, index|
      manifest << [page, CALIBRATION_STEPS + index * 2,
                   sample.text.codepoints.map { |point| "%04X" % point }.join('+'),
                   sample.group, sample.note].join('\t')
    end

    pages << taken
  end
end

File.write File.join(directory, "manifest.tsv"),
  (["# pad=#{PAD} steps=#{CALIBRATION_STEPS} rows=#{rows_used}",
    "page\tbar_row\tcodepoints\tgroup\tnote"] + manifest).join('\n') + "\n"

puts "#{pages.sum &.size} samples over #{pages.size} pages in #{directory}"
puts "pad=#{PAD} steps=#{CALIBRATION_STEPS} rows=#{rows_used} bounds=#{bounds}"
puts "now: python3 scripts/read_glyphs.py #{directory}"
