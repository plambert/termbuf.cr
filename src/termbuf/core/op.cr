require "./style_table"

module TermBuf
  # The vocabulary the painter emits and the encoder turns into bytes.
  #
  # Keeping the two apart is what makes the paint algorithm testable: a spec
  # can assert the structure of what was decided without pinning the exact
  # escape sequences, and pin the sequences separately where the byte count is
  # the point.
  #
  # The division of labour is that the painter says *what* goes where, and the
  # encoder works out how to say it in the fewest bytes. So the painter emits a
  # `MoveTo` before every run and a `SetStyle` for every run, and leaves it to
  # the encoder to drop the ones that are already true and to pick between
  # `CUP`, `CHA`, `CUF`, and a carriage return.
  module Ops
    # Put the cursor at (*x*, *y*).
    record MoveTo, x : Int32, y : Int32

    # Paint subsequent text in this style.
    record SetStyle, style : StyleId

    # Write *text* at the cursor, covering *columns* cells.
    record PutText, text : String, columns : Int32

    # How far an erase reaches from the cursor.
    enum EraseMode
      # From the cursor to the end of the line.
      ToEnd

      # From the start of the line to the cursor.
      ToStart

      # The whole line.
      All
    end

    # Erase part of the current line using the current background.
    record EraseInLine, mode : EraseMode

    # Erase *count* cells from the cursor, leaving the cursor where it is.
    record EraseChars, count : Int32

    # Confine scrolling to rows *top* through *bottom*, inclusive. The terminal
    # homes the cursor as a side effect.
    record SetScrollRegion, top : Int32, bottom : Int32

    # Release the scroll region back to the whole screen. Also homes the cursor.
    record ResetScrollRegion

    # Move the scroll region's content up *lines* rows, filling from the bottom.
    record ScrollUp, lines : Int32

    # Move the scroll region's content down *lines* rows, filling from the top.
    record ScrollDown, lines : Int32

    # Open *count* blank lines at the cursor's row, pushing the rest down.
    record InsertLines, count : Int32

    # Remove *count* lines at the cursor's row, pulling the rest up.
    record DeleteLines, count : Int32

    # Turn the terminal's own line wrapping on or off. The painter turns it off
    # for the duration of a paint, which removes the bottom-right corner
    # scrolling hazard rather than special-casing it.
    record SetAutowrap, enabled : Bool

    # Show or hide the terminal's own cursor.
    record SetCursorVisible, visible : Bool

    # Bracket the paint so the terminal shows the whole frame or none of it.
    record BeginSync

    # Close the frame, letting the terminal show it.
    record EndSync

    # Bytes to pass through untouched. Leaves the encoder's idea of the cursor
    # and style unknown, so the next operation re-establishes both.
    record Raw, bytes : Bytes
  end

  # One instruction for the encoder, as the painter emits them.
  alias Op = Ops::MoveTo | Ops::SetStyle | Ops::PutText | Ops::EraseInLine |
             Ops::EraseChars | Ops::SetScrollRegion | Ops::ResetScrollRegion |
             Ops::ScrollUp | Ops::ScrollDown | Ops::InsertLines | Ops::DeleteLines |
             Ops::SetAutowrap | Ops::SetCursorVisible | Ops::BeginSync | Ops::EndSync |
             Ops::Raw
end
