require "base64"

require "./caps/capability"
require "./core/rect"
require "./pixels"
require "./image"
require "./placement"

module TermBuf
  # Stability: stable — changes only in a major release.
  #
  # A terminal's image registry: which pictures it has been given, where they
  # are on the screen, and the sequences that put them there.
  #
  # Images are not cells. The buffer knows nothing about them: they are drawn
  # over the screen after each frame's cells go out, and an application that
  # writes text where one sits gets both. That is the whole of the model:
  # registering, placement and management, not compositing.
  #
  # Everything here needs `Capability::KittyGraphics`. Without it nothing is
  # sent and every call still answers, so an application does not have to branch
  # on whether the terminal draws pictures.
  #
  # ### Three lifetimes
  #
  # `Pixels` are a value with no id and no terminal behind them. `#register`
  # turns one into an `Image`, which is an id the terminal will come to know.
  # `Image#show` turns that into a `Placement`, which is one showing of it.
  #
  #     cover = store.register Pixels.png(path)
  #     behind = cover.show Rect.new(0, 0, 40, 20), z: -1
  #
  # That placement is permanent. Nothing takes it off the screen until something
  # asks: a background picture behind a panel is put up once and forgotten
  # about, and `Terminal#close` takes it down along with the rest.
  #
  # ### A frame at a time
  #
  # A widget tree does not know what the last frame put up, only what this one
  # wants, so it says the whole of it every time. `#frame` is what keeps saying
  # so from costing anything:
  #
  #     store.frame do |frame|
  #       frame.show cover, box          # the pixels, once
  #     end
  #
  #     store.frame do |frame|
  #       frame.show cover, box          # nothing on the wire at all
  #     end
  #
  # Only what a `Frame` put up is diffed. A picture shown in the same cells is
  # taken back and sends no bytes; one whose box moved is repositioned rather
  # than sent again; one nobody asked for again comes off the screen, and its
  # pixels come out of the terminal with it. A placement made with `Image#show`
  # is not a frame's business and no frame touches it.
  class ImageStore
    # The largest base64 payload one escape sequence may carry, from the
    # protocol. Anything longer is split across continuation chunks.
    CHUNK = 4096

    # Suppresses the terminal's acknowledgements but not its complaints.
    #
    # `q=2` would silence both, and did: a path a terminal refused to read cost
    # an afternoon because the `EINVAL` explaining exactly why was thrown away.
    # A complaint is worth hearing, and more than worth it now that `#answered`
    # reads one: a terminal that has lost an image says so this way and no
    # other. `Terminal#images` registers a response pattern for these so one
    # arrives as an `Events::Response` rather than as a burst of keystrokes
    # nobody pressed.
    QUIET = "q=1"

    APC = "\e_G"
    ST  = "\e\\"

    # What a temporary file has to be called before a terminal will read it.
    #
    # The protocol says the file must be a temporary one, and terminals check
    # that rather than take the caller's word. Measured against ghostty 1.3.2,
    # which answers `EINVAL: temporary file not named correctly` for a path
    # with this string nowhere in it, and `EINVAL: temporary file not in temp
    # dir` for one outside the directory `TMPDIR` names — `/tmp` included,
    # which is not the temporary directory on a Mac.
    TEMP_MARKER = "tty-graphics-protocol"

    # What the terminal can do, which decides whether anything is sent at all
    # and which transport carries it.
    getter capabilities : Capabilities

    # How many pixels one cell measures, or `nil` where nothing has said.
    #
    # This is what a fit is worked out from: without it there is no telling
    # whether a box of cells is a wide rectangle or a tall one, and a picture
    # scaled against a guess comes out the wrong shape. A placement whose fit
    # cannot be worked out fills its box instead, which at least stays inside
    # what the application asked for. See `Placement#fit`.
    #
    # `Terminal#images` sets it from `TIOCGWINSZ`, which plenty of terminals
    # answer with zeroes. An application that knows better — because it asked the
    # terminal with a `CSI 16 t`, or because it was told — can set it here, and
    # every placement is measured again and put back.
    getter cell_size : {Int32, Int32}?

    def initialize(@capabilities : Capabilities)
      @mutex = Mutex.new
      @registry = {} of UInt32 => Image
      @screen = [] of Placement
      @owned = [] of Placement
      @held = [] of Placement
      @framing = false
      @next_image = 0_u32
      @next_placement = 0_u32
      @files = [] of String
      @pending = [] of String
      @lost = [] of UInt32
    end

    # Says how large a cell is, and puts every placement back at the size that
    # makes. See `#cell_size`.
    def cell_size=(size : {Int32, Int32}?) : {Int32, Int32}?
      return size if size == @cell_size

      @cell_size = size
      absorb_lost
      @screen.each { |placement| draw placement }
      size
    end

    # A path in the system temporary directory named so that a terminal will
    # read it. See `TEMP_MARKER`. Used by `Prober#probe_temp_file` too, so that
    # what is asked about and what is later sent are named the same way.
    def self.temp_path : String
      File.tempname "#{TEMP_MARKER}-termbuf", ".img"
    end

    # Everything queued since the last time this was asked, and empties the
    # queue.
    #
    # An application places an image on whatever fibre it draws from; the bytes
    # go out on the one that owns the buffer, after that frame's cells, so that
    # a picture sits over the text rather than under it.
    def take_pending : Array(String)
      @mutex.synchronize do
        taken = @pending
        @pending = [] of String
        taken
      end
    end

    # Whether anything is waiting to go out.
    def pending? : Bool
      @mutex.synchronize { !@pending.empty? }
    end

    # Whether the terminal draws images at all.
    def available? : Bool
      @capabilities.includes? Capability::KittyGraphics
    end

    # Whether the pixels travel through a file rather than through the escape
    # sequence. Settled by the probe at startup; a file is cheaper for anything
    # larger than a few kilobytes and impossible over ssh.
    def temp_file? : Bool
      @capabilities.includes? Capability::KittyGraphicsTempFile
    end

    # ------------------------------------------------------------- registering

    # Gives *pixels* an id and answers the `Image` that holds it.
    #
    # Nothing is sent. `Image#upload` sends the bytes and `Image#show` sends
    # them along with a position if they have not gone already.
    #
    # Registering the same pixels twice gives two images with two ids and two
    # copies at the far end. An application that wants one picture in two places
    # registers it once and shows it twice.
    def register(pixels : Pixels) : Image
      @next_image += 1
      image = Image.new self, @next_image, pixels
      @registry[image.id] = image
      image
    end

    # Every image the store still knows, oldest first.
    def images : Array(Image)
      @registry.values
    end

    # Every placement on screen, oldest first, whatever put it there.
    #
    # A copy, so hiding one while walking the list is safe.
    def placements : Array(Placement)
      @screen.dup
    end

    # ------------------------------------------------------------------ frames

    # Draws one frame's worth of pictures, and takes off whatever the last frame
    # put up and this one did not ask for again.
    #
    # `Frame#show` is the only thing inside the block that a frame owns. A
    # picture asked for in the same cells at the same depth showing the same
    # part of itself is taken back and **nothing at all is sent** for it, not
    # even the cursor move. One that moved is repositioned. One that nobody
    # asked for again is hidden, and an image left with no placements anywhere
    # is forgotten, which frees the pixels at the far end.
    #
    # Placements made with `Image#show` are left alone. They are the
    # application's to manage, which is what makes a background picture
    # something to put up and stop thinking about.
    #
    # Nesting raises: two open frames would diff against each other.
    #
    # A block that raises abandons its frame. Everything on screen goes back to
    # being the frame's, so the next one diffs against what is actually there.
    def frame(& : Frame ->) : Nil
      raise ArgumentError.new "a frame is already open" if @framing

      @framing = true
      absorb_lost
      @held = @owned
      @owned = [] of Placement

      begin
        yield Frame.new self
      rescue error
        @owned = @held + @owned
        @held = [] of Placement
        raise error
      ensure
        @framing = false
      end

      settle
    end

    # ---------------------------------------------------------------- managing

    # Takes every picture off the screen and every image out of the terminal.
    #
    # Every `Image` this store handed out is dead afterwards. `d=A` frees the
    # pixels as well as the placements — measured against ghostty 1.3.2, where
    # it leaves the registry empty, while `d=a` takes the placements and keeps
    # the pixels.
    def clear : Nil
      absorb_lost
      emit "#{APC}a=d,d=A,#{QUIET}#{ST}" unless @screen.empty? && @registry.empty?

      @screen.each &.shown=(false)
      @screen.clear
      @owned.clear
      @held.clear

      @registry.each_value do |image|
        image.uploaded = false
        image.forgotten = true
      end
      @registry.clear

      discard_files
    end

    # Sends everything again, which is what a forced repaint needs.
    #
    # Nothing is taken to be at the far end. The screen this is recovering from
    # may have been cleared by something else, and a `RIS` from another program
    # empties a terminal's whole registry — measured against ghostty 1.3.2,
    # which answers a reset with no images and no placements.
    def redraw : Nil
      absorb_lost

      held_before = @registry.each_value.select(&.uploaded?).to_a
      @registry.each_value &.uploaded=(false)

      # In screen order, so the first showing of each image carries its pixels
      # and the rest are positions. `#reput` is not wanted here: the walk is
      # already putting every placement back.
      @screen.each { |placement| draw placement }

      # An image whose bytes had gone but which is nowhere on screen was lost
      # too, and redrawing the placements did not bring it back.
      held_before.each { |image| upload image }
    end

    # Drops the placements that no longer fit on a screen this size.
    #
    # Nothing is sent: the terminal dropped them when the screen shrank under
    # them. The images stay registered and the far end keeps their pixels, so a
    # frame that asks for one at a size that fits only has to position it. What
    # is left is redrawn by the next forced repaint.
    def resize(columns : Int32, rows : Int32) : Nil
      screen = Rect.full columns, rows
      dropped = @screen.reject { |placement| screen.contains? placement.bounds }
      return if dropped.empty?

      dropped.each { |placement| drop placement }
    end

    # Takes account of one reply from the terminal.
    #
    # What matters in a reply is the terminal saying it has not got an image.
    # Measured against ghostty 1.3.2, a put naming an id it does not hold
    # answers `\e_Gi=99,p=1;ENOENT: image not found\e\\`, and `q=1` does not
    # suppress it — only `q=2` does, which is one reason this shard does not
    # send `q=2`. See `QUIET`.
    #
    # The id is marked as not uploaded, so the next `Image#show` sends the
    # pixels rather than putting a placement over nothing. This is not a corner:
    # kitty drops images when its cache fills, and a reset from another program
    # wipes them.
    #
    # Safe to call from whichever fibre reads the terminal. The id is queued and
    # taken account of on the fibre that owns the registry, the next time
    # anything would go out. `Terminal#images` calls this, so an application
    # driving a terminal has nothing to wire up.
    def answered(reply : Bytes) : Nil
      answered String.new reply
    end

    # :ditto:
    def answered(reply : String) : Nil
      id = complained_about reply
      return unless id

      @mutex.synchronize { @lost << id }
    end

    # ------------------------------------------------------- what Image asks for

    # Sends an image's pixels with no placement. See `Image#upload`.
    protected def upload(image : Image) : Nil
      check image
      absorb_lost
      return if image.uploaded?

      transmit image, nil
      reput image
    end

    # Puts an image on the screen. See `Image#show`.
    protected def show(image : Image, bounds : Rect, z : Int32, crop : Rect?,
                       fit : Placement::Fit) : Placement
      check image
      absorb_lost
      place image, bounds, z, crop, fit
    end

    # Takes every placement of an image off the screen. See `Image#hide`.
    protected def hide(image : Image) : Nil
      check image
      gone = @screen.select &.image.same?(image)
      return if gone.empty?

      gone.each { |placement| drop placement }

      # One sequence for all of them: a delete naming an image and no placement
      # takes every placement of it off and leaves the pixels — measured against
      # ghostty 1.3.2, where the image is still in the registry afterwards and a
      # later put draws it again.
      emit "#{APC}a=d,d=i,i=#{image.id},#{QUIET}#{ST}"
    end

    # Takes one placement off the screen. See `Placement#hide`.
    protected def hide(placement : Placement) : Nil
      return unless placement.shown?

      drop placement
      emit "#{APC}a=d,d=i,i=#{placement.image.id},p=#{placement.id},#{QUIET}#{ST}"
    end

    # Takes an image off the screen and out of the terminal. See `Image#forget`.
    protected def forget(image : Image) : Nil
      return if image.forgotten?

      @screen.select(&.image.same?(image)).each { |placement| drop placement }

      @registry.delete image.id
      image.uploaded = false
      image.forgotten = true

      # The capital frees the pixels along with the placements — measured
      # against ghostty 1.3.2, where `d=I` empties the registry entry and `d=i`
      # leaves it. Ids are never reused, so freeing one cannot take a later
      # image with it.
      emit "#{APC}a=d,d=I,i=#{image.id},#{QUIET}#{ST}"
    end

    # Sends a placement again after it moved. See `Placement#move`.
    protected def repeat(placement : Placement) : Nil
      return unless placement.shown?

      absorb_lost
      reput placement.image, except: placement if draw placement
    end

    # What `Frame#show` does. Kept here because the diffing is the store's.
    protected def frame_show(image : Image, bounds : Rect, z : Int32,
                             crop : Rect?, fit : Placement::Fit) : Placement
      check image

      if taken = take_held image, bounds, z, crop, fit
        @owned << taken
        return taken
      end

      placement = place image, bounds, z, crop, fit
      @owned << placement
      placement
    end

    # ---------------------------------------------------------------- the frame

    # Holds the last frame's placements over. Nothing is sent: a picture asked
    # for again is still on the screen and still in the right cells.
    private def settle : Nil
      return if @held.empty?

      gone = @held
      @held = [] of Placement
      gone.each { |placement| hide placement }

      # An image whose last placement just went is holding pixels at the far end
      # for a picture nobody is going to ask for again. Only the images this
      # frame took something off are considered, so one registered and uploaded
      # ahead of being shown is left alone.
      gone.each do |placement|
        image = placement.image
        next if image.forgotten? || placed? image

        forget image
      end
    end

    # A placement the last frame put up that is exactly what is being asked for,
    # taken off the held list so `#settle` leaves it alone.
    private def take_held(image : Image, bounds : Rect, z : Int32,
                          crop : Rect?, fit : Placement::Fit) : Placement?
      return if @held.empty?

      index = @held.index do |placement|
        placement.image.same?(image) && placement.bounds == bounds &&
          placement.z == z && placement.crop == crop && placement.fit == fit
      end
      return unless index

      @held.delete_at index
    end

    private def place(image : Image, bounds : Rect, z : Int32,
                      crop : Rect?, fit : Placement::Fit) : Placement
      @next_placement += 1
      placement = Placement.new image, @next_placement, bounds, z, crop, fit
      @screen << placement
      reput image, except: placement if draw placement
      placement
    end

    # Puts every showing of *image* back on the screen, leaving *except* alone.
    #
    # Sending pixels over an id the terminal is already holding takes every
    # placement of that id off the screen — measured against ghostty 1.3.2,
    # where a second transmission for a live id leaves the registry entry and no
    # placements at all. An image the terminal has lost has to be sent again, so
    # the rest of its showings have to go back with it. Nothing is sent where
    # there is nothing else to put back, which is the usual case.
    private def reput(image : Image, except : Placement? = nil) : Nil
      @screen.each do |placement|
        next unless placement.image.same? image
        next if except && placement.same? except

        draw placement
      end
    end

    # Takes a placement out of the store's idea of the screen. Sends nothing:
    # what to send about it, if anything, is the caller's to say.
    private def drop(placement : Placement) : Nil
      @screen.delete placement
      @owned.delete placement
      @held.delete placement
      placement.shown = false
    end

    private def placed?(image : Image) : Bool
      @screen.any? &.image.same?(image)
    end

    private def check(image : Image) : Nil
      raise ArgumentError.new "image #{image.id} was forgotten" if image.forgotten?
      return if image.store.same? self

      raise ArgumentError.new "image #{image.id} belongs to another store"
    end

    # --------------------------------------------------------------- answering

    # The image an error reply complains about, or `nil` for anything else.
    private def complained_about(reply : String) : UInt32?
      return unless reply.starts_with? APC

      keys, semicolon, message = reply.lchop(APC).rchop(ST).partition ';'
      # `OK` is the terminal saying it did what it was asked. Everything else is
      # a complaint, and every complaint naming an image is a reason to send the
      # pixels again.
      return if semicolon.empty? || message.strip == "OK"

      keys.split(',').each do |pair|
        name, _, value = pair.partition '='
        return value.to_u32? if name == "i"
      end
    end

    # Takes account of the ids queued by `#answered`.
    #
    # Called wherever bytes are about to go out, which is where being wrong
    # about what the far end holds would show.
    private def absorb_lost : Nil
      lost = @mutex.synchronize do
        next if @lost.empty?

        taken = @lost
        @lost = [] of UInt32
        taken
      end
      return unless lost

      lost.each do |id|
        image = @registry[id]?
        image.uploaded = false if image
      end
    end

    # --------------------------------------------------------------- sending

    # Puts one placement on the screen, sending the pixels first if the far end
    # has not got them. Answers whether the pixels went, because that takes the
    # image's other placements with it. See `#reput`.
    private def draw(placement : Placement) : Bool
      box, extent = measure placement
      placement.drawn = box
      return false unless available?

      # The cursor has to be where the image goes, and must not be moved by the
      # placement itself, or the encoder's idea of where it is stops being true.
      # Where a fit left cells over, this is the middle of the box rather than
      # its corner, which is the whole of the centring.
      emit "\e[#{box.y + 1};#{box.x + 1}H"

      image = placement.image
      if image.uploaded?
        emit "#{APC}a=p,#{placement_keys placement, extent}#{ST}"
        return false
      end

      transmit image, placement, extent
      true
    end

    # The cells a placement covers, and the `c=` or `r=` that puts it there.
    #
    # `Fit::Stretch` sends both, which fills the rectangle and distorts whatever
    # is not already its shape. `Fit::Inside` sends one, because a put given only
    # `c=` or only `r=` works the other side out itself and keeps the picture's
    # proportions: measured against ghostty 1.3.2, where an 8x32 image put with
    # `c=10` came out 80x320 pixels across 10x20 cells, with `r=4` came out 16x64
    # across 2x4, and with both keys came out 80x64 across the 10x4 it was told.
    # The key that goes is for whichever side runs out of room first, so what is
    # drawn never spills past the rectangle, and the cells left over are split to
    # centre it.
    #
    # A crop decides the proportions where there is one, since that is the part
    # being shown — also measured: `c=4` of a 16x16 crop of a 64x16 image came out
    # square.
    #
    # Filling is the fallback wherever the fit cannot be worked out: without
    # `#cell_size` there is no telling a wide box of cells from a tall one, and
    # without the picture's own size there is nothing to fit. Filling at least
    # stays inside the cells the application asked for, which naming one key
    # would not: the same 8x32 image put with `c=10` alone wants twenty rows.
    private def measure(placement : Placement) : {Rect, String}
      box = placement.bounds
      filled = {box, "c=#{box.width},r=#{box.height},"}
      return filled if placement.fit.stretch? || box.empty?

      cell = @cell_size
      return filled unless cell && cell[0] > 0 && cell[1] > 0

      shown = shown_size placement
      return filled unless shown

      room = {box.width * cell[0], box.height * cell[1]}
      # Cross-multiplied rather than divided, so nothing rounds before the
      # comparison: the picture is wider than the room if w/h > room_w/room_h.
      if shown[0] * room[1] >= shown[1] * room[0]
        across = box.width
        down = in_cells shown[1] * room[0] // shown[0], cell[1], box.height
        keys = "c=#{box.width},"
      else
        down = box.height
        across = in_cells shown[0] * room[1] // shown[1], cell[0], box.width
        keys = "r=#{box.height},"
      end

      {centred(box, across, down), keys}
    end

    # The pixels a placement shows: its crop, or the whole picture, or nothing at
    # all for a `Png` whose header would not parse.
    private def shown_size(placement : Placement) : {Int32, Int32}?
      if crop = placement.crop
        return crop.width > 0 && crop.height > 0 ? {crop.width, crop.height} : nil
      end

      pixels = placement.image.pixels
      return unless pixels.width > 0 && pixels.height > 0

      {pixels.width, pixels.height}
    end

    # How many cells *pixels* reach across, rounded up the way a terminal counts
    # them — measured against ghostty 1.3.2, where 200 pixels of a 16 pixel cell
    # came out thirteen cells and not twelve. Never more than the box and never
    # less than one.
    private def in_cells(pixels : Int32, cell : Int32, limit : Int32) : Int32
      ((pixels + cell - 1) // cell).clamp 1, limit
    end

    # *box* with a picture *across* by *down* cells in the middle of it, with any
    # odd cell left at the right or the bottom.
    private def centred(box : Rect, across : Int32, down : Int32) : Rect
      Rect.new box.x + (box.width - across) // 2, box.y + (box.height - down) // 2,
        across, down
    end

    private def placement_keys(placement : Placement, extent : String) : String
      # `z` is left out at zero rather than sent as `z=0`, which is what the
      # protocol defaults to: bytes on the wire for nothing said.
      depth = placement.z.zero? ? "" : "z=#{placement.z},"

      "i=#{placement.image.id},p=#{placement.id}," \
      "#{extent}#{crop_keys placement.crop}#{depth}C=1,#{QUIET}"
    end

    # The rectangle of the image a placement shows, in the image's own pixels,
    # or nothing at all for the whole of it. The protocol's source rectangle.
    private def crop_keys(crop : Rect?) : String
      return "" unless crop

      "x=#{crop.x},y=#{crop.y},w=#{crop.width},h=#{crop.height},"
    end

    # Sends an image's pixels, with a placement or without one.
    #
    # `a=T` transmits and puts in one sequence, which is what an application
    # that has just fetched a picture and wants it on screen now needs. `a=t`
    # transmits and puts nothing, which is what `Image#upload` is.
    private def transmit(image : Image, placement : Placement?,
                         extent : String = "") : Nil
      return unless available?

      pixels = image.pixels
      action = placement ? "a=T" : "a=t"
      tail = placement ? placement_keys(placement, extent) : "i=#{image.id},#{QUIET}"
      keys = "#{action},f=#{pixels.format.value},#{dimensions pixels}#{tail}"

      image.uploaded = true

      return transmit_file pixels, keys if temp_file?

      transmit_direct pixels, keys
    end

    private def dimensions(pixels : Pixels) : String
      return "" if pixels.format.png?

      "s=#{pixels.width},v=#{pixels.height},"
    end

    # The pixels go through a file the terminal reads and then deletes itself,
    # which is what `t=t` means and why the path has to be a temporary one.
    private def transmit_file(pixels : Pixels, keys : String) : Nil
      path = ImageStore.temp_path
      File.write path, pixels.bytes
      @files << path

      emit "#{APC}#{keys},t=t;#{Base64.strict_encode path}#{ST}"
    rescue IO::Error | File::Error
      # A temp directory that cannot be written to is not a reason to fail a
      # paint; the pixels go the long way instead.
      transmit_direct pixels, keys
    end

    # Base64 down the escape sequence, in chunks the protocol allows, with
    # `m=1` on everything but the last to say more is coming.
    private def transmit_direct(pixels : Pixels, keys : String) : Nil
      payload = Base64.strict_encode pixels.bytes
      offset = 0

      while offset < payload.bytesize
        chunk = payload[offset, CHUNK]
        offset += chunk.bytesize
        more = offset < payload.bytesize ? 1 : 0

        emit offset == chunk.bytesize ? "#{APC}#{keys},m=#{more};#{chunk}#{ST}" : "#{APC}m=#{more};#{chunk}#{ST}"
      end
    end

    # Files handed to a terminal that never read them. `t=t` makes the terminal
    # delete them, so this only catches the ones it declined.
    private def discard_files : Nil
      @files.each { |path| File.delete? path }
      @files.clear
    end

    private def emit(text : String) : Nil
      return unless available?

      @mutex.synchronize { @pending << text }
    end

    # One frame's worth of pictures.
    #
    # `#show` is the whole of it, and what it puts up is the frame's: taken back
    # for nothing if the next frame asks for the same thing, and taken off the
    # screen if it does not. A placement made through `Image#show` is nobody's
    # business but the application's.
    #
    # `#show` takes an `Image` and never `Pixels`, because registering inside a
    # frame would mint an id per frame and send the picture again every time.
    # Register once, where the picture arrives.
    class Frame
      # The registry this frame is drawing into.
      getter store : ImageStore

      # Only `ImageStore#frame` builds one. A frame outside that block would
      # diff against nothing.
      protected def initialize(@store : ImageStore)
      end

      # Asks for *image* across the cells of *bounds* for this frame.
      #
      # *z* decides what it sits over, *crop* which of the image's own pixels it
      # shows, and *fit* what to do when the picture is not the shape of the
      # cells. See `Placement#z`, `Placement#crop` and `Placement#fit`.
      def show(image : Image, bounds : Rect, z : Int32 = 0, crop : Rect? = nil,
               fit : Placement::Fit = Placement::Fit::Inside) : Placement
        @store.frame_show image, bounds, z, crop, fit
      end
    end
  end
end
