require "../caps/capability"
require "./buffer"
require "./damage"
require "./encoder"
require "./grid"
require "./painter"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # One output of a `Buffer`: what that output is believed to be showing, what
  # it has yet to be told, and the painter and encoder that tell it.
  #
  # The buffer holds the cells an application drew. Everything about *where*
  # they go lives here, so a second output — a web terminal, a recording, a
  # second window — is a second sink over the same buffer rather than a second
  # buffer kept in step with the first. Two sinks paint at different moments
  # and know different things about what their terminals can do, which is why
  # the front grid, the damage, the painter and the encoder all come in pairs
  # with them.
  #
  # A sink holds no IO. It turns a buffer into bytes; carrying them to a device
  # is the driver's job.
  #
  #     buffer = TermBuf::Buffer.new 80, 24
  #     sink = TermBuf::Sink.new buffer, TermBuf::Capabilities::XTERM
  #
  #     buffer.write 0, 0, "hello"
  #     bytes = sink.encoder.encode sink.paint
  #     sink.commit
  class Sink
    # The screen this sink paints.
    getter buffer : Buffer

    # What this sink's terminal can do.
    getter capabilities : Capabilities

    # What this sink's terminal is believed to be showing.
    getter front : Grid

    # What this sink has yet to paint. Its own, because a sink committing must
    # not tell another sink over the same buffer that its rows are clean.
    getter damage : Damage

    # Works out the operations. One per sink: the decisions it makes turn on
    # the capability mask and on what this front grid holds.
    getter painter : Painter

    # Turns those operations into bytes for this terminal.
    getter encoder : Encoder

    # The serial of the newest scroll hint this sink has read. See
    # `ScrollHint#serial`.
    getter consumed_serial : Int64

    # What the cell a forced repaint leaves in the front grid holds: a
    # character no buffer can contain, so every cell compares unequal and the
    # next paint rewrites the screen.
    UNKNOWN = Cell.new '￿', StyleTable::DEFAULT, 1_u8

    def initialize(@buffer : Buffer, @capabilities : Capabilities)
      @front = Grid.new @buffer.width, @buffer.height
      @damage = Damage.new @buffer.height
      @painter = Painter.new @capabilities
      @encoder = Encoder.new @buffer.styles, @capabilities, @buffer.width, @buffer.height,
        @buffer.links
      @consumed_serial = @buffer.scroll_serial
      @buffer.attach self
    end

    # Where to leave the terminal's own cursor when the frame ends, or `nil` to
    # leave it hidden. See `Painter#hardware_cursor`.
    def hardware_cursor : {Int32, Int32}?
      @painter.hardware_cursor
    end

    # :ditto:
    def hardware_cursor=(position : {Int32, Int32}?) : {Int32, Int32}?
      @painter.hardware_cursor = position
    end

    # Whether to write the cell after a glyph that may have painted outside its
    # own columns. See `Painter#clear_overhang?`.
    def clear_overhang? : Bool
      @painter.clear_overhang?
    end

    # :ditto:
    def clear_overhang=(value : Bool) : Bool
      @painter.clear_overhang = value
    end

    # Whether to watch for a cluster this terminal will put in the wrong place.
    # See `Painter#watch_composed_drift?`.
    def watch_composed_drift? : Bool
      @painter.watch_composed_drift?
    end

    # :ditto:
    def watch_composed_drift=(value : Bool) : Bool
      @painter.watch_composed_drift = value
    end

    # The cluster this terminal was found to misplace, and forgets it. See
    # `Painter#take_composed_drift`.
    def take_composed_drift : String?
      @painter.take_composed_drift
    end

    # Replaces what this sink may use. The next paint should be forced, since
    # what is on the terminal was drawn under the old mask.
    def capabilities=(capabilities : Capabilities) : Capabilities
      @capabilities = capabilities
      @painter.capabilities = capabilities
      @encoder.capabilities = capabilities
      capabilities
    end

    # Whether this sink has anything to paint.
    def dirty? : Bool
      @damage.dirty? || @consumed_serial < @buffer.scroll_serial
    end

    # Whether the front grid holds what the application drew, which is to say a
    # paint would emit no cells.
    def painted? : Bool
      @buffer.back == @front
    end

    # The operations that bring this sink's terminal up to date. Empty when
    # there is nothing to do. The caller encodes them, writes them out, and
    # then calls `#commit`.
    #
    # *forced* throws away what the terminal was believed to be showing first,
    # so the frame rewrites every cell.
    def paint(forced : Bool = false) : Array(Op)
      if forced
        invalidate
        reset_state
      end

      @painter.paint @buffer, self
    end

    # Brings the front grid up to date after a paint has been written out, and
    # clears the damage and the scroll hints it was built from.
    def commit : Nil
      @front.copy_from @buffer.back
      @damage.clear
      @consumed_serial = @buffer.scroll_serial
      @buffer.settled
    end

    # The scroll hints this sink has not read yet, oldest first. Reading them
    # is what lets the buffer forget them.
    def take_scroll_hints : Array(ScrollHint)
      taken = @buffer.scroll_hints_since @consumed_serial
      @consumed_serial = @buffer.scroll_serial
      taken
    end

    # Forgets what this terminal was showing, so the next paint rewrites every
    # cell. Any scroll hint goes with it: a screen being redrawn outright has
    # nothing to scroll.
    def invalidate : Nil
      @front.clear UNKNOWN
      @front.damage.clear
      @damage.touch_all @buffer.width
      @consumed_serial = @buffer.scroll_serial
    end

    # Forgets what the terminal was last told about its cursor and style, so
    # the next frame says both again.
    def reset_state : Nil
      @painter.reset_state
      @encoder.reset_state
    end

    # Follows the buffer to a new size. Called by `Buffer#resize`, which has
    # already resized the back grid and this sink's damage with it.
    def resize(columns : Int32, rows : Int32, blank : Cell = Cell.blank) : Nil
      @front.resize columns, rows, blank
      @encoder.resize columns, rows
      @painter.reset_state
    end

    # Stops painting the buffer. A detached sink keeps what it was showing but
    # is told nothing further.
    def detach : Nil
      @buffer.detach self
    end
  end
end
