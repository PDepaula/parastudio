"""`python -m para_art_fix`: reads one JSON request from stdin, writes one
JSON result to stdout. `tools/para/art/fix.nim` is the only caller - it
resolves each asset's parameters from its flags and the nearest
art/style.toml (no `<name>.art.toml` sidecar), then invokes this once per
`para art fix` run with every asset's already-resolved parameters (§8.2:
"the agent sees only `para`"). Never touches the network: every dependency
is already installed by `uv sync --locked` before this runs.

Request shape:
    {"out_dir": "tmp/art/fix", "assets": [
        {"file": "path/in.png", "out_name": "skeleton",
         "cell": [64, 64] | null, "pivot": "bottom" | "none",
         "palette": "path/palette.hex" | null,
         "profile": "lowbit" | "hibit" | null,
         "key": "RRGGBB" | null, "key_border_only": bool,
         "outline": bool, "max_colors": int | null, "tile": bool}
    ], "fit": "whole" | "content" (default whole), "margin": pct (default 5),
       "figure_height": int | null}

"tile": true (needs "cell") treats the asset as one fully opaque seamless
ground tile: no keying, slicing, outline or content fit, the whole image is
reconstructed onto exactly "cell", snapped to "max_colors" and the palette -
see pipeline.fix_tile. Its result has "key": "tile" and "grid_source": "tile".

"fit": "content" (needs every asset's "cell") trims each asset to its opaque
bbox and scales it by one factor shared by the whole request - see fit.py.

Result shape:
    {"results": [{"file", "out", "changed", "width", "height", "cell_w",
                  "cell_h", "colors", "semi_alpha_px", "orphan_removed",
                  "grid_source", "key", "keyed_px", "key_leak_px",
                  "palette_off_px"?, "outline"?, "error"?}], "fit"?: {"scale", "figure_w", "figure_h"}}

"fit" (present only with "fit": "content") is the shared scale and the size the
largest figure came out at.

"outline" (present only when the asset's request set "outline": true) is
"ok" (no offenders, or offenders recoloured), "refuse:interior-ink" or
"flag:all-boundary", "refuse:edge-touch", "refuse:floor-at-black",
"refuse:color-cap" or "refuse:palette" - see para_art_fix.outline's module docstring.

"key_leak_px" counts the stray key-coloured pixels stripped from the output
after keying (removed, or filled from their neighbours when enclosed - see
keyleak.py); it is 0 when no key was found or "key_border_only" is set.

"key" is the RRGGBB colour keyed to alpha, "skip:alpha" (no --key and the
input already had transparency, so it wasn't keyed) or "skip:corners" (no --key and the
corners disagree, so there was no key background to find).

Exit codes: 0 every asset fixed with no error; 1 at least one asset is a
multi-cell sheet under "cell" (the run stops before anything is fixed or
written, and "results" holds only the refused sheets), or at least one
asset's grid recovery was rejected, or its output path collides with another asset's
input or output in the same run (a real finding, not a usage error); 2 the request
itself couldn't be read or run (bad JSON, missing file, an exception before
any per-asset result could be produced).
"""

from __future__ import annotations

import json
import logging
import os
import sys

from . import fit as fit_mod
from . import keying, pipeline

# fix.nim reads stdout as one JSON document; keep stderr to real errors, not
# unfake's/pixelfixer's per-step INFO logging (also avoids piling more into
# the stderr pipe than fix.nim, which reads stdout to completion first,
# drains promptly).
logging.basicConfig(level=logging.WARNING)


def main(argv: list[str] | None = None) -> int:
    try:
        request = json.loads(sys.stdin.read())
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"invalid JSON request: {e}"}))
        return 2

    try:
        out_dir = request["out_dir"]
        assets = request["assets"]
    except (KeyError, TypeError) as e:
        print(json.dumps({"error": f"request missing {e}"}))
        return 2

    results: list[dict] = []
    fit_info = None
    scale = None
    bottom_margin = 0
    try:
        refused = []
        for a in assets:
            if not a.get("cell") or a.get("tile"):
                continue
            keyed, key_info = keying.key_to_alpha(
                pipeline.load_rgba(a["file"]), override_hex=a.get("key"),
                border_only=bool(a.get("key_border_only")))
            refusal = pipeline.sheet_refusal(a["file"], out_dir, a.get("out_name") or a["file"],
                                             tuple(a["cell"]), keyed, key_info)
            if refusal:
                refused.append(refusal)
        if refused:
            print(json.dumps({"results": refused}))
            return 1
        if request.get("fit") == "content":
            sizes = [s for a in assets for s in pipeline.content_sizes(
                a["file"], key_hex=a.get("key"), key_border_only=bool(a.get("key_border_only")))]
            cell = tuple(assets[0]["cell"])
            margin_pct = float(request.get("margin", fit_mod.DEFAULT_MARGIN_PCT))
            scale = fit_mod.shared_scale(sizes, cell, margin_pct, request.get("figure_height"))
            bottom_margin = round(cell[1] * margin_pct / 100)
            fw, fh = fit_mod.scaled_size(max(sizes, key=lambda s: s[1]), scale)
            fit_info = {"scale": round(scale, 4), "figure_w": fw, "figure_h": fh}
        claimed = {os.path.realpath(a["file"]): a["file"] for a in assets}
        for asset in assets:
            cell = tuple(asset["cell"]) if asset.get("cell") else None
            results.extend(pipeline.fix_file(
                asset["file"], out_dir,
                out_name=asset.get("out_name") or asset["file"],
                cell=cell,
                pivot=asset.get("pivot") or "bottom",
                palette_path=asset.get("palette"),
                profile=asset.get("profile"),
                key_hex=asset.get("key"),
                key_border_only=bool(asset.get("key_border_only")),
                outline=bool(asset.get("outline")),
                max_colors=asset.get("max_colors"),
                scale=scale,
                bottom_margin=bottom_margin,
                claimed=claimed,
                tile=bool(asset.get("tile")),
            ))
    except fit_mod.FitError as e:
        print(json.dumps({"error": str(e)}))
        return 2
    except Exception as e:  # an asset outside the per-file error path (bad file, IO)
        print(json.dumps({"error": str(e), "results": results}))
        return 2

    response: dict = {"results": results}
    if fit_info:
        response["fit"] = fit_info
    print(json.dumps(response))
    return 1 if any("error" in r for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
