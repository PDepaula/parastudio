"""`--fit content` (fit.py): trim to the opaque bbox, one scale shared by every
figure in the run, a margin all round (bottom included, so the outline step's
edge-touch guard stays out of the way). Small synthetic figures on a key-green
canvas; the CLI flag handling is in tests/test_art_fix_cli.nim.
"""

import json
import subprocess
import sys

import numpy as np
import pytest
from PIL import Image

from para_art_fix import fit

CELL = (48, 72)


def _figure(path, fig_w, fig_h, canvas=128, x0=40):
    """A two-tone block figure standing near the bottom of a green canvas."""
    rgba = np.zeros((canvas, canvas, 4), dtype=np.uint8)
    rgba[..., :3] = [0, 255, 0]
    rgba[..., 3] = 255
    y1 = canvas - 8
    rgba[y1 - fig_h:y1, x0:x0 + fig_w] = [180, 40, 40, 255]
    rgba[y1 - fig_h:y1 - fig_h // 2, x0:x0 + fig_w] = [40, 40, 180, 255]
    Image.fromarray(rgba, "RGBA").save(path)


def _run(tmp_path, names, **request):
    assets = [{"file": str(tmp_path / f"{n}.png"), "out_name": n, "cell": list(CELL),
               "pivot": "bottom", "key": "00ff00"} for n in names]
    proc = subprocess.run([sys.executable, "-m", "para_art_fix"], capture_output=True, text=True,
                          input=json.dumps({"out_dir": str(tmp_path / "out"), "assets": assets,
                                            "fit": "content", **request}))
    return proc.returncode, json.loads(proc.stdout)


def _bbox(path):
    a = np.array(Image.open(path).convert("RGBA"))
    ys, xs = np.where(a[..., 3] > 0)
    return a.shape[:2], xs.min(), xs.max() + 1, ys.min(), ys.max() + 1


def test_shared_scale_fits_the_largest_figure_on_its_tightest_axis():
    # 100x200 in a 48x72 cell less 5% a side: min(43.2/100, 64.8/200) = 0.324
    assert fit.shared_scale([(100, 200), (50, 100)], CELL, 5, None) == pytest.approx(0.324)
    assert fit.shared_scale([(300, 100)], CELL, 5, None) == pytest.approx(43.2 / 300)


def test_shared_scale_by_figure_height_pins_the_tallest_figure():
    assert fit.shared_scale([(100, 200), (50, 100)], CELL, 5, 50) == pytest.approx(0.25)


def test_poses_of_different_height_keep_their_relative_size(tmp_path):
    _figure(tmp_path / "tall.png", 40, 100)
    _figure(tmp_path / "short.png", 40, 60)
    code, res = _run(tmp_path, ["tall", "short"])
    assert code == 0, res
    (shape, x0, x1, y0, y1) = _bbox(tmp_path / "out" / "tall.png")
    (_, sx0, sx1, sy0, sy1) = _bbox(tmp_path / "out" / "short.png")
    assert shape == (72, 48)
    # the tall one fills its 90% box (65 of 72 rows), the short one is 60/100 of it
    assert y1 - y0 == 65 and sy1 - sy0 == 39
    assert x1 - x0 == sx1 - sx0 == 26
    assert res["fit"]["scale"] == pytest.approx(0.648, abs=1e-3)
    assert (res["fit"]["figure_w"], res["fit"]["figure_h"]) == (26, 65)


def test_the_figure_sits_in_the_margin_box_bottom_aligned_and_centred(tmp_path):
    _figure(tmp_path / "a.png", 40, 100)
    code, _ = _run(tmp_path, ["a"], margin=5)
    assert code == 0
    (_, x0, x1, y0, y1) = _bbox(tmp_path / "out" / "a.png")
    assert 72 - y1 == 4  # round(72 * 5%): a gap under the feet, so nothing touches the cell edge
    assert y0 >= 3 and x0 >= 2 and 48 - x1 >= 2
    assert abs(x0 - (48 - x1)) <= 1


def test_a_wide_figure_is_limited_by_the_width(tmp_path):
    _figure(tmp_path / "wide.png", 100, 40)
    code, res = _run(tmp_path, ["wide"])
    assert code == 0
    (_, x0, x1, _y0, _y1) = _bbox(tmp_path / "out" / "wide.png")
    assert x1 - x0 == 43  # 48 less 5% a side = 43.2


def test_figure_height_scales_the_tallest_figure_to_that_height(tmp_path):
    _figure(tmp_path / "tall.png", 40, 100)
    _figure(tmp_path / "short.png", 40, 60)
    code, _ = _run(tmp_path, ["tall", "short"], figure_height=50)
    assert code == 0
    assert _bbox(tmp_path / "out" / "tall.png")[4] - _bbox(tmp_path / "out" / "tall.png")[3] == 50
    assert _bbox(tmp_path / "out" / "short.png")[4] - _bbox(tmp_path / "out" / "short.png")[3] == 30


def test_a_figure_that_cannot_fit_is_a_finding_not_a_bigger_cell(tmp_path):
    _figure(tmp_path / "tall.png", 40, 100)
    code, res = _run(tmp_path, ["tall"], figure_height=100)
    assert code == 1
    assert "bigger than" in res["results"][0]["error"]
    assert not (tmp_path / "out" / "tall.png").exists()


def test_without_fit_content_the_whole_canvas_is_fitted_as_before(tmp_path):
    _figure(tmp_path / "a.png", 40, 100)
    assets = [{"file": str(tmp_path / "a.png"), "out_name": "a", "cell": list(CELL),
               "pivot": "bottom", "key": "00ff00"}]
    proc = subprocess.run([sys.executable, "-m", "para_art_fix"], capture_output=True, text=True,
                          input=json.dumps({"out_dir": str(tmp_path / "out"), "assets": assets}))
    assert proc.returncode == 0 and "fit" not in json.loads(proc.stdout)
    (_, x0, x1, y0, y1) = _bbox(tmp_path / "out" / "a.png")
    assert y1 - y0 < 50  # x0.375 of a 100-row figure, not the content fit's 65


def test_a_source_smaller_than_the_cell_is_a_finding_not_an_upscale(tmp_path):
    _figure(tmp_path / "tiny.png", 8, 12, canvas=24, x0=8)
    code, res = _run(tmp_path, ["tiny"])
    assert code == 1
    assert "only scales down" in res["results"][0]["error"]
