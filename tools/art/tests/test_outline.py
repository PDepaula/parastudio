"""`para_art_fix.outline` (issue #41, `para art fix --outline`): the
boundary/interior/luma classification itself, and the three outcomes
`apply_outline` can return.

The first suite is this file's half of the cross-language check -
tests/test_art_outline_fixture.nim is the other half - both load the exact
same PNGs and check against the same recorded tests/fixtures/art/outline/
cases.json, instead of this module's classification being hand-copied from
lint.nim and trusted on faith.
"""

import json
from pathlib import Path

import numpy as np
from PIL import Image

from para_art_fix import outline

# tools/art/tests/test_outline.py -> parents[3] is the repo root.
FIXTURES = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "art" / "outline"


def _load_cases():
    return json.loads((FIXTURES / "cases.json").read_text())


def test_every_shared_fixture_matches_lint_nims_recorded_offender_count():
    for case in _load_cases():
        rgba = np.array(Image.open(FIXTURES / case["file"]).convert("RGBA"))
        assert rgba.shape[:2] == (case["cell_h"], case["cell_w"]), case["file"]
        stats = outline.analyze(rgba)
        assert stats["offenders"] == case["outline_offenders"], case["file"]


def _solid_square(size, fill, alpha=255):
    rgba = np.zeros((size, size, 4), dtype=np.uint8)
    rgba[..., :3] = fill
    rgba[..., 3] = alpha
    return rgba


def _pad(rgba, m=2):
    # Transparent margin so the opaque shape never touches the cell edge
    # (apply_outline refuses those).
    h, w = rgba.shape[:2]
    out = np.zeros((h + 2 * m, w + 2 * m, 4), dtype=np.uint8)
    out[m:m + h, m:m + w] = rgba
    return out


def _minority_offender_sprite():
    # 20x20 fully opaque square: a boundary ring that's mostly well below
    # the floor except for a handful of offending pixels, and a
    # varied-shade interior (so the floor isn't the interior's only shade -
    # a flat-fill sprite isn't this rule's target case) with a single pixel
    # at the true floor - art-outline-test report §3(c)'s "strike" shape (a
    # mostly-dark edge with a minority of offenders), just smaller.
    rgba = np.zeros((20, 20, 4), dtype=np.uint8)
    rgba[..., 3] = 255
    rgba[0, :, :3] = 60
    rgba[-1, :, :3] = 60
    rgba[:, 0, :3] = 60
    rgba[:, -1, :3] = 60
    rgba[1:-1, 1:-1, :3] = 150  # interior, shade 1
    rgba[5:15, 5:15, :3] = 130  # interior, shade 2
    rgba[10, 10, :3] = 90  # the single darkest (floor) pixel
    rgba[0, 1, :3] = 200  # boundary offender 1
    rgba[0, 2, :3] = 200  # boundary offender 2
    rgba[-1, -1, :3] = 200  # boundary offender 3
    return _pad(rgba)


def test_fixes_a_minority_offender_edge():
    rgba = _minority_offender_sprite()
    stats = outline.analyze(rgba)
    assert 0 < stats["offenders"] < stats["boundary_total"]
    assert stats["offender_fraction"] < outline.ALL_BOUNDARY_OFFENDER_FRACTION

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert info["offenders_fixed"] == stats["offenders"]
    boundary, _ = outline.classify(rgba[..., 3])
    after = outline.analyze(fixed)
    assert after["offenders"] == 0
    # untouched pixels (not an offending boundary pixel) keep their exact
    # original colour - only the offenders moved.
    unchanged = ~(boundary & (outline.luma(rgba[..., :3].astype(np.float64)) >=
                              stats["darkest_interior"]))
    assert np.array_equal(fixed[unchanged], rgba[unchanged])


