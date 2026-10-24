"""Step 7 (report §6.1 step 7): content slicing, when a generator returns a
whole sheet instead of one sprite - connected components, sorted row-major,
then re-gridded by cell.py (report: "slice sheets by content, not an assumed
grid"; roboticape, report §2.2, sliced the same way because the AI's grid
"is not perfectly uniform"). Only runs when the caller doesn't already know
the sprite's cell size: a declared --cell means the file is one already-
cropped asset (`para art lint`'s model, one sidecar per PNG), and a sprite's
own disconnected parts (a bat's wing, a held weapon) must not be split
apart. Components are dilated before labelling so nearby parts of one
sprite merge; only gaps wide enough to survive the dilation stay separate.

`--cell` also means one cell, so a file that is really a grid of cells (a
growth strip, a walk-cycle sheet) is refused by `multi_cell_grid` rather than
being collapsed into a single cell-sized output.
"""

from __future__ import annotations

import numpy as np
from scipy import ndimage

DILATE_PX = 2


def slice_content(rgba: np.ndarray, dilate: int = DILATE_PX) -> list[tuple[tuple[int, int, int, int], np.ndarray]]:
    alpha = rgba[..., 3] > 0
    if not alpha.any():
        return [((0, 0, rgba.shape[1], rgba.shape[0]), rgba)]

    structure = np.ones((3, 3), dtype=bool)
    dilated = ndimage.binary_dilation(alpha, structure=structure, iterations=dilate)
    labels, n = ndimage.label(dilated, structure=structure)

    pieces: list[tuple[tuple[int, int, int, int], np.ndarray]] = []
    for i in range(1, n + 1):
        comp = (labels == i) & alpha
        if not comp.any():
            continue
        ys, xs = np.where(comp)
        y0, y1, x0, x1 = int(ys.min()), int(ys.max()) + 1, int(xs.min()), int(xs.max()) + 1
        sub_mask = comp[y0:y1, x0:x1]
        sub = rgba[y0:y1, x0:x1].copy()
        sub[~sub_mask] = 0
        pieces.append(((x0, y0, x1 - x0, y1 - y0), sub))

    pieces.sort(key=lambda p: (p[0][1], p[0][0]))
    return pieces


def slice_or_whole(rgba: np.ndarray, known_cell: bool) -> list[tuple[tuple[int, int, int, int], np.ndarray]]:
    if known_cell:
        return [((0, 0, rgba.shape[1], rgba.shape[0]), rgba)]
    return slice_content(rgba)


def multi_cell_grid(rgba: np.ndarray, cell: tuple[int, int]) -> tuple[int, int] | None:
    """(cols, rows) when `rgba` looks like a sheet of several `cell`-sized
    cells rather than one sprite, else None. A file that is a whole multiple of
    the cell is not enough on its own: a 128x128 GameLab source of one stone is
    a legitimate 2x upscale for a 64x64 cell. It is a sheet when it is a whole
    multiple, at least two of its cells have content, and no opaque pixel
    straddles an internal cell boundary (one sprite's body would, a sheet's
    separate cells don't)."""
    cw, ch = cell
    h, w = rgba.shape[:2]
    if w % cw or h % ch or (w // cw) * (h // ch) < 2:
        return None
    cols, rows = w // cw, h // ch
    alpha = rgba[..., 3] > 0
    filled = alpha.reshape(rows, ch, cols, cw).any(axis=(1, 3))
    if int(filled.sum()) < 2:
        return None
    for x in range(cw, w, cw):
        if (alpha[:, x - 1] & alpha[:, x]).any():
            return None
    for y in range(ch, h, ch):
        if (alpha[y - 1, :] & alpha[y, :]).any():
            return None
    return cols, rows
