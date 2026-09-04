require "../spec_helper"

private alias Name = TermBuf::Key::Name
private alias Mods = TermBuf::Modifiers

# Every way the four modifiers can be held at once, `None` included.
private def combinations : Array(Mods)
  (0_u8..15_u8).map { |bits| Mods.new bits }
end

# Characters whose description survives a round trip unchanged under every
# modifier: none of them is a `Ctrl` away from a control byte, so none is
# folded onto another key. The awkward ones are here on purpose — the space and
# the nul that are written as words, the plus that is also the separator inside
# a description, and characters from outside ASCII and outside the BMP.
private def characters : Array(Char)
  ['a', 'z', '1', '/', '+', '\\', ' ', '\0', '\u{E9}', '\u{6F22}', '\u{1F642}']
end

# What the decoder makes of one byte on its own.
private def decoded(byte : UInt8) : TermBuf::Key
  keys = [] of TermBuf::Key
  decoder = TermBuf::Decoder.new
  collect = ->(event : TermBuf::Event) do
    keys << event.key if event.is_a? TermBuf::Events::Key
  end

  decoder.feed(Bytes[byte]) { |event| collect.call event }
  decoder.flush { |event| collect.call event }

  raise "expected one key from #{byte}, got #{keys.size}" unless keys.size == 1
  keys.first
end

