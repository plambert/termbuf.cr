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

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # How many cells the terminal is showing.
  struct ScreenSize
    # Cells across.
    getter columns : Int32

    # Cells down.
    getter rows : Int32

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
  module SizeDetector
    extend self

    {% if flag?(:darwin) || flag?(:bsd) %}
      TIOCGWINSZ = 0x40087468_u64
    {% else %}
      TIOCGWINSZ = 0x5413_u64
    {% end %}

    # In order: the kernel, the environment, then the shell utilities.
    def detect(fd : Int32? = nil, env : Hash(String, String) = ENV.to_h) : ScreenSize
      from_ioctl(fd) || from_env(env) || from_commands || ScreenSize::DEFAULT
    end

    # `TIOCGWINSZ` on the given descriptor, or on stdout, stdin, and stderr in
    # turn when none is named. A process with its output redirected often still
    # has a terminal on one of the others.
    def from_ioctl(fd : Int32? = nil) : ScreenSize?
      descriptors = fd ? [fd] : [1, 0, 2]

      descriptors.each do |descriptor|
        size = uninitialized LibC::TermBufWinsize
        next unless LibC.ioctl(descriptor, TIOCGWINSZ, pointerof(size)).zero?
        next if size.ws_col.zero? || size.ws_row.zero?

        return ScreenSize.new size.ws_col.to_i, size.ws_row.to_i
      end

      nil
    end

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
