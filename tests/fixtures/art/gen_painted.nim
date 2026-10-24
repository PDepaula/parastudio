# Generates painted.png, a synthetic stand-in for the scout report's §7.2
# parakeet.png row (a third-party painted-style sheet with no license, so it
# can't be redistributed here). It is built to measure exactly like that row:
# 210x100 in three 70x100 frames, 2,626 opaque colours, 1,399 semi-alpha
# pixels, no empty cells, and all three frames touching the cell's top and
# bottom rows. Each frame is a black-outlined ellipse filled with a smooth
# many-colour wash and translucent glaze pixels - what a pixel profile rejects.
#
#   nim c -r --hints:off --outdir:tmp tests/fixtures/art/gen_painted.nim

import std/os
import stb_image/write as stbw

const
  w = 210
  h = 100
  cellW = 70
  washColors = 2625 ## plus the black outline: 2,626 opaque colours
  semiTarget = 1399

proc inBody(x, y: int): bool =
  if x < 0 or x >= w or y < 0 or y >= h: return false
  let c = x div cellW
  let rx = 24.0 + 2.0 * c.float
  let dx = (x.float + 0.5 - (c * cellW).float - 35.0) / rx
  let dy = (y.float + 0.5 - 50.0) / 50.0
  dx * dx + dy * dy <= 1.0

proc isOutline(x, y: int): bool =
  let x0 = (x div cellW) * cellW
  if y == 0 or y == h - 1 or x == x0 or x == x0 + cellW - 1: return true
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      if not inBody(x + dx, y + dy): return true

var pixels = newSeq[byte](w * h * 4)
var interior = 0
for y in 0 ..< h:
  for x in 0 ..< w:
    if inBody(x, y) and not isOutline(x, y): inc interior
let semiEvery = interior div semiTarget

var seen, semi, wash = 0
for y in 0 ..< h:
  for x in 0 ..< w:
    if not inBody(x, y): continue
    let i = (y * w + x) * 4
    if isOutline(x, y):
      pixels[i + 3] = 255
      continue
    if seen mod semiEvery == 0 and semi < semiTarget:
      pixels[i] = 220; pixels[i + 1] = 230; pixels[i + 2] = 240; pixels[i + 3] = 128
      inc semi
    else:
      let k = wash mod washColors
      pixels[i] = byte(40 + (k mod 50) * 4)
      pixels[i + 1] = byte(60 + (k div 50) * 3)
      pixels[i + 2] = 90
      pixels[i + 3] = 255
      inc wash
    inc seen

doAssert semi == semiTarget and wash >= washColors
let outPath = currentSourcePath.parentDir / "painted.png"
doAssert stbw.writePNG(outPath, w, h, stbw.RGBA, pixels)
echo "wrote ", outPath
