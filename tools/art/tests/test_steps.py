"""Unit tests for the individual chain steps (report §6.1 steps 2, 4, 5, 6,
7). The end-to-end §6.3 regression (real degraded fixtures, exact size, ≤1%
sprite pixels off, idempotent, `para art lint` passes) lives in
tests/test_art_fix_regression.nim, run through the real `para art fix` CLI.
"""

import json
import subprocess
import sys

import numpy as np
from PIL import Image

from para_art_fix import cell, cleanup, keying, palette, pipeline, slicing


def _sprite(w=8, h=8, color=(50, 50, 200)):
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[2:6, 2:6] = [*color, 255]
    return rgba


def _on_green(rgba):
    out = rgba.copy()
    out[out[..., 3] == 0] = [0, 255, 0, 255]
    return out


def test_key_to_alpha_keys_the_sampled_background():
    rgba = _sprite()
    bg = rgba[..., 3] == 0
    keyed, info = keying.key_to_alpha(_on_green(rgba)[..., :3])
    assert (keyed[..., 3] == 0).sum() == bg.sum()
    assert (keyed[2:6, 2:6, 3] == 255).all()
    assert info["keyed_px"] == int(bg.sum())
    assert info["key"] == "00ff00"


def test_key_to_alpha_is_a_no_op_on_an_already_keyed_image():
    rgba = _sprite()
    keyed, info = keying.key_to_alpha(rgba)
    assert np.array_equal(keyed, rgba)
    assert info["keyed_px"] == 0
    assert info["key"] == keying.SKIP_ALPHA


def test_key_to_alpha_skips_a_full_bleed_asset_whose_corners_differ():
    rng = np.random.default_rng(1)
    tile = np.dstack([np.full((16, 16, 3), (120, 80, 40), dtype=np.uint8),
                      np.full((16, 16), 255, dtype=np.uint8)])
    tile[rng.random((16, 16)) < 0.2, :3] = (70, 45, 20)
    tile[0, 0, :3] = (250, 250, 250)  # a frame highlight: the corners no longer agree
    keyed, info = keying.key_to_alpha(tile)
    assert info["key"] == keying.SKIP_CORNERS
    assert np.array_equal(keyed, tile)
    forced, forced_info = keying.key_to_alpha(tile, override_hex="785028")
    assert forced_info["key"] == "785028"
    assert (forced[..., 3] == 0).any()


def _pocketed_sprite():
    rgba = _on_green(_sprite(12, 12))
    rgba[2:10, 2:10] = [50, 50, 200, 255]
    rgba[4:6, 4:6] = [10, 240, 20, 255]  # a 2x2 enclosed pocket, close to the key green
    return rgba


def test_key_to_alpha_keys_an_enclosed_key_coloured_pocket():
    keyed, info = keying.key_to_alpha(_pocketed_sprite())
    assert (keyed[4:6, 4:6, 3] == 0).all()
    assert (keyed[2:10, 2:10, 3] == 255).sum() == 64 - 4
    assert info["keyed_px"] == 144 - 64 + 4


def test_key_to_alpha_border_only_keeps_an_enclosed_pocket():
    keyed, _ = keying.key_to_alpha(_pocketed_sprite(), border_only=True)
    assert (keyed[2:10, 2:10, 3] == 255).all()
    assert (keyed[0, :, 3] == 0).all()


def test_key_to_alpha_keeps_a_lone_key_coloured_interior_pixel():
    rgba = _on_green(_sprite(12, 12))
    rgba[2:10, 2:10] = [50, 50, 200, 255]
    rgba[5, 5] = [0, 255, 0, 255]  # exactly the key, but a single pixel
    keyed, _ = keying.key_to_alpha(rgba)
    assert (keyed[2:10, 2:10, 3] == 255).all()


def test_key_to_alpha_keeps_a_green_eye_in_a_small_blue_sprite():
    rgba = np.zeros((10, 10, 4), dtype=np.uint8)
    rgba[2:8, 2:8] = [50, 50, 200, 255]
    rgba[4, 4] = [60, 200, 60, 255]  # a highlight or eye pixel near the key hue
    sprite = rgba[..., 3] == 255
    keyed, _ = keying.key_to_alpha(_on_green(rgba))
    assert (keyed[sprite, 3] == 255).all()
    assert (keyed[~sprite, 3] == 0).all()


