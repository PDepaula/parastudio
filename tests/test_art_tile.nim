# Seamless full-bleed ground tiles: `para art fix --tile` and lint's
# `kind = "tile"` rules (tools/art/README.md, "Ground tiles"). The sources are
# tests/fixtures/art/tile/*.png (regenerate with gen_tiles.py there): an opaque
# 256x256 seamless tile whose four corners agree - the input that made `fix`
# without --tile write a blank cell while lint printed "0 of 1 failed" - and
# the same slabs with a brightness ramp, which has a hard seam. The Python half
# (resampling, errors) is tools/art/tests/test_tile.py.

import unittest
import std/[math, options, os, sequtils, strutils]
import stb_image/read as stbi
import stb_image/write as stbw
import tools/para/art/[lint, profile, sidecar]
import tools/para/artcmd

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art" / "tile"
let testTmp = getTempDir() / ("paraloop_tile_" & $getCurrentProcessId())

proc rgba(w, h: int, f: proc (x, y: int): array[4, byte]): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let p = f(x, y)
      for c in 0 .. 3: result[(y * w + x) * 4 + c] = p[c]

proc tileReport(px: seq[byte], w, h: int, kind = "tile"): AssetReport =
  analyzeAsset(px, w, h, w, h, builtinHiBit, "none", [], "", kind)

proc loadPng(path: string): tuple[px: seq[byte], w, h: int] =
  var channels: int
  result.px = stbi.load(path, result.w, result.h, channels, stbi.RGBA)

proc writeRgba(path: string, px: seq[byte], w, h: int) =
  doAssert stbw.writePNG(path, w, h, stbw.RGBA, px)

