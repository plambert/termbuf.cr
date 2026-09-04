# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The probe batch now asks DECRQM for modes 2027, 1004, 1006 and 2004 alongside 2026, in the same
  write, and reads all five through one table. Focus events, SGR mouse reporting and bracketed paste
  were previously guessed from the terminal's name and never confirmed.
- `Capability::GraphemeClusters`, DEC private mode 2027, set by the mode report and by nothing else.
  It is measured and never enabled: turning the mode on changes how the terminal counts clusters,
  and the widths this shard works from were measured with it off. No environment table claims it and
  it is not in `Capabilities::MODERN`.
- `Capability::Osc52Clipboard`, reading and writing the system clipboard through the terminal.
- `Clipboard` and `Terminal#clipboard`, writing the system clipboard with OSC 52.
  `terminal.clipboard.copy "text"` puts the base64 of the text's UTF-8 bytes on the wire in order
  with the frames around it, and `Clipboard::Target::Primary` sends it to the X11 primary selection
  instead. Gated on `Capability::Osc52Clipboard`: without it a copy writes nothing, since a terminal
  that does not take the sequence prints it. Nothing chunks and nothing is read back — OSC 52
  carries one payload, the limit on it belongs to the terminal, and a write is answered by nothing
  at all, so a caller moving more than a few kilobytes should not expect it to arrive and cannot
  find out that it did not.
- kitty, ghostty, WezTerm and foot now come out of `EnvironmentDetector` with
  `Capability::Osc52Clipboard`. Table entries pending live verification: OSC 52 answers nothing on a
  write, so there is no probe to settle it, and the evidence is each terminal's documentation and
  source rather than having watched a paste. xterm supports the write and ships it off, so it stays
  out. `TERMBUF_CAPS=+osc52_clipboard` still covers a terminal that is not named.
- `Blend`, a per cell rule for what style a write, fill or clear places: given the style already in
  the cell, the style being written, and the cell's position in the buffer, it returns the style to
  put there. `Style::KEEP_BACKGROUND` keeps the colour already behind each cell, `Style::OVER`
  merges the write onto what is there the way a view does, and `Style.blend { |under, over| ... }`
  wraps the blends that answer from the two styles alone. `Buffer#write`, `#write_char`, `#fill` and
  `#clear` take `blend:`, as do the same methods on `Drawing`, and a `View` passes it through — the
  position a blend is handed is the cell's in the buffer, since the view has already translated the
  write. Styles are interned and `StyleTable` only grows, so a blend returning a colour computed per
  cell interns a style per cell: bounded by the screen for one frame, unbounded across an animation.

- `Gradient`, a colour ramp across a rectangle, handed to a draw call as a `Blend` rather than
  carried in a `Style`: styles are interned by value, and a colour that depends on where the cell is
  neither hashes nor compares. `#at(x, y)` interpolates each channel between `from` and `to` along
  the horizontal or vertical axis, clamping outside the rectangle, and `#foreground` and
  `#background` wrap that as blends. The colours are always 24 bit, so the encoder narrows them to
  the palette or to the sixteen system colours per the terminal's mask and one gradient renders
  everywhere.
- `View#blend` and `Drawing#view(rect, style, blend)`, a blend every cell drawn through a view is
  settled by. Unlike the blend of a draw call, which is asked in the buffer's coordinates, this one
  is asked in the view's own — so a `Gradient` built against `view.bounds` paints the same ramp
  wherever the view is moved to and however deeply it is nested. A draw call's own blend still runs,
  on what the view's answered, the way a write's style wins over the view's.

- `Unicode::WidthPolicy#conjunct_wide?`, on by default, and a `WidthProbe` sample that settles it:
  whether a consonant conjunct joined by a virama is two columns whatever it opens with. A conjunct
  ligates into one glyph and what a terminal charges for that glyph is its own decision — ghostty
  and Terminal.app take two, kitty 0.48.2 takes one. The floor used to be unconditional, which put
  `क्ष` and `क्षि` at two on a terminal drawing them in one and left everything after them on that
  row a cell to the left. With the rule measured, the model reproduces all nine of kitty's readings
  for the Indic corpus where it previously matched two.

