require "./caps/response_scanner"
require "./core/style"

module TermBuf
  # Reads the escape sequences an application writes to a cursor and turns the
  # ones about appearance into `Style` changes.
  #
  # This is what makes `io.print "\e[1mbold\e[0m"` set the bold attribute on
  # cells rather than putting escape bytes into them. A cursor marked raw skips
  # it, which is the whole point of that flag: an application that changes style
  # by assigning to `Cursor#style` pays nothing for a scan that would find
  # nothing.
  #
  # Sequences that say something a cell cannot hold — cursor movement, screen
  # clearing, anything addressing the terminal rather than the text — are
  # consumed and dropped. Honouring them would mean a second, competing idea of
  # where the cursor is, and the buffer already has one.
  #
  # The parser is separate from the encoder's SGR writer on purpose. They are
  # each other's inverse, and a spec that ran text through both would pass on a
  # pair of matching mistakes.
  class SgrScanner
    def initialize
      @scanner = ResponseScanner.new
    end

    # Feeds bytes in, yielding each run of printable text with the style in
    # force at the time. Returns the style left in force afterwards.
    #
    # Bytes that do not yet form a complete sequence are held until the rest of
    # them arrives, so an application is free to write an escape sequence in as
    # many pieces as it likes.
    def scan(bytes : Bytes, style : Style, &emit : String, Style ->) : Style
      current = style

      @scanner.feed bytes do |kind, chunk|
        if kind.text?
          emit.call String.new(chunk), current
        else
          current = interpret chunk, current
        end
      end

      current
    end

    # Whether an incomplete sequence is being held back.
    def pending? : Bool
      @scanner.pending?
    end

    # Drops anything held back. For a cursor being pointed at something else,
    # where half a sequence from the old text has no business colouring the new.
    def clear : Nil
      @scanner.clear
    end

    # What one complete escape sequence does to *style*.
    private def interpret(sequence : Bytes, style : Style) : Style
      return style unless sequence.size >= 3
      return style unless sequence[1] == '['.ord

      text = String.new sequence[2..]
      return style unless text.ends_with? 'm'

      apply text[0, text.size - 1], style
    end

    # ------------------------------------------------------------------ sgr

    # An empty parameter list means SGR 0, which is why `ESC [ m` resets.
    private def apply(parameters : String, style : Style) : Style
      return Style::DEFAULT if parameters.empty?

      fields = parameters.split ';'
      index = 0

      while index < fields.size
        style, index = apply_field fields, index, style
      end

      style
    end

    # Returns the style after the field at *index*, and the index of the next
    # one — extended colours run over several fields when they are separated by
    # semicolons rather than colons.
    private def apply_field(fields : Array(String), index : Int32,
                            style : Style) : {Style, Int32}
      # An empty parameter is a zero, which is why `ESC [ ; 1 m` resets first.
      parts = fields[index].split ':'
      code = parts[0].to_i? || 0

      case code
      when 4          then {underline_field(parts, style), index + 1}
      when 38, 48, 58 then colour_field fields, parts, index, code, style
      else                 {simple(code, style), index + 1}
      end
    end

    # `4` alone is a plain underline; `4:0` through `4:5` name a style, and a
    # terminal that cannot draw the fancier ones still gets told which was
    # wanted so a later repaint under a wider capability mask comes out right.
    private def underline_field(parts : Array(String), style : Style) : Style
      return style.copy_with underline: Underline::Single if parts.size < 2

      value = parts[1].to_i? || 0
      return style if value > Underline.values.size - 1

      style.copy_with underline: Underline.new(value.to_u8)
    end

    # `38`, `48`, and `58` take their argument either in following fields
    # (`38;5;9`) or as subparameters of their own (`38:5:9`). The colon form is
    # the one that nests properly; the semicolon form is the one everything
    # emits.
    private def colour_field(fields : Array(String), parts : Array(String),
                             index : Int32, code : Int32,
                             style : Style) : {Style, Int32}
      if parts.size > 1
        colour = read_colour parts, 1
        return {tint(style, code, colour || Color.default), index + 1}
      end

      kind = fields[index + 1]?.try(&.to_i?)
      taken = kind == 2 ? 5 : 3
      colour = read_colour fields, index + 1

      {colour ? tint(style, code, colour) : style, index + taken}
    end

    # A colour written as `5;n` or `2;r;g;b`, starting at *offset*. The colon
    # form sometimes carries an empty colour space field before the channels,
    # which is what the extra step is for.
    private def read_colour(fields : Array(String), offset : Int32) : Color?
      case fields[offset]?.try(&.to_i?)
      when 5
        index = fields[offset + 1]?.try(&.to_i?)
        index && 0 <= index <= 255 ? Color.indexed(index) : nil
      when 2
        # The colon form carries a colour space field before the channels, and
        # everything that writes it leaves that field empty.
        start = fields[offset + 1]?.try(&.empty?) ? offset + 2 : offset + 1
        red = channel fields, start
        green = channel fields, start + 1
        blue = channel fields, start + 2
        red && green && blue ? Color.rgb(red, green, blue) : nil
      end
    end

    private def channel(fields : Array(String), index : Int32) : Int32?
      value = fields[index]?.try &.to_i?
      value if value && 0 <= value <= 255
    end

    private def tint(style : Style, code : Int32, colour : Color) : Style
      case code
      when 38 then style.fg colour
      when 48 then style.bg colour
      else         style.copy_with underline_color: colour
      end
    end

    # ---------------------------------------------------------------- codes

    # The attributes, by the code that sets and the code that clears each.
    ATTRIBUTES = {
       1 => Attributes::Bold,
       2 => Attributes::Faint,
       3 => Attributes::Italic,
       5 => Attributes::SlowBlink,
       6 => Attributes::RapidBlink,
       7 => Attributes::Reverse,
       8 => Attributes::Conceal,
       9 => Attributes::Strike,
      53 => Attributes::Overline,
      73 => Attributes::Superscript,
      74 => Attributes::Subscript,
    }

    # A clearing code often undoes more than one attribute: 22 covers both
    # weights, 25 both blink rates, and 75 both scripts.
    CLEARS = {
      22 => Attributes::Bold | Attributes::Faint,
      23 => Attributes::Italic,
      25 => Attributes::SlowBlink | Attributes::RapidBlink,
      27 => Attributes::Reverse,
      28 => Attributes::Conceal,
      29 => Attributes::Strike,
      55 => Attributes::Overline,
      75 => Attributes::Superscript | Attributes::Subscript,
    }

    private def simple(code : Int32, style : Style) : Style
      if flags = ATTRIBUTES[code]?
        return style.with flags
      end

      if flags = CLEARS[code]?
        return style.without flags
      end

      colour code, style
    end

    private def colour(code : Int32, style : Style) : Style
      case code
      when 0        then Style::DEFAULT
      when 21       then style.copy_with underline: Underline::Double
      when 24       then style.copy_with underline: Underline::None
      when 30..37   then style.fg Color.indexed(code - 30)
      when 39       then style.fg Color.default
      when 40..47   then style.bg Color.indexed(code - 40)
      when 49       then style.bg Color.default
      when 59       then style.copy_with underline_color: Color.default
      when 90..97   then style.fg Color.indexed(code - 82)
      when 100..107 then style.bg Color.indexed(code - 92)
      else               style
      end
    end
  end
end
