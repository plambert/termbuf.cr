require "./spec_helper"

private def graphics(temp_file = false) : TermBuf::Capabilities
  flags = TermBuf::Capabilities::MODERN.flags | TermBuf::Capability::KittyGraphics
  flags |= TermBuf::Capability::KittyGraphicsTempFile if temp_file
  TermBuf::Capabilities.new flags
end

private def store(capabilities = graphics) : TermBuf::ImageStore
  TermBuf::ImageStore.new capabilities
end

private def swatch(width = 2, height = 2) : TermBuf::Pixels
  TermBuf::Pixels.rgb Bytes.new(width * height * 3, 7_u8), width, height
end

private def box(x = 0, y = 0, width = 2, height = 1) : TermBuf::Rect
  TermBuf::Rect.new x, y, width, height
end

# What every terminal this shard was measured against calls a cell.
private CELL = {8, 16}

# A store that knows how large a cell is, which is what a fit needs.
private def fitting(capabilities = graphics) : TermBuf::ImageStore
  made = TermBuf::ImageStore.new capabilities
  made.cell_size = CELL
  made
end

# The first bytes of a real PNG: the signature, then the length and the type of
# the `IHDR` chunk, then the width and the height as big-endian 32 bit counts.
# Nothing past that is read, so nothing past that is built.
private def png_header(width : UInt32, height : UInt32, marker = "IHDR") : Bytes
  bytes = IO::Memory.new
  bytes.write Bytes[137, 80, 78, 71, 13, 10, 26, 10]
  bytes.write_bytes 13_u32, IO::ByteFormat::BigEndian
  bytes << marker
  bytes.write_bytes width, IO::ByteFormat::BigEndian
  bytes.write_bytes height, IO::ByteFormat::BigEndian
  # The rest of IHDR: bit depth, colour type, compression, filter, interlace.
  bytes.write Bytes[8, 2, 0, 0, 0]
  bytes.to_slice
end

# The escape sequences a store has queued, with the cursor moves left out.
private def sequences(made : TermBuf::ImageStore) : Array(String)
  made.take_pending.select &.starts_with? "\e_G"
end

Spectator.describe TermBuf::Pixels do
  it "takes raw pixels with their dimensions" do
    pixels = TermBuf::Pixels.rgb Bytes.new(12, 0_u8), 2, 2

    expect(pixels.format).to eq TermBuf::Pixels::Format::Rgb
    expect(pixels.width).to eq 2
    expect(pixels.bytes.size).to eq 12
  end

  it "counts four bytes a pixel for rgba" do
    expect { TermBuf::Pixels.rgba Bytes.new(12, 0_u8), 2, 2 }.to raise_error ArgumentError
    expect(TermBuf::Pixels.rgba(Bytes.new(16, 0_u8), 2, 2).format)
      .to eq TermBuf::Pixels::Format::Rgba
  end

  # The terminal reads a PNG's dimensions out of the file, so it does not need
  # to be told them.
  it "takes a png without dimensions" do
    expect(TermBuf::Pixels.png(Bytes[137_u8, 80_u8]).width).to eq 0
  end

  describe "a png's own size" do
    it "reads the width and the height out of the header" do
      pixels = TermBuf::Pixels.png png_header(7_u32, 11_u32)

      expect(pixels.width).to eq 7
      expect(pixels.height).to eq 11
      expect(pixels.format).to eq TermBuf::Pixels::Format::Png
    end

    # The shard does not decode and does not validate. Bytes that are not a PNG
    # are still bytes a terminal may know what to do with.
    it "leaves both at zero for anything it cannot read" do
      expect(TermBuf::Pixels.png(Bytes[1_u8, 2_u8, 3_u8, 4_u8]).width).to eq 0
      expect(TermBuf::Pixels.png(png_header(7_u32, 11_u32)[0, 20]).width).to eq 0
      expect(TermBuf::Pixels.png(png_header(7_u32, 11_u32, "iTXt")).width).to eq 0
      broken = png_header 7_u32, 11_u32
      broken[1] = 0_u8
      expect(TermBuf::Pixels.png(broken).width).to eq 0
    end

    # Nothing this shard can hold and nothing any terminal will draw.
    it "leaves them at zero for a size past what an Int32 holds" do
      expect(TermBuf::Pixels.png(png_header(0xFFFF_FFFF_u32, 11_u32)).width).to eq 0
      expect(TermBuf::Pixels.png(png_header(7_u32, 0xFFFF_FFFF_u32)).height).to eq 0
    end
  end

  it "refuses pixels that do not match the dimensions" do
    expect { TermBuf::Pixels.rgb Bytes.new(11, 0_u8), 2, 2 }.to raise_error ArgumentError
    expect { TermBuf::Pixels.rgb Bytes.new(0, 0_u8), 2, 2 }.to raise_error ArgumentError
    expect { TermBuf::Pixels.rgb Bytes.new(12, 0_u8), 0, 2 }.to raise_error ArgumentError
  end
