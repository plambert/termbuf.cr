# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/plambert/termbuf.cr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/plambert/termbuf.cr/releases/tag/v0.1.0
