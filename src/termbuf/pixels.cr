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

    # Pixel dimensions. A terminal needs these for the raw formats and reads
    # them out of the file for `Png`, where they may be left at zero.
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
    def self.png(data : Bytes) : Pixels
      new data, Format::Png
    end

    # :ditto:
    def self.png(path : String | Path) : Pixels
      png File.read(path).to_slice
    end
  end
end
