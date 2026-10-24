"""Regression tests for three `para art fix` defects found fixing GameLab batch 1
(tests/fixtures/art/batch1/): `--cell` stretching a square source, the colour cap
only met by accident, and the outline step refusing small sprites. The same
sprites run through the real CLI + `para art lint` in tests/test_art_fix_batch1.nim.
"""

from pathlib import Path

import numpy as np
from PIL import Image

from para_art_fix import grid, keying, outline, pipeline, quantize

BATCH1 = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "art" / "batch1"
KEY = "00ff00"


def _fix(name, tmp_path, *, cell, profile="hibit", max_colors=48, outline=False,
         palette_path=None):
    results = pipeline.fix_file(str(BATCH1 / f"{name}.png"), str(tmp_path), out_name=name,
                                cell=cell, profile=profile, key_hex=KEY, outline=outline,
                                max_colors=max_colors, palette_path=palette_path)
    assert "error" not in results[0], results[0]
    return np.array(Image.open(tmp_path / f"{name}.png").convert("RGBA")), results[0]


def _bbox(mask):
    ys, xs = np.where(mask)
    return xs.min(), xs.max() + 1, ys.min(), ys.max() + 1


def _aspect(mask):
    x0, x1, y0, y1 = _bbox(mask)
    return (x1 - x0) / (y1 - y0)


def _colors(rgba):
    return quantize.count_colors(rgba)


# --- (1) --cell is aspect-correct ------------------------------------------

def test_a_square_source_into_a_tall_cell_keeps_the_figures_aspect(tmp_path):
    src = keying.key_to_alpha(np.array(Image.open(BATCH1 / "player_up.png").convert("RGBA")),
                              override_hex=KEY)[0]
    out, info = _fix("player_up", tmp_path, cell=(96, 144))
    assert out.shape[:2] == (144, 96)
    assert info["grid_source"] == "forced"
    # 0.70 in the source; the old non-uniform x0.375 by x0.5625 stretch gave 0.43.
    assert abs(_aspect(out[..., 3] > 0) - _aspect(src[..., 3] > 0)) < 0.03


def test_a_forced_cell_pads_bottom_aligned_by_default():
    rgba = np.zeros((64, 64, 4), dtype=np.uint8)
    rgba[8:64, 16:48] = [200, 40, 40, 255]  # 32x56 figure standing on the bottom edge
    fitted, padded = grid.fit_to_aspect(rgba, 24, 36, "bottom")
    assert padded and fitted.shape[:2] == (96, 64)  # 64 wide -> 64*36/24 = 96 tall
    assert (fitted[:32, :, 3] == 0).all()  # all the new rows are above the figure
    assert np.array_equal(fitted[32:], rgba)


def test_a_forced_cell_centres_the_padding_without_a_bottom_pivot():
    rgba = np.full((64, 64, 4), 255, dtype=np.uint8)
    fitted, _ = grid.fit_to_aspect(rgba, 24, 36, "none")
    assert (fitted[:16, :, 3] == 0).all() and (fitted[-16:, :, 3] == 0).all()
    assert (fitted[16:-16, :, 3] == 255).all()


def test_a_source_wider_than_the_cell_pads_the_sides():
    rgba = np.full((60, 120, 4), 255, dtype=np.uint8)
    fitted, padded = grid.fit_to_aspect(rgba, 48, 96, "bottom")
    assert padded and fitted.shape[:2] == (240, 120)  # height grows: 120 * 96/48
    # scale is uniform: 120 px wide -> 48 cells is x0.4 on both axes
    assert fitted.shape[1] / 48 == fitted.shape[0] / 96


def test_a_source_already_in_the_cell_aspect_is_not_padded():
    rgba = np.full((50, 100, 4), 255, dtype=np.uint8)
    fitted, padded = grid.fit_to_aspect(rgba, 24, 12, "bottom")
    assert not padded and fitted is rgba


# --- (2) the profile's colour cap is enforced ---------------------------------

def test_the_wolf_meets_the_lowbit_cap_that_the_library_default_ignored(tmp_path):
    out, _ = _fix("wolf", tmp_path, cell=(96, 96), profile="lowbit", max_colors=16)
    assert 1 < _colors(out) <= 16


def test_every_cap_up_to_the_profile_budget_is_met_exactly_not_by_accident(tmp_path):
    for cap in (8, 24, 48):
        out, info = _fix("wolf", tmp_path / str(cap), cell=(96, 96), max_colors=cap)
        assert _colors(out) <= cap, cap
        assert info["colors"] == _colors(out)


