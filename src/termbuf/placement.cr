require "./core/rect"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # One showing of an image: which image, the cells it covers, and which of its
  # pixels it shows.
  #
  # A handle rather than a value. `#move`, `#z=` and `#crop=` change what is
  # on screen and send nothing but the new position, because the terminal
  # already has the pixels.
  #
  # One image may be on screen any number of times, each showing a different
  # part of it, which is how a sheet of sprites works. See `#crop`.
  class Placement
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

    # Whether this is still on screen. `#hide` is what takes one off, and
    # nothing can be done with it afterwards.
    getter? shown : Bool = true

    # Only the store builds one. A placement is a row in a store's idea of the
    # screen, and one made without the store knowing would name a placement id
    # the terminal has never heard of.
    protected def initialize(@image : Image, @id : UInt32, @bounds : Rect,
                             @z : Int32 = 0, @crop : Rect? = nil)
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

    # Takes this one showing off the screen and leaves the pixels at the far
    # end. Other placements of the same image stay where they are.
    def hide : Nil
      @image.store.hide self
    end

    # Set by the store, once, from `#hide`.
    protected def shown=(value : Bool) : Bool
      @shown = value
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
      io << " z=" << @z unless @z.zero?
      if window = @crop
        io << " of " << window
      end
      io << " hidden" unless @shown
      io << '>'
    end
  end
end
