require "../caps/capability"
require "./buffer"
require "./op"

module TermBuf
  # Works out the operations that bring the terminal from what it is showing to
  # what the application has drawn.
  #
  # Two passes. The first looks for whole bands of rows that merely moved, and
  # asks the terminal to scroll them rather than sending them again. The second
  # walks the rows that are still different and emits the changed runs.
  #
  # The painter mutates the buffer's front grid as it extracts scrolls, so that
  # the second pass diffs against the post-scroll state. That means the bytes it
  # returns have to actually reach the terminal; a caller that throws them away
  # must call `Buffer#invalidate` before painting again.
  class Painter
    # Roughly what a scroll costs in bytes: margins, the scroll itself, and
    # releasing the margins again.
    SCROLL_OVERHEAD = 24

    # Redrawing a row costs at least this much, so a scroll starts paying for
    # itself once it saves this many rows.
    ROW_COST = 12

    # What moving the cursor a short distance within a row costs. A gap of
    # unchanged cells cheaper than this to reprint is not worth skipping.
    MOVE_COST = 4

    # What changing style costs, near enough.
    STYLE_COST = 6

    # A trailing run of blanks longer than this is cheaper to erase than to
    # write spaces over.
    ERASE_THRESHOLD = 4

    # What the terminal can do, which decides whether a scroll or an erase is
    # available at all.
    getter capabilities : Capabilities

    def initialize(@capabilities : Capabilities)
    end

    # Changes what the painter may use. The next paint should be forced, since
    # what is on the terminal was drawn under the old mask.
    def capabilities=(capabilities : Capabilities) : Capabilities
      @capabilities = capabilities
    end

    # The operations that bring the terminal up to date. Empty when there is
    # nothing to do. The caller writes them out and then calls
    # `Buffer#commit_paint`.
    def paint(buffer : Buffer) : Array(Op)
      return [] of Op unless buffer.dirty?

      body = [] of Op
      extract_scrolls buffer, body
      paint_rows buffer, body
      return body if body.empty?

      framed = [] of Op
      synchronized = @capabilities.includes? Capability::SynchronizedOutput

      framed << Ops::BeginSync.new if synchronized
      framed << Ops::SetAutowrap.new false
      framed.concat body
      framed << Ops::SetAutowrap.new true
      framed << Ops::EndSync.new if synchronized
      framed
    end

    # ------------------------------------------------------------ scrolling

    private def extract_scrolls(buffer : Buffer, ops : Array(Op)) : Nil
      hints = buffer.take_scroll_hints
      return unless @capabilities.includes? Capability::ScrollRegion

      hints.each { |hint| consider_scroll buffer, hint, ops }
    end

    # A hint says the buffer scrolled a rectangle. Whether the terminal should
    # be asked to do the same turns on two things: that it *can* — the
    # terminal's margins run the full width, so a narrower rectangle is out —
    # and that it pays, meaning the shift brings enough rows into agreement to
    # beat the cost of the escape sequences.
    private def consider_scroll(buffer : Buffer, hint : ScrollHint, ops : Array(Op)) : Nil
      rect = hint.rect
      lines = hint.lines

      return unless rect.x.zero? && rect.width == buffer.width
      return if rect.height < 2
      return if lines.zero? || lines.abs >= rect.height
      return if scroll_benefit(buffer, rect, lines) * ROW_COST <= SCROLL_OVERHEAD

      emit_scroll buffer, rect, lines, ops
    end

    # How many more rows of the rectangle would agree after the shift than
    # agree now. Comparing row hashes rather than cells is what the grid keeps
    # them for.
    private def scroll_benefit(buffer : Buffer, rect : Rect, lines : Int32) : Int32
      before = 0
      after = 0

      rect.each_row do |row|
        before += 1 if buffer.front.row_hash(row) == buffer.back.row_hash(row)

        source = row + lines
        next unless rect.y <= source <= rect.bottom

        after += 1 if buffer.front.row_hash(source) == buffer.back.row_hash(row)
      end

      after - before
    end

    private def emit_scroll(buffer : Buffer, rect : Rect, lines : Int32,
                            ops : Array(Op)) : Nil
      whole_screen = rect.y.zero? && rect.height == buffer.height

      # The terminal fills the vacated rows with whatever background is in
      # force, and not every terminal honours a non-default one. Resetting
      # first makes every terminal fill with the default, which the row pass
      # then corrects wherever the buffer wanted something else.
      ops << Ops::SetStyle.new StyleTable::DEFAULT
      ops << Ops::SetScrollRegion.new rect.y, rect.bottom unless whole_screen
      ops << (lines > 0 ? Ops::ScrollUp.new(lines) : Ops::ScrollDown.new(-lines))
      ops << Ops::ResetScrollRegion.new unless whole_screen

      buffer.front.scroll rect, lines, Cell.blank(StyleTable::DEFAULT)
      buffer.front.damage.clear
    end

    # ----------------------------------------------------------- row diffing

    private def paint_rows(buffer : Buffer, ops : Array(Op)) : Nil
      buffer.damage.each { |row, span| paint_row buffer, row, span, ops }
    end

    private def paint_row(buffer : Buffer, row : Int32, span : Range(Int32, Int32),
                          ops : Array(Op)) : Nil
      first, last = changed_range buffer, row, span
      return unless start = first

      segments = merge_snapped buffer.back, row, build_segments(buffer, row, start, last)
      erase = trailing_erase buffer, row, segments

      if erase
        limit = erase[0]
        segments = segments.compact_map do |segment|
          next if segment.from >= limit

          segment.to < limit ? segment : Segment.new(segment.from, limit - 1)
        end
      end

      segments.each { |segment| emit_segment buffer, row, segment, ops }
      return unless tail = erase

      ops << Ops::MoveTo.new tail[0], row
      ops << Ops::SetStyle.new tail[1]
      ops << Ops::EraseInLine.new Ops::EraseMode::ToEnd
    end

    # The first and last columns of *span* where the two grids disagree.
    private def changed_range(buffer : Buffer, row : Int32,
                              span : Range(Int32, Int32)) : {Int32?, Int32}
      back = buffer.back
      front = buffer.front
      first = nil.as(Int32?)
      last = 0

      span.each do |column|
        next if back[column, row] == front[column, row]

        first ||= column
        last = column
      end

      {first, last}
    end

    # A run of columns to be rewritten in one go.
    private record Segment, from : Int32, to : Int32

    # Groups the changed columns into runs, absorbing a gap of unchanged cells
    # whenever reprinting it costs less than moving the cursor over it.
    private def build_segments(buffer : Buffer, row : Int32, start : Int32,
                               finish : Int32) : Array(Segment)
      back = buffer.back
      front = buffer.front
      segments = [] of Segment
      from = start
      previous = start
      column = start + 1

      while column <= finish
        if back[column, row] == front[column, row]
          column += 1
          next
        end

        gap = column - previous - 1

        if gap > 0 && gap_cost(back, row, previous, column) > MOVE_COST
          segments << Segment.new from, previous
          from = column
        end

        previous = column
        column += 1
      end

      segments << Segment.new from, previous
      segments
    end

    # What it costs to write the gap between the changed cells at *before* and
    # *after* rather than skip over it: the cells themselves, plus a style
    # change wherever the style shifts on the way through — including back to
    # whatever the following run needs.
    #
    # Charging for that last change unconditionally is what makes the common
    # case come out wrong: a short gap in the same style as its neighbours
    # needs no style change at all, and reprinting it beats a cursor move.
    private def gap_cost(back : Grid, row : Int32, before : Int32, after : Int32) : Int32
      cost = after - before - 1
      current = back[before, row].style

      (before + 1...after).each do |column|
        style = back[column, row].style
        next if style == current

        cost += STYLE_COST
        current = style
      end

      cost += STYLE_COST unless current == back[after, row].style
      cost
    end

    # Widens each segment so that it never begins on the second half of a wide
    # character or ends on the first, then merges any that now touch. Writing
    # half a wide character would leave the terminal's cursor and the buffer's
    # idea of it in different places.
    private def merge_snapped(back : Grid, row : Int32,
                              segments : Array(Segment)) : Array(Segment)
      merged = [] of Segment

      segments.each do |segment|
        from = segment.from
        to = segment.to

        while from > 0 && back[from, row].continuation?
          from -= 1
        end

        to += 1 if back[to, row].wide? && to + 1 < back.width

        if (previous = merged.last?) && from <= previous.to + 1
          merged[-1] = Segment.new previous.from, Math.max(previous.to, to)
        else
          merged << Segment.new from, to
        end
      end

      merged
    end

    # Where a trailing erase should start and the style to erase in, or `nil`
    # when writing the cells out is no worse.
    #
    # An erase only reliably reproduces the default background — terminals
    # disagree about whether it honours the current one — so a run tinted any
    # other colour has to be written out.
    private def trailing_erase(buffer : Buffer, row : Int32,
                               segments : Array(Segment)) : {Int32, StyleId}?
      last = segments.last?
      return unless last && last.to == buffer.width - 1

      back = buffer.back
      style = back[buffer.width - 1, row].style
      return unless erasable? buffer, style

      start = buffer.width - 1
      while start > last.from
        cell = back[start - 1, row]
        break unless cell.blank? && cell.style == style

        start -= 1
      end

      return unless buffer.width - start > ERASE_THRESHOLD

      # Only worth it if the cells being erased are actually stale.
      front = buffer.front
      stale = (start...buffer.width).any? { |column| back[column, row] != front[column, row] }
      return unless stale

      {start, style}
    end

    private def erasable?(buffer : Buffer, style : StyleId) : Bool
      resolved = buffer.styles[style]
      resolved.background.default? && !resolved.ink?
    end

    private def emit_segment(buffer : Buffer, row : Int32, segment : Segment,
                             ops : Array(Op)) : Nil
      back = buffer.back
      ops << Ops::MoveTo.new segment.from, row

      column = segment.from

      while column <= segment.to
        style = back[column, row].style
        finish = column

        while finish + 1 <= segment.to && back[finish + 1, row].style == style
          finish += 1
        end

        ops << Ops::SetStyle.new style
        ops << Ops::PutText.new run_text(buffer, row, column, finish), finish - column + 1
        column = finish + 1
      end
    end

    # The text of a run. Segments are snapped to whole characters, so every
    # continuation cell here belongs to a wide character already written.
    private def run_text(buffer : Buffer, row : Int32, from : Int32, to : Int32) : String
      back = buffer.back
      pool = buffer.clusters

      String.build do |io|
        (from..to).each do |column|
          cell = back[column, row]
          next if cell.continuation?

          io << cell.text(pool)
        end
      end
    end
  end
end
