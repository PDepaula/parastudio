# tools/art

The Python half of `para art fix` (asset pipeline report §6.1, §8.2, §9 row A2):
background key, pixel-grid recovery, colour budget, palette lock, orphan cleanup,
cell/pivot, content slicing. No generation, no network calls at run time, no GPU - the ML
here is the offline `pixel-art-fixer` grid detector, not a generator.

`tools/para/art/fix.nim` is the only caller. It resolves each asset's parameters
from its flags (`--cell`, `--profile`, ...) and the nearest `art/style.toml` (found
the same way `para art lint` finds it; `fix` takes no parameters from a `<name>.art.toml` sidecar; it only writes one per output, see the last section),
then runs

```sh
uv run --locked --project tools/art python -m para_art_fix
```

with a JSON request on stdin and reads one JSON result from stdout. This
package never reads a sidecar or style.toml itself.

## Dependencies

Pinned in `uv.lock`. `pixelfixer` (MIT, Retro-Diffusion/pixel-art-fixer) is a
git dependency pinned to an exact commit - it isn't published to PyPI.
`unfake` is the fallback grid recovery when `pixelfixer`'s detection is
implausible for the target style profile.

```sh
uv sync --locked --project tools/art       # installs from the lockfile, fails on drift
uv run --locked --project tools/art pytest # unit tests for the individual steps
```

## `--cell` and the colour cap

`--cell WxH` scales uniformly: a source whose aspect differs from the cell's is
padded with transparency to that aspect first (bottom-aligned for the default
`--pivot bottom`, centred for `none`), then reconstructed, so a 256x256 figure
in a 96x144 cell is x0.375 on both axes with the spare 48 rows above it. It
never stretches and never crops. That fits the whole source canvas, so a
GameLab source whose figure only fills part of it (a 256x256 canvas holds a
~156x239 figure) comes out small; use `--fit content` below.

`--cell` is also one sprite's size. A file that is a whole multiple of it, with separate content in two or more cells and nothing crossing a cell line (a growth strip, a walk-cycle sheet), is refused with exit 1 instead of being collapsed into one cell; crop one cell per file first. One sprite saved at 2x or 4x the cell (its body crosses the cell lines) is still fixed.

## `--fit content` (poses of one character share one scale)

`--fit content --cell WxH` (the default is `--fit whole`, above) trims each
key-removed source to its opaque bounding box, scales it uniformly to fit the
cell less a margin, and places it centred and bottom-aligned (`--pivot none`:
centred). The margin is `--margin PCT` of the cell on every side, default 5, so
the figure fills 90% of the tighter axis; it also keeps `PCT` of the cell
height empty under the feet, so nothing touches the cell edge and `--outline`
(whose guard refuses edge-touching art) still runs. `--cell` is required.

One scale serves the whole call, so poses stay the same size relative to each
other instead of each filling its own cell: it is the scale that fits the
*largest* figure (tightest axis wins) into the margin box, and every file in
that `para art fix` call gets it. Fix one character's poses together:

```sh
para art fix player_down.png player_up.png player_left.png player_right.png \
  --cell 96x144 --fit content --key 00FF00 --outline --out art/player
```

`--figure-height PX` instead pins the *tallest* figure of the call to PX rows
(everything else follows at the same scale), for sets fixed in separate calls
that must still agree. The first line of output reports the scale and the
size the tallest figure came out at (`fit: content, scale 0.5268, tallest
figure 83x130 in a 96x144 cell`). A figure that would not fit (a too-big
`--figure-height`) is a normal per-asset finding, and so is a source smaller
than its target: `--fit content` only scales down. Files of different cells
(a wolf in 96x96, a player in 96x144) go in separate calls, each with its own
shared scale.

