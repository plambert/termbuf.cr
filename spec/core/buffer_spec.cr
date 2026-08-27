require "../spec_helper"

private RED = TermBuf::Style::DEFAULT.fg TermBuf::Color::RED

Spectator.describe TermBuf::Region do
  it "keeps nothing when its capacity is zero" do
    region = TermBuf::Region.new TermBuf::Rect.new(0, 0, 4, 2)
    region.push_scrollback Slice[TermBuf::Cell.new('a')]

    expect(region.scrollback).to be_empty
  end

  it "keeps rows up to its capacity, dropping the oldest" do
    region = TermBuf::Region.new TermBuf::Rect.new(0, 0, 4, 2), scrollback: 2

    ['a', 'b', 'c'].each { |char| region.push_scrollback Slice[TermBuf::Cell.new(char)] }

    expect(region.scrollback.size).to eq 2
    expect(region.history(1).try(&.first.char)).to eq 'c'
    expect(region.history(2).try(&.first.char)).to eq 'b'
    expect(region.history(3)).to be_nil
  end

  it "copies the row it is handed, so the caller may overwrite it" do
    region = TermBuf::Region.new TermBuf::Rect.new(0, 0, 4, 2), scrollback: 4
    row = Slice[TermBuf::Cell.new('a')]

    region.push_scrollback row
    row[0] = TermBuf::Cell.new 'z'

    expect(region.history(1).try(&.first.char)).to eq 'a'
  end

  it "clamps the view offset to what it actually has" do
    region = TermBuf::Region.new TermBuf::Rect.new(0, 0, 4, 2), scrollback: 2
    region.push_scrollback Slice[TermBuf::Cell.new('a')]

    region.view_offset = 9
    expect(region.view_offset).to eq 1

    region.view_offset = -3
    expect(region.view_offset).to eq 0
    expect(region.scrolled_back?).to be_false
  end

  it "holds the view on the same historical row as new rows arrive" do
    region = TermBuf::Region.new TermBuf::Rect.new(0, 0, 4, 2), scrollback: 8
    region.push_scrollback Slice[TermBuf::Cell.new('a')]
    region.view_offset = 1

    region.push_scrollback Slice[TermBuf::Cell.new('b')]

    expect(region.view_offset).to eq 2
    expect(region.history(2).try(&.first.char)).to eq 'a'
  end

  it "rejects a negative capacity" do
    expect { TermBuf::Region.new(TermBuf::Rect.new(0, 0, 1, 1), -1) }
      .to raise_error(ArgumentError)
  end
end

