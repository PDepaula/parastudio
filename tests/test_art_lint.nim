# Runs `para art lint`'s checks against the twelve sheets of asset pipeline
# report §7.2 in tests/fixtures/art (eleven copied from parasurvivors, plus
# painted.png, a synthetic stand-in for its unlicensed parakeet.png), and reproduces its
# table and named facts: koalio's grid is BAD, ghost's alpha is waived, and
# gino's bottom-edge touches are the pivot, not clipping. The last suite reproduces
# the report's "a naive downscale fails on colours" finding (§6.3, §7.2) by
# resizing a real fixture with a blending resize - the wrong tool for pixel
# art - and showing the lint colour-count rule catches it.

import unittest
import std/[math, options, os, strutils]
import stb_image/read as stbi
import tools/para/art/[lint, profile, sidecar]

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art"

let testTmp = getTempDir() / ("paraloop_" & $getCurrentProcessId())

proc naiveBilinearDownscale(pixels: seq[byte], w, h, nw, nh: int): seq[byte] =
  ## The "-resize" a general image tool reaches for by default: bilinear
  ## sampling. It is exactly the wrong tool for pixel art (report §6.3): it
  ## blends crisp flat-colour regions into a smear of new intermediate
  ## colours, which is what naive downscale color counts.
  result = newSeq[byte](nw * nh * 4)
  for oy in 0 ..< nh:
    let fy = (oy.float + 0.5) * h.float / nh.float - 0.5
    let y0 = clamp(fy.floor.int, 0, h - 1)
    let y1 = clamp(y0 + 1, 0, h - 1)
    let ty = fy - y0.float
    for ox in 0 ..< nw:
      let fx = (ox.float + 0.5) * w.float / nw.float - 0.5
      let x0 = clamp(fx.floor.int, 0, w - 1)
      let x1 = clamp(x0 + 1, 0, w - 1)
      let tx = fx - x0.float
      for c in 0 .. 3:
        let p00 = pixels[(y0 * w + x0) * 4 + c].float
        let p10 = pixels[(y0 * w + x1) * 4 + c].float
        let p01 = pixels[(y1 * w + x0) * 4 + c].float
        let p11 = pixels[(y1 * w + x1) * 4 + c].float
        let top = p00 * (1 - tx) + p10 * tx
        let bot = p01 * (1 - tx) + p11 * tx
        let v = top * (1 - ty) + bot * ty
        result[(oy * nw + ox) * 4 + c] = byte(clamp(v.round, 0.0, 255.0))

type Row72 = tuple[file: string, w, h, cellW, cellH: int, grid: GridStatus,
                   colors, semiAlpha, emptyCells, edgeTouchCells: int]

const unmeasured = -1 ## a per-cell column on a sheet whose grid doesn't tile

const table72: array[12, Row72] = [
  ("zombie.png", 576, 256, 64, 64, gsOk, 16, 0, 0, 0),
  ("skeleton.png", 576, 256, 64, 64, gsOk, 6, 0, 0, 0),
  ("ghost.png", 576, 256, 64, 64, gsOk, 0, 19148, 0, 0),
  ("bat.png", 96, 128, 32, 32, gsOk, 6, 0, 0, 6),
  ("koalio.png", 128, 32, 18, 26, gsBad, 172, 609, unmeasured, unmeasured),
  ("painted.png", 210, 100, 70, 100, gsOk, 2626, 1399, 0, 3),
  ("otto.png", 1152, 512, 128, 128, gsOk, 29, 0, 0, 0),
  ("otto_attack.png", 1536, 768, 192, 192, gsOk, 31, 0, 0, 0),
  ("imma.png", 576, 256, 64, 64, gsOk, 35, 0, 0, 2),
  ("lina_attack.png", 1152, 768, 192, 192, gsOk, 28, 0, 0, 0),
  ("gino.png", 1152, 512, 128, 128, gsOk, 24, 0, 0, 0),
  ("gino_attack.png", 832, 256, 64, 64, gsOk, 39, 0, 0, 20),
]

