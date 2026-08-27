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

  # Wraps a terminal built elsewhere, for the cases that have to construct one
  # with different arguments.
  def self.wrapping(terminal : TermBuf::Terminal, output : IO::Memory,
                    keyboard : IO::FileDescriptor) : Harness
    new terminal, output, keyboard
  end

  private def initialize(@terminal : TermBuf::Terminal, @output : IO::Memory,
                         @keyboard : IO::FileDescriptor)
  end

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

# A harness whose terminal measures its widths on the way up, with *answers*
# already waiting to be read.
private def with_probing_harness(answers : String, spec : String? = nil, &)
  reader, keyboard = IO.pipe
  output = IO::Memory.new
  tty = TermBuf::Tty.new reader, output, managed: false

  keyboard.print answers
  keyboard.flush

  terminal = TermBuf::Terminal.new tty, TermBuf::Capabilities::XTERM,
    TermBuf::ScreenSize.new(20, 6),
    width_spec: spec, probe_widths: true
  terminal.start

  begin
    yield Harness.wrapping(terminal, output, keyboard)
  ensure
    terminal.close
    keyboard.close rescue nil
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

  describe "the paint meter" do
    it "counts what the last paint sent" do
      with_harness do |harness|
        # The takeover sequence went out before any paint did, and the meter
        # counts frames rather than everything the driver has ever written.
        harness.drain

        harness.terminal.write 0, 0, "hello"
        harness.terminal.paint

        expect(harness.terminal.last_paint_bytes).to eq harness.drain.bytesize
        expect(harness.terminal.total_paint_bytes).to eq harness.terminal.last_paint_bytes
      end
    end

    it "reports nothing for a frame that changed nothing" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "hello"
        harness.terminal.paint
        first = harness.terminal.total_paint_bytes

        harness.terminal.paint

        expect(harness.terminal.last_paint_bytes).to eq 0
        expect(harness.terminal.total_paint_bytes).to eq first
      end
    end

    it "keeps a running total across frames" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "hello"
        harness.terminal.paint
        first = harness.terminal.last_paint_bytes

        harness.terminal.write 0, 1, "again"
        harness.terminal.paint

        expect(harness.terminal.total_paint_bytes)
          .to eq first + harness.terminal.last_paint_bytes
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

  describe "cursors" do
    it "puts what was streamed through one on the screen" do
      with_harness do |harness|
        harness.drain
        harness.terminal.cursor.io.puts "hello"
        harness.terminal.paint

        expect(harness.drain).to contain "hello"
      end
    end

    it "gives the default cursor the whole screen" do
      with_harness(columns: 8, rows: 3) do |harness|
        cursor = harness.terminal.cursor
        6.times { |index| cursor.puts "r#{index}" }
        harness.terminal.paint

        harness.terminal.sync do |buffer|
          expect(buffer.to_text.lines.first).to start_with "r4"
        end
      end
    end

    it "grows the default cursor's region with the screen" do
      with_harness(columns: 8, rows: 3) do |harness|
        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(20, 6))
        harness.event_of TermBuf::Events::Resize

        cursor = harness.terminal.cursor
        cursor.print "0123456789abcdefghij"

        expect(cursor.y).to eq 0
        expect(cursor.x).to eq 19
      end
    end

    it "keeps a cursor over a region inside it" do
      with_harness(columns: 12, rows: 5) do |harness|
        cursor = harness.terminal.cursor TermBuf::Rect.new(2, 1, 4, 2)
        cursor.print "abcdef"
        harness.terminal.paint

        harness.terminal.sync do |buffer|
          lines = buffer.to_text.lines
          expect(lines[1]).to eq "  abcd      "
          expect(lines[2]).to eq "  ef        "
        end
      end
    end
  end

  describe "the terminal's own cursor" do
    it "stays hidden until a cursor is associated with it" do
      with_harness do |harness|
        harness.terminal.write 0, 0, "x"
        harness.terminal.paint

        expect(harness.drain).not_to contain "\e[?25h"
      end
    end

    it "shows and follows the cursor it was given" do
      with_harness do |harness|
        cursor = harness.terminal.cursor
        cursor.move_to 4, 2
        harness.terminal.hardware_cursor = cursor
        harness.drain

        harness.terminal.paint
        written = harness.drain

        expect(written).to contain "\e[?25h"
        expect(written).to contain "\e[3;5H"
      end
    end

    # A frame that changes no cells is still worth sending when the cursor has
    # moved: it is what tells someone where they are typing.
    it "sends a frame for a move even when nothing else changed" do
      with_harness do |harness|
        cursor = harness.terminal.cursor
        harness.terminal.hardware_cursor = cursor
        harness.terminal.paint
        harness.drain

        cursor.move_to 7, 3
        harness.terminal.paint

        expect(harness.drain).to contain "\e[4;8H"
      end
    end

    it "sends nothing when neither the screen nor the cursor moved" do
      with_harness do |harness|
        harness.terminal.hardware_cursor = harness.terminal.cursor
        harness.terminal.paint
        harness.drain

        harness.terminal.paint

        expect(harness.drain).to eq ""
      end
    end

    # Painting cells leaves the terminal's cursor wherever the last run ended,
    # so a frame that drew anything has to put it back.
    it "puts it back after the cells have been painted" do
      with_harness do |harness|
        cursor = harness.terminal.cursor
        cursor.move_to 1, 1
        harness.terminal.hardware_cursor = cursor
        harness.terminal.paint
        harness.drain

        harness.terminal.write 0, 4, "elsewhere"
        harness.terminal.paint
        written = harness.drain

        expect(written).to contain "elsewhere"
        # The move comes after the text, or it would be undone by it.
        expect(written.rindex!("\e[2;2H")).to be > written.index!("elsewhere")
      end
    end

    it "hides it again when asked" do
      with_harness do |harness|
        harness.terminal.hardware_cursor = harness.terminal.cursor
        harness.terminal.paint
        harness.drain

        harness.terminal.hide_cursor
        harness.terminal.paint

        expect(harness.drain).to contain "\e[?25l"
      end
    end
  end

  describe "blitting" do
    it "composites another buffer into a frame" do
      with_harness do |harness|
        panel = TermBuf::Buffer.new 4, 1
        panel.clear
        panel.write 0, 0, "pane"

        harness.terminal.batch do |screen|
          screen.write 0, 0, "........"
          screen.blit panel, 2, 0
        end
        harness.terminal.paint

        expect(harness.drain).to contain "..pane.."
      end
    end

    it "clips a blit through a view" do
      with_harness do |harness|
        panel = TermBuf::Buffer.new 4, 1
        panel.clear
        panel.write 0, 0, "pane"

        harness.terminal.batch do |screen|
          screen.write 0, 0, "........"
          screen.view(TermBuf::Rect.new(2, 0, 2, 1)).blit panel, 0, 0
        end
        harness.terminal.paint

        expect(harness.drain).to contain "..pa...."
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

    it "runs a resize handler before the event reaches the application" do
      with_harness do |harness|
        placed = nil.as(TermBuf::Rect?)
        pane = TermBuf::Region.new TermBuf::Rect.new(0, 5, 20, 1)

        harness.terminal.on_resize do |size|
          pane.bounds = TermBuf::Rect.new 0, size.rows - 1, size.columns, 1
          placed = pane.bounds
        end

        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(40, 10))
        expect(harness.event_of(TermBuf::Events::Resize)).not_to be_nil

        # Set by the handler, so it had already run when the event arrived.
        expect(placed).to eq TermBuf::Rect.new(0, 9, 40, 1)
        expect(pane.bounds).to eq TermBuf::Rect.new(0, 9, 40, 1)
      end
    end

    it "runs after the terminal has taken the new size" do
      with_harness do |harness|
        reported = nil.as(Tuple(Int32, Int32)?)
        settled = nil.as(Tuple(Int32, Int32)?)

        harness.terminal.on_resize do |size|
          reported = {size.columns, size.rows}
          # Already updated, so a handler can lay out from either one.
          settled = {harness.terminal.size.columns, harness.terminal.size.rows}
        end

        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(40, 10))
        harness.event_of TermBuf::Events::Resize

        expect(reported).to eq({40, 10})
        expect(settled).to eq({40, 10})

        harness.terminal.sync do |buffer|
          expect(buffer.width).to eq 40
          expect(buffer.height).to eq 10
        end
      end
    end

    it "runs handlers in the order they were registered" do
      with_harness do |harness|
        order = [] of Int32

        harness.terminal.on_resize { order << 1 }
        harness.terminal.on_resize { order << 2 }
        harness.terminal.on_resize { order << 3 }

        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(40, 10))
        harness.event_of TermBuf::Events::Resize

        expect(order).to eq [1, 2, 3]
      end
    end

    it "reports a handler that raises and runs the rest anyway" do
      with_harness do |harness|
        reached = false

        harness.terminal.on_resize { raise "layout is wrong" }
        harness.terminal.on_resize { reached = true }

        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(40, 10))
        failure = harness.event_of TermBuf::Events::Failure

        expect(failure.try &.error.message).to eq "layout is wrong"
        expect(harness.event_of(TermBuf::Events::Resize)).not_to be_nil
        expect(reached).to be_true
      end
    end

    it "stops running a handler that was taken back" do
      with_harness do |harness|
        runs = 0
        handler = harness.terminal.on_resize { runs += 1 }

        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(40, 10))
        harness.event_of TermBuf::Events::Resize

        expect(harness.terminal.forget_resize(handler)).to be_true
        expect(harness.terminal.forget_resize(handler)).to be_false

        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(30, 8))
        harness.event_of TermBuf::Events::Resize

        expect(runs).to eq 1
      end
    end

    it "does not run handlers when the size did not change" do
      with_harness do |harness|
        runs = 0
        harness.terminal.on_resize { runs += 1 }

        harness.terminal.issue TermBuf::Commands::Resize.new(TermBuf::ScreenSize.new(20, 6))
        expect(harness.event_of(TermBuf::Events::Resize, 200.milliseconds)).to be_nil

        expect(runs).to eq 0
      end
    end
  end

  describe "input" do
    it "delivers a key per character typed" do
      with_harness do |harness|
        harness.type "abc"

        %w[a b c].each do |letter|
          event = harness.event_of TermBuf::Events::Key
          fail "no key arrived for #{letter}" unless event

          expect(event.key.char).to eq letter[0]
          expect(String.new(event.bytes)).to eq letter
        end
      end
    end

    it "delivers a registered reply as a response" do
      with_harness do |harness|
        harness.terminal.expect_response "\e[", "R"
        harness.type "\e[3;4R"
        response = harness.event_of TermBuf::Events::Response

        fail "no response arrived" unless response
        expect(String.new(response.bytes)).to eq "\e[3;4R"
      end
    end

    # An arrow key sends `ESC [ A`; so could a terminal. Nothing in the bytes
    # says which, so what settles it is whether the application asked for a
    # reply shaped like that. With nothing registered, it is a key.
    it "delivers an escape sequence nobody asked for as a keystroke" do
      with_harness do |harness|
        harness.type "\e[A"
        event = harness.event_of TermBuf::Events::Key

        fail "no key arrived" unless event
        expect(event.key.name).to eq TermBuf::Key::Name::Up
        expect(String.new(event.bytes)).to eq "\e[A"
      end
    end

    it "delivers a sequence that does not match what was registered as input" do
      with_harness do |harness|
        harness.terminal.expect_response "\e[?", "$y"
        harness.type "\e[A"
        event = harness.event_of TermBuf::Events::Key

        fail "no key arrived" unless event
        expect(event.key.name).to eq TermBuf::Key::Name::Up
      end
    end

    it "stops treating a reply as one once it is forgotten" do
      with_harness do |harness|
        pattern = harness.terminal.expect_response "\e[", "R"
        harness.terminal.forget_response pattern

        harness.type "\e[3;4R"
        event = harness.event_of TermBuf::Events::Key

        fail "no key arrived" unless event
        expect(String.new(event.bytes)).to eq "\e[3;4R"
      end
    end

    it "delivers keystrokes left over from probing before anything else" do
      with_harness(pending: "q".to_slice) do |harness|
        event = harness.event_of TermBuf::Events::Key

        fail "no key arrived" unless event
        expect(event.key.char).to eq 'q'
      end
    end

    # The escape key sends one byte, and so does the start of every arrow key.
    # Only time separates them, so a lone escape has to be handed over once
    # enough of it has passed that no more is coming.
    it "delivers the escape key on its own" do
      with_harness do |harness|
        harness.terminal.escape_timeout = 30.milliseconds
        harness.type "\e"
        event = harness.event_of TermBuf::Events::Key

        fail "the escape key never arrived" unless event
        expect(event.key.name).to eq TermBuf::Key::Name::Escape
      end
    end

    it "delivers two escape presses as two keys" do
      with_harness do |harness|
        harness.terminal.escape_timeout = 30.milliseconds
        harness.type "\e\e"

        first = harness.event_of TermBuf::Events::Key
        second = harness.event_of TermBuf::Events::Key

        fail "expected two keys" unless first && second
        expect(first.key.name).to eq TermBuf::Key::Name::Escape
        expect(second.key.name).to eq TermBuf::Key::Name::Escape
      end
    end

    it "still waits for the rest of a sequence that is on its way" do
      with_harness do |harness|
        harness.terminal.escape_timeout = 500.milliseconds
        harness.type "\e"
        sleep 20.milliseconds
        harness.type "[A"

        event = harness.event_of TermBuf::Events::Key
        fail "no key arrived" unless event
        expect(event.key.name).to eq TermBuf::Key::Name::Up
        expect(String.new(event.bytes)).to eq "\e[A"
      end
    end

    it "keeps an escape that begins an alt combination whole" do
      with_harness do |harness|
        harness.terminal.escape_timeout = 500.milliseconds
        harness.type "\ea"

        event = harness.event_of TermBuf::Events::Key
        fail "no key arrived" unless event
        expect(event.key).to eq TermBuf::Key.character('a', TermBuf::Modifiers::Alt)
        expect(String.new(event.bytes)).to eq "\ea"
      end
    end

    it "delivers pasted text as one event rather than as typing" do
      with_harness do |harness|
        harness.type "\e[200~hello\nthere\e[201~"

        paste = harness.event_of TermBuf::Events::Paste
        fail "no paste arrived" unless paste
        expect(paste.text).to eq "hello\nthere"
        expect(paste.complete).to be_true
      end
    end

    # An opening marker with no closing one used to take every keystroke after
    # it, and nothing anywhere would wake up to notice.
    it "gets out of a paste the terminal never closed" do
      with_harness do |harness|
        harness.terminal.paste_stall = 40.milliseconds
        harness.type "\e[200~half a clipboard"

        paste = harness.event_of TermBuf::Events::Paste
        fail "the paste never ended" unless paste
        expect(paste.text).to eq "half a clipboard"
        expect(paste.complete).to be_false

        harness.type "a"
        event = harness.event_of TermBuf::Events::Key
        fail "keys never came back" unless event
        expect(event.key.char).to eq 'a'
      end
    end

    it "says a long paste is arriving before it finishes" do
      with_harness do |harness|
        harness.terminal.paste_notice = 20.milliseconds
        harness.type "\e[200~slowly"

        notice = harness.event_of TermBuf::Events::Pasting
        fail "no notice arrived" unless notice
        expect(notice.bytes).to eq 6
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

  describe "measured widths" do
    # A terminal that answers is believed over the tables, since how many cells
    # an emoji takes is a question about the terminal.
    it "takes the terminal's answers over the tables" do
      answers = String.build do |io|
        TermBuf::WidthProbe::SAMPLES.each_with_index do |sample, index|
          measured = sample.rule == "spacing_marks" ? 1 : TermBuf::Unicode.string_width(sample.text)
          io << "\e[" << index + 1 << ';' << measured + 1 << 'R'
        end
      end

      with_probing_harness(answers) do |harness|
        expect(harness.terminal.widths.spacing_marks?).to be_false
        expect(harness.terminal.widths.joined_emoji?).to be_true
      end
    end

    it "keeps the tables when the terminal says nothing" do
      with_probing_harness("") do |harness|
        expect(harness.terminal.widths).to eq TermBuf::Unicode::WidthPolicy::DEFAULT
        expect(harness.terminal.width_readings.size).to eq TermBuf::WidthProbe::SAMPLES.size
      end
    end

    # Terminal.app advances eleven columns for a four-face emoji, which no rule
    # in the policy reaches. An application drawing one will see it misplaced,
    # and this is how it finds out why.
    it "warns about a measurement no rule explains" do
      answers = String.build do |io|
        TermBuf::WidthProbe::SAMPLES.each_with_index do |sample, index|
          measured = sample.rule == "joined_emoji" ? 11 : TermBuf::Unicode.string_width(sample.text)
          io << "\e[" << index + 1 << ';' << measured + 1 << 'R'
        end
      end

      with_probing_harness(answers) do |harness|
        warning = harness.event_of TermBuf::Events::Warning

        fail "no warning arrived" unless warning
        expect(warning.message).to contain "11 columns"
      end
    end

    it "lets TERMBUF_WIDTHS have the last word over what was measured" do
      with_probing_harness("", spec: "-joined_emoji") do |harness|
        expect(harness.terminal.widths.joined_emoji?).to be_false
      end
    end

    it "skips the measurement when told to" do
      with_probing_harness("", spec: "off") do |harness|
        expect(harness.terminal.width_readings).to be_empty
      end
    end

    it "reports a rule name it does not know" do
      with_probing_harness("", spec: "+nonsense") do |harness|
        warning = harness.event_of TermBuf::Events::Warning

        fail "no warning arrived" unless warning
        expect(warning.message).to contain "TERMBUF_WIDTHS"
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

