# Implementation plan

Covers TODO.md sections 1–7 across three shards. Task ids: A is termbuf groundwork (TODO §1, the
termbuf side of §3, §4); B is `termbuf-input` (§2, the input side of §3); C is `termbuf-widgets`
(§5, §6). Supersedes PLAN.md's Phase 13 and its open items; PLAN.md stays as the record of
phases 0–12.

File and line references are to termbuf at `5575fc9`. Sizes are relative: S, M, L.

## Decisions

Settled by the design discussion, recorded so they are not reopened:

* Mouse decoding lives in `termbuf-input`; enabling the reporting modes lives in termbuf.
* A signal's repeat count survives intervening input and is cleared only by an explicit reset.
* Widgets leave termbuf before the 1.0 freeze (C8 precedes A11).
* Percent is `n` of 100 of the space left on the axis after gaps and the fixed and fit siblings,
  not of the whole content box as in Clay (decided 2026-09-05, so a fixed rule between two 50%
  panes fits); weighted grow covers shares.

Open, each with a recommendation:

1. Enable mode 2027 when a terminal has it? No. Record the flag only; enabling changes how the
   terminal counts clusters, which the width probe was measured without. Its own task later.
2. `Blend` signature: four-arg `(under, over, x, y)` from the start. Yes; gradients become a
   `Blend` with no second mechanism.
3. Rename `Commands::SetColors` to `Commands::Quiet`. Yes; pre-1.0, one grep, shared by the
   clipboard and the title.
4. Add `WidthPolicy#conjunct_spacing_adds` so the codebase can produce a 3-wide cell. Yes; without
   it A9 has no test.
5. `Terminal#window_resized` public. Yes; it is what makes the rate-limit spec deterministic.
6. Namespace `TermBuf::Input`. Yes.
7. `Events::Warning`, `Failure`, `Closed` move to the input shard. Yes; they carry primitives
   only, and the dispatcher needs `Failure` for a middleware that raises.
8. Input stays in-tree until B9, extracted at B10. Yes; one CI and one suite per step.
9. Drop `Terminal#responses` and `#decoder`. Yes; nothing outside `terminal.cr` uses them.
10. Bound-prefix ambiguity: a build-time `Conflict`, bindings at trie leaves only. Yes; no timer
    and no runtime choice. `^V^A` binds; `^V` alone cannot also be bound.
11. `Keymap(T)` generic so `Editor` keeps `Action` as data. Yes.
12. Widgets draw view-relative, `draw(view)`. Yes; `PasteNotice` already does, clipping is free.
13. The widget harness asserts on `Buffer#to_text` only. Yes; the painter round trip is termbuf's.
14. `Key.parse` lives in `termbuf-input`, where `Key` does. Yes.

## Sequence

```text
A1 A4 ──► B1…B7 (in tree) ──► A2 A3 A5 A6 ──► A7 ──► A9 A10 ──► B8 B9 B10 ──┐
                                                                             ├──► C8 ──► A11 ──► C9 ──► §6
C1…C7 (new repo, path dependency, no termbuf edits) ─────────────────────────┘
A8 whenever the console is free, after A1 and A2
```

* A1 and A4 first. B needs the mode registry as its restore hook, and `Events::Resize` should have
  both fields before the event types move.
* B1–B7 before the rest of A. Both tracks edit `terminal.cr`; A's larger edits (A5, A7) land after
  B has removed the reader and signal code.
* A2 before B2. Both edit `prober.cr`.
* C1–C7 alongside everything. New repository, depends on termbuf by path, touches nothing in it.
* C8 is the sync point: needs B9 so `Key` and `Events` have their final names.
* A11 after B10 and C8, or it freezes an API that is then deleted.

## Track A: termbuf groundwork

### A1. Mode registry (S–M)

* Files: `terminal/tty.cr`, `terminal/terminal.cr`, `terminal/command.cr`; new
  `spec/terminal/tty_spec.cr`; `spec/support/model_terminal.cr` (`dispatch_private` at 284–292
  raises on unknown modes; add 1000, 1004, 1006).
* API: `record Tty::Mode, name : String, set : String, reset : String`. Constants
  `BRACKETED_PASTE`, `FOCUS_EVENTS` (`?1004`), `MOUSE_SGR` (`?1000h?1006h` / `?1006l?1000l`),
  `KITTY_KEYBOARD` (`>1u` / `<u`). `Tty#enable(mode)`, `#disable(mode)`, `getter modes`. The same
  name replaces. `enable` before `enter` records and defers; after, writes. `leave` writes resets
  in reverse order and marks them unapplied; `enter` re-applies them, which is what fixes the CONT
  path (`terminal.cr:977-982` today loses anything not in `enter`). `leave` loses its capabilities
  parameter (`tty.cr:148`; callers `terminal.cr:202, 661`); bracketed paste moves onto the
  registry. `Commands::Mode(mode, enabled)` through the owner fibre; `Terminal#enable`,
  `#disable`. Writing to the device off the owner fibre would interleave with a frame.
* Specs: deferred and immediate enable, reverse reset, idempotent leave, re-enter re-applies,
  replace by name, disabling an unregistered mode is a no-op; terminal_spec "taking the terminal
  over" (118–136) asserts close emits every registered reset.
* Accept: close, the signal path, and `at_exit` each emit every reset exactly once; a mode enabled
  before `start` goes out at `enter`.
* Gotcha: `KITTY_KEYBOARD` is a push/pop stack, so `enable` is idempotent by name and never
  pushes twice.

### A2. General DECRQM probe, record 2027 (S)

* Files: `caps/prober.cr`, `caps/capability.cr`; `spec/caps/prober_spec.cr`.
* API: append `GraphemeClusters` and `Osc52Clipboard` at the end of `Capability`
  (`capability.cr:71`; flag bits are positional, so append-only). The batch (`prober.cr:56`) asks
  `?2026$p ?2027$p ?1004$p ?1006$p ?2004$p`. `interpret` (176–178) becomes one regex
  `/\A\e\[\?(\d+);(\d+)\$y\z/` over `MODE_CAPABILITIES = {2026 => SynchronizedOutput, 2027 =>
  GraphemeClusters, 1004 => FocusEvents, 1006 => MouseSgr, 2004 => BracketedPaste}`. Keep 1/2/3
  present, 0/4 absent (209). `GraphemeClusters` goes in no environment table and not in `MODERN`;
  it is measured only, and not enabled (decision 1).
* Specs: extend the "answers everything" fixture (66–112) with 2027/1004/1006; generalise "reads a
  zero as unsupported" (123); add "DECRPM 4 is absent". `TERMBUF_CAPS=+grapheme_clusters` parses
  through `Capability.parse?` for free.
* Accept: `?2027;1$y` sets the flag; `?1006;0$y` removes `MouseSgr` even when the name put it in.

