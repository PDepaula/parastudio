"""Step 6 (report §6.1 step 6): fixed cell and pivot. A piece that already
fills its declared cell exactly - the normal case once grid recovery was
*forced* to that cell (grid.py) - is left alone: trimming and re-centring it
would shift genuinely-aligned art (real sprites aren't always pivot-flush;
report §7.2's gino_attack.png has legitimate bottom-edge touches that are
feet, not clipping). A piece that doesn't already match the cell - sliced
content, or auto-detected grid recovery - is trimmed to its opaque bbox and
placed with a bottom-centre pivot on the cell's baseline row (report §4.2),
matching parasurvivors' regrid lesson (fetch_assets.sh:32-36, report §6.1
step 6). Oversize content keeps its own larger cell instead of being cropped.
"""

from __future__ import annotations

import numpy as np


def trim(rgba: np.ndarray) -> tuple[np.ndarray, tuple[int, int, int, int]]:
    alpha = rgba[..., 3] > 0
    if not alpha.any():
        return rgba, (0, 0, rgba.shape[1], rgba.shape[0])
    ys, xs = np.where(alpha)
    y0, y1, x0, x1 = int(ys.min()), int(ys.max()) + 1, int(xs.min()), int(xs.max()) + 1
    return rgba[y0:y1, x0:x1], (x0, y0, x1 - x0, y1 - y0)


def place_in_cell(rgba: np.ndarray, cell: tuple[int, int] | None, pivot: str,
                  bottom_margin: int = 0) -> tuple[np.ndarray, dict]:
    """`bottom_margin` rows stay empty under a bottom-pivot figure (`--fit
    content`'s margin: the outline step refuses art that touches the cell edge)."""
    h, w = rgba.shape[:2]
    if cell and (w, h) == tuple(cell):
        return rgba, {"cell_w": w, "cell_h": h, "trim_w": w, "trim_h": h, "pivot": pivot, "placed": False}

    trimmed, _bbox = trim(rgba)
    th, tw = trimmed.shape[:2]
    cw, ch = cell if cell else (tw, th)
    cw, ch = max(cw, tw), max(ch, th + bottom_margin if pivot == "bottom" else th)

    out = np.zeros((ch, cw, 4), dtype=np.uint8)
    ox = (cw - tw) // 2
    oy = (ch - th - bottom_margin) if pivot == "bottom" else (ch - th) // 2
    out[oy:oy + th, ox:ox + tw] = trimmed
    return out, {"cell_w": cw, "cell_h": ch, "trim_w": tw, "trim_h": th, "pivot": pivot, "placed": True}
