require "../spec_helper"

private alias Name = TermBuf::Key::Name
private alias Mods = TermBuf::Modifiers

# Everything one feed produced, in order.
private def decode(text : String, decoder : TermBuf::Decoder? = nil) : Array(TermBuf::Event)
  events = [] of TermBuf::Event
  (decoder || TermBuf::Decoder.new).feed(text.to_slice) { |event| events << event }
  events
end

private def keys(text : String) : Array(TermBuf::Key)
  decode(text).compact_map { |event| event.as?(TermBuf::Events::Key).try &.key }
end

private def key(text : String) : TermBuf::Key
  found = keys text
  raise "expected one key from #{text.inspect}, got #{found.size}" unless found.size == 1

  found.first
end

Spectator.describe TermBuf::Decoder do
  describe "characters" do
    it "delivers one key per character" do
      expect(keys("abc").map &.char).to eq ['a', 'b', 'c']
    end

    it "carries the bytes the terminal sent" do
      event = decode("a").first.as TermBuf::Events::Key

      expect(String.new(event.bytes)).to eq "a"
    end

    it "decodes multi byte characters" do
      expect(key("\u{E9}").char).to eq '\u{E9}'
      expect(key("\u{6F22}").char).to eq '\u{6F22}'
      expect(key("\u{1F642}").char).to eq '\u{1F642}'
    end

    # A read can end anywhere, including the middle of a character.
    it "waits for the rest of a character split across two reads" do
      decoder = TermBuf::Decoder.new
      bytes = "\u{6F22}".to_slice

      expect(decode(String.new(bytes[0, 2]), decoder)).to be_empty
      expect(decoder.pending?).to be_true

      events = decode String.new(bytes[2..]), decoder
      expect(events.size).to eq 1
      expect(events.first.as(TermBuf::Events::Key).key.char).to eq '\u{6F22}'
    end

    it "gives up on a character that never finishes" do
      decoder = TermBuf::Decoder.new
      decode String.new("\u{6F22}".to_slice[0, 2]), decoder

      events = [] of TermBuf::Event
      decoder.flush { |event| events << event }

      expect(events.size).to eq 1
      expect(events.first.as(TermBuf::Events::Key).key.char).to eq Char::REPLACEMENT
    end
  end

  describe "control bytes" do
    it "names the keys that predate escape sequences" do
      expect(key("\r").name).to eq Name::Enter
      expect(key("\n").name).to eq Name::Enter
      expect(key("\t").name).to eq Name::Tab
      expect(key("\u{7F}").name).to eq Name::Backspace
    end

    # An escape on its own is held back, because it is also the first byte of
    # every arrow key. Only the timeout, which arrives as a flush, settles it.
    it "delivers a lone escape as the escape key once nothing follows" do
      decoder = TermBuf::Decoder.new

      expect(decode("\e", decoder)).to be_empty
      expect(decoder.pending?).to be_true

      events = [] of TermBuf::Event
      decoder.flush { |event| events << event }

      expect(events.size).to eq 1
      expect(events.first.as(TermBuf::Events::Key).key.name).to eq Name::Escape
    end

    it "reads a control byte as its letter with ctrl held" do
      expect(key("\u{3}")).to eq TermBuf::Key.character('c', Mods::Ctrl)
      expect(key("\u{1}")).to eq TermBuf::Key.character('a', Mods::Ctrl)
      expect(key("\u{1A}")).to eq TermBuf::Key.character('z', Mods::Ctrl)
      expect(key("\u{1C}")).to eq TermBuf::Key.character('\\', Mods::Ctrl)
      expect(key("\u{0}")).to eq TermBuf::Key.character(' ', Mods::Ctrl)
    end

    # Tab is Ctrl+I on the wire and there is nothing to be done about it; the
    # name that gets used is the one people press.
    it "prefers the named key where a byte stands for two" do
      expect(key("\t").name).to eq Name::Tab
      expect(key("\r").name).to eq Name::Enter
    end
  end

  describe "escape sequences" do
    it "decodes the arrows in both forms" do
      expect(key("\e[A").name).to eq Name::Up
      expect(key("\e[D").name).to eq Name::Left
      expect(key("\eOA").name).to eq Name::Up
      expect(key("\eOC").name).to eq Name::Right
    end

    it "decodes the keys around the arrows" do
      expect(key("\e[H").name).to eq Name::Home
      expect(key("\e[F").name).to eq Name::End
      expect(key("\e[2~").name).to eq Name::Insert
      expect(key("\e[3~").name).to eq Name::Delete
      expect(key("\e[5~").name).to eq Name::PageUp
      expect(key("\e[6~").name).to eq Name::PageDown
    end

    it "decodes the function keys" do
      expect(key("\eOP").name).to eq Name::F1
      expect(key("\e[15~").name).to eq Name::F5
      expect(key("\e[24~").name).to eq Name::F12
      expect(key("\e[34~").name).to eq Name::F20
    end

    it "reads the modifier parameter" do
      expect(key("\e[1;2A")).to eq TermBuf::Key.named(Name::Up, Mods::Shift)
      expect(key("\e[1;5C")).to eq TermBuf::Key.named(Name::Right, Mods::Ctrl)
      expect(key("\e[1;3D")).to eq TermBuf::Key.named(Name::Left, Mods::Alt)
      expect(key("\e[1;7B")).to eq TermBuf::Key.named(Name::Down, Mods::Ctrl | Mods::Alt)
      expect(key("\e[3;5~")).to eq TermBuf::Key.named(Name::Delete, Mods::Ctrl)
    end

    it "decodes the modified function keys" do
      expect(key("\e[1;2P")).to eq TermBuf::Key.named(Name::F1, Mods::Shift)
      expect(key("\e[15;5~")).to eq TermBuf::Key.named(Name::F5, Mods::Ctrl)
    end

    it "reads backtab as shift and tab" do
      expect(key("\e[Z")).to eq TermBuf::Key.named(Name::Tab, Mods::Shift)
    end

    it "reads escape then a character as that character with alt" do
      expect(key("\ea")).to eq TermBuf::Key.character('a', Mods::Alt)
      expect(key("\e\u{3}")).to eq TermBuf::Key.character('c', Mods::Alt | Mods::Ctrl)
    end

    # A cursor position report nobody registered is not F3, however much
    # `ESC [ 3 ; 4 R` looks like one.
    it "refuses to read an unregistered report as a function key" do
      expect(key("\e[3;4R").name).to eq Name::Unknown
    end

    it "hands over a sequence it cannot name with the bytes intact" do
      event = decode("\e[?1;2c").first.as TermBuf::Events::Key

      expect(event.key.name).to eq Name::Unknown
      expect(String.new(event.bytes)).to eq "\e[?1;2c"
    end

    it "decodes the kitty and modifyOtherKeys forms of a modified character" do
      expect(key("\e[99;5u")).to eq TermBuf::Key.character('c', Mods::Ctrl)
      expect(key("\e[27;5;99~")).to eq TermBuf::Key.character('c', Mods::Ctrl)
    end
  end

  # The kitty keyboard protocol spells out the keys an ordinary terminal has no
  # encoding for, as code points in the Unicode private use area. Decoded
  # whether or not the protocol was asked for, since a terminal left in that
  # mode by whatever ran before should still work.
  describe "the kitty functional keys" do
    it "reads the keys that also have an ordinary encoding" do
      expect(key("\e[27u").name).to eq Name::Escape
      expect(key("\e[13u").name).to eq Name::Enter
      expect(key("\e[9u").name).to eq Name::Tab
      expect(key("\e[127u").name).to eq Name::Backspace
    end

    it "reads the lock and system keys" do
      expect(key("\e[57358u").name).to eq Name::CapsLock
      expect(key("\e[57360u").name).to eq Name::NumLock
      expect(key("\e[57363u").name).to eq Name::Menu
    end

    it "reads the function keys past the twelve a terminal can name" do
      expect(key("\e[57376u").name).to eq Name::F13
      expect(key("\e[57398u").name).to eq Name::F35
    end

    it "reads the keypad apart from the keys it shares a meaning with" do
      expect(key("\e[57399u").name).to eq Name::KP0
      expect(key("\e[57414u").name).to eq Name::KPEnter
      expect(key("\e[57427u").name).to eq Name::KPBegin
    end

    it "reads the media and modifier keys" do
      expect(key("\e[57428u").name).to eq Name::MediaPlay
      expect(key("\e[57441u").name).to eq Name::LeftShift
      expect(key("\e[57454u").name).to eq Name::IsoLevel5Shift
    end

    it "keeps the modifiers that came with one" do
      expect(key("\e[57376;5u")).to eq TermBuf::Key.named(Name::F13, Mods::Ctrl)
    end

    # The protocol assigns nothing below 57358, and a code there is no more
    # than the private use character it nominally is.
    it "leaves an unassigned private use code as a character" do
      expect(key("\e[57344u")).to eq TermBuf::Key.character('\u{E000}')
    end
  end

  # With the protocol on, the escape key arrives as `CSI 27 u`: a lone `ESC` is
  # always the start of something longer, so waiting for the rest of it is
  # right and timing out is not.
  describe "#kitty_keyboard?" do
    it "is off until something turns it on" do
      expect(TermBuf::Decoder.new.kitty_keyboard?).to be_false
    end

    it "asks for no deadline while an escape is held back" do
      decoder = TermBuf::Decoder.new
      decoder.kitty_keyboard = true

      expect(decode("\e", decoder)).to be_empty
      expect(decoder.pending?).to be_true
      expect(decoder.read_deadline).to be_nil
    end

    it "does not flush a held escape when the clock runs out" do
      decoder = TermBuf::Decoder.new
      decoder.kitty_keyboard = true
      decoder.escape_timeout = 10.milliseconds
      decode "\e", decoder

      sleep 20.milliseconds
      events = [] of TermBuf::Event
      decoder.tick { |event| events << event }

      expect(events).to be_empty
      expect(decoder.pending?).to be_true
    end

    it "leaves the escape timeout alone when it is off" do
      decoder = TermBuf::Decoder.new
      decoder.escape_timeout = 10.milliseconds
      decode "\e", decoder

      expect(decoder.read_deadline).not_to be_nil

      sleep 20.milliseconds
      events = [] of TermBuf::Event
      decoder.tick { |event| events << event }

      expect(events.size).to eq 1
      expect(events.first.as(TermBuf::Events::Key).key.name).to eq Name::Escape
    end

    # A paste still has to end, whatever the keyboard is doing.
    it "still times a paste out" do
      decoder = TermBuf::Decoder.new
      decoder.kitty_keyboard = true
      decode "\e[200~x", decoder

      expect(decoder.read_deadline).not_to be_nil
    end
  end

  describe "responses" do
    it "delivers a claimed sequence as whatever claimed it" do
      patterns = TermBuf::Input::Patterns.new
      patterns.register(TermBuf::Input::Prefix::CSI, terminator: "R") do |sequence|
        TermBuf::Events::Response.new sequence.bytes
      end

      decoder = TermBuf::Decoder.new
      decoder.on_sequence = ->(sequence : TermBuf::Input::Sequence) { patterns.match sequence }

      events = decode "\e[3;4R", decoder
      expect(events.size).to eq 1
      expect(events.first).to be_a TermBuf::Events::Response
    end

    # A pattern that answers `nil` has looked at the sequence and decided it
    # wants nothing to do with it, which leaves it a keystroke.
    it "delivers a sequence a pattern declined as a key" do
      patterns = TermBuf::Input::Patterns.new
      patterns.register(TermBuf::Input::Prefix::CSI, terminator: "R") do |sequence|
        TermBuf::Events::Response.new(sequence.bytes) if sequence.body.starts_with? '?'
      end

      decoder = TermBuf::Decoder.new
      decoder.on_sequence = ->(sequence : TermBuf::Input::Sequence) { patterns.match sequence }

      expect(decode("\e[3;4R", decoder).first).to be_a TermBuf::Events::Key
    end

    it "delivers a sequence as a key when nothing is asked about it" do
      expect(decode("\e[3;4R").first).to be_a TermBuf::Events::Key
    end
  end

  describe "bracketed paste" do
    it "delivers what was pasted as one event" do
      events = decode "\e[200~hello\e[201~"

      expect(events.size).to eq 1
      expect(events.first.as(TermBuf::Events::Paste).text).to eq "hello"
    end

    it "does not decode pasted text as key presses" do
      events = decode "\e[200~q\r\e[201~"

      expect(events.size).to eq 1
      expect(events.first.as(TermBuf::Events::Paste).text).to eq "q\r"
    end

    # A paste can be split across as many reads as the kernel likes, and the
    # markers can land anywhere.
    it "collects a paste that arrives in pieces" do
      decoder = TermBuf::Decoder.new

      expect(decode("\e[200~one ", decoder)).to be_empty
      expect(decoder.pasting?).to be_true
      expect(decode("two ", decoder)).to be_empty

      events = decode "three\e[201~", decoder
      expect(events.size).to eq 1
      expect(events.first.as(TermBuf::Events::Paste).text).to eq "one two three"
    end

    # Terminals filter the closing marker out of pasted content and nothing
    # else, so an escape sequence on the clipboard reaches us intact.
    it "keeps an escape sequence that was itself pasted" do
      events = decode "\e[200~a\e[Ab\e[201~"

      expect(events.size).to eq 1
      expect(events.first.as(TermBuf::Events::Paste).text).to eq "a\e[Ab"
    end

    it "says whether the terminal closed the paste" do
      events = decode "\e[200~hi\e[201~"

      expect(events.first.as(TermBuf::Events::Paste).complete).to be_true
    end

    # A terminal that sends an opening marker and no closing one would
    # otherwise take every keystroke after it, with nothing to notice.
    it "ends a paste that has stopped arriving" do
      decoder = TermBuf::Decoder.new
      decoder.paste_stall = 20.milliseconds
      decode "\e[200~half a clipboard", decoder

      sleep 40.milliseconds
      events = [] of TermBuf::Event
      decoder.tick { |event| events << event }

      paste = events.compact_map(&.as?(TermBuf::Events::Paste)).first
      expect(paste.text).to eq "half a clipboard"
      expect(paste.complete).to be_false
      expect(decoder.pasting?).to be_false
    end

    # Slow and stopped are different, and the only evidence either way is
    # whether anything is still arriving.
    it "keeps a slow paste alive while bytes keep coming" do
      decoder = TermBuf::Decoder.new
      decoder.paste_stall = 60.milliseconds
      decode "\e[200~one ", decoder

      3.times do
        sleep 30.milliseconds
        decoder.tick { |_| nil }
        decode "more ", decoder
      end

      expect(decoder.pasting?).to be_true
    end

    it "asks the reader to come back while a paste is open" do
      decoder = TermBuf::Decoder.new
      expect(decoder.read_deadline).to be_nil

      decode "\e[200~x", decoder
      deadline = decoder.read_deadline

      fail "a paste with no deadline is a paste nothing can end" unless deadline
      expect(deadline).to be <= decoder.paste_stall
    end

    it "reports progress once a paste has been going long enough" do
      decoder = TermBuf::Decoder.new
      decoder.paste_notice = 10.milliseconds
      decode "\e[200~twelve bytes", decoder

      sleep 20.milliseconds
      events = [] of TermBuf::Event
      decoder.tick { |event| events << event }

      notice = events.compact_map(&.as?(TermBuf::Events::Pasting)).first
      expect(notice.bytes).to eq 12
      expect(notice.elapsed).to be > Time::Span.zero
    end

    it "says nothing about a paste that finishes before anyone would notice" do
      decoder = TermBuf::Decoder.new
      events = decode "\e[200~quick\e[201~", decoder

      expect(events.map(&.class)).to eq [TermBuf::Events::Paste]
    end

    it "does not repeat progress faster than the interval asks for" do
      decoder = TermBuf::Decoder.new
      decoder.paste_notice = 5.milliseconds
      decoder.paste_progress = 10.seconds
      decode "\e[200~x", decoder
      sleep 10.milliseconds

      events = [] of TermBuf::Event
      2.times { decoder.tick { |event| events << event } }

      expect(events.size).to eq 1
    end

    # After a stall, the marker the terminal owed us is worth nothing and
    # would otherwise be reported as a key nobody pressed.
    it "discards a closing marker that arrives after the paste ended" do
      expect(decode("\e[201~")).to be_empty
    end

    it "goes back to delivering keys once the paste closes" do
      decoder = TermBuf::Decoder.new
      decode "\e[200~x\e[201~", decoder

      events = decode "y", decoder
      expect(events.first.as(TermBuf::Events::Key).key.char).to eq 'y'
    end
  end
end
