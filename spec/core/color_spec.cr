require "../spec_helper"

Spectator.describe TermBuf::Color do
  describe "construction" do
    it "builds the terminal default" do
      expect(TermBuf::Color.default.default?).to be_true
      expect(TermBuf::Color.default.indexed?).to be_false
      expect(TermBuf::Color.default.rgb?).to be_false
    end

    it "builds palette colours" do
      color = TermBuf::Color.indexed 42

      expect(color.indexed?).to be_true
      expect(color.index).to eq 42
    end

    it "builds 24 bit colours from channels" do
      color = TermBuf::Color.rgb 10, 20, 30

      expect(color.rgb?).to be_true
      expect(color.red).to eq 10
      expect(color.green).to eq 20
      expect(color.blue).to eq 30
    end

    it "builds 24 bit colours from a packed value" do
      expect(TermBuf::Color.rgb(0x0A141E)).to eq TermBuf::Color.rgb(10, 20, 30)
    end

    it "rejects out of range values" do
      expect { TermBuf::Color.indexed(256) }.to raise_error(ArgumentError)
      expect { TermBuf::Color.indexed(-1) }.to raise_error(ArgumentError)
      expect { TermBuf::Color.rgb(256, 0, 0) }.to raise_error(ArgumentError)
      expect { TermBuf::Color.rgb(0, -1, 0) }.to raise_error(ArgumentError)
    end

    it "compares by value" do
      expect(TermBuf::Color.indexed(1)).to eq TermBuf::Color.indexed(1)
      expect(TermBuf::Color.indexed(1)).not_to eq TermBuf::Color.rgb(0x800000)
      expect(TermBuf::Color.default).not_to eq TermBuf::Color.indexed(0)
    end

    it "names the sixteen system colours" do
      expect(TermBuf::Color::RED).to eq TermBuf::Color.indexed(1)
      expect(TermBuf::Color::BRIGHT_WHITE).to eq TermBuf::Color.indexed(15)
    end
  end

  describe "#bright?" do
    it "is true only for palette indices eight through fifteen" do
      expect(TermBuf::Color.indexed(7).bright?).to be_false
      expect(TermBuf::Color.indexed(8).bright?).to be_true
      expect(TermBuf::Color.indexed(15).bright?).to be_true
      expect(TermBuf::Color.indexed(16).bright?).to be_false
    end
  end

  describe "#channels" do
    it "resolves system colours through the xterm palette" do
      expect(TermBuf::Color.indexed(0).channels).to eq({0, 0, 0})
      expect(TermBuf::Color.indexed(1).channels).to eq({0x80, 0, 0})
      expect(TermBuf::Color.indexed(15).channels).to eq({255, 255, 255})
    end

    it "resolves cube colours" do
      expect(TermBuf::Color.indexed(16).channels).to eq({0, 0, 0})
      expect(TermBuf::Color.indexed(231).channels).to eq({255, 255, 255})
      # index 16 + 36*r + 6*g + b with r=1, g=2, b=3
      expect(TermBuf::Color.indexed(16 + 36 + 12 + 3).channels).to eq({95, 135, 175})
    end

    it "resolves the grey ramp" do
      expect(TermBuf::Color.indexed(232).channels).to eq({8, 8, 8})
      expect(TermBuf::Color.indexed(255).channels).to eq({238, 238, 238})
    end

    it "reports black for the terminal default, which has no channels" do
      expect(TermBuf::Color.default.channels).to eq({0, 0, 0})
    end
  end

  describe "#to_indexed256" do
    it "leaves default and palette colours alone" do
      expect(TermBuf::Color.default.to_indexed256).to eq TermBuf::Color.default
      expect(TermBuf::Color.indexed(200).to_indexed256).to eq TermBuf::Color.indexed(200)
    end

    it "maps a colour that sits exactly on the cube to that cube entry" do
      expect(TermBuf::Color.rgb(95, 135, 175).to_indexed256)
        .to eq TermBuf::Color.indexed(16 + 36 + 12 + 3)
    end

    it "maps a grey to the ramp rather than the cube" do
      # 128,128,128 is nearer grey ramp entry 12 (128) than any cube level.
      expect(TermBuf::Color.rgb(128, 128, 128).to_indexed256).to eq TermBuf::Color.indexed(244)
    end

    it "maps pure black and white to the cube corners" do
      expect(TermBuf::Color.rgb(0, 0, 0).to_indexed256).to eq TermBuf::Color.indexed(16)
      expect(TermBuf::Color.rgb(255, 255, 255).to_indexed256).to eq TermBuf::Color.indexed(231)
    end

    it "always lands within the palette" do
      [{1, 2, 3}, {250, 5, 250}, {17, 200, 90}, {200, 200, 199}].each do |sample|
        result = TermBuf::Color.rgb(*sample).to_indexed256

        expect(result.indexed?).to be_true
        expect(16 <= result.index <= 255).to be_true
      end
    end
  end

  describe "#to_indexed16" do
    it "leaves default and the system colours alone" do
      expect(TermBuf::Color.default.to_indexed16).to eq TermBuf::Color.default
      expect(TermBuf::Color.indexed(9).to_indexed16).to eq TermBuf::Color.indexed(9)
    end

    it "maps 24 bit colours onto the nearest system colour" do
      expect(TermBuf::Color.rgb(255, 0, 0).to_indexed16).to eq TermBuf::Color::BRIGHT_RED
      expect(TermBuf::Color.rgb(0x80, 0, 0).to_indexed16).to eq TermBuf::Color::RED
      expect(TermBuf::Color.rgb(0, 0, 0).to_indexed16).to eq TermBuf::Color::BLACK
      expect(TermBuf::Color.rgb(255, 255, 255).to_indexed16).to eq TermBuf::Color::BRIGHT_WHITE
    end

    it "maps palette colours above fifteen down through their channels" do
      expect(TermBuf::Color.indexed(231).to_indexed16).to eq TermBuf::Color::BRIGHT_WHITE
      expect(TermBuf::Color.indexed(16).to_indexed16).to eq TermBuf::Color::BLACK
    end

    it "always lands in the first sixteen" do
      [{1, 2, 3}, {250, 5, 250}, {17, 200, 90}].each do |sample|
        result = TermBuf::Color.rgb(*sample).to_indexed16

        expect(result.indexed?).to be_true
        expect(result.index < 16).to be_true
      end
    end
  end

  describe "downgrade ordering" do
    it "is idempotent once a colour is already in range" do
      color = TermBuf::Color.rgb(120, 200, 60).to_indexed256

      expect(color.to_indexed256).to eq color
    end

    it "narrows monotonically from 24 bit through the palette to sixteen" do
      color = TermBuf::Color.rgb 200, 30, 30

      expect(color.to_indexed256.to_indexed16).to eq color.to_indexed16
    end
  end
end