### A3. OSC 52 write (S)

* Files: new `src/termbuf/clipboard.cr`, `terminal.cr`, `command.cr`, `caps/environment.cr`; new
  `spec/clipboard_spec.cr`.
* API: `class Clipboard` on the `ColorStack` pattern (`color_stack.cr:34, 111-115`):
  `initialize(capabilities, &sink : Bytes ->)`, `available?`, `enum Target { Clipboard; Primary }`
  (`c` / `p`), `copy(text, target = Clipboard)` emitting `OSC 52 ; c ; base64 ST`.
  `Terminal#clipboard`, lazy, issuing through the owner fibre. Rename `Commands::SetColors` to
  `Commands::Quiet, bytes : Bytes` — bytes that move no cursor and set no attribute — at
  `command.cr:41, 72` and `terminal.cr:464, 685, 867`. Environment: a `CLIPBOARD_WRITE` constant
  applied to kitty, ghostty, wezterm, foot; verified under A8.
* Specs: bytes and base64; nothing without the flag; target; terminal_spec "sends a copy in order
  with the frames around it", mirroring 905.
* Accept: `terminal.clipboard.copy "x"` puts `\e]52;c;eA==\e\\` on the wire after the pending
  frame.
* Gotcha: no chunking. Document the per-terminal payload cap rather than pretend.

### A4. Resize rate limit, old and new sizes (S–M)

* Files: `terminal/event.cr`, `terminal.cr`; `spec/terminal/terminal_spec.cr:490-632`.
* API: `record Events::Resize, size : ScreenSize, previous : ScreenSize`.
  `Terminal#window_resized(size = @tty.size)`, public, documented as what SIGWINCH calls.
  Leading edge issues; a burst inside `resize_interval` (property, default 50 ms, zero disables)
  spawns one fibre that sleeps out the remainder and issues `Commands::Resize.new(@tty.size)`,
  reading the size late so the trailing edge lands on the final geometry. `perform_resize`
  (815–836) captures `previous` before assigning.
* Specs: carries the size it left; ten calls in 5 ms produce one or two events with the last at
  the final size; a burst after the interval is fresh. The `size` argument keeps specs off the
  live terminal (`caps/screen_size.cr:55-56` falls through to it otherwise).
* Accept: dragging a corner queues at most one full repaint per interval.

### A5. Per-cell blend, replacing keep_background (M)

* Files: `core/style.cr`, `core/buffer.cr`, `command.cr`, `terminal/view.cr`,
  `examples/validate.cr:982`; `spec/core/buffer_spec.cr:135-207`,
  `spec/terminal/view_spec.cr:290-345`, `spec/core/invariants_spec.cr`.
