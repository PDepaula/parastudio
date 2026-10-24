"""`para_art_fix.keyleak`: key-coloured pixels that survive keying are stripped
(removed when they touch transparency, filled from the nearest sprite pixel when
enclosed). The real-sprite cases use GameLab batch 2's `core_medium.png`
(tests/fixtures/art/batch2/): after keying, 6 exact-key pixels hung off or sat
inside its silhouette, and lint could not see them.
"""

from pathlib import Path

import numpy as np
from PIL import Image

from para_art_fix import keyleak, pipeline

BATCH2 = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "art" / "batch2"
KEY = np.array([0, 255, 0], dtype=np.float64)


def _sprite():
    # 8x8 opaque brown body padded by 2 transparent pixels each side.
    rgba = np.zeros((12, 12, 4), dtype=np.uint8)
    rgba[2:10, 2:10] = [120, 80, 40, 255]
    return rgba


def test_no_key_is_a_no_op():
    rgba = _sprite()
    rgba[2, 2] = [0, 255, 0, 255]
    out, info = keyleak.strip_key_leaks(rgba, None)
    assert np.array_equal(out, rgba) and info == {"removed": 0, "filled": 0}


def test_a_leak_on_the_silhouette_goes_transparent():
    rgba = _sprite()
    rgba[2, 5] = [0, 255, 0, 255]
    out, info = keyleak.strip_key_leaks(rgba, KEY)
    assert out[2, 5, 3] == 0
    assert info == {"removed": 1, "filled": 0}
    assert np.array_equal(out[3:10, 2:10], rgba[3:10, 2:10])


def test_a_fringe_clump_is_eaten_from_the_outside_in():
    rgba = _sprite()
    rgba[2:4, 5] = [0, 255, 0, 255]  # two leaked pixels, the inner one only exposed once the outer goes
    out, info = keyleak.strip_key_leaks(rgba, KEY)
    assert out[2, 5, 3] == 0 and out[3, 5, 3] == 0
    assert info["removed"] == 2


def test_an_enclosed_leak_is_filled_not_holed():
    rgba = _sprite()
    rgba[5, 5] = [0, 255, 0, 255]
    out, info = keyleak.strip_key_leaks(rgba, KEY)
    assert out[5, 5, 3] == 255
    assert out[5, 5, :3].tolist() == [120, 80, 40]
    assert info == {"removed": 0, "filled": 1}


def test_colours_that_are_not_the_key_survive():
    rgba = _sprite()
    rgba[2, 5] = [0, 128, 128, 255]  # teal crystal
    rgba[3, 5] = [40, 150, 40, 255]  # a darker green, 129 from the key
    out, info = keyleak.strip_key_leaks(rgba, KEY)
    assert np.array_equal(out, rgba) and info == {"removed": 0, "filled": 0}


def test_key_colour_parses_a_status_and_skips_the_skip_statuses():
    assert keyleak.key_colour("00ff00").tolist() == [0, 255, 0]
    assert keyleak.key_colour("skip:alpha") is None
    assert keyleak.key_colour("skip:corners") is None


def _fix_core(tmp_path, **kw):
    results = pipeline.fix_file(str(BATCH2 / "core_medium.png"), str(tmp_path), out_name="core_medium",
                                cell=(24, 24), profile="hibit", key_hex="00ff00", max_colors=48,
                                scale=0.2323, **kw)
    assert "error" not in results[0], results[0]
    return np.array(Image.open(tmp_path / "core_medium.png").convert("RGBA")), results[0]


def test_a_real_sprite_comes_out_with_no_key_pixels(tmp_path):
    out, entry = _fix_core(tmp_path, outline=True)
    assert entry["key_leak_px"] > 0
    assert not keyleak.leaked(out, KEY).any()


def test_key_border_only_keeps_the_key_colour_inside_the_sprite(tmp_path):
    _out, entry = _fix_core(tmp_path, key_border_only=True)
    assert entry["key_leak_px"] == 0
