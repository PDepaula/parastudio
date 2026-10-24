"""Step 3 (report §6.1, §6.3): pixel-grid recovery. When the caller already
knows the sprite's native cell size (from --cell), reconstruction
is forced straight to it - the report's fixer evidence (§6.3: 0 and 14 of
606/1,407 sprite pixels off) is for *unknown* scales, and a known one needs
no detection at all. Without a known cell, pixelfixer's three-detector
consensus (report §3.4) finds the native size; unfake.py is the fallback
(report §3.4, §6.3: "came close"). An implausible result (outside the style
profile's largest cell, report §4.2) is rejected rather than written as a
wrong-sized sprite. Auto-detection only ever runs on a content-sliced piece
(slicing.py), trimmed to its opaque bbox, so the profile's cell size bounds
the detected size from above only: a small sprite in a big cell is fine.

`reconstruct(..., color="mode")`, not `two_stage_pack`'s continuous per-cell
colour mean, is what keeps the colour count low: two_stage_pack's accurate-
but-continuous colours measured 460 distinct colours on this repo's own
degraded skeleton fixture (report §6.3's case) - true to the source pixels,
useless for a profile with a colours budget. `reconstruct(color="mode")`
picks one colour per cell and measured 32 there, matching the report's own
range (§5.2: 33 colours before a palette remap) with the same 0-pixels-off
accuracy. `palette_snap=False` everywhere: the library's own k-means snap picks
`k = min(48, max(8, sqrt(cells) // 2))`, a constant that only happens to equal
hibit's cap, so the colour budget is enforced by quantize.py from the
profile instead.

A forced cell is met by scaling uniformly, never by stretching: a source whose
aspect differs from the cell's is first padded with transparency (bottom-
aligned for a bottom pivot, so the figure's feet stay on the baseline; centred
otherwise) to the cell's aspect, then reconstructed. 256x256 into 96x144 is
x0.375 on both axes with the 48 spare rows above the figure, not x0.375 by
x0.5625.
"""

from __future__ import annotations

import numpy as np

# report §4.2's two style profiles' largest cell, as a plausibility bound for
# auto-detected native size when no --cell gives an exact one.
PROFILE_MAX_CELL = {
    "lowbit": 32,
    "hibit": 128,
    "punchclub": 128,  # old name of hibit
}


class GridError(Exception):
    pass


def fit_to_aspect(rgba: np.ndarray, cols: int, rows: int, pivot: str) -> tuple[np.ndarray, bool]:
    """Pads `rgba` with transparency up to the cols:rows aspect (never crops,
    never scales). The padding's RGB repeats the nearest edge pixel so the
    reconstructor's colour vote never sees a stray black. Returns (image,
    padded)."""
    h, w = rgba.shape[:2]
    if w * rows == h * cols:
        return rgba, False
    if w * rows > h * cols:  # wider than the cell: grow the height
        new_h, new_w = -(-w * rows // cols), w
    else:  # taller than the cell: grow the width
        new_h, new_w = h, -(-h * cols // rows)
    pad_y, pad_x = new_h - h, new_w - w
    top = pad_y if pivot == "bottom" else pad_y // 2
    left = pad_x // 2
    out = np.pad(rgba, ((top, pad_y - top), (left, pad_x - left), (0, 0)), mode="edge")
    pad = np.ones(out.shape[:2], dtype=bool)
    pad[top:top + h, left:left + w] = False
    out[pad, 3] = 0
    return out, True


def _forced(rgba: np.ndarray, cols: int, rows: int, pivot: str) -> tuple[np.ndarray, dict]:
    from pixelfixer.reconstruct import reconstruct
    fitted, padded = fit_to_aspect(rgba, cols, rows, pivot)
    h, w = fitted.shape[:2]
    out = reconstruct(fitted, w / cols, h / rows, cols, rows, color="mode", palette_snap=False)
    return out, {"cols": cols, "rows": rows, "source": "forced", "padded": padded}


def reconstruct_exact(rgba: np.ndarray, cols: int, rows: int) -> tuple[np.ndarray, dict]:
    """Reconstructs `rgba` onto exactly cols x rows cells, no aspect padding
    (the caller - fit.py - already sized it, and a rounded cols:rows is off the
    source's aspect by at most half a cell)."""
    from pixelfixer.reconstruct import reconstruct
    h, w = rgba.shape[:2]
    out = reconstruct(rgba, w / cols, h / rows, cols, rows, color="mode", palette_snap=False)
    return out, {"cols": cols, "rows": rows, "source": "forced", "padded": False}


def _pixelfixer_auto(rgba: np.ndarray) -> tuple[np.ndarray, dict]:
    from pixelfixer.core import detect
    from pixelfixer.reconstruct import reconstruct
    r = detect(rgba)
    cols, rows = int(r["cols"]), int(r["rows"])
    step_x, step_y = float(r["step_x"]), float(r["step_y"])
    out = reconstruct(rgba, step_x, step_y, cols, rows, color="mode", palette_snap=False)
    info = {
        "cols": cols, "rows": rows, "source": "pixelfixer",
        "consensus": str(r.get("consensus", "")),
        "step_x": round(step_x, 4), "step_y": round(step_y, 4),
    }
    return out, info


def _unfake_auto(rgba: np.ndarray, max_colors: int | None) -> tuple[np.ndarray, dict]:
    import unfake.pixel as _pixel
    # The accelerated (Rust) Wu quantizer segfaults on some degraded inputs
    # (reproduced on this repo's own fixtures); the pure-Python path is
    # slower but doesn't crash the process it runs in.
    _pixel.RUST_AVAILABLE = False
    import unfake
    r = unfake.process_image_sync(rgba, max_colors=max_colors, auto_color_detect=max_colors is None)
    out = r["image_array"]
    if out.shape[2] == 3:
        out = np.dstack([out, np.full(out.shape[:2], 255, dtype=np.uint8)])
    return out, {"cols": int(out.shape[1]), "rows": int(out.shape[0]), "source": "unfake"}


def _plausible(cols: int, rows: int, max_cell: int | None) -> bool:
    return max_cell is None or (cols <= max_cell and rows <= max_cell)


def recover_grid(rgba: np.ndarray, target_cols: int | None, target_rows: int | None,
                  profile: str | None = None, max_colors: int | None = None,
                  pivot: str = "bottom") -> tuple[np.ndarray, dict]:
    if target_cols and target_rows:
        return _forced(rgba, target_cols, target_rows, pivot)

    max_cell = PROFILE_MAX_CELL.get(profile or "")
    errors: list[str] = []

    try:
        out, info = _pixelfixer_auto(rgba)
        if _plausible(info["cols"], info["rows"], max_cell):
            return out, info
        errors.append(f"pixelfixer gave {info['cols']}x{info['rows']}, over {profile}'s {max_cell}px cell")
    except Exception as e:  # pixel-art-fixer's detectors are best-effort
        errors.append(f"pixelfixer: {e}")

    try:
        out, info = _unfake_auto(rgba, max_colors)
        if _plausible(info["cols"], info["rows"], max_cell):
            return out, info
        errors.append(f"unfake gave {info['cols']}x{info['rows']}, over {profile}'s {max_cell}px cell")
    except Exception as e:
        errors.append(f"unfake: {e}")

    raise GridError("grid recovery rejected: " + "; ".join(errors))
