# Terminal.app 470.2, AtkynsonMono Nerd Font Mono

A third font over the same sixty seven clusters, chosen because a Nerd Font carries far more
glyphs than a plain monospace one. It carries them in the wrong place for this question.

Taken on 2026-08-28:

| | |
|---|---|
| terminal | Terminal.app 470.2 (`TERM_PROGRAM_VERSION`) |
| system | macOS 26.5.2, build 25F84 |
| font | AtkynsonMonoNFM-Regular 11, set on the window only |
| window | 155 columns, 67 rows |
| geometry read from the pictures | cell 14 px, row 28 px |

## More glyphs, none of them these

The font covers 10,916 code points. Of the sixteen that matter here it covers **none**: no
devanagari, bengali, telugu or tamil, no CJK or fullwidth, no jamo, no arabic ligature, no
combining enclosure, no emoji, not even the two flags or the heart. A Nerd Font's bulk is Latin
plus several thousand icons in the Private Use Area, so every disputed cluster falls to exactly
the same fallback chain as before.

## Nothing moved

| | of 67 |
|---|---|
| identical to SFMono | 61 |
| identical to Menlo | 65 |
| counted width identical to SFMono | **67** |

And the six that differ from SFMono are not the terminal drawing differently. They are all the
same artefact of how this instrument counts a painted cell:

| cluster | SFMono | Menlo | Atkynson | ink in the marginal cell |
|---|---|---|---|---|
| `क्ष` devanagari conjunct | 1/2 | 1/1 | 1/1 | 0.33 → 0.21 |
| `நி` tamil na plus a vowel | 1/2 | 1/1 | 1/1 | 0.25 → 0.21 |
| `क्षि` conjunct plus a vowel | 2/3 | 2/2 | 2/2 | |
| `a⃝` combining enclosing circle | 2/2 | 2/3 | 2/3 | ink reaches left of its own cell |
| `⚑` no presentation | 1/2 | 1/2 | 1/1 | 0.33, 0.43 → 0.21 |
| `‍` a joiner on its own | 1/1 | 1/1 | 1/0 | 0.33 → 0.21 |

`INK = 0.25` — a cell counts as painted when a quarter of its width carries ink. SFMono at 11
gives a 12 px cell and the other two give 14 px, so the same glyph's overhang is 0.33 of a cell
in one and 0.21 in the other, either side of the floor. The tamil reading under SFMono is 0.25
exactly, which is to say it was decided by the comparison being `>=`.

**So the four clusters the Menlo run reported as font-dependent are not.** That run's README
attributed them to different fallbacks doing the shaping; the cause is the cell getting wider.
Atkynson and Menlo have different coverage from each other and identical geometry, and they agree
on all six.

## Scored

```text
advance == drawn                45 of 67
our cluster width == advance    46 of 67
our cluster width == drawn      50 of 67
per-code-point sum == advance   39 of 67
```

## Counted width, a third time

Identical to SFMono on all sixty seven, as it was for Menlo. Three fonts, three agreements: the
counted width belongs to the terminal and the font has no vote in it.

## Files

* `page-*.png` — the pages as photographed, in LFS.
* `manifest.tsv` — which sample is on which row of which page.
* `measured.tsv` — advance and drawn.
* `counted.tsv` — counted width, with both models beside it.