Spectator.describe TermBuf::Key do
  describe "#to_s" do
    it "prints in a form a binding table would use" do
      expect(TermBuf::Key.character('c', Mods::Ctrl).to_s).to eq "Ctrl+C"
      expect(TermBuf::Key.named(Name::Up, Mods::Alt).to_s).to eq "Alt+Up"
      expect(TermBuf::Key.named(Name::F5, Mods::Shift).to_s).to eq "Shift+F5"
      expect(TermBuf::Key.character('a').to_s).to eq "a"
      expect(TermBuf::Key.character(' ').to_s).to eq "Space"
    end

    # Upper case is how a control character is spelled, and only ASCII has an
    # upper case that means the same key.
    it "leaves a character outside ASCII in the case it was pressed" do
      expect(TermBuf::Key.character('\u{E9}', Mods::Ctrl).to_s).to eq "Ctrl+\u{E9}"
    end
  end

  describe "#is?" do
    it "answers what was pressed without unpacking it" do
      expect(TermBuf::Key.character('q').is?('q')).to be_true
      expect(TermBuf::Key.character('q', Mods::Ctrl).is?('q')).to be_false
      expect(TermBuf::Key.named(Name::Up, Mods::Ctrl).is?(Name::Up)).to be_true
    end
  end

  describe ".parse" do
    it "reads back every named key under every modifier" do
      Name.values.reject(&.character?).each do |name|
        combinations.each do |held|
          key = TermBuf::Key.named name, held
          expect(TermBuf::Key.parse(key.to_s)).to eq [key]
        end
      end
    end

    it "reads back a character under every modifier" do
      characters.each do |char|
        combinations.each do |held|
          key = TermBuf::Key.character char, held
          expect(TermBuf::Key.parse(key.to_s)).to eq [key]
        end
      end
    end

    it "reads a sequence of descriptions" do
      expect(TermBuf::Key.parse("Ctrl+V Ctrl+A")).to eq [
        TermBuf::Key.character('v', Mods::Ctrl),
        TermBuf::Key.character('a', Mods::Ctrl),
      ]

      expect(TermBuf::Key.parse("Ctrl+X s")).to eq [
        TermBuf::Key.character('x', Mods::Ctrl),
        TermBuf::Key.character('s'),
      ]
    end

    it "treats whitespace as nothing but a separator" do
      expect(TermBuf::Key.parse("")).to be_empty
      expect(TermBuf::Key.parse("   ")).to be_empty
      expect(TermBuf::Key.parse("  Up \t Down ")).to eq [
        TermBuf::Key.named(Name::Up),
        TermBuf::Key.named(Name::Down),
      ]
    end

    it "does not care how a name or a modifier is cased" do
      expect(TermBuf::Key.parse("ctrl+ALT+pageup")).to eq(
        TermBuf::Key.parse("Ctrl+Alt+PageUp")
      )
      expect(TermBuf::Key.parse("SHIFT+f12")).to eq [TermBuf::Key.named(Name::F12, Mods::Shift)]
      expect(TermBuf::Key.parse("space")).to eq [TermBuf::Key.character(' ')]
      expect(TermBuf::Key.parse("NUL")).to eq [TermBuf::Key.character('\0')]
    end

    it "does not care in what order the modifiers were written" do
      expect(TermBuf::Key.parse("Super+Shift+Alt+Left")).to eq(
        TermBuf::Key.parse("Alt+Shift+Super+Left")
      )
    end

    it "reads the plus key, alone and modified" do
      expect(TermBuf::Key.parse("+")).to eq [TermBuf::Key.character('+')]
      expect(TermBuf::Key.parse("Ctrl++")).to eq [TermBuf::Key.character('+', Mods::Ctrl)]
    end
  end

  describe ".parse_one" do
    it "reads one description without the array" do
      expect(TermBuf::Key.parse_one("Alt+Up")).to eq TermBuf::Key.named(Name::Up, Mods::Alt)
    end
  end

  # A binding is written against what the terminal sends, and what it sends for
  # these is one byte that two key presses share.
  describe "control aliases" do
    it "folds the control characters that are named keys" do
      expect(TermBuf::Key.parse_one("Ctrl+I")).to eq TermBuf::Key.named(Name::Tab)
      expect(TermBuf::Key.parse_one("Ctrl+M")).to eq TermBuf::Key.named(Name::Enter)
      expect(TermBuf::Key.parse_one("Ctrl+J")).to eq TermBuf::Key.named(Name::Enter)
      expect(TermBuf::Key.parse_one("Ctrl+[")).to eq TermBuf::Key.named(Name::Escape)
      expect(TermBuf::Key.parse_one("Ctrl+?")).to eq TermBuf::Key.named(Name::Backspace)
    end

    # 0x08 is `Ctrl+Backspace` and 0x7F is `Backspace`, so the modifier is what
    # tells the two apart and dropping it would lose a key.
    it "keeps the control on backspace, which is how 0x08 arrives" do
      backspace = TermBuf::Key.named Name::Backspace, Mods::Ctrl

      expect(TermBuf::Key.parse_one("Ctrl+H")).to eq backspace
      expect(TermBuf::Key.parse_one("Ctrl+Backspace")).to eq backspace
      expect(TermBuf::Key.parse_one("Backspace")).to eq TermBuf::Key.named(Name::Backspace)
    end

    it "keeps whatever else was held down" do
      expect(TermBuf::Key.parse_one("Alt+Ctrl+I")).to eq TermBuf::Key.named(Name::Tab, Mods::Alt)
      expect(TermBuf::Key.parse_one("Super+Ctrl+M")).to eq(
        TermBuf::Key.named(Name::Enter, Mods::Super)
      )
      expect(TermBuf::Key.parse_one("Ctrl+Shift+A")).to eq(
        TermBuf::Key.character('a', Mods::Ctrl | Mods::Shift)
      )
    end

    it "settles the case of a control character the way the decoder does" do
      expect(TermBuf::Key.parse_one("Ctrl+A")).to eq TermBuf::Key.character('a', Mods::Ctrl)
      expect(TermBuf::Key.parse_one("Ctrl+a")).to eq TermBuf::Key.character('a', Mods::Ctrl)
    end

    it "reads the control characters that are punctuation" do
      expect(TermBuf::Key.parse_one("Ctrl+@")).to eq TermBuf::Key.character(' ', Mods::Ctrl)
      expect(TermBuf::Key.parse_one("Ctrl+Space")).to eq TermBuf::Key.character(' ', Mods::Ctrl)
      expect(TermBuf::Key.parse_one("Ctrl+^")).to eq TermBuf::Key.character('^', Mods::Ctrl)
      expect(TermBuf::Key.parse_one("Ctrl+_")).to eq TermBuf::Key.character('_', Mods::Ctrl)
    end

    # The point of all of the above: a description and the byte it stands for
    # have to arrive at the same key, or a binding table never fires.
    it "agrees with the decoder on every C0 byte" do
      bytes = (0_u8..0x1F_u8).to_a << 0x7F_u8

      bytes.each do |byte|
        key = decoded byte
        expect(TermBuf::Key.parse(key.to_s)).to eq [key]
      end
    end
  end

  describe "descriptions that are not keys" do
    it "refuses an empty description" do
      expect { TermBuf::Key.parse_one("") }.to raise_error(ArgumentError, /cannot be empty/)
    end

    it "refuses a description that is nothing but modifiers" do
      expect { TermBuf::Key.parse("Ctrl+") }.to raise_error(ArgumentError, /ends with a modifier/)
      expect { TermBuf::Key.parse("Ctrl+Alt+") }.to raise_error(ArgumentError, /ends with a modifier/)
    end

    it "refuses a modifier it does not know" do
      expect { TermBuf::Key.parse("Hyper+X") }.to raise_error(ArgumentError, /not Ctrl, Alt/)
    end

    it "refuses a name it does not know" do
      expect { TermBuf::Key.parse("F36") }.to raise_error(ArgumentError, /neither a key name/)
      expect { TermBuf::Key.parse("Ctrl+Wat") }.to raise_error(ArgumentError, /neither a key name/)
    end

    it "refuses `Character`, which names no key at all" do
      expect { TermBuf::Key.parse("Character") }.to raise_error(ArgumentError, /neither a key name/)
    end

    it "names the description it could not read" do
      expect { TermBuf::Key.parse("Up Ctrl+Nope Down") }.to raise_error(
        ArgumentError, /"Ctrl\+Nope"/
      )
    end
  end
end
