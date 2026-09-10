#!/usr/bin/env crystal
#
# Settles the four capabilities nothing in the specs can reach.
#
#     crystal build scripts/caps_check.cr -o /tmp/caps_check
#     /tmp/caps_check --out measurements/ghostty-1.3.2
#
# `Capability::FocusEvents`, `MouseSgr`, `Titles` and `CursorShape` are set
# from a table of terminal names and, for the first two, from a mode report.
# Neither is the same as having watched the thing happen: a terminal can know
# what mode 1004 is and never send a focus report, and there is no query at all
# for the window title. So this asks what can be asked and then asks the person
# at the keyboard about the rest — one command per terminal, seven readings,
# and a row of TSV for each answer.
#
# Three of those seven are not about a capability at all. They ask what the
# terminal reports under each of the three mouse tracking modes while nothing
# is held down, because 1000 and 1002 are defined to report nothing there and
# not every terminal obeys.
#
# It needs a real terminal at both ends and someone in front of it. Nothing
# here goes through `Terminal`: the modes are written straight to the device,
# because a driver that puts the terminal back the way it found it is the thing
# under test rather than the thing keeping the books.
#
# See `measurements/CAPS.md` for the procedure and which terminals to run it in.
require "option_parser"

require "../src/termbuf"

module CapsCheck
  extend self

  # Long enough for a terminal on the far end of a slow link, short enough not
  # to be noticed when nothing answers.
  PROBE_TIMEOUT = 250.milliseconds

  # How long a question waits for the person to do something. Alt-tabbing away
  # and back is slower than it sounds when a prompt has just been read.
  PATIENCE = 45.seconds

  # How long the pointer is watched under each tracking mode. This one is not
  # patience: it is the length of the window the reading is about, so it ends
  # whether or not anything arrived, and it is short because there are three
  # of them in a row.
  MOTION_WINDOW = 3.seconds

  # One reading: what was asked about, how it was asked, and what came back.
  record Row, capability : String, method : String, result : String

  # The capabilities this reports on, the probe query that would settle each,
  # and what to call that method in the output. A `nil` query is a capability
  # nothing can ask about, which is the whole reason this script exists.
  CHECKS = [
    {TermBuf::Capability::SynchronizedOutput, :synchronized_output, "decrqm"},
    {TermBuf::Capability::GraphemeClusters, :grapheme_clusters, "decrqm"},
    {TermBuf::Capability::BracketedPaste, :bracketed_paste, "decrqm"},
    {TermBuf::Capability::FocusEvents, :focus_events, "decrqm"},
    {TermBuf::Capability::MouseSgr, :mouse_sgr, "decrqm"},
    {TermBuf::Capability::CursorShape, :decrqss_cursor_style, "decrqss"},
    {TermBuf::Capability::Titles, nil, "table"},
  ]

  # A focus report, each way round.
  FOCUS_IN  = /\e\[I/
  FOCUS_OUT = /\e\[O/

  # How long the enable of a mode is given to answer on its own before the
  # reading proper starts.
  ENABLE_GRACE = 300.milliseconds

  # An SGR mouse report: `CSI < button ; column ; row` and a final M or m.
  MOUSE_REPORT = /\e\[<\d+;\d+;\d+[Mm]/

  # A press: an SGR report ending in `M` whose button field has no motion bit.
  MOUSE_PRESS = /\e\[<(\d+);\d+;\d+M/

  # How many reports a pointer moving for the window must produce before the
  # terminal is credited with reporting motion. One report is what a terminal
  # sends on its own when the mode is turned on; a moving pointer sends dozens.
  MOTION_REPORTS = 3

  # The three mouse tracking modes, and what to call the row each one leaves
  # behind. 1000 reports the press and the release, 1002 adds motion while a
  # button is held, 1003 reports every movement; the reading is what arrives
  # under each while nothing at all is held down.
  TRACKING = [
    {"1000", TermBuf::Tty::MOUSE_SGR_CLICKS},
    {"1002", TermBuf::Tty::MOUSE_SGR},
    {"1003", TermBuf::Tty::MOUSE_SGR_ANY},
  ]

  # What the title is set to while the question is on screen. Distinctive
  # enough that a person can say whether it is the one they are looking at.
  TITLE = "termbuf caps check"

  class Runner
    getter rows = [] of Row
    getter environment = {} of String => String

    def initialize(@tty : TermBuf::Tty, @interactive : Bool)
    end

    # Everything that can be asked of the terminal without asking the person.
    def query : Nil
      detected = TermBuf::EnvironmentDetector.detect ENV.to_h
      probe = TermBuf::Prober.new(@tty.input, @tty.output, PROBE_TIMEOUT).probe detected
      settled = TermBuf::CapabilityOverrides.apply(probe.capabilities, ENV.to_h).capabilities

      # A terminal that cannot parse a query prints it, and this is the screen
      # the person was looking at.
      @tty.scrub_line

      record_environment probe

      CHECKS.each do |(capability, query, method)|
        answered = query && probe.answered.includes? query
        told = probe.capabilities.includes? capability
        final = settled.includes? capability

        source = if told != final
                   "override"
                 elsif answered
                   method
                 else
                   "table"
                 end

        @rows << Row.new capability.to_s.underscore, source, final ? "yes" : "no"
      end
    end

    private def record_environment(probe : TermBuf::Prober::Result) : Nil
      size = @tty.size

      @environment["date"] = Time.local.to_s "%Y-%m-%d %H:%M:%S"
      @environment["term"] = ENV.fetch "TERM", ""
      @environment["term_program"] = ENV.fetch "TERM_PROGRAM", ""
      @environment["term_program_version"] = ENV.fetch "TERM_PROGRAM_VERSION", ""
      @environment["xtversion"] = probe.name || ""
      @environment["termbuf_caps"] = ENV.fetch "TERMBUF_CAPS", ""
      @environment["columns"] = size.columns.to_s
      @environment["rows"] = size.rows.to_s
      @environment["answered"] = probe.answered.join ','

      # A multiplexer decides the answer to most of these, so which one is in
      # the way matters as much as which terminal is behind it.
      if socket = ENV["TMUX"]?
        @environment["multiplexer"] = "tmux"
        @environment["multiplexer_socket"] = socket.split(',').first
      elsif session = ENV["STY"]?
        @environment["multiplexer"] = "screen"
        @environment["multiplexer_session"] = session
      end

      if layer = ENV["TERMBUF_LAYER"]?
        @environment["multiplexer"] = layer
      end
    end

    # The readings no query settles, in the order that leaves the terminal
    # least disturbed if somebody walks away half way through.
    def checklist : Nil
      unless @interactive
        %w[focus_report_on_enable focus_events mouse_report_on_enable mouse_sgr
          mouse_report_on_enable_1000 mouse_motion_1000 mouse_report_on_enable_1002 mouse_motion_1002
          mouse_report_on_enable_1003 mouse_motion_1003 titles cursor_shape].each do |name|
          @rows << Row.new name, "observed", "skipped"
        end

        return
      end

      say "Seven readings. The last two take y or n; q skips one."
      say ""

      check_focus
      check_mouse
      TRACKING.each_with_index do |(mode_number, mode), index|
        check_motion index + 3, mode_number, mode
      end
      check_title
      check_cursor_shape
    end

    # A terminal that reports focus sends `CSI I` when the window comes
    # forward and `CSI O` when it goes away, and nothing at all when it does
    # not have the feature. Watching for one is the only way to tell.
    # Many terminals answer the enable itself with `CSI I` when the window
    # already has focus. That report says the terminal knows the mode; it does
    # not say a switch will be reported. So the enable's own answer is recorded
    # on its own row and then drained, and the reading proper wants a focus
    # out followed by a focus in, which only a switch away and back produces.
    private def check_focus : Nil
      say "1. Focus reporting. Click another window, then click this one back."
      @tty.write TermBuf::Tty::FOCUS_EVENTS.set
      @tty.flush

      on_enable = wait_for FOCUS_IN, ENABLE_GRACE
      drain
      say "   the enable itself was answered with #{on_enable.inspect}" if on_enable

      out = wait_for FOCUS_OUT
      back = out ? wait_for(FOCUS_IN) : nil
      @tty.write TermBuf::Tty::FOCUS_EVENTS.reset
      @tty.flush

      seen = out && back
      say seen ? "   saw #{out.inspect} then #{back.inspect}" : "   no focus out and in arrived"
      say ""
      @rows << Row.new "focus_report_on_enable", "observed", on_enable ? "yes" : "no"
      @rows << Row.new "focus_events", "observed", seen ? "yes" : "no"
    end

    # As with focus, a terminal may answer the enable with a report of its own
    # (ghostty sends the pointer's position as a motion report). That is
    # recorded on its own row and drained, and the reading proper wants a
    # press: a report with the motion bit clear.
    private def check_mouse : Nil
      say "2. Mouse reporting. Click once anywhere in this window."
      @tty.write TermBuf::Tty::MOUSE_SGR.set
      @tty.flush

      on_enable = wait_for MOUSE_REPORT, ENABLE_GRACE
      drain
      say "   the enable itself was answered with #{on_enable.inspect}" if on_enable

      seen = wait_for_press
      @tty.write TermBuf::Tty::MOUSE_SGR.reset
      @tty.flush

      say seen ? "   saw #{seen.inspect}" : "   no press arrived"
      say ""
      @rows << Row.new "mouse_report_on_enable", "observed", on_enable ? "yes" : "no"
      @rows << Row.new "mouse_sgr", "observed", seen ? "yes" : "no"
    end

    # Waits for a report that is a press rather than motion: the button field
    # with bit 32 clear.
    private def wait_for_press : String?
      deadline = Time.instant + PATIENCE
      while Time.instant < deadline
        seen = wait_for MOUSE_PRESS, deadline - Time.instant
        return unless seen
        button = seen.match(MOUSE_PRESS).try(&.[1].to_i) || 0
        return seen if button & 32 == 0
      end
    end

    # What arrives under one tracking mode while nothing is held down.
    #
    # Under 1000 and 1002 the answer should be nothing: 1000 is defined to
    # report the press and the release, 1002 to add motion while a button is
    # held. A terminal that reports motion under either is over-reporting, and
    # a consumer that reads a motion report as evidence a button is down is
    # wrong on that terminal. Under 1003 a report is the mode working, and
    # silence says this terminal has no any-event tracking.
    #
    # The window is fixed rather than patient: what is being measured is what
    # three seconds of pointer movement produces, so nothing arriving is a
    # reading and not a timeout.
    private def check_motion(step : Int32, mode_number : String, mode : TermBuf::Tty::Mode) : Nil
      say "#{step}. Motion under mode #{mode_number}. Move the pointer across the window for " \
          "#{MOTION_WINDOW.total_seconds.to_i} seconds without pressing anything."

      # The release that followed the click a step ago is still in the buffer,
      # and reading it here would be this window's answer.
      drain

      @tty.write mode.set
      @tty.flush

      # The enable's own answer, if any, is not motion.
      on_enable = wait_for MOUSE_REPORT, ENABLE_GRACE
      drain
      say "   the enable itself was answered with #{on_enable.inspect}" if on_enable

      reports = collect MOUSE_REPORT, MOTION_WINDOW
      @tty.write mode.reset
      @tty.flush

      seen = reports.size >= MOTION_REPORTS
      say reports.empty? ? "   nothing arrived" : "   #{reports.size} reports, the first #{reports.first.inspect}"
      say ""
      @rows << Row.new "mouse_report_on_enable_#{mode_number}", "observed", on_enable ? "yes" : "no"
      @rows << Row.new "mouse_motion_#{mode_number}", "observed", seen ? "yes" : "no"
    end

    # Every match of *pattern* that arrives within *span*, without stopping at
    # the first.
    private def collect(pattern : Regex, span : Time::Span) : Array(String)
      input = @tty.input
      found = [] of String
      return found unless input.responds_to? :read_timeout=

      deadline = Time.instant + span
      seen = IO::Memory.new
      buffer = Bytes.new 256

      while Time.instant < deadline
        input.read_timeout = deadline - Time.instant
        count = begin
          input.read buffer
        rescue IO::TimeoutError
          break
        end
        break if count.zero?
        seen.write buffer[0, count]
      end

      seen.to_s.scan(pattern) { |match| found << match[0] }
      found
    end

    # OSC 2 answers nothing, so the only instrument for it is a person looking
    # at the window's title bar. The title is pushed onto the terminal's own
    # stack first and popped afterwards, which is what the driver does and is
    # itself worth watching: a terminal without the stack leaves the title
    # changed, and that shows up as the last question here.
    private def check_title : Nil
      @tty.write TermBuf::Terminal::TITLE_STACK.set
      @tty.write "\e]2;#{TITLE}\e\\"
      @tty.flush

      answer = ask "6. Does the window or tab now say #{TITLE.inspect}?"

      @tty.write TermBuf::Terminal::TITLE_STACK.reset
      @tty.flush

      @rows << Row.new "titles", "asked", answer
      say ""
    end

    private def check_cursor_shape : Nil
      @tty.write "\e[#{TermBuf::CursorShape::Bar.code} q"
      @tty.flush

      answer = ask "7. Is the cursor now a blinking bar rather than a block?"

      @tty.write TermBuf::Terminal::CURSOR_SHAPE_RESET
      @tty.flush

      @rows << Row.new "cursor_shape", "asked", answer
      say ""
    end

    # Reads until something matching *pattern* arrives or *patience* runs out,
    # and answers with what matched. Everything else read on the way is
    # discarded: it is the person typing while they wait.
    private def wait_for(pattern : Regex, patience : Time::Span = PATIENCE) : String?
      input = @tty.input
      return unless input.responds_to? :read_timeout=

      deadline = Time.instant + patience
      seen = IO::Memory.new
      buffer = Bytes.new 256

      while Time.instant < deadline
        input.read_timeout = deadline - Time.instant

        count = begin
          input.read buffer
        rescue IO::TimeoutError
          break
        end
        break if count.zero?

        seen.write buffer[0, count]
        text = seen.to_s

        if match = text.match pattern
          return match[0]
        end

        # A way out for a terminal that will never answer, and for a person
        # who has decided it will not.
        break if text.includes?('q') || text.includes?('\u{3}')
      end

      nil
    end

    # Throws away whatever is already in the buffer, so that the next window
    # measures what arrives during it rather than what was left over from the
    # step before.
    private def drain : Nil
      input = @tty.input
      return unless input.responds_to? :read_timeout=

      buffer = Bytes.new 256

      loop do
        input.read_timeout = 20.milliseconds

        count = begin
          input.read buffer
        rescue IO::TimeoutError
          break
        end

        break if count.zero?
      end
    end

    # Puts *question* on the screen and waits for one letter.
    private def ask(question : String) : String
      @tty.write "#{question} [y/n] "
      @tty.flush

      answer = case key
               when 'y', 'Y' then "yes"
               when 'n', 'N' then "no"
               else               "skipped"
               end

      say answer
      answer
    end

    # One keystroke, or nothing if the patience runs out.
    private def key : Char?
      input = @tty.input
      return unless input.responds_to? :read_timeout=

      input.read_timeout = PATIENCE
      buffer = Bytes.new 1

      begin
        return if input.read(buffer).zero?
      rescue IO::TimeoutError
        return
      end

      buffer[0].unsafe_chr
    end

    # The terminal is in raw mode, so a line feed on its own drops a row
    # without returning the carriage.
    private def say(line : String) : Nil
      @tty.write "#{line}\r\n"
      @tty.flush
    end
  end

  # The readings as TSV: the environment as comments, then a row per
  # capability. Comments rather than a second file, because one command per
  # terminal should leave one artefact behind.
  def render(runner : Runner) : String
    String.build do |io|
      runner.environment.each { |key, value| io << "# " << key << '\t' << value << '\n' }
      io << "capability\tmethod\tresult\n"

      runner.rows.each do |row|
        io << row.capability << '\t' << row.method << '\t' << row.result << '\n'
      end
    end
  end

  def run(directory : String?, interactive : Bool) : Nil
    unless STDIN.tty? && STDOUT.tty?
      abort "caps_check needs a terminal at both ends: run it in one, not through a pipe"
    end

    tty = TermBuf::Tty.standard
    runner = Runner.new tty, interactive

    begin
      # Raw before anything is asked. A cooked terminal echoes the replies onto
      # the screen and holds them until a newline that never comes.
      tty.raw!
      runner.query
      runner.checklist
    ensure
      tty.restore_modes
    end

    report = render runner
    print report

    return unless directory

    Dir.mkdir_p directory
    path = File.join directory, "caps.tsv"
    File.write path, report
    puts "written to #{path}"
  end
end

directory = nil.as(String?)
interactive = true

OptionParser.parse do |parser|
  parser.banner = "usage: caps_check [--out DIRECTORY] [--queries-only]"

  parser.on "--out DIRECTORY", "also write caps.tsv there, usually measurements/<name>" do |value|
    directory = value
  end

  parser.on "--queries-only", "ask the terminal but not the person" do
    interactive = false
  end

  parser.on "-h", "--help", "this message" do
    puts parser
    exit
  end

  parser.invalid_option do |flag|
    STDERR.puts "unknown option #{flag}"
    STDERR.puts parser
    exit 1
  end
end

CapsCheck.run directory, interactive