def test_the_cap_holds_with_the_outline_step_that_may_add_a_colour(tmp_path):
    out, info = _fix("wolf", tmp_path, cell=(96, 96), max_colors=24, outline=True)
    assert info["outline"] == outline.OK
    assert _colors(out) <= 24


def test_a_palette_larger_than_the_cap_still_meets_the_cap(tmp_path):
    palette = tmp_path / "palette.hex"
    palette.write_text("\n".join(f"{r:02x}{g:02x}{b:02x}" for r in range(0, 256, 51)
                                 for g in range(0, 256, 51) for b in range(0, 256, 51)))
    out, _ = _fix("wolf", tmp_path / "out", cell=(96, 96), max_colors=16, palette_path=str(palette))
    assert _colors(out) <= 16
    pal = {tuple(int(line[i:i + 2], 16) for i in (0, 2, 4)) for line in palette.read_text().split()}
    assert {tuple(c) for c in out[out[..., 3] > 0][:, :3].tolist()} <= pal


def test_quantize_leaves_an_image_that_already_fits_alone():
    rng = np.random.default_rng(3)
    rgba = np.dstack([rng.integers(0, 256, (16, 16, 3), dtype=np.uint8),
                      np.full((16, 16), 255, dtype=np.uint8)])
    rgba[..., :3] = rgba[..., :3] // 64 * 64  # at most 64 colours
    out, info = quantize.quantize(rgba, 64)
    assert np.array_equal(out, rgba) and not info["quantized"]


def test_quantize_is_reproducible_and_never_touches_alpha():
    rng = np.random.default_rng(4)
    rgba = rng.integers(0, 256, (24, 24, 4), dtype=np.uint8)
    rgba[..., 3] = np.where(rgba[..., 3] > 100, 255, 0)
    a, _ = quantize.quantize(rgba, 10)
    b, _ = quantize.quantize(rgba, 10)
    assert np.array_equal(a, b) and np.array_equal(a[..., 3], rgba[..., 3])
    assert quantize.count_colors(a) <= 10


# --- (3) small sprites outline ------------------------------------------------

def test_the_batch1_stones_outline_at_every_pickup_size(tmp_path):
    for name in ("stone_small", "stone_medium", "stone_large"):
        for size in (16, 24, 32):
            out, info = _fix(name, tmp_path / f"{size}", cell=(size, size), outline=True)
            assert info["outline"] == outline.OK, (name, size)
            assert outline.analyze(out)["offenders"] == 0, (name, size)
            assert _colors(out) <= 48


def _small_sprite_with_floor(floor, body=200):
    # 8x6 body (48 opaque px, the 16x16-stone scale) with a 2x2 interior block at the floor
    # luma: 4 px = 8% of the sprite.
    rgba = np.zeros((14, 14, 4), dtype=np.uint8)
    rgba[3:9, 3:11] = [body, body, body, 255]
    rgba[5:7, 6:8] = [floor, floor, floor, 255]
    return rgba


def test_a_small_sprite_whose_darkest_shade_is_mid_tone_outlines():
    rgba = _small_sprite_with_floor(90)
    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert outline.analyze(fixed)["offenders"] == 0


def test_a_small_sprite_with_dark_ink_inside_a_light_body_outlines():
    # The floor is genuinely dark ink (luma 10), but the rim is recoloured next
    # to a light body, so it reads. The earlier absolute test refused this.
    rgba = _small_sprite_with_floor(10)
    assert outline.analyze(rgba)["darkest_interior"] < 48
    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert outline.analyze(fixed)["offenders"] == 0


def test_a_small_near_black_sprite_still_refuses():
    rgba = _small_sprite_with_floor(10, body=18)
    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.REFUSE_INTERIOR_INK
    assert np.array_equal(fixed, rgba)


def test_an_icon_sized_cell_applies_the_all_boundary_outline_instead_of_flagging():
    rgba = np.zeros((24, 24, 4), dtype=np.uint8)
    rgba[4:20, 4:20] = [50, 50, 50, 255]
    rgba[12, 12] = [5, 5, 5, 255]
    stats = outline.analyze(rgba)
    assert stats["offender_fraction"] >= outline.ALL_BOUNDARY_OFFENDER_FRACTION
    fixed, info = outline.apply_outline(rgba)
    assert info["outline"] == outline.OK
    assert outline.analyze(fixed)["offenders"] == 0
