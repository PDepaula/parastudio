# Third-party notices

paraloop itself is MIT-licensed (see `LICENSE`). This file lists what else ships
in the repository or is pulled in to build it, and under which terms. Nothing here
changes the licence of paraloop's own code.

## Nim dependencies

Installed by nimble from `nimble.lock` (versions as pinned there); none are copied
into this repository. Licences are the `license` field of each package's `.nimble`
file.

| Package | Version | Licence |
|---------|---------|---------|
| [paranim](https://github.com/paranim/paranim) | 0.12.0 | Public Domain |
| [pararules](https://github.com/paranim/pararules) | 1.4.0 | Public Domain |
| [paratext](https://github.com/paranim/paratext) | 0.13.0 | Public Domain |
| [parasound](https://github.com/paranim/parasound) | 1.0.0 | Public Domain |
| paramidi, paramidi_soundfonts (pulled in by parasound) | 0.7.0, 0.2.0 | Public Domain |
| [stb_image](https://gitlab.com/define-private-public/stb_image-Nim) | 2.5 | Unlicense (Public Domain) |
| [nimgl](https://github.com/nimgl/nimgl) | 1.3.2 | MIT |
| [glm](https://github.com/stavenko/nim-glm) | 1.1.1 | MIT |
| [Nim](https://github.com/nim-lang/Nim) (compiler) | 2.2.10 | MIT |

`patches/paranim/` and `patches/pararules/` hold diffs that are applied to copies of
paranim and pararules at build time (`patchFile` in `config.nims`); the patched
files stay under those packages' Public Domain terms.

## Python tools (`tools/art`)

The asset-fix helper runs in a `uv` environment pinned by `tools/art/uv.lock`; nothing
is vendored. Direct dependencies: numpy (BSD-3-Clause), scipy (BSD-3-Clause),
opencv-python-headless (Apache-2.0), Pillow (HPND), pixelfixer (MIT), unfake (MIT), and
pytest (MIT, development only).

## Toolchain

Emscripten (for the browser build) and Chromium (for `para web smoke`) are installed by
the user and are not redistributed here.

## Bundled fonts

| File | Licence | Licence text |
|------|---------|--------------|
| `src/paraloop/assets/PressStart2P-Regular.ttf` (Press Start 2P, Copyright 2012 The Press Start 2P Project Authors) | SIL Open Font License 1.1 | `src/paraloop/assets/PressStart2P-OFL.txt` |
| `src/paraloop/assets/Roboto-Regular.ttf` (Roboto 2.137, Copyright 2011 Google Inc.) | Apache License 2.0 | `src/paraloop/assets/Roboto-LICENSE.txt` |

The Roboto file names the Apache 2.0 licence in its own name table, which is why that
text is the one included.

## Test fixtures

Images under `tests/fixtures/art/`; the full per-file credits are in
`tests/fixtures/art/CREDITS.md`. They are test inputs for `para art`, not part of any
game or of the library.

- `zombie.png`, `skeleton.png`, `ghost.png`, `otto.png`, `otto_attack.png`, `imma.png`,
  `lina_attack.png`, `gino.png`, `gino_attack.png`: character sheets composed from
  [Liberated Pixel Cup](https://lpc.opengameart.org/) art. **CC-BY-SA 3.0**; the per-layer
  credits live in [parasurvivors](https://github.com/PDepaula/parasurvivors)'
  `CREDITS-lpc.csv`. Anyone redistributing these files must keep the attribution and
  share any modified copy under the same licence. They are only test fixtures: the
  licence applies to the images, not to paraloop's code.
- `bat.png`: from the [LPC Base Assets](https://opengameart.org/content/liberated-pixel-cup-lpc-base-assets-sprites-map-tiles)
  by Charles Sanchez (CharlesGabriel), CC-BY-SA 3.0 / GPL 3.0 / OGA-BY 3.0.
- `koalio.png`: the Super Koalio character from the
  [libgdx](https://github.com/libgdx/libgdx) test suite, Apache License 2.0.
- `painted.png`, `tile/`, `outline/`: small images made for paraloop's tests (see
  `gen_painted.nim` and `tile/gen_tiles.py`); MIT like the rest of the code.
- `batch1/`, `batch2/`: AI-generated sprites, see below.

## AI-generated art

Some of the pixel art in this project was produced with AI image tools: GameLab,
Codex (OpenAI) and Gemini (Google), then cleaned up with `para art fix`. In this
repository that is the sprites in `tests/fixtures/art/batch1/` and `batch2/` (GameLab)
and the art of the games kept under `games/`. This is a provenance note only; it makes
no claim about copyright in generated images.

## Punch Club

No file from Punch Club is included. The `hibit` style profile of `para art` (formerly
named `punchclub`, still accepted as an alias) only borrows a look: a colour budget, a
dark outline rule and an orphan-pixel limit.
