require "../spec_helper"

# The painter's decisions, asserted as operations rather than bytes: whether a
# band was scrolled, whether a gap was skipped, whether a tail was erased. The
# round trip spec proves these are safe; here is where it is pinned down that
# they happen at all.
private class Session
  getter buffer : TermBuf::Buffer
  getter painter : TermBuf::Painter
  getter encoder : TermBuf::Encoder

  def initialize(width = 20, height = 6,
                 capabilities = TermBuf::Capabilities::XTERM)
    @buffer = TermBuf::Buffer.new width, height
    @painter = TermBuf::Painter.new capabilities
    @encoder = TermBuf::Encoder.new @buffer.styles, capabilities, width, height
  end

  # Paints and commits, returning the operations without the frame wrapper.
  def paint : Array(TermBuf::Op)
    ops = @painter.paint @buffer
    @buffer.commit_paint
    ops.reject do |op|
      op.is_a?(TermBuf::Ops::SetAutowrap) || op.is_a?(TermBuf::Ops::BeginSync) ||
        op.is_a?(TermBuf::Ops::EndSync)
    end
  end

  def bytes : String
    ops = @painter.paint @buffer
    output = @encoder.encode ops
    @buffer.commit_paint
    output
  end

  def settle : Nil
    @encoder.encode @painter.paint(@buffer)
    @buffer.commit_paint
  end
end

private def texts(ops : Array(TermBuf::Op)) : Array(String)
  ops.compact_map { |op| op.as?(TermBuf::Ops::PutText).try(&.text) }
end

private def moves(ops : Array(TermBuf::Op)) : Array({Int32, Int32})
  ops.compact_map { |op| op.as?(TermBuf::Ops::MoveTo).try { |move| {move.x, move.y} } }
end

