require "../spec_helper"

private def wide_cell(style : TermBuf::StyleId = 0_u32) : TermBuf::Cell
  TermBuf::Cell.new '漢', style, 2_u8
end

Spectator.describe TermBuf::Rect do
  it "reports its far edges" do
    rect = TermBuf::Rect.new 2, 3, 4, 5

    expect(rect.right).to eq 5
    expect(rect.bottom).to eq 7
  end

  it "is empty when either dimension is zero" do
    expect(TermBuf::Rect.new(0, 0, 0, 5).empty?).to be_true
    expect(TermBuf::Rect.new(0, 0, 5, 0).empty?).to be_true
    expect(TermBuf::Rect.new(0, 0, 1, 1).empty?).to be_false
  end

  it "rejects negative dimensions" do
    expect { TermBuf::Rect.new(0, 0, -1, 1) }.to raise_error(ArgumentError)
    expect { TermBuf::Rect.new(0, 0, 1, -1) }.to raise_error(ArgumentError)
  end

  it "tests containment of points and rectangles" do
    rect = TermBuf::Rect.new 1, 1, 3, 3

    expect(rect.contains?(1, 1)).to be_true
    expect(rect.contains?(3, 3)).to be_true
    expect(rect.contains?(4, 3)).to be_false
    expect(rect.contains?(TermBuf::Rect.new(2, 2, 1, 1))).to be_true
    expect(rect.contains?(TermBuf::Rect.new(2, 2, 5, 1))).to be_false
  end

  it "intersects" do
    first = TermBuf::Rect.new 0, 0, 4, 4
    second = TermBuf::Rect.new 2, 2, 4, 4

    expect(first.intersect(second)).to eq TermBuf::Rect.new(2, 2, 2, 2)
  end

  it "intersects to empty when the rectangles do not meet" do
    first = TermBuf::Rect.new 0, 0, 2, 2
    second = TermBuf::Rect.new 5, 5, 2, 2

    expect(first.intersect(second).empty?).to be_true
  end
end

Spectator.describe TermBuf::Damage do
  subject(damage) { TermBuf::Damage.new 4 }

  it "starts clean" do
    expect(damage.dirty?).to be_false
    expect(damage.rows).to eq 0
    expect(damage.span(0)).to be_nil
  end

  it "grows a row's span to cover every touched column" do
    damage.touch 5, 1
    damage.touch 2, 1
    damage.touch 9, 1

    expect(damage.span(1)).to eq 2..9
    expect(damage.rows).to eq 1
  end

  it "counts each dirty row once" do
    damage.touch 0, 0
    damage.touch 1, 0
    damage.touch 0, 2

    expect(damage.rows).to eq 2
    expect(damage.dirty?).to be_true
  end

  it "ignores rows outside the grid" do
    damage.touch 0, 9
    damage.touch 0, -1

    expect(damage.dirty?).to be_false
  end

  it "yields dirty rows top to bottom" do
    damage.touch 3, 2
    damage.touch 1, 0

    seen = [] of {Int32, Range(Int32, Int32)}
    damage.each { |row, span| seen << {row, span} }

    expect(seen).to eq [{0, 1..1}, {2, 3..3}]
  end

  it "clears" do
    damage.touch 1, 1
    damage.clear

    expect(damage.dirty?).to be_false
    expect(damage.span(1)).to be_nil
  end

  it "marks everything" do
    damage.touch_all 10

    expect(damage.rows).to eq 4
    expect(damage.span(3)).to eq 0..9
  end
end

