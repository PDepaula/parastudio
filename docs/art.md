# Asset lint and fix (`para art`)

`para art lint` and `para art sheet` check pixel-art sheets without any image generation
or network calls (Nim, no ML). Build the CLI with `nimble build`, or run a command directly:

```sh
nim c -r tools/para/para.nim art lint path/to/sheets
nim c -r tools/para/para.nim art sheet path/to/sheets --out tmp/contact-sheet.png
```

Each `<name>.png` needs a `<name>.art.toml` sidecar declaring its cell size, style profile, optionally the key colour it was keyed from (for the `key` rule),
and any per-asset lint waivers (a game's own manifest of this eventually replaces hand
files here). `lint` checks against one of two built-in example profiles, `lowbit` and
`hibit` (once named `punchclub`, still accepted everywhere a profile is read) - defaults a game overrides once it writes its own `art/style.toml` (found by
walking up from each linted sheet to the repo root, nearest first; `--style PATH` overrides
it), whose `profile` key names the profile it overrides and whose optional
`palette` (a `.hex` file path, relative to the style.toml) turns on palette membership for every asset
(except `kind = "tile"` ground tiles), whatever profile its sidecar names. Each run prints a
`style:` line per profile saying where its values came from. See `tools/para/art/` for the
checks and `tests/fixtures/art/` for the twelve sheets the scout report linted (one a synthetic
stand-in; see its `CREDITS.md`). A sheet
whose declared cells don't tile it (even with a `grid` waiver) prints `unmeasured` for its
per-cell columns and fails `cells unmeasured`, never a silent pass.

`para art fix` cleans up one raw or degraded sprite at a time, and writes the `<name>.art.toml` sidecar for each output (cell, profile, pivot and key) so `lint` can follow it directly. Steps:
background key to hard alpha, pixel-grid recovery, palette lock (when `art/style.toml` sets
one; not for `--tile`), orphan-pixel cleanup, a fixed cell with a pivot, and content slicing. Needs
[uv](https://docs.astral.sh/uv/) on `PATH`; the pixel work runs as `uv run --locked
--project tools/art python -m para_art_fix` (`tools/art/`, dependencies pinned in `tools/art/uv.lock`,
no network calls once `uv sync` has run once). No image generation, no GPU.

```sh
nim c -r tools/para/para.nim art fix path/to/sprite.png --cell 64x64 --profile hibit --out tmp/art/fix
```

`--cell WxH` names the sprite's native size (skip it to let `pixel-art-fixer`/`unfake.py`
detect it, rejecting a result larger than the profile's biggest cell; a source of a different aspect is padded, never stretched - see [`tools/art/README.md`](../tools/art/README.md)); `fix` also snaps the sprite to the profile's colour cap; `--pivot` and `--profile`
take a sidecar's `pivot`/`profile` values and `--style` mirrors `lint`'s. `--key RRGGBB` always keys that colour (pixels that
are already transparent stay so). Without it, keying runs only on a flat key background: an input
that already has transparent pixels (a transparent PNG, a repo sprite, a rerun on fix's own output)
isn't re-keyed, and the four corners must agree on a colour; otherwise nothing is keyed and the
output's `key` column and help say to pass `--key RRGGBB` to force keying. Background is flood-filled from the image border
over pixels close (in RGB distance) to the key colour; an enclosed pocket is keyed too when it is
a connected region of at least 4 pixels whose mean colour is close to the key sampled from that
border fill, so a lone key-coloured pixel or a dark key-tinted outline stays sprite.
`--fit content` trims each source to its opaque bounding box and scales it to fill the `--cell` less `--margin PCT` (default 5, every side), bottom-aligned, with one scale shared by every file in the call so one character's poses keep their relative size; `--figure-height PX` pins the tallest figure instead (details: [`tools/art/README.md`](../tools/art/README.md)). `--outline` opts into a last step that recolours offending boundary pixels so the `hibit` `outline` rule passes (details and refusals: [`tools/art/README.md`](../tools/art/README.md)). Stray key-coloured pixels that survive keying are stripped, and lint's `key` rule fails any left when the sidecar names a key. `--key-border-only` skips pockets and that strip, for art that uses the key colour inside the sprite. `--tile --cell WxH` is the mode for one opaque seamless ground tile (no keying or outline; lint's `kind = "tile"` rules include a 3x3 `seamless` check; recipe in [`tools/art/README.md`](../tools/art/README.md), "Ground tiles"). An output that would overwrite another asset's input or output in the same run fails
instead. Outputs are only (re)written when their decoded pixels
differ from what's already there, so a rerun on already-fixed art changes 0 files. That
guarantee covers the default invocation; an explicit `--key` keys that colour again even on a rerun. See
`tests/test_art_fix_regression.nim` for the report's own §6.3 regression numbers (exact
native size, at most 1% of sprite pixels off, 0 pixels changed on a rerun), reproduced here
by degrading real repo sprites in code rather than committing new art.
