## paraloop/clock: the fixed timestep and the accumulator that turns wall-clock
## frames into whole ticks. No window, no GL: headless code (a rule's tick
## value, a sim driver, a test) imports this directly, and `paraloop/app`
## re-exports it so a caller that imports `paraloop/app` sees no change.

const
  fixedDt* = 1.0 / 60.0
  defaultMaxFrameTime* = 0.1
    ## Clamp on a stalled frame (breakpoint, GC pause, backgrounded tab) so it
    ## can't demand an unbounded backlog of catch-up ticks. Parasurvivors
    ## capped its wall-clock delta the same way (`core.nim`'s
    ## `min(ts - totalTime, 0.1)`); here the cap moves onto the accumulator
    ## feed instead of the raw delta (report §3.4 R1).

type
  Accumulator* = object
    tick*: int
    acc: float
    fixedDt*: float
    maxFrameTime*: float

proc initAccumulator*(fixedDt = fixedDt, maxFrameTime = defaultMaxFrameTime): Accumulator =
  Accumulator(tick: 0, acc: 0.0, fixedDt: fixedDt, maxFrameTime: maxFrameTime)

proc advance*(a: var Accumulator, elapsed: float): int =
  ## Feed one frame's wall-clock elapsed time in. Runs zero or more fixed
  ## ticks, advancing `a.tick`, and returns how many ticks ran this call.
  a.acc += clamp(elapsed, 0.0, a.maxFrameTime)
  while a.acc >= a.fixedDt:
    a.acc -= a.fixedDt
    a.tick += 1
    inc result

proc alpha*(a: Accumulator): float =
  ## How far the accumulator sits into the next tick (0..1), for `draw` to
  ## interpolate render state between the last tick and the next one.
  a.acc / a.fixedDt
