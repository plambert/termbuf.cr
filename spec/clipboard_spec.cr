require "./spec_helper"

private def clipboard(osc52 = true) : {TermBuf::Clipboard, IO::Memory}
  flags = TermBuf::Capabilities::MODERN.flags
  flags |= TermBuf::Capability::Osc52Clipboard if osc52
  written = IO::Memory.new
  made = TermBuf::Clipboard.new(TermBuf::Capabilities.new(flags)) { |bytes| written.write bytes }
  {made, written}
end

Spectator.describe TermBuf::Clipboard do
  describe "what it says it can do" do
    it "needs the capability" do
      expect(clipboard.first.available?).to be_true
      expect(clipboard(osc52: false).first.available?).to be_false
    end
  end

  describe "copying" do
    it "writes the base64 of the text between OSC 52 and ST" do
      made, written = clipboard
      made.copy "x"

      expect(written.to_s).to eq "\e]52;c;eA==\e\\"
    end

    # Base64 of the UTF-8 bytes, not of the characters: a terminal decoding
    # this has to get the same bytes back that the string was made of.
    it "encodes multi-byte text by its UTF-8 bytes" do
      made, written = clipboard
      made.copy "héllo →"

      encoded = Base64.strict_encode "héllo →".to_slice
      expect(written.to_s).to eq "\e]52;c;#{encoded}\e\\"
      expect(Base64.decode_string(encoded)).to eq "héllo →"
    end

    it "names the primary selection with its own letter" do
      made, written = clipboard
      made.copy "x", :primary

      expect(written.to_s).to eq "\e]52;p;eA==\e\\"
    end

    # Better a clipboard that does not change than a screen with an escape
    # sequence printed across it.
    it "says nothing on a terminal without the capability" do
      made, written = clipboard(osc52: false)
      made.copy "x"
      made.copy "x", :primary

      expect(written.to_s).to be_empty
    end

    it "sends an empty string as an empty payload" do
      made, written = clipboard
      made.copy ""

      expect(written.to_s).to eq "\e]52;c;\e\\"
    end
  end
end
