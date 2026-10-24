# End-to-end `para art fix --outline` through the real
# `uv run --project tools/art` subprocess (issue #41) - the Nim-side
# counterpart to tools/art/tests/test_outline.py's unit coverage of
# `para_art_fix.outline` itself. These three fixtures are the same shapes
# that file's `_minority_offender_sprite`/`_heavy_interior_ink_sprite`/
# `_all_boundary_small_cell_sprite` build, just written here in Nim so this
# suite can drive the real CLI; `--key ff00ff` (a colour absent from every
# fixture below) keeps the keying step a no-op so the fixture's pixels
# reach the outline step unchanged, the same way the fully-opaque Python
# arrays do.

import unittest
import std/[os, strutils]
import stb_image/write as stbw
import tools/para/artcmd

let testTmp = getTempDir() / ("paraloop_fix_outlinetest_" & $getCurrentProcessId())

const margin = 2
  ## A transparent border around every shape below, so the opaque content
  ## never touches the canvas edge - lint's "edge" rule is about accidental
  ## clipping, a different question from this suite's, and every fixture
  ## here would otherwise trip it just by filling its own canvas corner to
  ## corner.

proc newCanvas(shapeSize: int): seq[byte] =
  let full = shapeSize + margin * 2
  newSeq[byte](full * full * 4)

proc canvasSize(shapeSize: int): int = shapeSize + margin * 2

proc fillRect(buf: var seq[byte], fullSize, x0, y0, x1, y1: int, r, g, b: byte) =
  for y in y0 + margin ..< y1 + margin:
    for x in x0 + margin ..< x1 + margin:
      let i = (y * fullSize + x) * 4
      buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = 255

proc setPx(buf: var seq[byte], fullSize, x, y: int, r, g, b: byte) =
  let i = ((y + margin) * fullSize + (x + margin)) * 4
  buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = 255

proc minorityOffenderSprite(): seq[byte] =
  ## 20x20 shape, fully opaque: a mostly-dark boundary ring with 3 bright
  ## offenders, a two-shade interior, and a single darkest (floor) pixel.
  const size = 20
  let full = canvasSize(size)
  result = newCanvas(size)
  result.fillRect(full, 0, 0, size, size, 60, 60, 60) # boundary default: dark, passes
  result.fillRect(full, 1, 1, size - 1, size - 1, 150, 150, 150) # interior shade 1
  result.fillRect(full, 5, 5, 15, 15, 130, 130, 130) # interior shade 2
  result.setPx(full, 10, 10, 90, 90, 90) # the floor
  result.setPx(full, 1, 0, 200, 200, 200) # boundary offender 1
  result.setPx(full, 2, 0, 200, 200, 200) # boundary offender 2
  result.setPx(full, size - 1, size - 1, 200, 200, 200) # boundary offender 3

proc nearBlackBodySprite(): seq[byte] =
  ## 10x10 shape, fully opaque, a near-black body (luma 14) with 5 slightly
  ## darker interior pixels (luma 9): a rim in the floor colour would sit 6
  ## luma units under the body beside it, so no outline could be told apart.
  const size = 10
  let full = canvasSize(size)
  result = newCanvas(size)
  result.fillRect(full, 0, 0, size, size, 14, 14, 14)
  for (x, y) in [(4, 4), (4, 5), (5, 4), (5, 5), (6, 6)]:
    result.setPx(full, x, y, 9, 9, 9)

proc allBoundarySprite(size: int): seq[byte] =
  ## size x size shape, fully opaque, one shade, with a single
  ## much-darker interior pixel setting the floor so every boundary pixel
  ## offends.
  let full = canvasSize(size)
  result = newCanvas(size)
  result.fillRect(full, 0, 0, size, size, 50, 50, 50)
  let mid = size div 2
  result.setPx(full, mid, mid, 5, 5, 5)

proc writeSprite(path: string, shapeSize: int, px: seq[byte]) =
  let full = canvasSize(shapeSize)
  doAssert stbw.writePNG(path, full, full, stbw.RGBA, px)

