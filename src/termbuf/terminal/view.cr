require "./command"

module TermBuf
  # A rectangle of another drawing surface, addressed from its own top left and
  # cut at its own edges.
  #
  # A panel drawn over other content has to stay inside its border, and the
  # arithmetic for that does not belong in every widget. A view is where it
  # goes: `(0, 0)` is the panel's top left corner, and anything reaching past
  # its edges is trimmed on the way through rather than landing on whatever is
  # beside it.
  #
  #     terminal.batch do |screen|
  #       draw_table screen
  #
  #       panel = screen.view Rect.new(10, 4, 30, 8)
  #       panel.fill panel.bounds, ' ', Style::DEFAULT.reverse
  #       panel.write 0, 0, "a line far longer than thirty cells"
  #     end
  #
  # Views nest: `view.view(inner)` is another view, so a border can hand what
  # it surrounds a surface of exactly the space left inside it. Everything
  # built on `Drawing` works against one.
  #
  # A view can also carry a `#style` that everything drawn through it merges
  # onto, which is what a highlighted row wants: fill it once, then write its
  # columns naming only what each one adds.
  #
  #     row = screen.view rect, style: Style::DEFAULT.bg(highlight)
  #     row.clear                                     # paints the highlight
  #     row.write 0, 0, name, Style::DEFAULT.bold     # bold, on the highlight
  #     row.write 24, 0, rate, Style::DEFAULT.faint
  #
  # A write that names a background of its own still wins. Nested views layer
  # the same way, each filling in what the one inside it left unset.
  #
  # This is clipping, not layering. Nothing here says a view is on top of
  # anything, and dismissing a panel means the next frame does not draw it —
  # the paint diff then sends the cells it covered and nothing else.
  #
  # Two commands pass through untouched, because neither is addressed in cells
  # of this view: `#passthrough`, which is aimed at the terminal, and
  # `#scroll_region`, since a `Region` carries its own rectangle in the
  # buffer's coordinates.
  class View
    include Drawing

    # Where clipped commands go: a `Terminal`, a `Batcher`, a `BufferSurface`,
    # or another view.
    getter target : Drawing

    # The rectangle this view covers, in *target*'s coordinates.
    getter rect : Rect

    # How clusters are measured when a write is trimmed. Set from whatever the
    # surface it was made from uses, so a cut falls where the buffer will put
    # the cells.
    property policy : Unicode::WidthPolicy = Unicode::WidthPolicy::DEFAULT

    # What everything drawn through the view merges onto: a field a write
    # leaves unset comes from here, and one it names wins. See `Style#merge`.
    property style : Style

    def initialize(@target : Drawing, @rect : Rect, @style : Style = Style::DEFAULT)
    end

    # The view's own rectangle, which starts at its origin rather than at the
    # target's. What to fill or pass on to something that wants an area.
    def bounds : Rect
      Rect.new 0, 0, @rect.width, @rect.height
    end

    # Cells across.
    def width : Int32
      @rect.width
    end

    # Rows down.
    def height : Int32
      @rect.height
    end

    # Trims *command* to the view and sends it on, or drops it when nothing of
    # it lands inside.
    def issue(command : Command) : Nil
      case command
      in Commands::Write     then clip_write command
      in Commands::WriteChar then clip_write_char command
      in Commands::Fill      then clip_fill command.rect, command.char, command.style
      in Commands::Clear     then clip_fill bounds, ' ', command.style
      in Commands::Scroll    then clip_scroll command
      in Commands::Blit      then clip_blit command
      in Commands::Batch     then command.commands.each { |inner| issue inner }
      in Commands::ScrollRegion, Commands::Passthrough, Commands::Invalidate,
         Commands::Paint, Commands::Resize, Commands::Apply, Commands::Stop
        @target.issue command
      end
    end

    private def clip_write(command : Commands::Write) : Nil
      return unless 0 <= command.y < @rect.height

      shown = clip_text command.text, command.x
      return unless shown

      start, text = shown
      @target.issue Commands::Write.new(@rect.x + start, @rect.y + command.y, text,
        styled(command.style))
    end

    # The part of *text* that lands inside the view when it is drawn at column
    # *x*, and the column that part starts at.
    #
    # A cluster crossing either edge is dropped whole, so a wide one cut by the
    # left edge leaves the visible run starting a column further in than the
    # cut did — which is why the column comes back rather than being worked out
    # from *x*.
    private def clip_text(text : String, x : Int32) : {Int32, String}?
      column = x
      first = 0
      start = nil.as(Int32?)
      stop = 0

      Unicode.each_grapheme text, @policy do |grapheme|
        after = column + grapheme.width

        if column >= 0 && after <= @rect.width
          if start.nil?
            start = grapheme.start
            first = column
          end

          stop = grapheme.start + grapheme.bytesize
        end

        column = after
        break if column >= @rect.width
      end

      return unless start

      {first, text.byte_slice(start, stop - start)}
    end

    private def clip_write_char(command : Commands::WriteChar) : Nil
      x = command.x
      return unless 0 <= x < @rect.width
      return unless 0 <= command.y < @rect.height

      # A wide character needs both its cells inside, the same rule the grid
      # applies at the screen edge.
      columns = Unicode.char_width command.char, @policy.ambiguous
      return if columns == 2 && x + 1 >= @rect.width

      @target.issue Commands::WriteChar.new(@rect.x + x, @rect.y + command.y,
        command.char, styled(command.style))
    end

    private def clip_fill(rect : Rect, char : Char, style : Style) : Nil
      area = rect.intersect bounds
      return if area.empty?

      @target.issue Commands::Fill.new(translate(area), char, styled(style))
    end

    private def clip_scroll(command : Commands::Scroll) : Nil
      area = command.rect.intersect bounds
      return if area.empty?

      @target.issue Commands::Scroll.new(translate(area), command.lines, styled(command.style))
    end

    private def clip_blit(command : Commands::Blit) : Nil
      taken = (command.from || command.source.bounds).intersect command.source.bounds
      return if taken.empty?

      placed = Rect.new(command.x, command.y, taken.width, taken.height).intersect bounds
      return if placed.empty?

      taken = Rect.new taken.x + (placed.x - command.x), taken.y + (placed.y - command.y),
        placed.width, placed.height

      @target.issue Commands::Blit.new(command.source, @rect.x + placed.x, @rect.y + placed.y, taken)
    end

    # *style* laid over the view's own. Most views carry none, so the common
    # case costs a comparison rather than a merge.
    private def styled(style : Style) : Style
      @style.default? ? style : @style.merge(style)
    end

    # A rectangle of this view, in the target's coordinates.
    private def translate(rect : Rect) : Rect
      Rect.new @rect.x + rect.x, @rect.y + rect.y, rect.width, rect.height
    end
  end
end
