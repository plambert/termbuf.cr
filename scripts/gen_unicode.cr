#!/usr/bin/env crystal
#
# Regenerates `src/termbuf/unicode/tables.cr` from the Unicode Character
# Database, and refreshes the UAX #29 conformance fixture used by the specs.
#
#     crystal run scripts/gen_unicode.cr
#
# Downloaded UCD files are cached under `tmp/ucd-<version>/`, so re-running is
# cheap. Bump `UNICODE_VERSION` to move to a new Unicode release.

require "http/client"
require "file_utils"

module GenUnicode
  UNICODE_VERSION = "16.0.0"
  BASE_URL        = "https://www.unicode.org/Public/#{UNICODE_VERSION}/ucd"
  CACHE_DIR       = "tmp/ucd-#{UNICODE_VERSION}"
  TABLES_PATH     = "src/termbuf/unicode/tables.cr"
  FIXTURE_PATH    = "spec/fixtures/GraphemeBreakTest.txt"
  MAX_CODEPOINT   = 0x10FFFF

  # Local name => path below `BASE_URL`.
  SOURCES = {
    "UnicodeData.txt"           => "UnicodeData.txt",
    "EastAsianWidth.txt"        => "EastAsianWidth.txt",
    "DerivedCoreProperties.txt" => "DerivedCoreProperties.txt",
    "emoji-data.txt"            => "emoji/emoji-data.txt",
    "GraphemeBreakProperty.txt" => "auxiliary/GraphemeBreakProperty.txt",
    "GraphemeBreakTest.txt"     => "auxiliary/GraphemeBreakTest.txt",
  }

  # Grapheme cluster break classes, in the order they are emitted into the
  # generated `Gcb` enum. `Other` must stay first so that zero is the default.
  GCB_CLASSES = %w[
    Other CR LF Control Extend ZeroWidthJoiner RegionalIndicator Prepend
    SpacingMark HangulL HangulV HangulT HangulLV HangulLVT
  ]

  # UCD spelling => generated enum member.
  GCB_NAMES = {
    "CR"                 => "CR",
    "LF"                 => "LF",
    "Control"            => "Control",
    "Extend"             => "Extend",
    "ZWJ"                => "ZeroWidthJoiner",
    "Regional_Indicator" => "RegionalIndicator",
    "Prepend"            => "Prepend",
    "SpacingMark"        => "SpacingMark",
    "L"                  => "HangulL",
    "V"                  => "HangulV",
    "T"                  => "HangulT",
    "LV"                 => "HangulLV",
    "LVT"                => "HangulLVT",
  }

  INCB_CLASSES = %w[None Linker Consonant Extend]

  # Blocks whose *unassigned* code points default to East Asian Wide, per the
  # header of `EastAsianWidth.txt`.
  WIDE_BY_DEFAULT = [
    0x3400..0x4DBF,   # CJK Unified Ideographs Extension A
    0x4E00..0x9FFF,   # CJK Unified Ideographs
    0xF900..0xFAFF,   # CJK Compatibility Ideographs
    0x20000..0x2FFFD, # Plane 2
    0x30000..0x3FFFD, # Plane 3
  ]

  # Bit layout of the packed property word stored per code point range.
  GCB_MASK         = 0x000F_u16
  WIDTH_SHIFT      =      4_u16
  AMBIGUOUS_BIT    = 0x0040_u16
  PICTOGRAPHIC_BIT = 0x0080_u16
  INCB_SHIFT       =      8_u16
  INCB_MASK        = 0x0300_u16

  def self.run : Nil
    FileUtils.mkdir_p CACHE_DIR
    FileUtils.mkdir_p File.dirname(FIXTURE_PATH)
    SOURCES.each_key { |name| fetch name }

    widths = Array(UInt8).new(MAX_CODEPOINT + 1, 1_u8)
    flags = Array(UInt16).new(MAX_CODEPOINT + 1, 0_u16)

    apply_east_asian_width widths, flags
    apply_emoji widths, flags
    apply_general_categories widths
    apply_default_ignorable widths
    apply_grapheme_break flags
    apply_incb flags

    starts, props = pack widths, flags
    write_tables starts, props
    FileUtils.cp File.join(CACHE_DIR, "GraphemeBreakTest.txt"), FIXTURE_PATH
    puts "wrote #{TABLES_PATH} (#{starts.size} ranges) and #{FIXTURE_PATH}"
  end

  # ---------------------------------------------------------------- fetching

  def self.fetch(name : String) : String
    path = File.join CACHE_DIR, name
    return path if File.exists? path

    url = "#{BASE_URL}/#{SOURCES[name]}"
    puts "fetching #{url}"
    response = HTTP::Client.get url
    raise "GET #{url} failed: #{response.status_code}" unless response.success?

    File.write path, response.body
    path
  end

  # ----------------------------------------------------------------- parsing

  # Yields the code point range and semicolon-separated fields of each data
  # line in a standard UCD property file, skipping comments and blank lines.
  def self.each_property(name : String, & : Range(Int32, Int32), Array(String) ->) : Nil
    File.each_line File.join(CACHE_DIR, name) do |line|
      body = line.split('#', 2).first.strip
      next if body.empty?

      fields = body.split(';').map!(&.strip)
      yield parse_range(fields[0]), fields
    end
  end

  def self.parse_range(text : String) : Range(Int32, Int32)
    if separator = text.index ".."
      text[0, separator].to_i(16)..text[separator + 2..].to_i(16)
    else
      value = text.to_i 16
      value..value
    end
  end

  # ------------------------------------------------------------- width rules

  def self.apply_east_asian_width(widths : Array(UInt8), flags : Array(UInt16)) : Nil
    WIDE_BY_DEFAULT.each do |block|
      block.each { |codepoint| widths[codepoint] = 2_u8 }
    end

    each_property "EastAsianWidth.txt" do |range, fields|
      case fields[1]
      when "W", "F"
        range.each { |codepoint| widths[codepoint] = 2_u8 }
      when "A"
        range.each do |codepoint|
          widths[codepoint] = 1_u8
          flags[codepoint] |= AMBIGUOUS_BIT
        end
      else
        range.each { |codepoint| widths[codepoint] = 1_u8 }
      end
    end
  end

  def self.apply_emoji(widths : Array(UInt8), flags : Array(UInt16)) : Nil
    each_property "emoji-data.txt" do |range, fields|
      case fields[1]
      when "Emoji_Presentation"
        range.each { |codepoint| widths[codepoint] = 2_u8 }
      when "Extended_Pictographic"
        range.each { |codepoint| flags[codepoint] |= PICTOGRAPHIC_BIT }
      end
    end
  end

  # Marks and format characters occupy no cell of their own; controls are never
  # stored in the buffer and are reported as zero width.
  def self.apply_general_categories(widths : Array(UInt8)) : Nil
    range_start = nil.as(Int32?)

    File.each_line File.join(CACHE_DIR, "UnicodeData.txt") do |line|
      fields = line.split ';'
      next if fields.size < 3

      codepoint = fields[0].to_i 16
      name = fields[1]
      category = fields[2]

      if name.ends_with? ", First>"
        range_start = codepoint
        next
      end

      first = if name.ends_with?(", Last>") && (start = range_start)
                range_start = nil
                start
              else
                codepoint
              end

      next unless category.in? "Mn", "Me", "Cf", "Cc", "Cs"

      (first..codepoint).each { |member| widths[member] = 0_u8 }
    end
  end

  def self.apply_default_ignorable(widths : Array(UInt8)) : Nil
    each_property "DerivedCoreProperties.txt" do |range, fields|
      next unless fields[1] == "Default_Ignorable_Code_Point"

      range.each { |codepoint| widths[codepoint] = 0_u8 }
    end
  end

  # --------------------------------------------------------- grapheme breaks

  def self.apply_grapheme_break(flags : Array(UInt16)) : Nil
    each_property "GraphemeBreakProperty.txt" do |range, fields|
      next unless name = GCB_NAMES[fields[1]]?

      index = GCB_CLASSES.index(name) || raise "unmapped GCB class #{name}"
      value = index.to_u16
      range.each { |codepoint| flags[codepoint] = (flags[codepoint] & ~GCB_MASK) | value }
    end
  end

  def self.apply_incb(flags : Array(UInt16)) : Nil
    each_property "DerivedCoreProperties.txt" do |range, fields|
      next unless fields.size > 2 && fields[1] == "InCB"
      next unless index = INCB_CLASSES.index fields[2]

      value = index.to_u16 << INCB_SHIFT
      range.each { |codepoint| flags[codepoint] = (flags[codepoint] & ~INCB_MASK) | value }
    end
  end

  # ------------------------------------------------------------------ output

  # Run-length encodes the per-code-point properties into contiguous ranges.
  # Range *n* covers `starts[n]` through `starts[n + 1] - 1`, so every code
  # point falls in exactly one range and lookup never has a miss case.
  def self.pack(widths : Array(UInt8), flags : Array(UInt16)) : {Array(Int32), Array(UInt16)}
    starts = [] of Int32
    props = [] of UInt16
    previous = nil.as(UInt16?)

    (0..MAX_CODEPOINT).each do |codepoint|
      word = flags[codepoint] | (widths[codepoint].to_u16 << WIDTH_SHIFT)
      next if word == previous

      starts << codepoint
      props << word
      previous = word
    end

    {starts, props}
  end

  # Emits the tables as two space-separated base-36 strings rather than array
  # literals: a few thousand literal elements would cost seconds of compile
  # time on every build, while one string literal costs nothing and decodes in
  # microseconds at startup.
  def self.encode(values : Array(Int32 | UInt16)) : String
    String.build { |io| values.each_with_index { |value, index| io << ' ' unless index.zero?; io << value.to_s(36) } }
  end

  def self.write_tables(starts : Array(Int32), props : Array(UInt16)) : Nil
    deltas = Array(Int32 | UInt16).new starts.size
    starts.each_with_index { |value, index| deltas << (index.zero? ? value : value - starts[index - 1]) }

    File.open TABLES_PATH, "w" do |file|
      file << <<-HEAD
        # Generated by `scripts/gen_unicode.cr` from Unicode #{UNICODE_VERSION}.
        # Do not edit by hand; re-run the generator instead.

        # Character properties packed one `UInt16` to a range of code points.
        #
        # `Unicode` is the way in; nothing here is meant to be read directly.
        module TermBuf::Unicode::Tables
          UNICODE_VERSION = #{UNICODE_VERSION.inspect}

          # Grapheme cluster break property (UAX #29, table 2).
          enum Gcb : UInt8

        HEAD

      GCB_CLASSES.each { |name| file << "    " << name << '\n' }

      file << <<-MID
          end

          # Indic conjunct break property (UAX #29, rule GB9c).
          enum Incb : UInt8

        MID

      INCB_CLASSES.each { |name| file << "    " << name << '\n' }

      file << <<-BITS
          end

          GCB_MASK         = 0x000F_u16
          WIDTH_SHIFT      =      4_u16
          WIDTH_MASK       = 0x0030_u16
          AMBIGUOUS_BIT    = 0x0040_u16
          PICTOGRAPHIC_BIT = 0x0080_u16
          INCB_SHIFT       =      8_u16
          INCB_MASK        = 0x0300_u16

          RANGE_COUNT = #{starts.size}

          # Base-36 deltas between consecutive range starts.
          private START_DELTAS = #{encode(deltas).inspect}

          # Base-36 packed property word for the range at the same index.
          private PROP_WORDS = #{encode(props.map { |word| word.as(Int32 | UInt16) }).inspect}

          # Decodes a space-separated base-36 list into `count` integers.
          private def self.decode(data : String, count : Int32, & : Int32, Int32 ->) : Nil
            index = 0
            value = 0

            data.each_byte do |byte|
              if byte == 0x20_u8
                yield index, value
                index += 1
                value = 0
              else
                value = value * 36 + (byte < 0x3A_u8 ? byte - 0x30_u8 : byte - 0x57_u8)
              end
            end

            yield index, value
          end

          # First code point of each range, ascending. Range `n` runs from
          # `RANGE_START[n]` through `RANGE_START[n + 1] - 1`, so the ranges tile
          # the whole code point space and a lookup never misses.
          RANGE_START = begin
            slice = Slice(Int32).new RANGE_COUNT, 0
            running = 0
            decode(START_DELTAS, RANGE_COUNT) do |index, delta|
              running += delta
              slice[index] = running
            end
            slice
          end

          # Packed properties for the range beginning at the same index.
          RANGE_PROPS = begin
            slice = Slice(UInt16).new RANGE_COUNT, 0_u16
            decode(PROP_WORDS, RANGE_COUNT) { |index, word| slice[index] = word.to_u16 }
            slice
          end
        end

        BITS
    end
  end
end

GenUnicode.run
