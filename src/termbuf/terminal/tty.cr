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
    # Where keystrokes and replies come from.
    getter input : IO

    # Where escape sequences go.
    getter output : IO

    # Whether this is a terminal whose modes are worth changing.
    getter? managed : Bool

    # Set once `#enter` has run, cleared by `#leave`.
    getter? entered : Bool = false

    # Set once the modes have been changed, which happens before `#enter` when
    # the terminal is about to be probed.
    getter? raw : Bool = false

    # Whether the alternate screen has been switched to. Tracked apart from
    # `#entered?` because the probe switches to it before the takeover, and
    # tracked at all so that `#leave` pops what was pushed rather than what a
    # capability set settled afterwards says should have been.
    getter? alternate : Bool = false

    # A terminal mode that can be turned on and off, and the sequences that do
    # it.
    #
    # The *name* is what identity means here, not the sequences: turning the
    # same mode on twice must not send its set sequence twice. `KITTY_KEYBOARD`
    # pushes onto a stack the terminal itself keeps, so a second push against
    # the one pop that `#leave` sends would leave the keyboard changed after
    # the program has gone.
    record Mode, name : String, set : String, reset : String

    # Pasted text arrives marked as pasted, rather than as a very fast typist
    # triggering every key binding on the way past.
    BRACKETED_PASTE = Mode.new "bracketed-paste", "\e[?2004h", "\e[?2004l"

    # The terminal reports the window gaining and losing focus.
    FOCUS_EVENTS = Mode.new "focus-events", "\e[?1004h", "\e[?1004l"

    # Mouse button reporting in the SGR encoding, which is the one that can
    # name a column past 223. Both are asked for together, and given back in
    # the reverse order.
    MOUSE_SGR = Mode.new "mouse-sgr", "\e[?1000h\e[?1006h", "\e[?1006l\e[?1000l"

    # The kitty keyboard protocol, which tells apart keystrokes an ordinary
    # terminal reports identically. This pushes a flag set onto the terminal's
    # own stack and the reset pops it.
    KITTY_KEYBOARD = Mode.new "kitty-keyboard", "\e[>1u", "\e[<u"

    # Every mode registered on this terminal, in the order it was enabled.
    # `#leave` resets them in the reverse of that order.
    getter modes = [] of Mode

    # The names of the modes currently set on the device, which is not always
    # every registered one: a mode enabled before `#enter` is recorded and only
    # written when the takeover happens.
    @applied = Set(String).new

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

    # Blanks the line the cursor is on, using nothing but a carriage return and
    # spaces.
    #
    # A terminal that does not recognise a query prints its payload instead of
    # swallowing it, so asking one leaves rubbish on the screen the person was
    # looking at — and it is still there once the program gives the screen
    # back. Terminal.app does this with `XTGETTCAP`, `DECRPM` and the kitty
    # graphics query, between them putting about forty five characters on the
    # line the program started on.
    #
    # The fallback for a terminal with no alternate screen to ask on. Where
    # there is one, `#enter_alternate` puts the echo somewhere nobody is
    # looking and leaving takes it away; a line of spaces is as much as a
    # terminal that has just demonstrated it cannot parse an escape sequence
    # can be asked to understand, and an echo long enough to have wrapped
    # would leave its earlier lines behind.
    def scrub_line : Nil
      @output << '\r' << " " * size.columns << '\r'
      @output.flush
    rescue IO::Error
      # The terminal has gone; there is nothing to tidy.
    end

    # Switches to the alternate screen, without the rest of the takeover.
    #
    # This is where the probe goes. A terminal that does not recognise a query
    # prints its payload instead of swallowing it, so asking on the screen the
    # person was looking at leaves rubbish there — and it is still there once
    # the program has given the screen back. On the alternate screen nobody
    # sees any of it and leaving takes it away along with the screen.
    #
    # Returns whether the screen was switched. Without `Capability::AltScreen`
    # there is nowhere to put the echo and the caller has `#scrub_line`
    # instead. Idempotent; `#enter` calls it, and `#leave` undoes it whether or
    # not `#enter` ever ran.
    def enter_alternate(capabilities : Capabilities = Capabilities::NONE) : Bool
      return true if @alternate
      return false unless capabilities.includes? Capability::AltScreen

      raw!
      @output << "\e[?1049h"
      @output.flush
      @alternate = true
    end

    # Takes the terminal over: raw mode, the alternate screen, no cursor.
    #
    # *capabilities* decides which of the optional modes are worth asking for;
    # asking a terminal to enable something it does not have leaves the request
    # printed on screen. Bracketed paste is registered here, and every mode
    # registered by `#enable` is written now, which is what makes taking the
    # terminal back after a suspend put the modes back too.
    def enter(capabilities : Capabilities = Capabilities::NONE) : Nil
      return if @entered

      raw!
      enter_alternate capabilities
      register BRACKETED_PASTE if capabilities.includes? Capability::BracketedPaste
      @entered = true
      apply_modes
      @output << "\e[?25l"
      @output << "\e[2J\e[H"
      @output.flush
    end

    # Gives the terminal back exactly as it was found. Safe to call twice, and
    # safe to call when `#enter` never ran, which is what makes it usable from
    # a signal handler and from `at_exit`.
    def leave : Nil
      taken = @entered
      alternate = @alternate
      @entered = false
      @alternate = false

      if taken || alternate
        @output << "\e[?25h" if taken
        reset_modes
        @output << "\e[?1049l" if alternate
        @output << "\e[0m" if taken
        @output.flush
      end

      restore_modes
    rescue IO::Error
      # The terminal has gone; put the modes back regardless.
      restore_modes
    end

    # Writes straight to the device, bypassing the buffer.
    def write(text : String) : Nil
      @output << text
    end

    # Pushes whatever is buffered out to the device.
    def flush : Nil
      @output.flush
    end

    # ---------------------------------------------------- terminal modes

    # Turns *mode* on: now if the terminal has been taken over, and at `#enter`
    # if it has not.
    #
    # Registration is by name, so enabling the same mode twice registers it
    # once and writes it once. That is not tidiness. `KITTY_KEYBOARD` pushes
    # onto a stack the terminal keeps, and a second push against the single pop
    # `#leave` sends leaves the keyboard changed after the program has gone.
    def enable(mode : Mode) : Nil
      register mode
      return unless @entered
      return if @applied.includes? mode.name

      @output << mode.set
      @output.flush
      @applied << mode.name
    end

    # Turns *mode* off and forgets it, so a later `#enter` does not bring it
    # back. A mode that was never enabled is nothing to turn off.
    def disable(mode : Mode) : Nil
      index = @modes.index { |registered| registered.name == mode.name }
      return unless index

      registered = @modes.delete_at index
      return unless @applied.delete registered.name

      @output << registered.reset
      @output.flush
    end

    # Records *mode*, replacing a registration of the same name where it
    # stands, so that the order the resets go out in does not depend on how
    # many times a mode was enabled.
    private def register(mode : Mode) : Nil
      index = @modes.index { |registered| registered.name == mode.name }

      if index
        @modes[index] = mode
      else
        @modes << mode
      end
    end

    # Writes every registered mode that is not on the device yet.
    private def apply_modes : Nil
      @modes.each do |mode|
        next if @applied.includes? mode.name

        @output << mode.set
        @applied << mode.name
      end
    end

    # Gives back every mode that is on the device, newest first, since a mode
    # enabled after another may depend on it.
    private def reset_modes : Nil
      @modes.reverse_each do |mode|
        next unless @applied.includes? mode.name

        @output << mode.reset
      end

      @applied.clear
    end

    # ------------------------------------------------------------- modes

    # Puts the terminal in raw mode, keeping what it was in so `#restore_modes`
    # can put it back. Crystal's own `raw!` would do most of this, but it
    # restores to a *cooked* terminal rather than to whatever was there before,
    # which is not the same thing when a program was started from something
    # other than an ordinary shell.
    #
    # This has to happen before the terminal is asked anything. A cooked
    # terminal echoes the replies onto the screen and holds them in the line
    # discipline until a newline that never comes, so the queries appear to go
    # unanswered and then all arrive at once the moment raw mode is set.
    #
    # Idempotent: calling it again keeps the modes first found, not the raw
    # ones, so `#restore_modes` still has somewhere to go back to.
    def raw! : Nil
      fd = @input_fd
      return if @raw
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
      @raw = true
    end

    # Puts the line discipline back the way it was found. Idempotent, and safe
    # to call when raw mode was never entered.
    def restore_modes : Nil
      fd = @input_fd
      saved = @saved
      return unless fd && saved

      @saved = nil
      @raw = false

      # A fresh local, because `pointerof` goes by the declared type and the
      # ivar's includes nil however narrow the check above made it.
      original = saved
      LibC.tcsetattr fd, LibC::TCSANOW, pointerof(original)
    end
  end
end