def test_never_changes_the_palette_beyond_the_reused_dark_colour():
    rgba = _minority_offender_sprite()
    before_colors = {tuple(c) for c in rgba[rgba[..., 3] == 255][:, :3].tolist()}
    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    after_colors = {tuple(c) for c in fixed[fixed[..., 3] == 255][:, :3].tolist()}
    new_colors = after_colors - before_colors
    # at most one new colour - the darkest interior colour, nudged at most
    # 1 unit per channel darker to clear the rule's own `>=` tie.
    assert len(new_colors) <= 1
    if new_colors:
        (new_color,) = new_colors
        darkest_interior_color = (90, 90, 90)
        assert all(abs(a - b) <= 1 for a, b in zip(new_color, darkest_interior_color))


def _near_black_body_sprite():
    # 20x20 fully opaque near-black body (luma 14) with a few slightly darker
    # interior pixels (luma 9): the floor is 9, so every edge pixel offends,
    # and a rim in the floor colour (luma ~8) would sit 6 luma units under the
    # body right beside it - art-outline-test report §5's cultivator pose, a
    # near-black body with near-black linework, scaled down. No outline drawn
    # here could be told from the body.
    rgba = _solid_square(20, 14)
    for y, x in [(9, 9), (9, 10), (10, 9), (10, 10), (12, 12)]:
        rgba[y, x] = [9, 9, 9, 255]
    return _pad(rgba)


def test_refuses_when_the_rim_would_melt_into_a_near_black_body():
    rgba = _near_black_body_sprite()
    assert outline.analyze(rgba)["offenders"] > 0

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.REFUSE_INTERIOR_INK
    assert info["rim_contrast"] < outline.MIN_RIM_CONTRAST
    assert info["offenders_fixed"] == 0
    assert np.array_equal(fixed, rgba)  # refused: nothing recoloured


def test_a_dark_body_the_rim_still_stands_off_from_outlines():
    # The same shape with a dark-robe body (luma 40 beside a luma-9 floor): a
    # dark sprite, not an indistinguishable one. The old absolute
    # darkness test refused this; the relative one lets it through.
    rgba = _solid_square(20, 40)
    for y, x in [(9, 9), (9, 10), (10, 9), (10, 10), (12, 12)]:
        rgba[y, x] = [9, 9, 9, 255]
    rgba = _pad(rgba)

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert info["rim_contrast"] >= outline.MIN_RIM_CONTRAST
    assert outline.analyze(fixed)["offenders"] == 0


def test_a_big_dark_mass_away_from_the_edge_does_not_block_the_outline():
    # 8% of the opaque pixels in one solid near-black blob, but in the middle
    # of a mid-grey body: the rim is recoloured next to grey, so it reads. The
    # blob is not what the rim has to stand off from.
    rgba = _solid_square(60, 128)
    rgba[20:37, 20:37] = [9, 9, 9, 255]  # 289 of 3600
    rgba = _pad(rgba)

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert outline.analyze(fixed)["offenders"] == 0


def test_scattered_dark_ink_away_from_the_edge_does_not_block_the_outline():
    rgba = _solid_square(60, 128)
    for y in range(4, 56, 2):
        for x in range(4, 56, 3):
            rgba[y, x] = [9, 9, 9, 255]
    rgba = _pad(rgba)

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert outline.analyze(fixed)["offenders"] == 0


def test_pure_black_ink_inside_still_refuses_because_nothing_is_darker():
    # Literal black linework: lint wants the boundary darker than the darkest
    # interior pixel, and there is no luma below 0.
    rgba = _solid_square(10, 128)
    for y, x in [(4, 4), (4, 5), (5, 4), (5, 5), (6, 6)]:
        rgba[y, x] = [0, 0, 0, 255]
    rgba = _pad(rgba)

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.REFUSE_FLOOR_AT_BLACK
    assert np.array_equal(fixed, rgba)


