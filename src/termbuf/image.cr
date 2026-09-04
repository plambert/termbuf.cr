require "base64"

require "./caps/capability"
require "./core/rect"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # Pixels ready to be sent to a terminal that draws them.
  #
  # The shard does not decode or scale anything. An application hands over the
  # bytes it already has, says what they are, and says how many cells to draw
  # them across; the terminal does the scaling.
  struct Image
    # What the bytes are, by the numbers the graphics protocol uses.
    enum Format
      # Three bytes per pixel.
      Rgb = 24

      # Four bytes per pixel, the fourth being alpha.
      Rgba = 32

      # A PNG file, header and all.
      Png = 100
    end

    # The bytes as the terminal will receive them.
    getter pixels : Bytes

    # What those bytes are.
    getter format : Format

    # Pixel dimensions. A terminal needs these for the raw formats and reads
    # them out of the file for `Png`, where they may be left at zero.
    getter width : Int32

    # :ditto:
    getter height : Int32

    def initialize(@pixels : Bytes, @format : Format,
                   @width : Int32 = 0, @height : Int32 = 0)
      raise ArgumentError.new "an image needs pixels" if @pixels.empty?
      raise ArgumentError.new "image width #{@width} is negative" if @width < 0
      raise ArgumentError.new "image height #{@height} is negative" if @height < 0

      return if @format.png?
      raise ArgumentError.new "a raw image needs its dimensions" if @width.zero? || @height.zero?

      expected = @width * @height * (@format.rgb? ? 3 : 4)
      return if @pixels.size == expected

      raise ArgumentError.new "#{@format} #{@width}x#{@height} needs #{expected} bytes, " \
                              "got #{@pixels.size}"
    end

    # Three bytes a pixel, row by row from the top left.
    def self.rgb(pixels : Bytes, width : Int32, height : Int32) : Image
      new pixels, Format::Rgb, width, height
    end

    # :ditto:
    def self.rgba(pixels : Bytes, width : Int32, height : Int32) : Image
      new pixels, Format::Rgba, width, height
    end

    # A PNG file as it came off disk.
    def self.png(data : Bytes) : Image
      new data, Format::Png
    end

    # :ditto:
    def self.png(path : String | Path) : Image
      png File.read(path).to_slice
    end
  end

  # Stability: stable — changes only in a major release.
  #
  # An image on screen: which image, and the cells it covers.
  struct Placement
    # Which image, by the id the protocol refers to it with.
    getter image : UInt32

    # Which placement of that image, since one image may be on screen more
    # than once.
    getter id : UInt32

    # The cells it covers.
    getter bounds : Rect

    # Where this sits in the stack against the text and the other placements.
    #
    # Zero is over the text, which is the default and what an image drawn to be
    # looked at wants. Negative is under it, so the cells keep their glyphs and
    # the picture shows through wherever they are blank — a chart behind a
    # table, a watermark. Higher covers lower among placements, so a cascade is
    # a rising *z* and nothing else.
    #
    # The protocol's own rule for the boundary: text is drawn between `-1` and
    # `0`, so `-1` is the topmost layer still beneath it.
    getter z : Int32

    def initialize(@image : UInt32, @id : UInt32, @bounds : Rect, @z : Int32 = 0)
    end

    # Whether this sits beneath the text rather than over it.
    def under_text? : Bool
      @z.negative?
    end

    # Column of the left edge.
    def x : Int32
      @bounds.x
    end

    # Row of the top edge.
    def y : Int32
      @bounds.y
    end
  end
end
