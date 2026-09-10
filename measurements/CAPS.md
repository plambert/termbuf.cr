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
   + **mouse** — turns SGR reporting on and waits for one click anywhere in the window.
     Recorded as `observed` the same way.
   + **`mouse_motion_1000`**, **`mouse_motion_1002`**, **`mouse_motion_1003`** — one reading per
     mouse tracking mode. Each turns its mode on, asks for the pointer to be moved across the
     window for three seconds with nothing pressed, and records `observed` yes when any SGR
     report arrived in that window, whatever button it named, and no when none did. The buffer is
     drained first, so the release that followed the click a step earlier is not counted as this
     window's answer.
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
| Terminal.app | 2.15 (build 470.2) | `terminal` | answers no DECRQM at all; the table is all there is |
| kitty | 0.48.2 | `kitty` | answers DECRQM, silent on DECRQSS |
| iTerm2 | 3.6.11 | `iterm2` | Automation approval needed the first time |
| `tmux` | 3.7c | `tmux` | `tmux -L termbuf -f /dev/null new-session -- /tmp/caps_check` |
| GNU `screen` | 5.0.2 | `screen-5.0.2` | `/opt/homebrew/bin/screen -c /dev/null -S termbuf-caps /tmp/caps_check` |
| GNU `screen` | 4.00.03 | `screen-4.00.03` | the macOS build, `/usr/bin/screen`, same arguments |

A multiplexer answers for itself and never asks the terminal underneath — that is what the width
survey found, and it is the reason both are in the list. A focus report has to cross two
implementations to reach the application, and either of them can drop it.

Private sockets and session names, no config files, and never type into a window this procedure
did not create. The rules of engagement in `SURVEY.md` apply here unchanged.

## What it would change

`Capabilities::MODERN` carries all four. Where the checks say a terminal that is unambiguously
modern does not honour one of them, the capability comes out of the preset and lives in
`EnvironmentDetector`'s tables instead, the way `Osc52Clipboard` and `GraphemeClusters` already do.

## Results

Seven runs on 2026-09-06, one per directory beside this file: `ghostty`, `kitty`, `iterm2`,
`terminal`, `tmux`, `screen-4.00.03` and `screen-5.0.2`. Those are the names the runs themselves
used, and each holds the `caps.tsv` the instrument wrote.

Each cell is what the person or the mode reporter saw, and then what the shard had concluded
before anyone looked. The seven FocusEvents readings were taken before the focus step required
a focus out followed by a focus in; on 2026-09-10 ghostty was seen to answer the enable itself
with `CSI I`, which the old step counted. Those cells need a second run.

| terminal | FocusEvents | MouseSgr | Titles | CursorShape | 1000 | 1002 | 1003 |
|---|---|---|---|---|---|---|---|
| ghostty 1.3.2 | yes, DECRQM agreed | yes, DECRQM agreed | yes, table agreed | yes, DECRQSS agreed | — | — | — |
| kitty 0.48.2 | yes, DECRQM agreed | yes, DECRQM agreed | yes, table agreed | yes, DECRQSS agreed | — | — | — |
| iTerm2 3.6.11 | yes, DECRQM agreed | yes, DECRQM agreed | yes, table agreed | yes, DECRQSS agreed | — | — | — |
| Terminal.app 470.2 | yes, table said no | yes, table said no | yes, table said no | yes, table said no | — | — | — |
| `tmux` 3.7c | no, DECRQM said yes | no, DECRQM said yes | skipped | yes, table agreed | — | — | — |
| `screen` 4.00.03 | no, table said yes | no, table said yes | no, table said yes | no, table said yes | — | — | — |
| `screen` 5.0.2 | no, table said yes | yes, table agreed | yes, table agreed | yes, table agreed | — | — | — |

The last three columns are the `mouse_motion_*` readings: whether the terminal reported anything
while the pointer moved with nothing held. All seven runs predate the rows, so every cell is `—`;
they fill in the next time the instrument is run. A `yes` under 1000 or 1002 there means a motion
report from that terminal is not evidence a button is held, and a consumer has to read
`Events::Mouse#button` rather than infer it.

Three things came out of that, and all three are now in the code.

**`Capabilities::MODERN` keeps all four.** On the three terminals with nothing in the way, every
one of the four was watched working and every query that could be asked agreed with the table.
There was nothing to prune.

**Terminal.app gains all four.** It answers no DECRQM, no DECRQSS and no XTGETTCAP, so the table
was the only evidence there was, and the table was wrong four times out of four: mode 1004 sent a
focus report, mode 1006 reported a click, OSC 2 renamed the window, and DECSCUSR changed the
cursor. `EnvironmentDetector::APPLE_TERMINAL_WATCHED` is those four.

**A multiplexer loses focus, the mouse and the title.** `EnvironmentDetector::THROUGH_MULTIPLEXER`
takes `FocusEvents`, `MouseSgr` and `Titles` off alongside the kitty protocols. `tmux` answered
`?1004;1$y` and `?1006;1$y` — it implements both modes — and forwarded neither, because
`focus-events` and `mouse` default off, and the title question was skipped because `set-titles`
does too. That is the shape of the thing: a multiplexer answers for the mode it knows rather than
for what it passes on. So `Prober#probe` now takes a set of capabilities to distrust, named by
`EnvironmentDetector.distrusted`, and a mode report saying *yes* for one of them is recorded as
answered and adds nothing. A report saying *no* is still trusted, since nothing forwards a mode it
does not know, and 2026, 2027 and 2004 stay trusted outright: a multiplexer implements those on
its own account, and synchronized output through `tmux` 3.7c was watched working.

`CursorShape` stays through a multiplexer. DECSCUSR reached the terminal through `tmux` and
through `screen` 5.0.2, and `screen` 4.00.03 swallowing it costs nothing anyone can see —
`Terminal#cursor_shape=` writes the sequence and reads nothing back.

### The two `screen` builds

4.00.03 delivered none of the four and 5.0.2 delivered three, and nothing in the environment tells
them apart: both set `TERM=screen`, both leave `TERM_PROGRAM` as whatever the terminal underneath
set, and neither answers XTVERSION. Assuming the worse of the two is what this shard does with
anything it cannot ask, so 5.0.2 loses the mouse and the title it would have honoured. A
configuration that does forward them says so:

```bash
export TERMBUF_CAPS=+focus_events,+mouse_sgr,+titles
```

The same line is the answer for a `tmux` with `focus-events on`, `mouse on` and `set-titles on`.

The instrument itself is unchanged and still records the raw answer: `scripts/caps_check.cr` calls
`Prober` without a distrust set, so a future run under a multiplexer will go on reporting
`focus_events decrqm yes` where the shard concludes no. That is the reading the file is for.