Spectator.describe TermBuf::Painter do
  describe "an idle buffer" do
    it "emits nothing" do
      session = Session.new

      expect(session.paint).to be_empty
    end

    it "emits nothing after a paint has settled" do
      session = Session.new
      session.buffer.write 0, 0, "hello"
      session.settle

      expect(session.paint).to be_empty
    end
  end

  describe "row diffing" do
    it "emits only the run that changed" do
      session = Session.new
      session.buffer.write 0, 0, "the quick brown fox"
      session.settle

      session.buffer.write 4, 0, "slow"
      ops = session.paint

      expect(texts(ops)).to eq ["slow"]
      expect(moves(ops)).to eq [{4, 0}]
    end

    it "reprints a short gap rather than moving over it" do
      session = Session.new
      session.buffer.write 0, 0, "abcdefghij"
      session.settle

      session.buffer.write 0, 0, "X"
      session.buffer.write 3, 0, "Y"

      expect(texts(session.paint)).to eq ["XbcY"]
    end

    it "moves over a gap too long to be worth reprinting" do
      session = Session.new
      session.buffer.write 0, 0, "abcdefghij"
      session.settle

      session.buffer.write 0, 0, "X"
      session.buffer.write 9, 0, "Y"
      ops = session.paint

      expect(texts(ops)).to eq ["X", "Y"]
      expect(moves(ops)).to eq [{0, 0}, {9, 0}]
    end

    it "splits a run wherever the style changes" do
      session = Session.new
      session.buffer.write 0, 0, "ab"
      session.buffer.write 2, 0, "cd", TermBuf::Style::DEFAULT.bold
      session.buffer.write 4, 0, "ef"

      expect(texts(session.paint)).to eq ["ab", "cd", "ef"]
    end

    it "touches only the rows that changed" do
      session = Session.new
      3.times { |row| session.buffer.write 0, row, "row #{row}" }
      session.settle

      session.buffer.write 0, 1, "changed"

      expect(moves(session.paint).map(&.[](1))).to eq [1]
    end
  end

  describe "wide characters" do
    it "widens a run that would otherwise start mid-character" do
      session = Session.new
      session.buffer.write 0, 0, "漢字"
      session.settle

      # Overwriting the continuation cell blanks the pair, so the run has to
      # reach back to the column the wide character started in.
      session.buffer.write 1, 0, "x"

      expect(moves(session.paint).first).to eq({0, 0})
    end

    it "never emits half of a wide character" do
      session = Session.new
      session.buffer.write 2, 0, "漢"
      ops = session.paint

      expect(texts(ops).join).to contain "漢"
    end
  end

  describe "trailing erase" do
    it "erases a long tail rather than writing spaces" do
      session = Session.new
      session.buffer.write 0, 1, "a" * 20
      session.settle

      session.buffer.fill TermBuf::Rect.new(3, 1, 17, 1), ' '
      ops = session.paint

      expect(ops.any?(TermBuf::Ops::EraseInLine)).to be_true
      expect(texts(ops)).to be_empty
      expect(moves(ops)).to eq [{3, 1}]
    end

    it "writes spaces for a tail too short to be worth erasing" do
      session = Session.new
      session.buffer.write 0, 1, "a" * 20
      session.settle

      session.buffer.fill TermBuf::Rect.new(18, 1, 2, 1), ' '
      ops = session.paint

      expect(ops.any?(TermBuf::Ops::EraseInLine)).to be_false
      expect(texts(ops)).to eq ["  "]
    end

    it "writes the cells out when the tail carries a background" do
      tinted = TermBuf::Style::DEFAULT.bg TermBuf::Color::BLUE
      session = Session.new
      session.buffer.write 0, 1, "a" * 20
      session.settle

      session.buffer.fill TermBuf::Rect.new(3, 1, 17, 1), ' ', tinted
      ops = session.paint

      expect(ops.any?(TermBuf::Ops::EraseInLine)).to be_false
      expect(texts(ops)).to eq [" " * 17]
    end

    it "writes the cells out when the tail is underlined" do
      session = Session.new
      session.buffer.write 0, 1, "a" * 20
      session.settle

      session.buffer.fill TermBuf::Rect.new(3, 1, 17, 1), ' ',
        TermBuf::Style::DEFAULT.underlined
      ops = session.paint

      expect(ops.any?(TermBuf::Ops::EraseInLine)).to be_false
    end
  end

  describe "scroll extraction" do
    it "scrolls the whole screen without setting margins" do
      session = Session.new
      6.times { |row| session.buffer.write 0, row, "line #{row} content" }
      session.settle

      session.buffer.scroll session.buffer.bounds, 2
      ops = session.paint

      expect(ops.any?(TermBuf::Ops::SetScrollRegion)).to be_false
      expect(ops.compact_map(&.as?(TermBuf::Ops::ScrollUp)).map(&.lines)).to eq [2]
      expect(texts(ops)).to be_empty
    end

    it "sets margins around a band and releases them afterwards" do
      session = Session.new
      6.times { |row| session.buffer.write 0, row, "line #{row} content" }
      session.settle

      session.buffer.scroll TermBuf::Rect.new(0, 1, 20, 4), 1
      ops = session.paint

      region = ops.compact_map(&.as?(TermBuf::Ops::SetScrollRegion)).first
      expect(region.top).to eq 1
      expect(region.bottom).to eq 4
      expect(ops.any?(TermBuf::Ops::ResetScrollRegion)).to be_true
    end

    it "scrolls down as well as up" do
      session = Session.new
      6.times { |row| session.buffer.write 0, row, "line #{row} content" }
      session.settle

      session.buffer.scroll session.buffer.bounds, -2
      ops = session.paint

      expect(ops.compact_map(&.as?(TermBuf::Ops::ScrollDown)).map(&.lines)).to eq [2]
    end

    it "resets the style first, so every terminal fills the same way" do
      session = Session.new
      session.buffer.clear TermBuf::Style::DEFAULT.bg(TermBuf::Color::BLUE)
      6.times { |row| session.buffer.write 0, row, "line #{row}" }
      session.settle

      session.buffer.scroll session.buffer.bounds, 2
      ops = session.paint
      style = ops.index { |op| op.is_a? TermBuf::Ops::SetStyle } || -1
      scroll = ops.index { |op| op.is_a? TermBuf::Ops::ScrollUp } || -1

      expect(style).to be >= 0
      expect(scroll).to be > style
      expect(ops[style].as(TermBuf::Ops::SetStyle).style).to eq TermBuf::StyleTable::DEFAULT
    end

    it "redraws instead when the terminal cannot scroll a region" do
      session = Session.new capabilities: TermBuf::Capabilities::NONE
      6.times { |row| session.buffer.write 0, row, "line #{row}" }
      session.settle

      session.buffer.scroll session.buffer.bounds, 2
      ops = session.paint

      expect(ops.any?(TermBuf::Ops::ScrollUp)).to be_false
      expect(texts(ops)).not_to be_empty
    end

    it "redraws instead when the rectangle is narrower than the screen" do
      session = Session.new
      6.times { |row| session.buffer.write 0, row, "line #{row} content" }
      session.settle

      session.buffer.scroll TermBuf::Rect.new(2, 0, 10, 6), 2
      ops = session.paint

      expect(ops.any?(TermBuf::Ops::ScrollUp)).to be_false
    end

    it "redraws instead when too few rows would be saved" do
      session = Session.new
      session.buffer.write 0, 0, "only one line here"
      session.settle

      # Scrolling a two row band moves one row of content, which does not pay
      # for the margins and the scroll command.
      session.buffer.scroll TermBuf::Rect.new(0, 0, 20, 2), 1
      ops = session.paint

      expect(ops.any?(TermBuf::Ops::ScrollUp)).to be_false
    end
  end

  describe "the frame wrapper" do
    it "turns wrapping off for the duration and back on afterwards" do
      session = Session.new
      session.buffer.write 0, 0, "x"
      ops = session.painter.paint session.buffer

      wraps = ops.compact_map(&.as?(TermBuf::Ops::SetAutowrap)).map(&.enabled)
      expect(wraps).to eq [false, true]
    end

    it "brackets the frame when the terminal can synchronize" do
      session = Session.new capabilities: TermBuf::Capabilities::MODERN
      session.buffer.write 0, 0, "x"
      ops = session.painter.paint session.buffer

      expect(ops.first).to be_a TermBuf::Ops::BeginSync
      expect(ops.last).to be_a TermBuf::Ops::EndSync
    end

    it "omits the wrapper entirely when there is nothing to paint" do
      session = Session.new
      session.settle

      expect(session.painter.paint(session.buffer)).to be_empty
    end
  end

  describe "a forced repaint" do
    it "rewrites the screen after the buffer is invalidated" do
      session = Session.new
      session.buffer.write 0, 0, "hello"
      session.settle

      session.buffer.invalidate
      ops = session.paint

      expect(texts(ops)).not_to be_empty
    end
  end
end
