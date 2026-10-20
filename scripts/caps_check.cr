#!/usr/bin/env crystal
#
# Settles the four capabilities nothing in the specs can reach.
#
#     crystal build scripts/caps_check.cr -o /tmp/caps_check
#     /tmp/caps_check --out measurements/ghostty-1.3.2
#     /tmp/caps_check --out measurements/ghostty-1.3.2 --only origin,pixels
#
# `--only` names the readings to take. With `--out` naming a directory that
# already holds a `caps.tsv`, the rows those readings produce replace their
# counterparts in it and every other row is kept, so one step can be run again
# without the other eight.
#
# `Capability::FocusEvents`, `MouseSgr`, `Titles` and `CursorShape` are set
# from a table of terminal names and, for the first two, from a mode report.
# Neither is the same as having watched the thing happen: a terminal can know
# what mode 1004 is and never send a focus report, and there is no query at all
# for the window title. So this asks what can be asked and then asks the person
# at the keyboard about the rest — one command per terminal, nine readings,
# and a row of TSV for each answer.
#
# Three of those are not about a capability at all. They ask what the
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
  # whether or not anything arrived. It starts when the person presses Space,
  # and includes the moment it takes to move a hand from the keyboard to the
  # mouse.
  MOTION_WINDOW = 5.seconds

  # One reading: what was asked about, how it was asked, and what came back.
  record Row, capability : String, method : String, result : String do
    # What a later run of the same reading replaces. A query row is named by
    # its capability alone, since the method it carries is part of the answer
    # (`decrqm` one day, `override` the next); a reading is named by both.
    def key : String
      method.in?("observed", "asked") ? "#{capability}/#{method}" : capability
    end
  end

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

  # An X10 mouse report: `CSI M` and three raw bytes. Nothing here asks for
  # this encoding. One arriving means mouse tracking is on that this script
  # did not turn on, which a Windows console does when it wants the mouse for
  # itself, and a motion reading taken then is not about the mode it names.
  X10_REPORT = /\e\[M.../

  # A release: an SGR report ending in `m`. The button field names which
  # button came up, and the click step waits for one before it ends.
  MOUSE_RELEASE = /\e\[<\d+;\d+;\d+m/

  # How many reports a pointer moving for the window must produce before the
  # terminal is credited with reporting motion. One report is what a terminal
  # sends on its own when the mode is turned on; a moving pointer sends dozens.
  MOTION_REPORTS = 3

  # A DECRQM reply for mode 1016. The digit is the state: 1 set, 2 reset,
  # 3 permanently set, 4 permanently reset, 0 not recognised.
  PIXEL_MODE_REPORT = /\e\[\?1016;(\d)\$y/

  # The two coordinates of an SGR mouse report, as the terminal wrote them.
  MOUSE_COORDS = /\e\[<\d+;(\d+);(\d+)[Mm]/

  # The reply to `CSI 14 t`: the text area's height, then its width, in the
  # terminal's own pixels.
  TEXT_AREA_REPORT = /\e\[4;(\d+);(\d+)t/

  # The readings a person can be asked for, by the name `--only` takes, with
  # the rows each one leaves behind and the method those rows carry. The
  # order is the order they run in, which leaves the terminal least disturbed
  # if somebody walks away half way through.
  STEPS = [
    {"focus", "observed", ["focus_report_on_enable", "focus_events"]},
    {"mouse", "observed", ["mouse_report_on_enable", "mouse_sgr"]},
    {"motion-1000", "observed", ["mouse_report_on_enable_1000", "mouse_motion_1000"]},
    {"motion-1002", "observed", ["mouse_report_on_enable_1002", "mouse_motion_1002"]},
    {"motion-1003", "observed", ["mouse_report_on_enable_1003", "mouse_motion_1003"]},
    {"pixels", "observed", ["mouse_pixels_report"]},
    {"origin", "observed", ["mouse_pixel_origin", "mouse_pixel_extent"]},
    {"title", "asked", ["titles"]},
    {"cursor", "asked", ["cursor_shape"]},
  ]

  # Names `--only` also takes, each standing for several steps.
  STEP_GROUPS = {
    "all"    => STEPS.map(&.[0]),
    "motion" => %w[motion-1000 motion-1002 motion-1003],
  }

  # The rows the query phase writes, in order, before any reading.
  QUERY_ROWS = %w[mouse_pixels synchronized_output grapheme_clusters bracketed_paste
    focus_events mouse_sgr cursor_shape titles]

  # Every row key a full run writes, in the order it writes them. A merged
  # file is put back in this order whatever order its rows were read in.
  ORDER = QUERY_ROWS + STEPS.flat_map { |(_, method, names)| names.map { |name| "#{name}/#{method}" } }

  # What the title is set to while the question is on screen. Distinctive
  # enough that a person can say whether it is the one they are looking at.
  TITLE = "termbuf caps check"

  class Runner
    getter rows = [] of Row
    getter environment = {} of String => String

    # The number the reading on screen is given, counted as they run.
    @step = 0

    def initialize(@tty : TermBuf::Tty, @steps : Array(String))
      # Every wait here has a deadline. A Windows console ignores
      # `IO#read_timeout`, and this reads through the console there.
      @reader = TermBuf::TimedRead.new @tty.input

      # What the person typed, decoded. The terminal's own reports arrive on
      # the same input, and their bytes are not keys: an X10 mouse report
      # carries its column as a raw byte, and column 81 is a `q`. Every
      # decision about a key is made on what this decodes, never on bytes.
      @decoder = TermBuf::Input::Decoder.new
      @keys = Deque(TermBuf::Input::Key).new
    end

    # Decodes *bytes*, keeping the keys in them.
    private def decode_keys(bytes : Bytes) : Nil
      @decoder.feed(bytes) do |event|
        @keys << event.key if event.is_a?(TermBuf::Input::Events::Key)
      end
    end

    # Whether a key that means "skip this" was typed: q, or Ctrl+C. Forgets
    # every key it looked at.
    private def skip_typed? : Bool
      skip = @keys.any? { |key| key.is?('q') || key.is?('Q') || (key.ctrl? && key.char == 'c') }
      @keys.clear
      skip
    end

    # Everything that can be asked of the terminal without asking the person.
    def query : Nil
      detected = TermBuf::EnvironmentDetector.detect ENV.to_h
      probe = TermBuf::Prober.new(@tty.input, @tty.output, PROBE_TIMEOUT)
        .probe detected, TermBuf::EnvironmentDetector.distrusted(ENV.to_h),
          TermBuf::EnvironmentDetector.distrusted_refusals(ENV.to_h)
      settled = TermBuf::CapabilityOverrides.apply(probe.capabilities, ENV.to_h).capabilities

      # A terminal that cannot parse a query prints it, and this is the screen
      # the person was looking at.
      @tty.scrub_line

      record_environment probe
      query_pixels
      query_text_area

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

    # Mode 1016 has no capability to settle yet, so it is asked for here
    # directly. A terminal that does not answer leaves `unanswered`, which is
    # not the same reading as `no`.
    private def query_pixels : Nil
      @tty.write TermBuf::Input::Query.mode(1016).request
      @tty.flush

      reply = wait_for PIXEL_MODE_REPORT, PROBE_TIMEOUT
      @tty.scrub_line

      result = if reply && (state = reply.match(PIXEL_MODE_REPORT).try(&.[1].to_i))
                 state.in?(1, 2, 3) ? "yes" : "no"
               else
                 "unanswered"
               end

      @rows << Row.new "mouse_pixels", "decrqm", result
    end

    # The text area in pixels, from `CSI 14 t`, which is what the far edge of
    # a drag under 1016 is read against. Left empty when nothing comes back.
    private def query_text_area : Nil
      @tty.write TermBuf::Input::Query::TEXT_AREA_PIXELS.request
      @tty.flush

      reply = wait_for TEXT_AREA_REPORT, PROBE_TIMEOUT
      @tty.scrub_line

      size = reply.try(&.match(TEXT_AREA_REPORT)).try { |match| "#{match[2]},#{match[1]}" }
      @environment["text_area_pixels"] = size || ""
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

    # The readings no query settles, those named in `@steps`, in the order
    # `STEPS` gives them.
    def checklist : Nil
      return if @steps.empty?

      say "#{@steps.size} #{@steps.size == 1 ? "reading" : "readings"}. Focus and the click wait " \
          "for the terminal, up to #{PATIENCE.total_seconds.to_i} s each; the motion and pixel " \
          "readings start when you press Space; the title and the cursor take y or n. q skips any one."
      say ""

      readings = {
        "focus"       => ->check_focus,
        "mouse"       => ->check_mouse,
        "motion-1000" => -> { check_motion "1000", TermBuf::Tty::MOUSE_SGR_CLICKS },
        "motion-1002" => -> { check_motion "1002", TermBuf::Tty::MOUSE_SGR },
        "motion-1003" => -> { check_motion "1003", TermBuf::Tty::MOUSE_SGR_ANY },
        "pixels"      => ->check_pixel_report,
        "origin"      => ->check_pixel_origin,
        "title"       => ->check_title,
        "cursor"      => ->check_cursor_shape,
      }

      STEPS.each do |(name, _, _)|
        readings[name].call if @steps.includes? name
      end
    end

    # The number for the next reading's heading.
    private def next_step : Int32
      @step += 1
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
      say "#{next_step}. Focus reporting. Click another window, then click this one back. " \
          "(up to #{PATIENCE.total_seconds.to_i} s; q skips)"
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
    #
    # The release is waited for too, and the step is not over until it comes.
    # A person holds a button down for far longer than the next step's drain,
    # so a release left behind here arrives during the step that follows and
    # is read there as that mode's answer to its own enable.
    private def check_mouse : Nil
      say "#{next_step}. Mouse reporting. Click once anywhere in this window. " \
          "(up to #{PATIENCE.total_seconds.to_i} s; q skips)"
      @tty.write TermBuf::Tty::MOUSE_SGR.set
      @tty.flush

      on_enable = wait_for MOUSE_REPORT, ENABLE_GRACE
      drain
      say "   the enable itself was answered with #{on_enable.inspect}" if on_enable

      seen = wait_for_press
      released = seen ? wait_for(MOUSE_RELEASE) : nil
      @tty.write TermBuf::Tty::MOUSE_SGR.reset
      @tty.flush

      say seen ? "   saw #{seen.inspect}" : "   no press arrived"
      say "   and the release #{released.inspect}" if released
      say "   no release arrived; the next reading may see it" if seen && !released
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

    # Waits for Space after showing *prompt*. Answers `false` for q, Ctrl+C,
    # or no answer within `PATIENCE`. Anything else, a stray mouse report
    # included, is ignored.
    private def ready(prompt : String) : Bool
      say prompt

      loop do
        case key
        when ' '                    then return true
        when 'q', 'Q', '\u{3}', nil then return false
        end
      end
    end

    private def skip_motion(mode_number : String) : Nil
      say "   skipped"
      say ""
      @rows << Row.new "mouse_report_on_enable_#{mode_number}", "observed", "skipped"
      @rows << Row.new "mouse_motion_#{mode_number}", "observed", "skipped"
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
    # five seconds of pointer movement produces, so nothing arriving is a
    # reading and not a timeout.
    #
    # The mode is turned on while the pointer is held still, and the movement
    # is asked for only after the enable's grace has run out. Turning a mode
    # on under a pointer that is already moving makes the movement's first
    # report the enable's answer, which is how every terminal came to look as
    # though it answered mode 1003.
    #
    # Nothing is timed until the person says they are ready, by pressing
    # Space: reading an instruction takes as long as it takes.
    private def check_motion(mode_number : String, mode : TermBuf::Tty::Mode) : Nil
      say "#{next_step}. Motion under mode #{mode_number}."
      unless ready "   Take your hand off the mouse, then press Space. (q skips this step.)"
        skip_motion mode_number
        return
      end

      # Whatever the pointer sent on its way to rest is thrown away before the
      # mode goes on, or the enable's grace would measure the last of the
      # movement instead of the enable.
      drain

      @tty.write mode.set
      @tty.flush

      # The enable's own answer, if any, is not motion: nothing is moving yet.
      on_enable = wait_for MOUSE_REPORT, ENABLE_GRACE
      drain
      say "   the enable itself was answered with #{on_enable.inspect}" if on_enable

      unless ready "   Press Space, then move the pointer across the window for " \
                   "#{MOTION_WINDOW.total_seconds.to_i} seconds without pressing a button."
        @tty.write mode.reset
        @tty.flush
        skip_motion mode_number
        return
      end

      reports, x10 = collect MOUSE_REPORT, X10_REPORT, MOTION_WINDOW
      @tty.write mode.reset
      @tty.flush

      seen = reports.size >= MOTION_REPORTS
      say reports.empty? ? "   nothing arrived" : "   #{reports.size} reports, the first #{reports.first.inspect}"
      say "   and #{x10.size} in the X10 encoding, which nothing here asked for" unless x10.empty?
      say ""
      @rows << Row.new "mouse_report_on_enable_#{mode_number}", "observed", on_enable ? "yes" : "no"
      @rows << Row.new "mouse_motion_#{mode_number}", "observed", seen ? "yes" : "no"
    end

    # Every match of *pattern*, and of *other*, that arrives within *span*,
    # without stopping at the first.
    private def collect(pattern : Regex, other : Regex, span : Time::Span) : {Array(String), Array(String)}
      deadline = Time.instant + span
      seen = IO::Memory.new
      buffer = Bytes.new 256

      while count = @reader.read(buffer, deadline)
        seen.write buffer[0, count]
      end

      # Scrubbed, because an X10 report past column or row 95 carries bytes
      # that are not UTF-8, and a regular expression raises on those.
      text = seen.to_s.scrub
      {text.scan(pattern).map(&.[0]), text.scan(other).map(&.[0])}
    end

    # Every match of *pattern* that arrives before *stop* matches or *patience*
    # runs out. The drags end at the release, which is *stop*.
    private def collect_until(pattern : Regex, stop : Regex, patience : Time::Span) : Array(String)
      deadline = Time.instant + patience
      seen = IO::Memory.new
      buffer = Bytes.new 256

      while count = @reader.read(buffer, deadline)
        seen.write buffer[0, count]
        break if seen.to_s.scrub.matches? stop
      end

      seen.to_s.scrub.scan(pattern).map(&.[0])
    end

    # The cell size to divide pixel reports by, from the tty's own answer.
    private def pixel_cell : TermBuf::Input::Events::CellPixels?
      return unless size = @tty.cell_size

      TermBuf::Input::Events::CellPixels.new size[0], size[1]
    end

    # Whether a press arrives under 1016 as a pixel report.
    #
    # A terminal that ignores 1016 sends cells, or the X10 encoding, and the
    # bytes of a cell report look like those of a pixel report. The click is
    # asked for away from the top-left so that a coordinate past the window's
    # columns or rows says it was pixels. A press inside that range reads as
    # `cells`. The reading needs the cell size to decode against; without one
    # the row is `no_cell_size`.
    private def check_pixel_report : Nil
      say "#{next_step}. Pixel mouse reports (mode 1016)."

      unless cell = pixel_cell
        say "   the tty gives no cell size"
        say ""
        @rows << Row.new "mouse_pixels_report", "observed", "no_cell_size"
        return
      end

      mode = TermBuf::Input::Mode::MOUSE_SGR_PIXELS

      unless ready "   Take your hand off the mouse, then press Space. (q skips this step.)"
        say "   skipped"
        say ""
        @rows << Row.new "mouse_pixels_report", "observed", "skipped"
        return
      end

      drain
      @tty.write mode.set
      @tty.flush
      wait_for MOUSE_REPORT, ENABLE_GRACE
      drain

      say "   Click once near the bottom-right of this window. " \
          "(up to #{PATIENCE.total_seconds.to_i} s)"
      seen = wait_for_press
      released = seen ? wait_for(MOUSE_RELEASE) : nil
      @tty.write mode.reset
      @tty.flush

      result = seen ? pixel_result(seen, cell) : "no"

      say seen ? "   saw #{seen.inspect}" : "   no press arrived"
      say "   no release arrived; the next reading may see it" if seen && !released
      say "   the coordinates fit a cell report" if result == "cells"
      say ""
      @rows << Row.new "mouse_pixels_report", "observed", result
    end

    # `yes` for a press that decodes with a pixel and lies past the window's
    # cells, `cells` for one that decodes but fits a cell report, `no` for
    # one that does not decode at all.
    private def pixel_result(seen : String, cell : TermBuf::Input::Events::CellPixels) : String
      size = @tty.size
      event = TermBuf::Input::Mouse.decode TermBuf::Input::Sequence.parse(seen.to_slice), cell
      coords = seen.match(MOUSE_COORDS).try { |match| {match[1].to_i, match[2].to_i} }
      beyond = coords && (coords[0] > size.columns || coords[1] > size.rows)

      return "yes" if event.try(&.pixel) && beyond
      event ? "cells" : "no"
    end

    # Which numbers the terminal gives the edges of its text area under 1016,
    # read from two drags out of the window rather than from aiming at a
    # corner, which round four found nobody can do.
    #
    # With a button held, a terminal keeps reporting after the pointer leaves
    # it and clamps the coordinates to its edge. So the smallest x,y of a drag
    # out past the top-left corner is the origin itself, `0,0` or `1,1`, and
    # the largest of a drag out past the bottom-right is the far edge, to be
    # read against `text_area_pixels` in the header: the size itself for a
    # terminal numbering from one, one less for one numbering from zero. A
    # terminal that stops reporting at the edge, or does not clamp, shows that
    # in the numbers. Both are raw, before anything is subtracted.
    private def check_pixel_origin : Nil
      say "#{next_step}. Pixel origin (mode 1016), from two drags out of the window."
      area = @environment["text_area_pixels"]?
      say "   the text area is #{area.presence || "unknown"} pixels by CSI 14 t"

      points = drag_out "top-left"
      unless points
        say "   skipped"
        say ""
        @rows << Row.new "mouse_pixel_origin", "observed", "skipped"
        @rows << Row.new "mouse_pixel_extent", "observed", "skipped"
        return
      end

      origin = extreme(points, &.min)
      say "   #{points.size} reports, smallest x,y #{origin}"
      @rows << Row.new "mouse_pixel_origin", "observed", origin

      points = drag_out "bottom-right"
      extent = points ? extreme(points, &.max) : "skipped"
      say points ? "   #{points.size} reports, largest x,y #{extent}" : "   skipped"
      say ""
      @rows << Row.new "mouse_pixel_extent", "observed", extent
    end

    # One drag under 1002 with 1016: every report's coordinates from the press
    # to the release, or `nil` when the person skips.
    private def drag_out(corner : String) : Array({Int32, Int32})?
      mode = TermBuf::Input::Mode::MOUSE_SGR_PIXELS

      return unless ready "   Take your hand off the mouse, then press Space. (q skips this step.)"
      drain

      @tty.write mode.set
      @tty.flush
      wait_for MOUSE_REPORT, ENABLE_GRACE
      drain

      unless ready "   Press Space, then hold the left button down anywhere in this window, drag the " \
                   "pointer out past the #{corner} corner of the window, and release it out there. " \
                   "(up to #{PATIENCE.total_seconds.to_i} s)"
        @tty.write mode.reset
        @tty.flush
        return
      end

      reports = collect_until MOUSE_REPORT, MOUSE_RELEASE, PATIENCE
      @tty.write mode.reset
      @tty.flush

      reports.compact_map do |text|
        text.match(MOUSE_COORDS).try { |match| {match[1].to_i, match[2].to_i} }
      end
    end

    # `x,y` with each coordinate picked from *points* by the block, or `none`.
    private def extreme(points : Array({Int32, Int32}), & : Array(Int32) -> Int32) : String
      return "none" if points.empty?

      "#{yield points.map(&.[0])},#{yield points.map(&.[1])}"
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

      answer = ask "#{next_step}. Does the window or tab now say #{TITLE.inspect}?"

      @tty.write TermBuf::Terminal::TITLE_STACK.reset
      @tty.flush

      @rows << Row.new "titles", "asked", answer
      say ""
    end

    # A steady underline, because it is nobody's default: most terminals start
    # with a block and Windows Terminal with a blinking bar, and a change to
    # the shape a cursor already has cannot be seen.
    private def check_cursor_shape : Nil
      @tty.write "\e[#{TermBuf::CursorShape::Underline.code(blink: false)} q"
      @tty.flush

      answer = ask "#{next_step}. Is the cursor now a steady underline, not blinking?"

      @tty.write TermBuf::Terminal::CURSOR_SHAPE_RESET
      @tty.flush

      @rows << Row.new "cursor_shape", "asked", answer
      say ""
    end

    # Reads until something matching *pattern* arrives or *patience* runs out,
    # and answers with what matched. Everything else read on the way is
    # discarded: it is the person typing while they wait.
    private def wait_for(pattern : Regex, patience : Time::Span = PATIENCE) : String?
      deadline = Time.instant + patience
      seen = IO::Memory.new
      buffer = Bytes.new 256

      while count = @reader.read(buffer, deadline)
        seen.write buffer[0, count]
        text = seen.to_s.scrub

        if match = text.match pattern
          return match[0]
        end

        # A way out for a terminal that will never answer, and for a person
        # who has decided it will not.
        decode_keys buffer[0, count]
        break if skip_typed?
      end

      nil
    end

    # Throws away whatever is already in the buffer, so that the next window
    # measures what arrives during it rather than what was left over from the
    # step before.
    private def drain : Nil
      buffer = Bytes.new 256

      # Until 20 milliseconds go by with nothing arriving.
      while @reader.read(buffer, Time.instant + 20.milliseconds)
      end

      # And whatever was half decoded or not yet taken goes with it.
      @decoder.flush { }
      @keys.clear
    end

    # Puts *question* on the screen and waits for one letter.
    # The buffer is drained first: the tracking steps leave mouse reports in
    # it, and a byte of one of those is not an answer. Then only y, n, or q
    # counts; anything else is thrown away and the question stands.
    private def ask(question : String) : String
      drain
      @tty.write "#{question} [y/n, q skips] "
      @tty.flush

      answer = "skipped"
      deadline = Time.instant + PATIENCE

      while Time.instant < deadline
        case key(deadline - Time.instant)
        when 'y', 'Y'
          answer = "yes"
          break
        when 'n', 'N'
          answer = "no"
          break
        when 'q', 'Q', '\u{3}', nil
          break
        end
      end

      say answer
      answer
    end

    # One typed character, decoded, or nothing if the patience runs out.
    # Ctrl+C comes back as `\u{3}`. Named keys and the terminal's reports are
    # passed over.
    private def key(patience : Time::Span = PATIENCE) : Char?
      deadline = Time.instant + patience
      buffer = Bytes.new 256

      loop do
        while key = @keys.shift?
          return '\u{3}' if key.ctrl? && key.char == 'c'
          return key.char if key.character? && (key.modifiers & ~TermBuf::Input::Modifiers::Shift).none?
        end

        count = @reader.read(buffer, deadline)
        return unless count

        decode_keys buffer[0, count]
      end
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
  def render(environment : Hash(String, String), rows : Array(Row)) : String
    String.build do |io|
      environment.each { |key, value| io << "# " << key << '\t' << value << '\n' }
      io << "capability\tmethod\tresult\n"

      rows.each do |row|
        io << row.capability << '\t' << row.method << '\t' << row.result << '\n'
      end
    end
  end

  # What an earlier run left at *path*, read back the way `render` wrote it.
  def read(path : String) : {Hash(String, String), Array(Row)}
    environment = {} of String => String
    rows = [] of Row

    File.each_line(path) do |line|
      if line.starts_with? "# "
        key, _, value = line[2..].partition '\t'
        environment[key] = value
      elsif line.starts_with?("capability\t") || line.blank?
        next
      else
        fields = line.split '\t'
        rows << Row.new fields[0], fields[1], fields[2] if fields.size == 3
      end
    end

    {environment, rows}
  end

  # *fresh* rows in place of the *kept* rows they re-read, the rest of *kept*
  # as it was, and the whole put back in the order a full run writes.
  def merge(kept : Array(Row), fresh : Array(Row)) : Array(Row)
    taken = fresh.map(&.key).to_set
    rows = kept.reject { |row| taken.includes? row.key } + fresh

    rows.each_with_index.to_a
      .sort_by { |(row, index)| {ORDER.index(row.key) || ORDER.size, index} }
      .map(&.[0])
  end

  # A `skipped` row for every reading not in *steps*, so a file written
  # without one still has the row.
  def skipped(steps : Array(String)) : Array(Row)
    STEPS.reject { |(name, _, _)| steps.includes? name }
      .flat_map { |(_, method, names)| names.map { |name| Row.new name, method, "skipped" } }
  end

  # The step names *value* asks for, groups expanded, in `STEPS` order.
  def steps_named(value : String) : Array(String)
    names = value.split(',').map(&.strip).reject(&.empty?)
    names = names.flat_map { |name| STEP_GROUPS[name]? || [name] }

    unknown = names.reject { |name| STEPS.any? { |(known, _, _)| known == name } }
    abort "unknown step #{unknown.join ", "}; the steps are #{STEPS.map(&.[0]).join ", "}; " \
          "#{STEP_GROUPS.keys.join " and "} each stand for several" unless unknown.empty?

    STEPS.map(&.[0]).select { |name| names.includes? name }
  end

  def run(directory : String?, steps : Array(String), partial : Bool) : Nil
    unless STDIN.tty? && STDOUT.tty?
      abort "caps_check needs a terminal at both ends: run it in one, not through a pipe"
    end

    tty = TermBuf::Tty.standard
    runner = Runner.new tty, steps

    begin
      # Raw before anything is asked. A cooked terminal echoes the replies onto
      # the screen and holds them until a newline that never comes.
      tty.raw!
      runner.query
      runner.checklist
    ensure
      tty.restore_modes
    end

    path = directory.try { |name| File.join name, "caps.tsv" }
    environment = runner.environment
    rows = runner.rows

    if partial && path && File.exists?(path)
      _, kept = read path
      rows = merge kept, rows
      environment["rerun"] = steps.empty? ? "queries" : steps.join(',')
    else
      rows = merge skipped(steps), rows
    end

    report = render environment, rows
    print report

    return unless directory && path

    Dir.mkdir_p directory
    File.write path, report
    puts "written to #{path}"
  end
end

directory = nil.as(String?)
steps = CapsCheck::STEP_GROUPS["all"]
partial = false

OptionParser.parse do |parser|
  parser.banner = "usage: caps_check [--out DIRECTORY] [--only STEPS] [--queries-only]"

  parser.on "--out DIRECTORY", "also write caps.tsv there, usually measurements/<name>" do |value|
    directory = value
  end

  parser.on "--only STEPS", "take only these readings, comma separated: " \
                            "#{CapsCheck::STEPS.map(&.[0]).join ", "}; motion stands for the three " \
                            "motion steps. With --out naming an existing caps.tsv, the rest of its " \
                            "rows are kept" do |value|
    steps = CapsCheck.steps_named value
    partial = true
  end

  parser.on "--queries-only", "ask the terminal but not the person" do
    steps = [] of String
    partial = true
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

CapsCheck.run directory, steps, partial
