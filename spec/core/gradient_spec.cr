require "../spec_helper"

private alias Rect = TermBuf::Rect
private alias Color = TermBuf::Color
private alias Gradient = TermBuf::Gradient

private BLACK  = Color.rgb 0, 0, 0
private BRIGHT = Color.rgb 100, 200, 50

Spectator.describe TermBuf::Gradient do
  describe "#at" do
    it "answers its endpoints at the edges of the rectangle" do
      ramp = Gradient.new BLACK, BRIGHT, Rect.new(0, 0, 5, 1)

      expect(ramp.at(0, 0)).to eq BLACK
      expect(ramp.at(4, 0)).to eq BRIGHT
    end

    it "interpolates each channel in between" do
      ramp = Gradient.new BLACK, BRIGHT, Rect.new(0, 0, 5, 1)

      expect(ramp.at(2, 0)).to eq Color.rgb(50, 100, 25)
      # A quarter of the way: 12.5 of the blue channel, rounded to even.
      expect(ramp.at(1, 0)).to eq Color.rgb(25, 50, 12)
    end

    it "starts where the rectangle does, not where the buffer does" do
      ramp = Gradient.new BLACK, BRIGHT, Rect.new(10, 4, 5, 3)

      expect(ramp.at(10, 4)).to eq BLACK
      expect(ramp.at(12, 5)).to eq Color.rgb(50, 100, 25)
      expect(ramp.at(14, 6)).to eq BRIGHT
    end

    it "clamps to the ends outside the rectangle" do
      ramp = Gradient.new BLACK, BRIGHT, Rect.new(2, 0, 4, 1)

      expect(ramp.at(-7, 0)).to eq BLACK
      expect(ramp.at(1, 0)).to eq BLACK
      expect(ramp.at(6, 0)).to eq BRIGHT
      expect(ramp.at(99, 0)).to eq BRIGHT
    end

    it "runs down the rows on the vertical axis" do
      ramp = Gradient.new BLACK, BRIGHT, Rect.new(0, 0, 5, 5), :vertical

      expect(ramp.at(0, 0)).to eq BLACK
      expect(ramp.at(4, 0)).to eq BLACK
      expect(ramp.at(0, 2)).to eq Color.rgb(50, 100, 25)
      expect(ramp.at(0, 4)).to eq BRIGHT
    end

    it "always answers a 24 bit colour, so the encoder can narrow it" do
      ramp = Gradient.new Color::RED, Color.indexed(21), Rect.new(0, 0, 3, 1)

      expect(ramp.at(0, 0).rgb?).to be_true
      expect(ramp.at(0, 0)).to eq Color.rgb(*Color::RED.channels)
      expect(ramp.at(2, 0)).to eq Color.rgb(*Color.indexed(21).channels)
    end

    it "is all of its starting colour when there is nowhere to ramp" do
      single = Gradient.new BLACK, BRIGHT, Rect.new(3, 3, 1, 1)
      empty = Gradient.new BLACK, BRIGHT, Rect.new(0, 0, 0, 0)

      expect(single.at(3, 3)).to eq BLACK
      expect(empty.at(0, 0)).to eq BLACK
    end
  end

  describe "#foreground" do
    it "sets the text colour of the style being written" do
      blend = Gradient.new(BLACK, BRIGHT, Rect.new(0, 0, 5, 1)).foreground
      under = TermBuf::Style::DEFAULT.bg Color::BLUE
      over = TermBuf::Style::DEFAULT.bold

      placed = blend.call under, over, 4, 0

      expect(placed.foreground).to eq BRIGHT
      expect(placed.has?(TermBuf::Attributes::Bold)).to be_true
      expect(placed.background.default?).to be_true
    end
  end

  describe "#background" do
    it "sets the cell colour of the style being written" do
      blend = Gradient.new(BLACK, BRIGHT, Rect.new(0, 0, 5, 1)).background
      under = TermBuf::Style::DEFAULT.bg Color::BLUE
      over = TermBuf::Style::DEFAULT.fg Color::RED

      placed = blend.call under, over, 0, 0

      expect(placed.background).to eq BLACK
      expect(placed.foreground).to eq Color::RED
    end
  end

  describe "#to_s" do
    it "says which way it runs" do
      ramp = Gradient.new BLACK, BRIGHT, Rect.new(0, 0, 5, 1), :vertical

      expect(ramp.to_s).to contain "Vertical"
      expect(ramp.to_s).to contain "Rect(0, 0, 5x1)"
    end
  end
end
