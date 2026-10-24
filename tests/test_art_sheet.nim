import unittest
import std/os
import stb_image/read as stbi
import tools/para/art/sheet

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art"

let testTmp = getTempDir() / ("paraloop_" & $getCurrentProcessId())

suite "art/sheet: contact sheet composition":
  test "lays out every asset once, at or under the tile cap, into one PNG":
    let outDir = testTmp / "art_sheet_test"
    createDir(outDir)
    let outPath = outDir / "sheet.png"
    let assets = @[
      fixturesDir / "zombie.png",
      fixturesDir / "ghost.png",
      fixturesDir / "koalio.png",
      fixturesDir / "gino.png",
      fixturesDir / "gino_attack.png",
    ]
    let res = buildContactSheet(assets, outPath, maxTile = 64, cols = 3)

    check res.tiles.len == 5
    check res.outPath == outPath
    check fileExists(outPath)

    for t in res.tiles:
      check t.w <= 64
      check t.h <= 64
      # Every tile must land fully inside the canvas.
      check t.x >= 0 and t.y >= 0
      check t.x + t.w <= res.canvasW
      check t.y + t.h <= res.canvasH

    var w, h, ch: int
    discard stbi.load(outPath, w, h, ch, stbi.RGBA)
    check w == res.canvasW
    check h == res.canvasH
    removeDir(outDir)

  test "tiles name each asset by the path given, so same-named sheets in different folders stay apart":
    let dir = testTmp / "art_sheet_test_samename"
    let assets = @[dir / "a" / "zombie.png", dir / "b" / "zombie.png"]
    for p in assets:
      createDir(p.parentDir)
      copyFile(fixturesDir / "zombie.png", p)
    let res = buildContactSheet(assets, dir / "sheet.png")
    check res.tiles.len == 2
    check res.tiles[0].file == assets[0]
    check res.tiles[1].file == assets[1]
    removeDir(dir)

  test "an empty asset list is a definitive error, not a blank image":
    expect(SheetError):
      discard buildContactSheet(@[], testTmp / "art_sheet_test_empty.png")

removeDir(testTmp)
