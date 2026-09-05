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
# at the keyboard about the rest — one command per terminal, four questions,
# and a row of TSV for each answer.
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

  # A focus report, either way round.
  FOCUS_REPORT = /\e\[[IO]/

  # An SGR mouse report: `CSI < button ; column ; row` and a final M or m.
  MOUSE_REPORT = /\e\[<\d+;\d+;\d+[Mm]/

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

    # The four questions no query settles, in the order that leaves the
    # terminal least disturbed if somebody walks away half way through.
    def checklist : Nil
      unless @interactive
        %w[focus_events mouse_sgr titles cursor_shape].each do |name|
          @rows << Row.new name, "observed", "skipped"
        end

        return
      end

      say "The four questions. Answer y or n; q skips one."
      say ""

      check_focus
      check_mouse
      check_title
      check_cursor_shape
    end

    # A terminal that reports focus sends `CSI I` when the window comes
    # forward and `CSI O` when it goes away, and nothing at all when it does
    # not have the feature. Watching for one is the only way to tell.
    private def check_focus : Nil
      say "1. Focus reporting. Click another window, then click this one back."
      @tty.write TermBuf::Tty::FOCUS_EVENTS.set
      @tty.flush

      seen = wait_for FOCUS_REPORT
      @tty.write TermBuf::Tty::FOCUS_EVENTS.reset
      @tty.flush

      say seen ? "   saw #{seen.inspect}" : "   nothing arrived"
      say ""
      @rows << Row.new "focus_events", "observed", seen ? "yes" : "no"
    end

    private def check_mouse : Nil
      say "2. Mouse reporting. Click once anywhere in this window."
      @tty.write TermBuf::Tty::MOUSE_SGR.set
      @tty.flush

      seen = wait_for MOUSE_REPORT
      @tty.write TermBuf::Tty::MOUSE_SGR.reset
      @tty.flush

      say seen ? "   saw #{seen.inspect}" : "   nothing arrived"
      say ""
      @rows << Row.new "mouse_sgr", "observed", seen ? "yes" : "no"
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

      answer = ask "3. Does the window or tab now say #{TITLE.inspect}?"

      @tty.write TermBuf::Terminal::TITLE_STACK.reset
      @tty.flush

      @rows << Row.new "titles", "asked", answer
      say ""
    end

    private def check_cursor_shape : Nil
      @tty.write "\e[#{TermBuf::CursorShape::Bar.code} q"
      @tty.flush

      answer = ask "4. Is the cursor now a blinking bar rather than a block?"

      @tty.write TermBuf::Terminal::CURSOR_SHAPE_RESET
      @tty.flush

      @rows << Row.new "cursor_shape", "asked", answer
      say ""
    end

    # Reads until something matching *pattern* arrives or the patience runs
    # out, and answers with what matched. Everything else read on the way is
    # discarded: it is the person typing while they wait.
    private def wait_for(pattern : Regex) : String?
      input = @tty.input
      return unless input.responds_to? :read_timeout=

      deadline = Time.instant + PATIENCE
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
