require "../spec_helper"

# A `Signals` over a channel of its own, so a delivery can be taken straight
# off the queue with no stream in the way, and an exit can be watched without
# it killing the spec process.
private class Postbox
  getter signals : TermBuf::Input::Signals

  # Every signal `Mode::Exit` would have re-raised, had it been allowed to.
  getter departures : Channel(::Signal)

  def initialize
    @inbound = Channel(TermBuf::Input::Reader::Inbound).new 16
    @signals = TermBuf::Input::Signals.new @inbound
    @departures = Channel(::Signal).new 8

    departures = @departures
    @signals.terminate = ->(signal : ::Signal) : Nil { departures.send signal }
  end

  def install : Nil
    @signals.install
  end

  def deliver(signal : ::Signal) : Nil
    Process.signal signal, Process.pid
  end

  # The next signal to reach the queue, or `nil` if none arrives in time.
  def received(timeout : Time::Span = 2.seconds) : TermBuf::Input::Signals::Signalled?
    select
    when message = @inbound.receive?
      message.is_a?(TermBuf::Input::Signals::Signalled) ? message : nil
    when timeout timeout
      nil
    end
  end

  # The next signal `Mode::Exit` reached the end of, or `nil` if none does.
  def departed(timeout : Time::Span = 2.seconds) : ::Signal?
    select
    when signal = @departures.receive?
      signal
    when timeout timeout
      nil
    end
  end

  def close : Nil
    @signals.uninstall
  end
end

# Traps are process-global, so every one of these puts them back however it
# ends.
private def with_postbox(&)
  postbox = Postbox.new

  begin
    yield postbox
  ensure
    postbox.close
  end
end

# A stream over a pipe, so a signal can be watched arriving as an event among
# the keystrokes.
private class Wired
  getter stream : TermBuf::Input::Stream

  def initialize
    @device, @keys = IO.pipe
    @stream = TermBuf::Input::Stream.new @device, blocking: false
  end

  def start : Nil
    @stream.start
  end

  def install : Nil
    @stream.signals.install
  end

  def deliver(signal : ::Signal) : Nil
    Process.signal signal, Process.pid
  end

  def type(text : String) : Nil
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

  def event_of(kind : T.class, timeout : Time::Span = 2.seconds) : T? forall T
    deadline = Time.instant + timeout

    while Time.instant < deadline
      received = event deadline - Time.instant
      return if received.nil?
      return received if received.is_a? T
    end

    nil
  end

  def close : Nil
    @keys.close rescue nil
    @stream.close
    @device.close rescue nil
  end
end

private def with_wired(&)
  wired = Wired.new
  wired.start

  begin
    yield wired
  ensure
    wired.close
  end
end

