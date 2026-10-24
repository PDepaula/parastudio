# `para check`: the one command a producer runs before saving a game. It runs
# the game's own tests (`para test --filter games/<game>/ --skip-balance`, the trailing slash
# anchors the filter to that directory) and `para build --game <game>`, prints
# one pass/fail line per step and one verdict, and exits 0 only when both
# passed. It never runs the full suite, goldens, web smoke, balance or a push.
# On a pass it writes the stamp `para save` looks for (savepoint.nim).
#
# `--lane ID` checks a helper's lane (`games/<game>.<id>/`, lanecmd.nim) instead: the same two
# steps on the lane's folder (each step is handed `<game>.<id>` in place of the game's name). It is
# a rehearsal the checker runs before the lane lands, so it writes no stamp: only a check of the
# game itself, after the landing, lets `para save` save.
#
# Both steps run in this process, so `runCheck` must be run from the repo
# root, like `para test`. `runCheckWith` takes the steps as procs so tests
# need no compiler.

import std/[os, strformat, strutils]
import art/[clihelpers, toon]
import savepoint
import testcmd
import buildcmd

type
  Run = clihelpers.Run
  CheckStep* = tuple[name: string, run: proc (game: string): Run]

const checkHelp* = "para check [--game NAME] [--lane ID]\n" &
  "  runs the game's tests (para test --filter games/<game>/ --skip-balance) and builds it (para build --game <game>),\n" &
  "  then prints one pass/fail line per step and a verdict; exit 0 when both passed, 1 when not\n" &
  "  --game NAME  the game under games/; left out, the only game with a PLAN.md\n" &
  "  --lane ID    check a helper's lane of the game (games/<game>.<id>/, `para lane`) instead; it writes\n" &
  "               no pass for `para save`: land the lane, then check the game\n" &
  "  a pass is what lets `para save` save the game as it is now; any later edit needs a new check\n" &
  "  never runs the full suite, goldens, web smoke, balance or a push\n"

proc testArgs*(game: string): seq[string] =
  @["--filter", gamePrefix(game), "--skip-balance"]

proc buildArgs*(game: string): seq[string] =
  ## `game` is a game's name, or `<game>.<id>` for a lane.
  let dot = game.find('.')
  if dot < 0: @["--game", game] else: @["--game", game[0 ..< dot], "--lane", game[dot + 1 .. ^1]]

proc realSteps*(): seq[CheckStep] =
  @[("tests", proc (game: string): Run = runTest(testArgs(game))),
    ("build", proc (game: string): Run = runBuild(buildArgs(game)))]

proc indented(s: string): string =
  for line in s.strip(leading = false).splitLines:
    result.add "  " & line & "\n"

proc checkLane(game, lane: string, steps: seq[CheckStep]): Run =
  ## The two steps on the lane's folder; no stamp, no digest (nothing here can be saved).
  var failed: seq[string]
  var details = ""
  result.output = &"game: {game}\nlane: {lane}\n"
  for step in steps:
    let r = step.run(laneName(game, lane))
    if r.code == 0:
      result.output.add &"{step.name}: pass\n"
    else:
      failed.add step.name
      result.output.add &"{step.name}: FAIL\n"
      details.add &"{step.name} output:\n" & indented(r.output)
  if failed.len > 0:
    result.output.add "check: FAIL (" & failed.join(", ") & ")\n" & details
    result.code = 1
  else:
    result.output.add "check: pass (the lane only; land it, then check the game before saving)\n"

proc runCheckWith*(args: seq[string], steps: seq[CheckStep], root = ""): Run =
  var requested = ""
  var lane = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (checkHelp, 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      requested = args[i]
    of "--lane":
      inc i
      if i >= args.len: return errorOut("--lane needs the lane id", @[])
      lane = args[i]
    else:
      return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --game NAME, --lane ID"])
    inc i

  var game: string
  let picked = pickGame(root, requested, game)
  if picked.code != 0: return picked
  if lane.len > 0:
    if not validLaneId(lane) or not dirExists(laneDir(root, game, lane)):
      return errorOut(&"{game} has no lane called \"{lane}\"", @["List them with `para lane list --game " & game & "`"])
    return checkLane(game, lane, steps)

  removeStamp(root, game)
  let before = gameDigest(root, game)
  var failed: seq[string]
  var details = ""
  result.output = &"game: {game}\n"
  for step in steps:
    let r = step.run(game)
    if r.code == 0:
      result.output.add &"{step.name}: pass\n"
    else:
      failed.add step.name
      result.output.add &"{step.name}: FAIL\n"
      details.add &"{step.name} output:\n" & indented(r.output)
  # an edit while the steps ran (a helper still writing) means they did not
  # check what is there now
  let changedWhileRunning = gameDigest(root, game) != before

  if failed.len > 0:
    result.output.add "check: FAIL (" & failed.join(", ") & ")\n"
    result.output.add details
    result.code = 1
  elif changedWhileRunning:
    result.output.add "check: FAIL (the game changed while it was being checked)\n"
    result.output.add toonHelp(@["Run `para check --game " & game & "` again once nothing is editing it"])
    result.code = 1
  else:
    writeStamp(root, game, before)
    result.output.add "check: pass\n"
    result.output.add toonHelp(@["Run `para save -m \"what changed\"` to keep this as a save point"])
    result.code = 0

proc runCheck*(args: seq[string]): Run =
  runCheckWith(args, realSteps())
