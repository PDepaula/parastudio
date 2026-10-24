# `--game NAME` resolution shared by every `para` command that takes one,
# and the per-game status files the bare view reads. A game is any
# `<base>/<name>/<name>.nim` under examples/ or games/ -- the shape
# `examples/hello/hello.nim` and task 1.9's `para new` both produce. Status
# lives in `tmp/status/<game>/<kind>` (`tests`, written by `para test`;
# `goldens`, by `para shot --check`; `web`, by `para web smoke`), one line
# recording the last run's outcome, pass or fail.

import std/[os, algorithm, sequtils, strutils, strformat, times]
import art/clihelpers

type Game* = tuple[name, dir: string]

const
  linkedGames* = ["hello"]
    ## The games compiled into `para` itself (linked.nim's registry), which `sim` and
    ## `shot` run in process. Any other game with a driver program runs through it.
  defaultGame* = "hello" ## the game `sim` and `shot` run when `--game` is absent

proc gameFlag*(args: seq[string]): string =
  ## The `--game NAME` an argument list names (the last one), else `defaultGame`.
  result = defaultGame
  for i in 0 ..< args.len - 1:
    if args[i] == "--game": result = args[i + 1]

proc listGames*(): seq[Game] =
  for base in ["examples", "games"]:
    if not dirExists(base): continue
    for kind, path in walkDir(base):
      let name = path.extractFilename
      if kind == pcDir and fileExists(path / (name & ".nim")):
        result.add (name, path)
  result.sort()

proc source*(game: Game): string =
  game.dir / (game.name & ".nim")

proc resolveGame*(name: string, game: var Game): Run =
  ## Finds `name` among `listGames()`; code 0 when found, otherwise a usage
  ## error listing the valid names.
  let games = listGames()
  for g in games:
    if g.name == name:
      game = g
      return ("", 0)
  errorOut(&"unknown game \"{name}\"", @["Valid games: " & games.mapIt(it.name).join(", ")])

proc statusFile(game, kind: string): string =
  "tmp" / "status" / game / kind

proc recordStatus*(game, kind, text: string) =
  createDir(statusFile(game, kind).parentDir)
  writeFile(statusFile(game, kind), text & "\n")

proc readStatus*(game, kind: string): string =
  let f = statusFile(game, kind)
  if fileExists(f): readFile(f).strip else: "never run"

proc today*(): string =
  now().utc.format("yyyy-MM-dd")
