# Ghostty 1.3.2

Counted width only. The photographic half of this run is missing and the reason is worth
recording: the screen was locked, so nothing composited, and `screencapture` returned the
wallpaper on every page. Escape sequences do not care whether anyone is logged in at the
console, so `CPR` answered normally and this file is sound.

Taken on 2026-08-28:

| | |
|---|---|
| terminal | Ghostty 1.3.2-main-+55a3e33ab |
| system | macOS 26.5.2, build 25F84 |
| font | SF Mono 11, in an instance started with `config-default-files=false` |
| window | 123 columns at launch, 64 rows once fullscreen |

The instance was thrown away afterwards. It loaded none of the user's configuration, so the
colours, font and padding here are the ones on the command line and nothing else.

## Ghostty counts clusters; Terminal.app counts code points

| | of 67 |
|---|---|
| Ghostty's count == our cluster width | 62 |
| Ghostty's count == per-code-point sum | 40 |
| Ghostty's count == Terminal.app's count | 41 |

Terminal.app is the mirror image of this — 64 of 67 on the per-code-point sum. The two
terminals agree with each other on 41 of 67, so the disagreement is not a rounding difference
in one table but two different ideas of what a column is charged to.

`👨‍👩‍👧‍👦` counts 2 here and 11 there. **`Quirk::PerCodePointColumns` does not belong to
Ghostty**, and none of what it causes on Terminal.app — the unreachable tail of a row, 14
families to a 155 column line, a cluster torn in half by a `CUP` into its middle — happens here.

## Five clusters where both terminals disagree with us

Our cluster width predicts Ghostty in 62 of 67. In every one of the five it misses, Terminal.app
counted the same as Ghostty, which makes this the strongest evidence yet that the table rather
than the terminal is wrong:

| cluster | both terminals | our cluster width |
|---|---|---|
| `⚑️` narrow base + VS16 | 1 | 2 |
| `1️⃣` keycap with a selector | 2 | 1 |
| `क्ष` devanagari conjunct | 2 | 1 |
| `ক্ষ` bengali conjunct | 2 | 1 |
| `క్ష` telugu conjunct | 2 | 1 |

Four are under-counts by us and one is an over-count. The three conjuncts are the same shape
and the same answer three times over. The tables are left alone pending a decision.

## Files

* `counted.tsv` — counted width with both models beside it, from `scripts/measure_columns.cr`.

To finish the run, unlock the screen and take the photographic half:

```bash
crystal run scripts/measure_glyphs.cr -- measurements/ghostty-1.3.2
python3 scripts/read_glyphs.py measurements/ghostty-1.3.2
```

It must run in a Ghostty started *after* screen recording was granted, and fullscreen, since
Ghostty cannot be asked where its window is and the picture is therefore the whole screen.
