require "./core/rect"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # One showing of an image: which image, the cells it covers, and which of its
  # pixels it shows.
  #
  # A handle rather than a value. `#move`, `#z=`, `#crop=` and `#fit=` change
  # what is on screen and send nothing but the new position, because the terminal
  # already has the pixels.
  #
  # One image may be on screen any number of times, each showing a different
  # part of it, which is how a sheet of sprites works. See `#crop`.
  class Placement
    # What to do when the picture and the cells it was given are not the same
    # shape.
    enum Fit
      # Draw the whole picture inside those cells, at its own proportions, and
      # centre it in what it does not fill. The default, because a picture shown
      # in a box is a picture somebody wants to look at.
      Inside

      # Draw it across exactly those cells whatever that does to it. What a
      # backdrop wants, and what to say for a picture that is meant to be
      # stretched.
      Stretch
    end

    # Which image this shows.
    getter image : Image

    # Which showing of that image this is, by the id the protocol refers to it
    # with. Monotonic within a store and never reused.
    getter id : UInt32

    # The cells it covers.
    getter bounds : Rect

    # Where this sits in the stack against the text and the other placements.
    #
    # Zero is over the text, which is the default and what an image drawn to be
    # looked at wants. Negative is under it, so the cells keep their glyphs and
    # the picture shows through wherever they are blank — a chart behind a
    # table, a watermark. Higher covers lower among placements, so a cascade is
    # a rising *z* and nothing else.
    #
    # The protocol's own rule for the boundary: text is drawn between `-1` and
    # `0`, so `-1` is the topmost layer still beneath it.
    getter z : Int32

    # The rectangle of the image's own pixels this shows, or `nil` for all of
    # them. The protocol calls it the source rectangle.
    #
    # In image pixels, not cells: a `Rect` is a rectangle here and nothing about
    # a screen. A sheet of sprites is one image showing a different rectangle in
    # each place, and stepping an animation is `#crop=` and nothing else.
    #
    # Measured against ghostty 1.3.2, which records it from `x=`, `y=`, `w=` and
    # `h=` on a put and on a transmit-and-put alike, and reports the whole image
    # where they are left out.
    getter crop : Rect?

    # What to do when the picture and `#bounds` are not the same shape.
    getter fit : Fit

    # The cells the picture is actually drawn across.
    #
    # `#bounds` is what was asked for; this is what that came to. Under
    # `Fit::Inside` it is as large as the picture's own proportions allow inside
    # `#bounds`, centred in it, so a portrait cover in a wide box covers the
    # middle of it and no more. Under `Fit::Stretch` the two are the same.
    #
    # They are also the same where the fit could not be worked out, which is
    # where `ImageStore#cell_size` is unknown or the picture's own size is. See
    # `Fit`.
    getter drawn : Rect

    # Whether this is still on screen. `#hide` is what takes one off, and
    # nothing can be done with it afterwards.
    getter? shown : Bool = true

    # Only the store builds one. A placement is a row in a store's idea of the
    # screen, and one made without the store knowing would name a placement id
    # the terminal has never heard of.
    protected def initialize(@image : Image, @id : UInt32, @bounds : Rect,
                             @z : Int32 = 0, @crop : Rect? = nil,
                             @fit : Fit = Fit::Inside)
      # Until the store has measured it, which it does before anything goes out.
      @drawn = @bounds
    end

    # Whether this sits beneath the text rather than over it.
    def under_text? : Bool
      @z.negative?
    end

    # Column of the left edge.
    def x : Int32
      @bounds.x
    end

    # Row of the top edge.
    def y : Int32
      @bounds.y
    end

    # Puts the same pixels across different cells, sending the position and
    # nothing else.
    def move(bounds : Rect) : Nil
      return if bounds == @bounds

      @bounds = bounds
      repeat
    end

    # Moves this up or down the stack. See `#z`.
    #
    # Not `#raise`, which is what a widget toolkit would call it and what
    # Crystal calls something else entirely.
    def z=(value : Int32) : Int32
      return value if value == @z

      @z = value
      repeat
      value
    end

    # Shows a different rectangle of the image, or all of it for `nil`. See
    # `#crop`.
    def crop=(rect : Rect?) : Rect?
      return rect if rect == @crop

      @crop = rect
      repeat
      rect
    end

    # Draws the picture the other way in the same cells. See `Fit`.
    def fit=(value : Fit) : Fit
      return value if value == @fit

      @fit = value
      repeat
      value
    end

    # Takes this one showing off the screen and leaves the pixels at the far
    # end. Other placements of the same image stay where they are.
    def hide : Nil
      @image.store.hide self
    end

    # Set by the store, once, from `#hide`.
    protected def shown=(value : Bool) : Bool
      @shown = value
    end

    # Set by the store every time it works the geometry out, which is every time
    # anything about this placement changes.
    protected def drawn=(value : Rect) : Rect
      @drawn = value
    end

    # Sends the placement again, which is what changing one amounts to.
    #
    # A put naming an id the terminal already has replaces that placement
    # rather than adding one — measured against ghostty 1.3.2, where the
    # position, the cell count, the depth and the crop all follow the new put.
    # It replaces rather than patches, so every key goes again even where only
    # one of them changed.
    private def repeat : Nil
      @image.store.repeat self
    end

    def to_s(io : IO) : Nil
      io << "#<TermBuf::Placement i=" << @image.id << " p=" << @id
      io << " at " << @bounds
      io << " drawn " << @drawn unless @drawn == @bounds
      io << " z=" << @z unless @z.zero?
      io << ' ' << @fit.to_s.downcase unless @fit.inside?
      if window = @crop
        io << " of " << window
      end
      io << " hidden" unless @shown
      io << '>'
    end
  end
end
