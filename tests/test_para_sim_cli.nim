# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Tests for `para sim` (task 1.8), on hello (the game linked into para) so they hold with games/ absent;
# the game-specific half is the game's own (games/<game>/tests/, its driver's sim tests): a fresh headless `--seed/--ticks` run, and
# `--from`, replaying an F9 bug capture through paraloop/sim and reporting
# the state hash. Generates its own bug captures headlessly the same way
# tests/test_dev.nim's F9 suite does (scripted input, no window) -- no
# GL/display needed.

import std/unittest except test
import std/[os, strutils, sequtils, hashes]
import paraloop/app
import paraloop/input
import paraloop/dev
import paraloop/sim
import paraloop/testkit
import examples/hello/hello
import tools/para/art/clihelpers
import tools/para/simcmd
import tools/para/hellodriver

const tmpDir = currentSourcePath().parentDir.parentDir / "tmp"

proc captureHelloBug(root: string, script: string, lastTick: int): tuple[dir: string, hash: Hash] =
  ## Runs `hello` through a script that ends in `f9`, into its own root (so a
  ## `walkDirs` glob over it sees exactly the one stamped capture
  ## `writeBugCapture` names), and returns that directory plus the live sim's
  ## state hash at the moment F9 fired.
  removeDir(root)
  createDir(root)
  bugRoot = root
  defer: bugRoot = "tmp" / "bugs"
  engineKeys = newKeyState()
  var game = initHelloGame()
  let replay = newReplay(parseScript(script))
  for tick in 1 .. lastTick:
    step(replay, engineKeys, tick)
    game.stepTick(tick)
  let dirs = toSeq(walkDirs(root / "*"))
  doAssert dirs.len == 1, "expected exactly one bug capture under " & root
  (dirs[0], game.sim.stateHash())

suite "para sim: flag and directory validation":
  test "--help prints usage, exit 0":
    let r = runSim(@["--help"])
    check r.code == 0
    check r.output.startsWith("para sim")
    check r.output.contains("--script FILE | --keys")

  test "neither --ticks nor --from is a usage error naming both":
    let r = runSim(@[])
    check r.code == 2
    check r.output.startsWith("error:")
    check r.output.contains("--ticks")
    check r.output.contains("--from")

  test "an unknown --game is a usage error listing the valid games":
    let r = runSim(@["--from", tmpDir, "--game", "nope"])
    check r.code == 2
    check r.output.startsWith("error: unknown game \"nope\"")
    # substring, not exact match: task 1.9's `para new` can leave other
    # games registered alongside hello (e.g. a CI run's games/ci_smoke)
    check r.output.contains("Valid games:")
    check r.output.contains("hello")

  test "a driver's own game is what a --game-less command line runs":
    let own = runSimWith(@["--ticks", "10"], helloSimDriver(), "nope")
    check own.code == 2
    check own.output.startsWith("error: unknown game \"nope\"")
    let named = runSimWith(@["--ticks", "10", "--game", "hello"], helloSimDriver(), "nope")
    check named.code == 0

  test "--autoplay fails loud, it is not silently ignored":
    check runSim(@["--ticks", "10", "--autoplay"]).code == 2

  test "a bad script, an unreadable --script, or both script flags are usage errors":
    let bad = runSim(@["--ticks", "10", "--keys", "5:nokey"])
    check bad.code == 2
    check bad.output.contains("input script item 1 (5:nokey)")
    check runSim(@["--ticks", "10", "--script", tmpDir / "test-sim-no-such.script"]).code == 2
    check runSim(@["--ticks", "10", "--keys", "5:right", "--script", "x"]).code == 2
    check runSim(@["--script"]).code == 2
    check runSim(@["--keys"]).code == 2

  test "--from replays a capture's own input: --script/--keys are a usage error":
    check runSim(@["--from", tmpDir, "--keys", "5:right"]).code == 2

  test "--from with --seed/--ticks, or a non-numeric/zero --ticks, is a usage error":
    check runSim(@["--from", tmpDir, "--ticks", "10"]).code == 2
    check runSim(@["--ticks", "ten"]).code == 2
    check runSim(@["--ticks", "0"]).code == 2

  test "a directory that doesn't exist is a usage error":
    let r = runSim(@["--from", tmpDir / "test-sim-no-such-dir"])
    check r.code == 2
    check r.output.contains("no such directory")

  test "a directory missing snapshot.json/input.txt/replay.txt is a usage error, not a crash":
    let dir = tmpDir / "test-sim-not-a-capture"
    createDir(dir)
    let r = runSim(@["--from", dir])
    check r.code == 2
    check r.output.contains("not a bug capture directory")
    removeDir(dir)

