#!/usr/bin/env crystal
#
# Builds the survey corpus described in `measurements/SURVEY.md`.
#
#     crystal run scripts/gen_corpus.cr
#
# Writes `measurements/corpus.tsv`, which is committed so that every terminal
# measures an identical list and runs taken weeks apart stay comparable. Reads
# the UCD files `scripts/gen_unicode.cr` caches; run that first if `tmp/` is
# empty.
#
# The corpus is chosen to find the cases nobody thought of. Two of the three
# departures the counting model needed, and three of the five width table
# corrections, came from widening the sample set from forty-four clusters to
# sixty-seven — so most of this is generated from property tables rather than
# picked by hand, on the grounds that taste is what missed them the first time.
require "../src/termbuf"
require "./glyph_samples"

module GenCorpus
  UNICODE_VERSION = "16.0.0"
  CACHE_DIR       = "tmp/ucd-#{UNICODE_VERSION}"
  OUTPUT          = "measurements/corpus.tsv"

  # A cluster nothing may draw, and the widest one worth sending. Anything
  # carrying a control would derail the instrument rather than measure it, and
  # a cluster wider than this cannot be read back on a sane window.
  MAX_COLUMNS = 40

  record Entry, text : String, group : String, note : String

  # Viramas, and the block each one's consonants live in. Three of the five
  # width corrections were conjuncts and all three were the same shape, so
  # every script that builds them the same way is worth asking about.
  VIRAMAS = {
    {0x094D, 0x0915..0x0939, "devanagari"},
    {0x09CD, 0x0995..0x09B9, "bengali"},
    {0x0A4D, 0x0A15..0x0A39, "gurmukhi"},
    {0x0ACD, 0x0A95..0x0AB9, "gujarati"},
    {0x0B4D, 0x0B15..0x0B39, "oriya"},
    {0x0BCD, 0x0B95..0x0BB9, "tamil"},
    {0x0C4D, 0x0C15..0x0C39, "telugu"},
    {0x0CCD, 0x0C95..0x0CB9, "kannada"},
    {0x0D4D, 0x0D15..0x0D39, "malayalam"},
    {0x0DCA, 0x0D9A..0x0DC6, "sinhala"},
    {0x17D2, 0x1780..0x17A2, "khmer"},
    {0x1039, 0x1000..0x1021, "myanmar"},
  }

  # Enclosing marks, general category `Me`. One of these is what makes a keycap
  # two columns on both terminals measured and one in our tables until it was
  # fixed, so all of them go in.
  ENCLOSING = [0x0488, 0x0489, 0x1ABE, 0x20DD, 0x20DE, 0x20DF, 0x20E0,
               0x20E2, 0x20E3, 0x20E4, 0xA670, 0xA671, 0xA672]

  def self.run : Nil
    entries = [] of Entry

    entries.concat control_samples
    entries.concat emoji_test
    entries.concat property_representatives
    entries.concat conjuncts
    entries.concat jamo
    entries.concat regional_indicators
    entries.concat variation_selectors
    entries.concat marks_and_keycaps

    kept, dropped = filter entries
    write kept
    report kept, dropped
  end

  # The sixty seven already measured, so a survey that cannot reproduce them is
  # known to be wrong before anything else it says is believed.
  def self.control_samples : Array(Entry)
    samples.map { |sample| Entry.new sample.text, "control", sample.note }
  end

  # Every sequence in the emoji test file, in all three states of
  # qualification. The unqualified ones matter as much as the rest: a keycap
  # without its variation selector is counted differently by the two terminals
  # already measured, and that is the shape of thing this is looking for.
  def self.emoji_test : Array(Entry)
    entries = [] of Entry

    File.each_line File.join(CACHE_DIR, "emoji-test.txt") do |line|
      body, _, comment = line.partition '#'
      points, _, status = body.partition ';'
      status = status.strip
      next if status.empty? || points.strip.empty?

      text = points.split.map(&.to_i(16).chr).join
      name = comment.split(/E\d+\.\d+/, 2)[1]?.try(&.strip) || comment.strip
      entries << Entry.new text, "emoji-#{status}", name
    end

    entries
  end

  # One code point for every combination of the properties that decide a width,
  # taken from the tables rather than from taste. This is where a corner nobody
  # has thought about is most likely to be sitting.
  def self.property_representatives : Array(Entry)
    seen = {} of String => Entry

    assigned do |codepoint, category|
      char = codepoint.chr
      key = {TermBuf::Unicode.char_width(char, 1),
             TermBuf::Unicode.grapheme_class(char),
             TermBuf::Unicode.conjunct_class(char),
             TermBuf::Unicode.ambiguous?(char),
             TermBuf::Unicode.pictographic?(char),
             TermBuf::Unicode.emoji?(char),
             category}.join '/'

      seen[key] ||= Entry.new char.to_s, "property", key
    end

    seen.values
  end

  # Consonant, virama, consonant, for every script that spells it that way,
  # with and without a spacing vowel after it.
  def self.conjuncts : Array(Entry)
    entries = [] of Entry

    VIRAMAS.each do |virama, consonants, script|
      pair = consonants.select do |codepoint|
        TermBuf::Unicode.conjunct_class(codepoint.chr).consonant?
      end.first 2

      # A script whose consonants the tables do not call consonants is itself
      # worth recording, so fall back to the first two of the block.
      pair = consonants.first 2 if pair.size < 2
      next if pair.size < 2

      first, second = pair[0].chr, pair[1].chr
      entries << Entry.new "#{first}#{virama.chr}#{second}", "conjunct", script
      entries << Entry.new "#{first}#{virama.chr}#{second}#{virama.chr}#{first}",
        "conjunct", "#{script}, two linkers"
      entries << Entry.new "#{first}#{virama.chr}", "conjunct", "#{script}, dangling linker"
    end

    entries
  end

  # Every arrangement of conjoining jamo, including the ones that are not well
  # formed. Terminal.app composes these before counting and the rule that says
  # so was fitted to two samples, neither of which was a vowel on its own.
  def self.jamo : Array(Entry)
    lead, vowel, tail = 0x1100.chr, 0x1161.chr, 0x11A8.chr
    syllable, with_tail = 0xAC00.chr, 0xAC01.chr

    [
      {lead.to_s, "lead alone"},
      {vowel.to_s, "vowel with no lead"},
      {tail.to_s, "tail with no lead"},
      {"#{lead}#{vowel}", "lead and vowel"},
      {"#{lead}#{vowel}#{tail}", "lead, vowel and tail"},
      {"#{lead}#{lead}#{vowel}", "two leads"},
      {"#{lead}#{vowel}#{vowel}", "two vowels"},
      {"#{lead}#{vowel}#{tail}#{tail}", "two tails"},
      {syllable.to_s, "precomposed syllable"},
      {with_tail.to_s, "precomposed with a tail"},
      {"#{syllable}#{tail}", "precomposed plus a tail"},
      {"#{vowel}#{tail}", "vowel and tail, no lead"},
    ].map { |text, note| Entry.new text, "jamo", note }
  end

  def self.regional_indicators : Array(Entry)
    (1..5).map do |count|
      text = String.build do |io|
        count.times { |index| io << (0x1F1E6 + index).chr }
      end

      Entry.new text, "regional", "#{count} indicator#{count == 1 ? "" : "s"}"
    end
  end

  # A variation selector against each kind of base there is. `⚑` is
  # pictographic and is not an emoji, which is the distinction that had `⚑️`
  # two columns wide in our tables and one on both terminals.
  def self.variation_selectors : Array(Entry)
    bases = [] of {Int32, String}
    kinds = {} of {Bool, Bool} => Int32

    assigned do |codepoint, category|
      next unless category == "So" || category == "Nd"
      char = codepoint.chr
      key = {TermBuf::Unicode.pictographic?(char), TermBuf::Unicode.emoji?(char)}
      next if kinds.fetch(key, 0) >= 3

      kinds[key] = kinds.fetch(key, 0) + 1
      bases << {codepoint, "pictographic=#{key[0]} emoji=#{key[1]}"}
    end

    entries = [] of Entry
    bases.each do |codepoint, kind|
      char = codepoint.chr
      entries << Entry.new char.to_s, "presentation", "#{kind}, bare"
      entries << Entry.new "#{char}\u{FE0F}", "presentation", "#{kind}, VS16"
      entries << Entry.new "#{char}\u{FE0E}", "presentation", "#{kind}, VS15"
    end

    entries
  end

  def self.marks_and_keycaps : Array(Entry)
    entries = [] of Entry

    ENCLOSING.each do |mark|
      entries << Entry.new "a#{mark.chr}", "enclosing", "latin a plus U+#{"%04X" % mark}"
      entries << Entry.new "1#{mark.chr}", "enclosing", "digit plus U+#{"%04X" % mark}"
      entries << Entry.new "1\u{FE0F}#{mark.chr}", "enclosing",
        "digit, VS16, U+#{"%04X" % mark}"
    end

    ("0".."9").to_a.concat(["#", "*"]).each do |base|
      entries << Entry.new "#{base}\u{FE0F}\u{20E3}", "keycap", "#{base}, qualified"
      entries << Entry.new "#{base}\u{20E3}", "keycap", "#{base}, no selector"
    end

    # Stacks of nonspacing marks, which is the other way a cluster grows.
    combining = [0x0301, 0x0302, 0x0303, 0x0304]
    [1, 2, 4].each do |count|
      text = "e" + combining.first(count).map(&.chr).join
      entries << Entry.new text, "marks", "#{count} nonspacing mark#{count == 1 ? "" : "s"}"
    end

    entries
  end

  # Every assigned code point, with its general category, ranges expanded.
  # Surrogates, private use and the unassigned are skipped; controls are left
  # to the filter, which drops anything carrying one.
  def self.assigned(& : Int32, String ->) : Nil
    range_start = nil.as(Int32?)

    File.each_line File.join(CACHE_DIR, "UnicodeData.txt") do |line|
      fields = line.split ';'
      next if fields.size < 3

      codepoint, name, category = fields[0].to_i(16), fields[1], fields[2]
      next if category.in? "Cs", "Co"

      if name.ends_with? ", First>"
        range_start = codepoint
        next
      end

      if (first = range_start) && name.ends_with?(", Last>")
        # A range of tens of thousands of look-alikes says nothing new, so take
        # its ends and leave the middle.
        {first, codepoint}.each { |point| yield point, category }
        range_start = nil
        next
      end

      yield codepoint, category
    end
  end

  # Drops what the instrument cannot send, and anything already present.
  def self.filter(entries : Array(Entry)) : {Array(Entry), Hash(String, Int32)}
    dropped = Hash(String, Int32).new 0
    seen = Set(String).new
    kept = [] of Entry

    entries.each do |entry|
      reason = if entry.text.empty?
                 "empty"
               elsif entry.text.each_char.any? { |char| control? char }
                 "control character"
               elsif TermBuf::Unicode.code_point_columns(entry.text) > MAX_COLUMNS
                 "wider than #{MAX_COLUMNS} columns"
               elsif !seen.add? entry.text
                 "duplicate"
               end

      if reason
        dropped[reason] += 1
      else
        kept << entry
      end
    end

    {kept, dropped}
  end

  def self.control?(char : Char) : Bool
    point = char.ord
    point < 0x20 || (0x7F <= point <= 0x9F)
  end

  def self.write(entries : Array(Entry)) : Nil
    File.open OUTPUT, "w" do |file|
      file << "# unicode=" << UNICODE_VERSION << " clusters=" << entries.size << '\n'
      file << "codepoints\tgroup\tnote\n"

      entries.each do |entry|
        points = entry.text.codepoints.map { |point| "%04X" % point }.join '+'
        file << points << '\t' << entry.group << '\t' << entry.note.gsub('\t', ' ') << '\n'
      end
    end
  end

  def self.report(kept : Array(Entry), dropped : Hash(String, Int32)) : Nil
    puts "#{kept.size} clusters to #{OUTPUT}"

    kept.group_by(&.group).to_a.sort_by { |group, list| {-list.size, group} }
      .each { |group, list| puts "  %-26s %5d" % {group, list.size} }

    unless dropped.empty?
      puts "dropped:"
      dropped.to_a.sort_by { |_, count| -count }
        .each { |reason, count| puts "  %-26s %5d" % {reason, count} }
    end

    # What the survey is for: the clusters where the two models differ are the
    # ones a terminal can come down on one side of.
    split = kept.count do |entry|
      TermBuf::Unicode.string_width(entry.text) !=
        TermBuf::Unicode.code_point_columns(entry.text)
    end
    puts "#{split} of #{kept.size} tell the two models apart"
  end
end

GenCorpus.run