Spectator.describe TermBuf::Input::Signals do
  alias Mode = TermBuf::Input::Signals::Mode

  describe "the modes it starts with" do
    it "stops for the signals that mean stop" do
      with_postbox do |postbox|
        expect(postbox.signals.mode(::Signal::TERM)).to eq Mode::Exit
        expect(postbox.signals.mode(::Signal::INT)).to eq Mode::Exit
        expect(postbox.signals.mode(::Signal::HUP)).to eq Mode::Exit
      end
    end

    it "makes an event of a window change" do
      with_postbox do |postbox|
        expect(postbox.signals.mode(::Signal::WINCH)).to eq Mode::Event
      end
    end
  end

  describe "Mode::Event" do
    it "puts a delivery on the queue" do
      with_postbox do |postbox|
        postbox.signals.mode ::Signal::USR1, Mode::Event
        postbox.install
        postbox.deliver ::Signal::USR1

        signalled = postbox.received
        fail "no signal arrived" unless signalled

        expect(signalled.signal).to eq ::Signal::USR1
        expect(signalled.count).to eq 1
      end
    end

    it "counts the deliveries" do
      with_postbox do |postbox|
        postbox.signals.mode ::Signal::USR1, Mode::Event
        postbox.install

        counts = [] of Int32

        2.times do
          postbox.deliver ::Signal::USR1
          signalled = postbox.received
          fail "no signal arrived" unless signalled
          counts << signalled.count
        end

        expect(counts).to eq [1, 2]
        expect(postbox.signals.count(::Signal::USR1)).to eq 2
      end
    end

    it "forgets the count when asked" do
      with_postbox do |postbox|
        postbox.signals.mode ::Signal::USR1, Mode::Event
        postbox.install

        postbox.deliver ::Signal::USR1
        postbox.received
        postbox.signals.reset_count ::Signal::USR1

        expect(postbox.signals.count(::Signal::USR1)).to eq 0

        postbox.deliver ::Signal::USR1
        signalled = postbox.received
        fail "no signal arrived" unless signalled
        expect(signalled.count).to eq 1
      end
    end
  end

  describe "Mode::WarnThenExit" do
    it "says so first and leaves on the threshold" do
      with_postbox do |postbox|
        postbox.signals.mode ::Signal::USR2, Mode::WarnThenExit
        postbox.signals.threshold ::Signal::USR2, 3
        postbox.install

        counts = [] of Int32

        2.times do
          postbox.deliver ::Signal::USR2
          signalled = postbox.received
          fail "no signal arrived" unless signalled
          counts << signalled.count
        end

        expect(counts).to eq [1, 2]
        expect(postbox.departed(100.milliseconds)).to be_nil

        postbox.deliver ::Signal::USR2
        signalled = postbox.received
        fail "no third signal arrived" unless signalled

        expect(signalled.count).to eq 3
        expect(postbox.departed).to eq ::Signal::USR2
      end
    end

    it "takes two by default" do
      with_postbox do |postbox|
        expect(postbox.signals.threshold(::Signal::USR2)).to eq 2

        postbox.signals.mode ::Signal::USR2, Mode::WarnThenExit
        postbox.install

        postbox.deliver ::Signal::USR2
        postbox.received
        expect(postbox.departed(100.milliseconds)).to be_nil

        postbox.deliver ::Signal::USR2
        postbox.received
        expect(postbox.departed).to eq ::Signal::USR2
      end
    end

    it "will not take a threshold of nothing" do
      with_postbox do |postbox|
        expect { postbox.signals.threshold ::Signal::USR2, 0 }.to raise_error ArgumentError
      end
    end
  end

  describe "Mode::Exit" do
    it "runs every hook in order and then leaves" do
      with_postbox do |postbox|
        order = [] of String

        postbox.signals.before_exit { order << "first" }
        postbox.signals.before_exit { order << "second" }
        postbox.signals.before_exit { order << "third" }
        postbox.signals.mode ::Signal::USR1, Mode::Exit
        postbox.install
        postbox.deliver ::Signal::USR1

        expect(postbox.departed).to eq ::Signal::USR1
        expect(order).to eq ["first", "second", "third"]
      end
    end

    # Giving things back is what these are for, and the ones after the failure
    # have their own to give.
    it "keeps going past a hook that raises" do
      with_postbox do |postbox|
        order = [] of String

        postbox.signals.before_exit { order << "first" }
        postbox.signals.before_exit { raise "the first one broke" }
        postbox.signals.before_exit { order << "third" }
        postbox.signals.mode ::Signal::USR1, Mode::Exit
        postbox.install
        postbox.deliver ::Signal::USR1

        expect(postbox.departed).to eq ::Signal::USR1
        expect(order).to eq ["first", "third"]
      end
    end
  end

  describe "#on" do
    it "runs a handler of its own instead of the modes" do
      with_postbox do |postbox|
        handled = Channel(Nil).new 4

        postbox.signals.on(::Signal::USR1) { handled.send nil }
        postbox.install
        postbox.deliver ::Signal::USR1

        select
        when handled.receive
        when timeout 2.seconds
          fail "the handler never ran"
        end

        expect(postbox.received(100.milliseconds)).to be_nil
        expect(postbox.signals.count(::Signal::USR1)).to eq 0
      end
    end

    # `SIGTSTP` resets its own signal so it can re-raise it at the default
    # handler and stop the process. Coming back from that, the trap has to be
    # there again or the next suspend leaves the screen in raw mode.
    it "puts the trap back after a handler that reset it" do
      with_postbox do |postbox|
        runs = Channel(Nil).new 4

        postbox.signals.on(::Signal::USR1) do
          ::Signal::USR1.reset
          runs.send nil
        end
        postbox.install

        2.times do |attempt|
          postbox.deliver ::Signal::USR1

          select
          when runs.receive
          when timeout 2.seconds
            fail "the handler never ran the #{attempt + 1} time"
          end
        end
      end
    end
  end

  describe "#install" do
    it "says whether it is installed" do
      with_postbox do |postbox|
        expect(postbox.signals.installed?).to be_false

        postbox.install
        expect(postbox.signals.installed?).to be_true

        postbox.signals.uninstall
        expect(postbox.signals.installed?).to be_false
      end
    end

    # A mode set after the handlers went in has to be trapped straight away,
    # not at the next install that never comes.
    it "traps a signal named after it was installed" do
      with_postbox do |postbox|
        postbox.install
        postbox.signals.mode ::Signal::USR1, Mode::Event
        postbox.deliver ::Signal::USR1

        signalled = postbox.received
        fail "no signal arrived" unless signalled
        expect(signalled.signal).to eq ::Signal::USR1
      end
    end
  end