end

Spectator.describe TermBuf::ImageStore do
  describe "registering" do
    it "gives an id and sends nothing" do
      made = store
      image = made.register swatch

      expect(image.id).to eq 1
      expect(image.uploaded?).to be_false
      expect(image.placements).to be_empty
      expect(made.take_pending).to be_empty
    end

    it "counts up and never goes back" do
      made = store
      first = made.register swatch
      second = made.register swatch(4, 4)
      first.forget

      expect(second.id).to eq 2
      expect(made.register(swatch).id).to eq 3
      expect(made.images.map &.id).to eq [2, 3]
    end

    it "refuses an image another store handed out" do
      mine = store
      yours = store
      expect { mine.frame(&.show(yours.register(swatch), box)) }
        .to raise_error ArgumentError, /another store/
    end

    it "refuses an image that was forgotten" do
      made = store
      image = made.register swatch
      image.forget

      expect(image.forgotten?).to be_true
      expect { image.show box }.to raise_error ArgumentError, /forgotten/
    end
  end

  describe "uploading" do
    it "sends the pixels and puts nothing" do
      made = store
      image = made.register swatch
      image.upload

      sent = sequences made
      expect(sent.size).to eq 1
      expect(sent.first).to contain "a=t,f=24,s=2,v=2,i=1,"
      expect(sent.first).not_to contain "p="
      expect(image.uploaded?).to be_true
      expect(made.placements).to be_empty
    end

    # A transmission over an id the terminal already holds takes every placement
    # of that id off the screen, measured against ghostty 1.3.2, so asking twice
    # has to be free rather than merely wasteful.
    it "sends nothing the second time" do
      made = store
      image = made.register swatch
      image.upload
      made.take_pending
      image.upload

      expect(made.take_pending).to be_empty
    end

    it "sends only the position once the pixels have gone" do
      made = store
      image = made.register swatch
      image.upload
      made.take_pending
      image.show box

      sent = sequences made
      expect(sent.size).to eq 1
      expect(sent.first).to contain "a=p"
      expect(sent.first).not_to contain "a=T"
    end
  end

  describe "showing" do
    it "sends the pixels and puts the cursor where they go" do
      made = store
      made.register(swatch).show TermBuf::Rect.new(3, 1, 4, 2)
      queued = made.take_pending

      expect(queued.first).to eq "\e[2;4H"
      expect(queued[1]).to contain "a=T,f=24,s=2,v=2,"
      expect(queued[1]).to contain "c=4,r=2"
    end

    # The cursor must not be moved by the placement, or the encoder's idea of
    # where it is stops being true.
    it "tells the terminal to leave the cursor alone and to say nothing" do
      made = store
      made.register(swatch).show box

      expect(made.take_pending.join).to contain "C=1,q=1"
    end

    # A reply would reach the input decoder as a keystroke nobody pressed.
    it "suppresses the reply on every sequence it sends" do
      made = store
      image = made.register swatch
      here = image.show box
      image.show box(4)
      here.hide
      image.forget

      made.take_pending.each do |text|
        next unless text.starts_with? "\e_G"

        expect(text).to contain "q=1"
      end
    end

    it "sends the pixels once however many showings follow" do
      made = store
      image = made.register swatch
      image.show box
      image.show box(4)

      sent = sequences made
      expect(sent.size).to eq 2
      expect(sent[0]).to contain "a=T"
      expect(sent[1]).to contain "a=p"
      expect(sent[1]).not_to contain "a=T"
    end

    it "keeps track of what is on screen" do
      made = store
      image = made.register swatch
      first = image.show box
      image.show box(4)

      expect(made.placements.size).to eq 2
      expect(image.placements.size).to eq 2

      first.hide
      expect(made.placements.size).to eq 1
      expect(first.shown?).to be_false
    end
  end

  describe "moving" do
    it "sends the position and not the pixels" do
      made = store
      here = made.register(swatch).show box
      made.take_pending
      here.move box(8, 4)

      sent = sequences made
      expect(sent.size).to eq 1
      expect(sent.first).to contain "a=p"
      expect(sent.first).to contain "p=#{here.id}"
      expect(here.bounds).to eq box(8, 4)
    end

    it "says nothing when nothing changed" do
      made = store
      here = made.register(swatch).show box
      made.take_pending

      here.move box
      here.z = 0
      here.crop = nil

      expect(made.take_pending).to be_empty
    end

    # A put replaces a placement rather than patching it, so a depth change has
    # to carry the cells again. Measured against ghostty 1.3.2, where a put
    # leaving out `z` sets the depth back to zero.
    it "carries the cells again when only the depth changed" do
      made = store
      here = made.register(swatch).show box(0, 0, 4, 2)
      made.take_pending
      here.z = -1

      sent = sequences made
      expect(sent.first).to contain "c=4,r=2"
      expect(sent.first).to contain "z=-1"
      expect(here.under_text?).to be_true
    end
  end

  # One image showing a different rectangle of itself in each of several places,
  # which is what a sheet of sprites is. Measured against ghostty 1.3.2, whose
  # own placement records the crop from `x=`, `y=`, `w=` and `h=`, and reports
  # the whole image where they are left out.
  describe "a crop" do
    it "sends the rectangle of the image to show" do
      made = store
      made.register(swatch(8, 8)).show box, crop: TermBuf::Rect.new(4, 4, 2, 2)

      expect(sequences(made).first).to contain "x=4,y=4,w=2,h=2,"
    end

    it "says nothing about a crop when there is none" do
      made = store
      made.register(swatch).show box

      sent = sequences(made).first
      expect(sent).not_to contain "x="
      expect(sent).not_to contain "w="
    end

    it "steps to another part of the sheet without sending the pixels" do
      made = store
      sprite = made.register(swatch(8, 8)).show box, crop: TermBuf::Rect.new(0, 0, 2, 2)
      made.take_pending
      sprite.crop = TermBuf::Rect.new(2, 0, 2, 2)

      sent = sequences made
      expect(sent.size).to eq 1
      expect(sent.first).to contain "a=p"
      expect(sent.first).to contain "x=2,y=0,w=2,h=2,"
    end

    it "shows two parts of one sheet in two places for one transmission" do
      made = store
      sheet = made.register swatch(8, 8)
      sheet.show box, crop: TermBuf::Rect.new(0, 0, 4, 4)
      sheet.show box(4), crop: TermBuf::Rect.new(4, 4, 4, 4)

      sent = sequences made
      expect(sent.count(&.includes? "a=T")).to eq 1
      expect(sent.count(&.includes? "a=p")).to eq 1
      expect(sheet.placements.size).to eq 2
    end
  end

  # A put carrying both `c=` and `r=` fills those cells whatever that does to the
  # picture's proportions. Measured against ghostty 1.3.2: a 255x340 cover put
  # across 79x17 cells came out 632x272 pixels, which is 2.32 wide to tall where
  # the picture is 0.75. A put carrying one of them works the other out and keeps
  # the proportions, which is what fitting sends.
  describe "a fit" do
    # A cover the shape the application that found this draws: taller than wide.
    def cover : TermBuf::Pixels
      swatch 255, 340
    end

    it "names one side and lets the terminal work the other out" do
      made = fitting
      made.register(cover).show TermBuf::Rect.new(0, 0, 79, 17)

      sent = sequences(made).first
      expect(sent).to contain "r=17,"
      expect(sent).not_to contain "c="
    end

    it "names both sides when it is told to stretch" do
      made = fitting
      made.register(cover).show TermBuf::Rect.new(0, 0, 79, 17), fit: :stretch

      sent = sequences(made).first
      expect(sent).to contain "c=79,r=17,"
    end

    # The box is 632x272 pixels, the picture 255x340, so the height runs out
    # first and 204 pixels of width is 26 cells of the 79.
    it "centres a tall picture in a wide box" do
      made = fitting
      here = made.register(cover).show TermBuf::Rect.new(0, 0, 79, 17)

      expect(here.bounds).to eq TermBuf::Rect.new(0, 0, 79, 17)
      expect(here.drawn).to eq TermBuf::Rect.new(26, 0, 26, 17)
    end

    # The other way round: 320x80 pixels in 20x20 cells is 160x160 pixels, so the
    # width runs out first and 40 pixels of height is 3 cells of the 20.
    it "centres a wide picture in a tall box" do
      made = fitting
      here = made.register(swatch 320, 80).show TermBuf::Rect.new(0, 0, 20, 20)

      expect(here.drawn).to eq TermBuf::Rect.new(0, 8, 20, 3)
      expect(sequences(made).first).to contain "c=20,"
    end

    # The cursor goes to the top left of what is drawn, not of what was asked
    # for, which is the whole of the centring.
    it "puts the cursor where the picture starts" do
      made = fitting
      made.register(cover).show TermBuf::Rect.new(0, 0, 79, 17)

      expect(made.take_pending.first).to eq "\e[1;27H"
    end

    it "fills a box the picture is already the shape of" do
      made = fitting
      here = made.register(swatch 160, 160).show TermBuf::Rect.new(0, 0, 20, 10)

      expect(here.drawn).to eq here.bounds
    end

    # A crop is the part being shown, so a crop decides the proportions.
    # Measured: `c=4` of a 16x16 crop of a 64x16 image came out square.
    it "goes by the crop where there is one" do
      made = fitting
      sheet = made.register swatch 320, 80
      here = sheet.show TermBuf::Rect.new(0, 0, 20, 20), crop: TermBuf::Rect.new(0, 0, 80, 80)

      expect(here.drawn).to eq TermBuf::Rect.new(0, 5, 20, 10)
    end

    it "fills the box when nothing has said how large a cell is" do
      made = store
      here = made.register(cover).show TermBuf::Rect.new(0, 0, 79, 17)

      expect(made.cell_size).to be_nil
      expect(here.drawn).to eq here.bounds
      expect(sequences(made).first).to contain "c=79,r=17,"
    end

    # A `Png` whose header would not parse has no size to fit against.
    it "fills the box when the picture's own size is unknown" do
      made = fitting
      unknown = TermBuf::Pixels.png Bytes[1_u8, 2_u8, 3_u8, 4_u8]
      here = made.register(unknown).show TermBuf::Rect.new(0, 0, 79, 17)

      expect(here.drawn).to eq here.bounds
      expect(sequences(made).first).to contain "c=79,r=17,"
    end

    it "measures again and puts everything back when the cell size changes" do
      made = store
      here = made.register(cover).show TermBuf::Rect.new(0, 0, 79, 17)
      made.take_pending

      made.cell_size = CELL

      expect(here.drawn).to eq TermBuf::Rect.new(26, 0, 26, 17)
      expect(sequences(made).count(&.includes? "r=17,")).to eq 1
    end

    it "says nothing when the cell size did not change" do
      made = fitting
      made.register(cover).show TermBuf::Rect.new(0, 0, 79, 17)
      made.take_pending

      made.cell_size = CELL

      expect(made.take_pending).to be_empty
    end

    it "draws the picture the other way without sending it again" do
      made = fitting
      here = made.register(cover).show TermBuf::Rect.new(0, 0, 79, 17)
      made.take_pending

      here.fit = :stretch

      sent = sequences made
      expect(sent.size).to eq 1
      expect(sent.first).to contain "a=p"
      expect(sent.first).to contain "c=79,r=17,"
      expect(here.drawn).to eq here.bounds
    end

    it "takes a frame's placement back only when the fit is the same" do
      made = fitting
      image = made.register cover
      wide = TermBuf::Rect.new 0, 0, 79, 17
      made.frame &.show(image, wide)
      made.take_pending

      made.frame &.show(image, wide)
      expect(made.take_pending).to be_empty

      made.frame &.show(image, wide, fit: :stretch)
      expect(sequences(made).count(&.includes? "c=79,r=17,")).to eq 1
    end
  end

  describe "transport" do
    it "splits a large image across continuation chunks" do
      made = store
      made.register(swatch(64, 64)).show TermBuf::Rect.new(0, 0, 8, 4)

      chunks = sequences made
      expect(chunks.size).to be > 1
      expect(chunks.first).to contain "m=1"
      expect(chunks.last).to contain "m=0"
      expect(chunks.last).not_to contain "a=T"
    end

    it "sends a path when the terminal reads files" do
      made = store graphics(temp_file: true)
      made.register(swatch).show box

      sent = sequences(made).first
      expect(sent).to contain "t=t"
      expect(sent).not_to contain "m=1"
    end

    # A terminal checks the path rather than taking the caller's word for it.
    # Ghostty 1.3.2 answers `EINVAL: temporary file not named correctly` for a
    # path without the marker and `EINVAL: temporary file not in temp dir` for
    # one outside what `TMPDIR` names, and `q=1` meant neither was ever seen.
    it "names the file so that a terminal will read it" do
      made = store graphics(temp_file: true)
      made.register(swatch).show box

      sent = sequences(made).first
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
      made.register(swatch).show box

      expect(sequences(made).first).not_to contain "z="
    end

    it "puts a placement under the text" do
      made = store
      under = made.register(swatch).show box, z: -1

      expect(sequences(made).first).to contain "z=-1"
      expect(under.under_text?).to be_true
    end

    it "keeps the depth when the same image is shown again" do
      made = store
      image = made.register swatch
      image.show box, z: -1
      made.take_pending
      image.show box(4), z: 3

      sent = sequences(made).first
      # The pixels went with the first showing; this one only positions them.
      expect(sent).to contain "a=p"
      expect(sent).to contain "z=3"
    end
  end

  describe "hiding and forgetting" do
    it "takes one showing off by image and placement" do
      made = store
      here = made.register(swatch).show box
      made.take_pending
      here.hide

      expect(made.take_pending.join)
        .to eq "\e_Ga=d,d=i,i=#{here.image.id},p=#{here.id},q=1\e\\"
    end

    # A delete naming an image and no placement takes every placement of it off
    # and leaves the pixels, measured against ghostty 1.3.2.
    it "takes every showing of an image off in one sequence" do
      made = store
      image = made.register swatch
      image.show box
      image.show box(4)
      made.take_pending
      image.hide

      expect(made.take_pending.join).to eq "\e_Ga=d,d=i,i=1,q=1\e\\"
      expect(image.placements).to be_empty
      expect(image.uploaded?).to be_true
      expect(made.images.size).to eq 1
    end

    it "positions an image shown again after it was hidden" do
      made = store
      image = made.register swatch
      image.show box
      image.hide
      made.take_pending
      image.show box

      expect(sequences(made).first).to contain "a=p"
    end

    # The capital frees the pixels along with the placements, measured against
    # ghostty 1.3.2, where `d=I` empties the registry entry and `d=i` leaves it.
    it "takes the pixels out of the terminal when an image is forgotten" do
      made = store
      image = made.register swatch
      image.show box
      made.take_pending
      image.forget

      expect(made.take_pending.join).to contain "a=d,d=I,i=1"
      expect(made.images).to be_empty
      expect(made.placements).to be_empty
      expect(image.uploaded?).to be_false
    end

    it "does nothing the second time an image is forgotten" do
      made = store
      image = made.register swatch
      image.forget
      made.take_pending
      image.forget

      expect(made.take_pending).to be_empty
    end

    it "clears every placement and every image at once" do
      made = store
      image = made.register swatch
      image.show box
      made.take_pending
      made.clear

      expect(made.take_pending.join).to contain "a=d,d=A"
      expect(made.placements).to be_empty
      expect(made.images).to be_empty
      expect(image.forgotten?).to be_true
    end

    it "clears an image that was registered and never shown" do
      made = store
      made.register swatch
      made.clear

      expect(made.take_pending.join).to contain "a=d,d=A"
      expect(made.images).to be_empty
    end
  end

  describe "a forced repaint" do
    # The screen it is recovering from may have been cleared by something else,
    # so the pixels go again rather than only the position.
    it "sends the pixels again" do
      made = store
      made.register(swatch).show box
      made.take_pending
      made.redraw

      expect(sequences(made).count(&.includes? "a=T")).to eq 1
    end

    it "sends the pixels of an image that was uploaded and never shown" do
      made = store
      image = made.register swatch
      image.upload
      made.take_pending
      made.redraw

      sent = sequences made
      expect(sent.size).to eq 1
      expect(sent.first).to contain "a=t"
    end

    it "sends nothing for an image that was never uploaded" do
      made = store
      made.register swatch
      made.redraw

      expect(made.take_pending).to be_empty
    end

    it "drops a placement that no longer fits" do
      made = store
      image = made.register swatch
      image.show box
      gone = image.show TermBuf::Rect.new(30, 10, 4, 2)
      made.take_pending
      made.resize 20, 6

      expect(made.placements.size).to eq 1
      expect(gone.shown?).to be_false
      # The terminal dropped it when the screen shrank under it.
      expect(made.take_pending).to be_empty
      expect(made.images.size).to eq 1
    end
  end

  # kitty drops images when its cache fills, and a reset from another program
  # wipes them, so an id the terminal had can stop being one. Measured against
  # ghostty 1.3.2, which answers a put naming an id it does not hold with
  # `ENOENT: image not found` and does not suppress it under `q=1`.
  describe "an image the terminal says it lost" do
    it "sends the pixels again the next time it is shown" do
      made = store
      image = made.register swatch
      here = image.show box
      made.take_pending

      made.answered "\e_Gi=#{image.id},p=#{here.id};ENOENT: image not found\e\\"
      image.show box(8)

      expect(sequences(made).count(&.includes? "a=T")).to eq 1
    end

    it "sends them again for a placement that moves" do
      made = store
      image = made.register swatch
      here = image.show box
      made.take_pending

      made.answered "\e_Gi=#{image.id};EINVAL: something the terminal did not like\e\\".to_slice
      here.move box(4)

      expect(sequences(made).count(&.includes? "a=T")).to eq 1
    end

    # Sending pixels over an id the terminal is already holding takes every
    # placement of that id off the screen, measured against ghostty 1.3.2, so an
    # image sent again has to bring the rest of its showings with it.
    it "puts the image's other showings back when the pixels go again" do
      made = store
      image = made.register swatch
      kept = image.show box
      image.show box(4)
      made.take_pending

      made.answered "\e_Gi=#{image.id};ENOENT: image not found\e\\"
      image.show box(8)

      sent = sequences made
      expect(sent.count(&.includes? "a=T")).to eq 1
      # The showing that carried the pixels, and the two put back after it, in
      # the order they are on screen.
      expect(sent.count(&.includes? "a=p")).to eq 2
      expect(sent.count(&.includes? "p=#{kept.id}")).to eq 1
      expect(image.placements.size).to eq 3
    end

    it "puts them back after an upload as well" do
      made = store
      image = made.register swatch
      image.show box
      image.show box(4)
      made.take_pending

      made.answered "\e_Gi=#{image.id};ENOENT: image not found\e\\"
      image.upload

      sent = sequences made
      expect(sent.count(&.includes? "a=t")).to eq 1
      expect(sent.count(&.includes? "a=p")).to eq 2
    end

    it "takes no notice of a reply saying all is well" do
      made = store
      image = made.register swatch
      image.show box
      made.take_pending

      made.answered "\e_Gi=#{image.id};OK\e\\"
      image.show box(8)

      expect(sequences(made).count(&.includes? "a=T")).to eq 0
      expect(image.uploaded?).to be_true
    end

    it "takes no notice of a reply about an image it never had" do
      made = store
      image = made.register swatch
      image.show box
      made.take_pending

      made.answered "\e_Gi=404;ENOENT: image not found\e\\"
      image.show box(8)

      expect(sequences(made).count(&.includes? "a=T")).to eq 0
    end

    it "takes no notice of something that is not a graphics reply" do
      made = store
      made.answered "\e[0n"
      made.answered ""

      expect(made.take_pending).to be_empty
    end
  end

  # A widget tree says every frame what it wants on screen. Saying the same
  # thing again has to cost nothing, because the thing is a few hundred
  # kilobytes and the wire may be an ssh connection.
  describe "a frame at a time" do
    it "sends the pixels on the frame that first wants them" do
      made = store
      image = made.register swatch
      made.frame(&.show(image, box))

      expect(sequences(made).count(&.includes? "a=T")).to eq 1
      expect(made.placements.size).to eq 1
    end

    it "sends nothing at all for the same picture in the same cells" do
      made = store
      image = made.register swatch
      made.frame(&.show(image, box))
      made.take_pending

      made.frame(&.show(image, box))

      # Not even a cursor move: the picture is on the screen in those cells.
      expect(made.take_pending).to be_empty
      expect(made.placements.size).to eq 1
    end

    it "keeps the same placement when it takes one back" do
      made = store
      image = made.register swatch
      first = nil.as(TermBuf::Placement?)
      made.frame { |frame| first = frame.show image, box }
      again = nil.as(TermBuf::Placement?)
      made.frame { |frame| again = frame.show image, box }

      expect(again).to be first
    end

    it "positions a picture that moved rather than sending it again" do
      made = store
      image = made.register swatch
      made.frame(&.show(image, box))
      made.take_pending

      moved = nil.as(TermBuf::Placement?)
      made.frame { |frame| moved = frame.show image, box(8, 4) }

      sent = sequences made
      expect(sent.count(&.includes? "a=T")).to eq 0
      expect(sent.count(&.includes? "a=p")).to eq 1
      # And the cells it left are given up, or the picture is on screen twice.
      expect(sent.count(&.includes? "a=d")).to eq 1
      fail "the frame showed nothing" unless moved
      expect(made.placements.map &.id).to eq [moved.id]
    end

    it "sends a picture again when only its crop changed" do
      made = store
      sheet = made.register swatch(8, 8)
      made.frame &.show(sheet, box, crop: TermBuf::Rect.new(0, 0, 4, 4))
      made.take_pending

      made.frame &.show(sheet, box, crop: TermBuf::Rect.new(4, 4, 4, 4))

      sent = sequences made
      expect(sent.count(&.includes? "a=T")).to eq 0
      expect(sent.count(&.includes? "x=4,y=4,w=4,h=4,")).to eq 1
    end

    it "takes off a picture nobody asked for again, and forgets the image" do
      made = store
      image = made.register swatch
      made.frame(&.show(image, box))
      made.take_pending

      made.frame { }

      expect(sequences(made).join).to contain "a=d,d=I"
      expect(made.placements).to be_empty
      expect(made.images).to be_empty
      expect(image.forgotten?).to be_true
    end

    it "keeps one showing of a picture while taking another off" do
      made = store
      image = made.register swatch
      made.frame do |frame|
        frame.show image, box
        frame.show image, box(8)
      end
      made.take_pending

      made.frame(&.show(image, box))

      # The placement goes and the pixels stay: `d=i` rather than `d=I`.
      sent = sequences made
      expect(sent.size).to eq 1
      expect(sent.first).to contain "a=d,d=i"
      expect(made.placements.size).to eq 1
      expect(image.forgotten?).to be_false
    end

    it "sends the pixels again when the picture comes back" do
      made = store
      first = made.register swatch
      made.frame(&.show(first, box))
      made.frame { }
      made.take_pending

      again = made.register swatch
      made.frame(&.show(again, box))

      expect(sequences(made).count(&.includes? "a=T")).to eq 1
    end

    # The new pixels go before the old placement is taken off, so the box is
    # never empty for a frame.
    it "sends a picture that replaced another, and takes the other off" do
      made = store
      old = made.register swatch
      made.frame(&.show(old, box))
      made.take_pending

      new = made.register swatch(4, 4)
      made.frame(&.show(new, box))

      sent = sequences made
      expect(sent.first).to contain "a=T"
      expect(sent.last).to contain "a=d,d=I,i=#{old.id}"
      expect(made.placements.size).to eq 1
    end

    it "sends nothing for a frame that wants no pictures" do
      made = store
      made.frame { }

      expect(made.take_pending).to be_empty
    end

    # The background-picture case: put one up and stop thinking about it.
    it "leaves a placement no frame made alone" do
      made = store
      image = made.register swatch
      behind = image.show TermBuf::Rect.new(0, 0, 40, 20), z: -1
      made.take_pending

      made.frame { }
      made.frame { }

      expect(made.take_pending).to be_empty
      expect(behind.shown?).to be_true
      expect(made.placements).to eq [behind]
      expect(image.forgotten?).to be_false
    end

    it "does not take an image off for a frame that never mentioned it" do
      made = store
      behind = made.register swatch
      behind.show box
      front = made.register swatch(4, 4)
      made.frame(&.show(front, box(8)))
      made.take_pending

      made.frame { }

      expect(sequences(made).join).to contain "a=d,d=I,i=#{front.id}"
      expect(made.images).to eq [behind]
    end

    it "leaves an image that was uploaded ahead of being shown alone" do
      made = store
      early = made.register swatch
      early.upload
      made.take_pending

      made.frame { }

      expect(made.take_pending).to be_empty
      expect(made.images).to eq [early]
      expect(early.uploaded?).to be_true
    end

    it "refuses to open a frame inside a frame" do
      made = store
      expect { made.frame { made.frame { } } }.to raise_error ArgumentError, /already open/
    end

    # A widget that raises leaves a half-drawn screen either way. What must not
    # happen is the next frame diffing against something that is not there.
    it "keeps what is on screen when the block raises" do
      made = store
      image = made.register swatch
      made.frame(&.show(image, box))
      made.take_pending

      expect do
        made.frame do |frame|
          frame.show image, box
          raise "no"
        end
      end.to raise_error Exception, "no"
      expect(made.take_pending).to be_empty

      made.frame(&.show(image, box))
      expect(made.take_pending).to be_empty
      expect(made.placements.size).to eq 1
    end
  end

  # An application should not have to branch on whether the terminal draws
  # pictures.
  describe "a terminal without graphics" do
    it "says so and sends nothing" do
      made = store TermBuf::Capabilities::MODERN
      image = made.register swatch
      here = image.show box
      image.upload
      made.redraw
      here.move box(4)
      here.hide
      image.forget
      made.frame { }

      expect(made.available?).to be_false
      expect(made.take_pending).to be_empty
    end

    it "still answers everything an application asks it" do
      made = store TermBuf::Capabilities::MODERN
      image = made.register swatch
      here = image.show box

      expect(image.id).to eq 1
      expect(here.bounds).to eq box
      expect(image.uploaded?).to be_false
      expect(made.placements.size).to eq 1
    end
  end
end
