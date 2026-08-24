require "../core/buffer"
require "../caps/screen_size"

module TermBuf
  # Everything that mutates the buffer arrives as one of these.
  #
  # One fibre owns the buffer and nothing else touches it, so the public
  # drawing methods do not mutate anything: they build a command and hand it
  # over. That is what makes ordering total and locking unnecessary.
  module Commands
    # Text from (*x*, *y*) rightwards, one grapheme cluster per cell.
    record Write, x : Int32, y : Int32, text : String, style : Style

    # One cluster at (*x*, *y*).
    record WriteChar, x : Int32, y : Int32, char : Char, style : Style

    # Every cell of *rect* set to *char*.
    record Fill, rect : Rect, char : Char, style : Style

    # The whole screen blanked.
    record Clear, style : Style

    # *rect* moved by *lines* rows, positive moving content up.
    record Scroll, rect : Rect, lines : Int32, style : Style

    # As `Scroll`, but rows leaving the top go to the region's scrollback.
    record ScrollRegion, region : Region, lines : Int32, style : Style

    # Forget what the terminal is showing, so the next paint rewrites it all.
    record Invalidate

    # Bytes to send to the terminal untouched, once the current frame is out.
    record Passthrough, bytes : Bytes

    # Draw. A *reply* channel makes the caller wait for the bytes to reach the
    # terminal and carries back anything that went wrong; without one the
    # command is fire and forget, which is what the frame scheduler wants.
    record Paint, forced : Bool, reply : Channel(Exception?)?

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
                  Commands::Invalidate | Commands::Passthrough | Commands::Paint |
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
    def write(x : Int32, y : Int32, text : String, style : Style = Style::DEFAULT) : Nil
      issue Commands::Write.new(x, y, text, style)
    end

    # Writes one character at (*x*, *y*).
    def write_char(x : Int32, y : Int32, char : Char, style : Style = Style::DEFAULT) : Nil
      issue Commands::WriteChar.new(x, y, char, style)
    end

    # Sets every cell of *rect* to *char*.
    def fill(rect : Rect, char : Char = ' ', style : Style = Style::DEFAULT) : Nil
      issue Commands::Fill.new(rect, char, style)
    end

    # Blanks the whole screen.
    def clear(style : Style = Style::DEFAULT) : Nil
      issue Commands::Clear.new(style)
    end

    # Scrolls *rect* by *lines* rows, positive moving content up.
    def scroll(rect : Rect, lines : Int32, style : Style = Style::DEFAULT) : Nil
      issue Commands::Scroll.new(rect, lines, style)
    end

    # Scrolls a region, keeping what leaves the top if it has scrollback.
    def scroll_region(region : Region, lines : Int32, style : Style = Style::DEFAULT) : Nil
      issue Commands::ScrollRegion.new(region, lines, style)
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
