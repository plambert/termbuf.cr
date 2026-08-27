require "./grapheme"
require "./policy"

module TermBuf::Unicode
  # Which end of a fitted string keeps its position when there is room to
  # spare.
  enum Align
    # Text first, padding after it.
    Left

    # Padding first, text after it.
    Right

    # Padding split either side, the odd cell going to the right.
    Center
  end

  # Fitting text to an exact number of terminal cells. Column layout is
  # arithmetic on cells, not on characters or bytes, and it has to run against
  # the same `WidthPolicy` the buffer measures with, or a table smears the
  # moment a name contains an emoji.
  #
  # Each of the four walks one grapheme cluster at a time and never splits one:
  # a double-width cluster that would half-cross the edge is left out whole, so
  # a result can come back a cell narrower than asked for. `fit` pads that cell
  # back; the others leave it.

  # Cuts *text* down to at most *width* cells, returning it unchanged when it
  # already fits. Nothing is added to mark the cut; see `.ellipsize` for that.
  def self.truncate(text : String, width : Int32, policy : WidthPolicy = Unicode.policy) : String
    return "" if width <= 0

    used = 0
    cut = 0

    each_grapheme text, policy do |grapheme|
      break if used + grapheme.width > width

      used += grapheme.width
      cut = grapheme.start + grapheme.bytesize
    end

    cut == text.bytesize ? text : text.byte_slice(0, cut)
  end

  # Cuts *text* down to at most *width* cells, marking the cut with *marker*.
  # The marker is measured under *policy* too, so the result is never wider
  # than *width*; when the marker alone will not fit, the text is cut without
  # one.
  def self.ellipsize(text : String, width : Int32, marker : String = "…",
                     policy : WidthPolicy = Unicode.policy) : String
    return "" if width <= 0
    return text if string_width(text, policy) <= width

    room = width - string_width(marker, policy)
    return truncate text, width, policy if room < 0

    truncate(text, room, policy) + marker
  end

  # Fits *text* to exactly *width* cells: cut when it is too long, padded with
  # *fill* when it is too short. A cluster dropped rather than split leaves a
  # cell over, which is padded like any other.
  def self.fit(text : String, width : Int32, align : Align = :left, fill : Char = ' ',
               policy : WidthPolicy = Unicode.policy) : String
    return "" if width <= 0

    shown = truncate text, width, policy
    room = width - string_width(shown, policy)
    return shown if room.zero?

    case align
    in .left?   then shown + padding(room, fill, policy)
    in .right?  then padding(room, fill, policy) + shown
    in .center? then padding(room // 2, fill, policy) + shown + padding(room - room // 2, fill, policy)
    end
  end

  # The *width* cells of *text* starting *offset* cells in — a horizontal
  # window over a value too wide to show at once. A cluster crossing either
  # edge is left out whole, and a window running past the end simply comes
  # back short. A negative *offset* is allowed and starts the window before the
  # text, which is what a marquee scrolling in from the left wants.
  def self.window(text : String, offset : Int32, width : Int32,
                  policy : WidthPolicy = Unicode.policy) : String
    return "" if width <= 0

    finish = offset + width
    start = nil.as(Int32?)
    stop = 0
    position = 0

    each_grapheme text, policy do |grapheme|
      after = position + grapheme.width

      if position >= offset && after <= finish
        start ||= grapheme.start
        stop = grapheme.start + grapheme.bytesize
      end

      position = after
      break if position >= finish
    end

    return "" unless start

    text.byte_slice start, stop - start
  end

  # *width* cells of *fill*. A fill character wider than one cell is repeated
  # only while it fits, the remainder going to spaces, so the run is exactly
  # the width asked for.
  private def self.padding(width : Int32, fill : Char, policy : WidthPolicy) : String
    return "" if width <= 0

    cells = char_width fill, policy.ambiguous
    return " " * width if cells < 1

    repeats = width // cells
    String.build(width) do |io|
      repeats.times { io << fill }
      (width - repeats * cells).times { io << ' ' }
    end
  end
end