suite "lint: tile rules":
  # A periodic 8x8 checker-ish tile: every row/column repeats, so it wraps.
  let seamless = rgba(8, 8, proc (x, y: int): array[4, byte] =
    let v = byte(60 + 40 * ((x div 2 + y div 2) mod 2))
    [v, v, v, 255'u8])

  test "a seamless opaque tile of exactly one cell passes and ignores the sprite rules":
    # It touches every cell edge and has no outline; its seam lands on an
    # edge of the pattern, as a sparse-edged seamless texture's may.
    let r = tileReport(seamless, 8, 8)
    check r.tile
    check r.failReasons.len == 0
    check r.verdict == "ok"
    check r.seamX == 0.0 and r.seamY == 0.0
    # the same pixels judged as a sprite fail the edge rule: the tile waiver is the kind
    check "edge" in tileReport(seamless, 8, 8, "").failReasons

  test "a hard seam is flagged with its measure, either axis":
    let ramp = rgba(8, 8, proc (x, y: int): array[4, byte] =
      let v = byte(20 + x * 30)
      [v, v, v, 255'u8])
    let r = tileReport(ramp, 8, 8)
    check "seamless" in r.failReasons
    check r.seamX > seamMax
    check r.seamY == 0.0
    let rampY = rgba(8, 8, proc (x, y: int): array[4, byte] =
      let v = byte(20 + y * 30)
      [v, v, v, 255'u8])
    let ry = tileReport(rampY, 8, 8)
    check "seamless" in ry.failReasons
    check ry.seamY > seamMax
    check ry.seamX == 0.0

  test "busy but seamless texture is not penalised for its contrast":
    let noisy = rgba(16, 16, proc (x, y: int): array[4, byte] =
      let v = byte(((x * 7 + y * 13) mod 5) * 50)
      [v, 255 - v, v, 255'u8])
    check tileReport(noisy, 16, 16).seamX <= seamMax

  test "a flat tile has a zero seam (0/0 is not a failure)":
    let flat = rgba(8, 8, proc (x, y: int): array[4, byte] = [90'u8, 100, 80, 255])
    check tileReport(flat, 8, 8).failReasons.len == 0

  test "the seam measure is the 3x3 tiling's wrap pair minus the 75th-percentile inside pair":
    # columns 10 x6, 110, 210: five inside pairs jump 0, two jump 100 per
    # channel (the 75th percentile is 0), the wrap joins 210 to 10 (200 per
    # channel), so the excess is 200 x sqrt 3.
    let px = rgba(8, 8, proc (x, y: int): array[4, byte] =
      let v = byte(if x == 7: 210 elif x == 6: 110 else: 10)
      [v, v, v, 255'u8])
    check abs(seamExcess(px, 8, 8, true) - 200.0 * sqrt(3.0)) < 1e-9
    check seamExcess(px, 8, 8, false) == 0.0

  test "a full-height line does not hide a hard seam":
    # a ~170-distance line at column 20 (two inside pairs of 98 per channel);
    # the last column is ~100 away from the first (58 per channel).
    proc slab(x, y: int): array[4, byte] =
      let v = byte(if x == 20: 158 else: 60)
      [v, v, v, 255'u8]
    let wraps = rgba(64, 64, slab)
    check tileReport(wraps, 64, 64).failReasons.len == 0
    let broken = rgba(64, 64, proc (x, y: int): array[4, byte] =
      if x == 63: [118'u8, 118, 118, 255'u8] else: slab(x, y))
    let r = tileReport(broken, 64, 64)
    check "seamless" in r.failReasons
    check r.seamX > seamMax

  test "wrong size, translucency and transparency fail":
    check "size" in analyzeAsset(seamless, 8, 8, 4, 8, builtinHiBit, "none", [], "", "tile").failReasons
    var semi = seamless
    semi[3] = 128
    check "alpha" in tileReport(semi, 8, 8).failReasons
    var hole = seamless
    hole[3] = 0
    let rh = tileReport(hole, 8, 8)
    check "alpha" in rh.failReasons
    check rh.failReasons.filterIt(it == "alpha").len == 1

  test "the colour cap still applies to a tile, the game palette does not":
    let many = rgba(8, 8, proc (x, y: int): array[4, byte] = [byte(x * 30), byte(y * 30), 7'u8, 255'u8])
    # 8x8 = 64 distinct colours > hibit's 48
    check "colors" in tileReport(many, 8, 8).failReasons
    let off = analyzeAsset(seamless, 8, 8, 8, 8, builtinHiBit, "none", [0x3c3c3c], "", "tile")
    check "palette" notin off.failReasons
    check not off.paletteChecked
    # the same pixels judged as a sprite are off the palette
    check "palette" in analyzeAsset(seamless, 8, 8, 8, 8, builtinHiBit, "none", [0x3c3c3c], "", "").failReasons

suite "lint: a blank output fails for every kind":
  test "fully transparent output fails blank (sprite, sheet and tile)":
    let blank = newSeq[byte](16 * 16 * 4)
    for kind in ["", "tile"]:
      let r = analyzeAsset(blank, 16, 16, 16, 16, builtinHiBit, "bottom", [], "", kind)
      checkpoint kind
      check "blank" in r.failReasons
      check r.verdict == "fail"
    check "blank" in applyWaivers(analyzeAsset(blank, 16, 16, 16, 16, builtinHiBit, "bottom"),
      @[Waiver(rule: "alpha", reason: "unrelated")]).failReasons

  test "a sprite with any visible pixel is not blank":
    var one = newSeq[byte](16 * 16 * 4)
    one[3] = 255
    check "blank" notin analyzeAsset(one, 16, 16, 16, 16, builtinHiBit, "bottom").failReasons

suite "sidecar: kind":
  test "kind round-trips, defaults to a sprite, and is not written for one":
    let dir = testTmp / "sidecar"
    createDir(dir)
    writeFile(dir / "t.art.toml", "cell_w = 96\ncell_h = 96\nprofile = \"hibit\"\nkind = \"tile\"\n")
    check loadSidecar(dir / "t.png").get.kind == "tile"
    check renderSidecar(loadSidecar(dir / "t.png").get).contains("kind = \"tile\"")
    writeFile(dir / "s.art.toml", "cell_w = 96\ncell_h = 96\nprofile = \"hibit\"\n")
    check loadSidecar(dir / "s.png").get.kind == ""
    check not renderSidecar(loadSidecar(dir / "s.png").get).contains("kind")
    writeFile(dir / "b.art.toml", "cell_w = 96\ncell_h = 96\nprofile = \"hibit\"\nkind = \"floor\"\n")
    expect SidecarError: discard loadSidecar(dir / "b.png")
    removeDir(dir)

suite "para art fix --tile: end to end through the real uv subprocess":
  setup:
    removeDir(testTmp)
    createDir(testTmp)

  test "a seamless opaque tile fixes to one opaque cell, lints ok, and a rerun changes nothing":
    let outDir = testTmp / "ok"
    let r = runArt(@["fix", fixturesDir / "seamless_256.png", "--tile", "--cell", "96x96", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains(",96x96,96x96,")
    check r.output.contains("fix: 1 written, 0 unchanged, 0 failed")
    let out1 = loadPng(outDir / "seamless_256.png")
    check (out1.w, out1.h) == (96, 96)
    var colours: seq[int]
    for i in 0 ..< 96 * 96:
      check out1.px[i * 4 + 3] == 255
      let c = out1.px[i * 4].int shl 16 or out1.px[i * 4 + 1].int shl 8 or out1.px[i * 4 + 2].int
      if c notin colours: colours.add c
    check colours.len > 1 # not the blank/flat output the key guess used to write
    check loadSidecar(outDir / "seamless_256.png").get.kind == "tile"
    let l = runArt(@["lint", outDir])
    checkpoint l.output
    check l.code == 0
    check l.output.contains("lint: 0 of 1 failed")
    check l.output.contains("seam_x 0.0 seam_y 0.0 (limit 16)")
    let again = runArt(@["fix", outDir / "seamless_256.png", "--tile", "--cell", "96x96", "--out", outDir])
    check again.code == 0
    check again.output.contains("fix: 0 written, 1 unchanged, 0 failed")

  test "the same tile without --tile no longer slips through lint when it comes out blank":
    # A flat opaque tile has four agreeing corners and nothing else: the key
    # guess takes all of it for background.
    let src = testTmp / "flat.png"
    writeRgba(src, rgba(256, 256, proc (x, y: int): array[4, byte] = [90'u8, 100, 80, 255]), 256, 256)
    let outDir = testTmp / "flat_old"
    check runArt(@["fix", src, "--cell", "96x96", "--out", outDir]).code == 0
    let l = runArt(@["lint", outDir])
    check l.code == 1
    check l.output.contains("blank")
    # and with --tile the flat tile is just a flat tile
    let outTile = testTmp / "flat_tile"
    check runArt(@["fix", src, "--tile", "--cell", "96x96", "--out", outTile]).code == 0
    check runArt(@["lint", outTile]).code == 0

  test "a non-seamless tile fixes but lint flags its seam":
    let outDir = testTmp / "broken"
    check runArt(@["fix", fixturesDir / "seam_break_256.png", "--tile", "--cell", "96x96", "--out", outDir]).code == 0
    let l = runArt(@["lint", outDir])
    checkpoint l.output
    check l.code == 1
    check l.output.contains("lint: 1 of 1 failed")
    check l.output.contains("seamless")
    check l.output.contains("seam_x ")
    # a waiver in the sidecar is the escape hatch, as for any rule
    let sc = outDir / "seam_break_256.art.toml"
    writeFile(sc, readFile(sc) & "\n[[waiver]]\nrule = \"seamless\"\nreason = \"one-off island\"\n")
    check runArt(@["lint", outDir]).code == 0

  test "the palette cap and a locked palette apply":
    let outDir = testTmp / "capped"
    createDir(testTmp / "g")
    writeFile(testTmp / "g" / "palette.hex", "262a24\n5a6450\n606860\n586258\n5c6e5a\n646458\n464e42\n")
    writeFile(testTmp / "g" / "style.toml", "profile = \"hibit\"\npalette = \"palette.hex\"\n")
    let r = runArt(@["fix", fixturesDir / "seam_break_256.png", "--tile", "--cell", "96x96",
      "--style", testTmp / "g" / "style.toml", "--out", outDir])
    check r.code == 0
    let l = runArt(@["lint", outDir, "--style", testTmp / "g" / "style.toml"])
    checkpoint l.output
    check not l.output.contains("off_palette:")
    check l.output.contains("colors")  # table column present
    let (px, w, h) = loadPng(outDir / "seam_break_256.png")
    check (w, h) == (96, 96)
    check px[3] == 255

  test "usage errors: --tile needs --cell and refuses keying, outline, pivot and fit":
    let png = fixturesDir / "seamless_256.png"
    check runArt(@["fix", png, "--tile"]).code == 2
    for extra in [@["--key", "00ff00"], @["--key-border-only"], @["--outline"], @["--pivot", "none"],
                  @["--fit", "content"], @["--margin", "5"], @["--figure-height", "40"]]:
      let r = runArt(@["fix", png, "--tile", "--cell", "96x96", "--out", testTmp / "u"] & extra)
      checkpoint $extra
      check r.code == 2
      check r.output.startsWith("error:")

  test "a source that is translucent, the wrong aspect or smaller than the cell is refused with a reason":
    let tr = testTmp / "translucent.png"
    writeRgba(tr, rgba(128, 128, proc (x, y: int): array[4, byte] = [90'u8, 100, 80, if x == 0: 0'u8 else: 255'u8]), 128, 128)
    let r1 = runArt(@["fix", tr, "--tile", "--cell", "96x96", "--out", testTmp / "r"])
    check r1.code == 1
    check r1.output.contains("fully opaque")
    let wide = testTmp / "wide.png"
    writeRgba(wide, rgba(200, 100, proc (x, y: int): array[4, byte] = [90'u8, 100, 80, 255]), 200, 100)
    let r2 = runArt(@["fix", wide, "--tile", "--cell", "96x96", "--out", testTmp / "r"])
    check r2.code == 1
    check r2.output.contains("never stretched or padded")
    let small = testTmp / "small.png"
    writeRgba(small, rgba(64, 64, proc (x, y: int): array[4, byte] = [90'u8, 100, 80, 255]), 64, 64)
    let r3 = runArt(@["fix", small, "--tile", "--cell", "96x96", "--out", testTmp / "r"])
    check r3.code == 1
    check r3.output.contains("only scales down")

removeDir(testTmp)
