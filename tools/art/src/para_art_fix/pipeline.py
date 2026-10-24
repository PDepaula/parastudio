"""Orchestrates the chain (report §6.1 steps 2-7) for one input asset:
key (the whole file, so a sheet on a solid key background can be sliced) ->
content slice -> (per piece) grid recovery -> key-leak strip -> colour budget ->
palette lock -> orphan cleanup -> cell/pivot -> outline. Idempotent by construction: an output
is written only when its decoded pixels differ from what's already on disk
(engine report pain #13, applied here per §8.2), so a rerun on already-fixed
output that produces the same pixels changes 0 files. Within one run, every asset's input
path is claimed by that asset up front, and an output path is claimed by the
first asset that produces it; an output that would land on a path claimed
by another asset is reported as an error instead of overwriting it.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np
from PIL import Image

from . import cell as cell_mod
from . import cleanup as cleanup_mod
from . import fit as fit_mod
from . import grid as grid_mod
from . import keying
from . import keyleak
from . import outline as outline_mod
from . import palette as palette_mod
from . import quantize as quantize_mod
from . import slicing


def load_rgba(path: str) -> np.ndarray:
    return np.array(Image.open(path).convert("RGBA"))


def save_rgba(path: str, rgba: np.ndarray) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgba, "RGBA").save(path)


def images_equal(a: np.ndarray, b: np.ndarray) -> bool:
    return a.shape == b.shape and bool(np.array_equal(a, b))


def colour_budget(max_colors: int | None, palette_size: int, outline: bool) -> int | None:
    """The cap quantize.py snaps to before the palette lock. With a locked
    palette that already fits the cap every result colour is a palette member,
    so there is nothing to do; otherwise the lock maps the quantised colours
    many-to-one and can only lower the count. `--outline` may add one colour
    (the nudged-darker rim, or the palette member just below the floor), so one
    slot is held back for it and the finished sprite never exceeds the cap."""
    if max_colors is None or (palette_size and palette_size <= max_colors):
        return None
    return max(1, max_colors - 1) if outline else max_colors


def fix_piece(keyed: np.ndarray, *, cell: tuple[int, int] | None, pivot: str,
              palette_path: str | None, profile: str | None,
              outline: bool = False, max_colors: int | None = None,
              scale: float | None = None,
              bottom_margin: int = 0,
              key: np.ndarray | None = None) -> tuple[np.ndarray, dict]:
    info: dict = {}
    if scale is not None:  # --fit content: trim, then a uniform scale shared across the run
        trimmed, _bbox = cell_mod.trim(keyed)
        cols, rows = fit_mod.scaled_size((trimmed.shape[1], trimmed.shape[0]), scale)
        if cols > trimmed.shape[1] or rows > trimmed.shape[0]:
            raise grid_mod.GridError(
                f"figure is {trimmed.shape[1]}x{trimmed.shape[0]} px but would scale up to {cols}x{rows}; "
                "--fit content only scales down, so use a larger source or a smaller cell/--figure-height")
        room_h = cell[1] - (bottom_margin if pivot == "bottom" else 0) if cell else None
        if cell and (cols > cell[0] or rows > room_h):
            raise grid_mod.GridError(
                f"figure scales to {cols}x{rows}, bigger than the {cell[0]}x{room_h} room in the {cell[0]}x{cell[1]} cell")
        recovered, grid_info = grid_mod.reconstruct_exact(trimmed, cols, rows)
    else:
        target_cols, target_rows = cell if cell else (None, None)
        recovered, grid_info = grid_mod.recover_grid(keyed, target_cols, target_rows, profile=profile,
                                                      max_colors=max_colors, pivot=pivot)
    info["grid"] = grid_info

    recovered, leak_info = keyleak.strip_key_leaks(recovered, key)
    info["key_leak"] = leak_info

    palette = palette_mod.load_hex_palette(palette_path) if palette_path else None
    budget = colour_budget(max_colors, len(palette) if palette is not None else 0, outline)
    if budget is not None:
        recovered, quant_info = quantize_mod.quantize(recovered, budget)
        info["quantize"] = quant_info

    if palette_path:
        recovered, pal_info = palette_mod.remap(recovered, palette_path, reserve_outline=outline)
        info["palette"] = pal_info

    cleaned, clean_info = cleanup_mod.remove_orphans(recovered)
    info["cleanup"] = clean_info

    placed, cell_info = cell_mod.place_in_cell(cleaned, cell, pivot, bottom_margin)
    info["cell"] = cell_info

    if outline:
        placed, outline_info = outline_mod.apply_outline(
            placed, max_colors=max_colors,
            palette=palette)
        info["outline"] = outline_info

    return placed, info


def fix_tile(in_path: str, out_dir: str, *, out_name: str, cell: tuple[int, int],
             palette_path: str | None, max_colors: int | None,
             claimed: dict[str, str]) -> dict:
    """`--tile`: the whole image is one seamless, fully opaque ground tile. No
    keying (an opaque tile has no background; a corner-agreement guess would
    take the tile for one), no slicing, outline or content fit: the image is
    reconstructed onto exactly `cell` (a pixel-art-safe per-cell colour vote,
    never a blend) and snapped to the colour cap on its own. A tile is deliberately
    NOT locked to a game palette (see README "Ground tiles"): a locked palette fitted
    to sprites pulls a ground's hues off its realm. The
    source must be opaque and already the cell's aspect: a tile is neither
    stretched nor padded, because either would break its seam."""
    out_path = str(Path(out_dir) / f"{out_name}.png")
    entry: dict = {"file": in_path, "out": out_path, "key": "tile"}
    owner = claimed.setdefault(os.path.realpath(out_path), in_path)
    if owner != in_path:
        entry["error"] = f"output {out_path} collides with {owner}, another asset in this run"
        return entry
    src = load_rgba(in_path)
    h, w = src.shape[:2]
    cols, rows = cell
    translucent = int((src[..., 3] < 255).sum())
    if translucent:
        entry["error"] = (f"{Path(in_path).name} has {translucent} transparent or translucent px; a --tile source "
                          "must be fully opaque (regenerate it without a cut-out background)")
    elif w * rows != h * cols:
        entry["error"] = (f"{Path(in_path).name} is {w}x{h}, not the {cols}:{rows} aspect of the {cols}x{rows} cell; "
                          "a tile is never stretched or padded (that would break its seam), so crop it square-on first")
    elif w < cols:
        entry["error"] = (f"{Path(in_path).name} is {w}x{h}, smaller than the {cols}x{rows} cell; "
                          "--tile only scales down, so use a larger source")
    if "error" in entry:
        return entry

    # Already the cell's size: nothing to resample (and the colour vote is not
    # an identity on a gradient), so a rerun on fix's own output changes 0 px.
    fixed = src.copy() if (w, h) == (cols, rows) else grid_mod.reconstruct_exact(src, cols, rows)[0]
    if max_colors is not None:
        fixed, _quant = quantize_mod.quantize(fixed, max_colors)
    fixed[..., 3] = 255

    changed = True
    if Path(out_path).exists():
        try:
            changed = not images_equal(load_rgba(out_path), fixed)
        except Exception:
            changed = True
    if changed:
        save_rgba(out_path, fixed)
    colors = len(np.unique(fixed[..., :3].reshape(-1, 3), axis=0))
    entry.update({
        "changed": changed, "width": int(fixed.shape[1]), "height": int(fixed.shape[0]),
        "cell_w": cols, "cell_h": rows, "colors": int(colors), "semi_alpha_px": 0,
        "orphan_removed": 0, "grid_source": "tile", "keyed_px": 0, "key_leak_px": 0,
    })
    return entry


def content_sizes(in_path: str, *, key_hex: str | None = None,
                  key_border_only: bool = False) -> list[tuple[int, int]]:
    """The opaque-bbox (w, h) of the file's one piece, for fit.shared_scale."""
    keyed, _info = keying.key_to_alpha(load_rgba(in_path), override_hex=key_hex,
                                        border_only=key_border_only)
    trimmed, _bbox = cell_mod.trim(keyed)
    return [(int(trimmed.shape[1]), int(trimmed.shape[0]))]


