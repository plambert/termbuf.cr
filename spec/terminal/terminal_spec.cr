require "../spec_helper"
require "../support/model_terminal"

# Drives a terminal over a pipe and an in-memory screen, so the whole driver
# runs without a device attached.
#
# Every wait has a deadline. A driver bug that deadlocks should fail a spec,
# not hang the suite.
private class Harness
  getter terminal : TermBuf::Terminal
  getter output : IO::Memory
  getter keyboard : IO::FileDescriptor

  def initialize(columns = 20, rows = 6,
                 capabilities = TermBuf::Capabilities::XTERM,
                 pending : Bytes = Bytes.empty)
    reader, @keyboard = IO.pipe
    @output = IO::Memory.new
    tty = TermBuf::Tty.new reader, @output, managed: false

    @terminal = TermBuf::Terminal.new tty, capabilities,
      TermBuf::ScreenSize.new(columns, rows), pending
    @terminal.start
  end

  # The next event, or `nil` if none arrives in time.
  def event(timeout : Time::Span = 2.seconds) : TermBuf::Event?
    select
    when received = @terminal.events.receive?
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

  # What has been written to the screen since it was last asked.
  def drain : String
    written = @output.to_s
    @output.clear
    written
  end

  def type(text : String) : Nil
    @keyboard.print text
    @keyboard.flush
  end

  def close : Nil
    @keyboard.close rescue nil
    @terminal.close
  end
end

private def with_harness(**options, &)
  harness = Harness.new **options

  begin
    yield harness
  ensure
    harness.close
  end
end

