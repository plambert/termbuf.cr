require "../caps/capability"
require "../caps/screen_size"

module TermBuf
  # The terminal device itself: the modes it is in, the screen it is showing,
  # and how big it is.
  #
  # Everything here is reversible, and reversing it is the point. A program
  # that leaves a terminal in raw mode on the alternate screen has made the
  # user's shell unusable, so `#leave` undoes exactly what `#enter` did and can
  # be called any number of times.
  #
  # It works over any pair of `IO`s. When those are not a terminal — a pipe, a
  # spec — the mode changes are skipped and the escape sequences still go out,
  # which is what makes the whole driver testable without a device.
  class Tty
    getter input : IO
    getter output : IO

    # Whether this is a terminal whose modes are worth changing.
    getter? managed : Bool

    # Set once `#enter` has run, cleared by `#leave`.
    getter? entered : Bool = false

    # Crystal's bindings carry `VMIN` but not `VTIME` on every platform, so the
    # index is filled in here when it is missing.
    {% if LibC.has_constant?(:VTIME) %}
      VTIME = LibC::VTIME
    {% elsif flag?(:darwin) || flag?(:bsd) %}
      VTIME = 17
    {% else %}
      VTIME = 5
    {% end %}

    @input_fd : Int32?
    @output_fd : Int32?
    @saved : LibC::Termios?

    def initialize(@input : IO, @output : IO, managed : Bool? = nil)
      @input_fd = descriptor @input
      @output_fd = descriptor @output
      @managed = managed.nil? ? terminal? : managed
    end

    # The process's own terminal.
    def self.standard : Tty
      new STDIN, STDOUT
    end

    private def descriptor(io : IO) : Int32?
      io.is_a?(IO::FileDescriptor) ? io.fd : nil
    end

    private def terminal? : Bool
      output = @output
      return false unless output.is_a? IO::FileDescriptor

      output.tty?
    end

    # How big the terminal is now. Asked afresh every time, since the answer
    # changes whenever the window does.
    def size : ScreenSize
      SizeDetector.detect @output_fd
    end

    # Takes the terminal over: raw mode, the alternate screen, no cursor.
    #
    # *capabilities* decides which of the optional modes are worth asking for;
    # asking a terminal to enable something it does not have leaves the request
    # printed on screen.
    def enter(capabilities : Capabilities = Capabilities::NONE) : Nil
      return if @entered

      apply_raw_mode
      @output << "\e[?1049h" if capabilities.includes? Capability::AltScreen
      @output << "\e[?25l"
      @output << "\e[2J\e[H"
      @output.flush
      @entered = true
    end

    # Gives the terminal back exactly as it was found. Safe to call twice, and
    # safe to call when `#enter` never ran, which is what makes it usable from
    # a signal handler and from `at_exit`.
    def leave(capabilities : Capabilities = Capabilities::NONE) : Nil
      return unless @entered
      @entered = false

      @output << "\e[?25h"
      @output << "\e[?1049l" if capabilities.includes? Capability::AltScreen
      @output << "\e[0m"
      @output.flush
      restore_modes
    rescue IO::Error
      # The terminal has gone. Nothing left to restore it to.
    end

    def write(text : String) : Nil
      @output << text
    end

    def flush : Nil
      @output.flush
    end

    # ------------------------------------------------------------- modes

    # Puts the terminal in raw mode, keeping what it was in so `#restore_modes`
    # can put it back. Crystal's own `raw!` would do most of this, but it
    # restores to a *cooked* terminal rather than to whatever was there before,
    # which is not the same thing when a program was started from something
    # other than an ordinary shell.
    private def apply_raw_mode : Nil
      fd = @input_fd
      return unless @managed && fd

      original = uninitialized LibC::Termios
      return unless LibC.tcgetattr(fd, pointerof(original)).zero?

      @saved = original
      raw = original

      raw.c_iflag &= ~(LibC::IGNBRK | LibC::BRKINT | LibC::PARMRK | LibC::ISTRIP |
                       LibC::INLCR | LibC::IGNCR | LibC::ICRNL | LibC::IXON)
      raw.c_oflag &= ~LibC::OPOST
      raw.c_lflag &= ~(LibC::ECHO | LibC::ECHONL | LibC::ICANON | LibC::ISIG | LibC::IEXTEN)
      raw.c_cflag &= ~(LibC::CSIZE | LibC::PARENB)
      raw.c_cflag |= LibC::CS8

      # Block until at least one byte arrives, with no inter-byte timer: the
      # reader wants to sleep rather than spin, and escape sequence timing is
      # decided further up, not here.
      raw.c_cc[LibC::VMIN] = 1_u8
      raw.c_cc[VTIME] = 0_u8

      LibC.tcsetattr fd, LibC::TCSANOW, pointerof(raw)
    end

    def restore_modes : Nil
      fd = @input_fd
      saved = @saved
      return unless fd && saved

      @saved = nil

      # A fresh local, because `pointerof` goes by the declared type and the
      # ivar's includes nil however narrow the check above made it.
      original = saved
      LibC.tcsetattr fd, LibC::TCSANOW, pointerof(original)
    end
  end
end
