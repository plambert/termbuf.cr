require "./tables"
require "./policy"

# Character property lookup for the terminal buffer: display width, grapheme
# cluster break class, and the two auxiliary properties UAX #29 needs.
#
# Every code point falls into exactly one range of `Tables::RANGE_START`, so a
# lookup is a binary search with no miss case. Code points below `FAST_LIMIT`
# skip the search entirely via a direct-indexed table built at startup, which
# covers Latin, Greek, Cyrillic, Hebrew, Arabic, the combining diacriticals,
# and most of the Indic scripts.
module TermBuf::Unicode
  # How clusters are measured when no policy is given. `Buffer` carries its
  # own, set from what the terminal said when asked; this is for casual callers
  # and for `char_width`, which has no cluster to consult.
  class_property policy : WidthPolicy = WidthPolicy::DEFAULT

  # Cells an East Asian Ambiguous character takes. Reads through to `.policy`,
  # which is where the answer lives now that it can be measured rather than
  # assumed.
  def self.ambiguous_width : Int32
    policy.ambiguous
  end

  # Code points below this are resolved by direct index rather than search.
  FAST_LIMIT = 0x1000

  private FAST_TABLE = begin
    slice = Slice(UInt16).new FAST_LIMIT, 0_u16
    index = 0

    FAST_LIMIT.times do |codepoint|
      while index + 1 < Tables::RANGE_COUNT && Tables::RANGE_START[index + 1] <= codepoint
        index += 1
      end

      slice[codepoint] = Tables::RANGE_PROPS[index]
    end

    slice
  end

  # Packed property word for *codepoint*.
  def self.properties(codepoint : Int32) : UInt16
    return FAST_TABLE[codepoint] if codepoint < FAST_LIMIT

    Tables::RANGE_PROPS[range_index(codepoint)]
  end

  # Index of the range containing *codepoint*: the last range whose start is at
  # or below it.
  private def self.range_index(codepoint : Int32) : Int32
    low = 0
    high = Tables::RANGE_COUNT - 1

    while low < high
      middle = (low + high + 1) // 2

      if Tables::RANGE_START[middle] <= codepoint
        low = middle
      else
        high = middle - 1
      end
    end

    low
  end

  # Number of terminal cells *char* occupies on its own, ignoring any grapheme
  # cluster it may belong to. Control characters report zero; they are never
  # stored in the buffer.
  def self.char_width(char : Char, ambiguous : Int32 = ambiguous_width) : Int32
    codepoint = char.ord
    return 1 if 0x20 <= codepoint < 0x7F
    return 0 if codepoint < 0x20 || codepoint == 0x7F

    width_of properties(codepoint), ambiguous
  end

  # Only a stored width of one can be ambiguous: combining marks resolve to
  # zero and East Asian Wide to two regardless of the ambiguous setting.
  private def self.width_of(props : UInt16, ambiguous : Int32) : Int32
    stored = ((props & Tables::WIDTH_MASK) >> Tables::WIDTH_SHIFT).to_i
    return stored unless stored == 1

    props & Tables::AMBIGUOUS_BIT == 0 ? 1 : ambiguous
  end

  # Grapheme cluster break class of *char* (UAX #29).
  def self.grapheme_class(char : Char) : Tables::Gcb
    Tables::Gcb.new (properties(char.ord) & Tables::GCB_MASK).to_u8
  end

  # Indic conjunct break class of *char*, used by rule GB9c.
  def self.conjunct_class(char : Char) : Tables::Incb
    Tables::Incb.new ((properties(char.ord) & Tables::INCB_MASK) >> Tables::INCB_SHIFT).to_u8
  end

  # Whether *char* has the `Extended_Pictographic` property, used by rule GB11.
  def self.pictographic?(char : Char) : Bool
    properties(char.ord) & Tables::PICTOGRAPHIC_BIT != 0
  end

  # Whether *char* has the Emoji property.
  #
  # Narrower than `.pictographic?` and a different question. `⚑` U+2691 is
  # pictographic and is not an emoji, so a variation selector after it asks for
  # a presentation it does not have and it stays one column — both terminals
  # measured agree. The digits are the other way about: emoji, not pictographic,
  # which is what makes `1️⃣` two columns.
  def self.emoji?(char : Char) : Bool
    properties(char.ord) & Tables::EMOJI_BIT != 0
  end

  # Whether *char* is East Asian Ambiguous, and so rendered at a width the
  # terminal's configuration decides.
  def self.ambiguous?(char : Char) : Bool
    properties(char.ord) & Tables::AMBIGUOUS_BIT != 0
  end

  # Enclosing marks, general category `Me`. There are thirteen of them, so a
  # list costs less than a bit in the generated tables.
  #
  # They matter only to `.code_point_columns`: a terminal counting per code
  # point gives an enclosing mark a column of its own, where it gives a
  # nonspacing mark none. That is the difference between `1️⃣` owning one
  # column and owning two.
  ENCLOSING_MARKS = StaticArray[
    0x0488..0x0489, 0x1ABE..0x1ABE, 0x20DD..0x20E0, 0x20E2..0x20E4, 0xA670..0xA672,
  ]

  # Tag characters, `U+E0020..U+E007F`. They carry the region of a subdivision
  # flag and are `Cf`, so nothing draws them and `.char_width` gives them none.
  #
  # They matter only to `.code_point_columns`: a terminal counting per code
  # point charges each of them a column, which is what makes `🏴󠁧󠁢󠁳󠁣󠁴󠁿` own eight.
  TAGS = 0xE0020..0xE007F

  # Whether *char* is a tag character.
  def self.tag?(char : Char) : Bool
    TAGS.includes? char.ord
  end

  # Whether *char* is an enclosing mark.
  def self.enclosing_mark?(char : Char) : Bool
    codepoint = char.ord
    return false if codepoint < 0x0488

    ENCLOSING_MARKS.any? &.includes?(codepoint)
  end

  # Columns a terminal takes for *text* when it counts them by summing the
  # code points rather than by measuring the grapheme cluster.
  #
  # Not what any standard says a cluster is worth — what
  # `Quirk::PerCodePointColumns` terminals do. Measured against Terminal.app
  # 470.2 across sixty-seven samples, and reproducing all of them:
  # `.char_width` per code point, with five departures.
  #
  # * The zero width joiner takes a column, so four joined faces own eleven.
  # * So does an enclosing mark, which is what makes `1️⃣` own two.
  # * So does a tag character, which is what makes `🏴󠁧󠁢󠁳󠁣󠁴󠁿` own eight.
  # * A regional indicator takes one rather than two, so a flag owns two and
  #   five indicators own five. That reads as if the terminal went by East
  #   Asian Width alone and never applied emoji presentation, but only the
  #   indicators were measured, so only they are named here.
  # * Conjoining jamo are composed before counting, so the vowel and the tail
  #   take nothing and `가` and `각` each own two, like the syllable they make.
  #   This is the one place the terminal counts a cluster rather than its
  #   pieces. A vowel or tail with no lead before it is not something the
  #   samples cover, and is given nothing here.
  def self.code_point_columns(text : String, policy : WidthPolicy = Unicode.policy) : Int32
    total = 0
    text.each_char { |char| total += code_point_columns char, policy }
    total
  end

  # :ditto:
  def self.code_point_columns(char : Char, policy : WidthPolicy = Unicode.policy) : Int32
    return 1 if char == ZERO_WIDTH_JOINER || enclosing_mark? char
    return 1 if grapheme_class(char).regional_indicator?
    return 1 if tag? char

    klass = grapheme_class char
    return 0 if klass.hangul_v? || klass.hangul_t?

    char_width char, policy.ambiguous
  end
end
