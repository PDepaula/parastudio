# `para check`: the one command a producer runs before saving a game. It runs
# the game's own tests (`para test --filter games/<game>/ --skip-balance`, the trailing slash
# anchors the filter to that directory) and `para build --game <game>`, prints
# one pass/fail line per step and one verdict, and exits 0 only when both
# passed. It never runs the full suite, goldens, web smoke, balance or a push.
# On a pass it writes the stamp `para save` looks for (savepoint.nim).
#
# Both steps run in this process, so `runCheck` must be run from the repo
# root, like `para test`. `runCheckWith` takes the steps as procs so tests
# need no compiler.

import std/[strformat, strutils]
import art/[clihelpers, toon]
import savepoint
import testcmd
import buildcmd

type
  Run = clihelpers.Run
  CheckStep* = tuple[name: string, run: proc (game: string): Run]

const checkHelp* = "para check [--game NAME]\n" &
  "  runs the game's tests (para test --filter games/<game>/ --skip-balance) and builds it (para build --game <game>),\n" &
  "  then prints one pass/fail line per step and a verdict; exit 0 when both passed, 1 when not\n" &
  "  --game NAME  the game under games/; left out, the only game with a PLAN.md\n" &
  "  a pass is what lets `para save` save the game as it is now; any later edit needs a new check\n" &
  "  never runs the full suite, goldens, web smoke, balance or a push\n"

proc testArgs*(game: string): seq[string] =
  @["--filter", gamePrefix(game), "--skip-balance"]

proc buildArgs*(game: string): seq[string] =
  @["--game", game]

proc realSteps*(): seq[CheckStep] =
  @[("tests", proc (game: string): Run = runTest(testArgs(game))),
    ("build", proc (game: string): Run = runBuild(buildArgs(game)))]

proc indented(s: string): string =
  for line in s.strip(leading = false).splitLines:
    result.add "  " & line & "\n"

proc runCheckWith*(args: seq[string], steps: seq[CheckStep], root = ""): Run =
  var requested = ""
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
    else:
      return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --game NAME"])
    inc i

  var game: string
  let picked = pickGame(root, requested, game)
  if picked.code != 0: return picked

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
