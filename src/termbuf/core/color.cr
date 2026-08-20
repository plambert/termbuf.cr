module TermBuf
  # A foreground, background, or underline colour.
  #
  # Colours are stored exactly as the application supplied them. Reducing a
  # 24 bit colour to the 256 colour palette, or that palette to the sixteen
  # system colours, happens at encode time against the terminal's capability
  # mask — so raising the mask and repainting yields better colour with no
  # information lost along the way.
  struct Color
    enum Kind : UInt8
      # The terminal's own default, which the application does not control.
      Default

      # An index into the 256 colour palette.
      Indexed

      # A 24 bit colour.
      Rgb
    end

    # The sixteen system colours as xterm renders them. Terminals are free to
    # remap these, which is exactly why an `Indexed` colour is never rewritten
    # to `Rgb`: only the reverse direction is a downgrade.
    SYSTEM_COLORS = StaticArray[
      0x000000, 0x800000, 0x008000, 0x808000,
      0x000080, 0x800080, 0x008080, 0xC0C0C0,
      0x808080, 0xFF0000, 0x00FF00, 0xFFFF00,
      0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]

    # The six levels each channel takes in the 6x6x6 colour cube.
    CUBE_LEVELS = StaticArray[0, 95, 135, 175, 215, 255]

    # Kind in bits 24 and up, value in the low 24 bits.
    @packed : UInt32

    private def initialize(@packed : UInt32)
    end

    # The terminal's default colour.
    def self.default : Color
      new 0_u32
    end

    # A colour from the 256 colour palette. Indices 0 through 7 are the basic
    # colours, 8 through 15 their bright counterparts, 16 through 231 the
    # colour cube, and 232 through 255 the grey ramp.
    def self.indexed(index : Int) : Color
      raise ArgumentError.new "colour index #{index} is outside 0..255" unless 0 <= index <= 255

      new (Kind::Indexed.value.to_u32 << 24) | index.to_u32
    end

    # A 24 bit colour.
    def self.rgb(red : Int, green : Int, blue : Int) : Color
      {red, green, blue}.each do |channel|
        raise ArgumentError.new "colour channel #{channel} is outside 0..255" unless 0 <= channel <= 255
      end

      new (Kind::Rgb.value.to_u32 << 24) | (red.to_u32 << 16) | (green.to_u32 << 8) | blue.to_u32
    end

    # A 24 bit colour from a packed `0xRRGGBB` value.
    def self.rgb(value : Int) : Color
      rgb (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF
    end

    def kind : Kind
      Kind.new (@packed >> 24).to_u8
    end

    def default? : Bool
      kind.default?
    end

    def indexed? : Bool
      kind.indexed?
    end

    def rgb? : Bool
      kind.rgb?
    end

    # Palette index, meaningful only for an `Indexed` colour.
    def index : Int32
      (@packed & 0xFF).to_i
    end

    def red : Int32
      ((@packed >> 16) & 0xFF).to_i
    end

    def green : Int32
      ((@packed >> 8) & 0xFF).to_i
    end

    def blue : Int32
      (@packed & 0xFF).to_i
    end

    # Whether this is one of the eight bright system colours, which some
    # terminals reach through the `90`-`97` and `100`-`107` codes rather than
    # the palette.
    def bright? : Bool
      indexed? && 8 <= index <= 15
    end

    # The colour's red, green, and blue channels. An `Indexed` colour resolves
    # through the standard xterm palette; a `Default` colour has no channels of
    # its own and reports black.
    def channels : {Int32, Int32, Int32}
      case kind
      in .default? then {0, 0, 0}
      in .rgb?     then {red, green, blue}
      in .indexed? then palette_channels
      end
    end

    private def palette_channels : {Int32, Int32, Int32}
      value = index

      if value < 16
        packed = SYSTEM_COLORS[value]
        {(packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF}
      elsif value < 232
        cube = value - 16
        {CUBE_LEVELS[cube // 36], CUBE_LEVELS[(cube // 6) % 6], CUBE_LEVELS[cube % 6]}
      else
        level = 8 + (value - 232) * 10
        {level, level, level}
      end
    end

    # The nearest colour in the 256 colour palette. `Default` and `Indexed`
    # colours are already expressible and pass through unchanged.
    def to_indexed256 : Color
      return self unless rgb?

      source = {red, green, blue}
      cube = Color.indexed nearest_cube_index(source)
      grey = Color.indexed nearest_grey_index(source)

      Color.distance(source, cube.channels) <= Color.distance(source, grey.channels) ? cube : grey
    end

    # The nearest of the sixteen system colours. A `Default` colour passes
    # through unchanged; everything else resolves through its channels.
    def to_indexed16 : Color
      return self if default?
      return self if indexed? && index < 16

      source = channels
      best = 0
      best_distance = Int32::MAX

      16.times do |candidate|
        packed = SYSTEM_COLORS[candidate]
        distance = Color.distance source,
          {(packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF}
        next unless distance < best_distance

        best = candidate
        best_distance = distance
      end

      Color.indexed best
    end

    private def nearest_cube_index(source : {Int32, Int32, Int32}) : Int32
      red_level = Color.nearest_cube_level source[0]
      green_level = Color.nearest_cube_level source[1]
      blue_level = Color.nearest_cube_level source[2]

      16 + red_level * 36 + green_level * 6 + blue_level
    end

    private def nearest_grey_index(source : {Int32, Int32, Int32}) : Int32
      # The ramp runs 8, 18, ... 238 across indices 232 through 255.
      average = (source[0] + source[1] + source[2]) // 3
      step = ((average - 8) + 5) // 10

      232 + step.clamp(0, 23)
    end

    protected def self.nearest_cube_level(value : Int32) : Int32
      best = 0
      best_distance = Int32::MAX

      CUBE_LEVELS.each_with_index do |level, position|
        distance = (level - value).abs
        next unless distance < best_distance

        best = position
        best_distance = distance
      end

      best
    end

    # Squared perceptual distance between two colours, using the low cost
    # approximation that weights the channels by the mean red level. Only the
    # ordering matters, so the square root is skipped.
    protected def self.distance(first : {Int32, Int32, Int32},
                                second : {Int32, Int32, Int32}) : Int32
      mean_red = (first[0] + second[0]) // 2
      red_delta = first[0] - second[0]
      green_delta = first[1] - second[1]
      blue_delta = first[2] - second[2]

      (((512 + mean_red) * red_delta * red_delta) >> 8) +
        4 * green_delta * green_delta +
        (((767 - mean_red) * blue_delta * blue_delta) >> 8)
    end

    def to_s(io : IO) : Nil
      case kind
      in .default? then io << "default"
      in .indexed? then io << "indexed(" << index << ')'
      in .rgb?     then io << "rgb(" << red << ", " << green << ", " << blue << ')'
      end
    end

    BLACK   = indexed 0
    RED     = indexed 1
    GREEN   = indexed 2
    YELLOW  = indexed 3
    BLUE    = indexed 4
    MAGENTA = indexed 5
    CYAN    = indexed 6
    WHITE   = indexed 7

    BRIGHT_BLACK   = indexed 8
    BRIGHT_RED     = indexed 9
    BRIGHT_GREEN   = indexed 10
    BRIGHT_YELLOW  = indexed 11
    BRIGHT_BLUE    = indexed 12
    BRIGHT_MAGENTA = indexed 13
    BRIGHT_CYAN    = indexed 14
    BRIGHT_WHITE   = indexed 15
  end
end
