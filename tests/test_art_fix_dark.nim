# GameLab batch 2's dark sprites through the real `para art fix` (uv subprocess)
# and `para art lint`, with the sidecar `fix` writes (no hand-written one):
# rogue_cultivator and corpse_puppet (dark robes, 96x96 cells) and core_medium
# (a dark cracked-magma core, 24x24) used to end `fix --outline` in
# refuse:interior-ink and fail lint's `outline` rule; their sources also kept
# stray key-green pixels that lint could not see. Sources: tests/fixtures/art/batch2/.

import unittest
import std/[options, os, strformat, strutils]
import stb_image/read as stbi
import stb_image/write as stbw
import tools/para/artcmd
import tools/para/art/[clihelpers, sidecar]

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art" / "batch2"
let testTmp = getTempDir() / ("paraloop_fix_dark_" & $getCurrentProcessId())

const sprites = [
  (name: "rogue_cultivator", cell: "96x96"),
  (name: "corpse_puppet", cell: "96x96"),
  (name: "core_medium", cell: "24x24"),
]

proc fix(name, cell, outDir: string): Run =
  runArt(@["fix", fixturesDir / (name & ".png"), "--cell", cell, "--profile", "hibit",
           "--key", "00ff00", "--fit", "content", "--outline", "--out", outDir])

proc keyPixels(png: string): int =
  ## Visible pixels within 40 (RGB) of 00ff00.
  var w, h, ch: int
  let px = stbi.load(png, w, h, ch, stbi.RGBA)
  for i in 0 ..< w * h:
    if px[i * 4 + 3] == 0: continue
    let r = px[i * 4].int
    let g = px[i * 4 + 1].int - 255
    let b = px[i * 4 + 2].int
    if r * r + g * g + b * b <= 1600: inc result

suite "para art fix: dark sprites outline, key pixels are stripped, the sidecar is written":
  createDir(testTmp)

  test "dark robes and a dark core outline with no refusal, and fix then lint passes":
    for s in sprites:
      let outDir = testTmp / s.name
      let r = fix(s.name, s.cell, outDir)
      checkpoint r.output
      check r.code == 0
      check "interior ink" notin r.output
      check "no outline step applied" notin r.output
      let lint = runArt(@["lint", outDir / (s.name & ".png")])
      checkpoint lint.output
      check lint.code == 0

  test "no key-coloured pixel survives, and fix reports how many it stripped":
    for s in sprites:
      let outDir = testTmp / ("key_" & s.name)
      let r = fix(s.name, s.cell, outDir)
      checkpoint r.output
      check keyPixels(outDir / (s.name & ".png")) == 0
      check "stray key-coloured pixel" in r.output

  test "the sidecar fix writes names the cell, profile, pivot and key":
    for s in sprites:
      let outDir = testTmp / ("sc_" & s.name)
      discard fix(s.name, s.cell, outDir)
      let sc = loadSidecar(outDir / (s.name & ".png"))
      check sc.isSome
      check &"{sc.get.cellW}x{sc.get.cellH}" == s.cell
      check sc.get.profile == "hibit"
      check sc.get.pivot == "bottom"
      check sc.get.key == "00ff00"

  test "lint fails `key` on a leaked key pixel painted back into the output":
    let outDir = testTmp / "leak"
    discard fix("core_medium", "24x24", outDir)
    let png = outDir / "core_medium.png"
    var w, h, ch: int
    var px = stbi.load(png, w, h, ch, stbi.RGBA)
    var i = 0
    while px[i * 4 + 3] == 0: inc i
    px[i * 4] = 0; px[i * 4 + 1] = 255; px[i * 4 + 2] = 0
    doAssert stbw.writePNG(png, w, h, stbw.RGBA, px)
    let lint = runArt(@["lint", png])
    checkpoint lint.output
    check lint.code == 1
    check "key" in lint.output
    check "key_leak:" in lint.output

  test "a rerun changes no sidecar, and a hand-written waiver survives it":
    let outDir = testTmp / "rerun"
    discard fix("core_medium", "24x24", outDir)
    let toml = outDir / "core_medium.art.toml"
    writeFile(toml, readFile(toml) & "\n[[waiver]]\nrule = \"colors\"\nreason = \"kept\"\n")
    let again = fix("core_medium", "24x24", outDir)
    checkpoint again.output
    check "sidecars: 0 written, 1 unchanged" in again.output
    check loadSidecar(outDir / "core_medium.png").get.waivers.len == 1

    # A stale cell is corrected, the waiver still kept.
    writeFile(toml, "cell_w = 8\ncell_h = 8\nprofile = \"lowbit\"\n\n[[waiver]]\nrule = \"colors\"\nreason = \"kept\"\n")
    let corrected = fix("core_medium", "24x24", outDir)
    checkpoint corrected.output
    check "sidecars: 1 written" in corrected.output
    let sc = loadSidecar(outDir / "core_medium.png").get
    check (sc.cellW, sc.cellH, sc.profile) == (24, 24, "hibit")
    check sc.waivers.len == 1

  test "fix rerun on its own output (keying skipped) keeps the sidecar's key":
    let outDir = testTmp / "own_output"
    discard fix("core_medium", "24x24", outDir)
    let png = outDir / "core_medium.png"
    check loadSidecar(png).get.key == "00ff00"
    let again = runArt(@["fix", png, "--cell", "24x24", "--profile", "hibit", "--out", outDir])
    checkpoint again.output
    check "skip:alpha" in again.output
    check "sidecars: 0 written, 1 unchanged" in again.output
    check loadSidecar(png).get.key == "00ff00"

  test "--key-border-only leaves the key out of the sidecar, so lint does not look for leaks":
    let outDir = testTmp / "border"
    let r = runArt(@["fix", fixturesDir / "core_medium.png", "--cell", "24x24", "--profile", "hibit",
                     "--key", "00ff00", "--key-border-only", "--out", outDir])
    checkpoint r.output
    check loadSidecar(outDir / "core_medium.png").get.key == ""

removeDir(testTmp)
