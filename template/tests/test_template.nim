## Headless tests for this game: `nimble test` (via `para test`) discovers
## every `tests/test_*.nim` under `games/*/` and `examples/*/` the same way
## it discovers the top-level `tests/` directory (`paraloop.nimble`). Mirrors
## `tests/test_hello.nim`'s replay-driven pattern -- see also the
## `pararules` skill's "getter"/"per-tick rule" worked examples.

import std/[unittest, sequtils]
import pararules
import paraloop/input
import paraloop/app
import paraloop/sim
import "../__GAME__"
import "../rules"

proc replay(script: string, lastTick: int): Game =
  ## Drive the game headless the way `app.run` does (ticks from 1, through
  ## `stepTick`), with the replay standing in for key events.
  engineKeys = newKeyState()
  result = initGame()
  let replay = newReplay(parseScript(script))
  for tick in 1 .. lastTick:
    step(replay, engineKeys, tick)
    result.stepTick(tick)

suite "__GAME__: input replay":
  test "no keys leaves the sprite centred":
    check replay("", 30).pos == (x: 0, y: 0)

  test "held arrow keys move the sprite tick for tick":
    const script = "1:right:10, 5:up:3, 20:left"
    check replay(script, 4).pos == (x: 4 * moveSpeed, y: 0)
    check replay(script, 7).pos == (x: 7 * moveSpeed, y: -3 * moveSpeed)
    check replay(script, 19).pos == (x: 10 * moveSpeed, y: -3 * moveSpeed)
    check replay(script, 30).pos == (x: 9 * moveSpeed, y: -3 * moveSpeed)

suite "__GAME__: command rule":
  test "a pulsed MoveCommand moves the sprite by its step and leaves no fact behind":
    var game = initGame()
    game.sim.pulse(Global, MoveCommand, (dx: 3, dy: -2))
    check game.pos == (x: 3, y: -2)
    game.sim.pulse(Global, MoveCommand, (dx: 3, dy: -2))
    check game.pos == (x: 6, y: -4)
    check (Global.ord, MoveCommand.ord) notin
      game.sim.dumpFacts.mapIt((it.id, it.attr))

suite "__GAME__: per-tick rule and determinism":
  test "the sim tick counter advances once per stepTick":
    check replay("", 10).sim.tick == 10

  test "the per-tick rule (TotalTime += DeltaTime) makes two identical runs hash the same":
    # `rules.tickTime` fires once per tick on the `DeltaTime` insert in
    # `step` (rules.nim's one trigger); two runs of the same script from the
    # same seed advance it identically, so their whole state -- including
    # TotalTime -- hashes the same (paraloop/sim's report §3.4 R3 contract).
    const script = "1:right:5"
    check replay(script, 20).sim.stateHash == replay(script, 20).sim.stateHash
