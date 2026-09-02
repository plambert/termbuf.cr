require "../caps/resolver"
require "../cursor"
require "../core/buffer"
require "../core/encoder"
require "../core/painter"
require "./command"
require "./event"
require "./meter"
require "./responses"
require "./tty"

module TermBuf
  # The terminal, as an application talks to it.
  #
  # One fibre owns the buffer. Every drawing method builds a command and sends
  # it there, so ordering is total and nothing needs locking. A command that
  # has something to report — a paint, a shutdown — carries a reply channel and
  # the caller waits on it; the rest are fire and forget.
  #
  # Input is read on a fibre of its own, in its own execution context when the
  # terminal is a real device, because a blocking read would otherwise stall
  # every other fibre sharing that thread.
  #
  # Whatever happens, the terminal is given back: the owning fibre restores it
  # on the way out, signal handlers restore it before dying, and `at_exit`
  # catches anything that got past both.
  class Terminal
    include Drawing

    # Deep enough that a full redraw does not stall the fibre sending it,
    # shallow enough to be backpressure rather than an unbounded queue.
    COMMAND_CAPACITY = 256

    # Events waiting for the application. Once this fills, the reader stops
    # reading, which is the right way round: the terminal's own buffer then
    # applies backpressure to the keyboard rather than memory growing here.
    EVENT_CAPACITY = 256

    # What the terminal was found to be able to do. The encoder emits nothing
    # that is not in here.
    getter capabilities : Capabilities

    # How big the terminal was when it was last looked at. Updated by the
    # owning fibre on a resize, so this is a snapshot rather than a promise.
    getter size : ScreenSize

    # Everything the terminal has to say, in the order it happened.
    getter events : Channel(Event)

    # The device underneath, for anything the driver does not wrap.
    getter tty : Tty

    # The replies the application is waiting for. Anything arriving from the
    # terminal that matches one becomes an `Events::Response`; everything else
    # goes to the decoder, because an escape sequence nobody asked for is a key
    # someone pressed.
    getter responses : ResponseRegistry

    # Whether the terminal has been given back.
    getter? closed : Bool = false

    # Whether the owning fibre is running.
    getter? started : Bool = false

    # How this terminal measures a grapheme cluster, which is what the buffer
    # writes with. Measured at startup unless `TERMBUF_WIDTHS=off` or the
    # terminal declined to answer.
    getter widths : Unicode::WidthPolicy = Unicode::WidthPolicy::DEFAULT

    # What the width probe asked and what came back, for diagnostics. Empty
    # when it did not run.
    getter width_readings = [] of WidthProbe::Reading

    # Turns the bytes the terminal sends into events. Held here rather than
    # made on the reader fibre so that its deadlines can be adjusted before
    # anything starts reading.
    getter decoder : Decoder

    # See `Decoder::ESCAPE_TIMEOUT`. Worth raising over a slow link, where a
    # sequence can take longer than that to arrive in full.
    def escape_timeout : Time::Span
      @decoder.escape_timeout
    end

    # :ditto:
    def escape_timeout=(span : Time::Span) : Time::Span
      @decoder.escape_timeout = span
    end

    # See `Decoder::PASTE_NOTICE`.
    def paste_notice : Time::Span
      @decoder.paste_notice
    end

    # :ditto:
    def paste_notice=(span : Time::Span) : Time::Span
      @decoder.paste_notice = span
    end

    # See `Decoder::PASTE_PROGRESS`.
    def paste_progress : Time::Span
      @decoder.paste_progress
    end

    # :ditto:
    def paste_progress=(span : Time::Span) : Time::Span
      @decoder.paste_progress = span
    end

    # See `Decoder::PASTE_STALL`. Worth raising for an application expecting
    # very large pastes over a very slow link.
    def paste_stall : Time::Span
      @decoder.paste_stall
    end

    # :ditto:
    def paste_stall=(span : Time::Span) : Time::Span
      @decoder.paste_stall = span
    end

    # How many bytes the last paint sent. The point of the buffer is that a
    # frame costs a diff rather than a screenful, and this is how an
    # application checks that it is getting one.
    getter last_paint_bytes : Int32 = 0

    # How many bytes every paint has sent between them.
    getter total_paint_bytes : Int64 = 0

    @buffer : Buffer
    @screen : Region
    @cursor : Cursor?
    @hardware_cursor : Cursor?
    @painter : Painter
    @encoder : Encoder
    @meter : Meter
    @commands : Channel(Command)
    @reader : Fiber::ExecutionContext::Isolated?
    @scheduler : Fiber?
    @scheduling = false
    @signals = [] of Signal
    @restored = false
    @resize_handlers = [] of ResizeHandler

    def initialize(@tty : Tty,
                   @capabilities : Capabilities = Capabilities::NONE,
                   size : ScreenSize? = nil,
                   pending_input : Bytes = Bytes.empty,
                   warnings : Array(String) = [] of String,
                   @width_spec : String? = nil,
                   @probe_widths : Bool = false,
                   @quirks : Quirk = Quirk::None,
                   @detect_composed_drift : Bool = true,
                   clear_overhang : Bool = true)
      @size = size || @tty.size
      @buffer = Buffer.new @size.columns, @size.rows
      @screen = Region.new Rect.full(@size.columns, @size.rows)
      @painter = Painter.new @capabilities
      @painter.clear_overhang = clear_overhang
      @encoder = Encoder.new @buffer.styles, @capabilities, @size.columns, @size.rows,
        @buffer.links
      @meter = Meter.new @tty.output
      @commands = Channel(Command).new COMMAND_CAPACITY
      @events = Channel(Event).new EVENT_CAPACITY
      @responses = ResponseRegistry.new
      @decoder = Decoder.new @responses
      @pending_input = pending_input
      @initial_warnings = warnings.dup
    end

    # Detects what the terminal can do, takes it over, and starts running.
    #
    # The block form is the one to reach for: it gives the terminal back even
    # when the body raises, which no amount of care in the body can guarantee
    # on its own.
    def self.open(input : IO = STDIN, output : IO = STDOUT,
                  env : Hash(String, String) = ENV.to_h,
                  probe : Bool = true,
                  detect_composed_drift : Bool = true) : Terminal
      tty = Tty.new input, output

      # Raw mode first, and only then ask the terminal anything. A cooked
      # terminal echoes the replies onto the screen and holds them in the line
      # discipline waiting for a newline that never arrives, so the queries
      # look unanswered and the replies turn up later as if they were typed.
      resolved = begin
        if probe && tty.managed?
          tty.raw!
          # Ask on the alternate screen. A terminal that does not recognise a
          # query prints its payload, and the screen the person was looking at
          # is not the place for that; here it goes away with the screen. Which
          # terminals have one is settled from the environment, since the probe
          # that would settle it properly is the thing being hidden.
          hidden = tty.enter_alternate preliminary(env)
          asked = CapabilityResolver.resolve env, input, output
          # Nowhere to hide it, so wipe the line it landed on instead.
          tty.scrub_line unless hidden
          asked
        else
          CapabilityResolver.resolve env
        end
      rescue error
        tty.leave
        raise error
      end

      terminal = new tty, resolved.capabilities, tty.size, resolved.input, resolved.warnings,
        width_spec: env[Unicode::WidthOverrides::VARIABLE]?,
        probe_widths: probe && tty.managed?,
        quirks: resolved.quirks,
        detect_composed_drift: detect_composed_drift
      terminal.start
      terminal
    end

    # Opens a terminal, yields it, and closes it however the block ends.
    def self.open(input : IO = STDIN, output : IO = STDOUT,
                  env : Hash(String, String) = ENV.to_h,
                  probe : Bool = true,
                  detect_composed_drift : Bool = true, & : Terminal ->) : Nil
      terminal = open input, output, env, probe, detect_composed_drift

      begin
        yield terminal
      ensure
        terminal.close
      end
    end

    # What the environment alone says the terminal can do, `TERMBUF_CAPS`
    # included, which is everything there is to go on before the probe runs.
    # Only the alternate screen is read out of it, and only to decide where the
    # probe's questions are safe to ask.
    private def self.preliminary(env : Hash(String, String)) : Capabilities
      CapabilityOverrides.apply(EnvironmentDetector.detect(env), env).capabilities
    end

    # Takes the terminal over and starts the fibres that run it.
    def start : Nil
      return if @started
      @started = true

      @tty.enter @capabilities
      measure_widths
      choose_image_transport
      install_signal_handlers
      install_exit_handler

      spawn(name: "termbuf-owner") { run }
      start_reader

      @initial_warnings.each { |message| emit Events::Warning.new(message) }
    end

    # What this terminal is known to get wrong. See `Quirk`.
    getter quirks : Quirk

    # Whether to write the cell after a glyph that may have painted outside its
    # own columns. See `Painter#clear_overhang?`, which this is.
    #
    # On unless the application says otherwise: every terminal measured draws
    # over a neighbouring cell without repainting it, so ink left there stays
    # until something writes that cell again.
    def clear_overhang? : Bool
      @painter.clear_overhang?
    end

    # :ditto:
    def clear_overhang=(value : Bool) : Bool
      @painter.clear_overhang = value
    end

    # Whether to give the screen back and say so on stderr the first time a
    # cluster this terminal will misplace is drawn.
    #
    # An application that handles `Events::Warning` itself will want this off:
    # the event arrives either way, and being pulled out of the alternate
    # screen mid-frame is worse than a message it chose where to put. On by
    # default, since a terminal quietly misrendering is the thing being
    # guarded against.
    property? warn_composed_drift : Bool = true

    # Asks whether the terminal will read pixels out of a file rather than take
    # them inline, which is cheaper for anything past a few kilobytes and
    # impossible over a connection where the file is on the wrong machine.
    #
    # Asked here rather than with the rest, on the alternate screen after it is
    # entered: a terminal that cannot parse the query prints it, and the screen
    # the person was looking at is not the place for that. Nothing built from
    # the capabilities so far reads this flag — only `ImageStore` does, and it
    # is not made until an application asks for it.
    private def choose_image_transport : Nil
      return unless @probe_widths && @capabilities.includes? Capability::KittyGraphics
      return unless Prober.new(@tty.input, @tty.output).probe_temp_file

      @capabilities = @capabilities.with Capability::KittyGraphicsTempFile
    rescue IO::Error
      # A terminal that stopped answering is one the application will find out
      # about soon enough; the inline transport works regardless.
    end

    # Works out how this terminal measures a cluster.
    #
    # On the alternate screen and before anything is drawn on it, because the
    # samples have to go somewhere and the screen the person was looking at is
    # not it. Before the reader starts, because the replies would otherwise
    # arrive as keystrokes.
    private def measure_widths : Nil
      measured = Unicode::WidthPolicy::DEFAULT

      if @probe_widths && Unicode::WidthOverrides.probe?(@width_spec)
        result = WidthProbe.run @tty.input, @tty.output, measured

        # The probe has just asked the question this quirk is about, so the
        # answer replaces the guess made from the terminal's name — in both
        # directions, since a terminal that starts counting clusters properly
        # should stop carrying the quirk. When it says nothing, the name is
        # still the best that can be done.
        case result.per_code_point_columns?
        when true  then @quirks = @quirks | Quirk::PerCodePointColumns
        when false then @quirks = @quirks & ~Quirk::PerCodePointColumns
        end

        # A terminal counting columns per code point answers the probe with
        # that count, so its answers describe its bookkeeping rather than what
        # it draws: it reports one column for a variation selector emoji and
        # paints two. Taking those answers as rules would have the buffer place
        # text under the glyph. The tables are the better guess here.
        measured = result.policy unless @quirks.per_code_point_columns?
        @width_readings = result.readings
        @pending_input = keep @pending_input, result.input
        note_width_disagreements result
      end

      overrides = Unicode::WidthOverrides.apply measured, @width_spec
      @initial_warnings.concat overrides.warnings

      @widths = overrides.policy
      @buffer.policy = @widths
      @painter.watch_composed_drift = @detect_composed_drift &&
                                      @quirks.per_code_point_columns?
    end

    # Terminals reach conclusions this design has no rule for. Naming what is
    # left over beats modelling it wrong and beats saying nothing: an
    # application drawing such a cluster will see it misplaced, and this is how
    # it finds out why.
    private def note_width_disagreements(result : WidthProbe::Result) : Nil
      result.disagreements.each do |reading|
        expected = Unicode.string_width reading.sample.text, result.policy

        @initial_warnings << "this terminal advances #{reading.measured} columns for " \
                             "#{reading.sample.description} (#{reading.sample.text.inspect}); " \
                             "the buffer will use #{expected}"
      end
    end

    private def keep(first : Bytes, second : Bytes) : Bytes
      return first if second.empty?
      return second if first.empty?

      joined = Bytes.new first.size + second.size
      first.copy_to joined
      second.copy_to joined + first.size
      joined
    end

    # ------------------------------------------------------------- drawing

    def issue(command : Command) : Nil
      return if @closed

      @commands.send command
    rescue Channel::ClosedError
      # Shutting down; there is nothing left to draw on.
    end

    # Builds a frame's worth of drawing and sends it as one channel operation.
    def batch(& : Batcher ->) : Nil
      batcher = Batcher.new
      yield batcher
      return if batcher.empty?

      issue Commands::Batch.new(batcher.commands)
    end

    # Draws, and waits for the bytes to reach the terminal.
    def paint : Nil
      reply = reply_channel
      await Commands::Paint.new(false, reply), reply
    end

    # Rewrites every cell, whatever the buffer thinks the terminal is showing.
    # For after a resize, a suspend, or anything else that leaves the screen in
    # a state the buffer cannot know about.
    def paint! : Nil
      reply = reply_channel
      await Commands::Paint.new(true, reply), reply
    end

    # Draws without waiting, which is what the frame scheduler uses.
    def paint_async : Nil
      issue Commands::Paint.new(false, nil)
    end

    # Runs *action* against the buffer on the owning fibre, and waits.
    #
    # The escape hatch for anything the drawing API does not cover, and the
    # only safe way to read the buffer: doing it from another fibre would race
    # with whoever is drawing.
    def sync(&action : Buffer -> Nil) : Nil
      reply = reply_channel
      await Commands::Apply.new(action, reply), reply
    end

    # The images on screen.
    #
    # They are drawn over the cells after each frame rather than into them, so
    # text written where one sits gets both. See `ImageStore`.
    getter images : ImageStore { build_image_store }

    private def build_image_store : ImageStore
      # A graphics reply is an escape sequence the application did not ask for,
      # and without a pattern registered the decoder would hand it over as
      # keystrokes. Registered here rather than at startup, since a terminal
      # never asked for a picture never sends one. See `ImageStore::QUIET` for
      # what is left unsuppressed and why.
      expect_response ImageStore::APC, ImageStore::ST
      ImageStore.new @capabilities
    end

    # Images are written straight to the device after the frame's cells, not
    # through the command channel: they have to land in the same frame as the
    # cells they sit over, and they move the cursor, which the encoder has to be
    # told about.
    private def draw_images(forced : Bool, following : Cursor?) : Nil
      store = @images
      return unless store

      store.redraw if forced
      queued = store.take_pending
      return if queued.empty?

      queued.each { |text| @meter << text }
      # Each placement had to move the cursor to get there, so where the
      # encoder last left it is no longer where it is.
      @encoder.forget_cursor

      # And the one the application is having the terminal follow has to be put
      # back, or it spends the frame sitting under the last picture drawn.
      if following
        @encoder.encode [Ops::MoveTo.new(following.x, following.y)] of Op, @meter
      end

      @tty.flush
    end

    # The terminal's own colours: the defaults, the cursor, and the palette.
    #
    # Changes go out in order with the frames around them. See `ColorStack` for
    # why every one of them needs `Capability::KittyColorStack`.
    getter colors : ColorStack { build_color_stack }

    private def build_color_stack : ColorStack
      ColorStack.new(@capabilities) { |bytes| issue Commands::SetColors.new(bytes) }
    end

    # Interns a hyperlink and returns the id a `Style` carries it by.
    #
    #     link = terminal.link "https://example.com"
    #     screen.write 0, 0, "example", Style::DEFAULT.linked(link)
    #
    # Safe to call from any fibre. Nothing is emitted for it on a terminal
    # without `Capability::Osc8Links`; the text is drawn and the link is not.
    def link(uri : String, id : String? = nil) : LinkId
      @buffer.link uri, id
    end

    # Says that a reply beginning with *prefix* and ending with *terminator* is
    # expected, so it arrives as an `Events::Response` rather than as input.
    def expect_response(prefix : String, terminator : String) : ResponsePattern
      @responses.register prefix, terminator
    end

    # Stops expecting *pattern*, so sequences matching it are input again.
    def forget_response(pattern : ResponsePattern) : Nil
      @responses.unregister pattern
    end

    # --------------------------------------------------------------- resizing

    # Something to run when the screen changes size, before the application
    # hears about it.
    alias ResizeHandler = ScreenSize -> Nil

    # Registers *handler*, run when the screen changes size: after the grids
    # have been resized and before `Events::Resize` is sent.
    #
    # This is where an application puts its layout. A `Region` the application
    # made covers a pane it chose, and the driver has no idea what that pane
    # was meant to be a fraction or an edge of, so it does not move it — see
    # `Region#bounds=`. Rather than repeating the arithmetic at every
    # `Events::Resize`, work it out once here:
    #
    #     terminal.on_resize do |size|
    #       status.bounds = Rect.new 0, size.rows - 1, size.columns, 1
    #       log.bounds = Rect.new 0, 0, size.columns, size.rows - 1
    #     end
    #
    # Handlers run in the order they were registered, on the fibre that owns
    # the buffer. That fibre is the one servicing commands, so a handler must
    # not call back into `#batch`, `#paint`, or `#sync`; moving regions and
    # recomputing rectangles is what it is for. Anything it raises arrives as
    # an `Events::Failure` and the remaining handlers still run.
    #
    # Returns the handler, which `#forget_resize` takes back.
    def on_resize(&handler : ResizeHandler) : ResizeHandler
      on_resize handler
    end

    # :ditto:
    def on_resize(handler : ResizeHandler) : ResizeHandler
      @resize_handlers << handler
      handler
    end

    # Stops running *handler* on a resize, and says whether it was registered.
    def forget_resize(handler : ResizeHandler) : Bool
      !@resize_handlers.delete(handler).nil?
    end

    # -------------------------------------------------------------- cursors

    # The cursor streamed output goes to, covering the whole screen.
    #
    # `cursor.io` is an `IO`, so `puts`, `print`, `printf`, and anything else
    # that writes to one can be pointed at the screen.
    #
    # Made on first use rather than in the constructor, which would hand a
    # half-built terminal to something that keeps hold of it.
    def cursor : Cursor
      @cursor ||= cursor @screen
    end

    # What the buffer measures clusters with, so a `View` cuts writes where the
    # cells will fall.
    def policy : Unicode::WidthPolicy
      @widths
    end

    # A cursor over *region*, which scrolls and wraps within it.
    def cursor(region : Region) : Cursor
      made = Cursor.new self, region
      # A cursor measuring text differently from the buffer it writes into
      # would put the next character somewhere the cells disagree with.
      made.policy = @widths
      made
    end

    # A cursor over *rect*, keeping *scrollback* rows of what scrolls off it.
    def cursor(rect : Rect, scrollback : Int32 = 0) : Cursor
      cursor Region.new(rect, scrollback)
    end

    # Which cursor the terminal's own cursor follows, or `nil` while it is
    # hidden.
    #
    # Hidden is the default, which is what a full screen application wants:
    # a cursor blinking wherever the last run of text ended is a distraction.
    # An application with somewhere for someone to type points this at the
    # cursor they are typing into, and every paint puts the terminal's cursor
    # back there afterwards.
    getter hardware_cursor : Cursor?

    # :ditto:
    def hardware_cursor=(cursor : Cursor?) : Cursor?
      @hardware_cursor = cursor
    end

    # Hides the terminal's own cursor.
    def hide_cursor : Nil
      @hardware_cursor = nil
    end

    # ------------------------------------------------------------ scheduling

    # Starts painting automatically at up to *fps* frames a second, coalescing
    # whatever was drawn in between. A paint with nothing to do costs nothing,
    # so this is safe to leave running.
    #
    # Off by default: an application that draws in response to input knows
    # better than a timer when a frame is worth sending.
    def start_frame_scheduler(fps : Int32 = 60) : Nil
      raise ArgumentError.new "frame rate #{fps} is not positive" unless fps > 0
      return if @scheduling

      @scheduling = true
      interval = (1.0 / fps).seconds

      @scheduler = spawn(name: "termbuf-frames") do
        while @scheduling && !@closed
          sleep interval
          break if !@scheduling || @closed

          paint_async
        end
      end
    end

    # Stops the scheduler. Explicit paints keep working.
    def stop_frame_scheduler : Nil
      @scheduling = false
      @scheduler = nil
    end

    # Whether the frame scheduler is running.
    def scheduling? : Bool
      @scheduling
    end

    # ------------------------------------------------------------- lifecycle

    # Restores the terminal and stops. Safe to call more than once, and safe to
    # call from an exception handler.
    def close : Nil
      return if @closed
      @closed = true
      stop_frame_scheduler

      reply = reply_channel
      @commands.send Commands::Stop.new(reply)
      reply.receive
    rescue Channel::ClosedError
      restore
    ensure
      @commands.close rescue nil
    end

    # Gives the terminal back without going through the owning fibre. What the
    # signal handlers and `at_exit` call, since by then there may be no fibre
    # left to ask.
    def restore : Nil
      return if @restored
      @restored = true

      # Straight to the device rather than through the command channel: by the
      # time a signal handler or `at_exit` gets here there may be no fibre left
      # to ask, and a terminal left a different colour than it was found is
      # exactly what the stack exists to prevent.
      images = @images
      if images && !images.placements.empty?
        @tty.output << "\e_Ga=d,d=A,q=2\e\\"
      end

      stack = @colors

      if stack && stack.depth > 0
        @tty.output << "\e[#Q" * stack.depth
        @tty.flush rescue nil
      end

      @tty.leave @capabilities
    end

    # --------------------------------------------------------------- running

    private def run : Nil
      while command = @commands.receive?
        break if dispatch command
      end
    rescue Channel::ClosedError
      # Closed from underneath; fall through to the restore.
    rescue error
      emit Events::Failure.new(error)
    ensure
      restore
      @events.close rescue nil
    end

    # Returns true when the owning fibre should stop.
    private def dispatch(command : Command) : Bool
      return false if BufferSurface.apply command, @buffer

      case command
      in Commands::Passthrough then write_through command.bytes
      in Commands::SetColors   then write_colors command.bytes
      in Commands::Paint       then perform_paint command
      in Commands::Resize      then perform_resize command.size
      in Commands::Apply       then perform_apply command
      in Commands::Batch       then command.commands.each { |inner| dispatch inner }
      in Commands::Stop
        perform_stop command
        return true
      in Command
        # Handled by the buffer above.
      end

      false
    end

    private def perform_paint(command : Commands::Paint) : Nil
      if command.forced
        @buffer.invalidate
        @encoder.reset_state
        @painter.reset_state
      end

      # Read here rather than on whichever fibre moved the cursor, so a frame
      # carries one position rather than half of two.
      following = @hardware_cursor
      @painter.hardware_cursor = following && {following.x, following.y}

      ops = @painter.paint @buffer

      @meter.bytes = 0

      unless ops.empty?
        @encoder.encode ops, @meter
        @tty.flush
      end

      draw_images command.forced, following

      @last_paint_bytes = @meter.bytes
      @total_paint_bytes += @meter.bytes

      @buffer.commit_paint
      report_composed_drift
      command.reply.try &.send nil
    rescue error
      reply = command.reply
      reply ? reply.send(error) : emit(Events::Failure.new(error))
    end

    # Says so, once, when a cluster this terminal will misplace has gone out.
    #
    # The message goes to stderr as well as to the events, which is the one
    # exception to warnings staying off it: the screen is handed back first,
    # so there is nothing to corrupt, and an application that never reads its
    # events would otherwise watch the display come apart with no explanation.
    # `#warn_composed_drift=` turns the screen half off and leaves the event.
    private def report_composed_drift : Nil
      cluster = @painter.take_composed_drift
      return unless cluster

      message = composed_drift_message cluster

      emit Events::Warning.new(message)
      return unless @warn_composed_drift

      say_aside message
      repaint_in_place
    end

    # What went wrong with *cluster*, in the direction it went wrong.
    #
    # Counting more columns than the glyph is drawn in pushes the rest of the
    # row along and eats the room at its end; counting fewer leaves the glyph
    # sitting on whatever comes next. They are the same arithmetic and they do
    # not look remotely alike, so the message says which one happened.
    private def composed_drift_message(cluster : String) : String
      counted = @buffer.clusters.code_point_columns @buffer.clusters.id(cluster, @widths)
      drawn = Unicode.string_width cluster, @widths
      by = (counted - drawn).abs
      opening = "this terminal counts a grapheme cluster's columns by adding up its code " \
                "points, so #{cluster.inspect} takes #{plural counted, "column"} where it is " \
                "drawn in #{drawn}."

      if counted > drawn
        "#{opening} Everything after it on that row sits #{plural by, "column"} to the right of " \
        "where it was put, and the last #{plural by, "column"} of the row cannot be reached."
      else
        "#{opening} Everything after it on that row sits #{plural by, "column"} to the left of " \
        "where it was put, so the glyph covers what follows it."
      end
    end

    private def plural(count : Int32, noun : String) : String
      "#{count} #{noun}#{"s" unless count == 1}"
    end

    # Writes *message* where the application can see it, with the screen given
    # back for as long as it takes.
    private def say_aside(message : String) : Nil
      alternate = @capabilities.includes? Capability::AltScreen

      @tty.output << "\e[?1049l" if alternate
      @tty.flush
      STDERR.puts "termbuf: #{message}"
      STDERR.flush

      # The alternate screen keeps its own cursor visibility, so coming back
      # to it undoes the hide that `Tty#enter` did. Without this the cursor
      # reappears and, with nothing placing it, sits wherever each frame's last
      # run happened to end.
      @tty.output << "\e[?1049h" if alternate
      @tty.output << "\e[?25l"
      @tty.flush
      # The repaint that follows resets the painter, which is what puts the
      # cursor back on a screen that wants one showing.


    rescue IO::Error
      # The terminal has gone; there is nobody left to tell.
    end

    # A forced repaint from inside the owning fibre, which cannot send itself a
    # command and wait for it.
    private def repaint_in_place : Nil
      @buffer.invalidate
      @encoder.reset_state
      @painter.reset_state
      perform_paint Commands::Paint.new(false, nil)
    end

    private def perform_resize(size : ScreenSize) : Nil
      return if size.columns == @size.columns && size.rows == @size.rows

      @size = size
      @buffer.resize size.columns, size.rows
      @encoder.resize size.columns, size.rows
      @painter.reset_state

      # The screen-wide region has to follow the screen. A region an
      # application made covers a pane it chose, and moving that is its
      # business rather than the driver's — which is what `#on_resize` is for.
      @screen.bounds = Rect.full size.columns, size.rows
      # An image that no longer fits is gone; the terminal dropped it when the
      # screen shrank under it, and keeping a placement it does not have would
      # have the next forced repaint redraw a picture into the wrong cells.
      @images.try &.resize size.columns, size.rows
      @buffer.invalidate

      run_resize_handlers size

      emit Events::Resize.new(size)
    end

    # The application's layout, run before it is told the screen changed so
    # that whatever it draws next sees panes already in their new places. One
    # handler raising does not stop the others, since a half-placed layout is
    # worse than a reported failure.
    private def run_resize_handlers(size : ScreenSize) : Nil
      @resize_handlers.each do |handler|
        handler.call size
      rescue error
        emit Events::Failure.new(error)
      end
    end

    private def perform_apply(command : Commands::Apply) : Nil
      command.action.call @buffer
      command.reply.try &.send nil
    rescue error
      reply = command.reply
      reply ? reply.send(error) : emit(Events::Failure.new(error))
    end

    private def perform_stop(command : Commands::Stop) : Nil
      restore
      command.reply.try &.send nil
    rescue error
      command.reply.try &.send error
    end

    # A colour change moves no cursor and sets no attribute, so unlike a
    # passthrough it leaves what the encoder knows about the screen intact.
    private def write_colors(bytes : Bytes) : Nil
      @tty.output.write bytes
      @tty.flush
    end

    # Passthrough bytes go out after whatever frame is in flight, and leave the
    # encoder's idea of the cursor and style unknown, since there is no telling
    # what they did.
    private def write_through(bytes : Bytes) : Nil
      @tty.output.write bytes
      @tty.flush
      @encoder.reset_state
      @encoder.forget_link_state
    end

    # ----------------------------------------------------------------- input

    private def start_reader : Nil
      # A blocking read on a real device needs a thread of its own, or it
      # stalls every fibre sharing one. An in-memory stream returns straight
      # away and does not.
      if @tty.managed?
        @reader = Fiber::ExecutionContext::Isolated.new("termbuf-input") { read_loop }
      else
        spawn(name: "termbuf-input") { read_loop }
      end
    end

    private def read_loop : Nil
      decoder = @decoder
      decoder.feed(@pending_input) { |event| emit event } unless @pending_input.empty?

      buffer = Bytes.new 4096
      input = @tty.input

      loop do
        count = read_next input, buffer, decoder
        next if count.nil?
        break if count.zero?

        decoder.feed(buffer[0, count]) { |event| emit event }
      end
    rescue IO::Error
      # The terminal went away.
    ensure
      emit Events::Closed.new
    end

    # Reads the next chunk. Returns the number of bytes, zero at end of input,
    # or `nil` when a deadline expired and whatever it was waiting on has been
    # dealt with.
    #
    # A deadline is only set when the decoder is holding something. The rest of
    # the time the read blocks, which is what it should do: waking every 25
    # milliseconds to find nothing is work nobody asked for.
    private def read_next(input : IO, buffer : Bytes, decoder : Decoder) : Int32?
      deadline = decoder.read_deadline
      return input.read buffer unless deadline
      return input.read buffer unless input.responds_to? :read_timeout=

      input.read_timeout = deadline

      begin
        input.read buffer
      rescue IO::TimeoutError
        decoder.tick { |event| emit event }
        nil
      ensure
        input.read_timeout = nil
      end
    end

    private def emit(event : Event) : Nil
      @events.send event
    rescue Channel::ClosedError
      # Nobody is listening any more.
    end

    # --------------------------------------------------------------- signals

    private def install_signal_handlers : Nil
      return unless @tty.managed?

      trap Signal::WINCH do
        issue Commands::Resize.new(@tty.size)
      end

      # A terminal left in raw mode on the alternate screen makes the user's
      # shell unusable, so these restore before letting the default happen.
      {Signal::TERM, Signal::INT, Signal::HUP}.each do |signal|
        trap signal do
          restore
          signal.reset
          Process.signal signal, Process.pid
        end
      end

      install_suspend_handlers
    end

    # Suspending gives the terminal back before stopping, and resuming takes it
    # again and redraws, since the shell will have written over the screen in
    # between.
    private def install_suspend_handlers : Nil
      trap Signal::TSTP do
        restore
        Signal::TSTP.reset
        Process.signal Signal::TSTP, Process.pid
      end

      trap Signal::CONT do
        @restored = false
        @tty.enter @capabilities
        install_suspend_handlers
        issue Commands::Paint.new(true, nil)
      end
    end

    private def trap(signal : Signal, &handler : ->) : Nil
      @signals << signal unless @signals.includes? signal
      signal.trap { handler.call }
    end

    private def install_exit_handler : Nil
      at_exit { restore }
    end

    # ----------------------------------------------------------------- waiting

    private def reply_channel : Channel(Exception?)
      Channel(Exception?).new 1
    end

    # Sends a command and waits for the fibre that owns the buffer to report
    # back, re-raising there whatever went wrong here.
    private def await(command : Command, reply : Channel(Exception?)) : Nil
      return if @closed

      @commands.send command
      error = reply.receive
      raise error if error
    rescue Channel::ClosedError
      # Shutting down; there is nothing left to wait for.
    end
  end
end
