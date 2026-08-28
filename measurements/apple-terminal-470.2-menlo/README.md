# Terminal.app 470.2, Menlo

The same sixty seven clusters as the run beside this one, in the same terminal, with the primary
font changed from SFMono-Regular to Menlo-Regular. It exists to answer one question: how much of
what that run measured belongs to the font.

Taken on 2026-08-28:

| | |
|---|---|
| terminal | Terminal.app 470.2 (`TERM_PROGRAM_VERSION`) |
| system | macOS 26.5.2, build 25F84 |
| font | Menlo-Regular 11, set on the window only |
| window | 155 columns, 67 rows |
| geometry read from the pictures | cell 14 px, row 28 px |

The font was set on the window rather than in a profile, so the "Basic" profile the other run
used is untouched and the comparison is between two windows of the same application.

## What the font moves

Four clusters of sixty seven, and no emoji among them:

| cluster | SFMono advance/drawn | Menlo advance/drawn |
|---|---|---|
| `a⃝` combining enclosing circle | 2/2 | 2/3 |
| `क्ष` devanagari conjunct | 1/2 | 1/1 |
| `क्षि` conjunct plus a spacing vowel | 2/3 | 2/2 |
| `நி` tamil na plus a vowel | 1/2 | 1/1 |

All four are scripts neither font covers. **A later run showed this is not a rendering
difference at all**: AtkynsonMono Nerd Font Mono covers none of them either, has different
coverage from Menlo and the same 14 px cell, and reproduces all four. The cause is the cell
getting wider, which moves the same glyph's overhang from 0.33 of a cell to 0.21 and across this
instrument's `INK = 0.25` floor. See `../apple-terminal-470.2-atkynson/`. Everything else is
identical, including every emoji: `👨‍👩` still fails to compose and
advances 4, `👨‍👩‍👧` still composes and advances 2, `🏳️‍🌈` still advances 1 across two drawn
columns. Menlo has no emoji either, so both runs got the same Apple Color Emoji from the same
fallback chain — **changing the primary font cannot reach the clusters that are in dispute.**

Scored the way the other run is scored:

```text
advance == drawn                45 of 67
our cluster width == advance    46 of 67
our cluster width == drawn      48 of 67
per-code-point sum == advance   39 of 67
per-code-point sum == drawn     32 of 67
```

Within a sample or two of the SFMono numbers, and the ranking is unchanged: the width tables the
shard ships predict both screen numbers better than the per-code-point sum does.

## What the font does not move

`counted.tsv` holds the third width — what the terminal charged the row, read back with `CPR`.
It was taken twice, once under each font, and the two files agree on all sixty seven clusters.
The SFMono pass is at `../apple-terminal-470.2/counted-sfmono/counted.tsv`. Counted width is the
terminal's own arithmetic and the font has no vote in it.

## Three clusters the counted-width model gets wrong

The per-code-point model reproduces 64 of these 67. It was fitted to 44 samples that did not
include either of these shapes:

| cluster | counted | model says | |
|---|---|---|---|
| `🏴󠁧󠁢󠁳󠁣󠁴󠁿` tag sequence | 8 | 2 | a tag character is charged a column, like the joiner |
| `가` lead + vowel jamo | 2 | 3 | conjoining jamo are composed before counting |
| `각` lead, vowel, tail | 2 | 4 | likewise |

So the rule is per code point *except* that conjoining jamo compose first — the one place this
terminal counts a cluster rather than its parts. The tag characters follow the rule the joiner
established and the model already breaks for: anything in the cluster is charged at least one
column.

## Files

* `page-*.png` — the pages as photographed, in LFS.
* `manifest.tsv` — which sample is on which row of which page.
* `measured.tsv` — advance and drawn. Regenerate with
  `python3 scripts/read_glyphs.py measurements/apple-terminal-470.2-menlo`.
* `counted.tsv` — counted width, with the two models beside it, from
  `scripts/measure_columns.cr`.
