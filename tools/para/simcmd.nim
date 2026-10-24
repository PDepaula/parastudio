# `para sim`: runs a game headless through paraloop/sim, no window (engine
# report §5.3 rank 3). Two modes:
#
# - `--seed N --ticks N`: a fresh run of N ticks, reporting the game's state,
#   its entities by kind, per-tick sim time against the 1/60 s tick budget
#   and the state hash (the §5.3 sample's shape). The sample's `--autoplay`
#   is a scripted replay here: `--script FILE` / `--keys "..."` apply a
#   tick-indexed input script (paraloop/input's grammar, the same one `para
#   shot` takes) before each tick; with none, no input is held. `--ticks`
#   defaults to the script's last event.
# - `--from tmp/bugs/<stamp>`: replays an F9 bug capture and reports whether
#   it still reaches the captured state hash (engine report §4.4 "Reproduce
#   what the captain saw").
#
# `--budget-ms X` overrides the p99 tick budget (default the 1/60 s tick) and
# turns an overrun into exit 1; `--trace N` prints the facts hash every N ticks.
# Anything else about a particular game -- a starting treasure, a gate on what
# the run reached, a room to start in -- is a flag its driver adds
# (gamedriver.nim): the loop here never names a game. `hello` is linked into
# para; another game with a `tools/<name>_driver.nim` is built and run by
# driverexec.nim, which hands it this command line unchanged.

import std/[options, os, strutils, strformat, tables, algorithm, monotimes, times, sequtils, math]
import art/[clihelpers, toon]
import paraloop/app
import paraloop/input
import paraloop/dev
import games
import gamedriver
import driverexec
import linked
import replayopts

type Run = clihelpers.Run

proc readReplayMeta(dir: string): Table[string, string] =
  ## `replay.txt`'s `key: value` lines (paraloop/dev.writeBugCapture's shape).
  for line in readFile(dir / "replay.txt").splitLines:
    if line.len > 0:
      let kv = line.split(": ", 1)
      if kv.len == 2:
        result[kv[0]] = kv[1]

proc simHelp*(driver: SimDriver): string =
  "para sim [--game NAME] --seed N --ticks N [--script FILE | --keys SCRIPT]\n" &
  "         [--budget-ms X] [--trace N]" & driver.flags.mapIt(" [" & it.flag & (if it.arg.len > 0: " " & it.arg else: "") & "]").join & "\n" &
  "para sim [--game NAME] --from DIR\n" &
  "  --seed/--ticks: a fresh headless run; prints state, entities by kind, sim time per tick\n" &
  "    against the 16.7ms budget, the state hash and the facts hash (the state hash without\n" &
  "    the pending rule names, so it survives adding a rule)\n" &
  "  --trace N: also print the facts hash every N ticks (a table of tick, facts), to compare a\n" &
  "    change against main tick by tick\n" &
  "  --script FILE | --keys \"60:enter,300:right:15\": tick-indexed input applied before each tick\n" &
  "    (paraloop/input's script grammar, the file `para shot --script` takes; `frame` lines are\n" &
  "    ignored here); with neither, no input is held and --ticks is required, with one it\n" &
  "    defaults to the script's last event\n" &
  "  --budget-ms X: gate the run (exit 1 on a miss): p99 tick time under X ms (default the 16.667ms tick)\n" &
  driver.flags.flagHelp &
  "  --from: replays an F9 bug capture (paraloop/dev's module doc), reports the state hash\n" &
  "  games: hello (linked into para), and any game with a games/<name>/tools/<name>_driver.nim\n"

proc gameTime(ticks: int): string =
  let secs = int(float(ticks) * fixedDt)
  &"{secs div 60:02}:{secs mod 60:02}"

proc ms(d: Duration): string =
  formatFloat(d.inNanoseconds.float / 1e6, ffDecimal, 3) & "ms"

type Gate = object
  budgetMs: float
  trace: int ## print the facts hash every this many ticks; 0 = off

