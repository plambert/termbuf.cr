require "./termbuf/version"
require "./termbuf/unicode/grapheme"
require "./termbuf/core"
require "./termbuf/sgr_scanner"
require "./termbuf/cursor"
require "./termbuf/terminal"

# A terminal screen held in memory, repainted with a diff.
#
# An application draws into a buffer and asks for a paint. What reaches the
# terminal is the difference between what it is showing and what the buffer
# holds, encoded against what that particular terminal turned out to be able to
# do. Drawing the same frame twice sends nothing.
#
#     TermBuf::Terminal.open do |terminal|
#       terminal.batch do |screen|
#         screen.clear
#         screen.write 2, 1, "hello", TermBuf::Style::DEFAULT.bold
#       end
#       terminal.paint
#
#       terminal.events.receive
#     end
#
# ### The three layers
#
# `Terminal` is the one to reach for. It owns the device, runs a fibre that owns
# the buffer, and delivers keystrokes and resizes on `Terminal#events`.
#
# `Buffer`, `Painter`, and `Encoder` are that fibre's insides, usable on their
# own: a buffer of cells, a diff of what changed, and an encoding of that diff
# as escape sequences. Nothing in this layer touches a device, which is what
# makes it testable against a model terminal.
#
# `Capabilities` decides what the encoder may emit. It is settled once at
# startup from the environment, from asking the terminal directly, and from
# `TERMBUF_CAPS`; see `CapabilityResolver`.
#
# ### Drawing
#
# `Drawing` is the drawing API, mixed into both `Terminal` and `Batcher`.
# Coordinates are zero based from the top left. Text is placed one extended
# grapheme cluster per cell, and a cluster the terminal draws double width takes
# two — see `Unicode.string_width`.
#
# `Terminal#batch` collects a frame's drawing and sends it to the owning fibre
# as one channel operation, which is what a full redraw should use.
#
# ### Cursors
#
# A `Cursor` is somewhere to stream text to: a position, a `Style`, and the
# `Region` it wraps and scrolls inside. `Cursor#io` is an `IO`, so anything that
# writes to one can be pointed at a pane. `Terminal#hardware_cursor=` puts the
# terminal's own cursor wherever a chosen cursor is, after every paint.
#
# ### Input
#
# `Terminal#events` carries everything the terminal has to say. Keystrokes
# arrive as `Events::Key` with a decoded `Key`; text arrives as `Events::Paste`
# when it was pasted rather than typed; replies to queries the application
# registered with `Terminal#expect_response` arrive as `Events::Response`.
# See `Decoder` for what separates the three.
module TermBuf
end