Spectator.describe TermBuf::Terminal do
  describe "taking the terminal over" do
    it "hides the cursor and clears the screen" do
      with_harness do |harness|
        expect(harness.drain).to contain "\e[?25l"
      end
    end

    it "switches to the alternate screen when the terminal has one" do
      with_harness(capabilities: TermBuf::Capabilities::XTERM) do |harness|
        expect(harness.drain).to contain "\e[?1049h"
      end
    end

    it "leaves the alternate screen alone when the terminal has none" do
      with_harness(capabilities: TermBuf::Capabilities::NONE) do |harness|
        expect(harness.drain).not_to contain "\e[?1049h"
      end
    end
  end

  describe "drawing" do
    it "puts what was written on the screen" do
      with_harness do |harness|
        harness.drain
        harness.terminal.write 0, 0, "hello"
        harness.terminal.paint

        expect(harness.drain).to contain "hello"
      end
    end

    it "writes nothing when nothing changed" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "hello"
        harness.terminal.paint
        harness.drain

        harness.terminal.paint

        expect(harness.drain).to eq ""
      end
    end

    it "keeps the order commands were issued in" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "first"
        harness.terminal.write 0, 0, "second"
        harness.terminal.paint
        harness.drain

        harness.terminal.sync do |buffer|
          expect(buffer.to_text.lines.first).to start_with "second"
        end
      end
    end

    it "sends a batch as one unit" do
      with_harness do |harness|
        harness.drain

        harness.terminal.batch do |batch|
          batch.write 0, 0, "one"
          batch.write 0, 1, "two"
          batch.write 0, 2, "three"
        end

        harness.terminal.paint
        written = harness.drain

        expect(written).to contain "one"
        expect(written).to contain "two"
        expect(written).to contain "three"
      end
    end

    it "does nothing for an empty batch" do
      with_harness do |harness|
        harness.terminal.batch { }
        harness.terminal.paint
        harness.drain
        harness.terminal.paint

        expect(harness.drain).to eq ""
      end
    end

    it "clears and fills" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "gone"
        harness.terminal.paint
        harness.terminal.clear
        harness.terminal.paint

        harness.terminal.sync do |buffer|
          expect(buffer.to_text.lines.first.strip).to be_empty
        end
      end
    end

    it "scrolls" do
      with_harness do |harness|
        6.times { |row| harness.terminal.write 0, row, "line #{row}" }
        harness.terminal.paint
        harness.terminal.scroll TermBuf::Rect.new(0, 0, 20, 6), 2
        harness.terminal.paint

        harness.terminal.sync do |buffer|
          expect(buffer.to_text.lines.first).to start_with "line 2"
        end
      end
    end
  end

  describe "#paint!" do
    it "rewrites the screen even though nothing changed" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "hello"
        harness.terminal.paint
        harness.drain

        harness.terminal.paint!

        expect(harness.drain).to contain "hello"
      end
    end
  end

  describe "#sync" do
    it "runs against the buffer on the fibre that owns it" do
      with_harness do |harness|
        harness.terminal.write 2, 1, "x"

        seen = nil.as(Char?)
        harness.terminal.sync { |buffer| seen = buffer.back[2, 1].char }

        expect(seen).to eq 'x'
      end
    end

    it "raises in the caller what was raised in the buffer" do
      with_harness do |harness|
        expect { harness.terminal.sync { raise "from inside" } }
          .to raise_error(Exception, /from inside/)
      end
    end

    it "keeps running after an action raised" do
      with_harness do |harness|
        harness.terminal.sync { raise "ignored" } rescue nil
        harness.terminal.write 0, 0, "still here"
        harness.terminal.paint

        expect(harness.drain).to contain "still here"
      end
    end
  end

  describe "resizing" do
    it "resizes the buffer and says so" do
      with_harness do |harness|
        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(40, 10))
        resize = harness.event_of TermBuf::Events::Resize

        expect(resize).not_to be_nil
        expect(resize.try &.size.columns).to eq 40
        expect(harness.terminal.size.columns).to eq 40

        harness.terminal.sync do |buffer|
          expect(buffer.width).to eq 40
          expect(buffer.height).to eq 10
        end
      end
    end

    it "redraws the whole screen afterwards" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "content"
        harness.terminal.paint
        harness.drain

        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(40, 10))
        harness.event_of TermBuf::Events::Resize
        harness.terminal.paint

        expect(harness.drain).to contain "content"
      end
    end

    it "says nothing when the size did not change" do
      with_harness do |harness|
        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(20, 6))

        expect(harness.event_of(TermBuf::Events::Resize, 200.milliseconds)).to be_nil
      end
    end
  end

  describe "input" do
    it "delivers keystrokes" do
      with_harness do |harness|
        harness.type "abc"
        input = harness.event_of TermBuf::Events::Input

        fail "no input arrived" unless input
        expect(String.new(input.bytes)).to eq "abc"
      end
    end

    it "delivers a terminal reply separately from keystrokes" do
      with_harness do |harness|
        harness.type "\e[3;4R"
        response = harness.event_of TermBuf::Events::Response

        fail "no response arrived" unless response
        expect(String.new(response.bytes)).to eq "\e[3;4R"
      end
    end

    it "delivers keystrokes left over from probing before anything else" do
      with_harness(pending: "q".to_slice) do |harness|
        input = harness.event_of TermBuf::Events::Input

        fail "no input arrived" unless input
        expect(String.new(input.bytes)).to eq "q"
      end
    end

    it "says so when input ends" do
      harness = Harness.new
      harness.keyboard.close

      expect(harness.event_of(TermBuf::Events::Closed)).not_to be_nil
      harness.terminal.close
    end
  end

  describe "passthrough" do
    it "sends bytes to the terminal untouched" do
      with_harness do |harness|
        harness.drain
        harness.terminal.passthrough "\e]0;a title\a"
        harness.terminal.paint

        expect(harness.drain).to contain "\e]0;a title\a"
      end
    end

    it "re-establishes the cursor afterwards, since there is no telling" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "one"
        harness.terminal.paint
        harness.drain

        harness.terminal.passthrough "\e[9;9H"
        harness.terminal.write 0, 1, "two"
        harness.terminal.paint

        # An absolute move, not a relative one: the passthrough could have put
        # the cursor anywhere.
        expect(harness.drain).to contain "\e[2;1H"
      end
    end
  end

  describe "closing" do
    it "shows the cursor and leaves the alternate screen" do
      harness = Harness.new
      harness.drain
      harness.close

      written = harness.output.to_s
      expect(written).to contain "\e[?25h"
      expect(written).to contain "\e[?1049l"
    end

    it "can be closed twice" do
      harness = Harness.new
      harness.close

      expect { harness.terminal.close }.not_to raise_error
    end

    it "ignores drawing after it has closed" do
      harness = Harness.new
      harness.close

      expect { harness.terminal.write(0, 0, "too late") }.not_to raise_error
      expect { harness.terminal.paint }.not_to raise_error
    end

    it "restores the terminal even when the body raises" do
      output = IO::Memory.new
      reader, writer = IO.pipe
      tty = TermBuf::Tty.new reader, output, managed: false
      terminal = TermBuf::Terminal.new tty, TermBuf::Capabilities::XTERM,
        TermBuf::ScreenSize.new(20, 6)
      terminal.start

      begin
        begin
          terminal.write 0, 0, "before the trouble"
          raise "trouble"
        ensure
          terminal.close
        end
      rescue
        # The point is what the terminal did, not what was raised.
      end

      expect(output.to_s).to contain "\e[?1049l"
      writer.close
    end
  end

  describe "the frame scheduler" do
    it "paints without being asked" do
      with_harness do |harness|
        harness.terminal.paint
        harness.drain
        harness.terminal.start_frame_scheduler fps: 100
        harness.terminal.write 0, 0, "scheduled"

        deadline = Time.instant + 2.seconds
        written = ""

        while Time.instant < deadline && !written.includes?("scheduled")
          sleep 10.milliseconds
          written += harness.drain
        end

        expect(written).to contain "scheduled"
        harness.terminal.stop_frame_scheduler
      end
    end

    it "stops when told to" do
      with_harness do |harness|
        harness.terminal.start_frame_scheduler fps: 100
        expect(harness.terminal.scheduling?).to be_true

        harness.terminal.stop_frame_scheduler
        expect(harness.terminal.scheduling?).to be_false
      end
    end

    it "refuses a frame rate that is not positive" do
      with_harness do |harness|
        expect { harness.terminal.start_frame_scheduler(fps: 0) }
          .to raise_error(ArgumentError)
      end
    end
  end

  describe "warnings" do
    it "reports them as events rather than writing to the screen" do
      output = IO::Memory.new
      reader, writer = IO.pipe
      tty = TermBuf::Tty.new reader, output, managed: false
      terminal = TermBuf::Terminal.new tty, TermBuf::Capabilities::NONE,
        TermBuf::ScreenSize.new(20, 6), Bytes.empty, ["something was off"]
      terminal.start

      select
      when event = terminal.events.receive?
        expect(event).to be_a TermBuf::Events::Warning
      when timeout 2.seconds
        fail "no warning arrived"
      end

      expect(output.to_s).not_to contain "something was off"
      writer.close
      terminal.close
    end
  end

  # The bytes the driver sends have to survive the same round trip the painter
  # does; the driver adds framing and a lifecycle around them, not new output.
  describe "what reaches a terminal" do
    it "reproduces the buffer on a model terminal" do
      with_harness do |harness|
        harness.drain

        harness.terminal.batch do |batch|
          batch.write 0, 0, "hello world"
          batch.write 3, 2, "漢字", TermBuf::Style::DEFAULT.bold
          batch.write 0, 4, "\u{1F1FA}\u{1F1F8} flags"
        end

        harness.terminal.paint

        model = ModelTerminal.new 20, 6
        model.feed harness.drain

        harness.terminal.sync do |buffer|
          expect(model.to_text).to eq buffer.to_text
        end
      end
    end
  end
