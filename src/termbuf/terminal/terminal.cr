require "../caps/resolver"
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

    # How long to wait for the rest of an escape sequence before deciding
    # there is no rest.
    #
    # The escape key sends one byte, and so does the start of every arrow key,
    # so the two are indistinguishable until either more bytes arrive or
    # enough time passes that none will. Long enough to cover a sequence split
    # across two reads, short enough that pressing escape feels immediate.
    ESCAPE_TIMEOUT = 25.milliseconds

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

    # See `ESCAPE_TIMEOUT`. Worth raising over a slow link, where a sequence
    # can take longer than that to arrive in full.
    property escape_timeout : Time::Span = ESCAPE_TIMEOUT

    # How many bytes the last paint sent. The point of the buffer is that a
    # frame costs a diff rather than a screenful, and this is how an
    # application checks that it is getting one.
    getter last_paint_bytes : Int32 = 0

    # How many bytes every paint has sent between them.
    getter total_paint_bytes : Int64 = 0

    @buffer : Buffer
    @painter : Painter
    @encoder : Encoder
    @meter : Meter
    @commands : Channel(Command)
    @reader : Fiber::ExecutionContext::Isolated?
    @scheduler : Fiber?
    @scheduling = false
    @signals = [] of Signal
    @restored = false

    def initialize(@tty : Tty,
                   @capabilities : Capabilities = Capabilities::NONE,
                   size : ScreenSize? = nil,
                   pending_input : Bytes = Bytes.empty,
                   warnings : Array(String) = [] of String)
      @size = size || @tty.size
      @buffer = Buffer.new @size.columns, @size.rows
      @painter = Painter.new @capabilities
      @encoder = Encoder.new @buffer.styles, @capabilities, @size.columns, @size.rows
      @meter = Meter.new @tty.output
      @commands = Channel(Command).new COMMAND_CAPACITY
      @events = Channel(Event).new EVENT_CAPACITY
      @responses = ResponseRegistry.new
      @pending_input = pending_input
      @initial_warnings = warnings
    end

    # Detects what the terminal can do, takes it over, and starts running.
    #
    # The block form is the one to reach for: it gives the terminal back even
    # when the body raises, which no amount of care in the body can guarantee
    # on its own.
    def self.open(input : IO = STDIN, output : IO = STDOUT,
                  env : Hash(String, String) = ENV.to_h,
                  probe : Bool = true) : Terminal
      tty = Tty.new input, output

      # Raw mode first, and only then ask the terminal anything. A cooked
      # terminal echoes the replies onto the screen and holds them in the line
      # discipline waiting for a newline that never arrives, so the queries
      # look unanswered and the replies turn up later as if they were typed.
      resolved = begin
        if probe && tty.managed?
          tty.raw!
          CapabilityResolver.resolve env, input, output
        else
          CapabilityResolver.resolve env
        end
      rescue error
        tty.restore_modes
        raise error
      end

      terminal = new tty, resolved.capabilities, tty.size, resolved.input, resolved.warnings
      terminal.start
      terminal
    end

    # Opens a terminal, yields it, and closes it however the block ends.
    def self.open(input : IO = STDIN, output : IO = STDOUT,
                  env : Hash(String, String) = ENV.to_h,
                  probe : Bool = true, & : Terminal ->) : Nil
      terminal = open input, output, env, probe

      begin
        yield terminal
      ensure
        terminal.close
      end
    end

    # Takes the terminal over and starts the fibres that run it.
    def start : Nil
      return if @started
      @started = true

      @tty.enter @capabilities
      install_signal_handlers
      install_exit_handler

      spawn(name: "termbuf-owner") { run }
      start_reader

      @initial_warnings.each { |message| emit Events::Warning.new(message) }
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

    # Says that a reply beginning with *prefix* and ending with *terminator* is
    # expected, so it arrives as an `Events::Response` rather than as input.
    def expect_response(prefix : String, terminator : String) : ResponsePattern
      @responses.register prefix, terminator
    end

    # Stops expecting *pattern*, so sequences matching it are input again.
    def forget_response(pattern : ResponsePattern) : Nil
      @responses.unregister pattern
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
      case command
      in Commands::Write        then @buffer.write command.x, command.y, command.text, command.style
      in Commands::WriteChar    then @buffer.write_char command.x, command.y, command.char, command.style
      in Commands::Fill         then @buffer.fill command.rect, command.char, command.style
      in Commands::Clear        then @buffer.clear command.style
      in Commands::Scroll       then @buffer.scroll command.rect, command.lines, command.style
      in Commands::ScrollRegion then @buffer.scroll_region command.region, command.lines, command.style
      in Commands::Invalidate   then @buffer.invalidate
      in Commands::Passthrough  then write_through command.bytes
      in Commands::Paint        then perform_paint command
      in Commands::Resize       then perform_resize command.size
      in Commands::Apply        then perform_apply command
      in Commands::Batch        then command.commands.each { |inner| dispatch inner }
      in Commands::Stop
        perform_stop command
        return true
      end

      false
    end

    private def perform_paint(command : Commands::Paint) : Nil
      if command.forced
        @buffer.invalidate
        @encoder.reset_state
      end

      ops = @painter.paint @buffer

      @meter.bytes = 0

      unless ops.empty?
        @encoder.encode ops, @meter
        @tty.flush
      end

      @last_paint_bytes = @meter.bytes
      @total_paint_bytes += @meter.bytes

      @buffer.commit_paint
      command.reply.try &.send nil
    rescue error
      reply = command.reply
      reply ? reply.send(error) : emit(Events::Failure.new(error))
    end

    private def perform_resize(size : ScreenSize) : Nil
      return if size.columns == @size.columns && size.rows == @size.rows

      @size = size
      @buffer.resize size.columns, size.rows
      @encoder.resize size.columns, size.rows
      @buffer.invalidate

      emit Events::Resize.new(size)
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

    # Passthrough bytes go out after whatever frame is in flight, and leave the
    # encoder's idea of the cursor and style unknown, since there is no telling
    # what they did.
    private def write_through(bytes : Bytes) : Nil
      @tty.output.write bytes
      @tty.flush
      @encoder.reset_state
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
      decoder = Decoder.new @responses
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
    # or `nil` when the wait for the rest of a sequence ran out and what was
    # held back has been delivered for what it turned out to be.
    #
    # The deadline is only applied while something is pending. The rest of the
    # time the read blocks, which is what it should do: waking up every 25
    # milliseconds to find nothing is work nobody asked for.
    private def read_next(input : IO, buffer : Bytes, decoder : Decoder) : Int32?
      return input.read buffer unless decoder.pending?
      return input.read buffer unless input.responds_to? :read_timeout=

      input.read_timeout = @escape_timeout

      begin
        input.read buffer
      rescue IO::TimeoutError
        decoder.flush { |event| emit event }
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
