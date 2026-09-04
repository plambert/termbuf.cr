require "../core/cell"
require "./width"
require "./policy"

module TermBuf::Unicode
  # Joins emoji into one cluster, and on most terminals into one glyph.
  ZERO_WIDTH_JOINER = '\u200D'

  # Variation selector 15, forcing text presentation and so a width of one.
  TEXT_PRESENTATION = '\uFE0E'

  # Variation selector 16, forcing emoji presentation and so a width of two.
  EMOJI_PRESENTATION = '\uFE0F'

  # One extended grapheme cluster, located by byte offset within its source
  # string so that scanning a string allocates nothing.
  struct Grapheme
    # Byte offset of the cluster within the string it was scanned from.
    getter start : Int32

    # Length of the cluster in bytes.
    getter bytesize : Int32

    # Terminal cells the cluster occupies, from zero up to `Cell::MAX_WIDTH`.
    getter width : Int32

    # The cluster's only character, when it consists of a single code point.
    # `nil` for multi-code-point clusters, which the buffer keeps in its
    # cluster pool rather than inline in a cell.
    getter char : Char?

    def initialize(@start : Int32, @bytesize : Int32, @width : Int32, @char : Char?)
    end

    # Extracts the cluster from the string it was scanned from.
    def text(source : String) : String
      source.byte_slice start, bytesize
    end
  end

  # Decides where extended grapheme cluster boundaries fall, following the
  # UAX #29 rules GB1 through GB999.
  #
  # One instance walks one string. For each character in order, ask
  # `#boundary?` whether a cluster boundary precedes it, then hand the same
  # character to `#consume` to advance the state.
  struct Breaker
    # ExtPict Extend* ZWJ tracking for GB11.
    private enum Emoji : UInt8
      None       # nothing pictographic pending
      Pictograph # ExtPict Extend*
      Joined     # ExtPict Extend* ZWJ
    end

    # Consonant [Extend Linker]* Linker [Extend Linker]* tracking for GB9c.
    private enum Conjunct : UInt8
      None      # no conjunct sequence pending
      Consonant # a consonant, with no linker seen yet
      Linked    # a consonant followed by at least one linker
    end

    # A fresh breaker, positioned before the first character of a string.
    def initialize
    end

    @started = false
    @previous = Tables::Gcb::Other
    @regional_run = 0
    @emoji = Emoji::None
    @conjunct = Conjunct::None

    # Whether a cluster boundary falls immediately before *char*.
    # ameba:disable Metrics/CyclomaticComplexity
    def boundary?(char : Char) : Bool
      return false unless @started # GB1: nothing precedes the first character

      following = Unicode.grapheme_class char
      preceding = @previous

      # GB3, GB4, GB5: line endings and controls stand alone, except CR LF.
      return false if preceding.cr? && following.lf?
      return true if preceding.control? || preceding.cr? || preceding.lf?
      return true if following.control? || following.cr? || following.lf?

      # GB6, GB7, GB8: Hangul syllables assemble from jamo.
      if preceding.hangul_l?
        return false if following.hangul_l? || following.hangul_v? ||
                        following.hangul_lv? || following.hangul_lvt?
      end
      if preceding.hangul_lv? || preceding.hangul_v?
        return false if following.hangul_v? || following.hangul_t?
      end
      if preceding.hangul_lvt? || preceding.hangul_t?
        return false if following.hangul_t?
      end

      # GB9, GB9a, GB9b: marks attach to what precedes, prepends to what follows.
      return false if following.extend? || following.zero_width_joiner?
      return false if following.spacing_mark?
      return false if preceding.prepend?

      # GB9c: a linked consonant conjunct stays whole across the virama.
      return false if @conjunct.linked? && Unicode.conjunct_class(char).consonant?

      # GB11: emoji joined by ZWJ form one cluster.
      return false if @emoji.joined? && Unicode.pictographic?(char)

      # GB12, GB13: regional indicators pair up into flags.
      return false if following.regional_indicator? && @regional_run.odd?

      true # GB999
    end

    # Advances the state as though *char* had been added to the current
    # cluster. Call exactly once per character, after `#boundary?`.
    def consume(char : Char) : Nil
      klass = Unicode.grapheme_class char

      @emoji = if Unicode.pictographic? char
                 Emoji::Pictograph
               elsif @emoji.pictograph? && klass.extend?
                 Emoji::Pictograph
               elsif @emoji.pictograph? && klass.zero_width_joiner?
                 Emoji::Joined
               else
                 Emoji::None
               end

      conjunct = Unicode.conjunct_class char
      @conjunct = if conjunct.consonant?
                    Conjunct::Consonant
                  elsif @conjunct.none?
                    Conjunct::None
                  elsif conjunct.linker?
                    Conjunct::Linked
                  elsif conjunct.extend?
                    @conjunct
                  else
                    Conjunct::None
                  end

      @regional_run = klass.regional_indicator? ? @regional_run + 1 : 0
      @previous = klass
      @started = true
    end

    # Whether the character just consumed was a `Prepend`. That is the only
    # way an ASCII character can join the cluster before it, so it is also the
    # only case where the ASCII fast path in `Unicode.each_grapheme` is unsafe.
    def prepend_pending? : Bool
      @previous.prepend?
    end

    # Advances the state for a printable ASCII character. Every code point in
    # `0x20..0x7E` has break class `Other`, conjunct class `None`, and no
    # pictographic property, so none of the tables need consulting.
    def consume_ascii : Nil
      @emoji = Emoji::None
      @conjunct = Conjunct::None
      @regional_run = 0
      @previous = Tables::Gcb::Other
      @started = true
    end
  end

  # The cluster being accumulated by `.each_grapheme`: where it starts, how
  # many code points it holds, and everything needed to settle its width.
  private struct ClusterState
    @start = 0
    @count = 0
    @first = ' '
    @base_width = 0
    @spacing = 0
    @laid_out = 0
    @joined = false
    @regional = 0
    @presentation : Char? = nil
    # UAX #29 GB9c in miniature, kept here rather than read off the breaker so
    # a cluster can be measured on its own: a consonant, then a linker, then
    # another consonant is one conjunct.
    @after_consonant = false
    @linked = false
    @conjunct = false
    # Whether anything in the cluster is drawn rather than spelled, which is
    # what separates a joined emoji sequence from a letter, a joiner and a
    # letter.
    @pictograph = false
    @policy : WidthPolicy

    def initialize(@policy : WidthPolicy)
    end

    # Whether any code point has been added since the cluster was opened.
    def pending? : Bool
      @count > 0
    end

    # Begins a fresh, empty cluster at byte offset *position*.
    def open(position : Int32) : Nil
      @start = position
      @count = 0
      @spacing = 0
      @laid_out = 0
      @joined = false
      @regional = 0
      @presentation = nil
      @after_consonant = false
      @linked = false
      @conjunct = false
      @pictograph = false
    end

    def add(char : Char) : Nil
      @joined = true if char == ZERO_WIDTH_JOINER
      @regional += 1 if Unicode.grapheme_class(char).regional_indicator?
      @pictograph = true if Unicode.pictographic? char
      note_conjunct char
      # What the cluster would take if the terminal laid its pieces end to end
      # rather than collapsing them, which some do.
      @laid_out += measure char

      if @count.zero?
        @first = char
        @base_width = measure char
      elsif char == EMOJI_PRESENTATION || char == TEXT_PRESENTATION
        @presentation = char
      elsif @base_width.zero?
        # A cluster opening with a combining mark, which happens only at the
        # start of a string, still has to occupy a cell.
        @base_width = measure char
      elsif Unicode.grapheme_class(char).spacing_mark?
        # The one kind of mark that takes a cell of its own. The Tamil vowel
        # sign of `நி` sits beside its consonant rather than over it, and a
        # terminal advances the cursor for it; the same goes for the vowel
        # sign in a Devanagari conjunct. How far that may push the cluster is
        # `#spacing_cap`.
        @spacing += measure char
      end

      @count += 1
    end

    private def measure(char : Char) : Int32
      Unicode.char_width char, @policy.ambiguous
    end

    # Tracks whether the cluster has formed a conjunct.
    private def note_conjunct(char : Char) : Nil
      conjunct = Unicode.conjunct_class char

      if conjunct.consonant?
        @conjunct = true if @linked
        @linked = false
        @after_consonant = true
      elsif conjunct.linker?
        @linked ||= @after_consonant
      elsif !conjunct.extend?
        @linked = false
        @after_consonant = false
      end
    end

    # Closes the cluster at byte offset *finish*, exclusive.
    def grapheme(finish : Int32) : Grapheme
      Grapheme.new @start, finish - @start, width, @count == 1 ? @first : nil
    end

    # What the terminal will advance for this cluster, which is a question
    # about the terminal and not about Unicode. See `WidthPolicy`.
    private def width : Int32
      return @laid_out if @joined && !@policy.joined_emoji?
      return @laid_out if @regional > 1 && !@policy.regional_indicators?

      collapsed
    end

    private def collapsed : Int32
      base = floor @base_width
      base = Math.min base + @spacing, spacing_cap if @policy.spacing_marks? && !base.zero?

      case @presentation
      when EMOJI_PRESENTATION
        # The Emoji property, not Extended_Pictographic: a selector after `\u{2691}`
        # asks for a presentation it has not got, and a digit is an emoji even
        # though it is not pictographic.
        @policy.emoji_presentation? && Unicode.emoji?(@first) ? 2 : base
      when TEXT_PRESENTATION then base.zero? ? 0 : 1
      else                        base
      end
    end

    # How far a spacing mark may push a cluster.
    #
    # A cell pair, which is all any terminal charges for a base and its vowel
    # sign — except for a conjunct, where iTerm2 3.6.11 adds the vowel sign on
    # top of the two the conjunct itself takes. That reading needs a third
    # cell, and `Cell::MAX_WIDTH` is where it stops.
    private def spacing_cap : Int32
      @conjunct && @policy.conjunct_spacing_adds? ? Cell::MAX_WIDTH : 2
    end

    # Two columns is the least a cluster drawn as one glyph gets, whatever the
    # code point it opens with is worth alone.
    #
    # Both are the terminal's decision rather than Unicode's, so both are
    # policy. A conjunct ligates into one glyph that ghostty and Terminal.app
    # charge two for and kitty 0.48.2 charges one. A joined emoji sequence is
    # two on ghostty and kitty for every one of the 2,497 in the survey, where
    # taking the width from the first code point gave one for a narrow
    # pictograph like the weight lifter.
    private def floor(base : Int32) : Int32
      return base if base >= 2
      return 2 if @conjunct && @policy.conjunct_wide?
      return 2 if @joined && @pictograph && @policy.joined_emoji_wide?

      base
    end
  end

  # Yields each extended grapheme cluster of *string* in order, without
  # allocating: a `Grapheme` locates its cluster by byte offset.
  def self.each_grapheme(string : String, policy : WidthPolicy = Unicode.policy,
                         & : Grapheme ->) : Nil
    return if string.empty?

    bytes = string.to_unsafe
    bytesize = string.bytesize
    reader = Char::Reader.new string
    breaker = Breaker.new
    cluster = ClusterState.new policy

    while (position = reader.pos) < bytesize
      char = reader.current_char

      if ascii_singleton? breaker, bytes, char, position, bytesize
        yield cluster.grapheme position if cluster.pending?
        yield Grapheme.new position, 1, 1, char

        breaker.consume_ascii
        cluster.open position + 1
        reader.next_char
        next
      end

      boundary = breaker.boundary? char
      breaker.consume char

      if boundary && cluster.pending?
        yield cluster.grapheme position
        cluster.open position
      end

      cluster.add char
      reader.next_char
    end

    yield cluster.grapheme bytesize if cluster.pending?
  end

  # A printable ASCII character opens a cluster of its own, since nothing in
  # `0x20..0x7E` can extend the cluster before it — unless that cluster ends in
  # a `Prepend`, which reaches forward. When the next character is printable
  # ASCII too, this cluster is exactly one character wide and the break rules
  # never need to run.
  private def self.ascii_singleton?(breaker : Breaker, bytes : UInt8*, char : Char,
                                    position : Int32, bytesize : Int32) : Bool
    !breaker.prepend_pending? && printable_ascii?(char) &&
      printable_ascii_at?(bytes, position + 1, bytesize)
  end

  private def self.printable_ascii?(char : Char) : Bool
    0x20 <= char.ord < 0x7F
  end

  private def self.printable_ascii_at?(bytes : UInt8*, position : Int32, bytesize : Int32) : Bool
    return true if position >= bytesize

    byte = bytes[position]
    0x20 <= byte < 0x7F
  end

  # All extended grapheme clusters of *string*, as separate strings. Convenient
  # for specs and one-off work; the buffer uses `each_grapheme` instead.
  def self.graphemes(string : String) : Array(String)
    result = [] of String
    each_grapheme(string) { |grapheme| result << grapheme.text(string) }
    result
  end

  # Total number of terminal cells *string* occupies, under *policy*.
  def self.string_width(string : String, policy : WidthPolicy = Unicode.policy) : Int32
    total = 0
    each_grapheme(string, policy) { |grapheme| total += grapheme.width }
    total
  end
end