suite "para art lint on real parasurvivors sheets (report §7.2)":
  test "every sheet reproduces its row of the §7.2 table":
    for row in table72:
      let r = lintFile(fixturesDir / row.file)
      checkpoint row.file
      let emptyCells = if r.cellsMeasured: r.emptyCells else: unmeasured
      let edgeTouchCells = if r.cellsMeasured: r.edgeTouchCells else: unmeasured
      check (r.file.extractFilename, r.width, r.height, r.cellW, r.cellH, r.grid, r.colorCount,
             r.semiAlphaPx, emptyCells, edgeTouchCells) == row

  test "koalio.png: the hand-offset 18x26 cells don't tile 128x32 - grid is BAD, waived by design":
    let r = lintFile(fixturesDir / "koalio.png")
    check r.grid == gsBad
    check "grid" notin r.failReasons
    check r.waived.len == 1
    check r.waived[0].rule == "grid"
    # The waiver covers only the grid: its per-cell rules still can't be
    # measured, and its colour count and soft alpha are still out of the
    # lowbit profile's bounds.
    check not r.cellsMeasured
    check r.failReasons == @[cellsUnmeasured, "colors", "alpha"]

  test "ghost.png: fully translucent by design - the alpha waiver clears it, not a global rule change":
    let r = lintFile(fixturesDir / "ghost.png")
    check r.semiAlphaPx > 0
    check r.waived.len == 1
    check r.waived[0].rule == "alpha"
    check "alpha" notin r.failReasons
    # The waiver is per-asset: the same rule on an un-waived sheet still fires.
    let zombie = lintFile(fixturesDir / "zombie.png")
    check zombie.waived.len == 0

  test "gino_attack.png: 18 bottom touches are the pivot, the real defect is 1 left + 1 right":
    let r = lintFile(fixturesDir / "gino_attack.png")
    check r.grid == gsOk
    # Matches the report's own per-edge breakdown for this exact file (§7.2
    # evidence appendix: "{top 0, bottom 18, left 1, right 1}").
    check r.edges.top == 0
    check r.edges.bottom == 18
    check r.edges.left == 1
    check r.edges.right == 1
    # The 18 bottom touches are feet on the baseline and must not by
    # themselves fail the asset; the 2 side touches are real clipping and do.
    check "edge" in r.failReasons

  test "imma.png: both edge touches are feet on the baseline, so they don't fail it":
    let r = lintFile(fixturesDir / "imma.png")
    check r.edges == EdgeCounts(top: 0, bottom: 2, left: 0, right: 0)
    check "edge" notin r.failReasons

  test "bat.png: 6 cells touch an edge; the 4 with wing tips on the sides are clipping":
    let r = lintFile(fixturesDir / "bat.png")
    check r.edgeTouchCells == 6
    check r.edges == EdgeCounts(top: 0, bottom: 4, left: 4, right: 4)
    check r.failReasons == @["edge"]

  test "painted.png: a painted-style sprite a pixel profile rejects on colours and alpha":
    let r = lintFile(fixturesDir / "painted.png")
    check r.colorCount > r.profileName.builtinProfile.get.maxColors
    check "colors" in r.failReasons
    check "alpha" in r.failReasons
    # Its three frames fill the full 100px cell height, so they touch the top.
    check "edge" in r.failReasons

  test "a bottom-only touch is the pivot and passes; a side touch is clipping and fails":
    let prof = builtinHiBit
    # A single 4x4 cell; one opaque pixel on the bottom row only.
    var bottomOnly = newSeq[byte](4 * 4 * 4)
    let bi = (3 * 4 + 1) * 4
    bottomOnly[bi] = 10; bottomOnly[bi + 1] = 10; bottomOnly[bi + 2] = 10; bottomOnly[bi + 3] = 255
    let okReport = analyzeAsset(bottomOnly, 4, 4, 4, 4, prof, "bottom")
    check okReport.edges.bottom == 1
    check "edge" notin okReport.failReasons

    # The same shape, but the opaque pixel sits on the left column instead.
    var sideTouch = newSeq[byte](4 * 4 * 4)
    let si = (1 * 4 + 0) * 4
    sideTouch[si] = 10; sideTouch[si + 1] = 10; sideTouch[si + 2] = 10; sideTouch[si + 3] = 255
    let failReport = analyzeAsset(sideTouch, 4, 4, 4, 4, prof, "bottom")
    check failReport.edges.left == 1
    check "edge" in failReport.failReasons

  test "ordinary LPC sheets, drawn without hibit's outline, fail only the outline rule":
    for name in ["zombie.png", "skeleton.png", "otto.png", "otto_attack.png",
                 "lina_attack.png", "gino.png"]:
      let r = lintFile(fixturesDir / name)
      checkpoint name
      check r.grid == gsOk
      check r.cellsMeasured
      check r.outlineOffenders > 0
      check r.failReasons == @["outline"]
      let waived = applyWaivers(r, @[Waiver(rule: "outline", reason: "LPC art")])
      check waived.verdict == "ok"

  test "a waived grid never passes: the per-cell rules it leaves unchecked are named":
    # A 5x4 sheet declared as 3x3 cells (doesn't tile), its sprite clipped on
    # the left side: before the grid waiver hid it, this came out "ok".
    var sheet = newSeq[byte](5 * 4 * 4)
    for y in 1 .. 2:
      let i = (y * 5 + 0) * 4
      sheet[i] = 10; sheet[i + 1] = 10; sheet[i + 2] = 10; sheet[i + 3] = 255
    let report = analyzeAsset(sheet, 5, 4, 3, 3, builtinHiBit, "bottom")
    check report.grid == gsBad
    check not report.cellsMeasured
    let gridWaiver = Waiver(rule: "grid", reason: "hand-offset")
    let r = applyWaivers(report, @[gridWaiver])
    check r.failReasons == @[cellsUnmeasured]
    check r.verdict == "fail"
    let tried = applyWaivers(report, @[gridWaiver,
      Waiver(rule: cellsUnmeasured, reason: "trying to hide it")])
    check tried.failReasons == @[cellsUnmeasured]
    check tried.verdict == "fail"

  test "no sidecar means no declared cell size, not a guess":
    let dir = testTmp / "art_lint_test_nosidecar"
    createDir(dir)
    # Reuse a real fixture's bytes so this is a decodable PNG.
    copyFile(fixturesDir / "zombie.png", dir / "orphan.png")
    let r = lintFile(dir / "orphan.png")
    check r.grid == gsUnknown
    check "sidecar" in r.failReasons
    check cellsUnmeasured in r.failReasons
    check r.verdict == "fail"
    removeDir(dir)

