require "../spec_helper"
require "../support/model_terminal"

private alias Name = TermBuf::Key::Name
private alias Growth = TermBuf::Field::Growth

# Draws a field into a buffer, paints it, and reads the screen back through the
# model terminal, so what is asserted is what a terminal would show rather than
# what the buffer happens to hold.
private def render(field : TermBuf::Field, columns = 30, rows = 6) : Array(String)
  buffer = TermBuf::Buffer.new columns, rows
  surface = TermBuf::BufferSurface.new buffer
  buffer.clear
  field.draw surface

  painter = TermBuf::Painter.new TermBuf::Capabilities::XTERM
  encoder = TermBuf::Encoder.new buffer.styles, TermBuf::Capabilities::XTERM, columns, rows
  model = ModelTerminal.new columns, rows
  model.feed encoder.encode(painter.paint(buffer))
  buffer.commit_paint

  model.to_text.split('\n').map &.rstrip
end

private def field(text : String = "", **options) : TermBuf::Field
  made = TermBuf::Field.new(**options)
  made.text = text
  made
end

private def type(field : TermBuf::Field, text : String) : Nil
  text.each_char { |char| field.handle TermBuf::Key.character(char) }
end

Spectator.describe TermBuf::Border do
  it "closes the box on all four sides" do
    buffer = TermBuf::Buffer.new 6, 3
    buffer.clear
    TermBuf::Border.plain.draw TermBuf::BufferSurface.new(buffer), TermBuf::Rect.new(0, 0, 6, 3)

    expect(buffer.to_text.split('\n')).to eq ["┌────┐", "│    │", "└────┘"]
  end

  it "puts a title in the top edge" do
    buffer = TermBuf::Buffer.new 12, 3
    buffer.clear
    TermBuf::Border.rounded(title: "name").draw TermBuf::BufferSurface.new(buffer),
      TermBuf::Rect.new(0, 0, 12, 3)

    expect(buffer.to_text.split('\n').first).to eq "╭─name─────╮"
  end

  it "trims a title that will not fit, at a cluster boundary" do
    buffer = TermBuf::Buffer.new 8, 3
    buffer.clear
    TermBuf::Border.plain(title: "漢字漢字").draw TermBuf::BufferSurface.new(buffer),
      TermBuf::Rect.new(0, 0, 8, 3)

    expect(buffer.to_text.split('\n').first).to eq "┌─漢字─┐"
  end

  it "leaves room for what it surrounds" do
    inside = TermBuf::Border.inset TermBuf::Rect.new(2, 3, 10, 4)

    expect(inside).to eq TermBuf::Rect.new(3, 4, 8, 2)
  end
end

