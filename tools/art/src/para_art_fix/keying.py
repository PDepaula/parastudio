"""Step 2 (report §6.1, §2.2): background key to hard alpha (0/255 only,
matching the lint rule in tools/para/art/lint.nim). An explicit --key
always keys with that colour. Without one, keying runs only when the input
is a flat key background: an image that already has any transparent pixel
(a transparent PNG, a repo sprite, a slice, a rerun on this step's own
output) is already keyed and isn't keyed again - its semi-alpha is only
thresholded at 128, which makes a rerun a no-op - and otherwise the key is
the corners' median colour when all four corners agree within KEY_DIST of
each other; corners that disagree (a full-bleed tile, a framed panel) mean
there's no key background to find. Either skip tells the caller to pass
--key. Pixels already transparent always stay transparent, and the border
fill passes through them.

Background is a flood fill from the image border over pixels within KEY_DIST
(Euclidean RGB) of the key - the practitioner method (report §2.2, "not a
global colour swap"), the same border flood fill as unfake's
`make_background_transparent`. An enclosed pocket (the gap between a
skeleton's ribs) is keyed too, one whole connected region at a time: a
region of near-key pixels the border fill didn't reach is background only
when it has at least POCKET_MIN_PX pixels and its mean colour is within
POCKET_DIST of the key colour sampled from the border fill itself. A lone
key-coloured pixel, or a small highlight or eye near the key colour, stays
sprite; `border_only=True` skips pockets entirely, for art that
legitimately uses the key colour inside the silhouette. Distance, not hue,
decides: a dark outline or shadow tinted toward the key is nowhere near it.

`info["key"]` says what happened: the key colour as RRGGBB, SKIP_ALPHA or
SKIP_CORNERS."""

from __future__ import annotations

import numpy as np
from scipy import ndimage

KEY_DIST = 100.0
POCKET_MIN_PX = 4
POCKET_DIST = 48.0
ALPHA_CUT = 128
SKIP_ALPHA = "skip:alpha"
SKIP_CORNERS = "skip:corners"
_FOUR = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], dtype=bool)


def _hex_to_rgb(hex_color: str) -> np.ndarray:
    h = hex_color.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.uint8)


def key_to_alpha(rgba: np.ndarray, override_hex: str | None = None,
                  border_only: bool = False) -> tuple[np.ndarray, dict]:
    """rgba: (H,W,4) or (H,W,3) uint8. Returns (rgba with hard alpha, info)."""
    h, w = rgba.shape[:2]
    rgb = rgba[..., :3]
    alpha_in = rgba[..., 3] if rgba.shape[2] == 4 else np.full((h, w), 255, dtype=np.uint8)
    transparent = alpha_in < ALPHA_CUT
    rgbf = rgb.astype(np.float64)
    corners = rgbf[[0, 0, h - 1, h - 1], [0, w - 1, 0, w - 1]]

    if override_hex:
        bg = _hex_to_rgb(override_hex).astype(np.float64)
    elif transparent.any():
        bg, status = None, SKIP_ALPHA
    elif np.linalg.norm(corners[:, None] - corners[None, :], axis=-1).max() <= KEY_DIST:
        bg = np.median(corners, axis=0).round()
    else:
        bg, status = None, SKIP_CORNERS

    background = transparent
    if bg is not None:
        status = "".join(f"{int(c):02x}" for c in bg)
        near = ~transparent & (np.linalg.norm(rgbf - bg, axis=-1) <= KEY_DIST)
        labels, _ = ndimage.label(near | transparent, structure=_FOUR)
        edge = np.unique(np.concatenate([labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1]]))
        background = np.isin(labels, edge[edge != 0]) | transparent
        border_keyed = background & ~transparent
        if not border_only and border_keyed.any():
            key = rgbf[border_keyed].mean(axis=0)
            plabels, n = ndimage.label(near & ~background, structure=_FOUR)
            if n:
                ids = np.arange(1, n + 1)
                sizes = np.bincount(plabels.ravel(), minlength=n + 1)[1:]
                means = np.stack([ndimage.mean(rgbf[..., c], plabels, ids) for c in range(3)], axis=-1)
                keyed = np.concatenate([[False], (sizes >= POCKET_MIN_PX) &
                                        (np.linalg.norm(means - key, axis=-1) <= POCKET_DIST)])
                background = background | keyed[plabels]

    out = np.dstack([rgb, np.where(background, 0, 255).astype(np.uint8)])
    return out, {"key": status, "keyed_px": int((background & ~transparent).sum())}
