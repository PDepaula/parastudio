"""Step 3b: colour budget. `fix` is what makes a sprite meet its profile's
`max_colors` (lint's `colors` rule), not a side effect of whichever default
the grid reconstructor ships: every opaque pixel is snapped to at most
`max_colors` colours, or left alone when it already fits (so a rerun on a
fixed sprite changes nothing). Clustering is k-means in Oklab over the opaque
pixels (area-weighted by construction), seeded so the result is reproducible,
and each cluster's colour is its mean. Alpha is never touched.
"""

from __future__ import annotations

import numpy as np

SEED = 0
ATTEMPTS = 4
MAX_ITER = 24


def count_colors(rgba: np.ndarray) -> int:
    opaque = rgba[..., 3] > 0
    if not opaque.any():
        return 0
    return len(np.unique(rgba[opaque][:, :3], axis=0))


def quantize(rgba: np.ndarray, max_colors: int) -> tuple[np.ndarray, dict]:
    """Returns (rgba, info); info["colors_before"/"colors_after"], and
    info["quantized"] says whether anything was snapped."""
    import cv2
    from pixelfixer.colorspace import oklab_to_srgb, srgb_to_oklab

    before = count_colors(rgba)
    info = {"max_colors": max_colors, "colors_before": before, "colors_after": before,
            "quantized": False}
    if max_colors < 1 or before <= max_colors:
        return rgba, info

    opaque = rgba[..., 3] > 0
    rgb = rgba[opaque][:, :3]
    lab = srgb_to_oklab(rgb.astype(np.float64) / 255.0).astype(np.float32)
    cv2.setRNGSeed(SEED)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, MAX_ITER, 1e-4)
    _, labels, centers = cv2.kmeans(lab, max_colors, None, crit, ATTEMPTS, cv2.KMEANS_PP_CENTERS)
    palette = np.rint(oklab_to_srgb(centers.astype(np.float64)) * 255).clip(0, 255).astype(np.uint8)
    out = rgba.copy()
    out[opaque, :3] = palette[labels.ravel()]
    info["colors_after"] = count_colors(out)
    info["quantized"] = True
    return out, info
