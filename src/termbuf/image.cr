require "./pixels"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # One image in a terminal's registry: an id the protocol refers to it by, and
  # the pixels behind that id.
  #
  # Registering, uploading and showing are three things, and an application can
  # do them at three different times:
  #
  #     cover = store.register Pixels.png(path)   # an id, and nothing sent
  #     cover.upload                              # the bytes, no placement
  #     here = cover.show Rect.new(2, 1, 20, 12)  # on screen
  #     there = cover.show Rect.new(40, 1, 20, 12), z: -1
  #     here.move Rect.new(4, 1, 20, 12)          # no bytes but the position
  #     cover.forget                              # both ends, and it is dead
  #
  # `#upload` is optional. `#show` sends the pixels itself the first time, which
  # is what an application that has just fetched a picture and wants it on
  # screen now should do.
  #
  # An `Image` outlives the frames drawn around it. One shown with `#show`
  # stays until something takes it off: no `ImageStore::Frame` touches it, which
  # is what makes a background picture behind a panel something to put up and
  # forget about. `ImageStore#clear` takes those down, and so does giving the
  # terminal back.
  class Image
    # The id the protocol refers to this image by.
    #
    # Monotonic within a store and never reused, so a sequence naming a
    # forgotten id can never land on a later image.
    getter id : UInt32

    # The bytes behind the id.
    getter pixels : Pixels

    # The registry this belongs to.
    getter store : ImageStore

    # Whether the far end is holding the bytes.
    #
    # False until something sends them, and false again once the terminal says
    # it has lost them. See `ImageStore#answered`.
    getter? uploaded : Bool = false

    # Whether this image is dead. `#forget` is what kills one, and nothing can
    # be done with it afterwards.
    getter? forgotten : Bool = false

    # Only `ImageStore#register` builds one. An `Image` is a row in a store's
    # registry, and one made without the store knowing would name an id the
    # terminal has never heard of.
    protected def initialize(@store : ImageStore, @id : UInt32, @pixels : Pixels)
    end

    # Sends the pixels without putting them anywhere, so a later `#show` is a
    # position and nothing more.
    #
    # Nothing is sent if the far end already has them. That is not only
    # economy: measured against ghostty 1.3.2, a transmission over an id the
    # terminal already holds takes every placement of that id off the screen.
    def upload : Nil
      @store.upload self
    end

    # Puts the pixels across the cells of *bounds*, sending them first if the
    # far end has not got them.
    #
    # *z* decides what this sits over. See `Placement#z`.
    #
    # *crop* shows a rectangle of the image's own pixels rather than all of
    # them, which is how one sheet of sprites shows a different cell in each of
    # several places. See `Placement#crop`.
    #
    # *fit* says what to do when the picture is not the shape of the cells it was
    # given. The whole picture goes inside them at its own proportions unless
    # something asks for it stretched across them. See `Placement#fit`.
    def show(bounds : Rect, z : Int32 = 0, crop : Rect? = nil,
             fit : Placement::Fit = Placement::Fit::Inside) : Placement
      @store.show self, bounds, z, crop, fit
    end

    # Everywhere this image is on screen, oldest first.
    def placements : Array(Placement)
      @store.placements.select &.image.same?(self)
    end

    # Takes the image off the screen everywhere and leaves the pixels at the far
    # end, so showing it again costs a position and no more.
    def hide : Nil
      @store.hide self
    end

    # Takes the image off the screen and the pixels out of the terminal.
    #
    # The image is dead afterwards: `#show` on it raises, and the store has
    # forgotten it. Registering the same pixels again mints a new id.
    def forget : Nil
      @store.forget self
    end

    # Set by the store when the bytes go out, and unset when the terminal says
    # it has lost them or when a forced repaint gives up on what is there.
    protected def uploaded=(value : Bool) : Bool
      @uploaded = value
    end

    # Set by the store, once, from `#forget`.
    protected def forgotten=(value : Bool) : Bool
      @forgotten = value
    end

    def to_s(io : IO) : Nil
      io << "#<TermBuf::Image i=" << @id
      io << " " << @pixels.format
      io << (@uploaded ? " uploaded" : " not uploaded")
      io << " forgotten" if @forgotten
      io << '>'
    end
  end
end
