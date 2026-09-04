require "./termbuf/version"
require "./termbuf/unicode/grapheme"
require "./termbuf/unicode/text"
require "./termbuf/unicode/overrides"
require "./termbuf/core"
require "./termbuf/sgr_scanner"
require "./termbuf/color_stack"
require "./termbuf/clipboard"
require "./termbuf/image_store"
require "./termbuf/cursor"
require "./termbuf/input"
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
# `Buffer` and `Sink` are that fibre's insides, usable on their own: a buffer of
# cells, and one output of it holding what that terminal is believed to be
# showing along with the `Painter` and `Encoder` that get it there. A second
# sink over the same buffer is a second display, painted independently.
# Nothing in this layer touches a device, which is what makes it testable
# against a model terminal.
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
# two — see `Unicode.string_width`. `Unicode.truncate`, `Unicode.ellipsize`,
# `Unicode.fit`, and `Unicode.window` fit a string to a column width under the
# same measurement.
#
# `Terminal#batch` collects a frame's drawing and sends it to the owning fibre
# as one channel operation, which is what a full redraw should use.
#
# `Drawing#view` gives back a rectangle of a surface addressed from its own top
# left and cut at its own edges, which is what a panel drawn over other content
# wants. `Buffer` and `BufferSurface` need no terminal at all, and
# `Buffer#blit` copies one buffer's cells into another, so a shard wanting to
# composite its own off-screen panels has what it needs.
#
# ### Cursors
#
# A `Cursor` is somewhere to stream text to: a position, a `Style`, and the
# `Region` it wraps and scrolls inside. `Cursor#io` is an `IO`, so anything that
# writes to one can be pointed at a pane. `Terminal#hardware_cursor=` puts the
# terminal's own cursor wherever a chosen cursor is, after every paint.
#
# A region an application made keeps the rectangle it was given; only the
# screen-wide one follows the window. `Terminal#on_resize` is where an
# application states its layout once rather than at every `Events::Resize`.
#
# ### Input
#
# `Terminal#events` carries everything the terminal has to say. Keystrokes
# arrive as `Events::Key` with a decoded `Key`; text arrives as `Events::Paste`
# when it was pasted rather than typed; replies to queries the application
# registered with `Terminal#expect_response` arrive as `Events::Response`.
# See `Decoder` for what separates the three, and `Input::Stream` for the
# fibres that run it. An application wanting a reply as something other than
# its bytes registers with `Input::Patterns` itself.
#
# All of it lives under `TermBuf::Input` and depends on nothing else here,
# because it is on its way out into a `termbuf-input` shard. `Key` is
# `Input::Key`, `Events::Key` is `Input::Events::Key`, and so on for every name
# on the input side: the short spellings are aliases and are not going
# anywhere. The one event that stayed behind is `Events::Resize`, which carries
# a `ScreenSize` and so belongs to the terminal rather than to the keyboard.
module TermBuf
end
