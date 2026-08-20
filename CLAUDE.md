# TermBuf shard

This shard implements a low-level interface for terminal/console applications to decouple the
terminal UI from the application code, by creating a terminal buffer that is then repainted using an
algorithm to reduce the updates.

## ANSI and other terminal control code support

### Terminal Queries

It should attempt to use the VT100 codes to request terminal info whenever possible, such as getting
the terminal width/height. It should fall back to other means (`tput`, `stty`, fcntl(), etc) when
those aren't available and don't work.

### Colors

It should support 16-color, 256-color, and 24-bit color ANSI escape codes, the
bold/italic/underline/slow-blink/fast-blink/reverse/concealed/strike-through style codes, along with
the much less common ones found on modern terminal applications like double-underline,
underline-color, bright colors (90-97, 100-107), etc.

Color support should be capped, but not limited, meaning if the terminal is configured to allow
24-bit color, it should also allow 16-color and 256-color codes. A 256-color terminal also allows
16-color codes. But a 24-bit color code is not emitted unless 24-bit color is supported, nor is a
256-color code emitted if 256-color isn't supported.

It should maintain a mask of which of the above features are supported by the terminal. This mask
should be set by default based on whatever detection heuristics can be done. Worst case, it should
assume something is unsupported if it doesn't have a reason to believe otherwise. This can include
checking the TERM_PROGRAM and TERM env vars (worst case) against a list of patterns. For example,
ghostty and kitty support 24-bit color. Apple's Terminal.app support 256-color mode.

There should be a specific env var that can be used to explicitly enable/disable these flags, as
many as desired. This should not be app specific.

## Advanced Terminal Features

### Kitty Color Protocol

It should support the Kitty Color Protocol (<https://sw.kovidgoyal.net/kitty/color-stack/>) when
available.

### Links

It should support setting clickable URLs on a range of cells via OSC 8, if that is supported by the
terminal. See <https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda>

### Images

It should support kitty's graphics protocol (<https://sw.kovidgoyal.net/kitty/graphics-protocol/>),
allowing placement and management of images on screen. It doesn't need to support advanced uses, but
might, for example, use this to allow drawing of certain types of widgets like sparklines or bar
graphs.

At startup it should determine if the terminal supports the image protocol, and if it does,
determine whether it works with temp file transport. After this it will use either the local temp
file or remote transport.

### Passthrough

There should be an API for applications to be able to send an arbitrary sequence to the terminal.

### Terminal Responses

There should be an API for applications to register terminal response patterns--a prefix and
terminator that, when they are received in a very short window, are coalesced into an event and not
passed as direct user input to the application.

## Events and IO

All IO is UTF-8.

Input and output should be organized into events which are passed via channels. Direct APIs may of
course exist which create the events, such as a
`#write_char(x : Int32, y : Int32, style : BufTerm::Style, char : Char)` method that puts the given
character in the given position with the given style.

Output IO objects should be available with associated cursors so that application code can simply
use `#puts` or `#print` or other common IO methods when writing to the terminal. The cursors define
a scrollable region (defaulting to the entire screen) and use this for output.

## Cursors

A default cursor is created, and additional cursors may be created. Each cursor has a current
position where the next character will be written, as well as a current state (foreground color,
background color, style, URI link (if any), scrollable region, etc). The scrollable region defaults
to the entire terminal. IO methods are available for writing.

A flag can set the cursor to "raw", meaning that the data written to the IO is not scanned for
escape codes, which might improve performance when the application only wants to use the current
state during IO, and change it only via methods outside of IO writes.

Note that these do _not_ correspond to the "hardware" terminal's cursor; that is a terminal property
that by default is associated with the default internal cursor, which determines its position. It
can be hidden or assocated with a different internal cursor as well. The "hardware" cursor position
will be updated to match the associated internal cursor after every paint.

## Terminal Buffer

An in-memory representation of the terminal is maintained, and at each repaint event, a diff is
sent. This might be implemented by keeping track of 'dirty' cells, and when the count is 0 then a
repaint is a no-op. A forced repaint API is available as well, which sends any active images again
and then rewrites the entire set of cells. All repaints update just the dirty cells and endeavor to
reduce the total output size in order to improve performance over a connection with some latency.

The algorithm to repaint dirty cells should look for scrolled regions and use the fixed region
scrolling controls if they are available and would be less bytes to send.

The buffer must internally implement scrolling for each internal cursor.

## Implementation

It makes sense to implement this shard as a core, internal API that is then used by the higher level
API.

Specifically, the terminal buffer itself, the cell data, and the repaint algorithm should be a
self-contained implementation that can be tested entirely on its own. Then the full API described
here should be implemented on top of it.
