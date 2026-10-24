# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Tests for the scripted-replay flags of `para shot` (and the pieces it
# shares with `para sim`): the `--script`/`--keys` loader, `--seed`/`--size`
# parsing, the frame forms (`NAME=N`, `NAME=@Phase`, script-named frames),
# on hello (the game linked into para), so they hold with games/ absent; the
# game-specific half lives in each game's own tests/ (its driver's shot tests).

import std/[unittest, os, strutils, sequtils, algorithm]
import tools/para/shotcmd
import tools/para/replayopts
import tools/para/games
import tools/para/art/clihelpers
import paraloop/input
import stb_image/write as stbw

const tmpDir = currentSourcePath().parentDir.parentDir / "tmp" / "test-para-shot-script"

suite "replayopts: script files and flags":
  test "a script file takes comments, one item list per line, and frame lines":
    createDir(tmpDir)
    let path = tmpDir / "walk.script"
    writeFile(path, "# walk right, then down\n10:right:60,\n80:down:40  # a hold\n\nframe walked=200\nframe lvl=@LevelUp\n")
    var replay: ReplayScript
    check loadReplayScript(path, "", replay).code == 0
    check replay.source == path
    check replay.script.maxTick == 120
    check replay.script.events == parseScript("10:right:60,80:down:40").events
    check replay.frames == @[("walked", "200"), ("lvl", "@LevelUp")]

  test "--keys takes the bare parseScript string; no flag is the empty script":
    var replay: ReplayScript
    check loadReplayScript("", "60:enter,300:d:15", replay).code == 0
    check replay.script == parseScript("60:enter,300:d:15")
    check replay.source == "--keys"
    check loadReplayScript("", "", replay).code == 0
    check replay.script.events.len == 0
    check replay.source == ""

  test "a bad script, an unreadable file, both flags or a bad frame line are usage errors":
    var replay: ReplayScript
    let bad = loadReplayScript("", "60:nokey", replay)
    check bad.code == 2
    check bad.output.contains("input script item 1 (60:nokey)")
    let missing = loadReplayScript(tmpDir / "no-such.script", "", replay)
    check missing.code == 2
    check missing.output.contains("cannot read script")
    check loadReplayScript(tmpDir / "walk.script", "60:enter", replay).code == 2
    writeFile(tmpDir / "badframe.script", "10:right\nframe nope\n")
    let badFrame = loadReplayScript(tmpDir / "badframe.script", "", replay)
    check badFrame.code == 2
    check badFrame.output.contains("bad frame line \"frame nope\"")
    for reserved in ["title=100", "t600=@LevelUp", "t5=100"]:
      writeFile(tmpDir / "reserved.script", "10:right\nframe " & reserved & "\n")
      let r = loadReplayScript(tmpDir / "reserved.script", "", replay)
      check r.code == 2
      check r.output.contains("bad frame line \"frame " & reserved & "\"")
    writeFile(tmpDir / "dup.script", "frame a=1\nframe a=2\n")
    let dup = loadReplayScript(tmpDir / "dup.script", "", replay)
    check dup.code == 2
    check dup.output.contains("frame \"a\" is named twice")

  test "--seed and --size":
    var seed: int64
    check parseSeedFlag("7", seed).code == 0
    check seed == 7
    check parseSeedFlag("seven", seed).code == 2
    var size: tuple[width, height: int]
    check parseSizeFlag("960x540", size).code == 0
    check size == (960, 540)
    check parseSizeFlag("960X540", size).code == 0
    for bad in ["960", "960x", "x540", "0x540", "960x540x2", "axb", "99999x10"]:
      check parseSizeFlag(bad, size).code == 2