* API: `alias Blend = Proc(Style, Style, Int32, Int32, Style)` as `(under, over, x, y)`.
  `Style::KEEP_BACKGROUND : Blend` (today's behaviour, `buffer.cr:186-191`), `Style::OVER`
  (`under.merge over`), `Style.blend(&block : Style, Style -> Style)` for the two-arg case.
  `Buffer#write`, `#write_char`, `#fill` take `blend : Blend? = nil`; `fill` places per cell when
  blending, `Grid#fill` otherwise. `Commands::Write/WriteChar/Fill` carry it; `keep_background` is
  removed, not kept as sugar. `Drawing#write/#write_char/#fill/#clear` accept `blend:`. `View`
  passes it through with buffer coordinates; A6 wraps for view-relative ones. A wide cluster takes
  the colour of its first half as now (`buffer.cr:154-155`).
* Specs: the "keeping the background" block against `Style::KEEP_BACKGROUND`; dims what is under;
  italicises what is under; receives the cell's position; fill blends per cell; view_spec asserts
  `.blend`; a blend op in `invariants_spec` `apply_operation` so pairing holds under it.
* Accept: every former keep_background spec passes in intent; a blend over N distinct backgrounds
  yields N styles.
* Gotcha: `StyleTable` only grows (`style_table.cr:14-17`). A blend yielding a new colour per cell
  interns one style per cell — fine per screen, unbounded under animation. Say so in the doc.

### A6. Gradients (M, after A5)

* Files: new `core/gradient.cr`, `view.cr`, `command.cr`; new `spec/core/gradient_spec.cr`;
  `spec/core/roundtrip_spec.cr`.
* API: a gradient is a position-aware `Blend`, not a `Style` field — `Style` is interned by value
  and a function is neither hashable nor comparable, and the encoder already narrows `Color.rgb`
  (`encoder.cr:369-382`). `struct Gradient(from, to, rect, axis)` with `#at(x, y)` (linear RGB,
  clamped outside `rect`), `#foreground : Blend`, `#background : Blend`. `View#blend` property;
  `Drawing#view(rect, style = DEFAULT, blend = nil)`. `View` composes the command's blend over its
  own and translates positions by its origin, so a gradient built against `view.bounds` is right
  through nesting (`view.cr:186-195`).
* Specs: endpoints, midpoint, clamp; a gradient view translates positions; roundtrip
  `apply_operation` (75–92) gains a gradient fill so the ANSI and NONE masks exercise narrowing.
* Accept: `screen.view(rect, blend: Gradient.new(...).background).clear` round-trips under all
  four masks.

### A7. Per-sink paint state (L)

* Files: `core/buffer.cr`, `core/grid.cr`, `core/painter.cr`, `terminal.cr`, new `core/sink.cr`;
  `spec/core/roundtrip_spec.cr:46-72`, `spec/core/painter_spec.cr`, `spec/core/buffer_spec.cr`
  (15 references to `front`, `commit_paint`, `painted?`), `invariants_spec.cr`, `field_spec.cr`.
* API: `class Sink` in core, no IO: `initialize(buffer, capabilities)`; `getter front, damage,
  painter, encoder`; `#paint(forced = false) : Array(Op)`, `#commit`, `#invalidate`, `#resize`.
  `Buffer#attach(sink)`, `#detach(sink)`; `Buffer#front`, `#commit_paint`, `#painted?`,
  `#take_scroll_hints` go; `Buffer#invalidate` fans out; `Buffer#resize` resizes attached fronts.
  Damage: `Grid` keeps watched `Damage`s (`Grid#watch/#unwatch`) and every `touch` loops — N is
  one or two — leaving `Grid#damage` and existing specs intact. Scroll hints: `Buffer` keeps a
  serialised log; each sink remembers the serial it consumed; `commit` trims below the minimum.
  `Painter#paint(buffer, sink)`; the stray `buffer.front.damage.clear` at `painter.cr:551` goes.
  `Terminal` builds one `Sink`; a second is an array push later.
* Specs: the roundtrip `Harness` becomes sink-based; new property "two sinks over one buffer"
  (MODERN and ANSI, each with its own `ModelTerminal`, agreeing after every step); "a sink
  attached mid-sequence catches up" (attach at step 30, invalidate, agree).
* Accept: existing roundtrip, painter, terminal specs pass; the two-sink property holds for the
  six seeds.
* Gotcha: `clear_overhang`, `watch_composed_drift`, `take_composed_drift` are per painter and so
  per sink; `Terminal#clear_overhang=` (263–270) and `report_composed_drift` (741–752) address the
  primary.

### A8. Verify FocusEvents, CursorShape, Titles, MouseSgr (M, console-bound)

No GUI launches from a session; these need Paul at the console, or a real terminal running the
validate example.

* FocusEvents: DECRQM `?1004$p` (A2) on kitty, ghostty, wezterm, foot; Terminal.app answers no
  DECRQM (`environment.cr:201-203`) and stays a table entry. Live: `enable Tty::FOCUS_EVENTS`,
  `expect_response "\e[", "I"` and `"O"`; the keys page shows the bytes on alt-tab.
* MouseSgr: DECRQM `?1006$p`; live: `enable Tty::MOUSE_SGR`, patterns for `M` and `m`; the
  motion page prints the raw report. Decoding is B6.
* Titles: no query exists (`CSI 21 t` is disabled by default everywhere). `Terminal#title=` →
  `OSC 2 ; text ST` via `Commands::Quiet`; save and restore through a registry `Mode` using
  `CSI 22;0 t` / `CSI 23;0 t`. Verify by eye; Terminal.app also via `osascript`.
* CursorShape: `Terminal#cursor_shape=` over `enum CursorShape { Default; Block; Underline; Bar }`
  with `blink`, emitting DECSCUSR `CSI n SP q`, registered as a `Mode` named `cursor_shape` with
  reset `CSI 0 SP q`. Try `DCS $ q SP q ST` (DECRQSS) in the probe as an experiment; xterm and
  ghostty answer, kitty does not.
* Record one `caps.tsv` per directory under `measurements/` (`capability  method  result`, method
  in decrqm, decrqss, observed) for ghostty 1.3.2, Terminal.app 470.2, kitty 0.48.2, iTerm2 3.6.11,
  tmux, screen. Then prune `MODERN` (`capability.cr:154-159`) to what was seen.

### A9. Clusters wider than two cells (L)

Order matters: the property comes first, fails, and then passes.

* A9a. `WidthPolicy#conjunct_spacing_adds : Bool = false` (`unicode/policy.cr:53-60`); with it
  `क्षि` is 3. Lift the caps at `grapheme.cr:235-236, 277` to a new `Cell::MAX_WIDTH` (4). The
  `क्षि` probe sample (`width_probe.cr:51`) gets `rule: "conjunct_spacing_adds", enabled: 3,
  disabled: 2`; `TERMBUF_WIDTHS` parses it through the existing table (`policy.cr:110`).
* A9b. `ModelTerminal#put_cluster/#detach` (`model_terminal.cr:315-347`) go to N columns: detach
  walks left to the lead and blanks lead plus width. `invariants_spec.cr:32-55` `check_pairing`
  becomes "a lead of width N is followed by exactly N−1 continuations, its extent stays on the
  grid, and every continuation's lead, found by walking left, covers it". The roundtrip `Harness`
  takes a policy for buffer and model; `ALPHABET` gains `क्षि`; each mask runs under the default
  policy and under `conjunct_spacing_adds: true`. The property fails here, which is the point.
* A9c. Core: `Cell#wide?` becomes `@width > 1`; `Grid#lead_of(x, y)` (walk left; also the hit
  test) and `#extent(x, y)`; `place` loops `columns.times`; `detach` uses `lead_of`; `clip_wide`
  detaches any cluster whose extent crosses an edge; `resize` checks the last `MAX_WIDTH − 1`
  columns; `Buffer#fill` rejects `> 1`; `#orphan?` becomes "extent not inside `taken`";
  `Painter#snapped_end` becomes `to + width − 1` (`painter.cr:363-365`; `merge_snapped` at
  339–341 already walks N); `View#clip_write_char` (`view.cr:152-153`) uses `x + columns > width`.
  `Encoder#advance` and `Cursor#advance` are already N-safe.
* Accept: roundtrip and invariants green under both policies; iTerm2's `क्षि` reading leaves
  `disagreements` (`width_probe.cr:100-107`).
* Gotcha: `Unicode.code_point_columns` and the per-code-point quirk path (`painter.cr:450-453`)
  compare against `cell.width`, which stays correct and is no longer bounded by 2.

### A10. Hit test (S, after A9c)

* Files: `core/buffer.cr`, `view.cr`, `terminal.cr`; `spec/core/buffer_spec.cr`, `view_spec.cr`.
* API: `record Buffer::Hit, x, y, lead, cell, text`; `Buffer#hit(x, y) : Hit?` (nil off grid; a
  continuation resolves to its lead); `View#local(x, y) : {Int32, Int32}?` (screen cell to view
  coordinates, nil outside); `Terminal#hit(x, y, &)` through `sync`. SGR reports are 1-based and
  the conversion is B6's. Cluster index within a `LineBuffer` is the widget shard's.

### A11. 1.0 (M, last)

After B10 and C8.

* Tier 1, frozen: `Terminal` (`open`, `start`, `close`, `restore`, `batch`, `paint`, `paint!`,
  `paint_async`, `sync`, `events`, `capabilities`, `quirks`, `widths`, `size`, `cursor`,
  `hardware_cursor=`, `hide_cursor`, `on_resize`/`forget_resize`, `expect_response`/
  `forget_response`, `link`, `images`, `colors`, `clipboard`, `enable`/`disable`, `title=`,
  `cursor_shape=`, `window_resized`, `start_frame_scheduler`/`stop_frame_scheduler`,
  `last_paint_bytes`/`total_paint_bytes`, `clear_overhang=`, `warn_composed_drift=`, the decoder
  timing properties); `Drawing` and everything mixing it in (`Batcher`, `BufferSurface`, `View`);
  `Buffer` minus `front`/`commit_paint`/`painted?`; `Sink`; `Cursor`, `CursorIO`, `Region`,
  `Rect`; `Style`, `Blend`, `Gradient`, `Color`, `Attributes`, `Underline`, `Link`, `LinkId`;
  `Capability`, `Capabilities`, `Quirk`; `ColorStack`, `Clipboard`, `ImageStore`, `Image`,
  `Placement`; `Unicode` (`string_width`, `each_grapheme`, `graphemes`, `truncate`, `ellipsize`,
  `fit`, `window`, `WidthPolicy`); `ScreenSize`; `TERMBUF_CAPS/QUIRKS/WIDTHS`; `Events::*` as
  re-exported from the input shard.
* Tier 2, documented "internal, may change in a minor": `Grid`, `Cell`, `Damage`, `Painter`,
  `Encoder`, `Ops`/`Op`, `StyleTable`, `ClusterPool`, `LinkTable`, `Tty`, `Prober`,
  `EnvironmentDetector`, `CapabilityResolver`, `CapabilityOverrides`, `QuirkOverrides`,
  `WidthProbe`, `SgrScanner`, `Meter`, `SizeDetector`, `Commands::*`.
* Before freezing: `Terminal.new` (`terminal.cr:144-153`) keyword-only after `tty`;
  `Terminal.open`'s five positional args (175–178) likewise; `Capability` documented append-only;
  and A1, A3, A4, A5, A7 must have landed or `Tty#leave`'s arity, `SetColors`, `Resize`'s shape,
  `keep_background`, and `Buffer#front` freeze wrong.
* Deliverable: a Stability section in README and a `# Stability: internal` line on every tier-2
  type.

## Track B: termbuf-input

Namespace `TermBuf::Input`; shard `termbuf-input`; repo `termbuf-input.cr`; entry
`src/termbuf-input.cr`. Every step leaves `crystal spec` green.

### What moves

| Today | New home |
|---|---|
| `Modifiers`, `Key` (`input/key.cr`) | `Input::Modifiers`, `Input::Key`, unchanged |
| `Decoder` (`input/decoder.cr`) | `Input::Decoder`; loses `@responses` and the `Response` emit (73, 190–193); gains `kitty_keyboard` |
| `ResponseScanner` (`caps/response_scanner.cr`) | `Input::SequenceScanner`; termbuf's `Prober` and `WidthProbe` require it from the shard |
| `ResponsePattern`, `ResponseRegistry` (`terminal/responses.cr`) | `Input::Pattern`, `Input::Patterns`; `ResponsePattern` survives only as `expect_response`'s return |
| `Events::Key/Paste/Pasting/Response/Closed/Warning/Failure` | `Input::Events::*` |
| `Events::Resize` | stays in termbuf, `include Input::Event` |
| `alias Event` (`event.cr:58-60`) | `module Input::Event`; termbuf `alias Event = Input::Event` |
| `start_reader/read_loop/read_next/emit` (`terminal.cr:884-943`), `EVENT_CAPACITY` | `Input::Reader`, `Input::Stream` |
| WINCH/TERM/INT/HUP handlers (947–965, 985–988) | `Input::Signals` |
| TSTP/CONT (970–983), `at_exit` (990–992), `restore` (641–662) | stay; registered as hooks through `Input::Signals` |
| decoder timing accessors (79–119), `expect_response`/`forget_response` (478–487), pending input (147, 166, 330, 357–365) | stay; forward to `@input : Input::Stream` |
| `Terminal#responses`, `#decoder` | dropped |
| `Unicode.utf8_length` | copied as `Input::Utf8.length` |

New in the shard: `Events::Timer(nonce)`, `Events::Signal(signal, count)`, `Events::Mouse`,
`Timers`, `Stage`, `Mouse`, `Key.parse`.

### Dependency resolution

* `Resize` carries `ScreenSize`, so it stays. Input emits `Events::Signal(WINCH)`; termbuf's
  `:resize` stage consumes it and issues `Commands::Resize` as at `terminal.cr:950-952`.
* `Warning`, `Failure`, `Closed` move; termbuf emits them through `stream.inject`, bypassing
  middleware as they bypass the decoder today.
* The prober keeps its synchronous collect loop (`prober.cr:99-131`); it runs before the stream.
* Input has no capabilities. Kitty is `Decoder#kitty_keyboard : Bool`, set by termbuf.
* Independence in CI from B9: `crystal build --no-codegen spec/independence.cr` requiring only
  `src/termbuf/input.cr`.

### Stream design

Three fibres, two contexts.

* `Input::Reader`: `Isolated.new("termbuf-input")` when `blocking: true` (termbuf passes
  `tty.managed?`), else `spawn`. Reads into a 4096 buffer and sends a copy on `@inbound`; EOF or
  `IO::Error` sends `Eof`. No `read_timeout` (removes `terminal.cr:922-937`).
* Dispatcher, `spawn(name: "termbuf-dispatch")` in the default context, the only fibre touching
  `Decoder`, `Patterns`, and stages. Over `Inbound = Bytes | Tick | Signalled | Eof`: bytes feed
  the decoder, sequences go to `Patterns`, results run the stage chain, then `@out`. A `Tick`
  whose nonce is the decoder's deadline calls `decoder.tick`; otherwise it becomes
  `Events::Timer`. After each feed or tick the decoder's deadline nonce is cancelled and re-armed
  from `read_deadline` (`decoder.cr:108-124`, unchanged). Decoding off the isolated thread is what
  lets a pattern callback from another shard touch that shard's state without a lock.
* `Input::Timers`: `after(span) : Nonce` (UInt64, atomic counter) spawns `sleep span` then sends
  `Tick` if still live; `cancel(nonce)` removes from a mutex-guarded set; the dispatcher drops a
  tick cancelled between sleep end and receive. One fibre per timer is fine at these volumes.
* Channels: `@inbound` capacity 16 (reader blocks, kernel backpressure); `@out` 256.
* Public: `events`, `preload(bytes)` before `start`, `start`, `close`, `after`, `cancel`,
  `inject`, `patterns`, `stages`, `signals`, `decoder`.
* A response and its timeout share `@inbound`, so a response always precedes a timer armed after
  its registration; the nonce is what lets a consumer discard one that raced.

### Registration and middleware

```crystal
enum Input::Prefix { CSI; SS3; DCS; APC; OSC; PM; SOS; Other }
record Input::Sequence, bytes : Bytes, prefix : Prefix, body : String, final : Char?

class Input::Patterns
  def register(prefix : Prefix, head = "", terminator : String? = nil,
               &handler : Sequence -> Event?) : Pattern
  def unregister(pattern : Pattern) : Nil
  def match(sequence : Sequence) : Event?   # dispatcher only; first non-nil wins
end

record Input::Stage, name : Symbol, handler : Event, (Event ->) -> Nil
```

`head` matches after the introducer (`?` for DECRPM, `<` for SGR mouse, `G` for graphics),
`terminator` the tail (`$y`, `\e\\`). Resolution order in the dispatcher is today's
(`decoder.cr:188-202`) with the registry check pulled out of `Decoder`: paste marker, patterns,
paste start/end, key. A stage's handler calls `emit` zero times to consume, once to pass or
replace, more to inject. `Stream#stages : Array(Stage)` is swapped by reference and snapshotted
per event; termbuf builds `[:resize, :signals]` at start and the app reorders it.

termbuf's own uses: the capability probe is unchanged and its leftovers go to `preload`; a
runtime DECRPM with timeout registers a `ModeReport` pattern, arms `after(250.ms)`, and cancels
whichever loses — the seam for mode 2027 and a live 2026 re-check; `expect_response(prefix,
terminator)` parses the string prefix into `(Prefix, head)` and registers a handler returning
`Events::Response`, so `ImageStore` works unchanged; mouse is a default pattern on `CSI <`
returning `Events::Mouse(button, x, y, modifiers, action)` for `M`/`m`, nil otherwise so garbage
still falls to `Key::Name::Unknown` (`decoder.cr:405-407`).

### Signals

```crystal
enum Input::Signals::Mode { Exit; Event; WarnThenExit }
signals.mode(Signal::INT) = Mode::WarnThenExit   # TERM/INT/HUP default Exit; WINCH always Event
signals.threshold(Signal::INT) = 2
signals.before_exit(&hook)                       # ordered, each rescued; termbuf registers restore
signals.on(Signal::TSTP, &hook) / on(Signal::CONT)
signals.reset_count(Signal::INT)
```

Exit runs the hooks, resets, re-raises (`terminal.cr:958-960` verbatim), then re-traps so a second
delivery still restores. Event sends `Signalled` and counts. WarnThenExit counts, and exits at the
threshold; the count survives intervening input. Nothing in the shard writes to stderr; the
"warning" is `Events::Signal(signal, count)` for the app to draw. TSTP/CONT logic moves verbatim
into hooks; the re-install at 981 goes away. With A1, `before_exit` and `at_exit` both become
`Tty#leave`.

### Kitty keyboard

`Decoder#kitty_keyboard = true` changes exactly two things: `read_deadline` skips the
`@pending_since` branch (112–114) and `tick` skips the escape flush (130–132). With flag 1 the
terminal never sends a bare ESC (Escape is `CSI 27u`, already handled). Close the gap at the same
time: codes 57344–57454 become private-use characters today (476); map 57358+ (CapsLock…),
57376–57398 (F13–F35), 57399–57425 (keypad) to `Key::Name`. termbuf enables `CSI > 1 u` and
disables `CSI < u` through the mode registry when `Capability::KittyKeyboard`, then sets the flag.

### Steps

1. Open the union in place (S). `module Event`, each record includes it, delete the alias. Fix
   `field.cr:326-335`, `examples/clock.cr:44-64`, `examples/validate.cr:1213-1224`, and the doc at
   `paste_notice.cr:12-13` to `case ... when` with an `else`. Specs unchanged.
2. Stream and Patterns in tree (L). `src/termbuf/input/{stream,reader,patterns,scanner}.cr`;
   `response_scanner.cr` moves to `input/scanner.cr` and the prober/width-probe requires follow.
   `Terminal` holds `@input = Input::Stream.new(tty.input, blocking: tty.managed?)`, forwards the
   accessors, deletes 884–943, uses `preload`. Specs: decoder_spec "responses" (171–185) rewritten
   against `Patterns`; terminal_spec 1277–1335 becomes `spec/input/patterns_spec.cr`;
   response_scanner_spec moves. Accept: terminal_spec "input" (634–808) passes unchanged.
3. Timers (M). `Input::Timers`, `Events::Timer`, decoder deadline re-armed via `after`; reader
   loses `read_timeout`. Specs: decoder_spec 233–310 unchanged; new `spec/input/stream_spec.cr`
   over a pipe covering after/cancel, a timer arriving after a key typed before it, and the escape
   flush via the timer path (mirrors terminal_spec 710–733).
4. Signals (M). `Input::Signals`, `Events::Signal`; termbuf registers `before_exit { restore }`,
   `on(TSTP)`, `on(CONT)`, and the `:resize` stage; delete 947–988. Specs: unit-test with
   `Signal::USR1/USR2` in Event and WarnThenExit modes; WINCH to `Events::Resize` through an
   unmanaged stream with `signals: true`; hook ordering with a fake exit proc. Gotcha:
   `Signal.trap` is process-global, so specs reset in `ensure`.
5. Stages as data (S). `Stage`, `Stream#stages`, `Terminal#stages`. Specs: consume, pass, inject,
   reorder.
6. Mouse (S). `Input::Mouse`, `Events::Mouse`, the default pattern; 1-based to 0-based here.
   Specs: press, release, motion, wheel, modifiers; `CSI <` garbage becomes an unknown key.
7. Kitty flag and PUA names (S). Specs: flag on gives a nil `read_deadline` with a lone ESC
   pending; `CSI 27u` is Escape; `CSI 57376u` is F13.
8. `Key.parse` (S). Inverse of `Key#to_s` (`key.cr:138`); space-separated sequence; `Ctrl+`,
   `Alt+`, `Shift+`, `Super+`; names from `Key::Name`; `Space`/`Nul` labels (`key.cr:149`).
   Normalise aliases (`Ctrl+I`/`Tab`, `Ctrl+M`/`Enter`, `Ctrl+H`/`Backspace`) at parse. Spec:
   `Key.parse(k.to_s) == [k]` for every name and modifier combination.
9. Namespace (M). Everything under `src/termbuf/input/` becomes `module TermBuf::Input`;
   `src/termbuf/input.cr` adds `alias Key`, `Modifiers`, `Decoder`, `Event`, and `Events::*`
   aliases; copy `utf8_length`; add `spec/independence.cr` and its CI step. Specs unchanged.
10. Extract (M). New repo: `src/termbuf-input.cr`, `shard.yml` (`crystal: '>= 1.21'`, no
    dependencies, spectator dev-dep), `spec/` from `spec/input/*` plus the scanner spec and the
    `Key` describe from decoder_spec 324–340, the same ci.yml minus the examples step. termbuf:
    delete `src/termbuf/input/`, depend on `github: plambert/termbuf-input.cr, version: ~> 0.1`,
    `require "termbuf-input"`; a git-ignored `shard.override.yml` with `path: ../termbuf-input.cr`
    for local work. Tag `v0.1.0` before the termbuf commit or CI's `shards install` fails. Gotcha:
    `shard.lock` is git-ignored here, so pin tightly until termbuf 1.0.

## Track C: termbuf-widgets

Namespace `TermBuf::Widgets`. Reimplements Clay's algorithm (`clay.h:2281`, `:2573`, `:1639`)
over integers in retained mode; attribute Clay (zlib) in LICENSE. Tasks C1–C7 touch nothing in
termbuf and run alongside tracks A and B. C6 and C7 are independent of C2–C5.

### Layout types

```crystal
enum Layout::Direction { Row; Column }
enum Layout::Align { Start; Center; End }

struct Layout::Sizing
  enum Mode { Fit; Grow; Fixed; Percent }
  getter mode, min = 0, max = Int32::MAX, weight   # weight: grow share or percent numerator
  def self.fit(min = 0, max = Int32::MAX); def self.grow(weight = 1, min = 0, max = Int32::MAX)
  def self.fixed(n); def self.percent(n)             # n of 100 of what fixed and fit siblings leave
end

record Layout::Padding, top, right, bottom, left
enum Layout::AttachPoint { LeftTop; CenterTop; RightTop; LeftCenter; Center; RightCenter;
                           LeftBottom; CenterBottom; RightBottom }
record Layout::Anchor, target : Widget?, element : AttachPoint, parent : AttachPoint, dx, dy
enum Layout::Overflow { Flip; Clamp }
record Layout::Floating, anchor : Anchor, z = 0, capture = true, overflow = Overflow::Flip
record Layout::Intrinsic, min, preferred
enum Layout::Wrap { Words; Anywhere; None }
```

### Widget base

The layout element is the widget; there is no separate declaration tree.

```crystal
abstract class Widget
  getter parent : Widget?; getter children = [] of Widget; getter tree : Layout::Tree?
  layout_property width : Sizing = Sizing.fit;   layout_property height : Sizing = Sizing.fit
  layout_property direction = Direction::Column; layout_property padding = Padding.all(0)
  layout_property gap = 0;  layout_property align_x, align_y = Align::Start
  layout_property border : Border? = nil          # one cell per side added to the inset
  layout_property clip_x, clip_y = false          # a scroll panel: children not compressed
  layout_property scroll_x, scroll_y = 0
  layout_property floating : Floating? = nil      # setter registers in tree.floats
  layout_property hidden = false
  property style : Style? = nil                   # renderer fills the rect before draw
  getter rect : Rect; getter min_size : {Int32, Int32}
  def content : Rect; def inset : Padding
  def add(child); def remove(child)
  def intrinsic_width(policy) : Intrinsic;  def height_for_width(width, policy) : Int32
  def draw(view : View) : Nil;  def cursor_position : {Int32, Int32}?;  def focusable? : Bool
  def handle(event : Event | Message, ctx : Router::Context) : Nil
  protected def invalidate_layout : Nil           # walks parents to the tree
end
```

`layout_property` generates a setter that returns early on an equal value and otherwise assigns
and calls `invalidate_layout`. No call site touches the flag. `Label#text=`, `Field`'s edits,
`PasteNotice#arriving/finished` (via `hidden=`) all go through it: content is geometry. Plain
references throughout; the GC collects the parent/child cycle.

### Tree and passes

`Layout::Tree` holds `root`, `floats` (push order is declaration order; a float declared inside a
float's subtree is pushed after its parent root, so list order resolves nesting without a sort),
`policy` (from `Terminal#policy`, `terminal.cr:546`), `screen`, `dirty?`; `layout(screen)`,
`layout_if_needed`, `invalidate`, `roots_in_z_order`, `hit(x, y)`. `screen=` with a different
rect marks dirty. `class_property verify_invalidation` is the spec-only mode.

For each root in `[root] + floats`:

1. `fit_widths`, post-order. Leaf: `intrinsic_width(policy)`. Row: sum of children plus gaps and
   inset; Column: max plus inset; `min_size` by the same formula over child mins. Fixed is `n`;
   Grow and Percent are 0 for now but propagate `min_size`. Hidden is 0.
2. `distribute_widths`, pre-order. `content = size − inset`. Percent children get boundaries over
   `base = content − gaps − fixed − fit`: `b(i) = (cum_pct(i) * base + 50) // 100`, sizes by
   difference. Then
   `remaining = content − gaps − fixed − fit − percent`; negative shrinks via `apportion` over Fit
   and Grow children (text only when `wrap != None`; skipped when the parent clips this axis);
   positive with grow children grows via `apportion`. Off-axis: Grow is `min(content, max)`;
   every child clamps to `[min_size, content]`.
3. `wrap_text`: every leaf sets `height = height_for_width(rect.width, policy)`. Text leaves
   memoise words with cluster widths, invalidated by `text=` or a policy change.
4. `fit_heights`, post-order, as 1.
5. `distribute_heights`, pre-order, as 2.
6. `position`, pre-order: children along the axis from the content origin with `gap`; on-axis
   leftover by `align_x`/`align_y` when no grow child; a clipping parent subtracts its scroll.
7. Floats, in list order, after the base tree: Grow and Percent resolve against the anchor
   target's rect or the screen; run 1–6 on the subtree; position from attach points (integer
   halves floor, then `dx`/`dy`); on overflow, Flip mirrors the attach pair and recomputes, then
   clamps to `[0, screen − size]`; wider than the screen clamps to 0 and the View clips.

`apportion(slots, total, total_weight = nil)` is one loop for percent, grow and shrink: compute
boundaries over the unclamped slots with the TODO formula; any slot outside `[min, max]` is fixed
at the bound, subtracted from `total`, and removed; repeat until nothing clamps. Bounded by slot
count. Percent uses `weight = n`, `total_weight = 100`; grow uses the sizing weight and bounds;
shrink uses the current size as weight, `min_size` as min, current size as max. Subtract padding
and fixed gaps before apportioning.

Deliberate differences from Clay: a border consumes cells; shrink is proportional by boundary
rather than largest-first, so grow and shrink share the loop; anchors are plain references.

### Text measure

`TextMeasure.measure(text, policy) : Measured` — words as byte ranges with cell widths, widest
word, unwrapped width, newline flag — measured with `Unicode.each_grapheme(text, policy)`
(`grapheme.cr:311`) so the width probe reaches layout with no plumbing. `TextMeasure.wrap(measured,
width, mode)` per `Wrap`: Words fills lines and breaks an over-long word by cluster (`min` is the
widest word); Anywhere never straddles a wide cluster (`min` is the widest cluster); None is
unwrapped with height from newlines. Measure with the tree's policy, never `Unicode.policy`.

### Render and App

`Renderer.render(tree, screen : Drawing)`: for each root in z order, pre-order over visible
widgets: `clip = rect ∩ nearest clipping ancestor's content ∩ tree.screen`; `view =
screen.view(clip)` (the View is the scissor, and its style merge at `view.cr:420` is how a panel's
background reaches children); fill with `style` if set; `border.draw(view, view.bounds)`
(`border.cr:79`, unchanged); `widget.draw(view)`. A widget wanting a scrolling region calls
`view.scroll`, which becomes a `ScrollHint` (`buffer.cr:230`, `painter.cr:171`). The renderer
never calls `screen.clear` — it fills root rects — or the hints die.

`App(terminal, root)` holds `tree`, `focus`, `router`. `frame`: `layout_if_needed` → `batch {
Renderer.render }` → focused widget's `cursor_position` translated by its rect, or `hide_cursor`
→ `paint`. `pump`: drain `router.pending`, then terminal events. Handlers run only in `pump` and
only set properties, so hit tests run against the rects on screen. `App` takes a `Drawing`, a
size, and an event channel rather than a `Terminal`, so the spec `TestApp` needs no device.

### Focus, routing, keymaps

* `Focus::Scope(root, ring, keymap, index)`; `Focus::Stack` with `push(root, keymap)`, `pop`,
  `top`, `current`, `next`, `previous`, `focus(widget)`, `rebuild`. Rings rebuild on every layout
  (adding, removing, hiding are invalidations, so one flag serves both). Tab and Shift-Tab are
  bindings in the App's default keymap, not hard-wired. The top scope's root is a barrier for
  bubbling and for `focus`.
* `Router#dispatch(event, from = nil)`: target is `focus.current` for keys and paste, `tree.hit`
  for mouse, the emitter's parent for a `Message`. At each hop the widget's keymap runs through the
  matcher; if it fired, done; else `widget.handle(event, ctx)`; `ctx.consume` stops the walk;
  reacting without consuming is allowed. After the chain, the scope's keymap. Nothing consumed is
  dropped and `dispatch` returns false. `active_bindings` returns the chain's bindings with their
  source for the help overlay.
* `abstract struct Message` in the shard (`Field::Accepted(text)`, `Field::Cancelled`,
  `Field::EndOfInput`, `Button::Pressed`, `Form::Invalid(errors)`). `Widget#emit` appends to
  `router.pending`; `pump` drains it before reading the terminal on the next frame, from the
  emitter's parent upward. A widget cannot see its own message in the dispatch that emitted it.
  Once B1 lands, `Message` can include `Input::Event` if one channel is wanted.
* `Keymap(T)`: `Binding(keys : Array(Key), description, action : T)`, a trie of `Node(T)`,
  `build(&)`, `lookup(keys) : {Match, Binding?}` with `Match { Bound; Pending; None }`,
  `bindings`, `merge`. Build-time `Conflict` on a duplicate, a strict prefix of an existing
  binding, or an extension of a bound one (decision 10); aliases normalised at build.
  `Keymap::Matcher`, one per router, holds `pending : Array(Key)`; `feed(key, maps)` in bubbling
  order: any map Pending holds the key; the first Bound fires; all None clears and returns Unbound
  so the key falls through to `handle` (the insert rule at `editor.cr:237`). A pending prefix then
  an unbound key drops the prefix.
* The keymap stack is the focus stack; each scope carries a map. Pausing is pushing a scope.

### Migration

| Widget | Changes | Specs |
|---|---|---|
| `LineBuffer`, `History`, `Completion` | namespace only | move as-is |
| `Editor` | `Hash(Key, Action)` (`editor.cr:81`) becomes `Keymap(Action)`; `DEFAULT_KEYMAP` (84–149) becomes `Keymap.build` with descriptions; `handle` (219) feeds a matcher: Pending → `Outcome::Continue`, Bound → `perform`, Unbound → the insert rule | rewrite hash construction to `Keymap.build`; add `^V^A`, pending-then-unbound, a build conflict |
| `Border` | also a layout property: the engine adds a cell per side, the renderer draws it | `field_spec.cr:35-67` becomes `border_spec.cr` |
| `PasteNotice` | a `Widget`: `floating: Floating.new(Anchor.new(nil, Center, Center), z: 100)`, fit both axes, `border`; `intrinsic_width` is text width + 4, height 3; `arriving`/`finished` set `hidden`; `draw(view)` is the label write (`paste_notice.cr:78-79`); `centred` (81) and the fill go | `field_spec.cr:317-353` through the harness |
| `Field` | drop `bounds` (38), `run`/`repaint`/`step`/`settle` (288–357), and the terminal require; defaults `width: grow`, `height: fit(max: max_rows)`; `height_for_width` is text rows plus listing rows (+2 with a border); `draw(view)` uses `view.bounds` for `inner` (111) so the offsets in `draw_fixed`/`draw_wrapped`/`draw_listing` become 0; `cursor_position` (253) view-relative; `handle` routes `Events::Key` to `editor.handle`, `Events::Paste` to `editor.paste`, and emits `Accepted`/`Cancelled`/`EndOfInput`; `invalidate_layout` after every `handle`/`paste` | the `render` helper (`field_spec.cr:10-23`) becomes the shared harness; `bounds:` arguments become the harness screen size with the field as root, or a fixed-size child; cursor cases (201–233) subtract the old origin |

Then remove from termbuf: `src/termbuf/widgets/`, `spec/widgets/`, `src/termbuf.cr:11`, and the
field page of `examples/validate.cr` (`build_field` 877, `draw_field` 993, `field_key` 1327, the
`field?` branches at 1290 and 1346). Dropping `run` removes Field's only dependency on `Terminal`.

### Harness and property tests

`spec/support/harness.cr`: `render(widget, columns = 30, rows = 6, policy = DEFAULT)` builds a
`Buffer` with the policy, a `Tree`, lays out, renders into a `BufferSurface`, and returns
`to_text` lines rstripped; `press(target, keys : String)` via `Key.parse`; `type(widget, text)`;
`frame(app : TestApp)`. `spec_helper` sets `Layout::Tree.verify_invalidation = true`, so every
widget spec doubles as an invalidation test: when not dirty, snapshot every rect, run layout,
compare, and raise `Layout::MissedInvalidation` naming the widget on any difference.

`spec/layout/properties_spec.cr`: a generator over `Random.new(seed)` — depth ≤ 4, fan-out ≤ 5,
per-axis sizing from fit, grow(1..3), fixed 0..20, percent 0..100 with random `min ≤ max`,
padding 0..2, gap 0..2, random direction and alignment, optional border, Label leaves from an
alphabet with wide clusters, spaces and newlines, screens 1..60 × 1..24. Assert: every child
inside its parent's content box; non-floating siblings disjoint; on-axis sizes plus gaps equal
the content size when a grow child exists, else at most; percent sums match the boundary formula;
every rect inside the screen with no exception (`Rect.new` raises on a negative size,
`rect.cr:541`); layout twice gives identical rects, as does invalidate-then-layout; floats inside
the screen with stable z order. Spectator `sample seeds` as `invariants_spec.cr:75`.

`spec/layout/engine_spec.cr`, by hand: 33/33/34 in 10 → 3/3/4; 50/50 in 7 → 4/3; 25×4 in 10 →
3/2/3/2; grow mins 5/1/1 in 10 → 5/3/2; grow maxes 2/∞/∞ in 10 → 2/4/4; a grow Label going from
one row to two moves its sibling down; three percent children with gap 1 across widths 20..40 keep
`Σ + 2 == width`; shrink 8 and 4 into 6 with mins 2/2 → 4/2; float flip at the right edge, clamp
at the bottom, nested float, wider-than-screen float clamps to 0; clip parent leaves children
uncompressed and `scroll_y` shifts them; a Label's `@text` mutated directly raises
`MissedInvalidation` on the next `layout_if_needed`.

### Steps

1. Shard skeleton (S). `shard.yml` (termbuf by path in development, `github:` with a `branch:`
   after C8), `src/termbuf-widgets.cr`, `.ameba.yml` from termbuf, LICENSE with the Clay notice,
   `spec/spec_helper.cr`. Accept: `crystal spec` and `ameba` green with no specs. Do not commit a
   path dependency pointing at a checkout.
2. Layout core (L). `layout/sizing.cr`, `layout/padding.cr`, `widget.cr` with the
   `layout_property` macro and the dirty walk, `layout/tree.cr`, `layout/engine.cr` (passes 1, 2,
   4, 5, 6 and `apportion`), `layout/errors.cr`. Specs: `apportion_spec.cr` (exact sums, min and
   max cascades, bounded iterations, zero total, zero weights); `engine_spec.cr` minus text and
   floats. Gotchas: hidden children contribute no gap; a Fixed child larger than the parent clamps
   off-axis and overflows on-axis for the View to clip, as in Clay; `Int32::MAX` as a default max
   means clamp before summing, never sum maxima.
3. Text measure and Label (M). `layout/text_measure.cr`, `widgets/label.cr` (`text`, `wrap`,
   `align`, `ellipsis` via `Unicode.ellipsize` at `text.cr:50`, `style`), pass 3 wired in. Specs:
   `text_measure_spec.cr`, `label_spec.cr` through the harness, `properties_spec.cr` with the
   generator. Accept: every property holds for seeds 1..16.
4. Floats (M). `layout/floating.cr`, pass 7, `Tree#floats` registration, `Tree#hit`, z sort.
   Specs: the 9×9 attach matrix on a known parent rect, flip and clamp, nested float, hit test
   through a `capture: false` float, z order. A hidden or removed anchor target is treated as
   unanchored.
5. Renderer, App, harness (M). `renderer.cr`, `app.cr`, `spec/support/harness.cr`,
   `spec/support/test_app.cr`. Specs: `renderer_spec.cr` (a Label in a bordered Panel; clip to a
   scrolled panel; a float over content; style merge from a parent), `app_spec.cr` (frame sets the
   cursor; resize marks dirty). Accept: the harness renders every earlier spec's widget.
6. Keymap (M). `keymap/keymap.cr`, `keymap/matcher.cr`. Specs: lookup, `^V^A`, `Conflict` on
   duplicate, prefix, extension, alias; `bindings` order; `merge`; matcher pending-then-bound,
   pending-then-unbound drops the prefix, chain order.
7. Focus and Router (M). `focus.cr`, `router.cr`, `message.cr`. Specs: tab order is pre-order,
   hidden skipped, push/pop restores the index, `focus` outside the scope refused; target then
   parents, consume stops, react does not, the modal root is a barrier, unclaimed returns false, an
   emitted message is absent in the same dispatch and arrives on the next `pump`,
   `active_bindings` lists the chain. Gotcha: rebuild rings after every layout or a widget added
   this frame is unreachable by tab.
8. Migration (M). LineBuffer, History, Completion, Border (S each); Editor on `Keymap(Action)` (M);
   PasteNotice as a float (S); Field as an element (M), per the table. Then the removals from
   termbuf. Accept: termbuf's suite green without `spec/widgets`; the shard's suite reproduces
   every moved assertion; `examples/validate.cr` builds.
9. Example app (S). `examples/field.cr`: Field, PasteNotice, a Label of accepted lines, a help
   float listing `active_bindings`, driven by `App`; `align_y: End` keeps the field at the bottom
   on resize. Manual, on a real terminal.

### Section 6 order

Hard dependencies only; order within a group is appetite. Assumes C1–C7 and C8.

* Primitives: Label → Panel (padding, border, margin as outer padding, optional image background
  via `ImageStore`) → Scrollable panel (`clip_y`, `scroll_y`, `view.scroll`) → Scrollbar (reads
  the scrollable's state). Divider after Label. Split panes static after Panel; dragging needs A1
  and B6.
* Virtualized list right after Scrollable panel. It gates Selection List, Tree, Data Grid, Keyword
  List's chooser, and Combobox's list, and cannot be retrofitted.
* Input: Field → Text area (`Growth::Grow`, grow both axes) → Masked input and validation. Label →
  Button → Button Group. Checkbox → Checkbox Group. Combobox needs Field, Drop-down (C4), and the
  virtualized list. Keyword List needs Field, Completion, the list. List Selector needs two
  Selection Lists and Split panes. Form needs the focus ring and Message aggregation.
* Navigation: Navigation bar and Tabbed panels from the Button Group pattern and Panel;
  Breadcrumbs from Label and Link; Pagination from Button; Disclosure from Panel and a hidden
  toggle; Tree from the virtualized list.
* Overlays, all needing C4 floats and C7 scopes: Dialog (Button, modal scope); Popover and
  Drop-down (anchored floats with flip); Drawer (screen-edge anchor); Toast (a Column float at a
  corner, and B3 timers for dismissal); Help overlay (`active_bindings` and Dialog).
* Data: Virtualized list → Table with fixed widths → Data Grid. Auto-sizing with spans is its own
  algorithm, deferred.
* Display: Status bar, Single Value, Formatted Number, Bytes Display, Rating from Label; Progress
  bar from Label with a blend (A5); Image and Icon from `ImageStore`; Link from `Style#linked` and
  `Terminal#link` (`terminal.cr:474`), copy needs A3; Copy Button needs A3; Spinner, Clock,
  Relative Time, Date Display, and the Animation clock need B3 timers; Calendar and Date Picker
  deferred past 1.0.
* Groundwork that section 6 waits on: A5 for Dialog and Drawer backdrop dimming, Toast over
  content, Panel blend (design with an optional blend slot so they no-op until it lands); A3 for
  Copy Button and Link copy; A6 for Progress bar as an enhancement; A9 for Icon, Rating, and any
  Label containing a 3-wide cluster (the property alphabet should carry one so layout at least
  does not raise); A1 and B6 for Split-pane dragging, Scrollbar thumb drag, Button click, and
  hit-test routing; B3 for everything timed. A4 is needed by nothing here.

## Section 7: separate shards

Each is a spike or a shard of its own and is not planned here beyond its dependencies.

* `termbuf-charts`: bar, sparkline, single value need Label and a blend; box plot, time series,
  scatter need scales, ticks, axis labels, and `ImageStore`.
* `termbuf-markdown`: a viewer widget on Label, Panel, Table, and Link. Syntax highlighting out.
* QR code: check for an existing Crystal shard before writing Reed-Solomon.
* Terminal widget: a child process on a pty inside a Panel; needs a VT parser, which is a
  second `ModelTerminal`-sized piece of work.
* Web terminal: needs A7 (per-sink paint state) first, then a spike on Ghostty's browser build
  against xterm.js, then serving over a WebSocket, then embedding with app routes.