proc headlessResult(game: Game, seed: int64, ticks: int, replay: ReplayScript, gate: Gate,
                    run: SimRun): Run =
  engineKeys = newKeyState()
  let keys = newReplay(replay.script)
  var stepTimes: seq[Duration]
  var traceRows: seq[seq[string]]
  let started = getMonoTime()
  for tick in 1 .. ticks:
    input.step(keys, engineKeys, tick)
    if not run.beforeTick.isNil: run.beforeTick()
    let t0 = getMonoTime()
    run.step(tick)
    stepTimes.add getMonoTime() - t0
    if not run.afterTick.isNil: run.afterTick()
    if gate.trace > 0 and tick mod gate.trace == 0:
      traceRows.add @[$tick, run.factsHash()]
  let elapsed = (getMonoTime() - started).inMilliseconds.float / 1000

  var rows: seq[seq[string]]
  for kind, count in run.kinds():
    rows.add @[kind, $count]
  rows.sort(proc (a, b: seq[string]): int = cmp(a[0], b[0]))

  stepTimes.sort()
  let p50 = stepTimes[(stepTimes.len - 1) div 2]
  let p99 = stepTimes[(stepTimes.len - 1) * 99 div 100]
  let budget =
    if gate.budgetMs > 0: initDuration(nanoseconds = int64(gate.budgetMs * 1e6))
    else: initDuration(nanoseconds = int64(fixedDt * 1e9))
  let (x, y) = run.pos()

  result.output.add &"run: {ticks} ticks ({gameTime(ticks)} game time) in {elapsed:.1f}s, seed {seed}\n"
  if replay.source.len > 0:
    let fired = replay.script.events.filterIt(it.tick <= ticks).len
    result.output.add &"input: script {replay.source}, {fired} of {replay.script.events.len} key events fired\n"
  result.output.add &"state: x={x} y={y}\n"
  result.output.add toonTable("entities", ["kind", "count"], rows)
  result.output.add &"perf: sim p50 {ms(p50)} p99 {ms(p99)} (budget {ms(budget)})"
  if p99 > budget:
    result.output.add " OVER BUDGET\n"
    result.code = 1
  else:
    result.output.add "\n"
  if not run.report.isNil:
    let r = run.report()
    result.output.add r.text
    if r.failed: result.code = 1
  result.output.add &"hash: {run.stateHash()}\n"
  result.output.add &"facts-hash: {run.factsHash()}\n"
  if gate.trace > 0:
    result.output.add toonTable("trace", ["tick", "facts"], traceRows)
  result.output.add toonHelp(@[
    &"Run `para sim --game {game.name} --from tmp/bugs/<stamp>` to replay an F9 bug capture"])

proc replayResult(game: Game, fromDir: string, fromTick, ticks: int,
                  meta: Table[string, string], input: seq[KeyState],
                  driver: SimDriver): Run =
  var run: SimRun
  try:
    run = driver.restore(fromDir)
  except IOError, OSError, ValueError:
    return errorOut("cannot read " & fromDir / "snapshot.json: " & getCurrentExceptionMsg(), @[])

  engineKeys = input[0]
  for i in 1 ..< input.len:
    engineKeys = input[i]
    run.step(fromTick + i)

  let replayedHash = run.stateHash()
  let recordedHash = meta["hash"]

  result.output.add &"run: replayed {ticks} ticks (tick {fromTick} -> {fromTick + ticks}) " &
    &"via {game.dir}, seed {meta[\"seed\"]}\n"
  if replayedHash == recordedHash:
    result.output.add &"state: hash matches ({replayedHash})\n"
    result.code = 0
  else:
    result.output.add &"state: hash MISMATCH (got {replayedHash}, capture recorded {recordedHash})\n"
    result.output.add toonHelp(@["The replay no longer reaches the captured state -- behavior changed since capture"])
    result.code = 1

proc runReplay(game: Game, fromDir: string, driver: SimDriver): Run =
  if not dirExists(fromDir):
    return errorOut(fromDir & ": no such directory", @[])
  for f in ["snapshot.json", "input.txt", "replay.txt"]:
    if not fileExists(fromDir / f):
      return errorOut(fromDir / f & " missing -- not a bug capture directory " &
        "(expected snapshot.json, input.txt, replay.txt; see paraloop/dev's F9 capture)", @[])

  let meta = readReplayMeta(fromDir)
  for key in ["seed", "from", "ticks", "hash"]:
    if key notin meta:
      return errorOut(fromDir / "replay.txt: missing \"" & key & ": ...\" line", @[])

  var fromTick, ticks: int
  try:
    fromTick = meta["from"].parseInt
    ticks = meta["ticks"].parseInt
  except ValueError:
    return errorOut(fromDir / "replay.txt: " & getCurrentExceptionMsg(), @[])

  var input: seq[KeyState]
  try:
    input = readBugInput(fromDir)
  except IOError, OSError, ValueError:
    return errorOut("cannot read " & fromDir / "input.txt: " & getCurrentExceptionMsg(), @[])
  if input.len != ticks + 1:
    return errorOut(&"{fromDir}/input.txt has {input.len} lines, replay.txt says " &
      &"ticks: {ticks} (expected {ticks + 1})", @[])

  replayResult(game, fromDir, fromTick, ticks, meta, input, driver)

