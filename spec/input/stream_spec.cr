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

  # A sequence that arrives in pieces has to survive the deadline being
  # cancelled and armed again around each piece.
  it "still waits for the rest of a sequence that is on its way" do
    with_keyboard do |keyboard|
      keyboard.stream.decoder.escape_timeout = 500.milliseconds
      keyboard.type "\e"
      sleep 20.milliseconds
      keyboard.type "[A"

      event = keyboard.event_of TermBuf::Events::Key
      fail "no key arrived" unless event
      expect(event.key.name).to eq TermBuf::Key::Name::Up
      expect(String.new(event.bytes)).to eq "\e[A"
    end
  end

  # The deadline that flushed the first escape is spent. The second one needs
  # one of its own, which is only there if the dispatcher arms a fresh timer
  # after every tick as well as after every read.
  it "arms a fresh deadline for an escape typed after one has flushed" do
    with_keyboard do |keyboard|
      keyboard.stream.decoder.escape_timeout = 30.milliseconds

      keyboard.type "\e"
      first = keyboard.event_of TermBuf::Events::Key
      fail "the first escape never arrived" unless first
      expect(first.key.name).to eq TermBuf::Key::Name::Escape

      sleep 60.milliseconds
      keyboard.type "\e"

      second = keyboard.event_of TermBuf::Events::Key
      fail "the second escape never arrived" unless second
      expect(second.key.name).to eq TermBuf::Key::Name::Escape
    end
  end

  it "delivers a timer the application armed" do
    with_keyboard do |keyboard|
      nonce = keyboard.stream.after 20.milliseconds

      timer = keyboard.event_of TermBuf::Events::Timer
      fail "no timer arrived" unless timer
      expect(timer.nonce).to eq nonce
    end
  end

  it "says nothing about a timer that was cancelled before it fired" do
    with_keyboard do |keyboard|
      nonce = keyboard.stream.after 30.milliseconds
      keyboard.stream.cancel nonce

      expect(keyboard.event_of(TermBuf::Events::Timer, 300.milliseconds)).to be_nil
    end
  end

  # The point of the tick riding the same channel as the bytes: what the
  # terminal said before a timer was armed is delivered before that timer, and
  # not by luck.
  it "delivers a timer behind input that arrived before it" do
    with_keyboard do |keyboard|
      keyboard.type "z"
      keyboard.stream.after 50.milliseconds

      first = keyboard.event
      second = keyboard.event

      expect(first).to be_a TermBuf::Events::Key
      expect(second).to be_a TermBuf::Events::Timer
    end
  end

  it "refuses to preload once it has started" do
    with_keyboard do |keyboard|
      expect { keyboard.stream.preload "q".to_slice }.to raise_error
    end
  end

  # The half of cancellation a sleeping fibre cannot do. Cancelling a timer
  # whose tick is already on the channel cannot unsend it, so the nonce has to
  # be checked again by whoever takes it off. Exercised on the timers alone,
  # since holding a running dispatcher still long enough to lose the race is
  # not something a spec can arrange.
  context "the timers underneath" do
    it "drops a tick whose timer was cancelled after it fired" do
      inbound = Channel(TermBuf::Input::Reader::Inbound).new 4
      timers = TermBuf::Input::Timers.new inbound
      nonce = timers.after 5.milliseconds

      # Long enough that the fibre has woken and sent, and nobody has claimed
      # the tick, because nothing is reading this channel.
      sleep 100.milliseconds
      timers.cancel nonce

      tick = inbound.receive.as TermBuf::Input::Timers::Tick
      expect(tick.nonce).to eq nonce
      expect(timers.claim(nonce)).to be_false
    end

    it "hands a tick to whoever claims it first" do
      inbound = Channel(TermBuf::Input::Reader::Inbound).new 4
      timers = TermBuf::Input::Timers.new inbound
      nonce = timers.after 5.milliseconds

      sleep 100.milliseconds
      inbound.receive.as TermBuf::Input::Timers::Tick

      expect(timers.claim(nonce)).to be_true
      expect(timers.claim(nonce)).to be_false
    end

    it "sends nothing for a timer cancelled during its sleep" do
      inbound = Channel(TermBuf::Input::Reader::Inbound).new 4
      timers = TermBuf::Input::Timers.new inbound
      nonce = timers.after 50.milliseconds
      timers.cancel nonce

      sleep 150.milliseconds
      expect(timers.size).to eq 0

      select
      when message = inbound.receive
        fail "a cancelled timer sent #{message.inspect}"
      when timeout 50.milliseconds
        # Which is the point.
      end
    end

    it "gives every timer a nonce of its own" do
      inbound = Channel(TermBuf::Input::Reader::Inbound).new 4
      timers = TermBuf::Input::Timers.new inbound
      nonces = Array.new(4) { timers.after 5.seconds }

      expect(nonces.uniq.size).to eq nonces.size
      expect(timers.size).to eq nonces.size

      nonces.each { |nonce| timers.cancel nonce }
      expect(timers.size).to eq 0
    end
  end
end