- `Terminal#window_resized`, which is what the `SIGWINCH` handler now calls, and
  `Terminal#resize_interval` (`Time::Span`, 50 milliseconds) limiting how often it acts. Dragging a
  window corner produces a signal for every geometry the window passes through, and a full repaint
  per pixel of travel is a repaint per pixel wasted. The first resize of a burst goes through at
  once; the rest collapse into a single further resize at the end of the interval, taken on the
  size the window settled at rather than one it passed through. Zero turns the limiting off. An
  application driving a pty whose size it sets itself calls `#window_resized` in the signal's
  place.

- `Placement#z` and a `z:` argument to `ImageStore#place`: where a picture sits against the text and
  against the other placements. Zero and above covers the text, which is the default and what an
  image drawn to be looked at wants; negative sits beneath it, so the cells keep their glyphs and
  the picture shows through wherever they are blank — a chart behind a table, a watermark. Higher
  covers lower among placements, so a cascade is a rising `z` and nothing else. Nothing is emitted
  at zero, which is what the protocol defaults to.
- A `WidthProbe` sample for `क्षि`, a conjunct carrying a spacing vowel sign, with no rule of its
  own. It is the composite of the two rules before it and it is there to catch a terminal that adds
  them up past what a cell pair can hold: iTerm2 3.6.11 charges three columns for it, where every
  rule in this design tops out at two. It comes back in `WidthProbe::Result#disagreements` and
  reaches the application as an `Events::Warning` naming the cluster, rather than being modelled
  wrong. The row still cannot line up on such a terminal — a cluster occupies a cell or a pair of
  them, and there is no third to put anything in — but it says so.

- `Tty::Mode` and a registry of them on the tty: `Tty#enable`, `Tty#disable` and `Tty#modes`, with
  `Terminal#enable` and `Terminal#disable` sending the change through the owning fibre so it cannot
  land in the middle of a frame. `Tty::BRACKETED_PASTE`, `Tty::FOCUS_EVENTS`, `Tty::MOUSE_SGR` and
  `Tty::KITTY_KEYBOARD` come with it. Registration is by name, so enabling a mode twice writes it
  once — `KITTY_KEYBOARD` pushes onto a stack the terminal keeps, and a second push against one pop
  leaves the keyboard changed after the program has gone. A mode enabled before the takeover is
  recorded and goes out with it; leaving resets what is set, newest first, and keeps the
  registrations, so taking the terminal back re-applies them.

### Changed

- `Commands::SetColors` is now `Commands::Quiet`: bytes sent after the current frame that move no
  cursor and set no attribute, so the encoder's idea of the screen survives them. The colour stack
  and the clipboard both issue through it, and the name no longer claims one of them.

- `Events::Resize` carries `previous`, the size being left, alongside the new one. An application
  that scales or scrolls to follow a resize needs to know which way the window went, and asking the
  terminal after the fact only ever gives the size it is already at. Constructing the event by hand
  takes the second argument.

- `Event` is a marker module every event type includes rather than a closed union of the ones this
  shard defines, so a shard with an event of its own can include it and send it down the same
  channel. Channels, signatures and instance variables typed `Event` are unaffected. A module type
  is open, so a `case` over events can no longer be exhaustive: the handlers in `Field`, and the
  examples, take a `when`/`else` and an `else` that leaves an unrecognised event alone.

- A DECRPM reply saying a mode is absent now takes the capability back off, where before it could
  only fail to add one. A value of 0 or 4 removes the capability whatever put it there — the
  environment tables, or the name the terminal gave for itself — because the report is evidence
  about the terminal on the other end where a name is evidence about the family it belongs to. The
  refusals are collected apart from the additions and applied at the end, so it does not matter
  which reply arrived first.
- `Capability` is documented as append-only. A flags enum numbers its members by position, so
  inserting one silently renumbers every member after it.
- Kitty no longer claims `Capability::Overline` or `Capability::Conceal`. Measured against 0.48.2:
  SGR 53 leaves the text unmarked where SGR 4 underlines it, and SGR 8 leaves it visible. Kitty's
  own terminfo agrees, declaring `blink` and `smxx` and neither an overline nor `invis` — where
  ghostty's declares `invis=\E[8m`. Ghostty, WezTerm and foot draw both, so they stay in
  `Capabilities::MODERN` and come off the one terminal by name.
