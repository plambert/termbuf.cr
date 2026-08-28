#!/usr/bin/env python3
"""Reads what a terminal drew out of the pictures `measure_glyphs.cr` took.

    python3 scripts/read_glyphs.py tmp/glyphs

Two numbers come out of each sample, neither of which any escape sequence
reports:

* **advance** — where the pen ended up, from the column the bar was drawn in
  less the padding between them.
* **drawn** — how wide the glyph is, from the rightmost lit pixel on the row
  that has nothing after the sample.

Every page starts with a staircase: a bar on each of the first few rows, each a
column further along. Consecutive steps give the width of a cell and the height
of a row at once, averaged over the lot, so measurements convert pixels to
columns using marks from the same picture.

Rows are sliced by that geometry rather than by looking for bands of ink, so a
tall glyph touching the row below it changes nothing, and a sample that drew
nothing at all still lines up with its neighbours.
"""

import subprocess
import sys
from pathlib import Path

import numpy as np

PAD = 20
# A pixel counts as lit at this fraction of the brightest thing in the content
# area. Well below a glyph stroke and well above the background, its
# antialiasing, and any chrome that crept in.
THRESHOLD = 0.5

# A row belongs to the content area when most of it is darker than this. The
# window's title bar is a solid light band and would otherwise be brighter than
# every glyph on the page.
BACKGROUND = 60


def load(path: Path) -> np.ndarray:
    """The picture as a 2-D array of brightness, via ImageMagick."""
    size = subprocess.run(
        ["magick", "identify", "-format", "%w %h", str(path)],
        capture_output=True, text=True, check=True).stdout.split()
    width, height = int(size[0]), int(size[1])

    raw = subprocess.run(
        ["magick", str(path), "-colorspace", "Gray", "-depth", "8", "gray:-"],
        capture_output=True, check=True).stdout

    return np.frombuffer(raw, dtype=np.uint8).reshape(height, width).astype(np.int16)


def runs(indices: np.ndarray):
    """Contiguous runs in a sorted index array, as (first, last) pairs."""
    if indices.size == 0:
        return []

    breaks = np.flatnonzero(np.diff(indices) > 1)
    starts = np.concatenate(([0], breaks + 1))
    ends = np.concatenate((breaks, [indices.size - 1]))
    return [(int(indices[a]), int(indices[b])) for a, b in zip(starts, ends)]


def content(page: np.ndarray) -> np.ndarray:
    """The terminal's own rows, with the window's furniture cut away.

    A screen capture takes the whole window, and the title bar is a solid light
    band brighter than any glyph — bright enough to make every row of the
    picture look as though something were drawn on it. The terminal's rows are
    the ones that are mostly background, so the longest run of those is the part
    worth reading.
    """
    dark = np.flatnonzero(np.median(page, axis=1) < BACKGROUND)
    bands = runs(dark)
    if not bands:
        raise SystemExit("no dark rows: is this a picture of a terminal?")

    top, bottom = max(bands, key=lambda band: band[1] - band[0])
    return page[top:bottom + 1]


def geometry(page: np.ndarray, floor: int, steps: int):
    """Left margin, cell width, the first row's centre, and the row pitch.

    Read from a staircase of bars, one per row, each a column further along.
    Consecutive steps differ by exactly one cell in each direction, so the two
    pitches are the mean of the gaps.
    """
    bands = runs(np.flatnonzero((page > floor).any(axis=1)))
    if len(bands) < steps:
        raise SystemExit(f"expected {steps} calibration steps, found {len(bands)}")

    centres = []
    for band in bands[:steps]:
        strip = page[band[0]:band[1] + 1].max(axis=0)
        lit = np.flatnonzero(strip > floor)
        if lit.size == 0:
            raise SystemExit("a calibration step has no ink")

        centres.append(((lit[0] + lit[-1]) / 2, (band[0] + band[1]) / 2))

    xs = np.array([c[0] for c in centres])
    ys = np.array([c[1] for c in centres])
    cell = float(np.diff(xs).mean())
    pitch = float(np.diff(ys).mean())

    # If the steps are not evenly spaced the geometry is not a grid and every
    # number after this would be quietly wrong.
    for name, gaps, size in (("cell", np.diff(xs), cell), ("row", np.diff(ys), pitch)):
        if gaps.std() > size * 0.15:
            raise SystemExit(f"{name} spacing is uneven: {gaps}")

    return float(xs[0]), cell, float(ys[0]), pitch