suite "para sim --seed/--ticks: a fresh headless run":
  test "reports run, state, entities, perf against the budget and the hash, exit 0":
    let r = runSim(@["--game", "hello", "--seed", "7", "--ticks", "120"])
    check r.code == 0
    check r.output.contains("run: 120 ticks (00:02 game time) in ")
    check r.output.contains(", seed 7\n")
    check r.output.contains("state: x=0 y=0\n")
    check r.output.contains("entities[1]{kind,count}:\n  Player,1\n")
    check r.output.contains("(budget 16.667ms)\n")
    var game = initHelloGame()
    game.sim = initSim(newHelloSession(), seed = 7'i64, idType = HelloId)
    engineKeys = newKeyState()
    for tick in 1 .. 120: game.stepTick(tick)
    check r.output.contains("hash: " & $game.sim.stateHash() & "\n")

  test "the same seed and ticks give the same hash":
    let a = runSim(@["--seed", "3", "--ticks", "30"])
    let b = runSim(@["--seed", "3", "--ticks", "30"])
    check a.output.splitLines.filterIt(it.startsWith("hash:")) ==
      b.output.splitLines.filterIt(it.startsWith("hash:"))

proc hashLine(r: Run): string =
  r.output.splitLines.filterIt(it.startsWith("hash:")).join

suite "para sim: the facts hash and --trace":
  test "a run prints the facts hash beside the state hash":
    let r = runSim(@["--game", "hello", "--seed", "7", "--ticks", "60"])
    check r.code == 0
    var game = initHelloGame()
    game.sim = initSim(newHelloSession(), seed = 7'i64, idType = HelloId)
    engineKeys = newKeyState()
    for tick in 1 .. 60: game.stepTick(tick)
    check r.output.contains("hash: " & $game.sim.stateHash() & "\n")
    check r.output.contains("facts-hash: " & $game.sim.factsHash() & "\n")
    check not r.output.contains("trace[")

  test "--trace N prints the facts hash every N ticks, the last row matching facts-hash":
    let r = runSim(@["--game", "hello", "--seed", "7", "--ticks", "60", "--trace", "20"])
    check r.code == 0
    check r.output.contains("trace[3]{tick,facts}:\n")
    var game = initHelloGame()
    game.sim = initSim(newHelloSession(), seed = 7'i64, idType = HelloId)
    engineKeys = newKeyState()
    var want: seq[string]
    for tick in 1 .. 60:
      game.stepTick(tick)
      if tick mod 20 == 0:
        want.add "  " & $tick & "," & $game.sim.factsHash() & "\n"
    check want.len == 3
    for row in want:
      check r.output.contains(row)
    check r.output.contains("facts-hash: " & $game.sim.factsHash() & "\n")
    # tracing prints; it does not change the run
    check hashLine(r) == hashLine(runSim(@["--game", "hello", "--seed", "7", "--ticks", "60"]))

  test "--trace takes a whole number of ticks of 1 or more, and not with --from":
    for bad in ["0", "-3", "ten", "1.5"]:
      let r = runSim(@["--ticks", "10", "--trace", bad])
      check r.code == 2
      check r.output.contains("--trace takes a whole number")
    check runSim(@["--ticks", "10", "--trace"]).code == 2
    let r = runSim(@["--from", tmpDir, "--trace", "5"])
    check r.code == 2
    check r.output.contains("--trace")

suite "para sim --script/--keys: a scripted headless run":
  const script = "10:right:50,70:down:30,110:c"

  test "hello walks the script: right 50 ticks then down 30":
    let r = runSim(@["--game", "hello", "--seed", "7", "--ticks", "120", "--keys", "10:right:50,70:down:30"])
    check r.code == 0
    check r.output.contains("input: script --keys, 4 of 4 key events fired\n")
    check r.output.contains("state: x=" & $(50 * hello.moveSpeed) & " y=" & $(30 * hello.moveSpeed) & "\n")

  test "ticks default to the script's last event; --ticks overrides it":
    let r = runSim(@["--game", "hello", "--keys", "10:right:5"])
    check r.code == 0
    check r.output.contains("run: 15 ticks")
    let shorter = runSim(@["--game", "hello", "--keys", "10:right:5", "--ticks", "12"])
    check shorter.output.contains("run: 12 ticks")
    check shorter.output.contains("input: script --keys, 1 of 2 key events fired\n")

suite "para sim --from: a real F9 capture replays to the recorded hash":
  test "the reported hash matches a freshly captured bug, exit 0":
    let root = tmpDir / "test-sim-cli-ok-root"
    let (dir, liveHash) = captureHelloBug(root, "5:right:10,20:up:3,30:f9", 30)
    let r = runSim(@["--from", dir])
    check r.code == 0
    check r.output.contains("state: hash matches")
    check r.output.contains($liveHash)
    removeDir(root)

  test "a tampered replay.txt hash is a mismatch, exit 1, never a false pass":
    let root = tmpDir / "test-sim-cli-mismatch-root"
    let (dir, _) = captureHelloBug(root, "3:right:5,10:f9", 10)
    let meta = readFile(dir / "replay.txt")
    writeFile(dir / "replay.txt", meta.replace("hash: ", "hash: X999999_"))
    let r = runSim(@["--from", dir])
    check r.code == 1
    check r.output.contains("hash MISMATCH")
    removeDir(root)

suite "para sim: a game's own flags are its driver's":
  test "hello has none of another game's flags":
    for flag in [@["--hub"], @["--keep-alive"], @["--hold-mobs", "5"], @["--treasure", "SealingStamp"],
                 @["--room", "den"], @["--profile", "x.json"], @["--min-smashes", "1"], @["--min-mobs", "1"]]:
      let r = runSim(@["--game", "hello", "--ticks", "10"] & flag)
      check r.code == 2
      check r.output.contains("unknown flag")

  test "bad --budget-ms values are usage errors, and not with --from":
    check runSim(@["--ticks", "10", "--budget-ms", "0"]).code == 2
    check runSim(@["--ticks", "10", "--budget-ms", "nan"]).code == 2
    check runSim(@["--ticks", "10", "--budget-ms", "inf"]).code == 2
    check runSim(@["--from", tmpDir, "--budget-ms", "5"]).code == 2
