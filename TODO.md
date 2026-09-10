# high-level TODOs for termbuf

## Shards

* `termbuf-input` — bytes and signals to events. Owns the event stream, timers, pattern
  registration, key/mouse/paste decoding. Knows nothing about modes or capabilities.
* `termbuf` — buffer, painter, encoder, capabilities, unicode, driver, cursors, regions, images,
  links, colours. Requires `termbuf-input`. Owns capability detection, terminal modes, and the
  middleware order.
* `termbuf-widgets` — layout, focus, keymaps, the editing model, and every control.
* Separate shards later: charts, markdown, QR, web terminal, terminal-in-a-widget.

Mouse lives in the input shard: a mouse report is input, the same way bracketed paste is. termbuf
enables the reporting modes; input just parses what arrives.

## 1. termbuf groundwork

Each of these is cheaper before the split than after.

* [x] Mode registry: a mode is registered with its unset, and `Tty#leave` unsets whatever was
  registered — including from the signal and `at_exit` paths. Lets another shard enable mouse
  reporting without leaving the terminal in it.
* [x] Per-cell style merge. Generalise `write(keep_background: true)` from a Bool to a merge
  function, so a panel can blend backgrounds, dim, or italicise what is under it.
* [x] Per-sink paint state. `Buffer` keeps the back grid; front grid, painter and encoder become
  per-sink. Required for the web terminal running alongside a local one.
* [x] `Capability::Osc52Clipboard` and a write API. Copy Button depends on it. Read is widely
  disabled for security; write is the useful half.
* [x] Probe mode 2027 (grapheme cluster mode) alongside 2026 and record it, even before anything
  consumes it.
* [x] Resize rate limit. `Events::Resize` carries old and new dimensions.
* [x] Verify `FocusEvents`, `CursorShape`, `Titles`, `MouseSgr` against terminals. All four are
  detected and unverified; the five removed capabilities this week were all unchecked table entries.
* [x] Gradients as a `Style` extension: a style whose colour is a function of cell position rather
  than a constant. Decide whether `View` carries it.
* [x] Clusters wider than two cells. iTerm2 charges 3 for `क्षि`; `Cell` holds a lead and one
  continuation. Touches `Grid#place`, `#detach`, `#clip_wide`, `#resize`, `Painter`, `Buffer#blit`.
  Extend the round-trip property first.

Already done, do not re-plan: synchronized output (`?2026`) is probed and wraps every frame.

## 2. Extract the input shard

* [x] Move `Key`, `Modifiers`, and the event types into the new shard. termbuf depends on it and
  nothing points back.
* [x] Event stream: IO events and timer events on one queue. Timers carry a nonce so a response and
  its timeout can be told apart. Lives inside the input shard until something else wants it.
* [x] Pattern registration: register a prefix (CSI, SS3, DCS, APC, OSC) and a callback that returns
  an event. The event type may be defined in another shard entirely.
* [x] Keep in the shard: normal keys, paste markers and their deadlines, escape timeout, kitty
  keyboard decoding.
* [x] Kitty keyboard is tellable, not required. With it on, Escape arrives as `CSI 27u` and the
  escape timeout is dead weight — a latency win, not a correctness one.
* [x] Signals as events: SIGWINCH, SIGTERM, SIGINT.
  + [x] Default for SIGTERM/SIGINT is exit; switchable to event mode per signal.
  + [x] Warn-then-exit mode counts non-contiguous repeats.
  + [x] Nothing writes to stderr while the alternate screen is up.
* [x] termbuf registers a restore hook that runs regardless of what the app does with the signal.
* [x] termbuf forwards registration so consumers never hold the input instance.
* [x] Middleware order is explicit data the app can inspect and reorder, not registration order.
* [x] Events stop being a closed union. Each shard cases on what it handles; `case ... when` with an
  else is deliberate here, against the project default.

## 3. Mouse

* [x] SGR mouse decoding in the input shard: `ESC [ < b ; x ; y M` and `m`.
* [x] termbuf enables and disables the reporting modes through the mode registry.
* [x] Hit test from screen cell to buffer position.

## 4. termbuf 1.0

* [ ] Settle the public API and hold it. Chasing breaking changes across three repos is the cost of
  skipping this.

## 5. Widget shard foundations

Nothing else in the shard starts until these are in.

### 5a. Layout engine

Reimplemented in Crystal from Clay's model (zlib, compatible with MIT — attribute it). Integer
cells, not floats.

* [x] Sizing per axis: fit, grow, fixed, percent — each with min and max.
* [x] Padding, gaps and borders are element properties, not wrapper elements.
* [x] Pass order: fit widths bottom-up, grow/shrink widths top-down, wrap text, fit heights
  bottom-up, grow/shrink heights top-down, position. Text wrapping between the axes is what makes
  height-for-width work.
* [x] Measure callback is `Unicode.string_width` with the live `WidthPolicy`, so the width probe
  feeds layout with no extra plumbing.
* [x] Percent apportions boundaries, not widths: `b(i) = (cum_weight(i) * total + total_weight / 2)
  / total_weight`, then take differences. Sums exactly by construction, no leftover pass.
* [x] Subtract padding and fixed gaps before apportioning, or gaps drift a cell on resize.
* [x] Min/max clamping re-opens distribution: clamp, re-apportion the unclamped siblings, repeat.
  Bounded by the sibling count, and it is the same loop grow/shrink runs.
* [x] Floating elements.
  + [x] Each float is a layout root, so floats nest — a menu inside a modal.
  + [x] Optional anchor of (element, attach point), resolved in a second pass after the base tree.
  + [x] Flip or clamp when a float would leave the screen.
  + [x] One list, walked forward for z-order and backward for event capture.
