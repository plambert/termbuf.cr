# Capability checks

Four capabilities had never been checked against a terminal:
`Capability::FocusEvents`, `MouseSgr`, `Titles` and `CursorShape`. All four are in
`Capabilities::MODERN`, and all four reach a terminal by way of a table of terminal names — a
statement about a family rather than about the thing on the other end of the pipe. They have been
checked now; the readings and what they changed are under [Results](#results).

Two of them can now be asked about directly and two cannot, which is the whole shape of the
problem.

| capability | what can be asked | what only a person can say |
|---|---|---|
| `FocusEvents` | DECRQM for mode 1004 | whether a report actually arrives |
| `MouseSgr` | DECRQM for mode 1006 | whether a click is reported |
| `CursorShape` | DECRQSS for the DECSCUSR setting | whether the cursor changes shape |
| `Titles` | nothing at all | whether the window's title changes |

A mode report says the terminal knows what the mode is. It does not say the terminal does
anything when the mode is on, and DECRQSS is an experiment: Terminal.app and kitty answer it with
silence, which is not evidence either way. So the instrument asks what can be asked and then asks
the person at the keyboard about the rest.

## The instrument

`scripts/caps_check.cr`. Build it once and run the binary, so the compile is not part of what the
terminal is being asked to do:

```bash
crystal build scripts/caps_check.cr -o /tmp/caps_check
```

Then, **in each terminal**, one command:

```bash
/tmp/caps_check --out measurements/<name>
```

It needs a real terminal at both ends and someone in front of it; it refuses to run through a
pipe. `--queries-only` skips the seven readings and records them as `skipped`, which is what a
scripted run should use.

## What it does

1. Records `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, the name the terminal gives itself in
   answer to XTVERSION, the window size, `TERMBUF_CAPS`, and any multiplexer in the way.
2. Runs `TermBuf::Prober` — the shard's own probe, not a reimplementation of it — which sends
   DECRQM for modes 2026, 2027, 1004, 1006 and 2004 and DECRQSS for the cursor style, all in one
   write, ending with the cursor position report every terminal answers.
3. Prints one row per capability: the capability, the method that settled it (`decrqm`, `decrqss`,
   `table`, or `override` when `TERMBUF_CAPS` had the last word), and the answer.
4. Walks seven readings, restoring everything it turned on as it goes:
   + **focus** — turns mode 1004 on and waits up to 45 seconds for `CSI O` followed by `CSI I`.
     Click another window and click this one back. Recorded as `observed`, yes or no, from
     whether both arrived rather than from what anyone thought they saw. Many terminals answer
     the enable itself with `CSI I` when the window already has focus; that report is recorded
     on its own row, `focus_report_on_enable`, and then discarded, since it says the terminal
     knows the mode and nothing about whether a switch is reported.
   + **mouse** — turns SGR reporting on and waits for one press anywhere in the window: a report
     whose button field has the motion bit clear. Recorded as `observed` the same way. A terminal
     may answer the enable itself with a report (ghostty sends the pointer's position as a motion
     report, button field 34); that goes on its own row, `mouse_report_on_enable`, and is
     discarded before the reading. The step then waits for the matching release — an SGR report
     ending in `m` — and only then ends. A person holds a button down for longer than the next
     step's drain, so a release left here would arrive during the step that follows and be read
     there as that mode's answer to its own enable.
   + **`mouse_report_on_enable_1000`**, **`_1002`**, **`_1003`** — whether turning that tracking
     mode on was answered with a report before anyone moved. Discarded before the reading below.
   + **`mouse_motion_1000`**, **`mouse_motion_1002`**, **`mouse_motion_1003`** — one reading per
     mouse tracking mode. Each says **hold the pointer still**, waits a second for that to be
     true, drains, turns its mode on, and gives the enable its grace to answer; only then does it
     say **now move it for three seconds**, and it records `observed` yes when at least three SGR
     reports arrived in that window, whatever button they named, and no otherwise. One report is
     what a terminal sends on its own when the mode is turned on; a moving pointer sends dozens.
     Enabling a mode under a pointer that is already moving makes the movement's first report the
     enable's answer, which is what the still pointer is for: the on-enable row measures the
     enable rather than the tail of the step before.
   + **title** — pushes the title with `CSI 22 ; 0 t`, sets it with OSC 2, and asks whether the
     window or tab now says so. Pops it with `CSI 23 ; 0 t` afterwards, which is itself worth
     watching: a terminal that takes OSC 2 and has no title stack leaves the new title behind.
   + **cursor shape** — asks for a blinking bar with DECSCUSR and asks whether the cursor
     changed, then sends `CSI 0 SP q`.

The last two take y, n, or q to skip; the first five are watched rather than asked. Nothing is
left on: the modes are reset, the title is popped, the cursor shape is given back, and the line
discipline is put back the way it was found.

### The three tracking modes

Mode 1000 is defined to report the press and the release and nothing in between. Mode 1002 adds
motion while a button is held. Mode 1003 reports every movement. So under 1000 and 1002, moving
the pointer with nothing held should produce no report at all, and a `yes` in either row is the
terminal reporting more than the mode asks for.

That matters to anything reading the reports. A motion report is not evidence that a button is
down: on a terminal with a `yes` under 1000 or 1002 it can arrive with nothing held, so a widget
that treats motion as a drag will drag things nobody grabbed. Read `Events::Mouse#button` and
decide from that.

A `no` under 1003 is a different finding: it says the terminal does not do any-event tracking, so
hover cannot be built on it there.

## Output

TSV to standard output, and to `<directory>/caps.tsv` as well when `--out` is given. The
environment is written as `#`-prefixed comment lines above the header, so one command per terminal
leaves one file behind.

```text
# term    xterm-ghostty
# term_program     ghostty
...
capability      method  result
focus_events    decrqm  yes
mouse_sgr       decrqm  yes
cursor_shape    decrqss yes
titles  table   yes
focus_events    observed        yes
mouse_sgr       observed        yes
mouse_motion_1000       observed        no
mouse_motion_1002       observed        no
mouse_motion_1003       observed        yes
titles  asked   yes
cursor_shape    asked   yes
```

Two rows for each of the four under test, and they are meant to be compared: a capability the
tables claim and the terminal does not honour is exactly the thing this is looking for. The three
`mouse_motion_*` rows have no query to be compared against; they are a reading of behaviour that
nothing claims either way.

## Where to run it

The environments, matching the survey's matrix in `SURVEY.md` as far as it goes. Both `screen`
builds, because the survey found they behave differently and the environment cannot tell them
apart:

| environment | version | directory | notes |
|---|---|---|---|
| Ghostty | 1.3.2 | `ghostty` | expected to answer everything |
| Terminal.app | 2.15 (build 470.2) | `apple-terminal-470.2` | answers no DECRQM at all; the table is all there is |
| kitty | 0.48.2 | `kitty` | answers DECRQM, silent on DECRQSS |
| iTerm2 | 3.6.11 | `iterm2` | Automation approval needed the first time |
| `tmux` | 3.7c | `tmux` | `tmux -L termbuf -f /dev/null new-session -- /tmp/caps_check` |
| GNU `screen` | 5.0.2 | `screen-5.0.2` | `/opt/homebrew/bin/screen -c /dev/null -S termbuf-caps /tmp/caps_check` |
| GNU `screen` | 4.00.03 | `screen-4.00.03` | the macOS build, `/usr/bin/screen`, same arguments |

A multiplexer answers for itself and never asks the terminal underneath — that is what the width
survey found, and it is the reason both are in the list. A focus report has to cross two
implementations to reach the application, and either of them can drop it, and which multiplexer
it is turns out to matter: `tmux` forwards a click and `screen` 4.00.03 does not.

Private sockets and session names, no config files, and never type into a window this procedure
did not create. The rules of engagement in `SURVEY.md` apply here unchanged.

## What it would change

`Capabilities::MODERN` carries all four. Where the checks say a terminal that is unambiguously
modern does not honour one of them, the capability comes out of the preset and lives in
`EnvironmentDetector`'s tables instead, the way `Osc52Clipboard` and `GraphemeClusters` already do.

## Results

Seven runs on 2026-09-10 between 13:32 and 13:37, one per directory beside this file: `ghostty`,
`kitty`, `iterm2`, `apple-terminal-470.2`, `tmux`, `screen-4.00.03` and `screen-5.0.2`. Each holds
the `caps.tsv` the instrument wrote. This is the third round and it is the record; what the two
before it asked and got wrong is under [Rounds](#rounds).

Every cell is what was watched. The last four columns are readings of behaviour that nothing
claims either way: the three tracking modes with nothing held down, and which enables the terminal
answered with a report of its own.

| terminal | FocusEvents | MouseSgr | Titles | CursorShape | 1000 | 1002 | 1003 | answered the enable |
|---|---|---|---|---|---|---|---|---|
| `ghostty` | yes | yes | yes | yes | no | **yes** | yes | focus |
| `kitty` | yes | yes | yes | yes | no | no | yes | none |
| `iterm2` | yes | yes | yes | yes | no | no | yes | none |
| `apple-terminal-470.2` | yes | yes | yes | yes | no | no | yes | none |
| `tmux` | no | yes | no | yes | no | no | yes | none |
| `screen-4.00.03` | no | no | no | no | no | no | no | none |
| `screen-5.0.2` | no | yes | yes | yes | no | no | yes | none |

The last column counts an enable answered only where the report was provoked by the enable. Every
`mouse_report_on_enable_1000`, `_1002` and `_1003` cell in all seven files is no, ghostty's
included: turning a tracking mode on under a pointer held still produces nothing anywhere. One
`mouse_report_on_enable` is yes, in the click step, on ghostty; the section below says why that is
the pointer moving rather than the enable answering.

The tables these runs printed already carry what the first two rounds changed, so the
`method`/`result` pairs agree nearly everywhere and the conclusions below are round three
confirming them rather than four fresh surprises. Three disagreements are left. `tmux` answers
`?1004;1$y` and sends no focus report, which is what the distrust set is for. `screen` 4.00.03 is
credited with `CursorShape` and changed no cursor. And `screen` 5.0.2 is denied the mouse and the
title it honours, because the shard cannot tell it from 4.00.03.

**`Capabilities::MODERN` keeps all four.** On the four terminals with nothing in the way, every one
of the four was watched working and every query that could be asked agreed with the table. There is
nothing to prune.

**Terminal.app has all four**, as it has since the first round. It answers no DECRQM, no DECRQSS and
no XTGETTCAP, so its name was the only evidence there was, and the name was wrong four times out of
four: mode 1004 sent a focus report out and back in, mode 1002 with SGR encoding reported a click,
OSC 2 renamed the window, and DECSCUSR changed the cursor.
`EnvironmentDetector::APPLE_TERMINAL_WATCHED` is those four.

**A multiplexer loses focus and the title; only `screen` loses the mouse.** `focus-events` and
`set-titles` ship off in `tmux` 3.7c and neither reached the application, and neither `screen`
build sent a focus report; `screen` 4.00.03 set no title either. That is
`EnvironmentDetector::THROUGH_MULTIPLEXER`. The mouse is the one reversal: asked under mode 1002
rather than mode 1000, `tmux` forwarded the click, so `MouseSgr` stays through `tmux` and comes off
under `screen` alone, which is `EnvironmentDetector::THROUGH_SCREEN` — applied when `STY` is set or
`TERM` starts with `screen`. The distrust set follows the same split: under `tmux` a present
`?1006;1$y` is believed again and only 1004 is distrusted, and under `screen`, which answers no
DECRQM of its own, both stay distrusted.

`CursorShape` stays through a multiplexer. DECSCUSR reached the terminal through `tmux` and
through `screen` 5.0.2, and `screen` 4.00.03 swallowing it costs nothing anyone can see —
`Terminal#cursor_shape=` writes the sequence and reads nothing back.

### ghostty reports motion nobody asked for

One reading, and it is ghostty's alone. Under mode 1002 it reports movement with nothing held: 1002
is defined as motion *while a button is held*, and ghostty treats it as 1003. No other terminal in
the seven does. The button field it sends for that movement is 34 — bit 32, the motion bit, over
button 2 — so a consumer reading `Events::Mouse#button` sees button 2, `Right`, with action
`Motion`, which is a right-button drag. Nothing was pressed.

That is the whole of it. Asked with the pointer held still, ghostty answers none of the three mouse
enables. The one `mouse_report_on_enable` it does show is the click step's, where mode 1002 was
already on and the pointer moved before the button went down, so the over-reporting under 1002 put
a report in the enable's grace window. Round two read that as ghostty answering enables with a
report claiming button 2; it is one behaviour, not two.

The focus enable is separate and stands: ghostty answers `CSI ? 1004 h` with a `CSI I` of its own
when the window already has focus, and none of the other six do. That report says the terminal
knows the mode and nothing about whether a switch is reported, which is why the focus reading wants
a focus out before it counts a focus in.

The 1002 behaviour is worth reporting upstream against ghostty 1.3.2-main. termbuf does not guard
against it, so on ghostty a consumer should not take a motion report under 1002 as proof that a
button is held; read `Events::Mouse#button` and decide from that.

### Rounds

Round one, on 2026-09-06, asked for a focus report without requiring a focus out first and asked
for a click under mode 1000. Round two, on 2026-09-10 between 13:01 and 13:13, put both questions
again under 1002 and with the strict focus step, and carried two artefacts of its own instrument:
the click step ended at the press, so the release landed in the next mode's enable grace, and each
tracking mode went on under a pointer that was still moving from the step before. Round three, the
runs above, ends the click step at the release and holds the pointer still for a second before each
enable. It is the record; where it and an earlier round disagree, it is the one to read.

### The two `screen` builds

4.00.03 delivered none of the four and 5.0.2 delivered three, and nothing in the environment tells
them apart: both set `TERM=screen`, both leave `TERM_PROGRAM` as whatever the terminal underneath
set, and neither answers XTVERSION. Assuming the worse of the two is what this shard does with
anything it cannot ask, so 5.0.2 loses the mouse and the title it would have honoured. A
configuration that does forward them says so:

```bash
export TERMBUF_CAPS=+focus_events,+mouse_sgr,+titles
```

The same line is the answer for a `tmux` with `focus-events on` and `set-titles on`; `mouse_sgr`
is already there without it.

The instrument itself records the raw answer: `scripts/caps_check.cr` calls `Prober` without a
distrust set, so a run under a multiplexer goes on reporting `focus_events decrqm yes` where the
shard concludes no. That is the reading the file is for.
