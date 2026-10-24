"""Regenerates the two committed 256x256 source tiles (stdlib + numpy + PIL):

    cd tests/fixtures/art/tile && uv run --project ../../../../tools/art python gen_tiles.py

seamless_256.png   opaque, full bleed, 4x4 slabs with grout, periodic in both
                   axes so a 3x3 tiling has no seam. All four corners are the
                   same grout colour: the input that made `fix` without --tile
                   take the whole tile for a flat key background and write a
                   blank cell (tools/art/README.md, "Ground tiles").
seam_break_256.png the same slabs with a left-to-right brightness ramp laid
                   over them: opaque, but the right edge and the left edge are
                   far apart, so it must fail lint's `seamless` rule.
"""
import numpy as np
from PIL import Image

N, SLAB, GROUT = 256, 64, 6
TONES = [(96, 104, 92), (88, 98, 84), (104, 108, 96), (80, 90, 80), (92, 110, 90), (100, 100, 88)]
GROUT_RGB = (38, 42, 36)
SPECKLE_RGB = (70, 78, 66)


def slabs() -> np.ndarray:
    img = np.zeros((N, N, 3), dtype=np.uint8)
    for sy in range(N // SLAB):
        for sx in range(N // SLAB):
            img[sy * SLAB:(sy + 1) * SLAB, sx * SLAB:(sx + 1) * SLAB] = TONES[(sx * 3 + sy * 5) % len(TONES)]
    ys, xs = np.mgrid[0:N, 0:N]
    # a deterministic speckle whose pattern repeats every SLAB px, so it wraps
    speckle = ((xs % SLAB) * 7 + (ys % SLAB) * 13) % 37 == 0
    img[speckle] = SPECKLE_RGB
    # grout centred on every slab boundary, wrapping across the image edge
    grout = (((xs + GROUT // 2) % SLAB) < GROUT) | (((ys + GROUT // 2) % SLAB) < GROUT)
    img[grout] = GROUT_RGB
    return img


def main() -> None:
    base = slabs()
    Image.fromarray(base, "RGB").convert("RGBA").save("seamless_256.png")
    ramp = (np.arange(N, dtype=np.float64) / (N - 1) * 120).astype(np.int32)[None, :, None]
    broken = np.clip(base.astype(np.int32) + ramp, 0, 255).astype(np.uint8)
    Image.fromarray(broken, "RGB").convert("RGBA").save("seam_break_256.png")


if __name__ == "__main__":
    main()