def _dark_hair_sprite():
    # Cultivator-shaped: a 60x90 opaque body (5400 px) with a dark region of
    # ~3% of the opaque pixels shaded into 2x2 islands with a gap between each,
    # like dark hair - luma 7, the sprite's floor. Far from the edge, against
    # a luma-120 body.
    rgba = np.zeros((90, 60, 4), dtype=np.uint8)
    rgba[..., :3] = 120
    rgba[..., 3] = 255
    n = 0
    for y in range(10, 40, 3):
        for x in range(10, 50, 3):
            if n < 38:
                rgba[y:y + 2, x:x + 2, :3] = 7
                n += 1
    return _pad(rgba)


def test_outlines_a_small_dark_region_of_about_three_percent():
    rgba = _dark_hair_sprite()
    stats = outline.analyze(rgba)
    assert stats["offenders"] > 0

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert info["offenders_fixed"] == stats["offenders"]
    assert outline.analyze(fixed)["offenders"] == 0


def test_the_web_app_cultivator_with_dark_hair_outlines():
    # The real sprite the guard used to refuse (hair luma ~7, 2.6% of opaque
    # pixels): tests/fixtures/cultivator_64x96_no_outline.png, `para art fix`
    # output without --outline.
    rgba = np.array(Image.open(Path(__file__).parent / "fixtures"
                               / "cultivator_64x96_no_outline.png").convert("RGBA"))
    stats = outline.analyze(rgba)
    assert stats["offenders"] > 0

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert outline.analyze(fixed)["offenders"] == 0


def _all_boundary_small_cell_sprite(size):
    # A fully opaque size x size square, uniform body colour, with a single
    # much darker interior pixel setting the floor - art-webapp-lint report
    # §3's cultivator: no drawn outline anywhere, so once the one dark
    # interior pixel sets the floor, every boundary pixel offends. Only one
    # floor pixel keeps the interior-ink fraction tiny, isolating the
    # all-boundary guard from the interior-ink guard.
    rgba = _solid_square(size, 50)
    mid = size // 2
    rgba[mid, mid] = [5, 5, 5, 255]
    return _pad(rgba)


def test_flags_the_all_boundary_case_at_a_small_cell():
    rgba = _all_boundary_small_cell_sprite(40)  # 44 padded: under SMALL_CELL_DIM (48)
    stats = outline.analyze(rgba)
    assert stats["offender_fraction"] >= outline.ALL_BOUNDARY_OFFENDER_FRACTION

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.FLAG_ALL_BOUNDARY
    assert info["offenders_fixed"] == 0
    assert np.array_equal(fixed, rgba)  # flagged: nothing recoloured


def test_the_same_all_boundary_case_auto_applies_at_a_large_enough_cell():
    # art-webapp-lint report §3: the identical 100%-of-boundary failure
    # looked fine at 48x64/64x96 - only the small 32x48 cell read as
    # damage. The guard is cell size, not the offender fraction alone.
    rgba = _all_boundary_small_cell_sprite(64)  # at/over SMALL_CELL_DIM (48)
    stats = outline.analyze(rgba)
    assert stats["offender_fraction"] >= outline.ALL_BOUNDARY_OFFENDER_FRACTION

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert info["offenders_fixed"] == stats["offenders"]
    after = outline.analyze(fixed)
    assert after["offenders"] == 0


def test_never_grows_the_silhouette():
    for rgba in (_minority_offender_sprite(), _near_black_body_sprite(),
                 _all_boundary_small_cell_sprite(40), _all_boundary_small_cell_sprite(64)):
        fixed, _info = outline.apply_outline(rgba)
        assert np.array_equal(fixed[..., 3] > 0, rgba[..., 3] > 0)


def test_refuses_when_the_silhouette_touches_the_cell_edge():
    rgba = _solid_square(20, 50)
    rgba[10, 10] = [5, 5, 5, 255]
    assert outline.analyze(rgba)["offenders"] > 0

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.REFUSE_EDGE_TOUCH
    assert info["offenders_fixed"] == 0
    assert np.array_equal(fixed, rgba)


def test_refuses_instead_of_reporting_ok_when_the_floor_is_pure_black():
    rgba = _pad(_solid_square(60, 50))
    rgba[2 + 30, 2 + 30] = [0, 0, 0, 255]

    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.REFUSE_FLOOR_AT_BLACK
    assert info["offenders_fixed"] == 0
    assert np.array_equal(fixed, rgba)