Spectator.describe TermBuf::Grid do
  subject(grid) { TermBuf::Grid.new 6, 3 }

  describe "construction" do
    it "starts blank and clean" do
      expect(grid[0, 0]).to eq TermBuf::Cell.blank
      expect(grid.damage.dirty?).to be_false
    end

    it "rejects a non-positive size" do
      expect { TermBuf::Grid.new(0, 1) }.to raise_error(ArgumentError)
      expect { TermBuf::Grid.new(1, 0) }.to raise_error(ArgumentError)
    end
  end

  describe "#[]=" do
    it "marks damage where a cell changed" do
      grid[2, 1] = TermBuf::Cell.new 'x'

      expect(grid.damage.span(1)).to eq 2..2
      expect(grid.damage.rows).to eq 1
    end

    it "marks nothing when the cell is already what is being written" do
      grid[2, 1] = TermBuf::Cell.new 'x'
      grid.damage.clear
      grid[2, 1] = TermBuf::Cell.new 'x'

      expect(grid.damage.dirty?).to be_false
    end

    it "ignores writes outside the grid" do
      grid[99, 0] = TermBuf::Cell.new 'x'
      grid[0, 99] = TermBuf::Cell.new 'x'

      expect(grid.damage.dirty?).to be_false
    end
  end

  describe "#place" do
    it "writes a narrow character into one cell" do
      expect(grid.place(1, 0, TermBuf::Cell.new('a'))).to eq 1
      expect(grid[1, 0].char).to eq 'a'
    end

    it "writes a wide character into a cell and its continuation" do
      expect(grid.place(1, 0, wide_cell)).to eq 2
      expect(grid[1, 0].wide?).to be_true
      expect(grid[2, 0].continuation?).to be_true
    end

    it "refuses a wide character with only one column left, writing nothing" do
      expect(grid.place(5, 0, wide_cell)).to eq 0
      expect(grid[5, 0]).to eq TermBuf::Cell.blank
      expect(grid.damage.dirty?).to be_false
    end

    it "refuses a zero width cell" do
      expect(grid.place(0, 0, TermBuf::Cell.continuation)).to eq 0
    end

    it "refuses a position outside the grid" do
      expect(grid.place(9, 0, TermBuf::Cell.new('a'))).to eq 0
      expect(grid.place(0, 9, TermBuf::Cell.new('a'))).to eq 0
    end
  end

  describe "wide character invariants" do
    it "blanks both halves when the lead is overwritten" do
      grid.place 1, 0, wide_cell
      grid.place 1, 0, TermBuf::Cell.new('a')

      expect(grid[1, 0].char).to eq 'a'
      expect(grid[2, 0]).to eq TermBuf::Cell.blank
    end

    it "blanks both halves when the continuation is overwritten" do
      grid.place 1, 0, wide_cell
      grid.place 2, 0, TermBuf::Cell.new('a')

      expect(grid[1, 0]).to eq TermBuf::Cell.blank
      expect(grid[2, 0].char).to eq 'a'
    end

    it "blanks the earlier pair when a new wide character straddles it" do
      grid.place 0, 0, wide_cell
      grid.place 2, 0, wide_cell
      grid.place 1, 0, wide_cell

      expect(grid[0, 0]).to eq TermBuf::Cell.blank
      expect(grid[1, 0].wide?).to be_true
      expect(grid[2, 0].continuation?).to be_true
      expect(grid[3, 0]).to eq TermBuf::Cell.blank
    end

    # Unlike a rectangle operation, which leaves the half outside it alone.
    # A terminal erases what it displaces in whatever style it is writing in,
    # having no memory of what the cell used to be, and this follows it.
    it "blanks a displaced half in the style being written" do
      grid.place 1, 0, wide_cell(7_u32)
      grid.place 2, 0, TermBuf::Cell.new('x', 3_u32), TermBuf::Cell.blank(3_u32)

      expect(grid[1, 0]).to eq TermBuf::Cell.blank(3_u32)
      expect(grid[2, 0].char).to eq 'x'
    end

    it "never leaves a continuation without its lead" do
      grid.place 0, 0, wide_cell
      grid.place 2, 0, wide_cell
      grid.place 4, 0, wide_cell
      grid.place 3, 0, TermBuf::Cell.new('x')

      6.times do |column|
        cell = grid[column, 0]
        next unless cell.continuation?

        expect(grid[column - 1, 0].wide?).to be_true
      end
    end
  end

  describe "#fill" do
    it "fills only the rectangle" do
      grid.fill TermBuf::Rect.new(1, 1, 2, 1), TermBuf::Cell.new('#')

      expect(grid[0, 1].char).to eq ' '
      expect(grid[1, 1].char).to eq '#'
      expect(grid[2, 1].char).to eq '#'
      expect(grid[3, 1].char).to eq ' '
      expect(grid[1, 0].char).to eq ' '
    end

    it "clips a wide character straddling the rectangle's edge" do
      grid.place 0, 0, wide_cell
      grid.fill TermBuf::Rect.new(1, 0, 2, 1), TermBuf::Cell.new('#')

      expect(grid[0, 0]).to eq TermBuf::Cell.blank
      expect(grid[1, 0].char).to eq '#'
    end

    # Giving the half outside the rectangle the fill's style would paint one
    # column wider than asked for, and only on the rows where a wide character
    # happens to straddle.
    it "leaves the half before the left edge in the style it had" do
      grid.place 0, 0, wide_cell(7_u32)
      grid.fill TermBuf::Rect.new(1, 0, 2, 1), TermBuf::Cell.new('#', 3_u32)

      expect(grid[0, 0]).to eq TermBuf::Cell.blank(7_u32)
      expect(grid[1, 0].style).to eq 3_u32
    end

    it "leaves the half past the right edge in the style it had" do
      grid.place 1, 0, wide_cell(7_u32)
      grid.fill TermBuf::Rect.new(0, 0, 2, 1), TermBuf::Cell.new('#', 3_u32)

      expect(grid[2, 0]).to eq TermBuf::Cell.blank(7_u32)
      expect(grid[1, 0].style).to eq 3_u32
    end

    it "clips a rectangle that runs off the grid" do
      grid.fill TermBuf::Rect.new(4, 0, 10, 10), TermBuf::Cell.new('#')

      expect(grid[5, 2].char).to eq '#'
    end
  end

  describe "#row_hash" do
    it "matches for rows with equal contents" do
      grid[1, 0] = TermBuf::Cell.new 'a'
      grid[1, 2] = TermBuf::Cell.new 'a'

      expect(grid.row_hash(0)).to eq grid.row_hash(2)
    end

    it "differs when any field of any cell differs" do
      grid[1, 0] = TermBuf::Cell.new 'a'
      grid[1, 1] = TermBuf::Cell.new 'b'
      grid[1, 2] = TermBuf::Cell.new 'a', 7_u32

      expect(grid.row_hash(0)).not_to eq grid.row_hash(1)
      expect(grid.row_hash(0)).not_to eq grid.row_hash(2)
    end

    it "is recomputed after a row changes" do
      before = grid.row_hash 0
      grid[1, 0] = TermBuf::Cell.new 'a'

      expect(grid.row_hash(0)).not_to eq before
    end

    it "is stable when asked for twice" do
      grid[1, 0] = TermBuf::Cell.new 'a'

      expect(grid.row_hash(0)).to eq grid.row_hash(0)
    end
  end

  describe "#scroll" do
    before_each do
      3.times { |row| grid[0, row] = TermBuf::Cell.new('a' + row) }
    end

    it "moves content up and blanks the rows left behind" do
      grid.scroll grid.bounds, 1

      expect(grid[0, 0].char).to eq 'b'
      expect(grid[0, 1].char).to eq 'c'
      expect(grid[0, 2].char).to eq ' '
    end

    it "moves content down and blanks the rows left behind" do
      grid.scroll grid.bounds, -1

      expect(grid[0, 0].char).to eq ' '
      expect(grid[0, 1].char).to eq 'a'
      expect(grid[0, 2].char).to eq 'b'
    end

    it "yields each row that leaves, in the order it leaves" do
      leaving = [] of Char
      grid.scroll(grid.bounds, 2) { |row| leaving << row[0].char }

      expect(leaving).to eq ['a', 'b']
    end

    it "yields the rows leaving the bottom when scrolling down" do
      leaving = [] of Char
      grid.scroll(grid.bounds, -1) { |row| leaving << row[0].char }

      expect(leaving).to eq ['c']
    end

    it "blanks everything when the scroll covers the whole rectangle" do
      grid.scroll grid.bounds, 5

      expect(grid.to_text.gsub(' ', "")).to eq "\n\n"
    end

    it "scrolls only within the rectangle" do
      grid[3, 0] = TermBuf::Cell.new 'X'
      grid.scroll TermBuf::Rect.new(0, 0, 2, 3), 1

      expect(grid[0, 0].char).to eq 'b'
      expect(grid[3, 0].char).to eq 'X'
    end

    it "clips a wide character straddling the rectangle's right edge" do
      grid.place 1, 0, wide_cell
      grid.scroll TermBuf::Rect.new(0, 0, 2, 3), 1

      expect(grid[2, 0]).to eq TermBuf::Cell.blank
    end

    it "leaves the half outside the scrolled rectangle in the style it had" do
      grid.place 1, 0, wide_cell(7_u32)
      grid.scroll TermBuf::Rect.new(0, 0, 2, 3), 1, TermBuf::Cell.blank(3_u32)

      expect(grid[2, 0]).to eq TermBuf::Cell.blank(7_u32)
    end

    it "marks the rows it touched as damaged" do
      grid.damage.clear
      grid.scroll grid.bounds, 1

      expect(grid.damage.rows).to eq 3
    end

    it "does nothing for a zero line scroll" do
      grid.damage.clear
      grid.scroll grid.bounds, 0

      expect(grid.damage.dirty?).to be_false
      expect(grid[0, 0].char).to eq 'a'
    end
  end

  describe "#resize" do
    it "keeps content that still fits, anchored at the top left" do
      grid[1, 1] = TermBuf::Cell.new 'x'
      grid.resize 4, 2

      expect(grid.width).to eq 4
      expect(grid.height).to eq 2
      expect(grid[1, 1].char).to eq 'x'
    end

    it "blanks the space a larger grid gains" do
      grid.resize 8, 5

      expect(grid[7, 4]).to eq TermBuf::Cell.blank
    end

    it "drops a wide character cut in half by the new right edge" do
      grid.place 3, 0, wide_cell
      grid.resize 4, 3

      expect(grid[3, 0]).to eq TermBuf::Cell.blank
    end

    it "leaves everything dirty" do
      grid.resize 4, 2

      expect(grid.damage.rows).to eq 2
      expect(grid.damage.span(0)).to eq 0..3
    end

    it "does nothing when the size is unchanged" do
      grid[1, 1] = TermBuf::Cell.new 'x'
      grid.damage.clear
      grid.resize 6, 3

      expect(grid.damage.dirty?).to be_false
    end
  end

  describe "#copy_from" do
    it "takes on the other grid's contents and comes up clean" do
      other = TermBuf::Grid.new 6, 3
      other[2, 1] = TermBuf::Cell.new 'z'

      grid.copy_from other

      expect(grid[2, 1].char).to eq 'z'
      expect(grid.damage.dirty?).to be_false
      expect(grid).to eq other
    end

    it "refuses a grid of a different size" do
      expect { grid.copy_from(TermBuf::Grid.new(4, 3)) }.to raise_error(ArgumentError)
    end
  end

  describe "#to_text" do
    it "renders one line per row, counting a wide character once" do
      grid.place 0, 0, wide_cell
      grid[2, 0] = TermBuf::Cell.new 'x'

      expect(grid.to_text.lines.first).to eq "漢x   "
    end
  end
end
