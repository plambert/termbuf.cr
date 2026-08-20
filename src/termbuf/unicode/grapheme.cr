require "./width"

module TermBuf::Unicode
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

    # Terminal cells the cluster occupies: zero, one, or two.
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
    @presentation : Char? = nil

    # Whether any code point has been added since the cluster was opened.
    def pending? : Bool
      @count > 0
    end

    # Begins a fresh, empty cluster at byte offset *position*.
    def open(position : Int32) : Nil
      @start = position
      @count = 0
      @presentation = nil
    end

    def add(char : Char) : Nil
      if @count.zero?
        @first = char
        @base_width = Unicode.char_width char
      elsif char == EMOJI_PRESENTATION || char == TEXT_PRESENTATION
        @presentation = char
      elsif @base_width.zero?
        # A cluster opening with a combining mark, which happens only at the
        # start of a string, still has to occupy a cell.
        @base_width = Unicode.char_width char
      end

      @count += 1
    end

    # Closes the cluster at byte offset *finish*, exclusive.
    def grapheme(finish : Int32) : Grapheme
      Grapheme.new @start, finish - @start, width, @count == 1 ? @first : nil
    end

    # A variation selector overrides the base character's own width: emoji
    # presentation takes two cells, text presentation one.
    private def width : Int32
      case @presentation
      when EMOJI_PRESENTATION then Unicode.pictographic?(@first) ? 2 : @base_width
      when TEXT_PRESENTATION  then @base_width.zero? ? 0 : 1
      else                         @base_width
      end
    end
  end

  # Yields each extended grapheme cluster of *string* in order, without
  # allocating: a `Grapheme` locates its cluster by byte offset.
  def self.each_grapheme(string : String, & : Grapheme ->) : Nil
    return if string.empty?

    bytes = string.to_unsafe
    bytesize = string.bytesize
    reader = Char::Reader.new string
    breaker = Breaker.new
    cluster = ClusterState.new

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

  # Total number of terminal cells *string* occupies.
  def self.string_width(string : String) : Int32
    total = 0
    each_grapheme(string) { |grapheme| total += grapheme.width }
    total
  end
end
