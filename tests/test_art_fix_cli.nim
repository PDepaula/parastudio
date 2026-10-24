# AXI-shape checks on `para art fix` (asset pipeline report §8.3, §9 row
# A2), the same conventions tests/test_art_cli.nim checks for `lint`: TOON
# tables, a definitive empty state, next-step help[] hints, and exit codes
# 0 (every asset fixed)/1 (a real per-asset finding)/2 (usage error). The
# §6.3 regression numbers (exact size, <=1% pixels off, idempotent, lint
# passes) are tests/test_art_fix_regression.nim's job; this file is only
# about the CLI's shape and wiring to the real `uv run --project tools/art`
# subprocess.

import unittest
import std/[os, strutils]
import stb_image/read as stbi
import stb_image/write as stbw
import tools/para/artcmd

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art"
let testTmp = getTempDir() / ("paraloop_fix_cli_" & $getCurrentProcessId())

proc writeTinySprite(path: string; w, h: int) =
  ## A single already-clean sprite (not a multi-frame sheet, unlike this
  ## repo's own fixtures, which are already-packed sheets - `fix` runs on
  ## one raw sprite at a time, see tools/para/art/fix.nim's header comment):
  ## a small solid opaque block on a transparent field, feet on the last row.
  var px = newSeq[byte](w * h * 4)
  for y in h div 2 ..< h:
    for x in w div 4 ..< (w - w div 4):
      let i = (y * w + x) * 4
      px[i] = 40; px[i + 1] = 60; px[i + 2] = 90; px[i + 3] = 255
  doAssert stbw.writePNG(path, w, h, stbw.RGBA, px)

