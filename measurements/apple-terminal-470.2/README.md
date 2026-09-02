# Terminal.app 470.2

What this terminal draws, as against what it counts. Sixty seven grapheme clusters, photographed
and read back by `scripts/measure_glyphs.cr` and `scripts/read_glyphs.py`.

Taken on 2026-08-28:

| | |
|---|---|
| terminal | Terminal.app 470.2 (`TERM_PROGRAM_VERSION`) |
| system | macOS 26.5.2, build 25F84 |
| font | SFMono-Regular 18, profile "Basic" |
| window | 155 columns |
| geometry read from the pictures | cell 12 px, row 26 px |

## Why photographs

A terminal has three widths for a cluster and this one disagrees with itself about all three:

* **counted** — columns it takes off the row's budget. `CPR` reports this and nothing else.
* **advance** — where the render pen lands afterwards, on screen.
* **drawn** — how wide the glyph is painted.

`👨‍👩‍👧‍👦` counts 11, advances 2, is drawn 2. `🏳️‍🌈` counts 4, advances 1, is drawn 2 — which is
why a character written after it lands on top of the flag. No escape sequence reports the last
two, so the only instrument is the screen.

## Files

* `page-*.png` — the pages as photographed, kept in LFS. Each opens with a calibration
  staircase: a `|` on each of the first six rows, one column further along each time, which is
  where the cell and row geometry above came from.
* `manifest.tsv` — which sample is on which row of which page, with the padding and step count
  the reader needs.
* `measured.tsv` — the readings. Regenerate with
  `python3 scripts/read_glyphs.py measurements/apple-terminal-470.2`.

## What it says

```text
advance == drawn                43 of 67    no overlap in these
our cluster width == advance    46 of 67
our cluster width == drawn      47 of 67
per-code-point sum == advance   39 of 67
per-code-point sum == drawn     36 of 67
```

The width tables the shard ships are the best predictor of both numbers. The per-code-point
sum — what `CPR` reports, and what `Quirk::PerCodePointColumns` models — is the worst, which is
why the width probe's answers are rejected on a terminal carrying that quirk.

The pen has two modes. When the font composes a cluster into one glyph it advances by the
**first code point's width**: `🏳️‍🌈` starts with U+1F3F3 (East Asian Neutral) and advances 1,
`👨‍👩‍👧` starts with U+1F468 (Wide) and advances 2. When the font has no glyph it advances by
the **sum of the pieces it drew**: `👨‍👩` has no emoji of its own and advances 4, where the
family of three advances 2.

Composition is font coverage. `👨‍👩‍👧` composes and `👨‍👩` does not, same construction, and
nothing in Unicode says which. So no rule over code points predicts the pen here, and these
numbers hold for this terminal with this font and this version — nothing more.

## Reproducing

Inside the terminal being measured, font small and window large:

```bash
crystal run scripts/measure_glyphs.cr -- measurements/<name>
python3 scripts/read_glyphs.py measurements/<name>
```

The controls are the check that the instrument works: ascii 1/1, CJK 2/2, fullwidth 2/2,
hangul 2/2, block 1/1, box drawing 1/1. Anything else and the reader is wrong, not the terminal.
