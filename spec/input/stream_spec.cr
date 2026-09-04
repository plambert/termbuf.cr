require "../spec_helper"

# A stream over a pipe, so the whole input side runs with no device attached.
private class Keyboard
  getter stream : TermBuf::Input::Stream

  def initialize(preload : Bytes = Bytes.empty)
    @device, @keys = IO.pipe
    @stream = TermBuf::Input::Stream.new @device, blocking: false
    @stream.preload preload
  end

  def start : Nil
    @stream.start
  end

  def type(text : String) : Nil
    @keys.print text
    @keys.flush
  end

  # The next event, or `nil` if none arrives in time.
  def event(timeout : Time::Span = 2.seconds) : TermBuf::Event?
    select
    when received = @stream.events.receive?
      received
    when timeout timeout
      nil
    end
  end

  # The next event of the given type, skipping anything else.
  def event_of(kind : T.class, timeout : Time::Span = 2.seconds) : T? forall T
    deadline = Time.instant + timeout

    while Time.instant < deadline
      received = event deadline - Time.instant
      return if received.nil?
      return received if received.is_a? T
    end

    nil
  end

  # Closes the writing end, which is what the terminal going away looks like.
  def end_input : Nil
    @keys.close rescue nil
  end

  def close : Nil
    @keys.close rescue nil
    @stream.close
    @device.close rescue nil
  end
end

private def with_keyboard(preload : Bytes = Bytes.empty, &)
  keyboard = Keyboard.new preload
  keyboard.start

  begin
    yield keyboard
  ensure
    keyboard.close
  end
end

Spectator.describe TermBuf::Input::Stream do
  it "delivers a key per character typed" do
    with_keyboard do |keyboard|
      keyboard.type "hi"

      %w[h i].each do |letter|
        event = keyboard.event_of TermBuf::Events::Key
        fail "no key arrived for #{letter}" unless event

        expect(event.key.char).to eq letter[0]
      end
    end
  end

  # What the capability probe read before this stream existed belongs at the
  # front of the stream, not nowhere.
  it "decodes preloaded bytes before anything read" do
    with_keyboard("q".to_slice) do |keyboard|
      event = keyboard.event_of TermBuf::Events::Key

      fail "no key arrived" unless event
      expect(event.key.char).to eq 'q'
    end
  end

  it "hands a sequence a pattern claimed to that pattern" do
    with_keyboard do |keyboard|
      keyboard.stream.patterns.register(TermBuf::Input::Prefix::CSI, terminator: "R") do |sequence|
        TermBuf::Events::Response.new sequence.bytes
      end

      keyboard.type "\e[3;4R"
      response = keyboard.event_of TermBuf::Events::Response

      fail "no response arrived" unless response
      expect(String.new(response.bytes)).to eq "\e[3;4R"
    end
  end

  it "delivers a sequence nothing claimed as a keystroke" do
    with_keyboard do |keyboard|
      keyboard.type "\e[A"
      event = keyboard.event_of TermBuf::Events::Key

      fail "no key arrived" unless event
      expect(event.key.name).to eq TermBuf::Key::Name::Up
    end
  end

  # The escape key sends one byte, and so does the start of every arrow key.
  # Only time separates them, and the dispatcher is what keeps that time.
  it "delivers the escape key once its deadline passes" do
    with_keyboard do |keyboard|
      keyboard.stream.decoder.escape_timeout = 30.milliseconds
      keyboard.type "\e"

      event = keyboard.event_of TermBuf::Events::Key
      fail "the escape key never arrived" unless event
      expect(event.key.name).to eq TermBuf::Key::Name::Escape
    end
  end

  it "sends an injected event without decoding anything" do
    with_keyboard do |keyboard|
      keyboard.stream.inject TermBuf::Events::Warning.new("something to say")
      warning = keyboard.event_of TermBuf::Events::Warning

      fail "no warning arrived" unless warning
      expect(warning.message).to eq "something to say"
    end
  end

  it "says so when input ends" do
    keyboard = Keyboard.new
    keyboard.start
    keyboard.end_input

    begin
      expect(keyboard.event_of(TermBuf::Events::Closed)).not_to be_nil
    ensure
      keyboard.close
    end
  end

  it "refuses to preload once it has started" do
    with_keyboard do |keyboard|
      expect { keyboard.stream.preload "q".to_slice }.to raise_error
    end
  end
end
