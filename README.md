# termbuf

[![docs](https://img.shields.io/badge/docs-latest-blue)](https://plambert.github.io/termbuf.cr/latest/)
[![ci](https://github.com/plambert/termbuf.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/plambert/termbuf.cr/actions/workflows/ci.yml)

An in-memory terminal screen for Crystal, repainted with a diff.

Draw into a buffer, ask for a paint, and what reaches the terminal is the difference between what
it is showing and what the buffer holds — encoded against what that particular terminal turned out
to be able to do. Drawing the same frame twice sends nothing.

* Double-buffered cell grid with damage tracking; scrolled regions are moved with `DECSTBM` rather
  than redrawn where that is cheaper
* Capability detection by asking the terminal directly, falling back to `TERM` heuristics, with
  `TERMBUF_CAPS` as the last word
* Colour capped rather than limited: a 24-bit colour degrades to the 256 palette, then to the
  sixteen, then to nothing, depending on what is there
* UAX #29 grapheme clusters and UAX #11 widths, from generated tables, with cluster widths
  measured from the terminal rather than assumed
* Keys with modifiers, bracketed paste, resizes, and terminal replies delivered as events on a
  channel
* Widgets — an editable field, layout, focus, and keymaps — in a shard of their own, drawn
  through the same API
* Cursors that wrap and scroll inside a region, with an `IO` for each

Requires Crystal 1.21 or later.

## Installation

Add the dependency to `shard.yml` and run `shards install`:

```yaml
dependencies:
  termbuf:
    github: plambert/termbuf.cr
```

That pulls in [termbuf-input](https://github.com/plambert/termbuf-input.cr), which is the input
side and termbuf's only dependency.

## Usage

```crystal
require "termbuf"

TermBuf::Terminal.open do |terminal|
  terminal.batch do |screen|
    screen.clear
    screen.write 2, 1, "hello", TermBuf::Style::DEFAULT.bold
  end
  terminal.paint

  terminal.events.receive
end
```

`Terminal.open` probes the terminal, puts it in raw mode, switches to the alternate screen, and
starts a fibre that owns the buffer. The block form gives the terminal back however the body ends,
including on an exception or a signal.

### Drawing

Coordinates are zero based from the top left. Text goes in one grapheme cluster per cell, and a
cluster the terminal draws double width takes two.

```crystal
terminal.write 0, 0, "text", style
terminal.write_char 4, 0, '!', style
terminal.fill TermBuf::Rect.new(0, 1, 20, 3), '.', style
terminal.scroll TermBuf::Rect.new(0, 4, terminal.size.columns, 10), 1
terminal.clear
```

Nothing here touches the buffer: each call builds a command and sends it to the owning fibre, which
is what makes ordering total and locking unnecessary. `#batch` collects a frame's worth and sends it
as one channel operation — use it for anything larger than a few writes.

```crystal
terminal.batch do |screen|
  screen.clear
  rows.each_with_index { |row, index| screen.write 0, index, row }
end
```

To read the buffer, or to do something the drawing API does not cover, `#sync` runs a block on the
owning fibre and waits:

```crystal
terminal.sync { |buffer| puts buffer.to_text }
```

### Cursors

Drawing addresses cells. A `Cursor` streams instead: it holds a position, a `Style`, and the
`Region` it wraps and scrolls inside, and works out which cell each grapheme cluster lands in.

```crystal
cursor = terminal.cursor                                  # the whole screen
log = terminal.cursor TermBuf::Rect.new(0, 10, 80, 8), scrollback: 500

log.style = TermBuf::Style::DEFAULT.faint
log.puts "started"
log.io.printf "%-12s %s\n", name, status
```

`Cursor#io` is an `IO`, so `printf`, `Colorize`, `inspect`, and anything else that writes to one can
be pointed at a pane. It is unbuffered by default; set `sync = false` to gather writes until a
newline or a `#flush`.

Text written to a cursor is scanned for escape sequences, so `\e[1m` sets the bold attribute on the
cells that follow rather than landing in them. Sequences that address the terminal rather than the
text — cursor movement, screen clearing — are dropped, since the buffer already has its own idea of
where the cursor is. An application that changes appearance by assigning to `#style` and never
writes a sequence of its own can skip the scan:

```crystal
cursor.raw = true
```

Wrapping is deferred the way a terminal defers it: a character landing in the last column leaves the
cursor at the margin, and only the next character takes it to the row below. Turn `autowrap` off and
the cursor stops at the margin; turn `scrolls` off and the bottom row stops scrolling.

### Clipped panels

`Drawing#view` gives back a rectangle of a surface addressed from its own top left and cut at its
own edges. A panel drawn over other content stays inside its border without every widget doing the
arithmetic:

```crystal
terminal.batch do |screen|
  draw_table screen

  panel = screen.view TermBuf::Rect.new(10, 4, 30, 8)
  panel.fill panel.bounds, ' ', TermBuf::Style::DEFAULT.reverse
  panel.write 0, 0, "a line far longer than thirty cells"   # cut at the border
end
```

A cluster crossing an edge is dropped whole rather than split, measured with the policy of the
surface the view came from. Views nest, so a border can hand what it surrounds a surface of exactly
the space left inside it. `#passthrough` and `#scroll_region` pass through untouched, since neither
is addressed in the view's cells.

A view can also carry a style that everything drawn through it merges onto, so a highlighted row is
filled once and its columns name only what each one adds:

```crystal
row = screen.view rect, TermBuf::Style::DEFAULT.bg(highlight)
row.clear                                              # paints the highlight
row.write 0, 0, name, TermBuf::Style::DEFAULT.bold     # bold, on the highlight
row.write 24, 0, rate, TermBuf::Style::DEFAULT.faint
```

A write that names a field of its own wins; one that leaves a field unset takes the view's. Nested
views layer the same way. Attributes are the exception and combine rather than replace, since flags
have no value meaning "leave the panel's alone" — a bold write inside a faint panel is both. The
merge is `Style#merge`, usable on its own.

That covers one background for a whole row. When the background varies *under* the text — a label
across a progress bar — the cells themselves have the answer, and a `blend:` asks them per cell:

```crystal
screen.fill TermBuf::Rect.new(0, y, filled, 1), ' ', TermBuf::Style::DEFAULT.bg(bar)
screen.write x, y, "#{percent}%", TermBuf::Style::DEFAULT.bold,
  blend: TermBuf::Style::KEEP_BACKGROUND
```

A blend is given the style already in the cell, the style being written, and the cell's position in
the buffer, and returns the style to place. `Style::KEEP_BACKGROUND` keeps the colour already there
and takes everything else from the write; `Style::OVER` merges the two the way a view does; and
`Style.blend { |under, over| ... }` wraps anything else:

```crystal
screen.fill panel, ' ', TermBuf::Style::DEFAULT,
  blend: TermBuf::Style.blend { |under, over| under.merge(over).faint }
```

A cluster covering two cells takes the style its first half lands on. `#write_char`, `#fill` and
`#clear` take the same argument, and it survives a view's translation and clipping — the position a
blend is handed is the cell's in the buffer, not in the view.

One caution: styles are interned and the table only grows, so a blend returning a colour computed
per cell interns a style per cell. That is bounded by the screen for one frame; across an animation
it is not, and such a blend should draw from a fixed palette instead.

A `fill`, `scroll`, or `blit` whose edge falls inside a wide character takes the whole character —
half of one cannot be drawn — and the half lying outside the rectangle keeps the style it had,
losing only its glyph. So a panel over CJK text is the width it says it is on every row. Writing a
character over half of one is different: there the displaced half is erased in the style being
written, which is what a terminal does.

This is clipping, not layering: nothing says a view is on top of anything. Dismissing a panel means
the next frame does not draw it, and the paint diff then sends the cells it covered and nothing
else — a batched full frame is the cheap way to do this, not a workaround for the lack of layers.

### Off-screen buffers

A `Buffer` needs no terminal, and `BufferSurface` is a full drawing surface over one — so a shard
that wants to composite panels itself can draw each into a buffer of its own and blit them into
place:

```crystal
panel = TermBuf::Buffer.new 30, 8
TermBuf::BufferSurface.new(panel).view(inner).write 0, 0, "drawn off screen"

terminal.batch { |screen| screen.blit panel, 10, 4 }
```

Styles and clusters are interned per buffer, so the ids a source cell carries mean nothing in the
destination; `#blit` translates them. Stored widths are copied rather than remeasured, so a panel
keeps the layout it was drawn with. A wide character with only one half inside the copied rectangle
arrives as a blank. The source is read when the command is serviced, so do not draw into a panel
again between blitting it and painting.

### Panes and resizing

A `Region` an application makes covers a pane it chose, and the driver does not move it: only the
screen-wide region follows the window, because nothing tells the buffer whether a pane was meant to
be a bottom edge, a fixed sidebar, or a third of the width. So a region an application placed keeps
its rectangle until the application assigns a new one, and a stale region goes on drawing where the
window used to be.

Register the layout once instead of repeating it at every `Events::Resize`:

```crystal
status = terminal.cursor TermBuf::Rect.new(0, rows - 1, columns, 1)
log = terminal.cursor TermBuf::Rect.new(0, 0, columns, rows - 1), scrollback: 500

terminal.on_resize do |size|
  status.region.bounds = TermBuf::Rect.new 0, size.rows - 1, size.columns, 1
  log.region.bounds = TermBuf::Rect.new 0, 0, size.columns, size.rows - 1
end
```

Handlers run in the order registered, on the fibre that owns the buffer, after the grids have been
resized and before `Events::Resize` reaches the application — so whatever it draws in response
already sees panes in their new places. That fibre is the one servicing commands, so a handler must
not call back into `#batch`, `#paint`, or `#sync`; moving regions and recomputing rectangles is what
it is for. Anything it raises arrives as an `Events::Failure`, and the remaining handlers still run.
`#forget_resize` takes a handler back.

There is no layout engine here on purpose. Anchors, splits, and constraint solving belong a layer
up; this shard gives that layer the one hook it needs.

### The terminal's own cursor

Hidden by default, which is what a full-screen application wants. Point it at a cursor and every
paint puts it back there once the cells have been drawn:

```crystal
terminal.hardware_cursor = input_cursor   # shows it, and follows it
terminal.hide_cursor
```

A frame that changes no cells is still sent when this has moved.

### Painting

`#paint` sends the diff and waits for it to reach the terminal. `#paint!` rewrites every cell,
for after a suspend or anything else that leaves the screen in a state the buffer cannot know
about. `#paint_async` does not wait.

A scheduler is available for applications that would rather not decide:

```crystal
terminal.start_frame_scheduler fps: 30
```

It coalesces whatever was drawn between frames, and a paint with nothing to do costs nothing.
`#last_paint_bytes` and `#total_paint_bytes` report what frames are costing.

### Events

`Terminal#events` is a `Channel(Event)`. Everything the terminal has to say arrives on it in the
order it happened.

```crystal
case event = terminal.events.receive
in TermBuf::Events::Key      then handle event.key
in TermBuf::Events::Paste    then insert event.text
in TermBuf::Events::Pasting  then show_notice event.bytes
in TermBuf::Events::Resize   then redraw event.size
in TermBuf::Events::Response then handle_reply String.new(event.bytes)
in TermBuf::Events::Warning  then log event.message
in TermBuf::Events::Failure  then raise event.error
in TermBuf::Events::Closed   then break
end
```

`Warning` carries anything detection wanted to report — these never go to stderr, since the screen
is taken over by then.

The input side — the reader, the decoder, keys, mouse reports, timers, signals, and every event
above except `Resize` — is the
[termbuf-input](https://github.com/plambert/termbuf-input.cr) shard, which termbuf depends on and
which depends on nothing outside the standard library. A program that only wants to read a keyboard
can use it without a screen buffer attached. `TermBuf::Key` is `TermBuf::Input::Key`,
`TermBuf::Events::Key` is `TermBuf::Input::Events::Key`, and so on: the short spellings are aliases
and stay. `Resize` is the one event that did not move, because it carries a `ScreenSize`.

### Keys

`Key` is a value: which key, which modifiers, and for an ordinary character which character.

```crystal
ctrl_c = TermBuf::Key.character('c', TermBuf::Modifiers::Ctrl)

case
when key.is?('q')                          then quit          # q, nothing held
when key.is?(TermBuf::Key::Name::PageDown) then scroll 1      # whatever is held
when key == ctrl_c                         then interrupt     # exactly Ctrl+C
when key.character?                        then insert key.char
end

key.to_s   # => "Ctrl+C", "Alt+Up", "Shift+F5", "a", "Space"
```

`Events::Key#bytes` carries what the terminal actually sent, for the sequences the decoder could
not name — those arrive as `Key::Name::Unknown` rather than being dropped.

Modifiers are only as good as the terminal's encoding. `Ctrl` with a letter arrives as one control
byte, so `Ctrl+I` and `Tab` are the same key press and nothing downstream can separate them. The
decoder reports the name people press.

### Paste

Pasted text arrives as `Events::Paste` rather than as a burst of key presses, so a paste does not
run every key binding over whatever was on the clipboard. Bracketed paste is enabled at startup when
the terminal has it, and `Events::Paste` never arrives when it does not.

While a paste is open, every byte the terminal sends is paste content by definition — including the
one that would have quit the application. That makes a paste the terminal opens and never closes a
lost session rather than a slow paste, so there are deadlines:

| Property | Default | Reset by | Meaning |
|---|---|---|---|
| `escape_timeout` | 25 ms | — | A lone `ESC` is the escape key, not the start of an arrow |
| `paste_notice` | 300 ms | the paste opening | A paste running this long is worth mentioning |
| `paste_progress` | 100 ms | each notice sent | How often the byte count is worth resending |
| `paste_stall` | 3 s | every byte of the paste | No more of it is coming |

`paste_stall` is reset per byte rather than measured from the opening marker, since the question is
whether the paste is slow or stopped and the only evidence either way is whether anything is still
arriving. A paste ended that way is still delivered, with `Events::Paste#complete` false.

`Events::Pasting` carries the byte count so an application can say something rather than look hung;
`Events::Paste` is the signal to take that notice down. Drawing it is the application's job, because
the buffer belongs to the application — see page 7 of `examples/validate.cr` for one.

### Styles and colour

`Style` is a value. The builders return copies:

```crystal
alias Style = TermBuf::Style
alias Color = TermBuf::Color

Style::DEFAULT.bold.italic
  .fg(Color.rgb(0x66CCFF))
  .bg(Color.indexed(236))
  .underlined(TermBuf::Underline::Curly, Color.indexed(1))
```

Colours are stored as given and reduced at encode time, so raising the capability mask and
repainting yields better colour with nothing lost along the way. A terminal without
`ExtendedUnderline` gets a plain underline; one without `Italic` gets none.

### Capabilities

What the terminal can do is settled once at startup, each stage overriding the one before: nothing
at all, then `TERM` and friends, then the terminal's own answers to a batch of queries, then
`TERMBUF_CAPS`.

```crystal
terminal.capabilities.includes? TermBuf::Capability::KittyGraphics
```

`TERMBUF_CAPS` is the escape hatch, and is deliberately not application specific. Names are
`Capability` members in snake case:

```bash
TERMBUF_CAPS=+truecolor,-kitty_graphics
TERMBUF_CAPS=none,+color16,+bold      # start from nothing
TERMBUF_CAPS=all                      # start from everything
```

A name that is not recognised becomes a `Events::Warning` rather than an error.

Detection is pessimistic by design: a terminal nobody recognises gets plain text, because a screen
full of escape sequences is worse than no escape sequences. Pass `probe: false` to `Terminal.open`
to skip the queries.

### Terminal replies

A reply from the terminal and a keystroke are not distinguishable by looking at them — an arrow key
sends `ESC [ A`, and so could a terminal. What separates them is that the application asked for one.
Register the shape of the answer before sending the query:

```crystal
pattern = terminal.expect_response "\e[?", "$y"
terminal.passthrough "\e[?2026$p"
# the reply arrives as Events::Response; everything else is a key
terminal.forget_response pattern
```

With nothing registered, every escape sequence arriving from the terminal is treated as input.

### Unicode

```crystal
TermBuf::Unicode.string_width "漢字"   # => 4
TermBuf::Unicode.graphemes "🇺🇸!"       # => ["🇺🇸", "!"]
```

Width tables are generated from the UCD by `scripts/gen_unicode.cr` and committed, so building the
shard needs no network access.

### Fitting text to a column

Column layout is arithmetic on cells, so it has to run against the same measurement the buffer uses.
Four helpers do it, each taking an optional `WidthPolicy` and each walking whole grapheme clusters —
a double-width cluster that would half-cross the edge is dropped rather than split, so a result can
come back a cell short. `fit` pads that cell back; the others leave it.

```crystal
Unicode.truncate  "hello world", 5             # => "hello"
Unicode.ellipsize "hello world", 8             # => "hello w…"   marker measured too
Unicode.fit       "42", 6, :right              # => "    42"     exactly 6 cells
Unicode.fit       "name", 10, :left, '.'       # => "name......"
Unicode.window    "a long filename", 4, 6      # => "ng fil"     a marquee step
```

`fit` is the one a table row wants: every column comes back exactly the width it was given, whatever
is in it.

### Measured widths

How many cells a cluster occupies is a property of the terminal, not of Unicode. UAX #29 says where
a cluster ends; it says nothing about what a terminal does with four emoji joined by zero width
joiners, and terminals disagree. Measured on one machine:

| cluster | ghostty | tmux | Terminal.app |
|---|---|---|---|
| `☺️` U+263A U+FE0F | 2 | 2 | 1 |
| `👨‍👩‍👧‍👦` four faces, ZWJ | 2 | 2 | 11 |
| `क्षि` conjunct plus vowel sign | 2 | 2 | 3 |
| `நி` Tamil na plus vowel sign | 2 | 1 | 2 |

Being right about the standard does not help: a terminal advancing eleven columns for a cluster the
buffer thinks is two has every later cell on that row nine columns out of place. So the shard asks.
After the alternate screen is entered and before anything is drawn on it, a batch of discriminating
samples goes out, each followed by `ESC [ 6 n`, and the columns that come back are the terminal's
own measurements. One round trip, invisible.

```crystal
terminal.widths           # => WidthPolicy(ambiguous=1 -emoji_presentation … )
terminal.width_readings   # what was asked and what came back
```

`Buffer#policy` is what writes use, and `Terminal#cursor` hands the same one to every cursor it
makes. A measurement no rule explains — Terminal.app's eleven — becomes an `Events::Warning` naming
the cluster rather than being modelled wrong.

### What a terminal gets wrong

`Capability` says what a terminal can do. `Quirk` says what it gets wrong, and the two are kept
apart: a capability turned off means don't ask, where a quirk means ask and then cope with the
answer. Quirks are named for the behaviour, so mapping another terminal onto one is a row in a
table once somebody measures it.

`Quirk::PerCodePointColumns` is the one there is. Terminal.app counts a cluster's columns by adding
up its code points — `👨‍👩‍👧‍👦` is four emoji of two columns and three joiners of one, so it owns
eleven. That count is what `CPR` reports and what `CUP` addresses; forcing a character to column
three of such a row tears the cluster into `👨X👪`. It draws the composed glyph anyway, two columns
wide, and slides the rest of the row left to sit flush against it. So a row holding one of these has
everything after it out of step with every other row, and nothing here can lay it out correctly.

What the shard does instead is notice and say so, once, the first time it draws a cluster the
terminal will misplace:

```text
termbuf: this terminal counts a grapheme cluster's columns by adding up its code points, so
"👨‍👩‍👧‍👦" takes 11 columns where it is drawn in 2. Everything after it on that row is 9 columns
out of step with every other row, and the last 9 columns of it cannot be reached at all.
```

The last part is measured, not inferred: on a 155 column window, a `CUP` to column 155 on such a row
lands on screen column 146, and asking for 164 clamps at the margin and lands there too. The columns
the cluster consumes come out of the row's budget, so a right-anchored column vanishes from that row
and no escape sequence reaches it.

That goes to stderr with the alternate screen handed back for as long as it takes, and to
`Events::Warning` as well. `Terminal#warn_composed_drift = false` keeps the event and leaves the
screen alone, for an application that renders its own warnings.

The check costs one predictable branch per run of text on any terminal without the quirk, and stops
looking after the first one it finds. An application certain it will never draw such a cluster can
switch it off outright:

```crystal
TermBuf::Terminal.open detect_composed_drift: false
```

A terminal with this quirk also has its width probe answers ignored: it reports the columns it
counts rather than the ones it paints, so taking those as rules would put text under the glyph.

```bash
TERMBUF_QUIRKS=-per_code_point_columns   # same shape as TERMBUF_CAPS
TERMBUF_QUIRKS=none
```

`TERMBUF_WIDTHS` has the last word:

```bash
TERMBUF_WIDTHS=off                    # skip the measurement, keep the tables
TERMBUF_WIDTHS=+ambiguous_wide        # a CJK terminal, said rather than measured
TERMBUF_WIDTHS=-joined_emoji,-emoji_presentation
```

### The core layer

`Buffer` and `Sink` work without a device attached, which is how they are tested:

```crystal
buffer = TermBuf::Buffer.new 80, 24
sink = TermBuf::Sink.new buffer, TermBuf::Capabilities::XTERM

buffer.write 0, 0, "hello", TermBuf::Style::DEFAULT.bold

sink.encoder.encode sink.paint  # => "\e[?7l\e[1;1H\e[0;1mhello\e[?7h"
sink.commit
```

The buffer holds the cells. A `Sink` holds one output of them: the grid that terminal is believed
to be showing, the damage it has yet to paint, and the `Painter` and `Encoder` that turn the
difference into bytes. Attach a second sink and the same buffer drives a second display, painted
whenever that display asks and under whatever that terminal turned out to be able to do:

```crystal
web = TermBuf::Sink.new buffer, TermBuf::Capabilities::MODERN

bytes = web.encoder.encode web.paint
web.commit
```

A sink attached to a buffer that already holds content starts knowing nothing about the screen, so
call `Sink#invalidate` before its first paint. Detach it with `Sink#detach` when the display goes.

## Hyperlinks, images, and the terminal's colours

Four things a modern terminal will do that a cell grid cannot express, each behind the capability
that says whether asking is safe.

### Hyperlinks

```crystal
docs = terminal.link "https://example.com", "docs"   # the id groups two ranges as one link
terminal.write 0, 0, "example", TermBuf::Style::DEFAULT.linked(docs)
```

A link is not an SGR attribute — `SGR 0` does not close one — so the encoder tracks it apart from
the rest of the style and emits OSC 8 when it changes from one run to the next. Without
`Capability::Osc8Links` it is stripped from the style entirely, so two runs differing only by a link
become one run: setting links costs nothing on a terminal that has none.

### The terminal's own colours

```crystal
terminal.colors.saved do
  terminal.colors.background = TermBuf::Color.rgb(20, 20, 30)
  terminal.colors[3] = TermBuf::Color.rgb(255, 128, 0)
end
```

All of this needs `Capability::KittyColorStack`, the OSC 4 and OSC 10 setters included. The stack is
what makes a change reversible, and without somewhere to put the old values there is no way to give
them back. `Terminal#close` pops whatever is still pushed, so an application that forgets, or that
stops on a signal, still gives the terminal back the colours it was found with.

Fewer terminals have it than claim to, and there is no query to settle it: ghostty parses
`XTPUSHCOLORS` and `XTPOPCOLORS` and does nothing with them, so it is denied the capability by name.
Check `Terminal#colors.available?` if it matters which way a terminal went.

### The clipboard

```crystal
terminal.clipboard.copy "the selected text"
terminal.clipboard.copy "a middle-click paste", :primary
```

OSC 52, behind `Capability::Osc52Clipboard`. The terminal is the only thing in the picture with a
connection to the window system, so a program on the far end of an ssh session sets the clipboard of
the machine the human is sitting at. Copies go out in order with the frames around them, the way a
colour change does.

Nothing comes back: the terminal answers nothing on a write, so a refusal and a success look the
same from here. Nor is there anything to chunk into — OSC 52 carries one payload, and the limit on
it is the terminal's rather than the protocol's — so a caller moving more than a few kilobytes
should not expect it to arrive, and cannot find out that it did not. The capability is a table
entry for kitty, ghostty, WezTerm and foot rather than something measured; xterm supports the write
and ships it off, which from here is the same as not having it.

### Images

```crystal
sparkline = TermBuf::Image.rgb(pixels, 64, 16)
id = terminal.images.add sparkline
terminal.images.place id, TermBuf::Rect.new(2, 4, 16, 2)
terminal.images.place id, TermBuf::Rect.new(2, 8, 16, 2), z: -1   # under the text
```

Images are not cells. They are drawn over the screen after each frame rather than into the buffer,
so an application that writes text where one sits gets both. `z` decides which of them is on top:
zero and above covers the text, negative sits beneath it so the glyphs stay readable and the picture
shows through where the cells are blank. Among placements, higher covers lower. Pixels travel once
however many placements follow; the transport — a temp file or base64 down the escape sequence — is
chosen by a probe at startup. Placements that no longer fit are dropped on a resize, everything is
sent again on a forced repaint, and the pictures come down when the terminal is given back.

## Widgets

The editing widgets live in [termbuf-widgets](https://github.com/plambert/termbuf-widgets.cr):
an input field with history and completion, the line buffer and keymapped editor underneath it,
borders, layout, and focus. They draw through the `Drawing` API in this shard and cost the same
diff as anything else on screen, so nothing about them needs to be here. Add that shard alongside
this one and `require "termbuf-widgets"`.

## Examples

```bash
crystal run examples/clock.cr     # drawing, input, and resize in one small program
crystal run examples/validate.cr  # eleven pages checking a real terminal against the shard
```

`validate.cr` is worth running in any terminal you intend to support: it reports what detection
concluded, writes every cell of the screen including the bottom-right corner, checks the terminal's
idea of grapheme widths against the tables, shows what a frame costs in bytes, decodes whatever you
type, draws clipped panels and a label across a two-colour bar, and gives you a pane to type into
with the terminal's own cursor following along.

## Development

```bash
crystal spec                      # includes the UAX #29 conformance suite
ameba                             # lint
crystal tool format --check
crystal docs                      # API documentation into ./docs
```

Specs run the encoder's output back through a model terminal in `spec/support` and compare the
result against the buffer, over several capability masks and a mixed alphabet of ASCII, CJK,
combining marks, emoji sequences, and Indic conjuncts. A change that breaks the round trip fails
whether or not anyone wrote a spec for it.

To regenerate the Unicode tables against a newer UCD:

```bash
crystal run scripts/gen_unicode.cr
```

## Status

The core, the driver, input, cursors, hyperlinks, images, and the terminal's own colours are in
and specified. Mouse reporting is neither enabled nor decoded. See
[CHANGELOG.md](CHANGELOG.md) for what has landed and [PLAN.md](PLAN.md) for what is coming.

## Contributing

1. Fork it (<https://github.com/plambert/termbuf.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

* [Paul M. Lambert](https://github.com/plambert) — creator and maintainer
