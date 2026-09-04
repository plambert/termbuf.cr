require "./core/region"
require "./sgr_scanner"
require "./terminal/command"
require "./unicode/grapheme"
require "./unicode/utf8"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # A place to write, and the state to write it in.
  #
  # A cursor is where streamed output goes: it holds a position, a `Style`, and
  # the `Region` it lives inside, and it works out which cell each grapheme
  # cluster lands in as text arrives. Wrapping and scrolling happen against the
  # region's edges, so a cursor bound to a pane behaves like a small terminal
  # inside that pane.
  #
  # It is not the terminal's own cursor. That one is a property of the device,
  # associated with a cursor of this kind through `Terminal#hardware_cursor=`
  # and moved to match it after each paint.
  #
  # A cursor is application-side state and emits the same commands the drawing
  # API does, so it needs no privileged access to the buffer and works against
  # a `Batcher` as readily as against a `Terminal`. Nothing here is fibre-safe:
  # a cursor belongs to whoever made it.
  class Cursor
    # Where drawing commands go.
    getter target : Drawing

    # The rectangle the cursor writes inside, and scrolls when it runs off the
    # bottom.
    getter region : Region

    # Column of the next cell to be written.
    getter x : Int32

    # Row of the next cell to be written.
    getter y : Int32

    # What subsequent text is written in.
    property style : Style

    # Whether text running past the right edge continues on the next row.
    #
    # With this off the cursor stops at the right margin and each further
    # character replaces the one standing there, which is what a terminal with
    # `DECAWM` reset does.
    property? autowrap : Bool

    # Whether a line feed on the bottom row scrolls the region. With this off
    # the cursor stays on the bottom row and writing there overwrites it.
    property? scrolls : Bool

    # Whether written text is scanned for escape sequences.
    #
    # Off by default. Turn it on for an application that changes appearance by
    # assigning to `#style` and never writes an escape sequence of its own: the
    # scan is skipped outright, which is worth having on the path that carries
    # every character.
    property? raw : Bool

    # Columns between tab stops, measured from the region's left edge.
    property tab_width : Int32

    # How clusters are measured, which has to match what the buffer being
    # written to uses or the cursor and the cells disagree about where the next
    # character goes. `Terminal#cursor` sets it from the buffer's.
    property policy : Unicode::WidthPolicy = Unicode::WidthPolicy::DEFAULT

    # The terminal's own cursor sits at the right margin after a character
    # lands in the last column, and only wraps when the next one arrives. That
    # delay is what stops a line of text exactly as wide as the region from
    # scrolling before anything needs the row below.
    @wrap_pending = false

    @scanner : SgrScanner?
    @io : CursorIO?
    @pending : IO::Memory
    @partial : IO::Memory
    @origin : Int32

    def initialize(@target : Drawing, @region : Region,
                   @style : Style = Style::DEFAULT,
                   raw : Bool = false,
                   autowrap : Bool = true,
                   scrolls : Bool = true,
                   @tab_width : Int32 = 8)
      raise ArgumentError.new "tab width #{@tab_width} is not positive" unless @tab_width > 0

      @raw = raw
      @autowrap = autowrap
      @scrolls = scrolls
      @x = @region.bounds.x
      @y = @region.bounds.y
      @origin = @x
      @pending = IO::Memory.new
      @partial = IO::Memory.new
    end

    # A cursor over the whole of a *columns* by *rows* screen.
    def self.full(target : Drawing, columns : Int32, rows : Int32,
                  scrollback : Int32 = 0) : Cursor
      new target, Region.new(Rect.full(columns, rows), scrollback)
    end

    # ------------------------------------------------------------ position

    # Puts the cursor at (*x*, *y*), in buffer coordinates, clamped to the
    # region. Coordinates are absolute everywhere in this shard, and a cursor
    # is no exception; `#home` is the one that speaks in the region's terms.
    def move_to(x : Int32, y : Int32) : Nil
      bounds = @region.bounds
      @x = x.clamp bounds.x, Math.max(bounds.right, bounds.x)
      @y = y.clamp bounds.y, Math.max(bounds.bottom, bounds.y)
      @wrap_pending = false
    end

    # Puts the cursor at the region's top left.
    def home : Nil
      move_to @region.bounds.x, @region.bounds.y
    end

    # Moves *columns* right and *rows* down, negative going the other way.
    def move_by(columns : Int32, rows : Int32) : Nil
      move_to @x + columns, @y + rows
    end

    # Back to the left edge of the region, staying on this row.
    def carriage_return : Nil
      @x = @region.bounds.x
      @wrap_pending = false
    end

    # Down one row, scrolling the region if there is nowhere further to go.
    def line_feed : Nil
      @wrap_pending = false
      bottom = @region.bounds.bottom

      if @y < bottom
        @y += 1
      elsif @scrolls
        @y = bottom
        scroll 1
      end
    end

    # A carriage return and a line feed, which is what a `\n` does here: the
    # terminal is in raw mode, so nothing else is going to add the return.
    def newline : Nil
      carriage_return
      line_feed
    end

    # Scrolls the region by *lines*, positive moving content up.
    #
    # The vacated rows take the cursor's background and nothing else. Carrying
    # the whole style would leave underlines and strike-throughs hanging in
    # empty space, and dropping the background as well would punch holes in a
    # tinted pane.
    def scroll(lines : Int32) : Nil
      flush
      @target.scroll_region @region, lines, Style::DEFAULT.bg(@style.background)
    end

    # ------------------------------------------------------------- writing

    # Writes *text*, one grapheme cluster per cell, wrapping and scrolling at
    # the region's edges.
    def print(text : String) : Nil
      return if text.empty?

      if @raw
        emit text, @style
      else
        @style = scanner.scan(text.to_slice, @style) { |run, style| emit run, style }
      end
    end

    # :ditto:
    def print(value) : Nil
      print value.to_s
    end

    # Writes *text* and then a newline.
    def puts(text : String = "") : Nil
      print text
      newline
    end

    # :ditto:
    def puts(value) : Nil
      puts value.to_s
    end

    # Writes UTF-8 *bytes*.
    #
    # A character split by the end of *bytes* is held until the rest of it
    # arrives, since a write boundary lands wherever the caller's buffer
    # happened to fill.
    def write(bytes : Bytes) : Nil
      return if bytes.empty? && @partial.bytesize.zero?

      data = joined bytes
      whole = Unicode.utf8_prefix data

      @partial.clear
      @partial.write data[whole..]

      print String.new(data[0, whole]) unless whole.zero?
    end

    # An `IO` that writes here, so `printf`, `Colorize`, and anything else
    # expecting an `IO` can be pointed at a region of the screen.
    def io : CursorIO
      @io ||= CursorIO.new self
    end

    # ------------------------------------------------------------ internals

    private def scanner : SgrScanner
      @scanner ||= SgrScanner.new
    end

    private def joined(bytes : Bytes) : Bytes
      return bytes if @partial.bytesize.zero?

      held = @partial.to_slice
      combined = Bytes.new held.size + bytes.size
      held.copy_to combined
      bytes.copy_to combined + held.size
      combined
    end

    # Hands whatever has been gathered to the buffer as one write. Runs are
    # gathered rather than written a cluster at a time because a command per
    # character would spend more time in the channel than in the buffer.
    private def flush(style : Style = @style) : Nil
      return if @pending.bytesize.zero?

      @target.write @origin, @y, @pending.to_s, style
      @pending.clear
    end

    private def emit(text : String, style : Style) : Nil
      return if @region.bounds.empty?

      Unicode.each_grapheme text, @policy do |grapheme|
        char = grapheme.char

        if char && control? char
          flush style
          control char
        else
          place grapheme, text, style
        end
      end

      flush style
    end

    private def control?(char : Char) : Bool
      char.in? '\n', '\r', '\t', '\b'
    end

    private def control(char : Char) : Nil
      case char
      when '\n' then newline
      when '\r' then carriage_return
      when '\t' then tab
      when '\b' then backspace
      end
    end

    # Tab stops move the cursor without erasing what it passes over, the same
    # as they do on a terminal.
    private def tab : Nil
      bounds = @region.bounds
      offset = @x - bounds.x
      @x = Math.min bounds.x + (offset // @tab_width + 1) * @tab_width, bounds.right
      @wrap_pending = false
    end

    private def backspace : Nil
      @x = Math.max @x - 1, @region.bounds.x
      @wrap_pending = false
    end

    private def place(grapheme : Unicode::Grapheme, source : String, style : Style) : Nil
      bounds = @region.bounds
      width = grapheme.width

      if @wrap_pending
        @wrap_pending = false
        # Either way the gathered run ends here: it either continues on the row
        # below, or the margin cell is about to be written over.
        flush style
        newline if @autowrap
      end

      if width > 0 && @x + width > bounds.right + 1
        flush style
        @autowrap ? newline : (@x = Math.max bounds.x, bounds.right - width + 1)
      end

      @origin = @x if @pending.bytesize.zero?
      @pending.write source.to_slice[grapheme.start, grapheme.bytesize]
      advance width, bounds
    end

    private def advance(width : Int32, bounds : Rect) : Nil
      return if width.zero?

      if @x + width - 1 >= bounds.right
        @x = bounds.right
        @wrap_pending = true
      else
        @x += width
      end
    end
  end

  # Stability: stable — changes only in a major release.
  #
  # An `IO` bound to a `Cursor`.
  #
  # Unbuffered by default, so what is written has reached the buffer by the time
  # the call returns and the next paint shows it. An application streaming
  # enough text for the command traffic to matter can set `sync = false`, which
  # gathers writes until a newline or a `#flush`.
  class CursorIO < IO
    include IO::Buffered

    # Where this writes.
    getter cursor : Cursor

    def initialize(@cursor : Cursor)
      self.sync = true
      self.flush_on_newline = true
      self.read_buffering = false
    end

    # Always raises. A cursor is somewhere to put text, not somewhere to get it.
    def unbuffered_read(slice : Bytes) : Int32
      raise IO::Error.new "a cursor cannot be read from"
    end

    def unbuffered_write(slice : Bytes) : Nil
      @cursor.write slice
    end

    def unbuffered_flush : Nil
    end

    def unbuffered_close : Nil
    end

    # Always raises, for the same reason as `#unbuffered_read`.
    def unbuffered_rewind : Nil
      raise IO::Error.new "a cursor cannot be rewound"
    end
  end
end