def sheet_refusal(in_path: str, out_dir: str, out_name: str, cell: tuple[int, int] | None,
                  keyed: np.ndarray, key_info: dict) -> dict | None:
    """The error entry for a file that is a grid of `cell`s (`--cell` is one
    sprite's size, so fixing it would collapse the sheet), else None."""
    grid = slicing.multi_cell_grid(keyed, cell) if cell else None
    if not grid:
        return None
    return {"file": in_path, "out": str(Path(out_dir) / f"{out_name}.png"), "key": key_info["key"],
            "error": f"{Path(in_path).name} is {keyed.shape[1]}x{keyed.shape[0]}, a {grid[0]}x{grid[1]} grid of "
                     f"{cell[0]}x{cell[1]} cells; --cell is one sprite's size, so fixing it would collapse the "
                     "sheet into a single cell. Crop one cell per file, then fix each"}


def fix_file(in_path: str, out_dir: str, *, out_name: str, cell: tuple[int, int] | None = None,
             pivot: str = "bottom", palette_path: str | None = None, profile: str | None = None,
             key_hex: str | None = None, key_border_only: bool = False, outline: bool = False,
             max_colors: int | None = None, scale: float | None = None,
             bottom_margin: int = 0, claimed: dict[str, str] | None = None,
             tile: bool = False) -> list[dict]:
    claimed = {} if claimed is None else claimed
    if tile:
        if not cell:
            return [{"file": in_path, "out": str(Path(out_dir) / f"{out_name}.png"), "key": "tile",
                     "error": "--tile needs a cell"}]
        return [fix_tile(in_path, out_dir, out_name=out_name, cell=cell, palette_path=palette_path,
                         max_colors=max_colors, claimed=claimed)]
    keyed, key_info = keying.key_to_alpha(load_rgba(in_path), override_hex=key_hex,
                                           border_only=key_border_only)
    leak_key = None if key_border_only else keyleak.key_colour(key_info["key"])
    refusal = sheet_refusal(in_path, out_dir, out_name, cell, keyed, key_info)
    if refusal:
        return [refusal]
    pieces = slicing.slice_or_whole(keyed, known_cell=cell is not None or scale is not None)

    results = []
    for i, (_bbox, piece) in enumerate(pieces):
        name = out_name if len(pieces) == 1 else f"{out_name}_{i:02d}"
        out_path = str(Path(out_dir) / f"{name}.png")
        entry: dict = {"file": in_path, "out": out_path, "key": key_info["key"]}
        owner = claimed.setdefault(os.path.realpath(out_path), in_path)
        if owner != in_path:
            entry["error"] = f"output {out_path} collides with {owner}, another asset in this run"
            results.append(entry)
            continue
        try:
            fixed, info = fix_piece(piece, cell=cell, pivot=pivot, palette_path=palette_path,
                                     profile=profile, outline=outline,
                                     max_colors=max_colors, scale=scale,
                                     bottom_margin=bottom_margin, key=leak_key)
        except grid_mod.GridError as e:
            entry["error"] = str(e)
            results.append(entry)
            continue

        changed = True
        if Path(out_path).exists():
            try:
                changed = not images_equal(load_rgba(out_path), fixed)
            except Exception:
                changed = True
        if changed:
            save_rgba(out_path, fixed)

        opaque = fixed[..., 3] == 255
        colors = len(np.unique(fixed[opaque][:, :3].reshape(-1, 3), axis=0)) if opaque.any() else 0
        semi_alpha = int(((fixed[..., 3] > 0) & (fixed[..., 3] < 255)).sum())

        entry.update({
            "changed": changed,
            "width": int(fixed.shape[1]), "height": int(fixed.shape[0]),
            "cell_w": info["cell"]["cell_w"], "cell_h": info["cell"]["cell_h"],
            "colors": int(colors), "semi_alpha_px": semi_alpha,
            "orphan_removed": info["cleanup"]["removed"],
            "grid_source": info["grid"]["source"],
            "keyed_px": key_info["keyed_px"],
            "key_leak_px": info["key_leak"]["removed"] + info["key_leak"]["filled"],
        })
        if "palette" in info:
            entry["palette_off_px"] = info["palette"]["remapped_px"]
        if "outline" in info:
            entry["outline"] = info["outline"]["outline"]
        results.append(entry)
    return results
