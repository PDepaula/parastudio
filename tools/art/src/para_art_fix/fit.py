"""`--fit content`: trim each key-removed source to its opaque bounding box,
then scale uniformly so the figure fills the cell less a margin, bottom-aligned
to the pivot (cell.py places it). A GameLab canvas is mostly air - a 256x256
source holds a ~156x239 figure - so fitting the whole canvas into a cell leaves
the figure far smaller than the cell the game chose for detail.

One scale serves every figure in the run, so poses of one character keep their
relative size instead of each filling its own cell: the scale is the one that
fits the *largest* figure (tightest axis wins), or, with `--figure-height N`,
the one that makes the tallest figure N rows. Run one character's poses (or a
character and the things drawn at its scale) in one `para art fix` call.
"""

from __future__ import annotations

DEFAULT_MARGIN_PCT = 5.0


class FitError(Exception):
    pass


def shared_scale(sizes: list[tuple[int, int]], cell: tuple[int, int], margin_pct: float,
                 figure_height: int | None) -> float:
    """The source->cell scale for figures of the given (w, h) bbox sizes."""
    sizes = [(w, h) for w, h in sizes if w > 0 and h > 0]
    if not sizes:
        raise FitError("no opaque pixels to fit; nothing to scale")
    if figure_height:
        return figure_height / max(h for _w, h in sizes)
    keep = 1 - 2 * margin_pct / 100
    box_w, box_h = cell[0] * keep, cell[1] * keep
    return min(min(box_w / w, box_h / h) for w, h in sizes)


def scaled_size(size: tuple[int, int], scale: float) -> tuple[int, int]:
    return max(1, round(size[0] * scale)), max(1, round(size[1] * scale))
