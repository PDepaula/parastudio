"""`para_art_fix.pipeline.fix_tile` (`para art fix --tile`): one fully opaque
seamless ground tile, scaled onto its cell without keying, slicing, outline
or content fit. tests/test_art_tile.nim drives the same path through the real
CLI and checks lint's side (the seam measure, blank output)."""

from pathlib import Path

import numpy as np
from PIL import Image

from para_art_fix import pipeline

FIXTURES = Path(__file__).resolve().parents[3] / "tests" / "fixtures" / "art" / "tile"


def _fix(src, tmp_path, **kw):
    kw.setdefault("cell", (96, 96))
    return pipeline.fix_file(str(src), str(tmp_path), out_name="t", palette_path=None, max_colors=48,
                             tile=True, **kw)[0]


def test_an_opaque_tile_with_four_agreeing_corners_is_not_taken_for_a_key_background(tmp_path):
    entry = _fix(FIXTURES / "seamless_256.png", tmp_path)
    assert "error" not in entry
    out = np.array(Image.open(entry["out"]).convert("RGBA"))
    assert out.shape == (96, 96, 4)
    assert (out[..., 3] == 255).all()
    assert entry["colors"] > 1 and entry["key"] == "tile" and entry["keyed_px"] == 0


def test_the_downscale_keeps_a_seamless_source_seamless(tmp_path):
    entry = _fix(FIXTURES / "seamless_256.png", tmp_path)
    out = np.array(Image.open(entry["out"]).convert("RGB")).astype(int)
    seam = np.abs(out[:, -1] - out[:, 0]).sum(axis=1).mean()
    interior = np.abs(out[:, 1:] - out[:, :-1]).sum(axis=2).mean()
    assert seam <= interior


def test_resampling_picks_source_colours_not_blends(tmp_path):
    entry = _fix(FIXTURES / "seamless_256.png", tmp_path)
    src = {tuple(c) for c in np.array(Image.open(FIXTURES / "seamless_256.png").convert("RGB")).reshape(-1, 3)}
    out = {tuple(c) for c in np.array(Image.open(entry["out"]).convert("RGB")).reshape(-1, 3)}
    assert out <= src


def test_the_colour_cap_and_idempotence(tmp_path):
    first = _fix(FIXTURES / "seam_break_256.png", tmp_path, claimed={})
    assert first["colors"] <= 48 and first["changed"]
    again = pipeline.fix_file(first["out"], str(tmp_path), out_name="t", cell=(96, 96), palette_path=None,
                              max_colors=48, tile=True)[0]
    assert not again["changed"]


def test_a_locked_palette_is_not_applied_to_a_tile(tmp_path):
    pal = tmp_path / "p.hex"
    pal.write_text("262a24\n5a6450\n606860\n")
    entry = pipeline.fix_file(str(FIXTURES / "seamless_256.png"), str(tmp_path), out_name="t", cell=(96, 96),
                              palette_path=str(pal), max_colors=48, tile=True)[0]
    out = {tuple(c) for c in np.array(Image.open(entry["out"]).convert("RGB")).reshape(-1, 3)}
    assert not out <= {(0x26, 0x2a, 0x24), (0x5a, 0x64, 0x50), (0x60, 0x68, 0x60)}
    assert len(out) <= 48


def test_refusals_say_why(tmp_path):
    holed = np.full((128, 128, 4), 255, dtype=np.uint8)
    holed[0, 0, 3] = 0
    Image.fromarray(holed, "RGBA").save(tmp_path / "holed.png")
    assert "fully opaque" in _fix(tmp_path / "holed.png", tmp_path)["error"]
    Image.fromarray(np.full((100, 200, 4), 255, dtype=np.uint8), "RGBA").save(tmp_path / "wide.png")
    assert "never stretched or padded" in _fix(tmp_path / "wide.png", tmp_path)["error"]
    Image.fromarray(np.full((64, 64, 4), 255, dtype=np.uint8), "RGBA").save(tmp_path / "small.png")
    assert "only scales down" in _fix(tmp_path / "small.png", tmp_path)["error"]
