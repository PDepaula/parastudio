# The seam between `para sim` / `para shot` and a game: a driver is what a game
# hands the generic runs so `para` never imports the game. `hello` is linked into
# para (tools/para/hellodriver.nim, listed in tools/para/linked.nim); any other
# game that wants `sim` and `shot` ships `games/<name>/tools/<name>_driver.nim`, a
# program built from `driverMain` below that para compiles and runs in place of
# its own copy (tools/para/driverexec.nim). The drivers are type-erased -- closures
# over the game's own value -- so the shared loops (simcmd.nim, shotcmd.nim) never
# name a game type, and a game's extra flags (`--hub`, `--room`, `--fixtures`, ...)
# live in its driver, not in para.

import std/[options, os, tables, sets, sequtils, strutils]
import pararules
import art/clihelpers
import paraloop/sim
import paraloop/dev

type
  Run = clihelpers.Run

  ExtraFlag* = tuple[flag, arg, help: string]
    ## A flag the game adds to `sim` or `shot`. `arg` names its value (`FILE`), empty for a switch.

  Extras* = OrderedTable[string, string]
    ## The game's flags a command line gave, in order: flag -> value ("" for a switch).

  SimRun* = object
    ## One headless run of a game, as `para sim` drives it. The procs close over the game.
    step*: proc (tick: int)
    pos*: proc (): tuple[x, y: int]
    stateHash*, factsHash*: proc (): string
    kinds*: proc (): CountTable[string]
      ## live entities by kind, for the entities table
    beforeTick*, afterTick*: proc ()
      ## optional hooks around each `step` (a pressure flag, a counter)
    report*: proc (): tuple[text: string, failed: bool]
      ## optional: lines printed after the perf line, and whether a gate flag was missed

  SimDriver* = object
    flags*: seq[ExtraFlag]
    prepare*: proc (extras: Extras): string
      ## validates the game's flags and reads what they name; an error text, or "" when fine
    defaultSeed*: proc (): Option[int64]
      ## the seed the flags imply (a saved profile's), used when `--seed` is absent; nil for none
    newRun*: proc (seed: int64): SimRun
    restore*: proc (dir: string): SimRun
      ## the run a bug capture's snapshot holds (`para sim --from`); raises on an unreadable capture

  ShotGame* = object
    ## The game `para shot` renders, as closures over it.
    init*: proc ()
    stepTick*: proc (tick: int)
    draw*: proc ()
    phase*: proc (): string
      ## the phase name `NAME=@Phase` frames match; nil for a game without phases

  ShotFixtures* = object
    ## A game that can render states, not runs (`--fixtures DIR`).
    ext*: string
    names*: proc (dir: string): seq[string]
    load*: proc (path: string): tuple[game: ShotGame, tick: int]
      ## raises (a `CatchableError` naming the file) on a fixture it cannot read
    formatHelp*: string

  ShotDriver* = object
    flags*: seq[ExtraFlag]
      ## every game flag shapes the run, so `--fixtures` refuses them
    prepare*: proc (extras: Extras): string
    defaultSeed*: proc (): Option[int64]
    onTitle*: proc (): bool
      ## the run starts on the title screen (shown in the render line)
    newGame*: proc (seed: int64): ShotGame
    hasPhases*: bool
    fixtures*: Option[ShotFixtures]

proc extraFlagNames*(flags: seq[ExtraFlag]): seq[string] =
  for f in flags: result.add f.flag

proc flagHelp*(flags: seq[ExtraFlag]): string =
  ## The flags' help lines as a driver wrote them.
  for f in flags: result.add f.help

proc takeExtra*(flags: seq[ExtraFlag], args: seq[string], i: var int, extras: var Extras,
                outcome: var Run): bool =
  ## If `args[i]` is one of the game's `flags`, records it (and its value, advancing `i`) in
  ## `extras` and returns true; a flag missing its value sets `outcome` to a usage error.
  for f in flags:
    if args[i] == f.flag:
      if f.arg.len == 0:
        extras[f.flag] = ""
      elif i + 1 >= args.len:
        outcome = errorOut(f.flag & " needs " & (if f.arg == "FILE": "a file" else: "a value (" & f.arg & ")"), @[])
      else:
        inc i
        extras[f.flag] = args[i]
      return true

proc restoredSim*[T, MatchT, A](dir: string, newSession: proc (): Session[T, MatchT],
                                attrType: typedesc[A]): Sim[T, MatchT] =
  ## The sim a bug capture's snapshot holds. `T` is bound by `newSession`'s return type, so a
  ## driver never names the game's schema type (mirrors `tests/test_dev.nim`'s `replayBug`).
  restore(readBugSnapshot(dir, T), newSession, attrType)

proc kindCounts*[T, MatchT, I](sim: Sim[T, MatchT], idType: typedesc[I]): CountTable[string] =
  ## Live entities of a sim by the game's id enum (`id` for an id outside it).
  var seen: HashSet[int]
  for f in sim.dumpFacts:
    if not seen.containsOrIncl(f.id):
      result.inc(if f.id in I.low.ord .. I.high.ord: $I(f.id) else: "id")

type
  DriverCommand* = object
    name*, help*: string
    run*: proc (args: seq[string]): Run

proc driverMain*(game: string, commands: seq[DriverCommand]) =
  ## The `main` of a game's driver program: `<driver> COMMAND ARGS...` runs that command, prints
  ## its output and exits with its code (0 ok, 1 findings, 2 usage error, like `para`).
  let args = commandLineParams()
  var run: Run
  if args.len == 0 or args[0] in ["--help", "-h"]:
    run.output = game & "'s driver (para driver " & game & " COMMAND ARGS...); commands:\n"
    for c in commands: run.output.add "  " & c.name & ": " & c.help & "\n"
  else:
    run = errorOut("unknown driver command \"" & args[0] & "\"",
      @["Valid commands: " & commands.mapIt(it.name).join(", ")])
    for c in commands:
      if c.name == args[0]:
        run = c.run(args[1 .. ^1])
  stdout.write(run.output)
  quit(run.code)
