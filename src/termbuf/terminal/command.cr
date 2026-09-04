require "../core/buffer"
require "../caps/screen_size"
require "./tty"

module TermBuf
  # Everything that mutates the buffer arrives as one of these.
  #
  # One fibre owns the buffer and nothing else touches it, so the public
  # drawing methods do not mutate anything: they build a command and hand it
  # over. That is what makes ordering total and locking unnecessary.
  module Commands
    # Text from (*x*, *y*) rightwards, one grapheme cluster per cell.
    record Write, x : Int32, y : Int32, text : String, style : Style,
      blend : Blend? = nil

    # One cluster at (*x*, *y*).
    record WriteChar, x : Int32, y : Int32, char : Char, style : Style,
      blend : Blend? = nil

    # Every cell of *rect* set to *char*.
    record Fill, rect : Rect, char : Char, style : Style, blend : Blend? = nil

    # The whole screen blanked.
    record Clear, style : Style, blend : Blend? = nil

    # *rect* moved by *lines* rows, positive moving content up.
    record Scroll, rect : Rect, lines : Int32, style : Style

    # As `Scroll`, but rows leaving the top go to the region's scrollback.
    record ScrollRegion, region : Region, lines : Int32, style : Style

    # Copy *from* of *source* onto this buffer at (*x*, *y*), or all of it when
    # *from* is nil.
    record Blit, source : Buffer, x : Int32, y : Int32, from : Rect?

    # Forget what the terminal is showing, so the next paint rewrites it all.
    record Invalidate

    # Bytes sent once the current frame is out that move no cursor and set no
    # attribute: a change to the terminal's own colours, a clipboard write.
    # Unlike `Passthrough` the encoder's idea of the screen survives them, so
    # the next frame carries on from where the last one left off.
    record Quiet, bytes : Bytes

    # Bytes to send to the terminal untouched, once the current frame is out.
    record Passthrough, bytes : Bytes

    # Draw. A *reply* channel makes the caller wait for the bytes to reach the
    # terminal and carries back anything that went wrong; without one the
    # command is fire and forget, which is what the frame scheduler wants.
    record Paint, forced : Bool, reply : Channel(Exception?)?

    # A terminal mode turned on or off, once the current frame is out. Like
    # `Quiet` these move no cursor and set no attribute, so the encoder's
    # idea of the screen survives them.
    record Mode, mode : Tty::Mode, enabled : Bool

    # The window changed size.
    record Resize, size : ScreenSize

    # Run arbitrary work against the buffer on the owning fibre. The escape
    # hatch for anything the command set does not cover, and the only safe way
    # to read the buffer from outside.
    record Apply, action : Buffer -> Nil, reply : Channel(Exception?)?

    # Several commands as one channel operation. A full redraw is thousands of
    # writes; sending them individually would spend more time in the channel
    # than in the buffer.
    record Batch, commands : Array(Command)

    # Restore the terminal and stop the owning fibre.
    record Stop, reply : Channel(Exception?)?
  end

  # Anything that can be sent to the owning fibre.
  alias Command = Commands::Write | Commands::WriteChar | Commands::Fill |
                  Commands::Clear | Commands::Scroll | Commands::ScrollRegion |
                  Commands::Blit | Commands::Invalidate | Commands::Passthrough |
                  Commands::Quiet | Commands::Mode | Commands::Paint |
                  Commands::Resize | Commands::Apply | Commands::Batch |
                  Commands::Stop

  # The drawing surface, shared by the terminal and by a batch being built.
  #
  # The two differ only in what they do with a command: one sends it, the other
  # collects it. Everything else about the API is the same, so it lives here
  # rather than being written twice and drifting apart.
  module Drawing
    # Sends *command* on, or collects it. What a `Terminal` and a `Batcher`
    # disagree about, and all they disagree about.
    abstract def issue(command : Command) : Nil

    # Writes *text* starting at (*x*, *y*), one grapheme cluster per cell,
    # stopping at the right edge of the row.
    #
    # With a *blend*, each cell gets the style the blend answers for it from
    # what is already there and *style* — `Style::KEEP_BACKGROUND` for a label
    # across a progress bar. See `Buffer#write` and `Blend`.
    def write(x : Int32, y : Int32, text : String, style : Style = Style::DEFAULT,
              blend : Blend? = nil) : Nil
      issue Commands::Write.new(x, y, text, style, blend)
    end

    # Writes one character at (*x*, *y*), settled by *blend* against what is
    # already in the cell when there is one.
    def write_char(x : Int32, y : Int32, char : Char, style : Style = Style::DEFAULT,
                   blend : Blend? = nil) : Nil
      issue Commands::WriteChar.new(x, y, char, style, blend)
    end

    # Sets every cell of *rect* to *char*, each cell's style settled by *blend*
    # against what is already there when there is one.
    def fill(rect : Rect, char : Char = ' ', style : Style = Style::DEFAULT,
             blend : Blend? = nil) : Nil
      issue Commands::Fill.new(rect, char, style, blend)
    end

    # Blanks the whole screen.
    def clear(style : Style = Style::DEFAULT, blend : Blend? = nil) : Nil
      issue Commands::Clear.new(style, blend)
    end

    # Scrolls *rect* by *lines* rows, positive moving content up.
    def scroll(rect : Rect, lines : Int32, style : Style = Style::DEFAULT) : Nil
      issue Commands::Scroll.new(rect, lines, style)
    end

    # Scrolls a region, keeping what leaves the top if it has scrollback.
    def scroll_region(region : Region, lines : Int32, style : Style = Style::DEFAULT) : Nil
      issue Commands::ScrollRegion.new(region, lines, style)
    end

    # Copies cells out of *source*, its top left landing at (*x*, *y*), taking
    # *from* of it or all of it. See `Buffer#blit`.
    #
    # The source is read when the command is serviced rather than when it is
    # issued, so a batched blit must not be followed by drawing into the same
    # source before the frame is painted.
    def blit(source : Buffer, x : Int32, y : Int32, from : Rect? = nil) : Nil
      issue Commands::Blit.new(source, x, y, from)
    end

    # A rectangle of this surface, addressed from its own top left and cut at
    # its own edges. Anything drawn through it merges onto *style*. See `View`.
    #
    # A *blend* settles the style of every cell drawn through the view, on top
    # of whatever a draw call brings of its own. **It is asked in the view's
    # coordinates**, `(0, 0)` at the view's top left, so a `Gradient` built
    # against the view's `bounds` lands where the view is — unlike the *blend*
    # of a draw call, which is asked in the buffer's. See `View#blend`.
    #
    #     ramp = Gradient.new(top, bottom, Rect.new(0, 0, rect.width, rect.height), :vertical)
    #     screen.view(rect, blend: ramp.background).clear
    def view(rect : Rect, style : Style = Style::DEFAULT, blend : Blend? = nil) : View
      made = View.new self, rect, style, blend
      made.policy = policy
      made
    end

    # Where this surface's `(0, 0)` falls in the buffer's coordinates. Zero for
    # everything that draws on a whole buffer; a `View` says where it sits, so
    # the blend it carries can be asked in its own coordinates.
    def origin : {Int32, Int32}
      {0, 0}
    end

    # How clusters are measured on this surface, which is what a `View` cuts
    # writes by. Surfaces that know which buffer they draw into say so.
    def policy : Unicode::WidthPolicy
      Unicode.policy
    end

    # Sends *bytes* to the terminal untouched, after the current frame.
    def passthrough(bytes : Bytes) : Nil
      issue Commands::Passthrough.new(bytes)
    end

    # :ditto:
    def passthrough(text : String) : Nil
      passthrough text.to_slice
    end
  end

  # A drawing surface that writes into a buffer as commands arrive.
  #
  # The core layer's answer to `Terminal`: everything built on `Drawing` works
  # against it, with no device, no fibres, and nothing to tear down afterwards.
  class BufferSurface
    include Drawing

    # What is being drawn on.
    getter buffer : Buffer

    def initialize(@buffer : Buffer)
    end

    # What the buffer being drawn into measures with.
    def policy : Unicode::WidthPolicy
      @buffer.policy
    end

    # Applies *command*, ignoring the ones that need a terminal to mean
    # anything.
    def issue(command : Command) : Nil
      if command.is_a? Commands::Batch
        command.commands.each { |inner| issue inner }
        return
      end

      BufferSurface.apply command, @buffer
    end

    # Applies the commands that need nothing but a buffer, and reports whether
    # *command* was one of them.
    #
    # A class method because the owning fibre needs the same lines and has its
    # own reasons to keep hold of the ones this leaves alone.
    def self.apply(command : Command, buffer : Buffer) : Bool
      case command
      in Commands::Write then buffer.write command.x, command.y, command.text,
        command.style, command.blend
      in Commands::WriteChar then buffer.write_char command.x, command.y, command.char,
        command.style, command.blend
      in Commands::Fill then buffer.fill command.rect, command.char, command.style,
        command.blend
      in Commands::Clear        then buffer.clear command.style, command.blend
      in Commands::Scroll       then buffer.scroll command.rect, command.lines, command.style
      in Commands::ScrollRegion then buffer.scroll_region command.region, command.lines, command.style
      in Commands::Blit         then buffer.blit command.source, command.x, command.y, command.from
      in Commands::Invalidate   then buffer.invalidate
      in Commands::Passthrough, Commands::Quiet, Commands::Mode, Commands::Paint,
         Commands::Resize, Commands::Apply, Commands::Batch, Commands::Stop
        return false
      end

      true
    end
  end

  # Collects drawing commands so a whole frame reaches the owning fibre as one
  # channel operation.
  class Batcher
    include Drawing

    # What has been collected so far, in the order it was drawn.
    getter commands = [] of Command

    # Collects *command* rather than sending it.
    def issue(command : Command) : Nil
      @commands << command
    end

    # Whether anything has been drawn.
    def empty? : Bool
      @commands.empty?
    end
  end
end
