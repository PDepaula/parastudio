"""Step 4 (report §6.1 step 4, §5.2): palette lock. Remaps every visible
pixel's RGB to its nearest colour in the game's `art/palette.hex` (Lospec
format, one RRGGBB per line - the same file `tools/para/art/profile.nim`'s
`loadPalette` reads for `para art lint`), no dither, alpha untouched. The
report's own evidence (§5.2): remapping the fixed hero onto the original's
28-colour palette cut 33 colours to 24 and mean error 5.4 to 2.7.
"""

from __future__ import annotations

import numpy as np


def load_hex_palette(path: str) -> np.ndarray:
    ## Mirrors tools/para/art/profile.nim's loadPalette exactly: one
    ## RRGGBB per line, an optional leading '#', no inline comments.
    colors: list[list[int]] = []
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            hexs = line[1:] if line.startswith("#") else line
            if len(hexs) != 6:
                continue
            colors.append([int(hexs[i:i + 2], 16) for i in (0, 2, 4)])
    if not colors:
        raise ValueError(f"{path}: palette has no colours")
    return np.array(colors, dtype=np.uint8)


def _luma(rgb: np.ndarray) -> np.ndarray:
    return 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]


def _boundary(alpha: np.ndarray) -> np.ndarray:
    """Opaque pixels on the cell edge or with a transparent orthogonal
    neighbour - lint.nim's `outline` rule's own boundary (outline.classify)."""
    opaque = alpha > 0
    pad = np.pad(opaque, 1, constant_values=False)
    edge = ~(pad[1:-1, :-2] & pad[1:-1, 2:] & pad[:-2, 1:-1] & pad[2:, 1:-1])
    edge[0, :] = edge[-1, :] = True
    edge[:, 0] = edge[:, -1] = True
    return opaque & edge


# A boundary pixel at most this bright (luma, 0-255) is a sprite's rim, whatever
# near-black tint it was drawn in; with `reserve_outline` it takes the
# palette's darkest colour instead of whichever dark shade is nearest in RGB.
OUTLINE_LUMA_MAX = 20.0


def remap(rgba: np.ndarray, palette_path: str, *,
          reserve_outline: bool = False) -> tuple[np.ndarray, dict]:
    """`reserve_outline` (set by `--outline`) makes the palette's darkest
    colour the rim colour: the boundary pixels no brighter than
    OUTLINE_LUMA_MAX take it, and no interior pixel does, so a sprite's
    near-black shading cannot collapse onto the rim and fail lint's `outline`
    rule (boundary strictly darker than the darkest interior pixel). Other
    boundary pixels (a lit rim) still snap to their nearest colour."""
    palette = load_hex_palette(palette_path)
    out = rgba.copy()
    visible = out[..., 3] > 0
    if not visible.any():
        return out, {"path": palette_path, "colors": int(len(palette)), "remapped_px": 0}
    px = out[visible][:, :3].astype(np.int32)
    diffs = px[:, None, :] - palette[None, :, :].astype(np.int32)
    dist = (diffs * diffs).sum(axis=-1)
    rim = None
    if reserve_outline and len(palette) > 1:
        darkest = int(np.argmin(_luma(palette.astype(np.float64))))
        boundary = _boundary(out[..., 3])[visible]
        dist[~boundary, darkest] = np.iinfo(np.int32).max
        rim = boundary & (_luma(px.astype(np.float64)) <= OUTLINE_LUMA_MAX)
    nearest_idx = dist.argmin(axis=1)
    if rim is not None:
        nearest_idx[rim] = darkest
    remapped_px = int((dist[np.arange(len(px)), nearest_idx] > 0).sum())
    out[visible, :3] = palette[nearest_idx]
    return out, {"path": palette_path, "colors": int(len(palette)), "remapped_px": remapped_px}