* [x] Dirty flag rather than laying out every frame.
  + [x] Set inside the setters for anything affecting geometry, never at call sites.
  + [x] Content counts as geometry: a fit-sized or wrapping widget resizes when its text changes.
  + [x] Plain references, no `WeakRef` — Crystal's GC collects cycles.
* [x] Layout and render are a bound pair with no input handling between them, so hit tests run
  against the rects on screen. Handlers mark dirty; they never re-run layout.
* [x] Spec-only mode that lays out every frame and compares against the cached rects, so a missed
  invalidation fails a test instead of surfacing months later.
* [x] Property tests over random trees: children inside their parent's content box, non-floating
  siblings do not overlap, sizes sum to the inner size less padding and gaps, layout is idempotent,
  every rect integral and non-negative.
* [x] Hand-written cases for percentages that do not divide, a min forcing a cascade, and a text
  change that alters height but not width.

### 5b. Focus and input routing

* [x] Focus ring with tab and shift-tab.
* [x] Modal scopes push and pop the ring.
* [x] Events go to the focused widget then bubble to its parents, and are dropped unclaimed.
  Reacting and consuming are separate.
* [x] Widgets may emit events. Emitted events go to the next frame, not the current one, or a cycle
  is possible.

### 5c. Keymaps

* [x] Prefix trie, not a flat map — `^V^A` has to work from the first version.
* [x] Ambiguity rule for a bound prefix: wait for the next key, or leave it unbound.
* [x] A binding carries its own description, so the help widget renders live bindings. No action
  enum in termbuf.
* [x] Keymap stack for pausing and restoring, sharing the modal stack mechanism.
* [x] Duplicate bindings within one map are caught when the map is built.

### 5d. Migration

* [x] Move `LineBuffer`, `Editor`, `History`, `Completion`, `Field`, `Border`, `PasteNotice` out of
  termbuf. Field was in termbuf because there was no widget shard; there is one now.
* [x] Widget test harness: render into a `Buffer`, assert on `to_text`.

## 6. Widgets

Grouped by what they depend on. Order within a group is appetite.

* [x] Primitives
  + [x] Label — wrapping, truncation with ellipsis, alignment
  + [x] Panel — padding, margins, borders, optional image foreground or background
  + [x] Scrollable panel, telling termbuf to scroll so it can pick a scrolling region over a repaint
  + [x] Scrollbar with a thumb, reading the state of what it wraps
  + [x] Divider
  + [x] Split panes with draggable dividers
* [x] Input
  + [x] Field (line, scrolls horizontally)
  + [x] Text area (expands horizontally, vertically, or both)
  + [x] Masked input, and validation
  + [x] Button, Button Group
  + [x] Checkbox, Checkbox Group
  + [x] Combobox
  + [x] Selection List — labels to values, cap on simultaneous selections
  + [x] Keyword List — autocomplete to slugs, select and delete
  + [x] List Selector — move items between two panels
  + [x] Form — grouping, tab order, validation aggregation
* [x] Navigation
  + [x] Navigation bar
  + [x] Tabbed panels
  + [x] Breadcrumbs
  + [x] Pagination control
  + [x] Disclosure
  + [x] Tree
* [x] Overlays (need floats and modal scopes)
  + [x] Dialog
  + [x] Popover
  + [x] Drop-down menu
  + [x] Drawer
  + [x] Toast — stacking, corner placement, timed dismissal
  + [x] Help overlay bound to the live keymaps
* [ ] Data
  + [x] Virtualized list — Tree, Data Grid and Selection List do not scale without it, and it cannot
    be retrofitted
  + [x] Table, fixed column widths first
  + [ ] Table auto-sizing with colspan and rowspan — its own algorithm, not the general layout
    engine, and deferred
  + [x] Data Grid
* [ ] Display
  + [x] Status bar — label/value pairs with formatting
  + [x] Progress Bar
  + [x] Spinner, at a configurable frame rate
  + [x] Single Value, colour-coded
  + [x] Icon — emoji, or image where available
  + [x] Image
  + [x] Link — clickable where supported, full URL on selection, copy
  + [x] Copy Button (needs OSC 52)
  + [x] Formatted Number, Bytes Display
  + [x] Rating
  + [x] Clock, Relative Time, Date Display
  + [ ] Calendar and Date Picker — large and locale-heavy, defer past 1.0
* [ ] Cross-cutting, not widgets
  + [ ] Animation — a frame clock plus interpolation over widget properties. Decide whether the
    clock moves to the event stream.

## 7. Separate shards

* [ ] `termbuf-charts` — bar, sparkline, single value first; box plot, time series and scatter need
  scales, tick selection and axis labelling. Where the image protocol earns its keep.
* [ ] `termbuf-markdown` — a viewer widget: block layout, nested lists, tables, code fences, inline
  styling. Syntax highlighting is out of scope.
* [ ] QR code — its own shard or an existing dependency. Check before writing Reed-Solomon.
* [ ] Terminal widget — a terminal inside a panel, with its own child process.
* [ ] Web terminal
  + [ ] One app serving a terminal mode and a web mode, optionally both at once and in sync. Depends
    on per-sink paint state from step 1.
  + [ ] Spike first: whether Ghostty ships a usable browser build, against xterm.js.
  + [ ] Optional title, defaulting to the program name.
  + [ ] Embedding: the app supplies an HTML fragment with a placeholder and receives
    `HTTP::Server` contexts for client requests. Second feature, after serving works.