def test_refuses_when_the_reused_colour_would_exceed_the_colour_cap():
    rgba = _all_boundary_small_cell_sprite(64)
    n = len({tuple(c) for c in rgba[rgba[..., 3] > 0][:, :3].tolist()})

    fixed, info = outline.apply_outline(rgba, max_colors=n)
    assert info["outline"] == outline.REFUSE_COLOR_CAP
    assert np.array_equal(fixed, rgba)

    _fixed, info = outline.apply_outline(rgba, max_colors=n + 1)
    assert info["outline"] == outline.OK


def test_palette_lock_uses_the_closest_palette_member_below_the_floor():
    rgba = _all_boundary_small_cell_sprite(64)
    palette = np.array([[50, 50, 50], [5, 5, 5], [3, 3, 3], [0, 0, 0]], dtype=np.uint8)

    fixed, info = outline.apply_outline(rgba, palette=palette)
    assert info["outline"] == outline.OK
    assert outline.analyze(fixed)["offenders"] == 0
    changed = np.any(fixed != rgba, axis=-1)
    assert changed.any()
    assert {tuple(c) for c in fixed[changed][:, :3].tolist()} == {(3, 3, 3)}


def test_palette_lock_recolours_each_rim_pixel_to_the_nearest_darker_member():
    # A purple rim and a green rim, both lit, over a darker body: each takes the
    # darker member of its own hue, not the one closest in luma.
    rgba = np.zeros((8, 8, 4), dtype=np.uint8)
    rgba[1:7, 1:7] = [120, 120, 120, 255]
    rgba[1, 1:4] = [200, 80, 255, 255]
    rgba[1, 4:7] = [80, 255, 80, 255]
    palette = np.array([[120, 120, 120], [200, 80, 255], [80, 255, 80],
                        [90, 30, 130], [40, 150, 40], [100, 100, 100]], dtype=np.uint8)

    fixed, info = outline.apply_outline(rgba, palette=palette)
    assert info["outline"] == outline.OK
    assert outline.analyze(fixed)["offenders"] == 0
    assert tuple(fixed[1, 2, :3]) == (90, 30, 130)
    assert tuple(fixed[1, 5, :3]) == (40, 150, 40)


def test_palette_lock_with_no_member_below_the_floor_refuses():
    rgba = _all_boundary_small_cell_sprite(64)
    palette = np.array([[50, 50, 50], [200, 200, 200]], dtype=np.uint8)

    fixed, info = outline.apply_outline(rgba, palette=palette)
    assert info["outline"] == outline.REFUSE_PALETTE
    assert np.array_equal(fixed, rgba)


# --- dark sprites (GameLab batch 1/2: dark robes, dark cracked-magma core) ----
#
# The three real sprites `fix --outline` used to refuse with refuse:interior-ink,
# as `fix` output without --outline (tests/fixtures/art/batch2/ are their sources).

DARK_FIXTURES = Path(__file__).parent / "fixtures"


def test_the_dark_robed_sprites_and_the_dark_core_outline():
    for name in ("rogue_cultivator_96x96", "corpse_puppet_96x96", "core_medium_24x24"):
        rgba = np.array(Image.open(DARK_FIXTURES / f"{name}_no_outline.png").convert("RGBA"))
        stats = outline.analyze(rgba)
        assert stats["offenders"] > 0, name
        assert stats["darkest_interior"] < 5, name  # dark enough that the old guard refused

        fixed, info = outline.apply_outline(rgba, max_colors=48)
        assert info["outline"] == outline.OK, name
        assert info["rim_contrast"] >= outline.MIN_RIM_CONTRAST, name
        assert info["offenders_fixed"] == stats["offenders"], name
        assert outline.analyze(fixed)["offenders"] == 0, name
        assert np.array_equal(fixed[..., 3], rgba[..., 3]), name