end

Spectator.describe TermBuf::Input::Stream do
  alias Mode = TermBuf::Input::Signals::Mode

  describe "a signal reaching the dispatcher" do
    it "arrives as an event" do
      with_wired do |wired|
        wired.stream.signals.mode ::Signal::USR1, Mode::Event
        wired.install
        wired.deliver ::Signal::USR1

        event = wired.event_of TermBuf::Events::Signal
        fail "no signal arrived" unless event

        expect(event.signal).to eq ::Signal::USR1
        expect(event.count).to eq 1
      end
    end

    # Repeats need not be contiguous: someone pressing the key twice with a
    # keystroke in between still means it.
    it "keeps counting across the input in between" do
      with_wired do |wired|
        wired.stream.signals.mode ::Signal::USR1, Mode::Event
        wired.install

        wired.deliver ::Signal::USR1
        first = wired.event_of TermBuf::Events::Signal
        fail "no first signal arrived" unless first
        expect(first.count).to eq 1

        wired.type "a"
        key = wired.event_of TermBuf::Events::Key
        fail "no key arrived" unless key
        expect(key.key.char).to eq 'a'

        wired.deliver ::Signal::USR1
        second = wired.event_of TermBuf::Events::Signal
        fail "no second signal arrived" unless second
        expect(second.count).to eq 2
      end
    end

    it "delivers nothing for a signal a hook consumed" do
      with_wired do |wired|
        seen = Channel(::Signal).new 4

        wired.stream.on_signal do |signalled|
          seen.send signalled.signal
          nil
        end
        wired.stream.signals.mode ::Signal::USR1, Mode::Event
        wired.install
        wired.deliver ::Signal::USR1

        select
        when signal = seen.receive
          expect(signal).to eq ::Signal::USR1
        when timeout 2.seconds
          fail "the hook never saw the signal"
        end

        expect(wired.event_of(TermBuf::Events::Signal, 100.milliseconds)).to be_nil
      end
    end

    it "delivers whatever the hook made of it instead" do
      with_wired do |wired|
        wired.stream.on_signal do |signalled|
          TermBuf::Events::Warning.new "signal #{signalled.signal} number #{signalled.count}"
        end
        wired.stream.signals.mode ::Signal::USR1, Mode::Event
        wired.install
        wired.deliver ::Signal::USR1

        warning = wired.event_of TermBuf::Events::Warning
        fail "no warning arrived" unless warning
        expect(warning.message).to eq "signal USR1 number 1"
      end
    end

    # Traps are process-global, and one left pointing at a stream nobody is
    # draining would fill the inbound channel and block Crystal's signal fibre.
    it "puts the traps back when the stream closes" do
      wired = Wired.new
      wired.start
      wired.stream.signals.mode ::Signal::USR1, Mode::Event
      wired.install

      begin
        expect(wired.stream.signals.installed?).to be_true
        wired.stream.close
        expect(wired.stream.signals.installed?).to be_false
      ensure
        wired.close
      end
    end
  end
end