suite "para art fix: usage errors, exit code 2":
  test "no paths and no ./art directory":
    let r = runArt(@["fix"])
    check r.code == 2
    check r.output.startsWith("error:")

  test "an unknown flag":
    let r = runArt(@["fix", fixturesDir, "--nonsense"])
    check r.code == 2
    check r.output.startsWith("error:")

  test "a path that doesn't exist":
    let r = runArt(@["fix", "/no/such/path/at/all"])
    check r.code == 2
    check r.output.startsWith("error:")

  test "--cell needs WxH, not a bad or non-positive value":
    for bad in ["64", "64x", "0x64", "-1x64", "64xNaN"]:
      let r = runArt(@["fix", fixturesDir / "bat.png", "--cell", bad])
      checkpoint bad
      check r.code == 2
      check r.output.startsWith("error:")

  test "--pivot must be bottom or none":
    let r = runArt(@["fix", fixturesDir / "bat.png", "--pivot", "sideways"])
    check r.code == 2
    check r.output.contains("bottom")
    check r.output.contains("none")

  test "--profile must be lowbit or hibit":
    let r = runArt(@["fix", fixturesDir / "bat.png", "--profile", "midbit"])
    check r.code == 2

  test "--profile punchclub is the old name of hibit and writes the new one into the sidecar":
    let dir = testTmp / "fix_cli_alias"
    createDir(dir)
    let png = dir / "hero.png"
    writeTinySprite(png, 64, 64)
    let outDir = testTmp / "fix_cli_alias_out"
    let r = runArt(@["fix", png, "--cell", "64x64", "--profile", "punchclub", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check readFile(outDir / "hero.art.toml").contains("profile = \"hibit\"")
    removeDir(dir)
    removeDir(outDir)

  test "--key must be an RRGGBB hex colour":
    let r = runArt(@["fix", fixturesDir / "bat.png", "--key", "green"])
    check r.code == 2

  test "an explicit --style that doesn't exist":
    let r = runArt(@["fix", fixturesDir / "bat.png", "--style", fixturesDir / "nope.toml"])
    check r.code == 2
    check r.output.contains("nope.toml")

  test "a flag missing its value":
    for args in [@["--cell"], @["--out"], @["--pivot"], @["--profile"], @["--key"], @["--style"]]:
      let r = runArt(@["fix", fixturesDir / "bat.png"] & args)
      checkpoint $args
      check r.code == 2

  test "--fit must be whole or content, and content needs a --cell":
    let bad = runArt(@["fix", fixturesDir / "bat.png", "--fit", "stretch"])
    check bad.code == 2
    check bad.output.contains("content")
    let noCell = runArt(@["fix", fixturesDir / "bat.png", "--fit", "content"])
    check noCell.code == 2
    check noCell.output.contains("--cell")

  test "--margin and --figure-height need --fit content and sane values":
    let png = fixturesDir / "bat.png"
    check runArt(@["fix", png, "--cell", "32x32", "--margin", "5"]).code == 2
    check runArt(@["fix", png, "--cell", "32x32", "--figure-height", "20"]).code == 2
    for bad in [@["--margin", "-1"], @["--margin", "50"], @["--margin", "lots"],
                @["--figure-height", "0"], @["--figure-height", "tall"], @["--figure-height", "40"]]:
      let r = runArt(@["fix", png, "--cell", "32x32", "--fit", "content"] & bad)
      checkpoint $bad
      check r.code == 2
      check r.output.startsWith("error:")

  test "uv missing from PATH fails loud, not a crash":
    let savedPath = getEnv("PATH")
    putEnv("PATH", testTmp) # a directory with no `uv`
    let r = runArt(@["fix", fixturesDir / "bat.png", "--cell", "32x32"])
    putEnv("PATH", savedPath)
    check r.code == 2
    check r.output.contains("uv")

suite "para art fix: the definitive empty state":
  test "an empty directory is 0 found, not silent success":
    let dir = testTmp / "fix_cli_empty"
    createDir(dir)
    let r = runArt(@["fix", dir])
    check r.code == 1
    check r.output.contains("fixed[0]{")
    check r.output.contains("fix: 0 assets found")
    removeDir(dir)

suite "para art fix: TOON shape and a real fix through the real uv subprocess":
  test "a forced --cell fix on an already-clean sprite is a no-op write, TOON-shaped":
    let dir = testTmp / "fix_cli_clean"
    createDir(dir)
    let png = dir / "hero.png"
    writeTinySprite(png, 64, 64)
    let outDir = testTmp / "fix_cli_clean_out"
    let r = runArt(@["fix", png, "--cell", "64x64", "--profile", "hibit", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains("fixed[1]{file,out,changed,size,cell,colors,semi_alpha_px,orphan,grid,key}:")
    check r.output.contains("  " & png & "," & outDir / "hero.png" & ",true,64x64,64x64,")
    check r.output.contains("fix: 1 written, 0 unchanged, 0 failed")
    check r.output.contains("help[2]:")
    check r.output.contains(png & ": it already has transparency, so no background was keyed; pass --key RRGGBB to force keying")
    check r.output.contains("para art lint " & outDir)
    check fileExists(outDir / "hero.png")

    # re-running on the same input writes nothing more: 0 pixels changed
    let r2 = runArt(@["fix", png, "--cell", "64x64", "--profile", "hibit", "--out", outDir])
    check r2.code == 0
    check r2.output.contains("fix: 0 written, 1 unchanged, 0 failed")
    removeDir(dir)
    removeDir(outDir)

  test "auto-detected grid recovery (no --cell) accepts content smaller than the profile's cell":
    let dir = testTmp / "fix_cli_auto"
    createDir(dir)
    let png = dir / "hero.png"
    writeTinySprite(png, 64, 64) # 32x32 content, under hibit's smallest 48px cell
    let outDir = testTmp / "fix_cli_auto_out"
    let r = runArt(@["fix", png, "--profile", "hibit", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains("fixed[1]{")
    removeDir(dir)
    removeDir(outDir)

  test "two assets with the same output name fail instead of overwriting each other":
    let dirA = testTmp / "fix_cli_dup_a"
    let dirB = testTmp / "fix_cli_dup_b"
    createDir(dirA)
    createDir(dirB)
    writeTinySprite(dirA / "hero.png", 64, 64)
    writeTinySprite(dirB / "hero.png", 64, 64)
    let outDir = testTmp / "fix_cli_dup_out"
    let r = runArt(@["fix", dirA, dirB, "--cell", "64x64", "--profile", "hibit", "--out", outDir])
    checkpoint r.output
    check r.code == 1
    check r.output.contains("fix: 1 written, 0 unchanged, 1 failed")
    check r.output.contains("collides with " & dirA / "hero.png")
    removeDir(dirA)
    removeDir(dirB)
    removeDir(outDir)

  test "a full-bleed opaque asset whose corners differ isn't keyed, with a --key hint":
    let dir = testTmp / "fix_cli_full_bleed"
    createDir(dir)
    let png = dir / "tile.png"
    var px = newSeq[byte](32 * 32 * 4)
    for i in 0 ..< 32 * 32:
      px[i * 4] = 120; px[i * 4 + 1] = 80; px[i * 4 + 2] = 40; px[i * 4 + 3] = 255
    px[0] = 250; px[1] = 250; px[2] = 250 # one corner is a frame highlight
    doAssert stbw.writePNG(png, 32, 32, stbw.RGBA, px)
    let outDir = testTmp / "fix_cli_full_bleed_out"
    let r = runArt(@["fix", png, "--cell", "32x32", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains(",\"skip:corners\"\n")
    check r.output.contains(png & ": its corners differ, so no background was keyed; pass --key RRGGBB")
    var w, h, ch: int
    let fixedPx = stbi.load(outDir / "tile.png", w, h, ch, stbi.RGBA)
    var transparent = 0
    for i in 0 ..< w * h:
      if fixedPx[i * 4 + 3] == 0: inc transparent
    check transparent == 0
    removeDir(dir)
    removeDir(outDir)

  test "--key keys an input with a semi-transparent pixel; without it, skip:alpha and a hint":
    let dir = testTmp / "fix_cli_semi_alpha"
    createDir(dir)
    let png = dir / "hero.png"
    var px = newSeq[byte](32 * 32 * 4)
    for y in 0 ..< 32:
      for x in 0 ..< 32:
        let i = (y * 32 + x) * 4
        let sprite = y in 12 ..< 24 and x in 10 ..< 22
        px[i] = (if sprite: 40 else: 0); px[i + 1] = (if sprite: 60 else: 255)
        px[i + 2] = (if sprite: 90 else: 0); px[i + 3] = 255
    px[(12 * 32 + 10) * 4 + 3] = 120 # one semi-transparent sprite-edge pixel
    doAssert stbw.writePNG(png, 32, 32, stbw.RGBA, px)
    let outDir = testTmp / "fix_cli_semi_alpha_out"
    proc transparentCount(): int =
      var w, h, ch: int
      let fixedPx = stbi.load(outDir / "hero.png", w, h, ch, stbi.RGBA)
      for i in 0 ..< w * h:
        if fixedPx[i * 4 + 3] == 0: inc result

    let skipped = runArt(@["fix", png, "--cell", "32x32", "--out", outDir])
    checkpoint skipped.output
    check skipped.code == 0
    check skipped.output.contains(",\"skip:alpha\"\n")
    check skipped.output.contains(png & ": it already has transparency, so no background was keyed; pass --key RRGGBB to force keying")
    check transparentCount() == 1

    let forced = runArt(@["fix", png, "--cell", "32x32", "--key", "00ff00", "--out", outDir])
    checkpoint forced.output
    check forced.code == 0
    check forced.output.contains(",00ff00\n")
    check not forced.output.contains("force keying")
    check transparentCount() == 32 * 32 - 12 * 12 + 1
    removeDir(dir)
    removeDir(outDir)

  test "--key-border-only is accepted and still fixes the sprite":
    let dir = testTmp / "fix_cli_border_only"
    createDir(dir)
    let png = dir / "hero.png"
    writeTinySprite(png, 64, 64)
    let outDir = testTmp / "fix_cli_border_only_out"
    let r = runArt(@["fix", png, "--cell", "64x64", "--key-border-only", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains("fix: 1 written, 0 unchanged, 0 failed")
    removeDir(dir)
    removeDir(outDir)

  test "a style.toml's palette is discovered and reported, same as lint":
    let dir = testTmp / "fix_cli_palette"
    createDir(dir)
    let png = dir / "hero.png"
    writeTinySprite(png, 64, 64)
    writeFile(dir / "style.toml", "profile = \"hibit\"\npalette = \"palette.hex\"\n")
    writeFile(dir / "palette.hex", "28323c\nffffff\n") # 28323c = (40,60,90), the sprite's own colour
    let outDir = testTmp / "fix_cli_palette_out"
    let r = runArt(@["fix", png, "--style", dir / "style.toml", "--cell", "64x64", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains("palette: " & dir / "palette.hex" & " (2 colours, every asset)")
    removeDir(dir)
    removeDir(outDir)

proc writeKeyedFigure(path: string; figH: int) =
  ## A 128x128 canvas on a 00ff00 key background, a two-tone figure 32 wide and
  ## `figH` rows tall standing 8 rows above the bottom edge.
  const w = 128
  var px = newSeq[byte](w * w * 4)
  for i in 0 ..< w * w:
    px[i * 4 + 1] = 255
    px[i * 4 + 3] = 255
  for y in w - 8 - figH ..< w - 8:
    for x in 48 ..< 80:
      let i = (y * w + x) * 4
      let top = y < w - 8 - figH div 2
      px[i] = if top: 40 else: 180
      px[i + 1] = 40
      px[i + 2] = if top: 180 else: 40
  doAssert stbw.writePNG(path, w, w, stbw.RGBA, px)

proc figureRows(path: string): tuple[w, h, gapBelow: int] =
  var w, h, ch: int
  let px = stbi.load(path, w, h, ch, stbi.RGBA)
  var y0 = h
  var y1 = -1
  for y in 0 ..< h:
    for x in 0 ..< w:
      if px[(y * w + x) * 4 + 3] > 0:
        y0 = min(y0, y)
        y1 = max(y1, y)
  (w, y1 - y0 + 1, h - 1 - y1)

suite "para art fix --cell: a multi-cell sheet is refused, not collapsed (#38)":
  test "a 192x64 sheet of three 64x64 cells exits 1 and writes nothing":
    let dir = testTmp / "fix_cli_sheet3"
    createDir(dir)
    let (w, h) = (192, 64)
    var px = newSeq[byte](w * h * 4)
    for c in 0 ..< 3:
      for y in 16 ..< 56:
        for x in c * 64 + 20 ..< c * 64 + 44:
          let i = (y * w + x) * 4
          px[i] = byte(60 + 40 * c); px[i + 1] = 90; px[i + 2] = 140; px[i + 3] = 255
    doAssert stbw.writePNG(dir / "sheet3.png", w, h, stbw.RGBA, px)
    let outDir = testTmp / "fix_cli_sheet3_out"
    let r = runArt(@["fix", dir / "sheet3.png", "--cell", "64x64", "--profile", "hibit", "--out", outDir])
    checkpoint r.output
    check r.code == 1
    check r.output.contains("3x1 grid of 64x64 cells")
    check not fileExists(outDir / "sheet3.png")
    removeDir(dir)
    removeDir(outDir)

suite "para art fix --fit content: one scale for a character's poses":
  test "poses fixed in one call share a scale and fill ~90% of the cell":
    let dir = testTmp / "fix_cli_fit"
    createDir(dir)
    writeKeyedFigure(dir / "tall.png", 80)
    writeKeyedFigure(dir / "short.png", 48)
    let outDir = testTmp / "fix_cli_fit_out"
    let r = runArt(@["fix", dir / "tall.png", dir / "short.png", "--cell", "32x48", "--fit", "content",
                      "--key", "00ff00", "--profile", "hibit", "--out", outDir])
    checkpoint r.output
    check r.code == 0
    check r.output.contains("fit: content, scale ")
    let tall = figureRows(outDir / "tall.png")
    let short = figureRows(outDir / "short.png")
    check tall.h == 43 # 90% of 48 rows, rounded: the tallest figure fills its box
    check short.h == 26 # 48/80 of it: the same scale, not its own fill
    check tall.gapBelow == short.gapBelow
    check tall.gapBelow > 0
    removeDir(dir)
    removeDir(outDir)

  test "--figure-height pins the tallest figure; one that cannot fit is a finding":
    let dir = testTmp / "fix_cli_fit_height"
    createDir(dir)
    writeKeyedFigure(dir / "tall.png", 80)
    let outDir = testTmp / "fix_cli_fit_height_out"
    let ok = runArt(@["fix", dir / "tall.png", "--cell", "32x48", "--fit", "content",
                       "--key", "00ff00", "--figure-height", "30", "--out", outDir])
    checkpoint ok.output
    check ok.code == 0
    check figureRows(outDir / "tall.png").h == 30
    let tooBig = runArt(@["fix", dir / "tall.png", "--cell", "32x48", "--fit", "content",
                           "--key", "00ff00", "--figure-height", "47", "--out", outDir])
    checkpoint tooBig.output
    check tooBig.code == 1
    check tooBig.output.contains("bigger than")
    removeDir(dir)
    removeDir(outDir)

removeDir(testTmp)
