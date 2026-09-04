require "../spec_helper"

# A stream over a pipe, so the chain runs with no device attached.
private class Keyboard
  getter stream : TermBuf::Input::Stream

  def initialize
    @device, @keys = IO.pipe
    @stream = TermBuf::Input::Stream.new @device, blocking: false
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

  def close : Nil
    @keys.close rescue nil
    @stream.close
    @device.close rescue nil
  end
end

private def with_keyboard(&)
  keyboard = Keyboard.new
  keyboard.start

  begin
    yield keyboard
  ensure
    keyboard.close
  end
end

# A stage named *name* that runs *body*, spelled once so the specs below read
# as what they are about rather than as proc types.
private def stage(name : Symbol,
                  &body : TermBuf::Event, Proc(TermBuf::Event, Nil) -> Nil) : TermBuf::Input::Stage
  TermBuf::Input::Stage.new name, body
end

# What a warning says, for the stages that turn a key into one.
private def said(event : TermBuf::Event?) : String
  event.as(TermBuf::Events::Warning).message
end

# Naming a key and shouting about it are not the same operation twice: the
# order the two run in is the whole of the difference in the result.
private def naming : TermBuf::Input::Stage
  stage(:naming) do |event, emit|
    key = event.as? TermBuf::Events::Key
    next emit.call event unless key

    emit.call TermBuf::Events::Warning.new("typed #{key.key.char}")
  end
end

private def shouting : TermBuf::Input::Stage
  stage(:shouting) do |event, emit|
    warning = event.as? TermBuf::Events::Warning
    next emit.call event unless warning

    emit.call TermBuf::Events::Warning.new("#{warning.message}!")
  end
end

Spectator.describe TermBuf::Input::Stage do
  it "sends events straight through when nothing is registered" do
    with_keyboard do |keyboard|
      expect(keyboard.stream.stages).to be_empty

      keyboard.type "a"
      event = keyboard.event

      expect(event).to be_a TermBuf::Events::Key
      expect(event.as(TermBuf::Events::Key).key.char).to eq 'a'
    end
  end

  it "passes an event a stage emits unchanged" do
    with_keyboard do |keyboard|
      keyboard.stream.stages = [stage(:pass) { |event, emit| emit.call event }]

      keyboard.type "a"
      event = keyboard.event

      expect(event).to be_a TermBuf::Events::Key
      expect(event.as(TermBuf::Events::Key).key.char).to eq 'a'
    end
  end

  # A stage that never emits swallows the event, and nothing downstream — the
  # channel included — ever hears about it.
  it "consumes an event a stage does not emit" do
    with_keyboard do |keyboard|
      swallow = stage(:swallow) do |event, emit|
        emit.call event unless event.is_a? TermBuf::Events::Key
      end

      keyboard.stream.stages = [swallow]

      keyboard.type "abc"
      keyboard.stream.inject TermBuf::Events::Warning.new("still here")

      expect(said(keyboard.event)).to eq "still here"
    end
  end

  it "replaces an event with the one a stage emits in its place" do
    with_keyboard do |keyboard|
      rename = stage(:rename) do |event, emit|
        key = event.as? TermBuf::Events::Key
        next emit.call event unless key

        emit.call TermBuf::Events::Warning.new("typed #{key.key.char}")
      end

      keyboard.stream.stages = [rename]

      keyboard.type "z"
      expect(said(keyboard.event)).to eq "typed z"
    end
  end

  it "injects an extra event for every further emit" do
    with_keyboard do |keyboard|
      twice = stage(:twice) do |event, emit|
        key = event.as? TermBuf::Events::Key
        next emit.call event unless key

        emit.call TermBuf::Events::Warning.new("before")
        emit.call event
        emit.call TermBuf::Events::Warning.new("after")
      end

      keyboard.stream.stages = [twice]

      keyboard.type "q"

      expect(said(keyboard.event)).to eq "before"
      expect(keyboard.event.as(TermBuf::Events::Key).key.char).to eq 'q'
      expect(said(keyboard.event)).to eq "after"
    end
  end

  # `#inject` is the driver talking on its own account, so no stage gets to
  # swallow it — including one that swallows everything.
  it "leaves an injected event alone" do
    with_keyboard do |keyboard|
      keyboard.stream.stages = [stage(:nothing) { |_event, _emit| }]

      keyboard.stream.inject TermBuf::Events::Warning.new("straight past")
      expect(said(keyboard.event)).to eq "straight past"
    end
  end

  describe "order" do
    it "runs the stages in the order the array has them" do
      with_keyboard do |keyboard|
        keyboard.stream.stages = [naming, shouting]

        keyboard.type "k"
        expect(said(keyboard.event)).to eq "typed k!"
      end
    end

    it "gives a different answer when the array is reordered" do
      with_keyboard do |keyboard|
        keyboard.stream.stages = [shouting, naming]

        keyboard.type "k"
        expect(said(keyboard.event)).to eq "typed k"
      end
    end
  end

  # The chain is read once per event. A stage that swaps the array mid-event
  # is describing the next event, not the one in its hand: this one finishes
  # on the chain it started on.
  it "finishes an event on the chain it started on" do
    with_keyboard do |keyboard|
      stream = keyboard.stream

      replacement = stage(:replacement) do |later, pass|
        pass.call TermBuf::Events::Warning.new("replacement saw #{later.class}")
      end

      swapping = stage(:swapping) do |event, emit|
        stream.stages = [replacement]
        emit.call event
      end

      original = stage(:original) do |event, emit|
        emit.call TermBuf::Events::Warning.new("original still ran for #{event.class}")
      end

      stream.stages = [swapping, original]

      keyboard.type "a"
      expect(said(keyboard.event))
        .to eq "original still ran for TermBuf::Input::Events::Key"

      keyboard.type "b"
      expect(said(keyboard.event))
        .to eq "replacement saw TermBuf::Input::Events::Key"
    end
  end
end
