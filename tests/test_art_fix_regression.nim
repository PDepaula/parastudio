# The A2 acceptance test itself (asset pipeline report §6.3, §9 row A2):
# degrade two real repo sprites into fake-looking "AI output" (built here in
# code, per the task - never committed as new art), run them through the
# real `para art fix` (a real `uv run --project tools/art` subprocess, no
# mocking), and check the report's three numbers: exact native size, at most
# 1% of the sprite's pixels (every pixel opaque in the original or the fixed
# output) differing by more than 24 in any RGBA channel, so wrong alpha
# counts as off, and 0 pixels changed when fix runs again on its own output.
# `para art lint` (with a sidecar this LPC-derived art needs an outline
# waiver for, same as tests/test_art_cli.nim's other LPC fixtures) then
# passes on the fixed file.

import unittest
import std/[os, sets, strformat, strutils]
import stb_image/read as stbi
import stb_image/write as stbw
import tools/para/artcmd
import fixtures/art/degrade

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art"
let testTmp = getTempDir() / ("paraloop_fix_regression_" & $getCurrentProcessId())

type
  Case = object
    name: string
    fixture: string
    cropX, cropY, cellW, cellH: int
    profile: string
    upscaleFactor, finalPx: int
    maxColors: int ## the profile's budget, so the case is a real regression, not a fluke

const cases = [
  Case(name: "skeleton", fixture: "skeleton.png", cropX: 0, cropY: 128, cellW: 64, cellH: 64,
       profile: "hibit", upscaleFactor: 8, finalPx: 517, maxColors: 48),
  # bat.png's (0,0) cell clips both side edges by design (report §7.2:
  # "the 4 with wing tips on the sides are clipping" - a real pre-existing
  # defect in the source art, not this pipeline's concern); (1,0) only
  # touches its cell's bottom row, which the "bottom" pivot allows.
  Case(name: "bat", fixture: "bat.png", cropX: 0, cropY: 32, cellW: 32, cellH: 32,
       profile: "lowbit", upscaleFactor: 8, finalPx: 259, maxColors: 16),
]

proc loadRgba(path: string): tuple[pixels: seq[byte], w, h: int] =
  var w, h, ch: int
  let pixels = stbi.load(path, w, h, ch, stbi.RGBA)
  (pixels, w, h)

proc cropCell(pixels: seq[byte], srcW: int, x0, y0, cw, ch: int): seq[byte] =
  result = newSeq[byte](cw * ch * 4)
  for y in 0 ..< ch:
    for x in 0 ..< cw:
      for c in 0 .. 3:
        result[(y * cw + x) * 4 + c] = pixels[((y0 + y) * srcW + (x0 + x)) * 4 + c]

proc spritePixelsOffPct(origPath, outPath: string): float =
  let (orig, ow, oh) = loadRgba(origPath)
  let (outp, pw, ph) = loadRgba(outPath)
  doAssert (ow, oh) == (pw, ph), &"size mismatch: orig {ow}x{oh}, out {pw}x{ph}"
  var opaque, off = 0
  for i in 0 ..< ow * oh:
    if orig[i * 4 + 3] == 0 and outp[i * 4 + 3] == 0: continue
    inc opaque
    var maxDiff = 0
    for c in 0 .. 3:
      let d = abs(orig[i * 4 + c].int - outp[i * 4 + c].int)
      if d > maxDiff: maxDiff = d
    if maxDiff > 24: inc off
  doAssert opaque > 0
  off.float / opaque.float * 100.0

suite "para art fix: report §6.3's regression - degraded repo sprites":
  for c in cases:
    test c.name & ": exact native size, <=1% of sprite pixels off, idempotent, lint passes":
      let dir = testTmp / c.name
      createDir(dir)
      let (srcPixels, srcW, _) = loadRgba(fixturesDir / c.fixture)
      let cell = cropCell(srcPixels, srcW, c.cropX, c.cropY, c.cellW, c.cellH)

      let origPath = dir / "orig.png"
      doAssert stbw.writePNG(origPath, c.cellW, c.cellH, stbw.RGBA, cell)

      let (degraded, degSize) = degradeToFakeAI(cell, c.cellW, c.cellH, c.upscaleFactor, c.finalPx, 2)
      let degradedPath = dir / "degraded.png"
      doAssert stbw.writePNG(degradedPath, degSize, degSize, stbw.RGBA, degraded)

      let outDir = dir / "fixed"
      let cellFlag = &"{c.cellW}x{c.cellH}"
      let r1 = runArt(@["fix", degradedPath, "--cell", cellFlag, "--profile", c.profile, "--out", outDir])
      checkpoint r1.output
      check r1.code == 0
      check r1.output.contains(",true,") # first write

      let outPath = outDir / "degraded.png"
      check fileExists(outPath)

      let (fixedPixels, ow, oh) = loadRgba(outPath)
      check (ow, oh) == (c.cellW, c.cellH) # exact native size

      var opaqueColors = initHashSet[int]()
      for i in 0 ..< ow * oh:
        if fixedPixels[i * 4 + 3] == 255:
          opaqueColors.incl(fixedPixels[i*4].int shl 16 or fixedPixels[i*4+1].int shl 8 or fixedPixels[i*4+2].int)
      checkpoint &"{opaqueColors.len} opaque colours (profile budget {c.maxColors})"
      check opaqueColors.len <= c.maxColors

      let offPct = spritePixelsOffPct(origPath, outPath)
      checkpoint &"{offPct:.3f}% of sprite pixels off"
      check offPct <= 1.0

      # re-running fix on its own output changes 0 pixels
      let r2 = runArt(@["fix", outPath, "--cell", cellFlag, "--profile", c.profile, "--out", outDir])
      checkpoint r2.output
      check r2.code == 0
      check r2.output.contains(",false,") # unchanged

      # `para art lint` passes on the fix's output (an outline waiver is
      # needed for the same reason tests/test_art_cli.nim's other LPC
      # fixtures need one: this art predates hibit's forced-outline rule)
      writeFile(outPath.changeFileExt("") & ".art.toml", &"""
cell_w = {c.cellW}
cell_h = {c.cellH}
profile = "{c.profile}"
pivot = "bottom"

[[waiver]]
rule = "outline"
reason = "LPC art"
""")
      let lintResult = runArt(@["lint", outPath])
      checkpoint lintResult.output
      check lintResult.code == 0

      removeDir(dir)

removeDir(testTmp)