suite "para shot: frame forms and flag validation (before any window opens)":
  test "NAME=N is a fixed tick and NAME=@Phase a pin, mixed with title and t<N>":
    var frames: seq[Frame]
    var pins: seq[PhasePin]
    check parseFrames("title,mid=900,boss=@Tribulation,t30", frames, pins).code == 0
    check frames == @[("title", 0), ("mid", 900), ("boss", unresolvedTick), ("t30", 30)]
    check pins == @[("boss", "Tribulation")]

  test "a bare name is looked up among a script's named frames":
    var frames: seq[Frame]
    var pins: seq[PhasePin]
    let named = @[("walked", "200"), ("lvl", "@LevelUp")]
    check parseFrames("walked,lvl", frames, pins, named).code == 0
    check frames == @[("walked", 200), ("lvl", unresolvedTick)]
    check pins == @[("lvl", "LevelUp")]
    let r = parseFrames("later", frames, pins, named)
    check r.code == 2
    check r.output.contains("unknown frame \"later\"")
    check r.output.contains("This script names: walked, lvl")

  test "bad frame names, phases and duplicates are usage errors":
    var frames: seq[Frame]
    var pins: seq[PhasePin]
    for bad in ["title=5", "t5=9", "a b=5", "=5", "x=", "x=@", "x=@Lev el", "x=oops", "t5,t5", "a=1,a=2"]:
      check parseFrames(bad, frames, pins).code == 2
    # the fixed-tick overload has nowhere to return a pin
    check parseFrames("x=@LevelUp", frames).code == 2

  test "the replay flags need values and validate them":
    check runShot(@["--script"]).code == 2
    check runShot(@["--keys"]).code == 2
    check runShot(@["--seed"]).code == 2
    check runShot(@["--seed", "x"]).code == 2
    check runShot(@["--size", "big"]).code == 2
    check runShot(@["--max-ticks", "0"]).code == 2
    check runShot(@["--keys", "60:nokey"]).code == 2
    check runShot(@["--script", tmpDir / "no-such.script"]).code == 2
    check runShot(@["--keys", "5:right", "--script", tmpDir / "walk.script"]).code == 2

  test "a phase pin on a game with no phases is a usage error, not a silent miss":
    let r = runShot(@["--game", "hello", "--at", "x=@LevelUp"])
    check r.code == 2
    check r.output.contains("hello has no phases")

  test "a flag only another game's driver has is unknown for hello":
    for flag in [@["--title"], @["--hub"], @["--profile", "tmp/no-such-profile.json"]]:
      let r = runShot(@["--game", "hello"] & flag)
      check r.code == 2
      check r.output.contains("unknown flag")
    check runShot(@["--profile"]).code == 2

  test "--fixtures is a game's: hello has none":
    check runShot(@["--fixtures"]).code == 2
    let hello = runShot(@["--game", "hello", "--fixtures", tmpDir])
    check hello.code == 2
    check hello.output.contains("hello has none")
    check runShot(@["--help"]).output.contains("--fixtures")

  test "the tolerance flags need a whole number in range and loosen only --check":
    check runShot(@["--tolerance"]).code == 2
    check runShot(@["--max-diff-px"]).code == 2
    for bad in ["x", "-1", "256", "1.5"]:
      check runShot(@["--tolerance", bad, "--check"]).code == 2
    check runShot(@["--max-diff-px", "-1", "--check"]).code == 2
    let alone = runShot(@["--game", "hello", "--tolerance", "2"])
    check alone.code == 2
    check alone.output.contains("pass --check too")
    check runShot(@["--game", "hello", "--max-diff-px", "5", "--update-golden", "title"]).code == 2

  test "--help documents the replay and tolerance flags":
    let h = runShot(@["--help"]).output
    for flag in ["--script", "--keys", "--seed", "--size", "--max-ticks", "@Phase",
                 "--tolerance", "--max-diff-px"]:
      check h.contains(flag)

suite "para shot: comparing frames with a tolerance":
  proc image(w, h: int, pixel: array[4, byte]): Image =
    result = Image(w: w, h: h, pixels: newSeq[byte](w * h * 4))
    for i in 0 ..< w * h:
      for c in 0 .. 3: result.pixels[i * 4 + c] = pixel[c]

  test "tolerance 0 is exact: one channel one step off is a changed pixel":
    var a = image(4, 4, [10'u8, 20, 30, 255])
    let b = a
    check diffPixelCount(a, b) == 0
    a.pixels[5] += 1 # pixel 1, green
    check diffPixelCount(a, b) == 1
    check diffPixelCount(a, b, 0) == 1

  test "a pixel is changed only when some channel is off by more than the tolerance":
    var a = image(4, 4, [10'u8, 20, 30, 255])
    let b = a
    a.pixels[0] += 2  # pixel 0: red off by 2
    a.pixels[6] += 1  # pixel 1: blue off by 1
    a.pixels[11] -= 3 # pixel 2: alpha off by 3
    check diffPixelCount(a, b, 0) == 3
    check diffPixelCount(a, b, 1) == 2
    check diffPixelCount(a, b, 2) == 1
    check diffPixelCount(a, b, 3) == 0

  test "a size mismatch is -1 whatever the tolerance":
    check diffPixelCount(image(4, 4, [0'u8, 0, 0, 255]), image(4, 2, [0'u8, 0, 0, 255]), 255) == -1

  test "the diff image marks only the pixels beyond the tolerance":
    var a = image(2, 1, [90'u8, 90, 90, 255])
    let b = a
    a.pixels[0] += 1 # pixel 0 off by 1
    a.pixels[4] += 5 # pixel 1 off by 5
    createDir(tmpDir)
    let path = tmpDir / "diff-tolerance.png"
    writeDiffPng(a, b, path, tolerance = 2)
    let d = decodePng(path)
    check d.pixels[0 .. 3] == @[30'u8, 30, 30, 255] # within tolerance: dimmed golden
    check d.pixels[4 .. 7] == @[255'u8, 0, 0, 255] # beyond: red
