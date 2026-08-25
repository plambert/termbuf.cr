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
* UAX #29 grapheme clusters and UAX #11 widths, from generated tables
* Keys with modifiers, bracketed paste, resizes, and terminal replies delivered as events on a
  channel

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

Pasted text arrives as `Events::Paste` rather than as a burst of key presses, so a paste does not
run every key binding over whatever was on the clipboard. Bracketed paste is enabled at startup
when the terminal has it; `Events::Paste` simply never arrives when it does not.

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
TermBuf::Unicode.string_width "漢字"       # => 4
TermBuf::Unicode.graphemes "🇺🇸!"           # => ["🇺🇸", "!"]
TermBuf::Unicode.ambiguous_width = 2       # for a CJK-configured terminal
```

Width tables are generated from the UCD by `scripts/gen_unicode.cr` and committed, so building the
shard needs no network access.

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

## Examples

```bash
crystal run examples/clock.cr     # drawing, input, and resize in one small program
crystal run examples/validate.cr  # six pages checking a real terminal against the shard
```

`validate.cr` is worth running in any terminal you intend to support: it reports what detection
concluded, writes every cell of the screen including the bottom-right corner, checks the terminal's
idea of grapheme widths against the tables, shows what a frame costs in bytes, and decodes whatever
you type on its last page.

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
