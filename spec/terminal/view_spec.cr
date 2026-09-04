require "../spec_helper"

private alias Rect = TermBuf::Rect
private RED    = TermBuf::Style::DEFAULT.fg TermBuf::Color::RED
private BLACK  = TermBuf::Color.rgb 0, 0, 0
private BRIGHT = TermBuf::Color.rgb 100, 200, 50
private MIDWAY = TermBuf::Color.rgb 50, 100, 25

# A buffer and a surface over it, so a view can be checked by what reached the
# cells rather than by what commands went by.
private def with_screen(width : Int32 = 12, height : Int32 = 5, &)
  buffer = TermBuf::Buffer.new width, height
  buffer.clear
  yield TermBuf::BufferSurface.new(buffer), buffer
end

Spectator.describe TermBuf::View do
  describe "coordinates" do
    it "is addressed from its own top left" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(3, 1, 6, 3)
        panel.write 0, 0, "abc"

        expect(buffer.to_text.lines[1]).to eq "   abc      "
      end
    end

    it "reports its own bounds and size" do
      with_screen do |screen, _|
        panel = screen.view Rect.new(3, 1, 6, 3)

        expect(panel.bounds).to eq Rect.new(0, 0, 6, 3)
        expect(panel.width).to eq 6
        expect(panel.height).to eq 3
        expect(panel.rect).to eq Rect.new(3, 1, 6, 3)
      end
    end

    it "nests, each view relative to the one it came from" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(2, 1, 8, 3)
        inner = panel.view Rect.new(1, 1, 4, 1)
        inner.write 0, 0, "xy"

        expect(buffer.to_text.lines[2]).to eq "   xy       "
      end
    end
  end

  describe "clipping a write" do
    it "cuts what runs past the right edge" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(2, 0, 4, 1)
        panel.write 0, 0, "abcdefgh"

        expect(buffer.to_text.lines[0]).to eq "  abcd      "
      end
    end

    it "cuts what starts before the left edge" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(4, 0, 4, 1)
        panel.write -2, 0, "abcdef"

        expect(buffer.to_text.lines[0]).to eq "    cdef    "
      end
    end

    it "drops a write above or below it" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(0, 1, 6, 2)
        panel.write 0, -1, "above"
        panel.write 0, 2, "below"

        expect(buffer.to_text).to eq (["            "] * 5).join('\n')
      end
    end

    it "drops a write that lands entirely past an edge" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(2, 0, 4, 1)
        panel.write 4, 0, "right"
        panel.write -9, 0, "left"

        expect(buffer.to_text.lines[0]).to eq "            "
      end
    end

    it "keeps the style it was given" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(1, 0, 4, 1)
        panel.write 0, 0, "abcdef", RED

        expect(buffer.back[1, 0].style).to eq buffer.styles.id(RED)
        expect(buffer.back[4, 0].style).to eq buffer.styles.id(RED)
      end
    end
  end

  describe "clipping a wide cluster" do
    it "drops one straddling the right edge rather than splitting it" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(1, 0, 3, 1)
        panel.write 0, 0, "ab世c"

        # Two cells are spoken for and 世 wants two, so it goes rather than
        # being halved, and the last cell stays empty.
        expect(buffer.to_text.lines[0]).to eq " ab         "
      end
    end

    it "moves the run in a column when the left edge cuts one in half" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(4, 0, 5, 1)
        # Cells of "世ab" are 世世ab; skipping two starts at 'a', but skipping
        # one has to skip the whole cluster and start a column further in.
        panel.write -1, 0, "世ab"

        expect(buffer.to_text.lines[0]).to eq "     ab     "
      end
    end

    it "measures with the policy of the surface it came from" do
      buffer = TermBuf::Buffer.new 12, 1
      buffer.clear
      buffer.policy = TermBuf::Unicode::WidthPolicy::DEFAULT.copy_with ambiguous: 2
      panel = TermBuf::BufferSurface.new(buffer).view Rect.new(0, 0, 3, 1)

      expect(panel.policy.ambiguous).to eq 2

      # Each ¡ is two cells under this policy, so only one fits in three.
      panel.write 0, 0, "¡¡¡"

      expect(buffer.to_text).to eq "¡          "
    end
  end

  describe "clipping the other commands" do
    it "cuts a fill to the view" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(2, 1, 3, 2)
        panel.fill Rect.new(-2, -2, 20, 20), '#'

        expect(buffer.to_text.lines[0]).to eq "            "
        expect(buffer.to_text.lines[1]).to eq "  ###       "
        expect(buffer.to_text.lines[2]).to eq "  ###       "
        expect(buffer.to_text.lines[3]).to eq "            "
      end
    end

    it "clears only the view" do
      with_screen do |screen, buffer|
        screen.fill buffer.bounds, '.'

        panel = screen.view Rect.new(2, 1, 3, 2)
        panel.clear

        expect(buffer.to_text.lines[1]).to eq ".."[0, 2] + "   " + "."*7
        expect(buffer.to_text.lines[0]).to eq "." * 12
      end
    end

    it "keeps a character write inside" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(2, 0, 3, 1)
        panel.write_char 0, 0, 'a'
        panel.write_char 3, 0, 'b'
        panel.write_char -1, 0, 'c'

        expect(buffer.to_text.lines[0]).to eq "  a         "
      end
    end

    it "drops a wide character with only one cell left" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(0, 0, 3, 1)
        panel.write_char 2, 0, '世'
        panel.write_char 1, 0, '世'

        expect(buffer.to_text.lines[0]).to eq " 世         "
      end
    end

    it "cuts a scroll to the view" do
      with_screen do |screen, buffer|
        screen.write 0, 0, "aaaaaaaaaaaa"
        screen.write 0, 1, "bbbbbbbbbbbb"

        panel = screen.view Rect.new(2, 0, 4, 2)
        panel.scroll Rect.new(0, 0, 99, 99), 1

        expect(buffer.to_text.lines[0]).to eq "aabbbbaaaaaa"
        expect(buffer.to_text.lines[1]).to eq "bb    bbbbbb"
      end
    end

    it "cuts a blit to the view" do
      with_screen do |screen, buffer|
        panel = TermBuf::Buffer.new 4, 2
        panel.clear
        panel.write 0, 0, "abcd"
        panel.write 0, 1, "efgh"

        view = screen.view Rect.new(2, 1, 3, 1)
        view.blit panel, 0, 0

        # One row of the view, three columns of it: "abc" and no more.
        expect(buffer.to_text.lines[1]).to eq "  abc       "
        expect(buffer.to_text.lines[2]).to eq "            "
      end
    end

    it "drops what a blit puts before the view's origin" do
      with_screen do |screen, buffer|
        panel = TermBuf::Buffer.new 4, 1
        panel.clear
        panel.write 0, 0, "abcd"

        view = screen.view Rect.new(3, 0, 4, 1)
        view.blit panel, -2, 0

        expect(buffer.to_text.lines[0]).to eq "   cd       "
      end
    end

    it "passes a region scroll through, since a region is not view relative" do
      with_screen do |screen, buffer|
        screen.write 0, 0, "aaaaaaaaaaaa"
        region = TermBuf::Region.new Rect.new(0, 0, 12, 2)

        panel = screen.view Rect.new(4, 2, 4, 2)
        panel.scroll_region region, 1

        expect(buffer.to_text.lines[0]).to eq "            "
      end
    end
  end

  describe "a view carrying a style" do
    let(highlight) { TermBuf::Style::DEFAULT.bg TermBuf::Color::BLUE }

    it "gives its background to a write that names none" do
      with_screen do |screen, buffer|
        row = screen.view Rect.new(0, 1, 8, 1), highlight
        row.clear
        row.write 0, 0, "name", TermBuf::Style::DEFAULT.bold

        expect(buffer.styles[buffer.back[0, 1].style]).to eq highlight.bold
        expect(buffer.styles[buffer.back[6, 1].style]).to eq highlight
      end
    end

    it "lets a write name a background of its own" do
      with_screen do |screen, buffer|
        row = screen.view Rect.new(0, 0, 8, 1), highlight
        row.write 0, 0, "x", RED.bg(TermBuf::Color::GREEN)

        expect(buffer.styles[buffer.back[0, 0].style].background).to eq TermBuf::Color::GREEN
      end
    end

    it "applies to every command that carries a style" do
      with_screen do |screen, buffer|
        row = screen.view Rect.new(0, 0, 4, 2), highlight
        row.fill Rect.new(0, 0, 2, 1), '#'
        row.write_char 2, 0, 'c'

        expect(buffer.styles[buffer.back[0, 0].style]).to eq highlight
        expect(buffer.styles[buffer.back[2, 0].style]).to eq highlight
      end
    end

    it "can be set after the view was made" do
      with_screen do |screen, buffer|
        row = screen.view Rect.new(0, 0, 4, 1)
        row.style = highlight
        row.write 0, 0, "ab"

        expect(buffer.styles[buffer.back[0, 0].style]).to eq highlight
      end
    end

    it "layers through nested views, the innermost winning each field" do
      with_screen do |screen, buffer|
        outer = screen.view Rect.new(0, 0, 8, 1), highlight
        inner = outer.view Rect.new(1, 0, 6, 1), TermBuf::Style::DEFAULT.italic
        inner.write 0, 0, "x", TermBuf::Style::DEFAULT.bold

        expect(buffer.styles[buffer.back[1, 0].style]).to eq highlight.italic.bold
      end
    end

    it "lets a write keep what is behind it instead of the view's background" do
      with_screen do |screen, buffer|
        row = screen.view Rect.new(0, 0, 8, 1), highlight
        row.clear
        # A bar painted inside the row, then a label across the join.
        row.fill Rect.new(0, 0, 3, 1), ' ', TermBuf::Style::DEFAULT.bg(TermBuf::Color::GREEN)
        row.write 2, 0, "ab", TermBuf::Style::DEFAULT.bold,
          blend: TermBuf::Style::KEEP_BACKGROUND

        expect(buffer.styles[buffer.back[2, 0].style].background).to eq TermBuf::Color::GREEN
        expect(buffer.styles[buffer.back[3, 0].style].background).to eq TermBuf::Color::BLUE
        expect(buffer.styles[buffer.back[2, 0].style].has?(TermBuf::Attributes::Bold)).to be_true
      end
    end

    it "hands the blend the cell's position in the buffer, not in the view" do
      with_screen do |screen, buffer|
        seen = [] of {Int32, Int32}
        recorder = TermBuf::Blend.new do |_under, over, column, row|
          seen << {column, row}
          over
        end

        screen.view(Rect.new(3, 2, 4, 2)).write 1, 1, "ab", blend: recorder

        expect(seen).to eq [{4, 3}, {5, 3}]
        expect(buffer.back[4, 3].char).to eq 'a'
      end
    end

    it "asks a blend it carries in its own coordinates" do
      with_screen do |screen, buffer|
        seen = [] of {Int32, Int32}
        recorder = TermBuf::Blend.new do |_under, over, column, row|
          seen << {column, row}
          over
        end

        screen.view(Rect.new(3, 2, 4, 2), blend: recorder).write 1, 1, "ab"

        expect(seen).to eq [{1, 1}, {2, 1}]
        expect(buffer.back[4, 3].char).to eq 'a'
      end
    end

    it "paints a gradient built against its bounds wherever it sits" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(4, 1, 5, 2)
        panel.blend = TermBuf::Gradient.new(BLACK, BRIGHT, panel.bounds).background
        panel.clear

        expect(buffer.styles[buffer.back[4, 1].style].background).to eq BLACK
        expect(buffer.styles[buffer.back[6, 2].style].background).to eq MIDWAY
        expect(buffer.styles[buffer.back[8, 1].style].background).to eq BRIGHT
      end
    end

    it "lines a nested view's gradient up with the cells it covers" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(2, 1, 9, 3)
        inner = panel.view Rect.new(2, 1, 5, 1)
        inner.blend = TermBuf::Gradient.new(BLACK, BRIGHT, inner.bounds).background
        inner.clear

        expect(buffer.styles[buffer.back[4, 2].style].background).to eq BLACK
        expect(buffer.styles[buffer.back[6, 2].style].background).to eq MIDWAY
        expect(buffer.styles[buffer.back[8, 2].style].background).to eq BRIGHT
      end
    end

    it "runs its own blend first and the draw call's on the result" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(1, 0, 5, 1),
          blend: TermBuf::Gradient.new(BLACK, BRIGHT, Rect.new(0, 0, 5, 1)).background
        panel.clear
        # The label keeps the ramp's background and adds its own bold.
        panel.write 0, 0, "ab", TermBuf::Style::DEFAULT.bold,
          blend: TermBuf::Style::KEEP_BACKGROUND

        first = buffer.styles[buffer.back[1, 0].style]

        expect(first.background).to eq BLACK
        expect(first.has?(TermBuf::Attributes::Bold)).to be_true
        expect(buffer.styles[buffer.back[3, 0].style].background).to eq MIDWAY
      end
    end

    it "composes an outer view's blend under an inner one's" do
      with_screen do |screen, buffer|
        outer = screen.view Rect.new(0, 0, 6, 1),
          blend: TermBuf::Style.blend { |_under, over| over.fg TermBuf::Color::RED }
        inner = outer.view Rect.new(1, 0, 3, 1),
          blend: TermBuf::Gradient.new(BLACK, BRIGHT, Rect.new(0, 0, 3, 1)).background
        inner.clear

        placed = buffer.styles[buffer.back[1, 0].style]

        expect(placed.foreground).to eq TermBuf::Color::RED
        expect(placed.background).to eq BLACK
      end
    end

    it "leaves styles alone when it carries none" do
      with_screen do |screen, buffer|
        plain = screen.view Rect.new(0, 0, 4, 1)
        plain.write 0, 0, "ab", RED

        expect(buffer.styles[buffer.back[0, 0].style]).to eq RED
      end
    end
  end

  describe "an empty view" do
    it "drops everything" do
      with_screen do |screen, buffer|
        panel = screen.view Rect.new(2, 2, 0, 0)
        panel.write 0, 0, "nothing"
        panel.fill panel.bounds, '#'
        panel.clear

        expect(buffer.to_text).to eq (["            "] * 5).join('\n')
      end
    end
  end

  describe "over a batcher" do
    it "translates into the commands it collects" do
      batcher = TermBuf::Batcher.new
      batcher.view(Rect.new(3, 2, 4, 2)).write 1, 1, "abcdef"

      command = batcher.commands.first.as TermBuf::Commands::Write

      expect(batcher.commands.size).to eq 1
      expect({command.x, command.y, command.text}).to eq({4, 3, "abc"})
    end

    it "carries the blend through unchanged" do
      batcher = TermBuf::Batcher.new
      blend = TermBuf::Style::KEEP_BACKGROUND
      batcher.view(Rect.new(1, 0, 4, 1)).write 0, 0, "ab", blend: blend

      expect(batcher.commands.first.as(TermBuf::Commands::Write).blend).to eq blend
    end

    it "carries a blend through a fill too" do
      batcher = TermBuf::Batcher.new
      blend = TermBuf::Style::OVER
      batcher.view(Rect.new(1, 0, 4, 1)).fill Rect.new(0, 0, 2, 1), '.', blend: blend

      expect(batcher.commands.first.as(TermBuf::Commands::Fill).blend).to eq blend
    end

    it "sends a blend of its own along with a command carrying none" do
      batcher = TermBuf::Batcher.new
      view = batcher.view Rect.new(1, 0, 4, 1),
        blend: TermBuf::Gradient.new(BLACK, BRIGHT, Rect.new(0, 0, 4, 1)).background
      view.write 0, 0, "ab"

      command = batcher.commands.first.as TermBuf::Commands::Write
      blend = command.blend

      expect(blend).not_to be_nil

      if blend
        # Asked at the buffer column the write landed on, it answers for the
        # view's own column zero.
        expect(blend.call(TermBuf::Style::DEFAULT, TermBuf::Style::DEFAULT, 1, 0).background)
          .to eq BLACK
      end
    end
  end
end
