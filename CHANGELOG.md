# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Quirk`, a flags enum beside `Capability` for what a terminal gets wrong rather than what it can
  do, with `TERMBUF_QUIRKS` to override detection. ([#6])
- `Quirk::PerCodePointColumns`: Terminal.app counts a grapheme cluster's columns by adding up its
  code points, so `👨‍👩‍👧‍👦` owns eleven columns and is painted in two, and everything after it on
  that row is nine columns out of step with every other row. The first such cluster drawn is
  reported on stderr with the alternate screen handed back, and as an `Events::Warning`.
  `Terminal.open(detect_composed_drift: false)` switches the check off; `#warn_composed_drift=`
  keeps it and leaves the screen alone. ([#6])
- `Unicode.code_point_columns`, the column count such a terminal takes for a string.

### Fixed

- The width probe's answers are ignored on a terminal with `Quirk::PerCodePointColumns`. It reports
  the columns it counts rather than the ones it paints — one for a variation selector emoji it
  draws in two — so taking those as rules had the buffer place text under the glyph. ([#6])

## [0.1.5] - 2026-08-28

### Fixed

- A marker variable left in the environment by whatever opened the window no longer outranks the
  terminal naming itself in `TERM_PROGRAM`. Terminal.app started from a shell that had ghostty's
  environment was inheriting `GHOSTTY_RESOURCES_DIR` and with it the kitty graphics protocol, OSC 8
  links, extended underlines, synchronized output, and the rest — none of which it has. ([#5])
- Terminal.app is measured rather than assumed: bracketed paste, which it was only getting from the
  leak, and no strike-through, which it takes and ignores. 24 bit colour arrived with the version
  that ships on macOS Tahoe, so it turns on at `TERM_PROGRAM_VERSION` 464 and a version that is
  missing or unreadable is treated as older. Terminal.app answers no query that would settle it —
  not `DECRQSS` for SGR, not `XTGETTCAP`, not `DECRPM` — so the version is all there is.

## [0.1.4] - 2026-08-28

### Added

- `Editor#completion`: what the last completion came to — `Idle`, `Inserted`, `Choices`, `Listing`,
  or `Nothing` — so an application can tell a completion that found nothing from one that was never
  asked for. `Field` says which under the line: `no match`, or how many matches there are before it
  will list them. Without it a completion key that finds nothing looks like a key bound to nothing.

- `Style#merge`: a style laid over another, each field the upper one leaves unset coming from
  below. Attributes combine rather than replace. ([#4])
- A `View` carries a style everything drawn through it merges onto, so a highlighted row is filled
  once and its columns name only what each adds rather than threading the row's background through
  every per-cell style. `Drawing#view` takes it. ([#4])
- `keep_background` on `#write` and `#write_char`: each cell keeps the colour already behind it and
  the style supplies the rest, for text over a background that varies under it — a label across a
  progress bar. ([#4])

### Fixed

- A `fill`, `scroll`, or `blit` whose edge landed inside a wide character gave the half lying
  outside the rectangle the incoming style, so the operation painted a column wider than it was —
  on the rows where a character straddled, and not on the others. That half now keeps the style it
  had and loses only its glyph. `Grid#place` is unchanged: a terminal erases what it displaces in
  whatever style it is writing in, and that is what typing over half a character should do.

### Changed

- `PasteNotice` draws through a styled view, so its label is cut at the panel edge rather than
  landing on what the notice was drawn over.

## [0.1.3] - 2026-08-27

### Added

- `Drawing#view`: a rectangle of a drawing surface addressed from its own top left and cut at its
  own edges, so a panel drawn over other content stays inside its border. Clusters crossing an edge
  are dropped whole, measured with the policy of the surface the view came from. Views nest.
  ([#3])
- `Buffer#blit` and `Drawing#blit`: copies cells out of another buffer, translating the styles and
  clusters it interned and keeping the widths it stored — what a shard compositing its own
  off-screen panels needs. ([#3])

### Changed

- Layering and z-order are settled against rather than deferred; see `PLAN.md`. Restore needs no
  layers, since the paint diff already sends only what a dismissed panel covered.

## [0.1.2] - 2026-08-27

### Added

- `Terminal#on_resize`: a handler run when the screen changes size, after the grids are resized and
  before `Events::Resize`, so an application relays new bounds to the regions it made in one place.
  `Terminal#forget_resize` takes one back. Layout stays out of this shard by design. ([#2])

## [0.1.1] - 2026-08-27

### Added

- `Unicode.truncate`, `Unicode.ellipsize`, `Unicode.fit`, and `Unicode.window`: width-aware text
  fitting for column layout, measured against a `WidthPolicy` and cutting on grapheme cluster
  boundaries. `Unicode::Align` picks which end of a `fit` keeps its position. ([#1])

### Changed

- `Border` trims an over-long title with `Unicode.truncate` rather than its own copy of the walk.

## [0.1.0] - 2026-08-25

First release. Everything below is new.

### Core

- Double-buffered cell grid with damage tracking and interned styles and clusters.
- Repaint by diff: scrolled regions are moved with `DECSTBM` and `SU`/`SD` where that is cheaper
  than redrawing, gaps are skipped when a cursor move costs more than reprinting them, and a
  trailing run is erased rather than written out.
- Capability-gated encoding. A 24-bit colour degrades to the 256 palette, then to the sixteen,
  then to none, depending on what the terminal turned out to have. Colours are stored as given, so
  raising the mask and repainting yields better colour with nothing lost.
- `Buffer`, `Painter` and `Encoder` work with no device attached, which is how they are tested.

### Terminal

- Raw mode, alternate screen, window size, signal handling, and restoration from `at_exit`.
- Capability detection in four stages: nothing, then `TERM` and friends, then the terminal's own
  answers to a batch of queries, then `TERMBUF_CAPS`.
- One fibre owns the buffer; everything that mutates it arrives as a command over a channel.
- Explicit `#paint`, forced `#paint!`, and an optional frame scheduler.
- `#last_paint_bytes` and `#total_paint_bytes`, since the byte cost of a frame is the claim the
  buffer exists to make.

### Input

- Keys with modifiers, decoded from the CSI, SS3, tilde, `modifyOtherKeys` and kitty forms.
- Bracketed paste, delivered whole rather than as a burst of key presses.
- Deadlines for everything held back: a lone escape, a half-arrived character, and a paste the
  terminal opened and never closed.
- Registered response patterns, so a reply to a query is told apart from a keystroke that looks
  identical.

### Unicode

- UAX #29 grapheme clusters and UAX #11 widths from tables generated from the UCD and committed.
- Cluster widths measured from the terminal at startup rather than assumed, because no two
  terminals agree about a four-emoji ZWJ sequence. `TERMBUF_WIDTHS` overrides or skips it.

### Cursors

- Cursors with their own position, style and region, wrapping and scrolling within it.
- An `IO` per cursor, so `puts` and `print` write into a pane.
- The terminal's own cursor follows a chosen one, and every paint puts it back.

### Widgets

- `Field`: an input field with a border, a prompt, horizontal or vertical growth, history,
  completion, and selection.
- `PasteNotice`: the panel that says a long paste is arriving.

### Not yet

- OSC 8 links, kitty graphics, and the kitty colour stack are detected but not emitted.
- Mouse reporting is not enabled or decoded.

[Unreleased]: https://github.com/plambert/termbuf.cr/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/plambert/termbuf.cr/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/plambert/termbuf.cr/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/plambert/termbuf.cr/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/plambert/termbuf.cr/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/plambert/termbuf.cr/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/plambert/termbuf.cr/releases/tag/v0.1.0
[#1]: https://github.com/plambert/termbuf.cr/issues/1
[#2]: https://github.com/plambert/termbuf.cr/issues/2
[#3]: https://github.com/plambert/termbuf.cr/issues/3
[#4]: https://github.com/plambert/termbuf.cr/issues/4
[#5]: https://github.com/plambert/termbuf.cr/issues/5
[#6]: https://github.com/plambert/termbuf.cr/issues/6
