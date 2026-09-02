# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-09-02

### Added

- `ImageStore::TEMP_MARKER` and `ImageStore.temp_path`, which name a file the way a terminal will
  accept before reading it. Public because the prober shares them; an application has no reason to
  reach for either.

### Fixed

- `examples/validate.cr`: the rich page's keys do something. `c`, `C`, `i`, and `x` were written,
  documented in the page's own footer, and never dispatched — the handler was defined and nothing
  called it, so the page that demonstrates links, images, and the colour stack demonstrated only
  the links.
- `examples/validate.cr`: tab and shift-tab go round rather than stopping at the ends, so the last
  page is one shift-tab from the first instead of eleven tabs away. The arrow keys still stop,
  which is what leaves a way to tell which end you are at.
- Ghostty no longer claims `Capability::KittyColorStack`. It parses `XTPUSHCOLORS` and
  `XTPOPCOLORS` and does nothing with them: measured against 1.3.2, an OSC 11 read back after a
  push, a set, and a pop gives the value that was set rather than the one that was pushed, and
  `CSI # R` goes unanswered. Since the stack is what makes a colour change reversible, claiming it
  wrongly is worse than not having it — `Terminal#colors` was recolouring the terminal permanently
  and leaving it that way after the program had exited. There is no query for this, so it is denied
  by name, the way blinking is.
- A temporary file carrying pixels is named so that a terminal will read it. The protocol says the
  file must be a temporary one and terminals check rather than take the caller's word: ghostty
  wants the path under what `TMPDIR` names — `/tmp` is not that on a Mac — and the string
  `tty-graphics-protocol` somewhere in it. Every temp-file transmission was being refused with
  `EINVAL`, and `Prober#probe_temp_file` now asks about a path named the same way as the ones it
  is deciding for.
- Graphics replies use `q=1` rather than `q=2`, so a terminal's complaint survives while its
  acknowledgements are still suppressed. `Terminal#images` registers a response pattern for them,
  which is what stops one arriving as a burst of keystrokes nobody pressed — the reason they were
  silenced outright before. The `EINVAL` above was thrown away by the old setting.

## [0.2.0] - 2026-09-02

### Added

- **Hyperlinks.** `Link` and `LinkTable` intern a URI and the OSC 8 grouping parameter, `Buffer#link`
  and `Terminal#link` hand back the id a `Style` carries, and the encoder emits the sequence when
  the id changes from one run to the next. A link is not an SGR attribute and `SGR 0` does not close
  one, so it is tracked apart from the rest of the style. Without `Capability::Osc8Links` it is
  stripped from the effective style, so two runs differing only by a link are one run and an
  application that sets links pays nothing on a terminal that has none.
- **The terminal's own colours.** `Terminal#colors` pushes and pops the Kitty colour stack and sets
  the defaults, the cursor, the selection, and palette entries. All of it needs
  `Capability::KittyColorStack`, the setters included: the stack is what makes a change reversible,
  and without somewhere to put the old values there is no way to give them back. `Terminal#close`
  pops whatever is still pushed, so an application that forgets — or that stops on a signal — still
  gives the terminal back the colours it was found with.
- **Images.** `Image`, `Placement`, and `Terminal#images` transmit pixels once and place them as
  often as wanted, over the cells of each frame rather than into the buffer. The transport is the
  probe's: a temp file where the terminal reads one, base64 in chunks where it does not, asked on
  the alternate screen so a terminal that cannot parse the query does not print it on the screen the
  person was looking at. Placements that no longer fit are dropped on a resize, everything is sent
  again on a forced repaint, and the pictures come down when the terminal is given back.
- `Unicode::WidthPolicy#joined_emoji_wide?`, on by default: whether a collapsed joined sequence is
  two columns whatever it opens with, rather than as wide as the code point it starts from. iTerm2
  3.6.11 is the one terminal of seven surveyed that does the latter. `WidthProbe` measures it from
  a joined sequence opening with a narrow pictograph, so no terminal has to be recognised by name;
  it is a policy rather than a `Quirk` because nothing is broken by it, and a buffer told about it
  lays the row out correctly. With the probe running, iTerm2 matches 5,200 of the survey's 5,274
  where the old model managed 4,908.
