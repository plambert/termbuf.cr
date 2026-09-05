# Capability checks

Four capabilities have never been checked against a terminal:
`Capability::FocusEvents`, `MouseSgr`, `Titles` and `CursorShape`. All four are in
`Capabilities::MODERN`, and all four reach a terminal by way of a table of terminal names — a
statement about a family rather than about the thing on the other end of the pipe.

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
pipe. `--queries-only` skips the four questions and records them as `skipped`, which is what a
scripted run should use.

## What it does

1. Records `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, the name the terminal gives itself in
   answer to XTVERSION, the window size, `TERMBUF_CAPS`, and any multiplexer in the way.
2. Runs `TermBuf::Prober` — the shard's own probe, not a reimplementation of it — which sends
   DECRQM for modes 2026, 2027, 1004, 1006 and 2004 and DECRQSS for the cursor style, all in one
   write, ending with the cursor position report every terminal answers.
3. Prints one row per capability: the capability, the method that settled it (`decrqm`, `decrqss`,
   `table`, or `override` when `TERMBUF_CAPS` had the last word), and the answer.
4. Walks four questions, restoring everything it turned on as it goes:
   + **focus** — turns mode 1004 on and waits up to 45 seconds for `CSI I` or `CSI O`. Click
     another window and click this one back. Recorded as `observed`, yes or no, from whether a
     report arrived rather than from what anyone thought they saw.
   + **mouse** — turns SGR reporting on and waits for one click anywhere in the window.
     Recorded as `observed` the same way.
   + **title** — pushes the title with `CSI 22 ; 0 t`, sets it with OSC 2, and asks whether the
     window or tab now says so. Pops it with `CSI 23 ; 0 t` afterwards, which is itself worth
     watching: a terminal that takes OSC 2 and has no title stack leaves the new title behind.
   + **cursor shape** — asks for a blinking bar with DECSCUSR and asks whether the cursor
     changed, then sends `CSI 0 SP q`.

The four questions take y, n, or q to skip. Nothing is left on: the modes are reset, the title is
popped, the cursor shape is given back, and the line discipline is put back the way it was found.

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
titles  asked   yes
cursor_shape    asked   yes
```

Two rows for each of the four under test, and they are meant to be compared: a capability the
tables claim and the terminal does not honour is exactly the thing this is looking for.

## Where to run it

The six environments, matching the survey's matrix in `SURVEY.md` as far as it goes:

| environment | version | notes |
|---|---|---|
| Ghostty | 1.3.2 | expected to answer everything |
| Terminal.app | 2.15 (build 470.2) | answers no DECRQM at all; the table is all there is |
| kitty | 0.48.2 | answers DECRQM, silent on DECRQSS |
| iTerm2 | 3.6.11 | Automation approval needed the first time |
| `tmux` | 3.7c | `tmux -L termbuf -f /dev/null new-session -- /tmp/caps_check` |
| GNU `screen` | 5.0.2 | `/opt/homebrew/bin/screen -c /dev/null -S termbuf-caps /tmp/caps_check` |

A multiplexer answers for itself and never asks the terminal underneath — that is what the width
survey found, and it is the reason both are in the list. A focus report has to cross two
implementations to reach the application, and either of them can drop it.

Private sockets and session names, no config files, and never type into a window this procedure
did not create. The rules of engagement in `SURVEY.md` apply here unchanged.

## What it would change

`Capabilities::MODERN` carries all four. Where the checks say a terminal that is unambiguously
modern does not honour one of them, the capability comes out of the preset and lives in
`EnvironmentDetector`'s tables instead, the way `Osc52Clipboard` and `GraphemeClusters` already do.
Nothing is pruned until the readings are in.
