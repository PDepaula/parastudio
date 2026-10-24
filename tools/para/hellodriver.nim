# examples/hello's driver: the game linked into `para`, so `para sim` and `para
# shot` run it in process (linked.nim). A game outside para ships the same thing
# as a program of its own (gamedriver.nim). hello has no flags of its own.

import std/tables
import pararules
import paraloop/app
import paraloop/sim
import examples/hello/hello
import gamedriver

proc helloRun(box: ref HelloGame, step: proc (g: var HelloGame, tick: int)): SimRun =
  ## A run over the game `box` holds, which the closures share.
  result.step = proc (tick: int) = step(box[], tick)
  result.pos = proc (): tuple[x, y: int] = box[].pos
  result.stateHash = proc (): string = $box[].sim.stateHash()
  result.factsHash = proc (): string = $box[].sim.factsHash()
  result.kinds = proc (): CountTable[string] = box[].sim.kindCounts(HelloId)

proc stepWithTick(g: var HelloGame, tick: int) = g.stepTick(tick)
proc stepOnly(g: var HelloGame, tick: int) = g.step(tick)

proc helloSimDriver*(): SimDriver =
  result.newRun = proc (seed: int64): SimRun =
    let box = new HelloGame
    box[] = initHelloGame(seed)
    helloRun(box, stepWithTick)
  result.restore = proc (dir: string): SimRun =
    let box = new HelloGame
    box[] = initHelloGame(0'i64)
    box[].sim = restoredSim(dir, newHelloSession, HelloAttr)
    helloRun(box, stepOnly)

proc helloShotDriver*(): ShotDriver =
  result.newGame = proc (seed: int64): ShotGame =
    let box = new HelloGame
    box[] = initHelloGame(seed)
    result.init = proc () = box[].init()
    result.stepTick = proc (tick: int) = box[].stepTick(tick)
    result.draw = proc () = box[].drawFrame(0.0)
