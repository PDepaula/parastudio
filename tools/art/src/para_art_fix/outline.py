"""Step 7, opt-in (`--outline`): boundary-recolour outline
enforcement. Mirrors `tools/para/art/lint.nim::analyzeAsset`'s own
boundary/interior/luma rule exactly (tests/fixtures/art/outline/cases.json
plus tests/test_art_outline_fixture.nim and tools/art/tests/test_outline.py
keep this in sync with lint.nim's own cases rather than trusting a
hand-copied reimplementation), then recolours only the boundary pixels the
rule flags to the sprite's own existing darkest interior colour, nudged
minimally darker when needed to clear the rule's `>=` tie (with a locked
palette: per pixel, the palette member nearest its own colour among those
strictly darker than that floor, instead of a nudge). It never grows
the silhouette - only already-opaque boundary pixels change colour - and
runs last in the pipeline (after keying/grid/palette/cleanup/cell), because
it needs the already-locked palette and already hard-alpha, already-placed
image those steps produce.

art-outline-test report §3(b) showed dilating the silhouette by a pixel
reliably makes this worse (the old boundary becomes new interior, dropping
the floor), so this never does that; §6 and art-webapp-lint report §3/§5
are two of the guards below.

The guard that decides `refuse:interior-ink` is relative, not absolute: it
asks whether the recoloured rim reads against the body right next to it
(MIN_RIM_CONTRAST). A dark robe or a dark core is fine as long as its edge
pixels sit next to something visibly lighter than the rim colour; only a body
whose edge is itself near the floor colour - so the rim would melt into it -
is refused. The earlier proxy (how much of the sprite's interior is near-black,
anywhere) refused every dark-robed sprite whose edge had plenty of contrast.
The lint rule itself is unchanged: a boundary strictly darker than the
darkest interior pixel, which this step always meets or refuses.
"""

from __future__ import annotations

import numpy as np

# The interior-ink refusal: after the boundary is recoloured to the sprite's
# floor colour, each boundary pixel is compared (luma, 0-255) with the mean of
# the interior pixels in its 8-neighbourhood. When the median of those rim
# contrasts is under MIN_RIM_CONTRAST the rim does not read as an outline - it
# is the same near-black as the body it is meant to separate from - and
# recolouring would redraw the asset rather than fix it (art-outline-test
# report §5's cultivator pose, a near-black body with near-black linework along
# its edge). 16 is about 6% of the luma range: the dark-robed GameLab sprites
# measure a median of 24-37 and the lowest of the other twelve is 23, while a
# flat near-black body measures under 10. Boundary pixels with no interior
# neighbour (a one-pixel-wide tip) have nothing to be compared with and are
# skipped.
MIN_RIM_CONTRAST = 16.0

# Flag instead of auto-applying when (close to) the whole boundary is an
# offender and the cell is this small or smaller in either dimension, unless
# the cell is icon-sized (ICON_CELL_DIM or less in both): there the whole
# sprite is a few pixels wide, so its boundary is nearly all of it and the rim
# is the only outline that fits - flagging would make every small pickup fail
# lint's `outline` rule by construction. The flag's own evidence, below:
# art-webapp-lint report §3 found the exact same "100% of boundary offends"
# result reads as a clean inked silhouette at 48x64/64x96 but as chunky
# damage at 32x48 - the fix step can't tell those apart from the pixel
# counts alone, so it asks for a visual check instead of guessing.
ALL_BOUNDARY_OFFENDER_FRACTION = 0.95
SMALL_CELL_DIM = 48
ICON_CELL_DIM = 32

OK = "ok"
REFUSE_INTERIOR_INK = "refuse:interior-ink"
FLAG_ALL_BOUNDARY = "flag:all-boundary"
REFUSE_EDGE_TOUCH = "refuse:edge-touch"
REFUSE_FLOOR_AT_BLACK = "refuse:floor-at-black"
REFUSE_COLOR_CAP = "refuse:color-cap"
REFUSE_PALETTE = "refuse:palette"


def luma(rgb: np.ndarray) -> np.ndarray:
    return 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]


