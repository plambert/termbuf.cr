module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # Pixels ready to be sent to a terminal that draws them.
  #
  # The shard does not decode or scale anything. An application hands over the
  # bytes it already has, says what they are, and says how many cells to draw
  # them across; the terminal does the scaling.
  #
  # This is a value and nothing else. It has no id, it knows no terminal, and
  # holding one costs nothing but the bytes. `ImageStore#register` turns one
  # into an `Image`, which is the thing a terminal has heard of.
  struct Pixels
    # The first bytes of every PNG file.
    PNG_SIGNATURE = Bytes[137, 80, 78, 71, 13, 10, 26, 10]

    # How far into a PNG the width and the height sit: the signature, then the
    # first chunk's length and the four letters of its type. `IHDR` is required
    # to come first, so both numbers are always here.
    PNG_DIMENSIONS = 16

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
    getter bytes : Bytes

    # What those bytes are.
    getter format : Format

    # Pixel dimensions.
    #
    # A terminal needs these for the raw formats. `.png` reads them out of the
    # header and the terminal reads them again out of the file, so they agree
    # without anyone having to say. They are zero for a `Png` whose header would
    # not parse, and a terminal still draws that: the numbers here are for
    # working out what shape to draw it in, not for sending. See
    # `Placement#fit`.
    getter width : Int32

    # :ditto:
    getter height : Int32

    # Bytes in *format*. A raw format needs its dimensions and exactly as many
    # bytes as they imply; `Png` reads both out of the file. `.rgb`, `.rgba`
    # and `.png` say the same thing more plainly.
    def initialize(@bytes : Bytes, @format : Format,
                   @width : Int32 = 0, @height : Int32 = 0)
      raise ArgumentError.new "an image needs pixels" if @bytes.empty?
      raise ArgumentError.new "image width #{@width} is negative" if @width < 0
      raise ArgumentError.new "image height #{@height} is negative" if @height < 0

      return if @format.png?
      raise ArgumentError.new "a raw image needs its dimensions" if @width.zero? || @height.zero?

      expected = @width * @height * (@format.rgb? ? 3 : 4)
      return if @bytes.size == expected

      raise ArgumentError.new "#{@format} #{@width}x#{@height} needs #{expected} bytes, " \
                              "got #{@bytes.size}"
    end

    # Three bytes a pixel, row by row from the top left.
    def self.rgb(bytes : Bytes, width : Int32, height : Int32) : Pixels
      new bytes, Format::Rgb, width, height
    end

    # :ditto:
    def self.rgba(bytes : Bytes, width : Int32, height : Int32) : Pixels
      new bytes, Format::Rgba, width, height
    end

    # A PNG file as it came off disk.
    #
    # The width and the height are read out of the header. Nothing is decoded and
    # nothing is checked beyond those first bytes: what is not a PNG at all comes
    # through with both left at zero, and it is the terminal that has the last
    # word on whether it can draw it.
    def self.png(data : Bytes) : Pixels
      width, height = png_dimensions data
      new data, Format::Png, width, height
    end

    # What a PNG's `IHDR` says it measures, or zeroes for bytes that are not one.
    #
    # Two big-endian 32 bit counts at a fixed offset. A width past `Int32::MAX`
    # is nothing this shard can hold and nothing any terminal will draw, so it
    # comes back as zero rather than as a raise: these bytes are the caller's
    # picture, not the caller's mistake.
    def self.png_dimensions(data : Bytes) : {Int32, Int32}
      return {0, 0} if data.size < PNG_DIMENSIONS + 8
      return {0, 0} unless data[0, PNG_SIGNATURE.size] == PNG_SIGNATURE
      return {0, 0} unless String.new(data[12, 4]) == "IHDR"

      width = read_u32 data, PNG_DIMENSIONS
      height = read_u32 data, PNG_DIMENSIONS + 4
      return {0, 0} if width > Int32::MAX || height > Int32::MAX

      {width.to_i, height.to_i}
    end

    private def self.read_u32(data : Bytes, at : Int32) : UInt32
      (data[at].to_u32 << 24) | (data[at + 1].to_u32 << 16) |
        (data[at + 2].to_u32 << 8) | data[at + 3].to_u32
    end

    # :ditto:
    def self.png(path : String | Path) : Pixels
      png File.read(path).to_slice
    end
  end
end