- `Capabilities::MODERN` no longer claims `Capability::RapidBlink`, and the encoder steps a rapid
  blink down to an ordinary one rather than dropping it. SGR 6 is among the least implemented codes
  there is — kitty draws nothing at all for it where SGR 5 blinks — and this shard assumes a
  capability absent without a reason to believe otherwise. Text asked to blink rapidly now blinks
  slowly instead of sitting still, which is the same capping colour has always had. A terminal
  measured doing better can be given the flag by name.
- `examples/validate.cr`: the rich page pushes a different tint for each `c`, and draws what each
  level of the stack is holding. One tint cannot show a stack — popping from it looked identical to
  popping from nothing.
- `examples/validate.cr`: the cursors page accepts pasted text into its typing pane. It was arriving
  and being dropped, since only the field page had somewhere to put it. Typed and pasted text go the
  same way here, which is the application's decision to make rather than the shard's.
- `examples/validate.cr`: the rich page opens with one picture over the text and one under it, in
  boxes carrying the same words so the difference is the only thing to look at, and each `i` after
  that cascades another down and to the right on a rising `z`. The swatch is registered once and
  placed repeatedly, so the pixels cross the wire once rather than per press.
- `examples/validate.cr`: the cursors page says what its two escape-sequence rows are for. They are
  the same string down two cursors, one scanning it into attributes and one printing the bytes; the
  labels `scanned` and `raw` conveyed neither.
- `Tty#leave` no longer takes a capability set. Bracketed paste is on the mode registry now, so
  leaving gives back what was actually set rather than what a capability set says should have been.
  This is what a resume was missing: `Tty#enter` re-applies every registered mode, where before it
  knew only about the modes written into it, and anything the application had turned on came back
  from a suspend turned off.

### Removed

- `keep_background` on `#write` and `#write_char`, replaced by `blend: Style::KEEP_BACKGROUND`,
  which does the same thing and is one of many rather than the only one. The flag could only ever
  answer the one question; a blend answers whatever the caller asks, and `#fill` and `#clear` now
  take it too, which the flag never did.
- Input is now `Input::Stream`, under `src/termbuf/input/`, and `Terminal` holds one rather than
  running the reader itself. Two fibres instead of one: `Input::Reader` reads the device and puts
  what it read on a channel — in an isolated execution context when the terminal is a real one, so
  a blocking read stalls nothing else — and a dispatcher fibre feeds the decoder, offers each
  complete escape sequence to the registered patterns, and sends what came of it to the
  application. The escape and paste deadlines are the dispatcher's now, kept by a `select` on the
  inbound channel rather than by a read timeout, so they hold on an input that has none.
- Terminal replies are matched by `Input::Patterns` rather than by prefix and terminator strings. A
  pattern names an `Input::Prefix` — the introducer, `CSI` through `APC` — what has to follow it,
  what has to end it, and a handler that is given the parsed `Input::Sequence` and returns the
  event it makes of it, or `nil` to say it wants nothing to do with it and leave it a keystroke.
  That last part is the point: a reply and a key press are the same bytes, and until now the only
  thing an application could do about one was be told it arrived.
- `Terminal#expect_response` keeps its signature and now returns the `Input::Pattern` to hand back
  to `Terminal#forget_response`. It registers a handler emitting `Events::Response` with the same
  bytes as before, so nothing calling it needs to change.
- `ResponseScanner` is `Input::SequenceScanner` and lives in `src/termbuf/input/scanner.cr`. It was
  always the input decoder's as much as the capability probe's, and the probe is not where the
  splitting of a byte stream into escape sequences belongs.

### Removed

- `ResponsePattern` and `ResponseRegistry`, replaced by `Input::Patterns` and `Input::Pattern`.
- `Terminal#responses` and `Terminal#decoder`. The registry is `Terminal#input.patterns` and the
  decoder is `Terminal#input.decoder`; the timing accessors `Terminal#escape_timeout`,
  `#paste_notice`, `#paste_progress` and `#paste_stall` are unchanged.
- `Terminal::EVENT_CAPACITY`, which is `Input::Stream::CAPACITY` and still 256.

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
