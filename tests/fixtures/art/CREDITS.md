# Fixture credits

The twelve sprite sheets the asset pipeline report's §7.2 lints, as test fixtures for
`para art lint`/`sheet`: eleven copied unchanged from
[parasurvivors](https://github.com/PDepaula/parasurvivors) (`src/assets/`), plus a
synthetic stand-in for the twelfth. Among them: `koalio.png`'s hand-offset grid,
`ghost.png`'s translucency waiver, `gino.png`/`gino_attack.png`'s bottom-edge pivot versus
real side clipping, and `painted.png`'s painted-style colour count. See parasurvivors'
`src/assets/CREDITS.md` for full upstream attribution of the copied sheets.

- `zombie.png`, `skeleton.png`: Liberated Pixel Cup character art (`body/bodies/zombie`,
  `body/bodies/skeleton`), composed by parasurvivors' asset script. CC-BY-SA 3.0 (composed
  file); per-layer credits in parasurvivors' `CREDITS-lpc.csv`.
- `ghost.png`: `zombie.png` bleached and made translucent by parasurvivors. Same
  licensing as `zombie.png`.
- `otto.png`, `otto_attack.png` (spear), `imma.png` (magic), `lina_attack.png` (war axe),
  `gino.png`, `gino_attack.png` (bow): Liberated Pixel Cup character art, composed by
  parasurvivors' asset script. CC-BY-SA 3.0 (composed files); per-layer credits in
  parasurvivors' `CREDITS-lpc.csv`.
- `bat.png`: `sprites/monsters/bat.png` from the
  [LPC Base Assets](https://opengameart.org/content/liberated-pixel-cup-lpc-base-assets-sprites-map-tiles)
  by Charles Sanchez (CharlesGabriel), CC-BY-SA 3.0 / GPL 3.0 / OGA-BY 3.0.
- `koalio.png`: the Super Koalio character from the
  [libgdx](https://github.com/libgdx/libgdx) test suite, Apache License 2.0, fetched via
  Zach Oakes' port in [paranim_examples](https://github.com/paranim/paranim_examples).
- `painted.png`: synthetic, generated for paraloop by `gen_painted.nim` in this directory.
  It stands in for §7.2's `parakeet.png` (Zach Oakes' [parakeet](https://github.com/paranim/parakeet)
  demo frames, whose repository carries no license file, so they are not redistributed
  here) and measures exactly like that row: 210x100 in 70x100 cells, 2,626 colours,
  1,399 semi-alpha pixels, 3 edge-touching cells. Same license as paraloop.

## `batch1/`

Five GameLab-generated sprites (a player pose, a wolf, three spirit stones) on a flat
`#00FF00` key background, from art batch 1, kept as small regression
inputs for `para art fix`: `tools/art/tests/test_fix_batch1.py` and
`tests/test_art_fix_batch1.nim`. Project-owned generated art, not third-party.

## `batch2/`

Three GameLab-generated sprites (`rogue_cultivator`, `corpse_puppet`, `core_medium`) on a
flat `#00FF00` key background, from art batch 2, kept as regression inputs
for outlining and key-leak stripping in `para art fix`: `tests/test_art_fix_dark.nim` and
`tools/art/tests/test_keyleak.py`. Project-owned generated art, not third-party.
