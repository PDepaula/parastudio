"""Step 2b: strip key-coloured pixels that survived keying. `keying.py`
removes the background by flood fill from the border and drops enclosed pockets
of at least POCKET_MIN_PX pixels, deliberately keeping a smaller key-coloured
pocket as sprite (an eye, a highlight), and grid recovery can leave a
key-coloured pixel hanging off the silhouette. Either way an opaque pixel
within KEY_LEAK_DIST (Euclidean RGB) of the key colour is a leak in a finished
sprite: it reads as a bright dot against any ground. `tools/para/art/lint.nim`
carries the same constant for its `key` rule, so fix output always passes it.

A leaked pixel that touches transparency (or the edge of the image) is
background and goes transparent; repeating that eats a whole fringe clump. One
fully enclosed by sprite is a hole, not background, so it takes the colour of
the nearest sprite pixel instead of punching a hole through the figure.
Distance decides, never hue: a teal crystal or a darker green is nowhere near
the key (the next-nearest colour in the GameLab batch was 125 away, the leaks
0-13). `--key-border-only` skips this step for art that uses the key colour on
purpose.
"""

from __future__ import annotations

import numpy as np
from scipy import ndimage

KEY_LEAK_DIST = 40.0


def key_colour(status: str) -> np.ndarray | None:
    """The RGB behind a `keying` info["key"] status, None for a skip status."""
    if len(status) != 6:
        return None
    try:
        return np.array([int(status[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)
    except ValueError:
        return None


def leaked(rgba: np.ndarray, key: np.ndarray) -> np.ndarray:
    dist = np.linalg.norm(rgba[..., :3].astype(np.float64) - key, axis=-1)
    return (rgba[..., 3] > 0) & (dist <= KEY_LEAK_DIST)


def strip_key_leaks(rgba: np.ndarray, key: np.ndarray | None) -> tuple[np.ndarray, dict]:
    """Returns (rgba, {"removed", "filled"}): pixel counts."""
    info = {"removed": 0, "filled": 0}
    if key is None:
        return rgba, info
    out = rgba.copy()
    while True:
        bad = leaked(out, key)
        if not bad.any():
            return out, info
        opaque = out[..., 3] > 0
        pad = np.pad(opaque, 1, constant_values=False)
        exposed = ~(pad[1:-1, :-2] & pad[1:-1, 2:] & pad[:-2, 1:-1] & pad[2:, 1:-1])
        drop = bad & exposed
        if drop.any():
            out[drop, 3] = 0
            info["removed"] += int(drop.sum())
            continue
        # Only enclosed leaks are left: borrow the nearest sprite colour.
        good = opaque & ~bad
        if not good.any():
            return out, info
        _, (iy, ix) = ndimage.distance_transform_edt(~good, return_indices=True)
        by, bx = np.where(bad)
        out[by, bx, :3] = out[iy[by, bx], ix[by, bx], :3]
        info["filled"] += int(bad.sum())
        return out, info
