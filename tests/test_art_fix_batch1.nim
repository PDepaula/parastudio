# GameLab batch 1 (tests/fixtures/art/batch1/) through the real `para art fix`
# (uv subprocess) and `para art lint`: the three defects the scout found, as
# end-to-end regressions - `--cell` stretching a square source, the colour cap
# met only by a library default, and the outline step refusing small stones.
# `--key 00ff00` is the sprites' own background.

import unittest
import std/[options, os, strformat, strutils, sets]
import stb_image/read as stbi
import tools/para/artcmd
import tools/para/art/sidecar

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art" / "batch1"
let testTmp = getTempDir() / ("paraloop_fix_batch1_" & $getCurrentProcessId())

type Bbox = tuple[w, h: int]

proc loadRgba(path: string): tuple[px: seq[byte], w, h: int] =
  var w, h, ch: int
  let px = stbi.load(path, w, h, ch, stbi.RGBA)
  (px, w, h)

proc bboxOf(img: tuple[px: seq[byte], w, h: int], isContent: proc (px: seq[byte], i: int): bool): Bbox =
  var x0, y0 = high(int)
  var x1, y1 = -1
  for y in 0 ..< img.h:
    for x in 0 ..< img.w:
      if isContent(img.px, (y * img.w + x) * 4):
        x0 = min(x0, x); x1 = max(x1, x)
        y0 = min(y0, y); y1 = max(y1, y)
  (x1 - x0 + 1, y1 - y0 + 1)

proc notKeyGreen(px: seq[byte], i: int): bool =
  abs(int(px[i]) - 0) + abs(int(px[i + 1]) - 255) + abs(int(px[i + 2]) - 0) > 150

proc opaque(px: seq[byte], i: int): bool = px[i + 3] > 0

proc distinctColors(path: string): int =
  let img = loadRgba(path)
  var seen = initHashSet[(byte, byte, byte)]()
  for i in 0 ..< img.w * img.h:
    if img.px[i * 4 + 3] > 0:
      seen.incl (img.px[i * 4], img.px[i * 4 + 1], img.px[i * 4 + 2])
  seen.len

proc lintVerdict(png, profile: string, cellW, cellH: int): tuple[code: int, output: string] =
  ## `fix` wrote the sidecar next to the png; lint it as it stands.
  let sc = loadSidecar(png)
  doAssert sc.isSome, png & ": fix wrote no sidecar"
  doAssert (sc.get.cellW, sc.get.cellH, sc.get.profile, sc.get.pivot) == (cellW, cellH, profile, "bottom")
  let r = runArt(@["lint", png])
  (r.code, r.output)

suite "para art fix: GameLab batch 1 end to end":
  createDir(testTmp)

  test "a square player into a 96x144 cell keeps its aspect, meets the cap, and lints clean":
    let outDir = testTmp / "player"
    let r = runArt(@["fix", fixturesDir / "player_up.png", "--cell", "96x144",
                      "--profile", "hibit", "--key", "00ff00", "--outline", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check "refuse:" notin r.output
    let src = bboxOf(loadRgba(fixturesDir / "player_up.png"), notKeyGreen)
    let outPng = outDir / "player_up.png"
    let fixedBox = bboxOf(loadRgba(outPng), opaque)
    let srcAspect = src.w / src.h
    let fixedAspect = fixedBox.w / fixedBox.h
    checkpoint &"source {src} aspect {srcAspect}, fixed {fixedBox} aspect {fixedAspect}"
    check abs(fixedAspect - srcAspect) < 0.03 # the old stretch gave 0.43 for 0.64
    check distinctColors(outPng) <= 48
    let lint = lintVerdict(outPng, "hibit", 96, 144)
    checkpoint lint.output
    check lint.code == 0

  test "the wolf at 96x96 lints clean under hibit and under lowbit's 16-colour cap":
    for (profile, cap) in [("hibit", 48), ("lowbit", 16)]:
      let outDir = testTmp / ("wolf_" & profile)
      let r = runArt(@["fix", fixturesDir / "wolf.png", "--cell", "96x96",
                        "--profile", profile, "--key", "00ff00", "--outline", "--out", outDir])
      checkpoint r.output
      check r.code == 0
      let outPng = outDir / "wolf.png"
      check distinctColors(outPng) <= cap
      let lint = lintVerdict(outPng, profile, 96, 96)
      checkpoint lint.output
      check lint.code == 0

  test "the three stones outline at 16x16, 24x24 and 32x32 with no refusal":
    for size in [16, 24, 32]:
      for name in ["stone_small", "stone_medium", "stone_large"]:
        let outDir = testTmp / &"{name}_{size}"
        let r = runArt(@["fix", fixturesDir / (name & ".png"), "--cell", &"{size}x{size}",
                          "--profile", "hibit", "--key", "00ff00", "--outline", "--out", outDir])
        checkpoint r.output
        check r.code == 0
        check "interior ink" notin r.output
        check "nearly its whole boundary" notin r.output
        let lint = lintVerdict(outDir / (name & ".png"), "hibit", size, size)
        checkpoint lint.output
        check lint.code == 0

removeDir(testTmp)