`fix` enforces the profile's `max_colors` itself (`quantize.py`, k-means in
Oklab, seeded): an opaque sprite over the cap is snapped to at most that many
colours, one under it is left alone. With `--outline` one colour is held back
for the rim; with a locked `art/palette.hex` the quantise runs first and the
palette lock can only lower the count, so `para art lint`'s `colors` rule agrees
with `fix` for every profile (lowbit's 16 included).

## `--outline`

An opt-in, last-in-the-pipeline step (`para_art_fix/outline.py`) that closes
`hibit`'s `outline` rule by recolouring only the boundary pixels
`tools/para/art/lint.nim::analyzeAsset`'s own rule flags, to the sprite's own
existing darkest interior colour (with a locked palette: per pixel, the palette member
nearest its own colour among those strictly darker than that floor; and the palette
lock itself keeps the palette's darkest colour for dark boundary pixels, luma 20 or
less, and away from interior pixels, so a one-rim-colour palette cannot collapse a
sprite's shading onto its rim) - never a new colour outside
the sprite or palette, never a bigger silhouette. It refuses (reports a normal fix finding, same shape as the
existing `skip:corners`/`skip:alpha` hints) with `refuse:interior-ink` when the
recoloured rim would not read against the body beside it: after the recolour, each
boundary pixel is compared (luma, 0-255) with the mean of the interior pixels in
its 8-neighbourhood, and when the median of those contrasts is under
`MIN_RIM_CONTRAST` (16) the rim is the same near-black as the body it is meant to
separate from, so "fix" would be "redraw". The test is relative, not "is there
dark ink anywhere": a dark robe or a dark cracked-magma core outlines as long as
its edge has lighter body next to it (the GameLab batch's `rogue_cultivator`,
`corpse_puppet` and `core_medium` measure a median 21-37, a flat near-black body
under 10), and a big dark mass away from the edge no longer blocks anything. The
lint rule itself is unchanged (boundary strictly darker than the darkest interior
pixel), so a sprite with literal black inside still ends in `refuse:floor-at-black`:
nothing is darker. It flags (same
shape, no fix applied) rather than blindly recolouring when nearly the whole
boundary would change at a cell too small for that to read as an outline
instead of damage (cells over 32 px in a dimension and under 48; an icon-sized cell,
32x32 or less, is nearly all boundary by nature and applies). Other refusals: `refuse:edge-touch`, `refuse:floor-at-black`,
`refuse:color-cap` and `refuse:palette`. `tests/fixtures/art/outline/cases.json` plus
`tests/test_art_outline_fixture.nim` and `tools/art/tests/test_outline.py`
keep this module's classification in sync with `lint.nim`'s own rule.

`tests/fixtures/art/outline/demo_minority_offender.png` is a small synthetic
sprite built the same way as the art-outline-test report's lightning
telegraph/strike samples (a mostly-dark edge with a handful of offending
boundary pixels and one true floor pixel) - without `--outline`, `fix`
leaves it failing lint's `outline` rule; with it, the offenders get
recoloured to the sprite's own darkest colour and it passes:

```sh
$ ./tmp/para art fix tests/fixtures/art/outline/demo_minority_offender.png \
    --cell 24x24 --profile hibit --outline --out tmp/art/fix
fixed[1]{file,out,changed,size,cell,colors,semi_alpha_px,orphan,grid,key}:
  tests/fixtures/art/outline/demo_minority_offender.png,tmp/art/fix/demo_minority_offender.png,true,24x24,24x24,5,0,0,forced,"skip:alpha"
fix: 1 written, 0 unchanged, 0 failed
sidecars: 1 written, 0 unchanged
help[2]:
  Run `para art lint tmp/art/fix` to check the results
  ...: it already has transparency, so no background was keyed; pass --key RRGGBB to force keying

$ cat tmp/art/fix/demo_minority_offender.art.toml   # fix wrote this; no hand-written sidecar needed
cell_w = 24
cell_h = 24
profile = "hibit"
pivot = "bottom"
$ ./tmp/para art lint tmp/art/fix/demo_minority_offender.png
sheets[1]{file,size,cell,grid,colors,semi_alpha_px,empty_cells,edge_touch_cells,outline,palette}:
  tmp/art/fix/demo_minority_offender.png,24x24,24x24,ok,5,0,0,0,ok,-
lint: 0 of 1 failed
```

Known limitations: a single isolated interior pixel sitting at the luma
minimum can set the floor for the whole cell and push an otherwise-fine asset
onto the flag or refusal path rather than being auto-fixed - this is the
safe, intended outcome (not a bug), and such an asset should be cleaned up by
hand or regenerated rather than waiting for this step to guess which stray
pixels are noise.

Run the same `fix` without `--outline` and the fixed output still fails
lint with `outline` in its `help[]` reasons - `--outline` is the only
difference.

## Ground tiles (`--tile`)

A seamless, full-bleed ground tile is not a sprite: it is opaque (no background
to key, nothing to outline), it touches every edge of its cell, and the
property that matters is that it wraps. `--tile` is `fix`'s mode for it, and the
sidecar's `kind = "tile"` (written by `fix`) is lint's.

Why a flag plus a sidecar key rather than inferring it: the corner-agreement
guess that finds a key background reads a tile as one (a flat or grout-cornered
tile has four agreeing corners and was keyed away to a blank cell), so tile-ness
has to be stated by the person running `fix`, and lint can only learn it from
the sidecar, which `fix` already writes beside every output.

Recipe:

1. Generate at **256x256** (the cell is 96x96; a larger power-of-two source
   keeps the downscale ratio mild), the tool's seamless/texture option if it has
   one, Pixel Art on, 48 colours, 3/4 top-down OFF, no cut-out or chroma-key
   background (the source must be fully opaque and square-on).
2. Fix:

   ```sh
   para art fix ground_qi_condensation.png --tile --cell 96x96 --out games/<game>/assets
   ```

   The whole image is reconstructed onto exactly `--cell` with a per-cell colour
   vote (never a blend, like every other `fix` path), snapped to the profile's
   colour cap on its own, and stays fully opaque. A tile is **not** locked to the
   game palette, even when an `art/style.toml` names one (see below). No keying, slicing, orphan cleanup, outline or content
   fit run. `--tile` needs `--cell` and refuses `--key`, `--key-border-only`,
   `--outline`, `--pivot`, `--fit content`, `--margin` and `--figure-height`
   (usage error, exit 2). A source that has any transparent pixel, is not the
   cell's aspect (a tile is never stretched or padded: either breaks the seam),
   or is smaller than the cell is refused with a message (exit 1). A source
   already at the cell size is not resampled, so a rerun on `fix`'s own output
   changes 0 files.
3. Lint:

   ```sh
   para art lint games/<game>/assets/ground_qi_condensation.png
   ```

   A tile is held to its own rules: exactly one cell (`size`), fully opaque
   (`alpha`), the colour cap (`colors`), and `seamless`.
   The sprite rules that a full-bleed tile cannot meet (`edge`, `outline`,
   `orphan`, `key`) are not applied; no waiver is needed. The per-cell columns
   print `-`, and a `tile:` line reports the measure.

   Why a tile is outside the palette lock: a game's palette is fitted to its
   sprites, and snapping a ground to the nearest of those entries pulls its hues
   off the realm it stands for (one game's moss-green stone came out grey-brown
   and its jade lavender-grey). So neither `fix --tile` nor lint's tile kind applies
   the palette; each tile is quantised on its own to at most the profile's cap, and
   a tile-kind sidecar is how lint knows. Keep a ground low-contrast on purpose:
   mobs and pickups draw on top of it.

The seam check tiles the image 3x3 in effect: every seam of a 3x3 tiling joins
the last column to the first, or the last row to the first, so lint measures
those two wrap pairs (`seam_x`, `seam_y`). Each is the mean RGB (Euclidean,
0..441.7) distance across the wrap pair minus the 75th percentile of the same
mean across the tile's own inside column (row) pairs, clamped at 0: a seam is
judged against a typical cut through the tile, so a seamless texture scores 0 (or
close) and a tile that was never made to wrap, whose seam is far worse than the
typical cut, does not. The baseline is a percentile and not the worst inside
pair so that one strong full-height line (a grout line, a crack) cannot hide a
hard seam. The limitation: a texture that is smooth except for a few strong
lines scores its wrap pair in full when the wrap lands on one of them, so that
rare tile fails `seamless` even though it wraps; regenerate it, or waive the rule
with a reason. The tile fails `seamless` when the worse of the two exceeds
`seamMax` = 16 (`tools/para/art/lint.nim`; a seamless tile scores 0, the
`seam_break` fixture scores about 200). It is a measure, not a promise: a
generator cannot guarantee a seam, so a failing tile is regenerated, or the rule
is waived in the sidecar with a reason like any other rule.

Separately from tiles, lint now fails `blank` for any output with no visible
pixel at all, so a fix that wrote an empty cell can no longer print `0 of 1
failed`.

Fixtures: `tests/fixtures/art/tile/` (`gen_tiles.py` regenerates them); tests:
`tools/art/tests/test_tile.py` and `tests/test_art_tile.nim`.

## Stray key pixels and the sidecar

After keying, `fix` strips every opaque pixel within 40 (RGB distance,
`keyleak.py`'s `KEY_LEAK_DIST`) of the key colour: keying keeps a key-coloured
pocket under 4 pixels on purpose (an eye, a highlight), and grid recovery can leave
one hanging off the silhouette, and either shows as a bright dot on any ground.
One that touches transparency (or the image edge) goes transparent, repeated
until the clump is gone; one fully enclosed by sprite takes the colour of the
nearest sprite pixel instead of leaving a hole. The count comes back as a `help[]`
line (`stripped N stray key-coloured pixel(s)`). It needs a known key (`--key`, or
the agreed corner colour) and is skipped with `--key-border-only`, for art that
uses the key colour on purpose.

`fix` writes `<name>.art.toml` beside every output it writes: `cell_w`/`cell_h`
(the cell the sprite was placed in), `profile` and `pivot` as fixed, and `key`
when keying had a colour (not with `--key-border-only`), so `fix` then `lint`
needs no hand-written sidecar. An existing sidecar keeps its `[[waiver]]`s (and its `key` when a rerun on
already-keyed output skips keying), is left untouched when it already says the same, and a malformed one is reported
and left as is. With a `key` in the sidecar, `para art lint` fails the `key` rule
when any visible pixel is within 40 of it (`keyLeakDist` in `lint.nim`, kept
equal to `KEY_LEAK_DIST`); a sidecar without `key` is not checked, since lint
cannot guess a background.
