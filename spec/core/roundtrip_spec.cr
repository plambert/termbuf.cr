require "../spec_helper"
require "../support/model_terminal"

# The property the whole paint algorithm rests on:
#
#     model.apply(encode(paint(buffer))) == buffer.back
#
# Anything the painter decides — skipping a gap, erasing instead of writing
# spaces, scrolling instead of redrawing — has to survive this. A cheaper byte
# stream that puts the wrong thing on screen fails here and nowhere else.
private ALPHABET = [
  "a", "b", "Z", " ", "#", "0", "~",
  "漢", "か", "한",
  "é", "á̂",
  "😀", "☀️",
  "\u{1F1FA}\u{1F1F8}",
  "क्ष",
  "hello", "a漢b", "x́y", "  ",
]

private STYLES = [
  TermBuf::Style::DEFAULT,
  TermBuf::Style::DEFAULT.bold,
  TermBuf::Style::DEFAULT.italic.fg(TermBuf::Color::RED),
  TermBuf::Style::DEFAULT.fg(TermBuf::Color.indexed(200)),
  TermBuf::Style::DEFAULT.bg(TermBuf::Color.rgb(10, 20, 30)),
  TermBuf::Style::DEFAULT.fg(TermBuf::Color::BRIGHT_CYAN).bg(TermBuf::Color::BLUE),
  TermBuf::Style::DEFAULT.underlined(TermBuf::Underline::Curly, TermBuf::Color::RED),
  TermBuf::Style::DEFAULT.reverse.strike,
  TermBuf::Style::DEFAULT.bold.faint.blink,
]

private LINKS = ["https://example.com/a", "https://example.com/b"]

# A style, sometimes carrying a hyperlink. The link has to be interned into the
# buffer's own table, so it cannot live in the constant above.
private def random_style(buffer : TermBuf::Buffer, random : Random) : TermBuf::Style
  style = STYLES.sample random
  return style unless random.rand(4).zero?

  style.linked buffer.link(LINKS.sample(random), random.rand(2).zero? ? nil : "group")
end

# Drives one paint cycle and reports any disagreement between the terminal's
# screen and the buffer.
private class Harness
  getter buffer : TermBuf::Buffer
  getter terminal : ModelTerminal
  getter bytes = 0

  def initialize(width : Int32, height : Int32, capabilities : TermBuf::Capabilities)
    @buffer = TermBuf::Buffer.new width, height
    @terminal = ModelTerminal.new width, height, links: @buffer.links
    @painter = TermBuf::Painter.new capabilities
    @encoder = TermBuf::Encoder.new @buffer.styles, capabilities, width, height, @buffer.links
  end

  # Paints, feeds the result to the model terminal, and reports what still
  # differs. `nil` means the screen matches the buffer.
  def cycle : String?
    emit
    @terminal.diff @buffer, @encoder
  end

  # Paints and returns the bytes, without checking the result.
  def emit : String
    output = @encoder.encode @painter.paint(@buffer)
    @bytes += output.bytesize
    @terminal.feed output
    @buffer.commit_paint
    output
  end
end

private def apply_operation(buffer : TermBuf::Buffer, random : Random) : Nil
  case random.rand 13
  when 0..5
    buffer.write random.rand(buffer.width), random.rand(buffer.height),
      ALPHABET.sample(random), random_style(buffer, random)
  when 6
    buffer.write_char random.rand(buffer.width), random.rand(buffer.height),
      ALPHABET.sample(random)[0], random_style(buffer, random)
  when 7, 8
    buffer.scroll random_rect(buffer, random), random.rand(-2..2), random_style(buffer, random)
  when 9
    buffer.fill random_rect(buffer, random), '#', random_style(buffer, random)
  when 10
    buffer.fill random_rect(buffer, random), ' ', TermBuf::Style::DEFAULT
  when 11
    fill_gradient buffer, random
  else
    buffer.clear random_style(buffer, random)
  end
end

# A panel tinted by a `Gradient` carried on the view, which is what makes the
# painter deal with a run of 24 bit colours that change every cell. Under the
# shallower masks the encoder narrows them, so neighbouring cells collapse to
# one palette entry and the model terminal has to agree about where the runs
# now end.
private def fill_gradient(buffer : TermBuf::Buffer, random : Random) : Nil
  area = random_rect buffer, random
  axis = random.rand(2).zero? ? TermBuf::Gradient::Axis::Horizontal : TermBuf::Gradient::Axis::Vertical
  ramp = TermBuf::Gradient.new TermBuf::Color.rgb(10, 90, 200), TermBuf::Color.rgb(240, 30, 5),
    TermBuf::Rect.new(0, 0, area.width, area.height), axis
  screen = TermBuf::BufferSurface.new buffer

  screen.view(area, blend: ramp.background).clear
end

