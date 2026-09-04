module TermBuf::Unicode
  # How a particular terminal measures a grapheme cluster.
  #
  # UAX #29 says where a cluster ends and UAX #11 says how wide a character is.
  # Neither says what a terminal does with four emoji joined by zero width
  # joiners, and terminals disagree: some advance two columns, some eleven. A
  # buffer measuring a cluster differently from the terminal drawing it has
  # every later cell on that row in the wrong place, so the measurement has to
  # come from the terminal rather than from the standard.
  #
  # `WidthProbe` fills one of these in by asking. The defaults are what a
  # current terminal does, and what a terminal that answers nothing is assumed
  # to do.
  struct WidthPolicy
    # Cells an East Asian Ambiguous character takes. One on most terminals, two
    # on a terminal configured for CJK text, and the standard leaves it to the
    # environment.
    getter ambiguous : Int32

    # Whether U+FE0F widens a pictograph that would otherwise be text. Without
    # it `☺️` is as narrow as `☺`.
    getter? emoji_presentation : Bool

    # Whether an emoji sequence joined by U+200D collapses to the width of one
    # emoji. Without it the cluster is as wide as its pieces laid end to end.
    getter? joined_emoji : Bool

    # Whether a collapsed joined sequence is two columns whatever it opens
    # with, rather than as wide as the code point it starts from.
    #
    # Ghostty, kitty and `tmux` draw two for a weight lifter joined to a female
    # sign, which opens with a narrow pictograph. iTerm2 3.6.11 draws one, and it is alone in that among
    # the terminals surveyed — see `measurements/survey/`. It is not a `Quirk`:
    # nothing is broken by it, and a buffer told about it lays the row out
    # correctly.
    getter? joined_emoji_wide : Bool

    # Whether a pair of regional indicators collapses to one flag.
    getter? regional_indicators : Bool

    # Whether a spacing mark takes a cell beside its base rather than none.
    getter? spacing_marks : Bool

    # Whether a consonant conjunct joined by a virama is two columns whatever
    # it opens with, rather than as wide as the consonant it starts from.
    #
    # A conjunct ligates into one glyph, and what a terminal charges for that
    # glyph is its own decision: ghostty and Terminal.app take two, kitty
    # 0.48.2 takes one — `क्ष` is a single column there, and so is `क्षि`.
    # The companion of `joined_emoji_wide`, and the same kind of question.
    getter? conjunct_wide : Bool

    # Whether a spacing mark beside a conjunct adds a column on top of the two
    # the conjunct already takes, rather than fitting inside them.
    #
    # `क्षि` is a conjunct with a vowel sign, and iTerm2 3.6.11 advances three
    # columns for it where ghostty and Terminal.app advance two. Every other
    # rule here tops out at a cell pair; this is the one reading that needs a
    # third cell, and `Cell::MAX_WIDTH` is as far as any of them may go.
    getter? conjunct_spacing_adds : Bool

    def initialize(@ambiguous : Int32 = 1,
                   @emoji_presentation : Bool = true,
                   @joined_emoji : Bool = true,
                   @joined_emoji_wide : Bool = true,
                   @regional_indicators : Bool = true,
                   @spacing_marks : Bool = true,
                   @conjunct_wide : Bool = true,
                   @conjunct_spacing_adds : Bool = false)
      raise ArgumentError.new "ambiguous width #{@ambiguous} is not 1 or 2" unless @ambiguous.in? 1, 2
    end

    # What a current terminal does.
    DEFAULT = new

    def copy_with(ambiguous : Int32 = @ambiguous,
                  emoji_presentation : Bool = @emoji_presentation,
                  joined_emoji : Bool = @joined_emoji,
                  joined_emoji_wide : Bool = @joined_emoji_wide,
                  regional_indicators : Bool = @regional_indicators,
                  spacing_marks : Bool = @spacing_marks,
                  conjunct_wide : Bool = @conjunct_wide,
                  conjunct_spacing_adds : Bool = @conjunct_spacing_adds) : WidthPolicy
      WidthPolicy.new ambiguous, emoji_presentation, joined_emoji,
        joined_emoji_wide, regional_indicators, spacing_marks, conjunct_wide,
        conjunct_spacing_adds
    end

    # The flags by the names `TERMBUF_WIDTHS` uses.
    def with(name : String, enabled : Bool) : WidthPolicy
      case name
      when "ambiguous_wide"      then copy_with ambiguous: enabled ? 2 : 1
      when "emoji_presentation"  then copy_with emoji_presentation: enabled
      when "joined_emoji"        then copy_with joined_emoji: enabled
      when "joined_emoji_wide"   then copy_with joined_emoji_wide: enabled
      when "regional_indicators" then copy_with regional_indicators: enabled
      when "spacing_marks"       then copy_with spacing_marks: enabled
      when "conjunct_wide"       then copy_with conjunct_wide: enabled
      when "conjunct_spacing_adds"
        copy_with conjunct_spacing_adds: enabled
      else
        raise ArgumentError.new "unknown width rule #{name.inspect}"
      end
    end

    # Every rule by name, for diagnostics and for `TERMBUF_WIDTHS` to check
    # against.
    NAMES = %w[ambiguous_wide emoji_presentation joined_emoji joined_emoji_wide
      regional_indicators spacing_marks conjunct_wide conjunct_spacing_adds]

    def to_s(io : IO) : Nil
      io << "WidthPolicy(ambiguous=" << @ambiguous
      NAMES.each do |name|
        next if name == "ambiguous_wide"

        io << ' ' << (enabled?(name) ? '+' : '-') << name
      end
      io << ')'
    end

    # Whether the rule *name* is on. `ambiguous_wide` reads as a flag here even
    # though it is stored as a count.
    def enabled?(name : String) : Bool
      case name
      when "ambiguous_wide"        then @ambiguous == 2
      when "emoji_presentation"    then @emoji_presentation
      when "joined_emoji"          then @joined_emoji
      when "joined_emoji_wide"     then @joined_emoji_wide
      when "regional_indicators"   then @regional_indicators
      when "spacing_marks"         then @spacing_marks
      when "conjunct_wide"         then @conjunct_wide
      when "conjunct_spacing_adds" then @conjunct_spacing_adds
      else                              raise ArgumentError.new "unknown width rule #{name.inspect}"
      end
    end
  end
end