def row_ink(page: np.ndarray, floor: int, top: float, pitch: float, row: int):
    """The lit pixel columns of one text row, sliced by geometry."""
    centre = top + row * pitch
    first = max(int(centre - pitch / 2), 0)
    last = min(int(centre + pitch / 2), page.shape[0] - 1)
    if last <= first:
        return np.array([], dtype=int)

    return np.flatnonzero(page[first:last + 1].max(axis=0) > floor)


def bar_column(x: float, first: float, cell: float) -> int:
    """Which column a bar was drawn in.

    Measured against the staircase rather than against a guess at where column
    zero starts. Both are the same `|` glyph, so they sit the same way inside
    their cells and the offset cancels.
    """
    return int(round((x - first) / cell))


# A cell counts as painted when this much of its width carries ink. Antialiasing
# puts a pixel or two into the cell beyond a glyph that fills its own edge to
# edge — a block or a box drawing character — and without a floor those would
# measure two cells wide.
INK = 0.25


def cells_covered(lit: np.ndarray, first: float, cell: float) -> int:
    """How many cells a glyph's ink covers.

    Counted per cell rather than from the width of the ink, because a glyph
    that reaches its own edges bleeds a pixel into the next one and the two are
    indistinguishable by extent alone.
    """
    if lit.size == 0:
        return 0

    # The staircase bars sit in the middle of their cells, so column c runs
    # from half a cell either side of where its bar was.
    columns = np.floor((lit - (first - cell / 2)) / cell).astype(int)
    painted = [column for column in set(columns.tolist())
               if (columns == column).sum() >= cell * INK]

    return max(painted) - min(painted) + 1 if painted else 0


def main() -> int:
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else "tmp/glyphs")
    manifest = directory / "manifest.tsv"
    if not manifest.exists():
        raise SystemExit(f"no manifest in {directory}; run measure_glyphs.cr first")

    lines = manifest.read_text().splitlines()
    settings = dict(part.split("=") for part in lines[0].lstrip("# ").split())
    pad, steps = int(settings["pad"]), int(settings["steps"])

    entries = {}
    for line in lines[2:]:
        page, bar_row, codepoints, group, note = line.split("\t")
        entries.setdefault(int(page), []).append((int(bar_row), codepoints, group, note))

    print("codepoints\tgroup\tadvance\tdrawn\tnote")

    for page_number in sorted(entries):
        path = directory / f"page-{page_number:02d}.png"
        if not path.exists():
            print(f"# missing {path}", file=sys.stderr)
            continue

        page = content(load(path))
        floor = int(page.max() * THRESHOLD)
        left, cell, top, pitch = geometry(page, floor, steps)

        for bar_row, codepoints, group, note in entries[page_number]:
            bar_ink = row_ink(page, floor, top, pitch, bar_row)
            bare_ink = row_ink(page, floor, top, pitch, bar_row + 1)

            # The bar is the rightmost run of ink on its row, since the padding
            # clears the glyph. Its centre against the staircase's gives its
            # column, which is where the pen landed plus the padding.
            bar_runs = runs(bar_ink)
            advance = None
            if bar_runs:
                last = bar_runs[-1]
                advance = bar_column((last[0] + last[1]) / 2, left, cell) - pad
            # Nothing follows on the bare row, so its rightmost ink is the
            # glyph's own edge — which runs past the pen, and past anything
            # drawn after it on the row above.
            drawn = cells_covered(bare_ink, left, cell)

            note_out = note
            if advance is not None and drawn > pad:
                note_out += " (glyph reaches the bar; raise PAD)"

            print(f"{codepoints}\t{group}\t{advance if advance is not None else '?'}"
                  f"\t{drawn}\t{note_out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
