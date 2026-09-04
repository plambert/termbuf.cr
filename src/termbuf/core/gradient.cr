require "./color"
require "./rect"
require "./style"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # A colour ramp across a rectangle, handed to a draw call as a `Blend`.
  #
  # A gradient is not a field of `Style`: styles are interned by value, so
  # everything in one has to hash and compare, and a colour that depends on
  # where the cell is cannot. It is a position-aware blend instead — the one
  # thing in the drawing API that already takes a cell's coordinates.
  #
  #     ramp = TermBuf::Gradient.new Color.rgb(0x101820), Color.rgb(0x2060C0),
  #       screen.bounds, :vertical
  #     screen.clear TermBuf::Style::DEFAULT, blend: ramp.background
  #
  # A view can carry one instead, in which case the gradient is built against
  # `View#bounds` and the view translates each cell into its own coordinates
  # before asking. See `View#blend`.
  #
  # The colours it answers with are always `Color.rgb`, whatever the endpoints
  # were: the encoder narrows a 24 bit colour to the 256 colour cube or to the
  # sixteen system colours against the terminal's mask, so one gradient renders
  # everywhere and only the banding differs.
  #
  # Each cell's colour is a separate `Style`, and `StyleTable` only grows. A
  # gradient painted once, or repainted in the same colours, costs a style per
  # cell it covers and no more. One whose endpoints move every frame interns a
  # fresh set each time; an animation wanting that should step through a fixed
  # palette instead.
  struct Gradient
    # Which way the ramp runs.
    enum Axis
      # Left edge to right edge.
      Horizontal

      # Top edge to bottom edge.
      Vertical
    end

    # Colour at the rectangle's leading edge.
    getter from : Color

    # Colour at the rectangle's trailing edge.
    getter to : Color

    # The area the ramp is spread across. Positions outside it clamp to the
    # nearer end, so a gradient does not have to cover everything drawn
    # through it.
    getter rect : Rect

    # Which way the ramp runs.
    getter axis : Axis

    def initialize(@from : Color, @to : Color, @rect : Rect, @axis : Axis = Axis::Horizontal)
    end

    # The colour at (*x*, *y*): `#from` at the leading edge of `#rect`,
    # `#to` at the trailing one, linearly interpolated per channel in between
    # and clamped to the ends outside.
    #
    # An endpoint that is not already a 24 bit colour resolves through
    # `Color#channels` first, so a palette index or the terminal's default is
    # a usable end of a ramp.
    def at(x : Int32, y : Int32) : Color
      amount = fraction x, y
      start = @from.channels
      finish = @to.channels

      Color.rgb mix(start[0], finish[0], amount),
        mix(start[1], finish[1], amount),
        mix(start[2], finish[2], amount)
    end

    # A `Blend` setting the text colour of the style being written to `#at` for
    # the cell, leaving everything else in it alone.
    #
    # What is already in the cell is not consulted: a gradient decides by
    # position, and a write that also wants what was underneath should compose
    # this with `Style::OVER` by carrying one on a view and the other on the
    # draw call. See `View#blend`.
    def foreground : Blend
      gradient = self
      Blend.new { |_under, over, column, row| over.fg gradient.at(column, row) }
    end

    # A `Blend` setting the cell colour of the style being written to `#at`,
    # leaving everything else in it alone. What a tinted panel wants: fill it
    # through the gradient, then write over it naming only the text colour.
    def background : Blend
      gradient = self
      Blend.new { |_under, over, column, row| over.bg gradient.at(column, row) }
    end

    def to_s(io : IO) : Nil
      io << "Gradient(" << @from << " -> " << @to << ", " << @rect
      io << ", " << @axis << ')'
    end

    # How far along the ramp (*x*, *y*) falls, from zero at the leading edge to
    # one at the trailing edge.
    private def fraction(x : Int32, y : Int32) : Float64
      case @axis
      in .horizontal? then along x - @rect.x, @rect.width
      in .vertical?   then along y - @rect.y, @rect.height
      end
    end

    # *offset* cells into a run of *span*, as a fraction. The last cell of the
    # run is the far end rather than one step short of it, which is why the
    # divisor is a cell less than the span — and why a run of one cell is all
    # `#from` rather than a division by zero.
    private def along(offset : Int32, span : Int32) : Float64
      return 0.0 if span <= 1

      (offset.to_f / (span - 1)).clamp 0.0, 1.0
    end

    # One channel, *amount* of the way from *first* to *second*.
    private def mix(first : Int32, second : Int32, amount : Float64) : Int32
      (first + (second - first) * amount).round.to_i.clamp 0, 255
    end
  end
end
