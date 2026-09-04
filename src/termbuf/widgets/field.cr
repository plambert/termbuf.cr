require "../terminal/terminal"
require "./border"
require "./editor"
require "./paste_notice"

module TermBuf
  # A place to type, drawn through the same `Drawing` API an application uses.
  #
  # The field owns a rectangle and nothing else: it reports the height it would
  # like and where the terminal's cursor belongs, and the application decides
  # where to put it. That is the line between this and a layout manager, which
  # this shard does not have.
  class Field
    # What happens when the text outgrows one row.
    enum Growth
      # One row, scrolling sideways, with a marker where text runs off.
      Fixed

      # Wrap and grow to `Field#max_rows`, then scroll.
      Grow
    end

    # What sits in front of the text.
    record Prompt,
      text : String,
      style : Style = Style::DEFAULT,
      # What the rows after the first get, so a wrapped line stays aligned
      # under the one before it. Spaces the width of *text* when `nil`.
      continuation : String? = nil

    # Shown where text has run off the left or right of a fixed field.
    MARKERS = {'<', '>'}

    # Keys, bound to what they do to the text.
    getter editor : Editor

    # The whole panel, border included.
    property bounds : Rect

    # Drawn around the panel, or `nil` for none.
    property border : Border?

    # Drawn in front of the text, or `nil` for none.
    property prompt : Prompt?

    # What happens when the text outgrows one row.
    property growth : Growth

    # Rows the panel may grow to, border included.
    property max_rows : Int32

    # What the panel and its text are drawn in.
    property style : Style

    # What selected text is drawn in.
    property selection_style : Style

    # Shown instead of the text when there is none.
    property placeholder : String?
    # What the placeholder is drawn in.
    property placeholder_style : Style

    # Where the view has scrolled to: cells for a fixed field, rows for one
    # that grows.
    getter offset : Int32 = 0

    def initialize(@bounds : Rect,
                   @editor : Editor = Editor.new,
                   @border : Border? = nil,
                   @prompt : Prompt? = nil,
                   @growth : Growth = Growth::Fixed,
                   @max_rows : Int32 = 8,
                   @style : Style = Style::DEFAULT,
                   @selection_style : Style = Style::DEFAULT.reverse,
                   @placeholder : String? = nil,
                   @placeholder_style : Style = Style::DEFAULT.faint)
      @editor.multiline = @growth.grow?
    end

    # The line as it stands.
    def text : String
      @editor.text
    end

    # Replaces the line, ending any history walk.
    def text=(value : String) : String
      @editor.text = value
    end

    # The text being edited.
    def buffer : LineBuffer
      @editor.buffer
    end

    # ------------------------------------------------------------- events

    # Does whatever *key* is bound to. The view catches up at the next draw.
    def handle(key : Key) : Editor::Outcome
      @editor.handle key
    end

    # Pasted text goes in as text. A field with no room for a line break
    # flattens them rather than dropping the rest.
    def paste(text : String) : Editor::Outcome
      @editor.paste text
    end

    # ------------------------------------------------------------- layout

    # The area inside the border.
    def inner : Rect
      border = @border
      border ? border.inset(@bounds) : @bounds
    end

    # Cells the prompt takes on the first row.
    def prompt_width : Int32
      prompt = @prompt
      prompt ? Unicode.string_width(prompt.text) : 0
    end

    # Cells available for text, which the prompt eats into.
    #
    # The wider of the prompt and its continuation, so that a row is laid out
    # to fit under either and nothing overflows the one that is longer.
    def text_width : Int32
      Math.max inner.width - Math.max(prompt_width, continuation_width), 0
    end

    # Where each row of text starts and ends, in cluster indices.
    #
    # A fixed field is one row however long the text is. A growing one wraps at
    # the right edge and at every line break, and a cluster the terminal draws
    # double never straddles the edge: it moves down whole.
    def rows : Array(Range(Int32, Int32))
      return [0...buffer.size] if @growth.fixed?

      width = text_width
      return [0...buffer.size] if width < 1

      wrap width
    end

    private def wrap(width : Int32) : Array(Range(Int32, Int32))
      lines = [] of Range(Int32, Int32)
      start = 0
      used = 0
      index = 0

      while index < buffer.size
        cluster = buffer[index] || ""

        if cluster == LineBuffer::NEWLINE
          lines << (start...index)
          index += 1
          start = index
          used = 0
          next
        end

        cells = buffer.width_at index

        if used + cells > width && index > start
          lines << (start...index)
          start = index
          used = 0
        end

        used += cells
        index += 1
      end

      lines << (start...buffer.size)
      # A cursor after a row that is exactly full belongs on the next row, and
      # that row has to exist for it to go there.
      lines << (buffer.size...buffer.size) if used == width
      lines
    end

    # Which row the cursor is on and how many cells into it.
    def cursor_cell : {Int32, Int32}
      cursor = buffer.cursor
      lines = rows

      lines.each_with_index do |range, index|
        # At a soft wrap the cursor belongs to the row it will type into, which
        # is the lower one, not the end of the row above.
        next if cursor >= range.end && index < lines.size - 1

        return {index, buffer.width_between range.begin, cursor}
      end

      last = lines.size - 1
      {last, buffer.width_between lines[last].begin, cursor}
    end

    # Rows of text the field would like, before the border and any listing.
    def text_rows : Int32
      @growth.fixed? ? 1 : rows.size
    end

    # Rows the whole panel would like, border included, capped at `max_rows`.
    def desired_height : Int32
      padding = @border ? Border::PADDING : 0
      wanted = text_rows + listing_rows + padding

      Math.max Math.min(wanted, @max_rows), 1 + padding
    end

    private def listing_rows : Int32
      case @editor.completion
      in .listing?            then @editor.candidates.size + 1
      in .choices?, .nothing? then 1
      in .idle?, .inserted?   then 0
      end
    end

    # Keeps the cursor in view, scrolling by the least that does it.
    #
    # Recomputed at every draw rather than at every keystroke, because how much
    # is in view depends on the bounds and the bounds are the application's to
    # change. Doing it on a keystroke measures against the panel as it was
    # before it grew.
    def reflow : Nil
      scroll_into_view
    end

    private def scroll_into_view : Nil
      row, cell = cursor_cell
      width = text_width
      height = visible_rows

      if @growth.fixed?
        # A column is kept spare at each end for the markers, so that scrolling
        # into view does not put the cursor under one.
        room = Math.max width - 2, 1
        @offset = cell if cell < @offset
        @offset = cell - room if cell > @offset + room
        @offset = Math.max @offset, 0
      else
        @offset = row if row < @offset
        @offset = row - height + 1 if row >= @offset + height
        @offset = Math.max @offset, 0
      end
    end

    private def visible_rows : Int32
      padding = @border ? Border::PADDING : 0
      Math.max Math.min(inner.height, @max_rows - padding) - listing_rows, 1
    end

    # Where the terminal's own cursor belongs, in screen coordinates.
    def cursor_position : {Int32, Int32}
      area = inner
      row, cell = cursor_cell

      if @growth.fixed?
        x = area.x + prompt_width + cell - @offset
        {x.clamp(area.x, Math.max(area.right, area.x)), area.y}
      else
        indent = row.zero? ? prompt_width : continuation_width
        x = area.x + indent + cell
        y = area.y + row - @offset
        {x.clamp(area.x, Math.max(area.right, area.x)),
         y.clamp(area.y, Math.max(area.bottom, area.y))}
      end
    end

    private def continuation_width : Int32
      prompt = @prompt
      return 0 unless prompt

      continuation = prompt.continuation
      continuation ? Unicode.string_width(continuation) : prompt_width
    end

    # -------------------------------------------------------------- running

    # Owns the event loop until the line is accepted or abandoned, and hands
    # back what was entered or `nil`.
    #
    # For the case where a prompt is the only thing on screen. An application
    # with a loop of its own drives `#handle` and `#draw` from that instead.
    #
    # The field is placed at the bottom of the screen and follows a resize.
    # Pasted text goes in as text, and a paste worth noticing draws a
    # `PasteNotice` over the top.
    def run(terminal : Terminal) : String?
      notice = PasteNotice.new
      previous = terminal.hardware_cursor
      terminal.hardware_cursor = terminal.cursor

      begin
        loop do
          repaint terminal, notice
          outcome = step terminal, notice
          return @editor.accepted if outcome.accepted?
          return if outcome.cancelled? || outcome.ended?
        end
      ensure
        terminal.hardware_cursor = previous
      end
    end

    private def repaint(terminal : Terminal, notice : PasteNotice) : Nil
      # Every frame, because what the field wants changes as the text wraps and
      # as a listing opens under it.
      settle terminal.size

      terminal.batch do |screen|
        screen.clear
        draw screen
        notice.draw screen, Rect.full(terminal.size.columns, terminal.size.rows)
      end

      x, y = cursor_position
      terminal.cursor.move_to x, y
      terminal.paint
    end

    # Returns what handling the next event came to. Anything that is not input
    # leaves the field alone.
    private def step(terminal : Terminal, notice : PasteNotice) : Editor::Outcome
      event = terminal.events.receive?

      case event
      when Events::Key     then handle event.key
      when Events::Paste   then finish_paste notice, event.text
      when Events::Pasting then keep_waiting notice, event.bytes
      when Events::Resize  then Editor::Outcome::Continue
      when Events::Closed, Events::Failure, Nil
        Editor::Outcome::Ended
      else
        # A response, a warning, or an event another shard defined: none of
        # them are input, so the field is left alone.
        Editor::Outcome::Continue
      end
    end

    private def finish_paste(notice : PasteNotice, text : String) : Editor::Outcome
      notice.finished
      paste text
    end

    private def keep_waiting(notice : PasteNotice, bytes : Int32) : Editor::Outcome
      notice.arriving bytes
      Editor::Outcome::Continue
    end

    # Puts the field along the bottom of a screen this size, as tall as it
    # wants to be and no taller than there is room for.
    private def settle(size : ScreenSize) : Nil
      height = Math.min desired_height, size.rows
      @bounds = Rect.new 0, size.rows - height, size.columns, height
    end

    # ------------------------------------------------------------ drawing

    # Draws the panel, its border, its prompt, and as much of the text as
    # there is room for.
    def draw(screen : Drawing) : Nil
      return if @bounds.empty?

      reflow
      screen.fill @bounds, ' ', @style
      @border.try &.draw screen, @bounds

      area = inner
      return if area.empty?

      @growth.fixed? ? draw_fixed(screen, area) : draw_wrapped(screen, area)
      draw_listing screen, area
    end

    private def draw_fixed(screen : Drawing, area : Rect) : Nil
      draw_prompt screen, area.x, area.y, first: true
      left = area.x + prompt_width
      width = Math.max area.width - prompt_width, 0
      return if width.zero?

      return draw_placeholder screen, left, area.y, width if buffer.empty?

      # A marker each side, so what is off the edge is visible rather than
      # merely absent.
      ahead = buffer.width - @offset > width
      behind = @offset > 0

      screen.write_char left, area.y, MARKERS[0], @style.faint if behind
      inset = behind ? 1 : 0
      room = width - inset - (ahead ? 1 : 0)

      draw_clusters screen, left + inset, area.y, 0...buffer.size, @offset, room
      screen.write_char left + width - 1, area.y, MARKERS[1], @style.faint if ahead
    end

    private def draw_wrapped(screen : Drawing, area : Rect) : Nil
      lines = rows
      height = visible_rows
      shown = 0

      (@offset...lines.size).each do |index|
        break if shown >= height || shown >= area.height

        y = area.y + shown
        first = index.zero?
        draw_prompt screen, area.x, y, first
        indent = first ? prompt_width : continuation_width

        if buffer.empty? && first
          draw_placeholder screen, area.x + indent, y, area.width - indent
        else
          draw_clusters screen, area.x + indent, y, lines[index], 0,
            Math.max(area.width - indent, 0)
        end

        shown += 1
      end
    end

    private def draw_prompt(screen : Drawing, x : Int32, y : Int32, first : Bool) : Nil
      prompt = @prompt
      return unless prompt

      if first
        screen.write x, y, prompt.text, prompt.style
        return
      end

      continuation = prompt.continuation
      return unless continuation

      screen.write x, y, continuation, prompt.style
    end

    private def draw_placeholder(screen : Drawing, x : Int32, y : Int32, room : Int32) : Nil
      text = @placeholder
      return unless text && room > 0

      screen.write x, y, text, @placeholder_style
    end

    # Writes *range* starting at (*x*, *y*), skipping *skip* cells of it and
    # stopping after *room*. Clusters are gathered into runs of one style, so a
    # line with nothing selected costs one write rather than one per character.
    #
    # A cluster straddling either edge is left out rather than halved: there is
    # no half of a wide character to draw.
    private def draw_clusters(screen : Drawing, x : Int32, y : Int32,
                              range : Range(Int32, Int32), skip : Int32, room : Int32) : Nil
      return if room <= 0

      selection = buffer.selection
      column = 0
      run = String::Builder.new
      run_style = @style
      run_x = x

      range.each do |index|
        cells = buffer.width_at index
        start = column
        column += cells
        next if start < skip
        break if column - skip > room

        style = selection && selection.includes?(index) ? @selection_style : @style
        at = x + start - skip

        if run.bytesize.zero?
          run_x = at
          run_style = style
        elsif style != run_style
          screen.write run_x, y, run.to_s, run_style
          run = String::Builder.new
          run_x = at
          run_style = style
        end

        run << (buffer[index] || "")
      end

      text = run.to_s
      screen.write run_x, y, text, run_style unless text.empty?
    end

    private def draw_listing(screen : Drawing, area : Rect) : Nil
      top = area.y + visible_rows
      room = area.bottom - top + 1
      return if room <= 0

      # A completion that changed nothing has to say so, or a key that found
      # no match and a key that is not bound look exactly alike.
      case @editor.completion
      in .nothing?          then screen.write area.x + 1, top, "no match", @style.faint
      in .choices?          then screen.write area.x + 1, top, choices_note, @style.faint
      in .listing?          then draw_candidates screen, area, top, room
      in .idle?, .inserted? then return
      end
    end

    private def choices_note : String
      "#{@editor.candidates.size} matches, again to list"
    end

    private def draw_candidates(screen : Drawing, area : Rect, top : Int32,
                                room : Int32) : Nil
      candidates = @editor.candidates
      shown = Math.min candidates.size, room - 1

      shown.times do |index|
        screen.write area.x + 1, top + index, candidates[index], @style.faint
      end

      left = candidates.size - shown
      note = left.zero? ? "#{candidates.size} candidates" : "#{left} more"
      screen.write area.x + 1, top + shown, note, @style.faint if room > shown
    end
  end
end
