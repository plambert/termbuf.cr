# termbuf

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
* An editable input field with history, completion, and a border, drawn through the same API
* Cursors that wrap and scroll inside a region, with an `IO` for each

Requires Crystal 1.21 or later.

## Installation

Add the dependency to `shard.yml` and run `shards install`:

```yaml
dependencies:
  termbuf:
    github: plambert/termbuf.cr
```

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

`TERMBUF_WIDTHS` has the last word:

```bash
TERMBUF_WIDTHS=off                    # skip the measurement, keep the tables
TERMBUF_WIDTHS=+ambiguous_wide        # a CJK terminal, said rather than measured
TERMBUF_WIDTHS=-joined_emoji,-emoji_presentation
```

### The core layer

`Buffer`, `Painter`, and `Encoder` work without a device attached, which is how they are tested:

```crystal
buffer = TermBuf::Buffer.new 80, 24
buffer.write 0, 0, "hello", TermBuf::Style::DEFAULT.bold

painter = TermBuf::Painter.new TermBuf::Capabilities::XTERM
encoder = TermBuf::Encoder.new buffer.styles, TermBuf::Capabilities::XTERM, 80, 24

encoder.encode painter.paint(buffer)  # => "\e[?7l\e[1;1H\e[0;1mhello\e[?7h"
buffer.commit_paint
```

## An input field

The one widget in the shard, because every terminal application needs one and nobody should write
it twice. It draws through the same `Drawing` API an application uses, so it composes with whatever
else is on screen and costs the same diff.

```crystal
field = TermBuf::Field.new(
  bounds: TermBuf::Rect.new(0, terminal.size.rows - 3, terminal.size.columns, 3),
  editor: TermBuf::Editor.new(
    history: TermBuf::History.new,
    completions: ->(request : TermBuf::Completion::Request) do
      TermBuf::Completion::Result.new COLOURS.select(&.starts_with? request.word)
    end),
  border: TermBuf::Border.rounded(title: " a colour "),
  prompt: TermBuf::Field::Prompt.new("› "),
  growth: TermBuf::Field::Growth::Grow,
  max_rows: 8)

answer = field.run terminal   # => the line, or nil if it was given up on
```

`#run` owns the event loop, which is what a prompt with nothing else on screen wants. An application
with a loop of its own calls `#handle`, `#draw`, and `#cursor_position` from that instead:

```crystal
case field.handle key
in TermBuf::Editor::Outcome::Continue  then nil
in TermBuf::Editor::Outcome::Accepted  then submit field.editor.accepted
in TermBuf::Editor::Outcome::Cancelled then dismiss
in TermBuf::Editor::Outcome::Ended     then quit
end
```

Four outcomes rather than two: `Enter`, `Ctrl+C`, and `Ctrl+D` on an empty line mean different
things.

### Layout

`Growth::Fixed` keeps one row and scrolls sideways, marking what has run off either edge.
`Growth::Grow` wraps and grows to `max_rows`, then scrolls. A growing field reports
`#desired_height` and the application decides where to put it — this shard has no layout manager.

`#cursor_position` says where the terminal's own cursor belongs; point `Terminal#hardware_cursor` at
a cursor moved there and every paint puts it back.

### Editing

`Editor` maps `Key` to `Action` in a plain `Hash`, so rebinding is replacing an entry:

```crystal
field.editor.keymap[TermBuf::Key.character 'k', TermBuf::Modifiers::Ctrl] =
  TermBuf::Editor::Action::KillToStart
```

The default is the readline set. Anything unbound that carries a character and no modifier but shift
is text, which is what keeps the map small.

`LineBuffer` underneath counts grapheme clusters, carries the measured `WidthPolicy`, and holds a
selection as an anchor and a point. It has no idea a terminal exists, which is what makes it
testable on its own.

History keeps the line being typed when a walk starts and gives it back on the way down, and
`History::Search::Prefix` walks only the entries beginning with what was typed. Completion is a
hook: one candidate is inserted, several insert what they agree on, and a second `Tab` lists them.

### Saying a paste is arriving

`PasteNotice` draws the panel the paste deadlines exist for:

```crystal
in TermBuf::Events::Pasting then notice.arriving event.bytes
in TermBuf::Events::Paste   then notice.finished
```

`#draw` does nothing at all while nothing is arriving.

## Examples

```bash
crystal run examples/clock.cr     # drawing, input, and resize in one small program
crystal run examples/prompt.cr    # an input field, and nothing else
crystal run examples/validate.cr  # ten pages checking a real terminal against the shard
```

`validate.cr` is worth running in any terminal you intend to support: it reports what detection
concluded, writes every cell of the screen including the bottom-right corner, checks the terminal's
idea of grapheme widths against the tables, shows what a frame costs in bytes, decodes whatever you
type, and gives you a pane to type into with the terminal's own cursor following along.

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

## Contributing

1. Fork it (<https://github.com/plambert/termbuf.cr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

* [Paul M. Lambert](https://github.com/plambert) — creator and maintainer