- `Terminal#clear_overhang?` and `Painter#clear_overhang?`, on by default: the cell after a glyph
  that may have painted outside its own columns is written again even when nothing in it changed.
  Both terminals measured draw over a neighbouring cell without repainting it first, and a
  cluster's ink runs past its columns often enough to matter — `ﷺ` is charged one column and
  painted across three, an uncomposed `👨‍👩` is charged two and painted across four. Nothing predicts
  which clusters overhang, so the rule is conservative and cheap: after anything that is not plain
  ASCII, write the next cell. Ordinary text pays nothing. An application that knows better, or
  would rather have the bytes, can turn it off.
- `Unicode.emoji?`, the Emoji property, generated into the tables beside
  Extended_Pictographic. The two are different questions and the difference is visible on screen:
  `⚑` is pictographic and is not an emoji, so a variation selector after it asks for a
  presentation it has not got, and the digits are emoji without being pictographic, which is what
  makes a keycap two columns.

### Fixed

- Probe queries are asked on the alternate screen. A terminal that does not recognise a query
  prints its payload instead of swallowing it, so asking on the screen the person was looking at
  left about forty five characters of rubbish there — `+q5463;524742pGi=31,s=1,v=1,a=q,t=d,f=24;AAAA`
  under Terminal.app — and it was still there after the program had given the screen back. The
  screen is now switched before the first query and switched back on the way out, so the echo goes
  where nobody sees it and leaves with the screen. A terminal with no alternate screen still has
  the line it landed on wiped, which is all that can be done for one. ([#7])
- `Unicode.code_point_columns` charges an **ignorable** character what East Asian Width says
  rather than nothing, which is one rule where the zero width joiner and the tag character had
  been two, and which also gives the hangul fillers the two columns they are due. Measured over
  5,274 clusters against Terminal.app 470.2 and GNU `screen` 5.0.2; it now reproduces every one of
  Terminal.app's, where it missed six.
- `Unicode.string_width` counts a joined emoji sequence as two columns whatever it opens with. The
  width used to come from the first code point, which is one for a narrow pictograph such as
  `U+1F3CB`; Ghostty and kitty draw two for every joined sequence in the corpus. Worth 54 clusters
  on Ghostty and 42 on kitty. iTerm2 takes the first code point's width, as we used to, and is
  measured rather than mispredicted — see `joined_emoji_wide` above.
- `Quirk::PerCodePointColumns` is now measured rather than matched on the terminal's name. The
  width probe already sends four faces joined by zero width joiners and reads the answer back, and
  that answer settles the question outright: eleven columns is per-code-point counting, where two
  is per-cluster and no policy can reach eleven. The answer overrides the guess in both
  directions, so a terminal that starts counting properly stops carrying the quirk and one nobody
  has tried is judged on what it does rather than what it is called. The `TERM_PROGRAM` match
  stays as the fallback for a terminal that does not answer.
- Cluster widths, against Terminal.app 470.2 and Ghostty 1.3.2 measured over the same sixty seven
  clusters. A variation selector now widens only a base with the Emoji property, so `⚑️` is one
  column and `1️⃣` is two; an indic conjunct is two columns rather than one, so `क्ष`, `ক্ষ` and `క్ష`
  match what both terminals count. `Unicode.string_width` now reproduces all sixty seven of
  Ghostty's counts, where it reproduced sixty two.
- `Unicode.code_point_columns` charges a tag character a column, so `🏴󠁧󠁢󠁳󠁣󠁴󠁿` owns eight, and composes
  conjoining jamo before counting, so `가` and `각` each own two. It now reproduces all sixty seven
  of Terminal.app's counts, where it reproduced sixty four. Both departures came from widening the
  sample set from forty-four clusters; neither shape was in the original set.

### Changed

- `examples/validate.cr`: tab and shift-tab move between pages everywhere, ctrl-r redraws
  everywhere, and the two pages with somewhere to type are entered with enter and left with escape,
  which is what frees tab to mean the same thing on every page. The capability grid draws each
  capability's name in the style it claims, so one the terminal ignores is a glance away from being
  spotted. The colours page carries a single hue from black to full, which bands under the palette
  where a sweep through every hue does not. The measured page keeps its sample in a column of its
  own, so a cluster the terminal counts differently cannot take the table with it. A page change
  repaints outright on a terminal with `Quirk::PerCodePointColumns`, which clears the rows that no
  longer carry such a cluster.

## [0.1.6] - 2026-08-28

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

[Unreleased]: https://github.com/plambert/termbuf.cr/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/plambert/termbuf.cr/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/plambert/termbuf.cr/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/plambert/termbuf.cr/compare/v0.1.5...v0.1.6
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
[#7]: https://github.com/plambert/termbuf.cr/issues/7
