# Ghostty 1.3.2

The same sixty seven clusters as the Terminal.app runs beside this one, in a terminal that
disagrees with it about nearly everything.

Taken on 2026-08-28:

| | |
|---|---|
| terminal | Ghostty 1.3.2-main-+55a3e33ab |
| system | macOS 26.5.2, build 25F84 |
| font | SF Mono 11 |
| window | 265 columns, 64 rows, fullscreen |
| geometry read from the pictures | cell 13 px, row 29 px |

Run in a throwaway instance started with `config-default-files=false` and a config of its own, so
it read none of the user's settings: the colours, font, padding and fullscreen here are that file
and nothing else. It was fullscreen because Ghostty cannot be asked where its window is, so the
picture is the whole screen and the window has to be the only thing on it.

## The pen does not leave the grid

| | of 67 |
|---|---|
| advance == what it counted | **67** |
| advance == drawn | 56 |
| our cluster width == advance | 62 |
| our cluster width == drawn | 53 |
| per-code-point sum == advance | 40 |

**Every cluster advances by exactly the width it was charged.** Terminal.app manages 40 of 67
against its own count, because it lets the shaped advance drive the pen and counts columns
separately; Ghostty places each cluster at a cell origin, so the two cannot drift apart. Nothing
here lands on top of the character before it, and the two terminals agree on advance and drawn
together in only 36 of 67.

## What goes wrong here instead

The grid holds, so the failure moves into the ink: eleven clusters are painted wider than the
cells they were given, and spill over the neighbour.

| cluster | advance | drawn | Terminal.app adv/drawn | |
|---|---|---|---|---|
| `ﷺ` arabic ligature | 1 | 3 | 1/2 | |
| `❤` text presentation | 1 | 2 | 1/1 | |
| `🏳` no presentation | 1 | 2 | 1/2 | |
| `👨‍👩` | 2 | 4 | 4/4 | the uncomposed pair |
| `1⃣` keycap without a selector | 1 | 2 | 1/2 | |
| `a⃝` combining enclosing circle | 1 | 2 | 2/2 | |
| `a҈` combining cyrillic sign | 1 | 2 | 2/2 | |
| `நோ` tamil, two part vowel | 2 | 3 | 3/3 | |
| `ক্ষ` bengali conjunct | 2 | 3 | 1/2 | |
| `క్ష` telugu conjunct | 2 | 4 | 1/1 | |
| `กำำ` two sara am | 2 | 3 | 5/5 | |

`👨‍👩` is the clearest of them. Neither terminal has a glyph for it, so both draw the two faces
side by side across four columns — but Terminal.app moves the pen to match the ink and Ghostty
does not. Here the pair is charged 2, drawn across 4, and whatever is written next goes into the
third column, on top of the second face. **A cluster's ink can outlive its cells, so a neighbour
written afterwards needs the cells beneath it repainted.**

## Counted width: Ghostty counts clusters

| | of 67 |
|---|---|
| == our cluster width | 62 |
| == per-code-point sum | 40 |
| == what Terminal.app counted | 41 |

Terminal.app is the mirror image at 64 of 67 on the per-code-point sum. `👨‍👩‍👧‍👦` counts 2 here
and 11 there; the tag flag counts 2 here and 8 there. **`Quirk::PerCodePointColumns` is
Terminal.app's alone** — measured now, not assumed — and none of what it causes there happens
here: no unreachable tail to a row, no fourteen families to a line, no cluster torn in half by a
`CUP` into its middle.

## Five clusters where both terminals disagree with us

In all five our cluster width misses, Terminal.app counted the same as Ghostty:

| cluster | both terminals | our cluster width |
|---|---|---|
| `⚑️` narrow base + VS16 | 1 | 2 |
| `1️⃣` keycap with a selector | 2 | 1 |
| `क्ष` devanagari conjunct | 2 | 1 |
| `ক্ষ` bengali conjunct | 2 | 1 |
| `క్ష` telugu conjunct | 2 | 1 |

Two independent implementations reaching the same answer is the best evidence available that the
table is what needs changing. The three conjuncts are the same shape and the same answer three
times. The tables are left alone pending a decision.

## Files

* `page-*.png` — the pages as photographed, in LFS.
* `manifest.tsv` — which sample is on which row of which page.
* `measured.tsv` — advance and drawn. Regenerate with
  `python3 scripts/read_glyphs.py measurements/ghostty-1.3.2`.
* `counted.tsv` — counted width, with both models beside it.