# Weighted toward full-width rectangles, which is what the scroll extractor can
# actually act on.
private def random_rect(buffer : TermBuf::Buffer, random : Random) : TermBuf::Rect
  if random.rand(2).zero?
    y = random.rand buffer.height
    return TermBuf::Rect.new 0, y, buffer.width, random.rand(1..buffer.height - y)
  end

  x = random.rand buffer.width
  y = random.rand buffer.height

  TermBuf::Rect.new x, y, random.rand(1..buffer.width - x), random.rand(1..buffer.height - y)
end

Spectator.describe "paint round trip" do
  {% for mask in %w[MODERN XTERM ANSI NONE] %}
    describe "against a {{ mask.downcase.id }} terminal" do
      let(caps) { TermBuf::Capabilities::{{ mask.id }} }

      it "reproduces a screen written once" do
        harness = Harness.new 20, 6, caps
        harness.buffer.write 0, 0, "hello world"
        harness.buffer.write 3, 2, "漢字テスト", STYLES[2]
        harness.buffer.write 0, 4, "😀 flags \u{1F1FA}\u{1F1F8}", STYLES[4]

        expect(harness.cycle).to be_nil
      end

      it "reproduces a screen changed a little at a time" do
        harness = Harness.new 20, 6, caps
        harness.buffer.write 0, 0, "the quick brown fox"
        expect(harness.cycle).to be_nil

        harness.buffer.write 4, 0, "slow", STYLES[1]
        expect(harness.cycle).to be_nil

        harness.buffer.write 0, 3, "and back again"
        expect(harness.cycle).to be_nil
      end

      it "reproduces a scrolled screen" do
        harness = Harness.new 20, 6, caps
        6.times { |row| harness.buffer.write 0, row, "line #{row}" }
        expect(harness.cycle).to be_nil

        harness.buffer.scroll harness.buffer.bounds, 2
        harness.buffer.write 0, 4, "line 6"
        harness.buffer.write 0, 5, "line 7"
        expect(harness.cycle).to be_nil
      end

      it "reproduces a partially scrolled screen" do
        harness = Harness.new 20, 6, caps
        6.times { |row| harness.buffer.write 0, row, "line #{row}" }
        expect(harness.cycle).to be_nil

        harness.buffer.scroll TermBuf::Rect.new(0, 1, 20, 4), 1
        expect(harness.cycle).to be_nil
      end

      it "reproduces a cleared screen" do
        harness = Harness.new 20, 6, caps
        6.times { |row| harness.buffer.write 0, row, "filled #{row}" }
        expect(harness.cycle).to be_nil

        harness.buffer.clear
        expect(harness.cycle).to be_nil
      end

      it "reproduces a screen tinted with a background" do
        harness = Harness.new 20, 6, caps
        harness.buffer.clear STYLES[4]
        harness.buffer.write 2, 2, "on a tint", STYLES[4]

        expect(harness.cycle).to be_nil
      end

      it "reproduces a panel tinted by a gradient" do
        harness = Harness.new 20, 6, caps
        panel = TermBuf::Rect.new 2, 1, 12, 4
        ramp = TermBuf::Gradient.new TermBuf::Color.rgb(0x102080), TermBuf::Color.rgb(0xE04010),
          TermBuf::Rect.new(0, 0, panel.width, panel.height), :vertical
        screen = TermBuf::BufferSurface.new harness.buffer

        screen.view(panel, blend: ramp.background).clear
        screen.view(panel).write 1, 1, "over the ramp", TermBuf::Style::DEFAULT.bold,
          blend: TermBuf::Style::KEEP_BACKGROUND

        expect(harness.cycle).to be_nil
      end

      sample [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64] do |seed|
        it "holds across a random sequence (seed #{seed})" do
          random = Random.new seed
          harness = Harness.new 16, 6, caps

          60.times do |step|
            random.rand(1..4).times { apply_operation harness.buffer, random }

            if failure = harness.cycle
              fail "seed #{seed}, step #{step}: #{failure}"
            end
          end
        end
      end
    end
  {% end %}

  # A panel with a border down the right of the screen leaves blanks in the
  # middle of a row and a glyph in the last column. Erasing to the end of the
  # line takes the glyph with the blanks, and only a terminal shows it: the
  # buffer was right the whole time.
  it "keeps the last cell of a row an erase would have reached" do
    harness = Harness.new 20, 6, TermBuf::Capabilities::MODERN
    harness.buffer.fill TermBuf::Rect.new(0, 1, 20, 1), '-'
    harness.cycle

    harness.buffer.fill TermBuf::Rect.new(0, 1, 20, 1), ' '
    harness.buffer.write_char 0, 1, '|'
    harness.buffer.write 1, 1, "text"
    harness.buffer.write_char 19, 1, '|'

    expect(harness.cycle).to be_nil
  end

  it "emits nothing when a paint would change nothing" do
    harness = Harness.new 20, 6, TermBuf::Capabilities::MODERN
    harness.buffer.write 0, 0, "settled"
    harness.cycle

    expect(harness.emit).to eq ""
  end
end