Spectator.describe TermBuf::Buffer do
  subject(buffer) { TermBuf::Buffer.new 8, 4 }

  describe "#write_char" do
    it "writes a narrow character and reports one column" do
      expect(buffer.write_char(1, 1, 'a')).to eq 1
      expect(buffer.back[1, 1].char).to eq 'a'
    end

    it "writes a wide character across two cells" do
      expect(buffer.write_char(1, 1, '漢')).to eq 2
      expect(buffer.back[2, 1].continuation?).to be_true
    end

    it "stores nothing for a zero width character" do
      expect(buffer.write_char(1, 1, '́')).to eq 0
      expect(buffer.write_char(1, 1, '\n')).to eq 0
      expect(buffer.back.damage.dirty?).to be_false
    end

    it "interns the style it was given" do
      buffer.write_char 0, 0, 'a', RED

      expect(buffer.styles[buffer.back[0, 0].style]).to eq RED
    end
  end

  describe "#write" do
    it "writes one grapheme cluster per cell" do
      expect(buffer.write(0, 0, "abc")).to eq 3
      expect(buffer.to_text.lines.first).to eq "abc     "
    end

    it "keeps a combining mark with its base in one cell" do
      expect(buffer.write(0, 0, "éx")).to eq 2

      expect(buffer.back[0, 0].cluster).not_to eq TermBuf::ClusterPool::NONE
      expect(buffer.clusters[buffer.back[0, 0].cluster]).to eq "é"
      expect(buffer.back[1, 0].char).to eq 'x'
    end

    it "gives a flag one cell pair" do
      expect(buffer.write(0, 0, "\u{1F1FA}\u{1F1F8}")).to eq 2
      expect(buffer.back[0, 0].wide?).to be_true
      expect(buffer.back[1, 0].continuation?).to be_true
    end

    it "counts columns rather than characters" do
      expect(buffer.write(0, 0, "a漢b")).to eq 4
    end

    it "stops at the right edge" do
      expect(buffer.write(6, 0, "abcdef")).to eq 2
      expect(buffer.back[7, 0].char).to eq 'b'
    end

    it "stops rather than splitting a wide character at the right edge" do
      expect(buffer.write(6, 0, "a漢b")).to eq 1
      expect(buffer.back[7, 0]).to eq TermBuf::Cell.blank
    end

    it "skips a leading combining mark, which has no base to attach to" do
      expect(buffer.write(0, 0, "́a")).to eq 1
      expect(buffer.back[0, 0].char).to eq 'a'
    end

    it "refuses a starting position outside the buffer" do
      expect(buffer.write(9, 0, "abc")).to eq 0
      expect(buffer.write(0, 9, "abc")).to eq 0
    end
  end

  describe "damage tracking" do
    it "starts clean" do
      expect(buffer.dirty?).to be_false
    end

    it "reports the columns a write touched" do
      buffer.write 2, 1, "abc"

      expect(buffer.damage.span(1)).to eq 2..4
      expect(buffer.damage.span(0)).to be_nil
    end

    it "records nothing when a write changes nothing" do
      buffer.write 2, 1, "abc"
      buffer.commit_paint
      buffer.write 2, 1, "abc"

      expect(buffer.dirty?).to be_false
    end

    it "notices a change of style even when the text is the same" do
      buffer.write 2, 1, "abc"
      buffer.commit_paint
      buffer.write 2, 1, "abc", RED

      expect(buffer.dirty?).to be_true
    end
  end

  describe "#fill and #clear" do
    it "fills a rectangle" do
      buffer.fill TermBuf::Rect.new(1, 1, 2, 2), '#'

      expect(buffer.back[1, 1].char).to eq '#'
      expect(buffer.back[2, 2].char).to eq '#'
      expect(buffer.back[3, 1].char).to eq ' '
    end

    it "clears the whole screen to a style" do
      buffer.write 0, 0, "abc"
      buffer.clear RED

      expect(buffer.back[0, 0].char).to eq ' '
      expect(buffer.styles[buffer.back[0, 0].style]).to eq RED
    end

    it "refuses to fill with a wide or zero width character" do
      expect { buffer.fill(buffer.bounds, '漢') }.to raise_error(ArgumentError)
      expect { buffer.fill(buffer.bounds, '́') }.to raise_error(ArgumentError)
    end
  end

  describe "#scroll" do
    before_each { 4.times { |row| buffer.write 0, row, ('a' + row).to_s } }

    it "moves content and records a hint" do
      buffer.scroll buffer.bounds, 1

      expect(buffer.back[0, 0].char).to eq 'b'
      expect(buffer.scroll_hints.size).to eq 1
      expect(buffer.scroll_hints.first.lines).to eq 1
      expect(buffer.scroll_hints.first.rect).to eq buffer.bounds
    end

    it "records nothing for a zero line scroll" do
      buffer.scroll buffer.bounds, 0

      expect(buffer.scroll_hints).to be_empty
    end

    it "records the clipped rectangle, not the one it was asked for" do
      buffer.scroll TermBuf::Rect.new(0, 0, 99, 99), 1

      expect(buffer.scroll_hints.first.rect).to eq buffer.bounds
    end

    it "hands the hints over once" do
      buffer.scroll buffer.bounds, 1

      expect(buffer.take_scroll_hints.size).to eq 1
      expect(buffer.scroll_hints).to be_empty
    end
  end

  describe "#scroll_region" do
    it "keeps the rows that leave the top when the region has scrollback" do
      region = buffer.region 0, 0, 8, 4, scrollback: 10
      4.times { |row| buffer.write 0, row, ('a' + row).to_s }

      buffer.scroll_region region, 2

      expect(region.scrollback.size).to eq 2
      expect(region.history(1).try(&.first.char)).to eq 'b'
      expect(region.history(2).try(&.first.char)).to eq 'a'
      expect(buffer.back[0, 0].char).to eq 'c'
    end

    it "keeps nothing when the region has no scrollback" do
      region = buffer.region 0, 0, 8, 4
      buffer.write 0, 0, "a"

      buffer.scroll_region region, 1

      expect(region.scrollback).to be_empty
    end

    it "keeps nothing when scrolling down, since nothing leaves the top" do
      region = buffer.region 0, 0, 8, 4, scrollback: 10
      buffer.write 0, 0, "a"

      buffer.scroll_region region, -1

      expect(region.scrollback).to be_empty
      expect(buffer.back[0, 1].char).to eq 'a'
    end

    it "scrolls only the region's rectangle" do
      region = buffer.region 0, 0, 8, 2, scrollback: 4
      4.times { |row| buffer.write 0, row, ('a' + row).to_s }

      buffer.scroll_region region, 1

      expect(buffer.back[0, 0].char).to eq 'b'
      expect(buffer.back[0, 2].char).to eq 'c'
    end
  end

  describe "#commit_paint" do
    it "brings the front grid up to date and clears what it was built from" do
      buffer.write 0, 0, "abc"
      buffer.scroll buffer.bounds, 1

      buffer.commit_paint

      expect(buffer.painted?).to be_true
      expect(buffer.dirty?).to be_false
      expect(buffer.scroll_hints).to be_empty
    end
  end

  describe "#invalidate" do
    it "makes the next paint a full one" do
      buffer.write 0, 0, "abc"
      buffer.commit_paint

      buffer.invalidate

      expect(buffer.dirty?).to be_true
      expect(buffer.painted?).to be_false
      expect(buffer.damage.rows).to eq 4
      expect(buffer.damage.span(0)).to eq 0..7
    end

    it "leaves the drawn content alone" do
      buffer.write 0, 0, "abc"
      buffer.invalidate

      expect(buffer.to_text.lines.first).to eq "abc     "
    end
  end

  describe "#resize" do
    it "resizes both grids and forces a full repaint" do
      buffer.write 0, 0, "abc"
      buffer.commit_paint

      buffer.resize 4, 2

      expect(buffer.width).to eq 4
      expect(buffer.height).to eq 2
      expect(buffer.back.width).to eq 4
      expect(buffer.front.width).to eq 4
      expect(buffer.damage.rows).to eq 2
    end

    it "keeps content that still fits" do
      buffer.write 0, 0, "abc"
      buffer.resize 4, 2

      expect(buffer.back[2, 0].char).to eq 'c'
    end

    it "drops scroll hints, since the screen is being redrawn anyway" do
      buffer.scroll buffer.bounds, 1
      buffer.resize 4, 2

      expect(buffer.scroll_hints).to be_empty
    end

    it "does nothing when the size is unchanged" do
      buffer.write 0, 0, "abc"
      buffer.commit_paint
      buffer.resize 8, 4

      expect(buffer.dirty?).to be_false
    end
  end

  describe "#blit" do
    # A panel drawn somewhere else, which is how a shard compositing its own
    # buffers would build one.
    let(panel) do
      made = TermBuf::Buffer.new 4, 2
      made.clear
      made.write 0, 0, "abcd"
      made.write 0, 1, "efgh"
      made
    end

    it "copies a whole buffer in at a position" do
      buffer.clear
      buffer.blit panel, 2, 1

      expect(buffer.to_text.lines[1]).to eq "  abcd  "
      expect(buffer.to_text.lines[2]).to eq "  efgh  "
      expect(buffer.to_text.lines[0]).to eq "        "
    end

    it "copies only the part it was asked for" do
      buffer.clear
      buffer.blit panel, 0, 0, TermBuf::Rect.new(1, 1, 2, 1)

      expect(buffer.to_text.lines[0]).to eq "fg      "
    end

    it "cuts what falls past the destination edges" do
      buffer.clear
      buffer.blit panel, 6, 3

      expect(buffer.to_text.lines[3]).to eq "      ab"
    end

    it "drops what the destination clipped off the left and top" do
      buffer.clear
      buffer.blit panel, -2, -1

      expect(buffer.to_text.lines[0]).to eq "gh      "
    end

    it "does nothing when nothing lands on the destination" do
      buffer.clear
      buffer.commit_paint
      buffer.blit panel, 20, 20
      buffer.blit panel, -9, 0

      expect(buffer.dirty?).to be_false
    end

    it "translates styles into this buffer's table" do
      red = TermBuf::Style::DEFAULT.fg TermBuf::Color::RED
      panel.write 0, 0, "ab", red
      buffer.clear
      buffer.blit panel, 1, 0

      expect(buffer.styles[buffer.back[1, 0].style]).to eq red
      expect(buffer.styles[buffer.back[2, 0].style]).to eq red
      expect(buffer.styles[buffer.back[3, 0].style]).to eq TermBuf::Style::DEFAULT
    end

    it "translates clusters into this buffer's pool" do
      family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"
      panel.write 0, 0, family
      buffer.clear
      buffer.blit panel, 1, 0

      cell = buffer.back[1, 0]

      expect(cell.cluster).not_to eq TermBuf::ClusterPool::NONE
      expect(cell.text(buffer.clusters)).to eq family
      expect(buffer.back[2, 0].continuation?).to be_true
    end

    it "keeps the width the source stored rather than remeasuring" do
      narrow = TermBuf::Buffer.new 4, 1
      narrow.policy = TermBuf::Unicode::WidthPolicy::DEFAULT.copy_with ambiguous: 2
      narrow.clear
      narrow.write 0, 0, "\u00A1" # ambiguous, two cells there and one here

      buffer.clear
      buffer.blit narrow, 0, 0

      expect(buffer.back[0, 0].width).to eq 2
      expect(buffer.back[1, 0].continuation?).to be_true
    end

    it "blanks a wide character with only one half inside the source rect" do
      wide = TermBuf::Buffer.new 4, 1
      wide.clear
      wide.write 0, 0, "a\u4E16b" # a 世 b, the ideograph across columns 1 and 2

      buffer.clear
      buffer.blit wide, 0, 0, TermBuf::Rect.new(0, 0, 2, 1) # keeps only its lead
      buffer.blit wide, 4, 0, TermBuf::Rect.new(2, 0, 2, 1) # keeps only its tail

      expect(buffer.to_text.lines[0]).to eq "a    b  "
    end

    it "blanks a wide character the destination cut in half" do
      wide = TermBuf::Buffer.new 2, 1
      wide.clear
      wide.write 0, 0, "\u4E16"

      buffer.clear
      buffer.write 0, 0, "\u4E16xxxxxx"
      buffer.blit wide, 1, 0 # lands on the second half of what is already there

      expect(buffer.to_text.lines[0]).to eq " \u4E16xxxxx"
    end

    it "reports the cells it changed as damage" do
      buffer.clear
      buffer.commit_paint
      buffer.blit panel, 2, 1

      expect(buffer.damage.span(1)).to eq(2..5)
      expect(buffer.damage.dirty?(0)).to be_false
    end
  end
end