proc runSimWith*(args: seq[string], driver: SimDriver, ownGame = defaultGame): Run =
  ## `para sim` over `driver`'s game: parses the flags the command and the driver share, then
  ## runs. A game's own binary (`driverMain`) calls this with the command line it was handed
  ## and its own name as `ownGame`, the game a `--game`-less command line runs.
  var fromDir = ""
  var gameName = ownGame
  var seedText, ticksText = ""
  var scriptFile, keysText = ""
  var gate = Gate()
  var extras: Extras
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (simHelp(driver), 0)
    of "--from":
      inc i
      if i >= args.len: return errorOut("--from needs a directory", @[])
      fromDir = args[i]
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      gameName = args[i]
    of "--seed":
      inc i
      if i >= args.len: return errorOut("--seed needs a number", @[])
      seedText = args[i]
    of "--ticks":
      inc i
      if i >= args.len: return errorOut("--ticks needs a number", @[])
      ticksText = args[i]
    of "--script":
      inc i
      if i >= args.len: return errorOut("--script needs a file", @[])
      scriptFile = args[i]
    of "--keys":
      inc i
      if i >= args.len: return errorOut("--keys needs a script, e.g. \"60:enter,300:right:15\"", @[])
      keysText = args[i]
    of "--trace":
      inc i
      if i >= args.len: return errorOut("--trace needs a number of ticks", @[])
      try:
        gate.trace = args[i].parseInt
        if gate.trace < 1: raise newException(ValueError, "below 1")
      except ValueError:
        return errorOut(&"--trace takes a whole number of ticks of 1 or more, got \"{args[i]}\"", @[])
    of "--budget-ms":
      inc i
      if i >= args.len: return errorOut("--budget-ms needs a number of milliseconds", @[])
      try:
        gate.budgetMs = args[i].parseFloat
      except ValueError:
        return errorOut(&"--budget-ms takes a number, got \"{args[i]}\"", @[])
      if not (gate.budgetMs > 0 and gate.budgetMs < Inf):
        return errorOut(&"--budget-ms must be above 0, got \"{args[i]}\"", @[])
    else:
      var bad: Run
      if driver.flags.takeExtra(args, i, extras, bad):
        if bad.code != 0: return bad
      else:
        return errorOut(&"unknown flag \"{a}\"",
          @["Valid flags: --game NAME, --seed N, --ticks N, --script FILE, --keys SCRIPT, --from DIR, --budget-ms X, --trace N" &
            driver.flags.mapIt(", " & it.flag & (if it.arg.len > 0: " " & it.arg else: "")).join])
    inc i

  var game: Game
  let notFound = resolveGame(gameName, game)
  if notFound.code != 0: return notFound
  if not driver.prepare.isNil:
    let bad = driver.prepare(extras)
    if bad.len > 0: return errorOut(bad, @[])

  if fromDir.len > 0:
    if seedText.len > 0 or ticksText.len > 0 or scriptFile.len > 0 or keysText.len > 0 or
        gate.budgetMs > 0 or gate.trace > 0 or extras.len > 0:
      return errorOut("--from replays a capture's own seed, ticks and input; drop --seed/--ticks/--script/--keys, --trace, --budget-ms and the game's flags", @[])
    return runReplay(game, fromDir, driver)

  var replay: ReplayScript
  let badScript = loadReplayScript(scriptFile, keysText, replay)
  if badScript.code != 0: return badScript

  if ticksText.len == 0 and replay.script.maxTick == 0:
    return errorOut("no --ticks or --from given",
      @[&"Run `para sim --game {game.name} --seed 7 --ticks 3600` for a headless run",
        &"Run `para sim --game {game.name} --from tmp/bugs/<stamp>` to replay an F9 bug capture"])
  var seed: int64
  var ticks: int
  try:
    let implied = if driver.defaultSeed.isNil: none(int64) else: driver.defaultSeed()
    seed = if seedText.len > 0: seedText.parseBiggestInt.int64
           elif implied.isSome: implied.get
           else: 0'i64
    ticks = if ticksText.len > 0: ticksText.parseInt else: replay.script.maxTick
  except ValueError:
    return errorOut("--seed and --ticks take whole numbers: " & getCurrentExceptionMsg(), @[])
  if ticks < 1:
    return errorOut(&"--ticks must be at least 1 (got {ticks})", @[])
  headlessResult(game, seed, ticks, replay, gate, driver.newRun(seed))

proc runSim*(args: seq[string]): Run =
  ## `para sim`: a linked game's driver runs in process; any other game that ships a driver
  ## program gets this command line (see driverexec.nim).
  let gameName = gameFlag(args)
  let linkedDriver = linkedSim(gameName)
  if linkedDriver.isSome:
    return runSimWith(args, linkedDriver.get)
  runGameDriver(gameName, "sim", args)