suite "para art fix --outline: end to end through the real uv subprocess (issue #41)":
  test "a minority-offender edge is recoloured, and the asset then passes lint's outline rule":
    let dir = testTmp / "outline_minority"
    createDir(dir)
    let png = dir / "sprite.png"
    writeSprite(png, 20, minorityOffenderSprite())
    let outDir = testTmp / "outline_minority_out"
    let r = runArt(@["fix", png, "--cell", "24x24", "--profile", "hibit",
                      "--key", "ff00ff", "--outline", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check "refuse:" notin r.output
    check "flag:" notin r.output

    let lintResult = runArt(@["lint", outDir / "sprite.png"])
    checkpoint lintResult.output
    check lintResult.code == 0
    removeDir(dir)
    removeDir(outDir)

  test "a rim that would melt into a near-black body is refused: the finding is reported, the asset is untouched":
    let dir = testTmp / "outline_refuse"
    createDir(dir)
    let png = dir / "sprite.png"
    writeSprite(png, 10, nearBlackBodySprite())
    let outDir = testTmp / "outline_refuse_out"
    let r = runArt(@["fix", png, "--cell", "14x14", "--profile", "hibit",
                      "--key", "ff00ff", "--outline", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains(png & ": the body along its edge is as dark as the outline would be")

    let lintResult = runArt(@["lint", outDir / "sprite.png"])
    checkpoint lintResult.output
    check lintResult.code == 1
    check lintResult.output.contains(outDir / "sprite.png" & ": outline")
    removeDir(dir)
    removeDir(outDir)

  test "an all-boundary offender at a small cell is flagged, not blindly recoloured":
    let dir = testTmp / "outline_flag"
    createDir(dir)
    let png = dir / "sprite.png"
    writeSprite(png, 40, allBoundarySprite(40))
    let outDir = testTmp / "outline_flag_out"
    let r = runArt(@["fix", png, "--cell", "44x44", "--profile", "hibit",
                      "--key", "ff00ff", "--outline", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains(png & ": nearly its whole boundary")

    let lintResult = runArt(@["lint", outDir / "sprite.png"])
    checkpoint lintResult.output
    check lintResult.code == 1
    check lintResult.output.contains(outDir / "sprite.png" & ": outline")
    removeDir(dir)
    removeDir(outDir)

  test "the same all-boundary shape at a large enough cell auto-applies, with no hint":
    let dir = testTmp / "outline_large_ok"
    createDir(dir)
    let png = dir / "sprite.png"
    writeSprite(png, 64, allBoundarySprite(64))
    let outDir = testTmp / "outline_large_ok_out"
    let r = runArt(@["fix", png, "--cell", "68x68", "--profile", "hibit",
                      "--key", "ff00ff", "--outline", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check "refuse:" notin r.output
    check "flag:" notin r.output
    removeDir(dir)
    removeDir(outDir)

  test "a silhouette touching the cell edge is refused, and the asset is untouched":
    let dir = testTmp / "outline_edge"
    createDir(dir)
    let png = dir / "sprite.png"
    var px = newSeq[byte](20 * 20 * 4)
    for i in 0 ..< 20 * 20:
      px[i * 4] = 50
      px[i * 4 + 1] = 50
      px[i * 4 + 2] = 50
      px[i * 4 + 3] = 255
    let mid = (10 * 20 + 10) * 4
    px[mid] = 5
    px[mid + 1] = 5
    px[mid + 2] = 5
    doAssert stbw.writePNG(png, 20, 20, stbw.RGBA, px)
    let outDir = testTmp / "outline_edge_out"
    let r = runArt(@["fix", png, "--cell", "20x20", "--profile", "hibit",
                      "--key", "ff00ff", "--outline", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains(png & ": its silhouette touches the cell edge")

    let lintResult = runArt(@["lint", outDir / "sprite.png"])
    checkpoint lintResult.output
    check lintResult.code == 1
    check lintResult.output.contains(outDir / "sprite.png" & ": outline")
    removeDir(dir)
    removeDir(outDir)

  test "without --outline, a heavy-ink sprite's fix shows no outline hint":
    let dir = testTmp / "outline_off"
    createDir(dir)
    let png = dir / "sprite.png"
    writeSprite(png, 10, nearBlackBodySprite())
    let outDir = testTmp / "outline_off_out"
    let r = runArt(@["fix", png, "--cell", "14x14", "--profile", "hibit",
                      "--key", "ff00ff", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check "refuse:" notin r.output
    check "flag:" notin r.output
    removeDir(dir)
    removeDir(outDir)

removeDir(testTmp)