Spectator.describe TermBuf::Field do
  describe "drawing" do
    it "shows the text with the prompt in front of it" do
      made = field "hello",
        bounds: TermBuf::Rect.new(0, 0, 20, 1),
        prompt: TermBuf::Field::Prompt.new("> ")

      expect(render(made).first).to eq "> hello"
    end

    it "draws a border around itself" do
      made = field "hi",
        bounds: TermBuf::Rect.new(0, 0, 8, 3),
        border: TermBuf::Border.plain

      expect(render(made).first(3)).to eq ["┌──────┐", "│hi    │", "└──────┘"]
    end

    it "shows the placeholder while there is nothing to show" do
      made = field bounds: TermBuf::Rect.new(0, 0, 20, 1), placeholder: "type here"

      expect(render(made).first).to eq "type here"

      made.text = "x"
      expect(render(made).first).to eq "x"
    end
  end

  describe "a fixed field" do
    it "stays one row however long the text is" do
      made = field "a" * 50, bounds: TermBuf::Rect.new(0, 0, 10, 1)

      expect(made.text_rows).to eq 1
      expect(made.desired_height).to eq 1
    end

    # What is off the edge should be visible as missing rather than merely
    # absent.
    it "scrolls sideways and marks what is off the edge" do
      made = field bounds: TermBuf::Rect.new(0, 0, 10, 1)
      type made, "abcdefghijklmno"

      line = render(made).first
      expect(line.starts_with? "<").to be_true
      expect(line).to contain "o"
    end

    it "scrolls back when the cursor goes left again" do
      made = field bounds: TermBuf::Rect.new(0, 0, 10, 1)
      type made, "abcdefghijklmno"
      made.handle TermBuf::Key.named(Name::Home)

      expect(made.offset).to eq 0
      expect(render(made).first.starts_with? "a").to be_true
    end

    it "flattens a pasted line break" do
      made = field bounds: TermBuf::Rect.new(0, 0, 20, 1)
      made.paste "one\ntwo"

      expect(made.text).to eq "one two"
    end
  end

  describe "a growing field" do
    it "wraps at the right edge and asks for the rows it needs" do
      made = field "abcdefgh",
        bounds: TermBuf::Rect.new(0, 0, 4, 1),
        growth: Growth::Grow, max_rows: 8

      expect(made.rows.size).to eq 3
      expect(made.desired_height).to eq 3
    end

    it "never splits a wide cluster across the edge" do
      made = field "a漢漢",
        bounds: TermBuf::Rect.new(0, 0, 4, 3),
        growth: Growth::Grow

      expect(render(made).first(2)).to eq ["a漢", "漢"]
    end

    it "keeps a line break where it was put" do
      made = field "one\ntwo",
        bounds: TermBuf::Rect.new(0, 0, 10, 2),
        growth: Growth::Grow

      expect(render(made).first(2)).to eq ["one", "two"]
    end

    it "indents the rows after the first under the prompt" do
      made = field "abcde",
        bounds: TermBuf::Rect.new(0, 0, 5, 2),
        prompt: TermBuf::Field::Prompt.new("> ", continuation: ".."),
        growth: Growth::Grow

      expect(render(made).first(2)).to eq ["> abc", "..de"]
    end

    # Text that exactly fills a row leaves the cursor with nowhere to go, so
    # the row it will type into has to exist.
    it "asks for a row to put the cursor on after a full one" do
      made = field "abcd",
        bounds: TermBuf::Rect.new(0, 0, 4, 1),
        growth: Growth::Grow

      expect(made.rows.size).to eq 2
      expect(made.desired_height).to eq 2
    end

    # A view too short for the text follows the cursor rather than showing the
    # top and losing it.
    it "scrolls to keep the cursor in view" do
      made = field "abcdefghi",
        bounds: TermBuf::Rect.new(0, 0, 3, 2),
        growth: Growth::Grow, max_rows: 2

      expect(render(made).first(2)).to eq ["ghi", ""]
      made.buffer.move_to 0

      expect(render(made).first(2)).to eq ["abc", "def"]
    end

    it "stops growing at the height it was given" do
      made = field "a" * 40,
        bounds: TermBuf::Rect.new(0, 0, 5, 3),
        growth: Growth::Grow, max_rows: 3

      expect(made.desired_height).to eq 3
    end
  end

  describe "#cursor_position" do
    it "sits where the next character goes" do
      made = field bounds: TermBuf::Rect.new(2, 1, 20, 1),
        prompt: TermBuf::Field::Prompt.new("> ")
      type made, "abc"

      expect(made.cursor_position).to eq({7, 1})
    end

    it "allows for a wide cluster in front of it" do
      made = field bounds: TermBuf::Rect.new(0, 0, 20, 1)
      type made, "漢"

      expect(made.cursor_position).to eq({2, 0})
    end

    it "moves inside the border" do
      made = field "ab", bounds: TermBuf::Rect.new(0, 0, 10, 3),
        border: TermBuf::Border.plain

      expect(made.cursor_position).to eq({3, 1})
    end

    # A cursor after a row that is exactly full belongs at the start of the
    # next one, not off the right edge of the one above.
    it "drops to the next row after a full one" do
      made = field "abcd", bounds: TermBuf::Rect.new(0, 0, 4, 3),
        growth: Growth::Grow

      expect(made.cursor_position).to eq({0, 1})
    end
  end

  describe "selection" do
    it "draws what is selected differently" do
      made = field "hello", bounds: TermBuf::Rect.new(0, 0, 10, 1)
      made.buffer.move_to 0
      3.times { made.handle TermBuf::Key.named(Name::Right, TermBuf::Modifiers::Shift) }

      expect(made.buffer.selected_text).to eq "hel"
      expect(render(made).first).to eq "hello"
    end
  end

  describe "completion" do
    it "grows to list the candidates once they are worth listing" do
      made = TermBuf::Field.new bounds: TermBuf::Rect.new(0, 0, 20, 1),
        editor: TermBuf::Editor.new(completions: ->(_request : TermBuf::Completion::Request) do
          TermBuf::Completion::Result.new ["commit", "commander"]
        end)
      type made, "co"
      2.times { made.handle TermBuf::Key.named(Name::Tab) }

      expect(made.editor.listing?).to be_true
      expect(made.desired_height).to be > 1
    end
  end
end

Spectator.describe TermBuf::PasteNotice do
  it "draws nothing at all while nothing is arriving" do
    buffer = TermBuf::Buffer.new 20, 5
    buffer.clear
    TermBuf::PasteNotice.new.draw TermBuf::BufferSurface.new(buffer),
      TermBuf::Rect.full(20, 5)

    expect(buffer.to_text.split('\n').map &.strip).to eq ["", "", "", "", ""]
  end

  it "says how much has arrived, centred" do
    notice = TermBuf::PasteNotice.new
    notice.arriving 4096

    buffer = TermBuf::Buffer.new 30, 5
    buffer.clear
    notice.draw TermBuf::BufferSurface.new(buffer), TermBuf::Rect.full(30, 5)

    expect(buffer.to_text).to contain "pasting 4096 bytes"
  end

  it "keeps a label too wide for the screen inside its own panel" do
    notice = TermBuf::PasteNotice.new label: "pasting a great deal of something"
    notice.arriving 4096

    buffer = TermBuf::Buffer.new 12, 5
    buffer.clear
    buffer.write 0, 2, "............"
    notice.draw TermBuf::BufferSurface.new(buffer), TermBuf::Rect.full(12, 5)

    # The panel is as wide as the screen, so nothing of the row it covers is
    # left, and nothing of the label reached past it either.
    buffer.to_text.split('\n').each do |line|
      expect(line.size).to be <= 12
    end
    expect(buffer.to_text).not_to contain "."
  end

  it "goes away when the paste ends" do
    notice = TermBuf::PasteNotice.new
    notice.arriving 10
    expect(notice.visible?).to be_true

    notice.finished
    expect(notice.visible?).to be_false
  end
end
