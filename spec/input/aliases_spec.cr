require "../spec_helper"

# The input side moved into `TermBuf::Input` and is on its way out into a shard
# of its own. The short spellings are what everything written against the old
# arrangement uses, so each one is checked here: an alias that quietly stopped
# pointing at the same type would break a dependent shard and nothing else.
Spectator.describe "the input side's short spellings" do
  it "names the same types" do
    expect(TermBuf::Key).to eq TermBuf::Input::Key
    expect(TermBuf::Modifiers).to eq TermBuf::Input::Modifiers
    expect(TermBuf::Decoder).to eq TermBuf::Input::Decoder
    expect(TermBuf::Event).to eq TermBuf::Input::Event
  end

  it "names the same events" do
    expect(TermBuf::Events::Key).to eq TermBuf::Input::Events::Key
    expect(TermBuf::Events::Paste).to eq TermBuf::Input::Events::Paste
    expect(TermBuf::Events::Pasting).to eq TermBuf::Input::Events::Pasting
    expect(TermBuf::Events::Mouse).to eq TermBuf::Input::Events::Mouse
    expect(TermBuf::Events::Response).to eq TermBuf::Input::Events::Response
    expect(TermBuf::Events::Timer).to eq TermBuf::Input::Events::Timer
    expect(TermBuf::Events::Signal).to eq TermBuf::Input::Events::Signal
    expect(TermBuf::Events::Warning).to eq TermBuf::Input::Events::Warning
    expect(TermBuf::Events::Failure).to eq TermBuf::Input::Events::Failure
    expect(TermBuf::Events::Closed).to eq TermBuf::Input::Events::Closed
  end

  # What a dependent shard actually writes, rather than what the alias points
  # at: a value built through the short name, used through the short name.
  it "builds and matches through the short spellings" do
    key = TermBuf::Key.parse("Ctrl+Shift+Tab").first
    event = TermBuf::Events::Key.new key, Bytes[0x1B, 0x5B, 0x5A]

    expect(key.name.tab?).to be_true
    expect(key.modifiers).to eq TermBuf::Modifiers::Shift | TermBuf::Modifiers::Ctrl
    expect(event).to be_a TermBuf::Event
    expect(event.as?(TermBuf::Input::Events::Key)).to eq event
  end

  # The one event that did not move, because it carries a `ScreenSize`. It
  # arrives on the same channel, which means it has to be an `Input::Event`.
  it "keeps Resize on the same channel" do
    size = TermBuf::ScreenSize.new 80, 24
    resize = TermBuf::Events::Resize.new size, TermBuf::ScreenSize.new(40, 12)

    expect(resize).to be_a TermBuf::Input::Event
    expect(resize).to be_a TermBuf::Event
  end
end