def test_key_to_alpha_keeps_a_dark_key_tinted_outline_and_shadow():
    rgba = np.zeros((12, 12, 4), dtype=np.uint8)
    rgba[3:9, 3:9] = [12, 18, 12, 255]  # outline ring, touching the background
    rgba[4:8, 4:8] = [50, 50, 200, 255]
    rgba[5, 5] = [0, 1, 0, 255]  # interior shadow pixel
    rgba[9, 3:9] = [0, 1, 0, 255]  # drop shadow under the sprite, touching the background
    sprite = rgba[..., 3] == 255
    keyed, info = keying.key_to_alpha(_on_green(rgba))
    assert (keyed[sprite, 3] == 255).all()
    assert (keyed[~sprite, 3] == 0).all()
    assert info["keyed_px"] == int((~sprite).sum())


def test_key_to_alpha_trusts_existing_alpha_on_a_transparent_input():
    rgba = _sprite(color=(200, 30, 30))
    rgba[3, 3] = [0, 0, 0, 0]  # an enclosed transparent hole
    rgba[4, 4, 3] = 100  # semi-alpha below the cut
    rgba[4, 3, 3] = 200  # semi-alpha above the cut
    keyed, info = keying.key_to_alpha(rgba)
    assert keyed[3, 3, 3] == 0
    assert keyed[4, 4, 3] == 0
    assert keyed[4, 3, 3] == 255
    assert ((keyed[2:6, 2:6, 3] == 255).sum()) == 14
    assert (keyed[..., 3] == 0).sum() == 64 - 14
    assert info["keyed_px"] == 0
    assert info["key"] == keying.SKIP_ALPHA


def test_key_to_alpha_explicit_key_applies_to_input_with_a_semi_transparent_pixel():
    rgba = _on_green(_sprite())
    rgba[2, 2, 3] = 120  # one semi-transparent sprite-edge pixel
    skipped, skipped_info = keying.key_to_alpha(rgba)
    assert skipped_info["key"] == keying.SKIP_ALPHA
    assert (skipped[0, :, 3] == 255).all()
    forced, info = keying.key_to_alpha(rgba, override_hex="00ff00")
    assert info["key"] == "00ff00"
    assert forced[2, 2, 3] == 0
    assert ((forced[2:6, 2:6, 3] == 255).sum()) == 15
    assert (forced[..., 3] == 0).sum() == 64 - 15
    assert info["keyed_px"] == 64 - 16


def test_remove_orphans_clears_isolated_pixels_only():
    rgba = _sprite()
    rgba[0, 0] = [1, 1, 1, 255]  # isolated: no visible 8-neighbour
    cleaned, info = cleanup.remove_orphans(rgba)
    assert cleaned[0, 0, 3] == 0
    assert info["removed"] == 1
    assert (cleaned[2:6, 2:6, 3] == 255).all()  # the solid block is untouched


def test_remove_orphans_keeps_a_touching_pair():
    rgba = np.zeros((4, 4, 4), dtype=np.uint8)
    rgba[0, 0] = [1, 1, 1, 255]
    rgba[1, 1] = [1, 1, 1, 255]  # diagonal neighbour of (0,0): not isolated
    cleaned, info = cleanup.remove_orphans(rgba)
    assert info["removed"] == 0
    assert cleaned[0, 0, 3] == 255 and cleaned[1, 1, 3] == 255


def test_palette_remap_snaps_to_nearest_and_counts_changed_pixels():
    rgba = np.zeros((8, 8, 4), dtype=np.uint8)
    rgba[2:6, 2:6] = [200, 50, 50, 255]
    rgba[2, 2] = [201, 49, 49, 255]  # 1 px off the block's colour
    out, info = palette.remap(rgba, _write_palette("c8_3232"))
    assert (out[2:6, 2:6, :3] == [200, 50, 50]).all()
    assert info["remapped_px"] == 1
    assert info["colors"] == 1


def test_palette_remap_reserves_the_darkest_colour_for_the_boundary(tmp_path):
    pal = tmp_path / "p.hex"
    pal.write_text("050505\n202020\n808080\n")
    rgba = np.zeros((7, 7, 4), dtype=np.uint8)
    rgba[1:6, 1:6] = [6, 6, 6, 255]  # rim and body both nearest the darkest colour
    plain, _ = palette.remap(rgba, str(pal))
    assert (plain[1:6, 1:6, :3] == [5, 5, 5]).all()
    out, info = palette.remap(rgba, str(pal), reserve_outline=True)
    assert (out[1, 1:6, :3] == [5, 5, 5]).all()  # the rim keeps the darkest colour
    assert (out[2:5, 2:5, :3] == [32, 32, 32]).all()  # the interior skips it
    assert info["remapped_px"] == 25


def _write_palette(tmp_name):
    import pathlib
    import tempfile
    path = pathlib.Path(tempfile.gettempdir()) / f"para_art_fix_test_{tmp_name}.hex"
    path.write_text("c83232\n")
    return str(path)


