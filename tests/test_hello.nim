import unittest
import paraloop/audio
import paraloop/input
import paraloop/app
import examples/hello/hello

proc replayHello(script: string, lastTick: int, backend: Backend = nil): HelloGame =
  ## Drive hello headless the way `app.run` does (ticks from 1, through
  ## `stepTick`), with the replay standing in for key events. `backend` is
  ## where its sounds go (none: silent, as in every headless run).
  engineKeys = newKeyState()
  result = initHelloGame()
  result.audio = initAudio(backend, helloSounds)
  let replay = newReplay(parseScript(script))
  for tick in 1 .. lastTick:
    step(replay, engineKeys, tick)
    result.stepTick(tick)

suite "hello: input replay":
  test "no keys leaves the sprite centred":
    check replayHello("", 30).pos == (x: 0, y: 0)

  test "held arrow keys move the sprite tick for tick":
    const script = "1:right:10, 5:up:3, 20:left"
    check replayHello(script, 4).pos == (x: 4 * moveSpeed, y: 0)
    check replayHello(script, 7).pos == (x: 7 * moveSpeed, y: -3 * moveSpeed)
    check replayHello(script, 19).pos == (x: 10 * moveSpeed, y: -3 * moveSpeed)
    check replayHello(script, 30).pos == (x: 9 * moveSpeed, y: -3 * moveSpeed)

suite "hello: sound":
  const script = "1:right:10, 5:up:3, 20:left"

  test "the beep plays once each time an arrow goes down from rest":
    let early = NullBackend()
    discard replayHello(script, 19, early)
    check early.plays == @[(slot: 0, volume: 1.0)] # tick 1; up joining at 5 is not a new start
    let late = NullBackend()
    discard replayHello(script, 30, late)
    check late.plays.len == 2 # and tick 20, after nine ticks at rest

  test "no keys, no beep; and the sound never moves the sprite":
    let quiet = NullBackend()
    discard replayHello("", 30, quiet)
    check quiet.plays.len == 0
    let b = NullBackend()
    check replayHello(script, 30, b).pos == replayHello(script, 30).pos
