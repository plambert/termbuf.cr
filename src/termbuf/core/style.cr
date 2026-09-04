require "./color"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # Character attributes that can be combined freely.
  #
  # The underline *styles* are deliberately not in here: a cell has at most one
  # of them, so they live in `Underline` where the type enforces that.
  @[Flags]
  enum Attributes : UInt16
    Bold
    Faint
    Italic
    SlowBlink
    RapidBlink
    Reverse
    Conceal
    Strike
    Overline
    Superscript
    Subscript
  end

  # Stability: stable — changes only in a major release.
  #
  # The underline styles of SGR 4, including the `4:x` subparameter forms that
  # modern terminals accept.
  enum Underline : UInt8
    None
    Single
    Double
    Curly
    Dotted
    Dashed
  end

  # Stability: stable — changes only in a major release.
  #
  # Everything about a cell other than the character in it.
  #
  # Styles are values, so they compare and hash by content. `StyleTable`
  # interns them, which is what lets a `Cell` carry a four byte id instead of
  # this whole struct.
  struct Style
    # Text colour.
    getter foreground : Color

    # Cell colour behind the text.
    getter background : Color

    # Colour of the underline, when the terminal supports colouring it
    # separately from the text.
    getter underline_color : Color

    # Everything a cell can be at once.
    getter attributes : Attributes

    # Which of the underline styles, if any.
    getter underline : Underline

    # OSC 8 hyperlink id, or zero for no link. Populated once link support
    # lands; the buffer carries it through in the meantime.
    getter link : UInt32

    def initialize(@foreground : Color = Color.default,
                   @background : Color = Color.default,
                   @underline_color : Color = Color.default,
                   @attributes : Attributes = Attributes::None,
                   @underline : Underline = Underline::None,
                   @link : UInt32 = 0_u32)
    end

    # The style a freshly cleared terminal is in.
    DEFAULT = new

    # Whether this is the untouched style, which needs no escape sequence.
    def default? : Bool
      self == DEFAULT
    end

    # Returns a copy with the named fields replaced.
    def copy_with(foreground : Color = @foreground,
                  background : Color = @background,
                  underline_color : Color = @underline_color,
                  attributes : Attributes = @attributes,
                  underline : Underline = @underline,
                  link : UInt32 = @link) : Style
      Style.new foreground, background, underline_color, attributes, underline, link
    end

    # A copy with a different text colour.
    def fg(color : Color) : Style
      copy_with foreground: color
    end

    # A copy with a different background.
    def bg(color : Color) : Style
      copy_with background: color
    end

    # A copy carrying an underline. Terminals without `ExtendedUnderline`
    # render every style as a plain one, and without `UnderlineColor` ignore
    # *color*.
    def underlined(style : Underline = Underline::Single, color : Color = @underline_color) : Style
      copy_with underline: style, underline_color: color
    end

    # A copy carrying OSC 8 link *id*. Zero means no link.
    def linked(id : UInt32) : Style
      copy_with link: id
    end

    # A copy of this style with everything *other* sets taking over. A field
    # *other* leaves at its default is kept from here.
    #
    # What a surface carrying a base style needs: a panel says its background
    # once, and a write inside it names only the colour and the attributes it
    # cares about. Colours, the underline style, and the link merge that way.
    #
    # Attributes are the exception. They are flags rather than a choice of one,
    # so they combine: a bold write inside a faint panel is both, and there is
    # no value of `Attributes` that means "leave the panel's alone" separately
    # from "add none of my own".
    def merge(other : Style) : Style
      Style.new(
        other.foreground.default? ? @foreground : other.foreground,
        other.background.default? ? @background : other.background,
        other.underline_color.default? ? @underline_color : other.underline_color,
        @attributes | other.attributes,
        other.underline.none? ? @underline : other.underline,
        other.link.zero? ? @link : other.link)
    end

    # A blend that keeps the colour already behind each cell and takes
    # everything else from the style being written — a label across a progress
    # bar, without the caller working out where the bar's colours change. A
    # background named in the written style is ignored.
    #
    # The position is ignored: this blend answers the same way wherever the
    # cell is, which is why the two arguments it does use are named and the
    # rest are not.
    KEEP_BACKGROUND = Blend.new { |under, over, _column, _row| over.bg under.background }

    # A blend laying the written style over what is already there, field by
    # field, the way a view lays its own style under a write. See `#merge`.
    #
    # The position is ignored, as it is for `KEEP_BACKGROUND`.
    OVER = Blend.new { |under, over, _column, _row| under.merge over }

    # Wraps a two argument block as a `Blend`, for the blends that answer from
    # the two styles alone.
    #
    #     dim = TermBuf::Style.blend { |under, over| under.merge(over).faint }
    #
    # The position the `Blend` signature carries is dropped rather than named,
    # since a block written this way has nowhere to receive it.
    def self.blend(&block : Style, Style -> Style) : Blend
      Blend.new { |under, over, _column, _row| block.call under, over }
    end

    # Returns a copy with *flags* added.
    def with(flags : Attributes) : Style
      copy_with attributes: @attributes | flags
    end

    # Returns a copy with *flags* removed.
    def without(flags : Attributes) : Style
      copy_with attributes: @attributes & ~flags
    end

    # A copy with the bold attribute set.
    def bold : Style
      self.with Attributes::Bold
    end

    # A copy with the faint attribute set.
    def faint : Style
      self.with Attributes::Faint
    end

    # A copy with the italic attribute set.
    def italic : Style
      self.with Attributes::Italic
    end

    # A copy with foreground and background swapped by the terminal.
    def reverse : Style
      self.with Attributes::Reverse
    end

    # A copy with the strike-through attribute set.
    def strike : Style
      self.with Attributes::Strike
    end

    # A copy the terminal renders as blanks.
    def conceal : Style
      self.with Attributes::Conceal
    end

    # A copy that blinks, slowly unless *rapid*.
    def blink(rapid : Bool = false) : Style
      self.with rapid ? Attributes::RapidBlink : Attributes::SlowBlink
    end

    # Whether every attribute in *flags* is set.
    def has?(flags : Attributes) : Bool
      @attributes.includes? flags
    end

    # Whether the cell paints anything other than its background. A cell that
    # does not is interchangeable with a blank of the same background, which is
    # what lets the painter reach for an erase instead of writing spaces.
    def ink? : Bool
      !@underline.none? || @attributes.includes?(Attributes::Reverse) ||
        @attributes.includes?(Attributes::Strike) ||
        @attributes.includes?(Attributes::Overline) || @link != 0
    end

    def to_s(io : IO) : Nil
      io << "Style(fg=" << foreground << ", bg=" << background
      io << ", " << attributes unless attributes.none?
      io << ", underline=" << underline unless underline.none?
      io << ", link=" << link unless link.zero?
      io << ')'
    end
  end

  # Stability: stable — changes only in a major release.
  #
  # How a write settles the style of each cell it lands on: given the style
  # already there, the style being written, and the cell's position, it returns
  # the style to place.
  #
  #     dim = TermBuf::Style.blend { |under, over| under.merge(over).faint }
  #     screen.write 0, 0, "over a shadow", Style::DEFAULT, blend: dim
  #
  # `Style::KEEP_BACKGROUND` and `Style::OVER` cover the two common answers,
  # and `Style.blend` wraps a block that only wants the two styles.
  #
  # The position is in the *buffer's* coordinates, not those of whatever view
  # the write went through: a view translates the write before the buffer runs
  # the blend, so a blend keyed on position sees where the cell actually is.
  #
  # A blend is run per cell and its answer is interned, and `StyleTable` only
  # grows. One returning a colour computed from the position — a gradient —
  # therefore interns a style per cell. That is bounded by the screen for a
  # single frame and fine; recomputed every frame from different colours it is
  # unbounded, and an animation wanting that should draw from a fixed palette
  # of styles instead.
  alias Blend = Proc(Style, Style, Int32, Int32, Style)
end
