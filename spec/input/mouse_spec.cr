require "../spec_helper"

private alias Button = TermBuf::Input::Mouse::Button
private alias Action = TermBuf::Input::Mouse::Action

# What the decoder makes of an SGR report, without a stream in the way.
private def report(text : String) : TermBuf::Events::Mouse?
  TermBuf::Input::Mouse.decode TermBuf::Input::Sequence.parse(text.to_slice)
end

# A stream over a pipe, so a report can be watched arriving as an event.
private class Pointer
  getter stream : TermBuf::Input::Stream

  def initialize
    @device, @keys = IO.pipe
    @stream = TermBuf::Input::Stream.new @device, blocking: false
  end

  def start : Nil
    @stream.start
  end

  def send(text : String) : Nil
    @keys.print text
    @keys.flush
  end

  def event(timeout : Time::Span = 2.seconds) : TermBuf::Event?
    select
    when received = @stream.events.receive?
      received
    when timeout timeout
      nil
    end
  end

  def close : Nil
    @keys.close rescue nil
    @stream.close
    @device.close rescue nil
  end
end

private def with_pointer(&)
  pointer = Pointer.new
  pointer.start

  begin
    yield pointer
  ensure
    pointer.close
  end
end

Spectator.describe TermBuf::Input::Mouse do
  describe "what happened" do
    it "reads a press" do
      event = report "\e[<0;10;5M"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Press
      expect(event.button).to eq Button::Left
    end

    it "reads a release" do
      event = report "\e[<0;10;5m"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Release
      expect(event.button).to eq Button::Left
    end

    # Bit 32 turns a press into a drag: the button is still down and the
    # pointer moved.
    it "reads a motion" do
      event = report "\e[<32;10;5M"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Motion
      expect(event.button).to eq Button::Left
    end

    # Nothing is held, which is what a terminal asked for all motion sends.
    it "reads a motion with no button held" do
      event = report "\e[<35;10;5M"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Motion
      expect(event.button).to eq Button::None
    end
  end

  describe "which button" do
    {% for code, button in {  0 => "Left",
                              1 => "Middle",
                              2 => "Right",
                              3 => "None",
                             64 => "WheelUp",
                             65 => "WheelDown",
                             66 => "WheelLeft",
                             67 => "WheelRight",
                            128 => "Button8",
                            129 => "Button9",
                            130 => "Button10",
                            131 => "Button11"} %}
      it "reads button code {{ code }} as {{ button.id }}" do
        event = report "\e[<{{ code }};1;1M"
        fail "nothing decoded" unless event

        expect(event.button).to eq Button::{{ button.id }}
      end
    {% end %}

    # A wheel notch is a press with nothing to release afterwards, which is
    # why the four notches are buttons rather than an action of their own.
    it "calls the wheel a press and nothing else" do
      event = report "\e[<64;3;4M"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Press
      expect(event.button.wheel?).to be_true
      expect(Button::Left.wheel?).to be_false
    end
  end

  describe "what was held" do
    it "reads no modifiers" do
      event = report "\e[<0;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers).to eq TermBuf::Modifiers::None
    end

    it "reads shift" do
      event = report "\e[<4;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers).to eq TermBuf::Modifiers::Shift
      expect(event.button).to eq Button::Left
    end

    it "reads alt" do
      event = report "\e[<8;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers).to eq TermBuf::Modifiers::Alt
    end

    it "reads ctrl" do
      event = report "\e[<16;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers).to eq TermBuf::Modifiers::Ctrl
    end

    it "reads all three at once" do
      event = report "\e[<30;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers)
        .to eq TermBuf::Modifiers::Shift | TermBuf::Modifiers::Alt | TermBuf::Modifiers::Ctrl
      expect(event.button).to eq Button::Right
    end
  end

  # The terminal numbers from one and every buffer coordinate in this shard is
  # numbered from zero. Subtracting that here is what lets an application hand
  # the event straight to `Terminal#hit`.
  describe "where" do
    it "numbers the cells from zero" do
      event = report "\e[<0;1;1M"
      fail "nothing decoded" unless event

      expect(event.x).to eq 0
      expect(event.y).to eq 0
    end

    it "keeps the column and the row the right way round" do
      event = report "\e[<0;80;24M"
      fail "nothing decoded" unless event

      expect(event.x).to eq 79
      expect(event.y).to eq 23
    end

    # SGR is the encoding that can name a column past 223, which is the whole
    # reason for decoding it rather than mode 1000's byte-packed form.
    it "reads a column no byte could carry" do
      event = report "\e[<0;500;300M"
      fail "nothing decoded" unless event

      expect(event.x).to eq 499
      expect(event.y).to eq 299
    end
  end

  describe "what it refuses" do
    {% for description, text in {"a body that is not a report"       => "\e[<A",
                                 "a field that is not a number"      => "\e[<0;x;5M",
                                 "too few fields"                    => "\e[<0;5M",
                                 "too many fields"                   => "\e[<0;1;2;3M",
                                 "no final byte it knows"            => "\e[<0;1;1R",
                                 "a column the terminal cannot mean" => "\e[<0;0;1M",
                                 "a row the terminal cannot mean"    => "\e[<0;1;0M",
                                 "a negative button"                 => "\e[<-1;1;1M",
                                 "nothing after the marker"          => "\e[<M"} %}
      it "says nothing about {{ description.id }}" do
        expect(report({{ text }})).to be_nil
      end
    {% end %}

    it "says nothing about a sequence that is not a CSI" do
      expect(TermBuf::Input::Mouse.decode(
        TermBuf::Input::Sequence.parse("\eO<0;1;1M".to_slice))).to be_nil
    end
  end

  # The stream registers the `CSI <` pattern when it is built, so a report is
  # understood with or without a terminal around it.
  describe "through the stream" do
    it "delivers a report as an event" do
      with_pointer do |pointer|
        pointer.send "\e[<0;12;7M"
        event = pointer.event

        expect(event).to be_a TermBuf::Events::Mouse
        mouse = event.as TermBuf::Events::Mouse
        expect(mouse.button).to eq Button::Left
        expect(mouse.action).to eq Action::Press
        expect(mouse.x).to eq 11
        expect(mouse.y).to eq 6
      end
    end

    it "delivers the release that follows" do
      with_pointer do |pointer|
        pointer.send "\e[<0;12;7M\e[<0;12;7m"

        expect(pointer.event.as(TermBuf::Events::Mouse).action).to eq Action::Press
        expect(pointer.event.as(TermBuf::Events::Mouse).action).to eq Action::Release
      end
    end

    # A pattern answering `nil` is saying "not mine after all", so the sequence
    # carries on to the key decoder rather than being dropped or guessed at.
    it "leaves a CSI < that is not a report to the key decoder" do
      with_pointer do |pointer|
        pointer.send "\e[<nonsense~"
        event = pointer.event

        expect(event).to be_a TermBuf::Events::Key
        expect(event.as(TermBuf::Events::Key).key.name).to eq TermBuf::Key::Name::Unknown
      end
    end
  end
end