def test_place_in_cell_is_a_no_op_when_already_the_declared_size():
    rgba = _sprite()
    out, info = cell.place_in_cell(rgba, (8, 8), "bottom")
    assert np.array_equal(out, rgba)
    assert info["placed"] is False


def test_place_in_cell_trims_and_pivots_when_sizes_differ():
    rgba = _sprite()
    out, info = cell.place_in_cell(rgba, (12, 12), "bottom")
    assert out.shape == (12, 12, 4)
    assert info["placed"] is True
    # feet on the last row: the block's bottom row (y=5 in the original,
    # 4px tall) lands on row 11
    assert (out[11, 4:8, 3] == 255).all()
    assert (out[7, 4:8, 3] == 0).all()  # nothing above the trimmed content


def test_slice_content_merges_a_dilation_gap_but_keeps_far_sprites_apart():
    rgba = np.zeros((10, 30, 4), dtype=np.uint8)
    rgba[2:6, 1:3] = [1, 1, 1, 255]
    rgba[2:6, 4:6] = [1, 1, 1, 255]  # 1px gap: merges under the default 2px dilation
    rgba[2:6, 20:24] = [2, 2, 2, 255]  # far away: stays separate
    pieces = slicing.slice_content(rgba)
    assert len(pieces) == 2
    widths = sorted(p[0][2] for p in pieces)
    assert widths == [4, 5]


def test_slice_or_whole_skips_slicing_when_the_cell_is_already_known():
    rgba = np.zeros((10, 30, 4), dtype=np.uint8)
    rgba[2:6, 1:3] = [1, 1, 1, 255]
    rgba[2:6, 20:24] = [2, 2, 2, 255]
    pieces = slicing.slice_or_whole(rgba, known_cell=True)
    assert len(pieces) == 1
    assert pieces[0][1].shape == rgba.shape


def test_fix_file_keys_before_slicing_so_a_sheet_on_a_key_background_splits(tmp_path):
    sheet = np.zeros((16, 40, 4), dtype=np.uint8)
    sheet[4:12, 2:10] = [50, 50, 200, 255]
    sheet[4:12, 28:36] = [200, 120, 40, 255]
    src = tmp_path / "sheet.png"
    Image.fromarray(_on_green(sheet), "RGBA").save(src)
    results = pipeline.fix_file(str(src), str(tmp_path / "out"), out_name="sheet")
    assert [r["out"].rsplit("/", 1)[-1] for r in results] == ["sheet_00.png", "sheet_01.png"]
    assert all("error" not in r for r in results)


def test_an_in_place_run_never_overwrites_another_assets_input(tmp_path):
    sheet = np.zeros((16, 40, 4), dtype=np.uint8)
    sheet[4:12, 2:10] = [200, 120, 40, 255]
    sheet[4:12, 28:36] = [200, 120, 40, 255]
    Image.fromarray(_on_green(sheet), "RGBA").save(tmp_path / "hero.png")
    Image.fromarray(_sprite(), "RGBA").save(tmp_path / "hero_00.png")
    before = (tmp_path / "hero_00.png").read_bytes()
    request = {"out_dir": str(tmp_path), "assets": [
        {"file": str(tmp_path / "hero.png"), "out_name": "hero", "cell": None},
        {"file": str(tmp_path / "hero_00.png"), "out_name": "hero_00", "cell": [8, 8]},
    ]}
    proc = subprocess.run([sys.executable, "-m", "para_art_fix"], input=json.dumps(request),
                          capture_output=True, text=True)
    results = json.loads(proc.stdout)["results"]
    assert proc.returncode == 1
    assert (tmp_path / "hero_00.png").read_bytes() == before
    errors = [r for r in results if "error" in r]
    assert [(r["file"], r["out"]) for r in errors] == [(str(tmp_path / "hero.png"), str(tmp_path / "hero_00.png"))]
    assert "collides with" in errors[0]["error"]


def test_fix_file_rerun_on_its_own_output_changes_nothing(tmp_path):
    src = tmp_path / "hero.png"
    Image.fromarray(_on_green(_sprite(12, 12)), "RGBA").save(src)
    out_dir = tmp_path / "out"
    first = pipeline.fix_file(str(src), str(out_dir), out_name="hero", cell=(12, 12))
    assert first[0]["changed"] is True and first[0]["key"] == "00ff00"
    before = (out_dir / "hero.png").read_bytes()
    second = pipeline.fix_file(str(out_dir / "hero.png"), str(out_dir), out_name="hero", cell=(12, 12))
    assert second[0]["changed"] is False and second[0]["key"] == keying.SKIP_ALPHA
    assert (out_dir / "hero.png").read_bytes() == before
