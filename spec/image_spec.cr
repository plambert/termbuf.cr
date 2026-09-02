require "./spec_helper"

private def graphics(temp_file = false) : TermBuf::Capabilities
  flags = TermBuf::Capabilities::MODERN.flags | TermBuf::Capability::KittyGraphics
  flags |= TermBuf::Capability::KittyGraphicsTempFile if temp_file
  TermBuf::Capabilities.new flags
end

private def store(capabilities = graphics) : TermBuf::ImageStore
  TermBuf::ImageStore.new capabilities
end

private def swatch(width = 2, height = 2) : TermBuf::Image
  TermBuf::Image.rgb Bytes.new(width * height * 3, 7_u8), width, height
end

Spectator.describe TermBuf::Image do
  it "takes raw pixels with their dimensions" do
    image = TermBuf::Image.rgb Bytes.new(12, 0_u8), 2, 2

    expect(image.format).to eq TermBuf::Image::Format::Rgb
    expect(image.width).to eq 2
  end

  it "counts four bytes a pixel for rgba" do
    expect { TermBuf::Image.rgba Bytes.new(12, 0_u8), 2, 2 }.to raise_error ArgumentError
    expect(TermBuf::Image.rgba(Bytes.new(16, 0_u8), 2, 2).format)
      .to eq TermBuf::Image::Format::Rgba
  end

  # The terminal reads a PNG's dimensions out of the file, so it does not need
  # to be told them.
  it "takes a png without dimensions" do
    expect(TermBuf::Image.png(Bytes[137_u8, 80_u8]).width).to eq 0
  end

  it "refuses pixels that do not match the dimensions" do
    expect { TermBuf::Image.rgb Bytes.new(11, 0_u8), 2, 2 }.to raise_error ArgumentError
    expect { TermBuf::Image.rgb Bytes.new(0, 0_u8), 2, 2 }.to raise_error ArgumentError
    expect { TermBuf::Image.rgb Bytes.new(12, 0_u8), 0, 2 }.to raise_error ArgumentError
  end
end

