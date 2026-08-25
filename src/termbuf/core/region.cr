require "./cell"
require "./rect"

module TermBuf
  # A rectangle of the buffer that scrolls as a unit, optionally keeping the
  # rows that scroll off it.
  #
  # Scrollback capacity defaults to zero, which is the classic curses model:
  # what scrolls away is gone. Give a region a capacity and it keeps that many
  # rows of history, so a log pane gets scrollback without the application
  # reimplementing it.
  class Region
    # The rectangle the region covers.
    getter bounds : Rect

    # Moves or resizes the region.
    #
    # What the screen-wide region a default cursor lives in needs when the
    # window changes size. A region an application placed itself keeps the
    # rectangle it was given; the buffer does not move regions about.
    def bounds=(bounds : Rect) : Rect
      @bounds = bounds
    end

    # How many scrolled-off rows to keep. Zero discards them.
    getter scrollback_capacity : Int32

    # Rows that have scrolled off the top, oldest first.
    getter scrollback : Deque(Array(Cell))

    @view_offset = 0
    @scrollback_capacity : Int32

    def initialize(@bounds : Rect, scrollback : Int32 = 0)
      raise ArgumentError.new "scrollback capacity #{scrollback} is negative" if scrollback < 0

      @scrollback_capacity = scrollback
      @scrollback = Deque(Array(Cell)).new
    end

    # How far back through the scrollback the region is being viewed: zero
    # shows live content, one shows the most recently scrolled-off row at the
    # top, and so on.
    getter view_offset : Int32

    # Scrolls the view back by *value* rows, clamped to what scrollback holds.
    def view_offset=(value : Int32) : Int32
      @view_offset = value.clamp 0, @scrollback.size
    end

    # Whether the region is showing history rather than live content.
    def scrolled_back? : Bool
      @view_offset > 0
    end

    # Keeps a row that has scrolled off the top. The slice is copied, so the
    # caller is free to overwrite it immediately.
    def push_scrollback(row : Slice(Cell)) : Nil
      return if @scrollback_capacity.zero?

      @scrollback.push row.to_a

      while @scrollback.size > @scrollback_capacity
        @scrollback.shift
      end

      # Holding the view still while new rows arrive means the offset has to
      # grow with them, otherwise the view drifts forward through history.
      @view_offset = Math.min(@view_offset + 1, @scrollback.size) if @view_offset > 0
    end

    # The scrolled-off row *distance* rows above the live content, where one is
    # the most recent. `nil` once the request runs past what is kept.
    def history(distance : Int32) : Array(Cell)?
      return unless 1 <= distance <= @scrollback.size

      @scrollback[@scrollback.size - distance]
    end

    # Throws away the history and returns the view to the live rows.
    def clear_scrollback : Nil
      @scrollback.clear
      @view_offset = 0
    end

    def to_s(io : IO) : Nil
      io << "Region(" << @bounds
      io << ", scrollback=" << @scrollback.size << '/' << @scrollback_capacity
      io << " at " << @view_offset if scrolled_back?
      io << ')'
    end
  end
end
