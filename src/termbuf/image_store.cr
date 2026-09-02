require "./image"

module TermBuf
  # The images a terminal is currently showing, and the sequences that put them
  # there.
  #
  # Images are not cells. The buffer knows nothing about them: they are drawn
  # over the screen after each frame's cells go out, and an application that
  # writes text where one sits gets both. That is the whole of the model, and it
  # is what `CLAUDE.md` asks for — placement and management, not compositing.
  #
  # Everything here needs `Capability::KittyGraphics`. Without it nothing is
  # sent and `#place` still returns a placement, so an application does not have
  # to branch on whether the terminal draws pictures.
  class ImageStore
    # The largest base64 payload one escape sequence may carry, from the
    # protocol. Anything longer is split across continuation chunks.
    CHUNK = 4096

    # Suppresses the terminal's replies. Without it every image draws an
    # acknowledgement that the input decoder would deliver as a keystroke
    # nobody pressed.
    QUIET = "q=2"

    APC = "\e_G"
    ST  = "\e\\"

    # What the terminal can do, which decides whether anything is sent at all
    # and which transport carries it.
    getter capabilities : Capabilities

    # Every placement on screen, oldest first.
    getter placements : Array(Placement)

    def initialize(@capabilities : Capabilities)
      @mutex = Mutex.new
      @images = {} of UInt32 => Image
      @placements = [] of Placement
      @next_image = 0_u32
      @next_placement = 0_u32
      @sent = Set(UInt32).new
      @files = [] of String
      @pending = [] of String
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

    # Registers *image* and returns the id the protocol refers to it by.
    #
    # Registering is not sending. The pixels go out the first time the image is
    # placed, and once only however many placements follow.
    def add(image : Image) : UInt32
      @next_image += 1
      @images[@next_image] = image
      @next_image
    end

    # Draws *image* over the cells of *bounds*, sending the pixels if this is
    # the first time it has been needed.
    def place(image : Image, bounds : Rect) : Placement
      place add(image), bounds
    end

    # :ditto:
    def place(image : UInt32, bounds : Rect) : Placement
      @next_placement += 1
      placement = Placement.new image, @next_placement, bounds
      @placements << placement
      draw placement
      placement
    end

    # Takes one image off the screen.
    def delete(placement : Placement) : Nil
      return unless @placements.delete placement

      emit "#{APC}a=d,d=i,i=#{placement.image},p=#{placement.id},#{QUIET}#{ST}"
    end

    # Takes every image off the screen and forgets them.
    def clear : Nil
      emit "#{APC}a=d,d=A,#{QUIET}#{ST}" unless @placements.empty?

      @placements.clear
      @sent.clear
      discard_files
    end

    # Sends every placement again, which is what a forced repaint needs: the
    # screen it is recovering from may have been cleared by something else.
    def redraw : Nil
      @sent.clear
      @placements.each { |placement| draw placement }
    end

    # Drops the placements that no longer fit on a screen this size. What is
    # left is redrawn by the next forced repaint.
    def resize(columns : Int32, rows : Int32) : Nil
      screen = Rect.full columns, rows
      @placements.reject! { |placement| !screen.contains? placement.bounds }
    end

    # --------------------------------------------------------------- sending

    private def draw(placement : Placement) : Nil
      return unless available?

      image = @images[placement.image]?
      return unless image

      # The cursor has to be where the image goes, and must not be moved by the
      # placement itself, or the encoder's idea of where it is stops being true.
      emit "\e[#{placement.y + 1};#{placement.x + 1}H"

      if @sent.includes? placement.image
        emit "#{APC}a=p,#{placement_keys placement}#{ST}"
        return
      end

      @sent << placement.image
      transmit image, placement
    end

    private def placement_keys(placement : Placement) : String
      "i=#{placement.image},p=#{placement.id}," \
      "c=#{placement.bounds.width},r=#{placement.bounds.height},C=1,#{QUIET}"
    end

    private def transmit(image : Image, placement : Placement) : Nil
      keys = "a=T,f=#{image.format.value},#{dimensions image}#{placement_keys placement}"

      return transmit_file image, keys if temp_file?

      transmit_direct image, keys
    end

    private def dimensions(image : Image) : String
      return "" if image.format.png?

      "s=#{image.width},v=#{image.height},"
    end

    # The pixels go through a file the terminal reads and then deletes itself,
    # which is what `t=t` means and why the path has to be a temporary one.
    private def transmit_file(image : Image, keys : String) : Nil
      path = File.tempname "termbuf", ".img"
      File.write path, image.pixels
      @files << path

      emit "#{APC}#{keys},t=t;#{Base64.strict_encode path}#{ST}"
    rescue IO::Error | File::Error
      # A temp directory that cannot be written to is not a reason to fail a
      # paint; the pixels go the long way instead.
      transmit_direct image, keys
    end

    # Base64 down the escape sequence, in chunks the protocol allows, with
    # `m=1` on everything but the last to say more is coming.
    private def transmit_direct(image : Image, keys : String) : Nil
      payload = Base64.strict_encode image.pixels
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
  end
end
