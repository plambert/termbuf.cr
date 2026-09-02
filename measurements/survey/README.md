# The survey

Counted width for 5,274 clusters, measured in sixteen environments on 2026-09-01: four terminals,
each bare and under `tmux` and both builds of GNU `screen`. 84,384 readings, every one
of them answered.

Taken with `scripts/survey.sh`, which drives `scripts/measure_columns.cr` against
`measurements/corpus.tsv`. The plan is `measurements/SURVEY.md`; this is what it found.

## Sixteen environments, seven answers

**A multiplexer decides the answer completely.** Under `tmux`, all four terminals returned
byte-identical readings for all 5,274 clusters; the same holds under each `screen`. The
multiplexer answers `CPR` from its own accounting and never asks the terminal underneath, so the
host is not a variable — it is invisible.

That is why only seven directories are here rather than sixteen. The nine omitted runs are
byte-identical to the layer's representative and are reproducible with `scripts/survey.sh`.

## What each one counts

| implementation | matches our cluster width | matches per-code-point | carries the quirk | counts `👨‍👩‍👧‍👦` as |
|---|---|---|---|---|
| Ghostty 1.3.2 | 5,211 | 1,848 | no | 2 |
| kitty 0.48.2 | 5,141 | 1,815 | no | 2 |
| iTerm2 3.6.11 | 4,908 | 2,063 | no | 2 |
| `tmux` 3.7c | 4,574 | 2,107 | no | 2 |
| GNU `screen` 5.0.2 | 1,943 | 3,911 | **yes** | 11 |
| Terminal.app 470.2 | 1,845 | 5,268 | **yes** | 11 |
| Apple `screen` 4.00.03 | 1,606 | 859 | no | 4 |

Out of 5,274 each.

Both models survive the corpus growing seventy-nine fold. Against the terminal each was fitted to,
`Unicode.code_point_columns` misses **6 of 5,274** on Terminal.app and `Unicode.string_width`
misses **63** on Ghostty.

## GNU screen 5.0.2 carries `Quirk::PerCodePointColumns`

It counts the four joined faces as 11, the same as Terminal.app, and scores twice as well on the
per-code-point model as on cluster width. **No list of terminal names could have found this.**
Under a multiplexer `TERM_PROGRAM` still names the host — it read `Apple_Terminal` under
Terminal.app and `ghostty` under Ghostty — so a name-based rule would have called the same
`screen` session quirked under one host and clean under another, and been wrong at least once
either way.

Measuring it settles all four cases identically. This is the change made in `b0cb5c2` doing the
job it was made for, on an environment nobody had tried.

Apple's `screen` 4.00.03 is a third thing again: it counts the family as 4 and an emoji as one
column, which is a width table from 2006 meeting characters that did not exist yet. It matches
neither model, and no quirk describes it.

## What the terminals say we have wrong

Two findings, both by the standard that has held up: a cluster where independent implementations
agree with each other and against us is our bug, not their quirk.

### A format character takes a column

All six of Terminal.app's misses are the same shape, and two of them are confirmed by the
cluster-counting terminals as well:

| cluster | Terminal.app | we say | |
|---|---|---|---|
| `U+00AD` soft hyphen | 1 | 0 | `Cf` |
| `U+0600` arabic number sign | 1 | 0 | `Cf` |
| `U+061C` arabic letter mark | 1 | 0 | `Cf` |
| `U+200C` zero width non-joiner | 1 | 0 | `Cf` |
| `U+115F` hangul choseong filler | 2 | 0 | `Lo`, East Asian Wide |
| `U+3164` hangul filler | 2 | 0 | `Lo`, East Asian Wide |

The first four generalise a rule already in the model. The zero width joiner takes a column and so
does a tag character — both were discovered one at a time, and both are `Cf`. **The rule is that a
format character takes a column**, which would have predicted the tag case rather than waiting to
be surprised by it. The two fillers are a different matter: they are ordinary letters with an East
Asian Width of Wide, and our width table gives them zero.

### An emoji sequence is two columns whatever it starts with

Fifty-nine clusters have two or more of Ghostty, kitty, iTerm2 and `tmux` agreeing against our
cluster width. Forty-eight of them are one shape:

| we say | they say | count | example |
|---|---|---|---|
| 1 | 2 | 48 | `🏋🏻‍♀️` woman lifting weights, light skin tone |
| 2 | 3 | 7 | `क्ष्क` devanagari with two linkers |
| 0 | 1 | 2 | `U+00AD` soft hyphen |
| 1 | 0 | 2 | `U+2028` line separator |

The forty-eight all begin with a narrow pictograph — `U+1F3CB` is East Asian Neutral — and our
model takes the cluster's width from its first code point. The terminals do not: a joined emoji
sequence is two columns whatever it opens with. This is the same shape as `🏳️‍🌈`, which was
measured a year of clusters ago and treated as a curiosity rather than a rule.

The seven double conjuncts say the conjunct floor should not stop at two.

## What was changed as a result

Both rules are in, and the survey re-scored against every implementation:

| implementation | cluster width | per code point |
|---|---|---|
| Terminal.app 470.2 | 1,845 | 5,268 → **5,274** |
| GNU `screen` 5.0.2 | 1,943 | 3,911 → 3,917 |
| Ghostty 1.3.2 | 5,211 → **5,265** | 1,848 |
| kitty 0.48.2 | 5,141 → 5,183 | 1,819 |
| `tmux` 3.7c | 4,574 → 4,586 | 2,107 |
| Apple `screen` 4.00.03 | 1,606 → 1,620 | 859 |
| iTerm2 3.6.11 | 4,908 → **4,864** | 2,063 |

`Unicode.code_point_columns` now reproduces **every one of the 5,274** on Terminal.app.

The joined-emoji rule costs iTerm2 44 clusters, and that is the point rather than an oversight.
iTerm2 takes a joined sequence's width from its first code point, which is what our model used to
do; Ghostty and kitty both draw two for every joined sequence in the corpus. Being outvoted two to
one is the standard this project has been using, so iTerm2 becomes the odd one out and a candidate
for a quirk of its own rather than a reason to keep the old rule. Six of the 44 are cases where
only Ghostty backs the new answer, which is what a rule simple enough to state costs.

The double conjunct was **not** changed. Ghostty says 2, kitty says 1, iTerm2 and `tmux` say 3:
four implementations, three answers, no majority. That is a disagreement between terminals, not a
table we can fix.

## Files

Each directory holds the readings and the environment they were taken in.

* `counted.tsv` — cluster, what the implementation counted, and both model predictions.
* `environment.tsv` — terminal, multiplexer and version, window size, and what `DECRPM` said
  about mode 2027. Terminal.app does not answer it, iTerm2 calls it permanently reset, kitty
  calls it unsupported, Ghostty calls it reset.

To reproduce any cell of the matrix:

```bash
crystal build scripts/measure_columns.cr -o /tmp/measure_columns
scripts/survey.sh ghostty screen5 /tmp/out measurements/corpus.tsv
```