def classify(alpha: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Boundary/interior masks for one cell - lint.nim's analyzeAsset, with
    the cell set to the whole array. The fix pipeline hands this one already
    cell-placed sprite at a time (see module docstring), so that's always
    lint.nim's own per-cell loop degenerating to a single cell; it is not a
    simplification of the rule itself, both apply the identical per-pixel
    test lint.nim does."""
    opaque = alpha > 0
    h, w = alpha.shape
    boundary = np.zeros((h, w), dtype=bool)
    boundary[0, :] = True
    boundary[-1, :] = True
    boundary[:, 0] = True
    boundary[:, -1] = True
    pad = np.pad(opaque, 1, constant_values=False)
    boundary |= ~pad[1:-1, :-2]  # transparent to the left
    boundary |= ~pad[1:-1, 2:]  # transparent to the right
    boundary |= ~pad[:-2, 1:-1]  # transparent above
    boundary |= ~pad[2:, 1:-1]  # transparent below
    boundary &= opaque
    interior = opaque & ~boundary
    return boundary, interior


def analyze(rgba: np.ndarray) -> dict:
    """The rule's own numbers for one cell, with no decision applied yet -
    the same shape `outline_enforce.py` (art-outline-test report §3(c))
    printed."""
    alpha = rgba[..., 3]
    opaque = alpha > 0
    boundary, interior = classify(alpha)
    l = luma(rgba[..., :3].astype(np.float64))
    total_opaque = int(opaque.sum())
    result = {
        "total_opaque": total_opaque,
        "boundary_total": int(boundary.sum()),
        "interior_total": int(interior.sum()),
        "darkest_interior": None,
        "offenders": 0,
        "offender_fraction": 0.0,
    }
    if not interior.any():
        return result
    darkest = float(l[interior].min())
    result["darkest_interior"] = darkest
    offend = boundary & (l >= darkest)
    result["offenders"] = int(offend.sum())
    if result["boundary_total"] > 0:
        result["offender_fraction"] = result["offenders"] / result["boundary_total"]
    return result


def rim_contrast(rgba: np.ndarray) -> float | None:
    """Median over boundary pixels of (mean luma of the interior pixels in the
    pixel's 8-neighbourhood) minus (the pixel's own luma): how far the rim
    stands off the body beside it. None when no boundary pixel has an
    interior neighbour, so there is nothing to compare."""
    boundary, interior = classify(rgba[..., 3])
    l = luma(rgba[..., :3].astype(np.float64))
    ih, iw = l.shape
    total = np.zeros((ih, iw))
    count = np.zeros((ih, iw))
    lp = np.pad(np.where(interior, l, 0.0), 1)
    ip = np.pad(interior.astype(np.float64), 1)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy or dx:
                total += lp[1 + dy:1 + dy + ih, 1 + dx:1 + dx + iw]
                count += ip[1 + dy:1 + dy + ih, 1 + dx:1 + dx + iw]
    has_body = boundary & (count > 0)
    if not has_body.any():
        return None
    return float(np.median(total[has_body] / count[has_body] - l[has_body]))


def touches_cell_edge(alpha: np.ndarray) -> bool:
    """The cell-margin rule (art-outline-test report §6): an asset whose
    opaque content already touches its own cell edge must never be recoloured
    by this step - with no margin left there is no telling a drawn silhouette
    edge from content merely clipped by the cell boundary."""
    return bool((alpha[0, :] > 0).any() or (alpha[-1, :] > 0).any()
                or (alpha[:, 0] > 0).any() or (alpha[:, -1] > 0).any())


def apply_outline(rgba: np.ndarray, *, max_colors: int | None = None,
                  palette: np.ndarray | None = None) -> tuple[np.ndarray, dict]:
    """Returns (rgba, info); info["outline"] is one of OK (no offenders, or
    offenders recoloured), REFUSE_EDGE_TOUCH (the cell-margin guard: an opaque
    pixel sits on the cell's own edge, so recolouring its edge is unsafe), REFUSE_FLOOR_AT_BLACK
    (the floor is so dark that no nudge clears lint's `>=` tie),
    REFUSE_COLOR_CAP / REFUSE_PALETTE (the reused colour would exceed
    `max_colors` or fall outside `palette`), REFUSE_INTERIOR_INK (the body
    along the edge is as dark as the rim colour would be - see
    MIN_RIM_CONTRAST - so the outline would not read; a normal fix finding,
    same shape as fix.nim's existing skip:corners/skip:alpha hints), or FLAG_ALL_BOUNDARY (nearly
    the whole boundary would be recoloured at a cell this small - needs a
    look, not a blind apply). rgba is returned unchanged for every status
    but OK-with-offenders."""
    stats = analyze(rgba)
    info = dict(stats)
    info["offenders_fixed"] = 0

    if stats["interior_total"] == 0 or stats["offenders"] == 0:
        info["outline"] = OK
        return rgba, info

    if touches_cell_edge(rgba[..., 3]):
        info["outline"] = REFUSE_EDGE_TOUCH
        return rgba, info

    h, w = rgba.shape[:2]
    is_icon = max(w, h) <= ICON_CELL_DIM
    if (stats["offender_fraction"] >= ALL_BOUNDARY_OFFENDER_FRACTION
            and min(w, h) < SMALL_CELL_DIM and not is_icon):
        info["outline"] = FLAG_ALL_BOUNDARY
        return rgba, info

    alpha = rgba[..., 3]
    boundary, interior = classify(alpha)
    l = luma(rgba[..., :3].astype(np.float64))
    darkest = stats["darkest_interior"]

    # Reuse the sprite's own existing darkest interior colour as the single
    # flat outline colour - no new palette entries, same recipe as
    # outline_enforce.py. Its luma == darkest_interior exactly, which still
    # fails the rule's own `>=`, so nudge every channel down by 1 (floor 0)
    # to clear the tie with the same hue.
    if palette is not None:
        # Locked palette: no nudge (it would almost never land on a member);
        # use the palette members strictly below the floor, per pixel.
        pl = luma(palette.astype(np.float64))
        below = np.where(pl < darkest)[0]
        if below.size == 0:
            info["outline"] = REFUSE_PALETTE
            return rgba, info
        outline_color = None
        candidates = palette[below].astype(np.int32)
    else:
        iy, ix = np.where(interior)
        il = l[iy, ix]
        darkest_idx = np.argmin(il)
        outline_color = rgba[iy[darkest_idx], ix[darkest_idx], :3].astype(np.int32)
        if luma(outline_color.reshape(1, 1, 3).astype(np.float64))[0, 0] >= darkest:
            outline_color = np.maximum(outline_color - 1, 0)

    out = rgba.copy()
    offend = boundary & (l >= darkest)
    oy, ox = np.where(offend)
    if outline_color is None:
        # Each rim pixel takes the candidate nearest its own colour, so a
        # purple glow edge becomes a darker purple, not whichever grey or red
        # happens to sit closest in luma.
        diffs = out[oy, ox, :3].astype(np.int32)[:, None, :] - candidates[None, :, :]
        out[oy, ox, :3] = candidates[(diffs * diffs).sum(axis=-1).argmin(axis=1)].astype(np.uint8)
    else:
        out[oy, ox, :3] = outline_color.astype(np.uint8)
    out[oy, ox, 3] = 255  # already opaque by definition of "boundary"; kept explicit

    if analyze(out)["offenders"] > 0:
        info["outline"] = REFUSE_FLOOR_AT_BLACK
        return rgba, info
    contrast = rim_contrast(out)
    info["rim_contrast"] = contrast
    if contrast is not None and contrast < MIN_RIM_CONTRAST:
        info["outline"] = REFUSE_INTERIOR_INK
        return rgba, info
    if max_colors is not None and len(np.unique(out[out[..., 3] > 0][:, :3], axis=0)) > max_colors:
        info["outline"] = REFUSE_COLOR_CAP
        return rgba, info

    info["outline"] = OK
    info["offenders_fixed"] = int(offend.sum())
    return out, info