Spectator.describe TermBuf::ImageStore do
  describe "placing" do
    it "sends the pixels and puts the cursor where they go" do
      made = store
      made.place swatch, TermBuf::Rect.new(3, 1, 4, 2)
      queued = made.take_pending

      expect(queued.first).to eq "\e[2;4H"
      expect(queued[1]).to contain "a=T,f=24,s=2,v=2,"
      expect(queued[1]).to contain "c=4,r=2"
    end

    # The cursor must not be moved by the placement, or the encoder's idea of
    # where it is stops being true.
    it "tells the terminal to leave the cursor alone and to say nothing" do
      made = store
      made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)

      expect(made.take_pending.join).to contain "C=1,q=1"
    end

    # A reply would reach the input decoder as a keystroke nobody pressed.
    it "suppresses the reply on every sequence it sends" do
      made = store
      placement = made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)
      made.place swatch, TermBuf::Rect.new(4, 0, 2, 1)
      made.delete placement

      made.take_pending.each do |text|
        next unless text.starts_with? "\e_G"

        expect(text).to contain "q=1"
      end
    end

    it "sends the pixels once however many placements follow" do
      made = store
      id = made.add swatch
      made.place id, TermBuf::Rect.new(0, 0, 2, 1)
      made.place id, TermBuf::Rect.new(4, 0, 2, 1)

      sent = made.take_pending.select &.starts_with? "\e_G"
      expect(sent.size).to eq 2
      expect(sent[0]).to contain "a=T"
      expect(sent[1]).to contain "a=p"
      expect(sent[1]).not_to contain "a=T"
    end

    it "keeps track of what is on screen" do
      made = store
      first = made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)
      made.place swatch, TermBuf::Rect.new(4, 0, 2, 1)
      expect(made.placements.size).to eq 2

      made.delete first
      expect(made.placements.size).to eq 1
    end
  end

  describe "transport" do
    it "splits a large image across continuation chunks" do
      made = store
      made.place swatch(64, 64), TermBuf::Rect.new(0, 0, 8, 4)

      chunks = made.take_pending.select &.starts_with? "\e_G"
      expect(chunks.size).to be > 1
      expect(chunks.first).to contain "m=1"
      expect(chunks.last).to contain "m=0"
      expect(chunks.last).not_to contain "a=T"
    end

    it "sends a path when the terminal reads files" do
      made = store graphics(temp_file: true)
      made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)

      sent = made.take_pending.find &.starts_with? "\e_G"
      fail "nothing was sent" unless sent

      expect(sent).to contain "t=t"
      expect(sent).not_to contain "m=1"
    end

    # A terminal checks the path rather than taking the caller's word for it.
    # Ghostty 1.3.2 answers `EINVAL: temporary file not named correctly` for a
    # path without the marker and `EINVAL: temporary file not in temp dir` for
    # one outside what `TMPDIR` names, and `q=1` meant neither was ever seen.
    it "names the file so that a terminal will read it" do
      made = store graphics(temp_file: true)
      made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)

      sent = made.take_pending.find &.starts_with? "\e_G"
      fail "nothing was sent" unless sent

      encoded = sent.partition(';')[2].rchop("\e\\")
      path = String.new Base64.decode(encoded)

      expect(path).to contain TermBuf::ImageStore::TEMP_MARKER
      expect(path).to start_with Dir.tempdir
    end
  end

  # Kitty draws text between z -1 and 0, so a negative z is a picture the text
  # sits on top of and a positive one covers it.
  describe "stacking" do
    it "says nothing at the default, which is over the text" do
      made = store
      made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)

      sent = made.take_pending.find &.starts_with? "\e_G"
      fail "nothing was sent" unless sent

      expect(sent).not_to contain "z="
    end

    it "puts a placement under the text" do
      made = store
      placement = made.place swatch, TermBuf::Rect.new(0, 0, 2, 1), z: -1

      sent = made.take_pending.find &.starts_with? "\e_G"
      fail "nothing was sent" unless sent

      expect(sent).to contain "z=-1"
      expect(placement.under_text?).to be_true
    end

    it "keeps the depth when the same image is placed again" do
      made = store
      id = made.add swatch
      made.place id, TermBuf::Rect.new(0, 0, 2, 1), z: -1
      made.take_pending
      made.place id, TermBuf::Rect.new(4, 0, 2, 1), z: 3

      sent = made.take_pending.find &.starts_with? "\e_G"
      fail "nothing was sent" unless sent

      # The pixels went with the first placement; this one only positions them.
      expect(sent).to contain "a=p"
      expect(sent).to contain "z=3"
    end

    it "is over the text by default" do
      expect(TermBuf::Placement.new(1_u32, 1_u32, TermBuf::Rect.new(0, 0, 2, 1)).z).to eq 0
      expect(TermBuf::Placement.new(1_u32, 1_u32, TermBuf::Rect.new(0, 0, 2, 1)).under_text?)
        .to be_false
    end
  end

  describe "managing" do
    it "deletes one placement by image and placement" do
      made = store
      placement = made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)
      made.take_pending
      made.delete placement

      expect(made.take_pending.join)
        .to eq "\e_Ga=d,d=i,i=#{placement.image},p=#{placement.id},q=1\e\\"
    end

    it "deletes everything at once" do
      made = store
      made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)
      made.take_pending
      made.clear

      expect(made.take_pending.join).to contain "a=d,d=A"
      expect(made.placements).to be_empty
    end

    # A forced repaint is recovering from a screen something else may have
    # cleared, so the pixels go again rather than only the placement.
    it "sends the pixels again on a redraw" do
      made = store
      made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)
      made.take_pending
      made.redraw

      expect(made.take_pending.join).to contain "a=T"
    end

    it "drops a placement that no longer fits" do
      made = store
      made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)
      made.place swatch, TermBuf::Rect.new(30, 10, 4, 2)
      made.resize 20, 6

      expect(made.placements.size).to eq 1
    end
  end

  # An application should not have to branch on whether the terminal draws
  # pictures.
  describe "a terminal without graphics" do
    it "says so and sends nothing" do
      made = store TermBuf::Capabilities::MODERN
      placement = made.place swatch, TermBuf::Rect.new(0, 0, 2, 1)
      made.redraw
      made.delete placement

      expect(made.available?).to be_false
      expect(made.take_pending).to be_empty
    end
  end
end
