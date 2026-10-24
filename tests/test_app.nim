import unittest
import std/[math, os]
import paranim/glfw
import paraloop/app

suite "app: fixed-timestep accumulator":
  test "N ticks for a given elapsed time":
    var a = initAccumulator(fixedDt = 1.0 / 60.0, maxFrameTime = 1.0)
    let ticks = a.advance(0.5)
    check ticks == 30
    check a.tick == 30

  test "ticks accumulate across frames without losing the remainder":
    var a = initAccumulator(fixedDt = 1.0 / 60.0, maxFrameTime = 1.0)
    var total = 0
    for _ in 1 .. 60:
      total += a.advance(1.0 / 60.0)
    check total == 60
    check a.tick == 60

  test "clamps a stalled frame instead of running an unbounded backlog":
    var a = initAccumulator(fixedDt = 1.0 / 60.0, maxFrameTime = 0.25)
    let ticks = a.advance(10.0) # a 10s stall
    check ticks == 15 # 0.25s worth of ticks at 1/60s, not 600
    check a.tick == 15

  test "alpha reports how far into the next tick the accumulator sits":
    var a = initAccumulator(fixedDt = 1.0 / 60.0, maxFrameTime = 1.0)
    discard a.advance(1.5 / 60.0)
    check abs(a.alpha() - 0.5) < 1e-9

  test "a negative elapsed (clock reset) runs no ticks and leaves no debt":
    var a = initAccumulator(fixedDt = 1.0 / 60.0, maxFrameTime = 1.0)
    check a.advance(-1.5) == 0
    check a.alpha() == 0.0
    check a.advance(1.0 / 60.0) == 1

type LocalGame = object
  steps: int

var inits, draws: int
var ticksSeen: seq[int]
var stepsAtLastDraw: int

proc init(game: var LocalGame) =
  inc inits

proc step(game: var LocalGame, tick: int) =
  inc game.steps
  ticksSeen.add(tick)
  if game.steps >= 3:
    glfwGetCurrentContext().setWindowShouldClose(true)

proc draw(game: var LocalGame, alpha: float) =
  inc draws
  stepsAtLastDraw = game.steps

proc runLocalGame() =
  var game = LocalGame()
  run(game, title = "paraloop test")

suite "app: run":
  test "drives a game declared as a local in the caller's proc":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      runLocalGame()
      check inits == 1
      check ticksSeen.len >= 3
      for i, t in ticksSeen:
        check t == i + 1
      check draws > 0
      check stepsAtLastDraw == ticksSeen.len