end

Spectator.describe TermBuf::Tty do
  it "does not touch the modes of something that is not a terminal" do
    tty = TermBuf::Tty.new IO::Memory.new, IO::Memory.new

    expect(tty.managed?).to be_false
  end

  it "reports whether it has been entered" do
    output = IO::Memory.new
    tty = TermBuf::Tty.new IO::Memory.new, output, managed: false

    expect(tty.entered?).to be_false
    tty.enter TermBuf::Capabilities::XTERM
    expect(tty.entered?).to be_true
    tty.leave TermBuf::Capabilities::XTERM
    expect(tty.entered?).to be_false
  end

  it "writes nothing when leaving a terminal it never entered" do
    output = IO::Memory.new
    tty = TermBuf::Tty.new IO::Memory.new, output, managed: false
    tty.leave TermBuf::Capabilities::XTERM

    expect(output.to_s).to eq ""
  end

  it "undoes exactly what it did" do
    output = IO::Memory.new
    tty = TermBuf::Tty.new IO::Memory.new, output, managed: false

    tty.enter TermBuf::Capabilities::XTERM
    tty.leave TermBuf::Capabilities::XTERM
    written = output.to_s

    expect(written).to contain "\e[?1049h"
    expect(written).to contain "\e[?1049l"
    expect(written).to contain "\e[?25l"
    expect(written).to contain "\e[?25h"
  end
end