proc setPx(buf: var seq[byte], size, x, y: int, v: byte) =
  let i = (y * size + x) * 4
  buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255

proc block5(ring, interior: byte): seq[byte] =
  ## A 7x7 cell with a 5x5 opaque block in the middle: its 16-pixel ring is
  ## the boundary, the 3x3 inside the interior.
  result = newSeq[byte](7 * 7 * 4)
  for y in 1 .. 5:
    for x in 1 .. 5:
      let v = if x in 2 .. 4 and y in 2 .. 4: interior else: ring
      result.setPx(7, x, y, v)

proc solidCell(size: int, ring, center: byte): seq[byte] =
  ## A size x size cell with a 3x3 opaque block in the middle: the 8-pixel
  ## ring is the boundary, the single centre pixel the interior.
  result = newSeq[byte](size * size * 4)
  let mid = size div 2
  for y in mid - 1 .. mid + 1:
    for x in mid - 1 .. mid + 1:
      let v = if x == mid and y == mid: center else: ring
      let i = (y * size + x) * 4
      result[i] = v; result[i + 1] = v; result[i + 2] = v; result[i + 3] = 255

suite "para art lint: outline and palette rules (report §5.3)":
  test "an interior darker than the outline fails hibit, and is only reported for lowbit":
    let lightRing = solidCell(5, 200, 10)
    let hi = analyzeAsset(lightRing, 5, 5, 5, 5, builtinHiBit, "bottom")
    check hi.cellsMeasured
    check hi.outlineOffenders == 8
    check "outline" in hi.failReasons
    let lo = analyzeAsset(lightRing, 5, 5, 5, 5, builtinLowBit, "bottom")
    check lo.outlineOffenders == 8
    check "outline" notin lo.failReasons

  test "one dark boundary pixel doesn't outline the rest of the silhouette":
    var boot = block5(200, 100)
    boot.setPx(7, 3, 5, 10)
    let r = analyzeAsset(boot, 7, 7, 7, 7, builtinHiBit, "bottom")
    check r.outlineOffenders == 15
    check "outline" in r.failReasons

  test "a boundary darker everywhere than the darkest interior pixel passes":
    let r = analyzeAsset(block5(10, 100), 7, 7, 7, 7, builtinHiBit, "bottom")
    check r.outlineOffenders == 0
    check r.verdict == "ok"

  test "a 1-px outline with diagonal steps passes; fill touching the outside only diagonally is interior":
    # A diamond: outline where |x-3|+|y-3| == 2, fill inside it. Fill pixels
    # such as (3,2) have a transparent diagonal neighbour but no orthogonal one.
    var diamond = newSeq[byte](7 * 7 * 4)
    for y in 0 ..< 7:
      for x in 0 ..< 7:
        let d = abs(x - 3) + abs(y - 3)
        if d == 2: diamond.setPx(7, x, y, 10)
        elif d < 2: diamond.setPx(7, x, y, 100)
    let r = analyzeAsset(diamond, 7, 7, 7, 7, builtinHiBit, "bottom")
    check r.outlineOffenders == 0
    check r.verdict == "ok"

  test "a boundary pixel only as dark as the darkest interior pixel isn't darker, so it fails":
    let r = analyzeAsset(solidCell(5, 10, 10), 5, 5, 5, 5, builtinHiBit, "bottom")
    check r.outlineOffenders == 8
    check "outline" in r.failReasons

  test "an outline missing from one frame fails, even when another frame has one":
    let outlined = solidCell(5, 0, 200)
    let unoutlined = solidCell(5, 200, 30)
    var sheet = newSeq[byte](10 * 5 * 4)
    for y in 0 ..< 5:
      for x in 0 ..< 5:
        for c in 0 .. 3:
          sheet[(y * 10 + x) * 4 + c] = outlined[(y * 5 + x) * 4 + c]
          sheet[(y * 10 + x + 5) * 4 + c] = unoutlined[(y * 5 + x) * 4 + c]
    let r = analyzeAsset(sheet, 10, 5, 5, 5, builtinHiBit, "bottom")
    check r.outlineOffenders == 8
    check "outline" in r.failReasons

  test "with a palette set, every opaque colour outside it fails and is listed":
    let prof = builtinHiBit
    let r = analyzeAsset(solidCell(5, 10, 200), 5, 5, 5, 5, prof, "bottom", [0x0a0a0a])
    check r.paletteChecked
    check r.offPalette == @[0xc8c8c8]
    check "palette" in r.failReasons
    let ok = analyzeAsset(solidCell(5, 10, 200), 5, 5, 5, 5, prof, "bottom", [0x0a0a0a, 0xc8c8c8])
    check ok.offPalette.len == 0
    check ok.verdict == "ok"

  test "with no palette set, membership isn't checked":
    let r = analyzeAsset(solidCell(5, 10, 200), 5, 5, 5, 5, builtinHiBit, "bottom")
    check not r.paletteChecked
    check "palette" notin r.failReasons

  test "a style.toml's palette applies to every sheet, whatever profile its sidecar names":
    let dir = testTmp / "art_lint_test_palette"
    createDir(dir)
    writeFile(dir / "style.toml", "profile = \"hibit\"\npalette = \"palette.hex\"\n")
    writeFile(dir / "palette.hex", "000000\n")
    let style = some(loadStyle(dir / "style.toml"))
    let zombie = lintFile(fixturesDir / "zombie.png", style)
    check zombie.offPalette.len == 16
    check "palette" in zombie.failReasons
    # bat's sidecar names lowbit, not the style's hibit: it gets lowbit's
    # builtin budgets, but the game's palette still applies.
    let bat = lintFile(fixturesDir / "bat.png", style)
    check bat.profileName == "lowbit"
    check bat.profileSource == "builtin default"
    check bat.paletteChecked
    check bat.offPalette.len == 6
    check "palette" in bat.failReasons
    removeDir(dir)

  test "an alpha waiver never hides off-palette colours in translucent pixels":
    let dir = testTmp / "art_lint_test_palette_alpha"
    createDir(dir)
    writeFile(dir / "style.toml", "profile = \"hibit\"\npalette = \"palette.hex\"\n")
    writeFile(dir / "palette.hex", "000000\n")
    # ghost.png has no opaque pixels at all, only semi-alpha ones, and its
    # sidecar waives the alpha rule.
    let ghost = lintFile(fixturesDir / "ghost.png", some(loadStyle(dir / "style.toml")))
    check ghost.colorCount == 0
    check ghost.waived.len == 1
    check ghost.waived[0].rule == "alpha"
    check ghost.paletteChecked
    check ghost.offPalette.len > 0
    check ghost.failReasons == @["palette", "outline"]
    check ghost.verdict == "fail"
    removeDir(dir)

