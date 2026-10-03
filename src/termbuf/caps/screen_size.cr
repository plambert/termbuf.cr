{% unless flag?(:win32) %}
  lib LibC
    # What `TIOCGWINSZ` fills in. Named for the shard because Crystal's own
    # `LibC` does not bind it on every platform, and a clashing definition would
    # not compile.
    struct TermBufWinsize
      ws_row : UShort
      ws_col : UShort
      ws_xpixel : UShort
      ws_ypixel : UShort
    end

    fun ioctl(fd : Int, request : ULong, ...) : Int
  end
{% end %}

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # How many cells the terminal is showing.
  struct ScreenSize
    # Cells across.
    getter columns : Int32

    # Cells down.
    getter rows : Int32

    # A screen *columns* cells across and *rows* down. Neither may be zero or
    # negative: a terminal that size cannot be drawn on.
    def initialize(@columns : Int32, @rows : Int32)
      raise ArgumentError.new "column count #{@columns} is not positive" unless @columns > 0
      raise ArgumentError.new "row count #{@rows} is not positive" unless @rows > 0
    end

    # What to assume when nothing can be established. Every terminal is at
    # least this big, and guessing larger paints off the edge of the screen.
    DEFAULT = new 80, 24

    def to_s(io : IO) : Nil
      io << @columns << 'x' << @rows
    end
  end

  # Stability: internal
  #
  # Works out how big the terminal is, trying each source in turn and taking
  # the first that answers.
  #
  # The ioctl comes first because it is exact, free, and needs no cooperation
  # from the terminal. Everything after it is a fallback for the cases where
  # there is no controlling terminal to ask — a pipe, a pty without a size set,
  # a terminal reached across a connection that did not forward one.
  #
  # Windows has no ioctl. Its console says how big its window is instead, and
  # there are no shell utilities to fall back on: `stty` from a Unix toolkit
  # describes a terminal of its own emulation, not the console this process is
  # attached to.
  module SizeDetector
    extend self

    # What a descriptor is: a file descriptor, or on Windows the handle
    # `IO::FileDescriptor#fd` answers there.
    {% if flag?(:win32) %}
      alias Descriptor = LibC::UIntPtrT
    {% else %}
      alias Descriptor = Int32
    {% end %}

    {% if flag?(:darwin) || flag?(:bsd) %}
      TIOCGWINSZ = 0x40087468_u64
    {% elsif !flag?(:win32) %}
      TIOCGWINSZ = 0x5413_u64
    {% end %}

    # In order: the kernel, the environment, then the shell utilities. On
    # Windows: the console, then the environment.
    def detect(fd : Descriptor? = nil, env : Hash(String, String) = ENV.to_h) : ScreenSize
      {% if flag?(:win32) %}
        from_console(fd) || from_env(env) || ScreenSize::DEFAULT
      {% else %}
        from_ioctl(fd) || from_env(env) || from_commands || ScreenSize::DEFAULT
      {% end %}
    end

    {% if flag?(:win32) %}
      # The console window on the given handle, or on standard output and then
      # standard error when none is named. Standard input is not asked: the
      # window belongs to an output handle, and an input handle cannot say.
      #
      # The window, not the buffer. A classic console window's buffer holds its
      # scrollback too, thousands of rows that are not the screen.
      def from_console(fd : Descriptor? = nil) : ScreenSize?
        handles = if fd
                    [LibC::HANDLE.new(fd)]
                  else
                    [LibC::STD_OUTPUT_HANDLE, LibC::STD_ERROR_HANDLE].map { |which| LibC.GetStdHandle(which) }
                  end

        handles.each do |handle|
          info = uninitialized LibTermBufConsole::ConsoleScreenBufferInfo
          next if LibTermBufConsole.GetConsoleScreenBufferInfo(handle, pointerof(info)).zero?

          columns = info.window.right.to_i - info.window.left.to_i + 1
          rows = info.window.bottom.to_i - info.window.top.to_i + 1
          next unless columns > 0 && rows > 0

          return ScreenSize.new columns, rows
        end

        nil
      end

      # Always `nil` on Windows. A console's font is the console's own, and a
      # terminal hosting it through a pseudoconsole draws in a font the console
      # never hears about, so no answer here would be the terminal's.
      def cell_pixels(fd : Descriptor? = nil) : {Int32, Int32}?
        nil
      end
    {% else %}
      # `TIOCGWINSZ` on the given descriptor, or on stdout, stdin, and stderr in
      # turn when none is named. A process with its output redirected often still
      # has a terminal on one of the others.
      def from_ioctl(fd : Descriptor? = nil) : ScreenSize?
        descriptors = fd ? [fd] : [1, 0, 2]

        descriptors.each do |descriptor|
          size = uninitialized LibC::TermBufWinsize
          next unless LibC.ioctl(descriptor, TIOCGWINSZ, pointerof(size)).zero?
          next if size.ws_col.zero? || size.ws_row.zero?

          return ScreenSize.new size.ws_col.to_i, size.ws_row.to_i
        end

        nil
      end

      # How many pixels one cell measures, from the same ioctl, or `nil` when the
      # terminal does not say.
      #
      # `TIOCGWINSZ` carries the window in pixels beside the window in cells, and
      # one divided by the other is a cell. Plenty of terminals fill in the cells
      # and leave the pixels at zero, which is why this answers `nil` rather than
      # guessing: a cell's shape cannot be inferred from anything else, and an
      # image scaled against a guess comes out the wrong shape. See
      # `ImageStore#cell_size`.
      #
      # There is no environment or `stty` fallback. Neither reports pixels.
      def cell_pixels(fd : Descriptor? = nil) : {Int32, Int32}?
        descriptors = fd ? [fd] : [1, 0, 2]

        descriptors.each do |descriptor|
          size = uninitialized LibC::TermBufWinsize
          next unless LibC.ioctl(descriptor, TIOCGWINSZ, pointerof(size)).zero?
          next if size.ws_col.zero? || size.ws_row.zero?
          next if size.ws_xpixel.zero? || size.ws_ypixel.zero?

          width = size.ws_xpixel.to_i // size.ws_col.to_i
          height = size.ws_ypixel.to_i // size.ws_row.to_i
          next unless width > 0 && height > 0

          return {width, height}
        end

        nil
      end
    {% end %}

    # `COLUMNS` and `LINES`, which a shell exports and which can be set by hand
    # when nothing else knows.
    def from_env(env : Hash(String, String)) : ScreenSize?
      columns = env["COLUMNS"]?.try &.to_i?
      rows = env["LINES"]?.try &.to_i?
      return unless columns && rows
      return unless columns > 0 && rows > 0

      ScreenSize.new columns, rows
    end

    # `stty` and `tput`, which reach the same ioctl by another route. Worth
    # trying because they may find a controlling terminal this process cannot
    # see through its own descriptors.
    def from_commands : ScreenSize?
      from_stty || from_tput
    end

    private def from_stty : ScreenSize?
      output = capture "stty", ["size"]
      return unless output

      fields = output.split
      return unless fields.size == 2

      rows = fields[0].to_i?
      columns = fields[1].to_i?
      return unless rows && columns && rows > 0 && columns > 0

      ScreenSize.new columns, rows
    end

    private def from_tput : ScreenSize?
      columns = capture("tput", ["cols"]).try &.strip.to_i?
      rows = capture("tput", ["lines"]).try &.strip.to_i?
      return unless columns && rows
      return unless columns > 0 && rows > 0

      ScreenSize.new columns, rows
    end

    private def capture(command : String, arguments : Array(String)) : String?
      output = IO::Memory.new
      status = Process.run command, arguments, output: output, error: Process::Redirect::Close,
        input: Process::Redirect::Inherit
      return unless status.success?

      output.to_s.strip.presence
    rescue IO::Error
      nil
    end
  end
end
