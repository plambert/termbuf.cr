require "./border"

module TermBuf
  # A panel saying a paste is arriving, so a long one does not look like a hung
  # application.
  #
  # The driver will not draw this. The buffer belongs to the application, and
  # something writing into it uninvited would have to undraw itself and would
  # fight whatever else was painting. So the decoder reports and this draws:
  # `Events::Pasting` opens it and `Events::Paste` closes it.
  #
  #     in TermBuf::Events::Pasting then notice.arriving event.bytes
  #     in TermBuf::Events::Paste   then notice.finished
  #
  # and `#draw` does nothing at all while nothing is arriving.
  class PasteNotice
    # Drawn around the panel, or `nil` for none.
    property border : Border?

    # What the panel is drawn in.
    property style : Style

    # What it says, before the byte count.
    property label : String

    # Bytes collected so far, or `nil` when nothing is arriving.
    getter bytes : Int32? = nil

    def initialize(@label : String = "pasting",
                   @style : Style = Style::DEFAULT.reverse,
                   @border : Border? = nil)
    end

    # A paste has been going long enough to be worth mentioning, and has *bytes*
    # so far.
    def arriving(bytes : Int32) : Nil
      @bytes = bytes
    end

    # The paste is over.
    def finished : Nil
      @bytes = nil
    end

    # Whether there is anything to draw.
    def visible? : Bool
      !@bytes.nil?
    end

    # What the panel says, which is the byte count as it grows.
    def text : String
      bytes = @bytes
      return @label unless bytes

      "#{@label} #{bytes} bytes"
    end

    # Draws centred within *area*, or nothing at all when no paste is arriving.
    def draw(screen : Drawing, area : Rect) : Nil
      return unless visible?
      return if area.empty?

      rect = centred area
      return if rect.empty?

      screen.fill rect, ' ', @style
      @border.try &.draw screen, rect

      inside = @border ? Border.inset(rect) : rect
      return if inside.empty?

      label = text
      x = inside.x + Math.max((inside.width - Unicode.string_width(label)) // 2, 0)
      screen.write x, inside.y + inside.height // 2, label, @style.bold
    end

    private def centred(area : Rect) : Rect
      padding = @border ? Border::PADDING : 0
      width = Math.min Unicode.string_width(text) + 4 + padding, area.width
      height = Math.min 3 + padding, area.height
      return Rect.new area.x, area.y, 0, 0 if width < 3 || height < 1

      Rect.new area.x + (area.width - width) // 2,
        area.y + (area.height - height) // 2,
        width, height
    end
  end
end