suite "para art lint: a naive downscale fails on colours (report §6.3/§7.2)":
  test "bilinear-resizing a real sheet blows the colour budget a nearest-neighbour crop would not":
    var w, h, ch: int
    let pixels = stbi.load(fixturesDir / "gino.png", w, h, ch, stbi.RGBA)
    let prof = builtinHiBit
    let clean = analyzeAsset(pixels, w, h, 0, 0, prof, "bottom")
    check clean.colorCount <= prof.maxColors

    let nw = int(w.float * 0.61)
    let nh = int(h.float * 0.61)
    let degraded = naiveBilinearDownscale(pixels, w, h, nw, nh)
    let bad = analyzeAsset(degraded, nw, nh, 0, 0, prof, "bottom")
    check bad.colorCount > prof.maxColors
    check "colors" in bad.failReasons

suite "para art lint: the key rule (leaked key-coloured pixels)":
  proc keyCell(rgb: array[3, byte]): seq[byte] =
    ## A 4x4 cell, all opaque dark grey except pixel (1,1).
    result = newSeq[byte](4 * 4 * 4)
    for i in 0 ..< 16:
      result[i * 4] = 40; result[i * 4 + 1] = 40; result[i * 4 + 2] = 40; result[i * 4 + 3] = 255
    let k = (1 * 4 + 1) * 4
    result[k] = rgb[0]; result[k + 1] = rgb[1]; result[k + 2] = rgb[2]

  test "an opaque pixel at the declared key fails `key`; with no key declared nothing is checked":
    let prof = builtinHiBit
    let px = keyCell([0'u8, 255, 0])
    let r = analyzeAsset(px, 4, 4, 4, 4, prof, "none", key = "00ff00")
    check r.keyLeakPx == 1
    check "key" in r.failReasons
    let unchecked = analyzeAsset(px, 4, 4, 4, 4, prof, "none")
    check unchecked.keyLeakPx == 0
    check "key" notin unchecked.failReasons

  test "the rule is a distance: 40 away leaks, a darker or a teal green does not":
    let prof = builtinHiBit
    check analyzeAsset(keyCell([0'u8, 215, 0]), 4, 4, 4, 4, prof, "none", key = "00ff00").keyLeakPx == 1
    check analyzeAsset(keyCell([0'u8, 214, 0]), 4, 4, 4, 4, prof, "none", key = "00ff00").keyLeakPx == 0
    check analyzeAsset(keyCell([40'u8, 150, 40]), 4, 4, 4, 4, prof, "none", key = "00ff00").keyLeakPx == 0
    check analyzeAsset(keyCell([0'u8, 128, 128]), 4, 4, 4, 4, prof, "none", key = "00ff00").keyLeakPx == 0

  test "a transparent pixel of the key colour is not a leak":
    let prof = builtinHiBit
    var px = keyCell([0'u8, 255, 0])
    px[(1 * 4 + 1) * 4 + 3] = 0
    check analyzeAsset(px, 4, 4, 4, 4, prof, "none", key = "00ff00").keyLeakPx == 0

  test "a sidecar's key reaches lintFile; a waiver clears it":
    let dir = testTmp / "art_lint_test_key"
    createDir(dir)
    copyFile(fixturesDir / "zombie.png", dir / "z.png")
    let base = "cell_w = 64\ncell_h = 64\nprofile = \"lowbit\"\n"
    writeFile(dir / "z.art.toml", base)
    check lintFile(dir / "z.png").keyLeakPx == 0
    # zombie.png has no pure-green pixels; declaring a key it does contain
    # (its own darkest-skin colour) proves the key travels to the check.
    var w, h, ch: int
    let pixels = stbi.load(dir / "z.png", w, h, ch, stbi.RGBA)
    var found = false
    for i in 0 ..< w * h:
      if pixels[i * 4 + 3] == 255 and not found:
        writeFile(dir / "z.art.toml", base & "key = \"" &
          toHex(pixels[i * 4].int shl 16 or pixels[i * 4 + 1].int shl 8 or pixels[i * 4 + 2].int, 6) & "\"\n")
        found = true
    let r = lintFile(dir / "z.png")
    check r.keyLeakPx > 0
    check "key" in r.failReasons
    check applyWaivers(r, @[Waiver(rule: "key", reason: "test")]).failReasons.find("key") < 0
    removeDir(dir)

removeDir(testTmp)