Spectator.describe TermBuf::ResponseRegistry do
  subject(registry) { TermBuf::ResponseRegistry.new }

  it "starts empty, so every sequence is a keystroke" do
    expect(registry.empty?).to be_true
    expect(registry.matches?("\e[A")).to be_false
  end

  it "matches on both ends" do
    registry.register "\e[?", "$y"

    expect(registry.matches?("\e[?2026;2$y")).to be_true
    expect(registry.matches?("\e[?2026;2c")).to be_false
    expect(registry.matches?("\e[2026$y")).to be_false
  end

  # The two ends have to fit without overlapping, or `"\e["` would match a
  # pattern whose prefix and terminator are both `"\e["`.
  it "needs room for both ends" do
    registry.register "\e[", "R"
    expect(registry.matches?("\e[R")).to be_true
    expect(registry.matches?("\e[1;1R")).to be_true

    registry.clear
    registry.register "\e[", "\e["
    expect(registry.matches?("\e[")).to be_false
    expect(registry.matches?("\e[x\e[")).to be_true
  end

  it "registers a pattern once" do
    registry.register "\e[", "R"
    registry.register "\e[", "R"

    expect(registry.size).to eq 1
  end

  it "matches any of several patterns" do
    registry.register "\e[?", "$y"
    registry.register "\eP", "\e\\"

    expect(registry.matches?("\e[?2026;2$y")).to be_true
    expect(registry.matches?("\eP>|ghostty\e\\")).to be_true
    expect(registry.matches?("\e[A")).to be_false
  end

  it "forgets a pattern" do
    pattern = registry.register "\e[", "R"
    registry.unregister pattern

    expect(registry.matches?("\e[1;1R")).to be_false
    expect(registry.empty?).to be_true
  end

  it "refuses a pattern with an empty end" do
    expect { TermBuf::ResponsePattern.new("", "R") }.to raise_error(ArgumentError)
    expect { TermBuf::ResponsePattern.new("\e[", "") }.to raise_error(ArgumentError)
  end
end
