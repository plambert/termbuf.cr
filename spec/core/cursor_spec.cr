require "../spec_helper"

private alias Style = TermBuf::Style
private alias Color = TermBuf::Color

# A cursor over a buffer of its own, with nothing between the two.
private def surface(columns = 12, rows = 5) : {TermBuf::Buffer, TermBuf::BufferSurface}
  buffer = TermBuf::Buffer.new columns, rows
  {buffer, TermBuf::BufferSurface.new(buffer)}
end

private def screen(columns = 12, rows = 5, **options) : {TermBuf::Buffer, TermBuf::Cursor}
  buffer, target = surface columns, rows
  region = TermBuf::Region.new TermBuf::Rect.full(columns, rows)
  {buffer, TermBuf::Cursor.new(target, region, **options)}
end

private def rows(buffer : TermBuf::Buffer) : Array(String)
  buffer.to_text.split '\n'
end

Spectator.describe TermBuf::Cursor do
  describe "writing" do
    it "puts text where the cursor is and moves it along" do
      buffer, cursor = screen
      cursor.print "hello"

      expect(rows(buffer)[0]).to eq "hello       "
      expect(cursor.x).to eq 5
      expect(cursor.y).to eq 0
    end

    it "counts a wide character as the two cells it takes" do
      buffer, cursor = screen
      cursor.print "a\u{6F22}b"

      expect(rows(buffer)[0]).to eq "a\u{6F22}b        "
      expect(cursor.x).to eq 4
    end

    it "keeps a grapheme cluster in one cell" do
      buffer, cursor = screen
      cursor.print "e\u{301}x"

      expect(cursor.x).to eq 2
      expect(rows(buffer)[0].starts_with?("e\u{301}x")).to be_true
    end

    it "carries the style it was set to" do
      buffer, cursor = screen
      cursor.style = Style::DEFAULT.bold.fg Color.indexed(2)
      cursor.print "x"

      style = buffer.styles[buffer.back[0, 0].style]
      expect(style.has?(TermBuf::Attributes::Bold)).to be_true
      expect(style.foreground).to eq Color.indexed(2)
    end
  end

  describe "wrapping" do
    it "continues on the next row" do
      buffer, cursor = screen 6, 4
      cursor.print "abcdefgh"

      expect(rows(buffer)[0]).to eq "abcdef"
      expect(rows(buffer)[1]).to eq "gh    "
      expect(cursor.x).to eq 2
      expect(cursor.y).to eq 1
    end

    # A terminal leaves the cursor at the margin with the wrap pending, and
    # only wraps when the next character turns up. Doing it eagerly would
    # scroll a full region before anything needed the row below.
    it "holds the wrap until there is something to put on the next row" do
      buffer, cursor = screen 6, 4
      cursor.print "abcdef"

      expect(cursor.x).to eq 5
      expect(cursor.y).to eq 0

      cursor.print "g"
      expect(cursor.y).to eq 1
      expect(rows(buffer)[1]).to eq "g     "
    end

    it "stops at the margin when autowrap is off" do
      buffer, cursor = screen 6, 4, autowrap: false
      cursor.print "abcdefXY"

      expect(rows(buffer)[0]).to eq "abcdeY"
      expect(rows(buffer)[1]).to eq "      "
      expect(cursor.y).to eq 0
    end

    it "moves a wide character down whole rather than splitting it" do
      buffer, cursor = screen 6, 4
      cursor.print "abcde\u{6F22}"

      expect(rows(buffer)[0]).to eq "abcde "
      expect(rows(buffer)[1]).to eq "\u{6F22}    "
    end
  end

  describe "line movement" do
    it "returns to the left edge and drops a row on a newline" do
      buffer, cursor = screen
      cursor.print "ab\ncd"

      expect(rows(buffer)[0]).to eq "ab          "
      expect(rows(buffer)[1]).to eq "cd          "
    end

    it "overwrites from the left edge after a carriage return" do
      buffer, cursor = screen
      cursor.print "abcdef\rxy"

      expect(rows(buffer)[0]).to eq "xycdef      "
    end

    it "moves to the next tab stop without erasing on the way" do
      buffer, cursor = screen 20, 3
      cursor.print "ab\tc"

      expect(cursor.x).to eq 9
      expect(rows(buffer)[0]).to eq "ab      c           "
    end

    it "steps back over the last cell without erasing it" do
      buffer, cursor = screen
      cursor.print "abc\b"

      expect(cursor.x).to eq 2
      expect(rows(buffer)[0]).to eq "abc         "
    end

    it "stays inside the region when told to move outside it" do
      _, cursor = screen 6, 4
      cursor.move_to 99, 99

      expect(cursor.x).to eq 5
      expect(cursor.y).to eq 3
    end
  end

  describe "scrolling" do
    it "scrolls the region when there is nowhere further down" do
      buffer, cursor = screen 8, 3
      5.times { |index| cursor.puts "row#{index}" }

      expect(rows(buffer)[0]).to eq "row3    "
      expect(rows(buffer)[1]).to eq "row4    "
      expect(cursor.y).to eq 2
    end

    it "stays put instead when scrolling is off" do
      buffer, cursor = screen 8, 3, scrolls: false
      5.times { |index| cursor.puts "row#{index}" }

      expect(rows(buffer)[0]).to eq "row0    "
      expect(rows(buffer)[2]).to eq "row4    "
      expect(cursor.y).to eq 2
    end

    it "keeps what scrolls off a region that has scrollback" do
      buffer = TermBuf::Buffer.new 8, 3
      region = TermBuf::Region.new TermBuf::Rect.full(8, 3), scrollback: 4
      cursor = TermBuf::Cursor.new TermBuf::BufferSurface.new(buffer), region

      5.times { |index| cursor.puts "row#{index}" }

      expect(region.scrollback.size).to eq 3
    end

    # Carrying the whole style would leave underlines hanging in empty space;
    # dropping the background as well would punch holes in a tinted pane.
    it "fills the vacated rows with the background and nothing else" do
      buffer = TermBuf::Buffer.new 8, 2
      cursor = TermBuf::Cursor.new TermBuf::BufferSurface.new(buffer),
        TermBuf::Region.new(TermBuf::Rect.full(8, 2))

      cursor.style = Style::DEFAULT.bg(Color.indexed(4)).underlined
      3.times { cursor.puts "x" }

      style = buffer.styles[buffer.back[7, 1].style]
      expect(style.background).to eq Color.indexed(4)
      expect(style.underline.none?).to be_true
    end
  end

  describe "regions" do
    it "writes and wraps inside the region rather than the screen" do
      buffer = TermBuf::Buffer.new 12, 5
      region = TermBuf::Region.new TermBuf::Rect.new(3, 1, 4, 2)
      cursor = TermBuf::Cursor.new TermBuf::BufferSurface.new(buffer), region

      expect(cursor.x).to eq 3
      expect(cursor.y).to eq 1

      cursor.print "abcdef"
      expect(rows(buffer)[0]).to eq "            "
      expect(rows(buffer)[1]).to eq "   abcd     "
      expect(rows(buffer)[2]).to eq "   ef       "
    end

    it "scrolls only the region" do
      buffer = TermBuf::Buffer.new 12, 4
      buffer.write 0, 0, "keep me"
      region = TermBuf::Region.new TermBuf::Rect.new(0, 1, 12, 2)
      cursor = TermBuf::Cursor.new TermBuf::BufferSurface.new(buffer), region

      3.times { |index| cursor.puts "row#{index}" }

      expect(rows(buffer)[0]).to eq "keep me     "
      expect(rows(buffer)[1]).to eq "row2        "
      expect(rows(buffer)[2]).to eq "            "
    end
  end

  describe "escape sequences in written text" do
    it "reads them as style changes" do
      buffer, cursor = screen
      cursor.print "\e[1mAB\e[0mcd"

      expect(buffer.styles[buffer.back[0, 0].style].has?(TermBuf::Attributes::Bold)).to be_true
      expect(buffer.styles[buffer.back[2, 0].style]).to eq Style::DEFAULT
      expect(rows(buffer)[0]).to eq "ABcd        "
    end

    it "leaves the style behind for the next write" do
      buffer, cursor = screen
      cursor.print "\e[4m"
      cursor.print "x"

      expect(buffer.styles[buffer.back[0, 0].style].underline).to eq TermBuf::Underline::Single
    end

    it "puts nothing in the buffer for a sequence it cannot render" do
      buffer, cursor = screen
      cursor.print "a\e[2Jb"

      expect(rows(buffer)[0]).to eq "ab          "
    end

    # The flag exists so an application that never writes an escape sequence
    # does not pay for a scan that would find none. One written anyway lands as
    # the text it is, minus the escape byte, which no cell can hold.
    it "skips the scan when the cursor is raw" do
      buffer, cursor = screen 20, 3, raw: true
      cursor.print "\e[1mAB"

      expect(rows(buffer)[0]).to eq "[1mAB               "
      expect(buffer.styles[buffer.back[0, 0].style]).to eq Style::DEFAULT
    end
  end

  describe "#write" do
    it "holds a character split across two writes" do
      buffer, cursor = screen
      bytes = "\u{6F22}".to_slice

      cursor.write bytes[0, 2]
      expect(rows(buffer)[0]).to eq "            "

      cursor.write bytes[2..]
      expect(rows(buffer)[0]).to eq "\u{6F22}          "
    end
  end

  describe TermBuf::CursorIO do
    it "writes what print and puts hand it" do
      buffer, cursor = screen
      io = cursor.io
      io.print "ab"
      io.puts "cd"
      io.print "ef"

      expect(rows(buffer)[0]).to eq "abcd        "
      expect(rows(buffer)[1]).to eq "ef          "
    end

    it "works with anything that writes to an IO" do
      buffer, cursor = screen 20, 3
      cursor.io.printf "%05d %s", 42, "ok"

      expect(rows(buffer)[0]).to eq "00042 ok            "
    end

    it "gathers writes until a newline once buffering is asked for" do
      buffer, cursor = screen
      io = cursor.io
      io.sync = false

      io.print "held"
      expect(rows(buffer)[0]).to eq "            "

      io.flush
      expect(rows(buffer)[0]).to eq "held        "
    end

    it "refuses to be read from" do
      _, cursor = screen
      expect { cursor.io.gets }.to raise_error IO::Error
    end
  end
end
