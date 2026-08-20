require "./color"

module TermBuf
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

  # Everything about a cell other than the character in it.
  #
  # Styles are values, so they compare and hash by content. `StyleTable`
  # interns them, which is what lets a `Cell` carry a four byte id instead of
  # this whole struct.
  struct Style
    getter foreground : Color
    getter background : Color

    # Colour of the underline, when the terminal supports colouring it
    # separately from the text.
    getter underline_color : Color

    getter attributes : Attributes
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

    def fg(color : Color) : Style
      copy_with foreground: color
    end

    def bg(color : Color) : Style
      copy_with background: color
    end

    def underlined(style : Underline = Underline::Single, color : Color = @underline_color) : Style
      copy_with underline: style, underline_color: color
    end

    def linked(id : UInt32) : Style
      copy_with link: id
    end

    # Returns a copy with *flags* added.
    def with(flags : Attributes) : Style
      copy_with attributes: @attributes | flags
    end

    # Returns a copy with *flags* removed.
    def without(flags : Attributes) : Style
      copy_with attributes: @attributes & ~flags
    end

    def bold : Style
      self.with Attributes::Bold
    end

    def faint : Style
      self.with Attributes::Faint
    end

    def italic : Style
      self.with Attributes::Italic
    end

    def reverse : Style
      self.with Attributes::Reverse
    end

    def strike : Style
      self.with Attributes::Strike
    end

    def conceal : Style
      self.with Attributes::Conceal
    end

    def blink(rapid : Bool = false) : Style
      self.with rapid ? Attributes::RapidBlink : Attributes::SlowBlink
    end

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
end
