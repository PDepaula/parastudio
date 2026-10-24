# Runs a game's driver program. A game that is not linked into `para` (linked.nim)
# but wants `para sim`, `para shot` or its own tools ships
# `games/<name>/tools/<name>_driver.nim`: a program built on gamedriver.nim whose
# first argument is the command (`sim`, `shot`, or any the game adds) and whose exit code is the command's. Here
# the program is compiled to tmp/drivers/ (nim keeps its own incremental state, so
# a second run only checks) and run from the repo root with the command line `para`
# was given. `para driver GAME ARGS...` is the same thing for the game's own commands.

import std/[os, strformat, strutils, sequtils]
import art/[clihelpers, toon]
import games
import nimutil

type Run = clihelpers.Run

const driverHelp* = "para driver GAME [COMMAND ARGS...]\n" &
  "  builds and runs games/GAME/tools/GAME_driver.nim, the program a game ships for the commands only it\n" &
  "  has (para sim and para shot hand it their command line the same way), and passes COMMAND ARGS to it;\n" &
  "  with none, the driver prints its own help\n"

proc driverSource*(game: Game): string =
  game.dir / "tools" / (game.name & "_driver.nim")

proc driverBinary(game: Game): string =
  "tmp" / "drivers" / (game.name & "_driver" & ExeExt)

proc buildDriver(game: Game): Run =
  ## Code 0, or the compiler's diagnostics.
  createDir("tmp" / "drivers")
  let res = runCaptured("nim", @["c", "--hints:off", "--outdir:tmp/drivers", driverSource(game)])
  if res.exitCode == 0: return ("", 0)
  let diags = parseNimDiagnostics(res.output).filterIt(it.severity == "Error")
  if diags.len > 0:
    result.output = &"error: {game.name}'s driver failed to build ({diags.len} error{(if diags.len == 1: \"\" else: \"s\")})\n"
    result.output.add toonTable("errors", ["at", "msg"], diags.mapIt(@[it.at, it.msg]))
  else:
    result.output = &"error: {game.name}'s driver failed to build\n" & lastLines(res.output, 20)
  result.code = 1

proc runDriver*(gameName: string, driverArgs: seq[string]): Run =
  ## Builds `gameName`'s driver and runs it with `driverArgs`: its output and exit code.
  var game: Game
  let notFound = resolveGame(gameName, game)
  if notFound.code != 0: return notFound
  if not fileExists(driverSource(game)):
    return errorOut(&"{gameName} has no driver program ({driverSource(game)})",
      @["`para sim` and `para shot` run the games linked into para (" & linkedGames.join(", ") &
        ") and any game that ships a tools/<name>_driver.nim"])
  let built = buildDriver(game)
  if built.code != 0: return built
  let ran = runCaptured(driverBinary(game).absolutePath, driverArgs)
  (ran.output, ran.exitCode)

proc runGameDriver*(gameName, command: string, args: seq[string]): Run =
  ## `para <command>` for a game that is not linked: its driver runs `command` with `args`.
  runDriver(gameName, @[command] & args)

proc runDriverCommand*(args: seq[string]): Run =
  ## `para driver GAME [COMMAND ARGS...]`.
  if args.len == 0 or args[0] in ["--help", "-h"]:
    return (driverHelp, 0)
  runDriver(args[0], args[1 .. ^1])
