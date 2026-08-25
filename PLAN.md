# TermBuf Implementation Plan

Implementation plan for the `termbuf` shard described in `CLAUDE.md`. Written for review before any
code is written.

## Decisions

These were settled up front; the rest of the plan assumes them.

| Question | Decision |
|---|---|
| Namespace | `TermBuf` (`CLAUDE.md`'s `BufTerm::Style` treated as a typo) |
| First milestone | Core buffer + repaint only (Phases 0–4) |
| Links and images | Deferred to a late phase, after driver and cursors |
| Concurrency | Single owner fiber; all mutation arrives as commands over channels |
| Unicode | Full UAX #29 grapheme clusters + East Asian width, from a committed generator |
| Input | Response coalescing plus basic key decoding; mouse and kitty keyboard deferred |
| Repaint trigger | Explicit `#paint`, plus an optional frame-scheduler fiber |
| Capability detection | Active terminal queries with an env-heuristic fallback |
| Screen model | Full-screen (alternate screen) only |
| Scrollback | Opt-in per region, capacity defaults to zero |
| Override env var | `TERMBUF_CAPS` with a `+name,-name` list |
| Spec strategy | Model terminal for correctness **and** golden byte strings for optimizations |

Assumptions made without asking, flagged here so they can be overridden:

* **Spectator**, not stdlib `Spec` (per the Crystal skill). The scaffolded `spec/` gets converted.
* **POSIX only** — macOS and Linux. No Windows console support.
* **Runtime dependencies:** `guard` only. No other shards; everything else is stdlib.
* **Unicode 16.0** pinned as the data version, regenerable per release.
* **Non-tty output** is supported: the buffer works, probing is skipped, capabilities fall back to a
  minimal set, and paint writes to whatever `IO` it was given.

## Architecture

Three layers, each usable without the one above it.

```text
┌───────────────────────────────────────────────────────────────┐
│ Layer 3  Application API                                      │
│   TermBuf::Terminal (owner fiber)  Cursor / IO  Event channels│
│   Link, Image, ColorStack, passthrough, response registry     │
├───────────────────────────────────────────────────────────────┤
│ Layer 2  Terminal driver                                      │
│   TTY (raw mode, winsize, signals)  Capabilities  Input decode│
├───────────────────────────────────────────────────────────────┤
│ Layer 1  Core — pure, synchronous, no IO, no terminal         │
│   Color Style Cell Grid Buffer Region Painter Op Encoder      │
│   Unicode (width + graphemes)                                 │
└───────────────────────────────────────────────────────────────┘
```

Layer 1 is the piece `CLAUDE.md` calls out as self-contained and independently testable. It has no
knowledge of file descriptors, terminals, or fibers. It takes cell writes in and produces a byte
string out; a spec can drive it entirely in memory.

### Source layout

```text
src/termbuf.cr                    entry point
src/termbuf/version.cr
src/termbuf/unicode/
  tables.cr                       GENERATED — do not edit
  width.cr                        codepoint and cluster width
  grapheme.cr                     UAX #29 break iterator
src/termbuf/core/
  color.cr                        Color value type + quantization
  attributes.cr                   style attribute bit flags
  style.cr                        fg/bg/underline colour/attrs/link id
  style_table.cr                  Style ↔ StyleId interning
  cell.cr                         one grid cell
  grid.cr                         flat Slice(Cell) with row hashes
  region.cr                       rect, scroll behaviour, scrollback ring
  buffer.cr                       front + back grids, damage, scroll hints
  op.cr                           abstract paint operations
  painter.cr                      diff → Array(Op)
  encoder.cr                      Array(Op) → ANSI bytes, capability-gated
src/termbuf/caps/
  capability.cr                   flag enum + capping rules
  detector.cr                     env heuristics
  prober.cr                       active queries
src/termbuf/terminal/
  tty.cr                          raw mode, winsize, signals, alt screen
  terminal.cr                     owner fiber, command channel, lifecycle
  event.cr                        event types
  input/decoder.cr                byte stream → events
  input/key.cr                    key + modifier model
  input/responses.cr              registered response patterns
src/termbuf/cursor.cr             cursor state + IO
src/termbuf/sgr_scanner.cr        interprets escapes in non-raw cursor writes
src/termbuf/link.cr               OSC 8
src/termbuf/image.cr              kitty graphics
src/termbuf/color_stack.cr        kitty colour protocol
scripts/gen_unicode.cr            regenerates unicode/tables.cr
spec/support/model_terminal.cr    spec-only ANSI-consuming terminal model
```

## Core data model

### Colour

```crystal
struct TermBuf::Color
  enum Kind : UInt8
    Default   # terminal's default fg/bg
    Indexed   # 0..255 (0..7 basic, 8..15 bright, 16..255 cube/grey)
    Rgb
  end
end
```

Downgrade is a pure function of the capability mask, applied at encode time, never at write time —
the buffer always stores what the application asked for, so raising the capability mask and
repainting yields better colour with no data loss:

* `Rgb` → nearest of the 6×6×6 cube and 24-step grey ramp when `TrueColor` is absent.
* `Indexed(16..255)` → nearest of the 16 basic colours when `Color256` is absent.
* `Indexed(8..15)` → basic colour + bold, or the `9x`/`10x` bright codes when available.
* No colour capability at all → `Default`.

Nearest-colour search uses a small precomputed table of the 256 xterm RGB values and a weighted
Euclidean distance; results are memoized in a fixed-size cache since real applications use few
distinct colours.

### Style and interning

`Style` holds foreground, background, underline colour, an `Attributes` bit-flag enum, and a link
id. Styles are interned in a per-buffer `StyleTable`, so a `Cell` stores a `UInt32` style id. Two
consequences that matter: diffing compares integers rather than four-field structs, and the encoder
can cache the emitted SGR byte string per style id.

`Attributes` covers what `CLAUDE.md` asks for and a little more:

```text
Bold  Faint  Italic  Underline  DoubleUnderline  CurlyUnderline  DottedUnderline
DashedUnderline  SlowBlink  RapidBlink  Reverse  Conceal  Strike  Overline
Superscript  Subscript
```

### Cell

```crystal
struct TermBuf::Cell
  getter char    : Char    # base codepoint; '\0' means "continuation of a wide cell"
  getter cluster : UInt32  # 0 = single codepoint; otherwise index into the cluster pool
  getter style   : UInt32  # StyleId
  getter width   : UInt8   # 0 continuation, 1 narrow, 2 wide
end
```

Sixteen bytes, fixed size, no heap reference — so a `Grid` is one flat `Slice(Cell)` and a row is a
`Slice` view into it. Multi-codepoint grapheme clusters (accents, ZWJ emoji, flags) live in a
side-table string pool referenced by index; the overwhelmingly common single-codepoint case never
touches it.

Wide-character invariants, enforced in `Grid`:

* A width-2 cluster occupies cell *n* (`width == 2`) and cell *n+1* (`width == 0`, `char == '\0'`).
* Writing to either half blanks both halves before writing.
* A width-2 cluster cannot start in the last column. Default policy is to blank the last column and
  place the cluster at the start of the next line if the writing cursor has autowrap on, or to drop
  it if not. This is a documented, configurable policy — not silently defined by whichever branch
  the code happened to take.

### Grid, damage, and scroll hints

`Grid` keeps a flat cell slice plus a per-row FNV-1a hash, invalidated on write and recomputed
lazily. `Buffer` holds two grids:

* **back** — what the application has drawn; every write lands here.
* **front** — what the terminal is believed to be showing; only `#paint` updates it.

Damage tracking is per-row `{min_col, max_col}` spans plus a total dirty-cell count, so a paint with
no changes is a no-op without scanning, and a paint with a few changes scans only the affected rows.

When a buffer operation scrolls a region (a cursor writing past the region's last line, or an
explicit `#scroll` call), the buffer records a `ScrollHint {region, lines, direction}`. The painter
prefers these hints over rediscovering the scroll from row hashes; hint validation against the
hashes is what keeps a stale hint from corrupting the screen.

### Regions and scrollback

A `Region` is a rectangle plus scroll behaviour and an optional scrollback ring:

```crystal
region = buffer.region(x: 0, y: 1, width: 80, height: 20, scrollback: 5000)
```

Capacity defaults to `0` (rows scrolled off are discarded, the classic curses model). With a
capacity, evicted rows are pushed into a ring buffer of `Array(Cell)` rows, and the region exposes a
view offset so an application can scroll back through history without reimplementing it. When the
view offset is non-zero the region composites from scrollback during paint; the front/back diff is
unaffected because it operates on the composited result.

## Repaint algorithm

`Painter#paint(buffer, caps) : Array(Op)` then `Encoder#encode(ops, caps) : Bytes`. Splitting the
two is what makes both spec strategies possible: ops are asserted structurally, bytes are asserted
as golden strings.

### Operations

```text
MoveTo(x, y)          SetStyle(style_id)     PutText(String, width)
EraseInLine(mode)     EraseChars(count)      SetScrollRegion(top, bottom)
ScrollUp(n)           ScrollDown(n)          InsertLines(n)   DeleteLines(n)
ShowCursor / HideCursor  SetAutowrap(Bool)   BeginSync / EndSync   Raw(Bytes)
```

### Pass 1 — scroll extraction

For each region with damage:

1. Take any recorded `ScrollHint`s and verify them: for shift *s*, check that `back` row hashes
   match `front` row hashes offset by *s* across the claimed band.
2. If there is no hint, optionally run detection: for each candidate shift in ±(1..height-1), count
   matching row hashes. Take the best-scoring shift with at least three matching rows.
3. Estimate bytes. Scrolling costs `SetScrollRegion` + `MoveTo` + `SU`/`SD` + region reset (roughly
   20–25 bytes) and leaves *n* rows to redraw. Rewriting costs the sum of the per-row diffs. Emit
   the scroll only when it wins, and only when the `ScrollRegion` capability is present.
4. Apply the scroll to `front` so pass 2 diffs against the post-scroll state.

Line insert/delete (`IL`/`DL`) is the same machinery restricted to a shift that reaches the region
edge; it is checked in the same pass.

### Pass 2 — per-row diff

For each damaged row, walk the changed span and build runs. The interesting decisions:

* **Move versus reprint.** Skipping a gap of unchanged cells costs a cursor move (3–8 bytes). If the
  gap is shorter than the move, reprint the unchanged cells instead. The painter picks per gap.
* **Cheapest move.** Among `CUP`, `CUF`/`CUB`, `CR` + `CUF`, `HPA`, and a bare newline, choose by
  encoded length given the current emitted position.
* **Erase over spaces.** A trailing run of blank cells in the default background becomes `EL 0`
  (3 bytes) rather than *n* spaces. An interior blank run of sufficient length becomes `ECH`.
* **Style runs.** Cells are grouped by style id; each group emits one `SetStyle`. The encoder emits
  the shorter of a full `SGR 0` reset plus the new style, or the incremental delta from the
  currently emitted style.
* **Autowrap.** Autowrap is disabled for the duration of the paint and restored afterwards, which
  removes the bottom-right-corner scroll hazard entirely rather than special-casing it.
* **Synchronized output.** When DEC 2026 is supported, the whole paint is wrapped in begin/end sync
  so the terminal shows no partial frame.

### Forced repaint

`#paint!` clears `front` to an impossible state, re-emits every active image, resets style and
cursor state, and rewrites all cells. Used after a resize, after suspend/resume, and on demand.

### Frame scheduler

`#paint` is always explicit and synchronous. `Terminal#start_frame_scheduler(fps: 60)` additionally
starts a fiber that coalesces damage and paints at most once per frame interval, skipping frames
with no damage. Off by default.

## Concurrency model

`TermBuf::Terminal` owns the buffer; no other fiber touches it.

* A **command channel** (`Channel(Command)`) carries every mutation. Public methods such as
  `#write_char` construct a command and send it. Commands needing a result carry a reply
  `Channel(T)` and the caller blocks on it — so `#paint` and `#size` read synchronously while
  `#write_char` stays fire-and-forget.
* A **batch API** (`terminal.batch { |batch| ... }`) accumulates commands locally and sends one
  `Batch` command, so a full-screen redraw is one channel operation rather than thousands.
* The **input reader** runs in a `Fiber::ExecutionContext::Isolated` context, since it blocks on
  `read`; isolating it means a blocked read cannot stall the owner fiber or the application's
  fibers.
* The **event channel** (`Channel(Event)`) is the only thing the application reads from.
* Shutdown closes the command channel, drains it, restores the terminal, then closes the event
  channel — so a crash in application code cannot leave the terminal in raw mode with the alt screen
  active. `at_exit` and signal handlers both route through the same restore path.

Layer 1 stays synchronous and is explicitly documented as *not* fiber-safe. That is fine: only the
owner fiber ever calls into it.

## Capabilities

`TermBuf::Capability` is an `@[Flags]` enum:

```text
Color16  Color256  TrueColor
Bold  Faint  Italic  Underline  DoubleUnderline  CurlyUnderline  UnderlineColor
Blink  RapidBlink  Reverse  Conceal  Strike  Overline
AltScreen  ScrollRegion  InsertDeleteLine  EraseChars  SynchronizedOutput
BracketedPaste  FocusEvents  MouseSgr  KittyKeyboard
Osc8Links  KittyGraphics  KittyGraphicsTempFile  KittyColorStack
Titles  CursorShape
```

Capping, enforced in the setter as `CLAUDE.md` requires: `TrueColor` implies `Color256` implies
`Color16`. `KittyGraphicsTempFile` implies `KittyGraphics`. `UnderlineColor` implies `Underline`.

Resolution order, each step overriding the last:

1. **Baseline** — pessimistic. Nothing is assumed supported.
2. **Env heuristics** — `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `COLORTERM`,
   `KITTY_WINDOW_ID`, `WEZTERM_EXECUTABLE`, `VTE_VERSION`, `KONSOLE_VERSION`, `ITERM_SESSION_ID`,
   matched against a table. `TMUX`/`STY` force a downgrade of anything the multiplexer will eat.
   `NO_COLOR` clears all colour bits.
3. **Active probes** — see below. Skipped entirely when stdout is not a tty.
4. **`TERMBUF_CAPS`** — final word, always wins.

### Active probing

All probes are written in one batch, then replies are read until the sentinel arrives or the
deadline (default 250 ms, configurable) expires:

| Probe | Sequence | Tells us |
|---|---|---|
| Primary DA | `ESC [ c` | device class, sixel |
| Secondary DA | `ESC [ > c` | terminal family and version |
| XTVERSION | `ESC [ > 0 q` | terminal name string |
| XTGETTCAP | `ESC P + q <hex> ESC \` | `Tc`, `RGB`, `setrgbf`, `Su` |
| DECRPM 2026 | `ESC [ ? 2026 $ p` | synchronized output |
| Kitty keyboard | `ESC [ ? u` | kitty keyboard protocol |
| Kitty graphics | `ESC _ G i=31,s=1,v=1,a=q,t=d,f=24;<data> ESC \` | graphics protocol |
| Kitty temp file | same with `t=f` and a real temp file | temp-file transport |
| **Sentinel** | `ESC [ 6 n` | *always* answered — bounds the wait |

Sending the cursor-position report last is what makes this reliable: its reply is the signal that
every terminal that was going to answer has answered, so the common case costs one round trip rather
than the full timeout. The timeout is only a backstop for terminals that answer nothing.

Probing writes to a raw, non-echoing tty and consumes only the replies it recognizes; anything else
read during the probe window is pushed back into the input decoder rather than discarded.

### `TERMBUF_CAPS`

```bash
TERMBUF_CAPS=+truecolor,-kitty_graphics,+osc8   # adjust specific capabilities
TERMBUF_CAPS=none,+color16                      # start from nothing, add one
TERMBUF_CAPS=all                                # assume everything
```

Names are the enum members in `snake_case`. A bare name enables, `-` disables, unlisted capabilities
keep their detected value. `none` and `all` are recognized as starting points. Unknown names are
ignored with a warning routed to the event channel, never to stderr — writing to stderr would
corrupt the screen.

### Size detection

`IO::FileDescriptor#winsize` first, then `ESC [ 18 t`, then the `CUP 999,999` + CPR trick, then
`tput cols`/`tput lines`, then `stty size`, then `COLUMNS`/`LINES`, then 80×24. `SIGWINCH` triggers
re-detection and a `Resize` event; resize resizes both grids, preserving content anchored at the top
left, and forces a full repaint.

## Unicode

`scripts/gen_unicode.cr` downloads the pinned UCD files (`UnicodeData.txt`, `EastAsianWidth.txt`,
`emoji-data.txt`, `GraphemeBreakProperty.txt`, `DerivedCoreProperties.txt`) and emits
`src/termbuf/unicode/tables.cr` as sorted range tables with a binary-search lookup. The generated
file is committed; the script exists so a Unicode release is a one-command regeneration, and the
spec suite includes `GraphemeBreakTest.txt` as a conformance fixture.

* **Width** — 0 for combining marks, most control and format characters; 2 for East Asian Wide and
  Fullwidth plus `Emoji_Presentation`; 1 otherwise. East Asian Ambiguous defaults to 1 with a
  configurable override, since it is genuinely terminal-dependent.
* **Graphemes** — full UAX #29 extended grapheme cluster breaking, including regional indicator
  pairs, `Prepend`, `SpacingMark`, emoji ZWJ sequences, and `InCB` linkers. Cluster width is the
  width of the base character, not the sum.

## Testing

Spectator, `crystal spec -v --error-trace`. Three complementary strategies:

1. **Model terminal** (`spec/support/model_terminal.cr`) — a spec-only terminal emulator that
   consumes the encoder's bytes and maintains its own grid: cursor movement, SGR, erase, scroll
   regions, `IL`/`DL`/`ECH`, autowrap. The core property is:

   ```text
   for any sequence of buffer operations:
     model.apply(encoder.encode(painter.paint(buffer))) == buffer.back
   ```

   This is the only way to establish that the diff is correct rather than merely plausible, and it
   catches the entire class of "optimization that emits fewer bytes and the wrong screen".

2. **Randomized sequences** — generate thousands of random write/scroll/style/resize sequences from
   a seeded PRNG, assert the property above after every paint. Failing seeds get shrunk by hand into
   named regression specs.

3. **Golden byte strings** — a small, deliberately chosen set pinning the specific optimizations:
   scroll region used instead of redraw, `EL` used instead of trailing spaces, SGR runs coalesced,
   cursor move versus reprint chosen correctly, colour downgraded under each capability mask.

Plus: UAX #29 conformance against `GraphemeBreakTest.txt`, width tables against known samples, and
capability resolution against a table of recorded probe responses from real terminals.

## Phases

Each phase ends green: formatted, `ameba` clean, specs passing.

### Phase 0 — Project setup

`VERSION` from the `shards version` macro, `.ameba.yml` copied from `~/.ameba.yml`, Spectator wired
in place of stdlib `Spec`, `crystal: ">= 1.21"` in `shard.yml`, `guard` dependency, `rumdl fmt` over
the Markdown, initial commit.

### Phase 1 — Unicode

Generator script, generated tables, width lookup, grapheme break iterator, conformance specs.

### Phase 2 — Core buffer

Colour with quantization, attributes, style, style table, cell, grid with wide-character invariants
and row hashes, regions, scrollback ring, buffer with damage tracking and scroll hints.

### Phase 3 — Painter and encoder

Op types, scroll extraction, per-row diff with the cost model, ANSI encoder with capability gating
and colour downgrade, forced repaint.

### Phase 4 — Spec harness

Model terminal, the round-trip property, randomized sequence specs, golden-string specs. Built
alongside Phase 3 rather than strictly after it — the model terminal is the development tool for the
painter, not an afterthought.

**Milestone 1 ends here.** At this point the core is complete and provably correct with no terminal
involved.

### Phase 5 — Capabilities

Capability enum with capping, env detector, active prober with the CPR sentinel, `TERMBUF_CAPS`
parsing, size detection.

### Phase 6 — Terminal driver

TTY control (raw mode, alt screen, winsize, `SIGWINCH`, `SIGTERM`/`SIGINT`, suspend and resume),
owner fiber, command channel, batch API, event channel, lifecycle and guaranteed restore, frame
scheduler.

### Phase 7 — Input

Byte reader in an isolated context, UTF-8 and escape-sequence decoder, basic key model with
modifiers, response-pattern registry with coalescing, passthrough API, bracketed paste.

### Phase 8 — Cursors and IO

Cursor state, region binding, autowrap and scroll behaviour, `IO` implementation so `puts`/`print`
work, the escape-scanning path for non-raw cursors and the fast path for raw ones, hardware cursor
association and post-paint positioning.

### Phase 9 — Links, images, colour stack

OSC 8 link ids threaded through `Style` and emitted as ranges; kitty graphics with transport chosen
by the Phase 5 probe, image placement, deletion, and re-emission on forced repaint; kitty colour
stack push/pop.

### Phase 10 — Documentation and release

README with worked examples, `examples/`, API docs, the versioned GitHub Pages docs workflow,
`v0.1.0` tag.

## Risks

* **Scroll detection correctness.** The highest-risk component: a wrong scroll corrupts the screen
  in a way that is hard to reproduce. Mitigation is hint-plus-verification rather than pure
  detection, and the randomized round-trip property.
* **Probe replies interleaved with user input.** A keystroke during the probe window must not be
  swallowed. Mitigation is pushing unrecognized bytes back into the decoder rather than dropping
  them, and probing before the application's input loop starts.
* **Multiplexers.** `tmux` and `screen` intercept or mangle DCS, APC, and OSC. Passthrough wrapping
  is possible but fiddly; the initial position is to detect the multiplexer and downgrade, and
  revisit in Phase 9.
* **`Cell` size.** Sixteen bytes per cell means a 300×100 terminal is ~480 KB per grid, ~1 MB for
  both. Acceptable, but worth measuring before adding fields.
* **Grapheme clustering cost.** Cluster segmentation on every write could dominate the write path.
  Mitigation is an ASCII fast path that skips segmentation entirely for the common case.

## Open items

Not blocking, decide when reached:

* Mouse tracking and the kitty keyboard protocol were deferred; confirm at Phase 7 whether they
  belong in `0.1.0` or a follow-up.
* Sixel as an image fallback for terminals without kitty graphics — currently out of scope.
* Whether `Region` should support overlap and z-ordering, or stay non-overlapping. Non-overlapping
  is assumed; widget layering would be built above this shard.
