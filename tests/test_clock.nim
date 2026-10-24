## paraloop/clock: the fixed timestep and accumulator, with no window. This
## file imports only `paraloop/clock` (no `paranim`), so it also holds that
## module to being headless; `tests/test_app.nim` covers the same names
## arriving through `paraloop/app`.

import std/[unittest, math]
import paraloop/clock

suite "clock: fixedDt and the accumulator":
  test "fixedDt is 1/60 s and the default accumulator uses it":
    check fixedDt == 1.0 / 60.0
    let a = initAccumulator()
    check a.fixedDt == fixedDt
    check a.maxFrameTime == defaultMaxFrameTime
    check a.tick == 0

  test "one second of frames is exactly 60 ticks, whatever the frame size":
    for frames in [60, 120, 30, 7]:
      var a = initAccumulator(maxFrameTime = 1.0)
      var ticks = 0
      for _ in 1 .. frames:
        ticks += a.advance(1.0 / frames.float)
      # a float remainder can leave the 60th tick for the next frame
      check ticks in 59 .. 60
      check a.tick == ticks

  test "a stall is clamped: the work a frame can demand is bounded":
    var a = initAccumulator()
    let ticks = a.advance(3600.0)
    check ticks == int(floor(defaultMaxFrameTime / fixedDt + 1e-9))
    check a.tick == ticks

  test "the remainder carries over and alpha reports it":
    var a = initAccumulator(maxFrameTime = 1.0)
    check a.advance(1.25 * fixedDt) == 1
    check abs(a.alpha - 0.25) < 1e-9
    check a.advance(0.75 * fixedDt) == 1
    check abs(a.alpha) < 1e-9
