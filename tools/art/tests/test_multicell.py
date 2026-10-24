"""`--cell` is one sprite's size (issue #38): a file that is a grid of cells -
a growth strip, a walk-cycle sheet - is refused instead of being collapsed
into one cell-sized output. A single sprite whose source is merely a whole
multiple of the cell (a 2x GameLab upscale) is still fixed as before.
"""

import json
import subprocess
import sys

import numpy as np
from PIL import Image

from para_art_fix import pipeline, slicing

CELL = (64, 64)


def _sheet(cols, rows, filled=None, cell=CELL):
    """cols x rows cells; each filled cell holds a block clear of its edges."""
    cw, ch = cell
    rgba = np.zeros((rows * ch, cols * cw, 4), dtype=np.uint8)
    for i in range(cols * rows) if filled is None else filled:
        cy, cx = divmod(i, cols)
        rgba[cy * ch + 16:cy * ch + 56, cx * cw + 20:cx * cw + 44] = [60 + 40 * i, 90, 140, 255]
    return rgba


def _save(tmp_path, name, rgba):
    path = tmp_path / name
    Image.fromarray(rgba, "RGBA").save(path)
    return str(path)


def test_a_three_cell_strip_is_a_grid():
    assert slicing.multi_cell_grid(_sheet(3, 1), CELL) == (3, 1)


def test_a_two_by_two_sheet_is_a_grid():
    assert slicing.multi_cell_grid(_sheet(2, 2), CELL) == (2, 2)


def test_a_sheet_with_only_two_filled_cells_is_a_grid():
    assert slicing.multi_cell_grid(_sheet(3, 1, filled=[0, 2]), CELL) == (3, 1)


def test_one_cell_sized_source_is_not_a_grid():
    assert slicing.multi_cell_grid(_sheet(1, 1), CELL) is None


def test_a_source_that_is_not_a_whole_multiple_is_not_a_grid():
    rgba = _sheet(3, 1)[:, :-1]
    assert slicing.multi_cell_grid(rgba, CELL) is None


def test_a_single_upscaled_sprite_is_not_a_grid():
    # a 128x128 source of one figure for a 64x64 cell: its body crosses the
    # middle lines, so the whole multiple alone does not make it a sheet
    rgba = np.zeros((128, 128, 4), dtype=np.uint8)
    rgba[20:120, 30:100] = [60, 90, 140, 255]
    assert slicing.multi_cell_grid(rgba, CELL) is None


def test_a_blank_multiple_is_not_a_grid():
    assert slicing.multi_cell_grid(np.zeros((64, 192, 4), dtype=np.uint8), CELL) is None


def test_fix_file_refuses_a_multi_cell_sheet_and_writes_nothing(tmp_path):
    src = _save(tmp_path, "sheet3.png", _sheet(3, 1))
    out_dir = tmp_path / "out"
    res = pipeline.fix_file(src, str(out_dir), out_name="sheet3", cell=CELL, profile="hibit")
    assert len(res) == 1
    assert "3x1 grid of 64x64 cells" in res[0]["error"]
    assert "192x64" in res[0]["error"]
    assert not out_dir.exists()


def test_fix_file_still_fixes_an_upscaled_single_sprite(tmp_path):
    rgba = np.zeros((128, 128, 4), dtype=np.uint8)
    rgba[20:120, 30:100] = [60, 90, 140, 255]
    src = _save(tmp_path, "stone.png", rgba)
    res = pipeline.fix_file(src, str(tmp_path / "out"), out_name="stone", cell=CELL, profile="hibit")
    assert "error" not in res[0]
    assert (res[0]["width"], res[0]["height"]) == CELL


def _run_cli(tmp_path, names, **request):
    assets = [{"file": str(tmp_path / n), "out_name": n.removesuffix(".png"), "cell": list(CELL),
               "pivot": "bottom"} for n in names]
    proc = subprocess.run([sys.executable, "-m", "para_art_fix"], capture_output=True, text=True,
                          input=json.dumps({"out_dir": str(tmp_path / "out"), "assets": assets, **request}))
    return proc.returncode, json.loads(proc.stdout)


def _pose(tmp_path, name):
    rgba = np.zeros((128, 128, 4), dtype=np.uint8)
    rgba[20:120, 40:90] = [60, 90, 140, 255]
    _save(tmp_path, name, rgba)


def test_a_refused_sheet_stops_a_fit_content_run_before_any_pose_is_written(tmp_path):
    _pose(tmp_path, "pose_a.png")
    _pose(tmp_path, "pose_b.png")
    _save(tmp_path, "strip.png", _sheet(3, 1))
    code, resp = _run_cli(tmp_path, ["pose_a.png", "pose_b.png", "strip.png"], fit="content")
    assert code == 1
    assert [r["file"] for r in resp["results"]] == [str(tmp_path / "strip.png")]
    assert "3x1 grid of 64x64 cells" in resp["results"][0]["error"]
    assert "fit" not in resp
    assert not (tmp_path / "out").exists()

