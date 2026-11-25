## paraloop/prof: the timer seams behind `para bench` and the per-game-class
## performance gate. Everything here is compiled in, but only a `-d:prof`
## build records anything; without it `rulesNanos` is 0, the recorders are
## never called (the callers sit behind `when profEnabled`) and nothing is
## printed.
##
## Three seams:
##
## - **rules**: `patches/pararules/engine.nim` adds the time of every
##   outermost pararules call (`insertFact`, `retractFact`, `fireRules`,
##   `find`, `findAll`, `queryAll`, `get`) to one counter under `-d:prof`;
##   `rulesNanos` reads it. A `then` body runs inside `fireRules`, so it is
##   rules time; reads a system makes (`query`, `queryAll`) are too.
## - **tick**: `paraloop/app.run` times each `stepTick` and the rules time
##   inside it (`recordTick`); `para sim` does the same around each headless
##   `step` (tools/para/simcmd.nim) and prints the split.
##   systems = tick - rules: everything a tick does outside pararules.
## - **frame**: `paraloop/app.run` times `drawFrame` (draw CPU), `swapBuffers`
##   (present, plus any wait for the GPU) and the whole loop iteration
##   (`recordFrame`). A `-d:prof` window runs with vsync off unless
##   `-d:profVsync` is also given, so a frame is the work, not the display's
##   refresh; `-d:profFrames=N` closes the window after N frames.
##
## A native `-d:prof` window prints `profSummary()` to stdout when it closes.
## For the headless split, build a driver (or `para` itself, for the linked
## `hello`) with `-d:prof`, e.g. `nim c -d:prof -d:release --outdir:tmp/prof
## tools/para/para.nim`, and run its `sim`: the `perf:` line gains a `rules:`
## line. Percentiles here are nearest-rank on the sorted samples, the same
## rule `para sim` uses.

import std/[algorithm, strformat, strutils]
import paraloop/clock
when defined(prof):
  from pararules/engine import profRulesNs

const profEnabled* = defined(prof)
  ## True in a `-d:prof` build: the seams record and `rulesNanos` counts.

const profFrames* {.intdefine.} = 0
  ## `-d:profFrames=N`: a `-d:prof` window closes itself after N frames (0: never).

const profWarmupFrames* = 120
  ## Frames (and their ticks) `profSummary` leaves out: window creation,
  ## first uploads and shader compiles land in the first ones.

type
  TickSample* = object
    tickMs*, rulesMs*: float

  FrameSample* = object
    frameMs*: float ## the whole loop iteration: ticks, draw, swap and polling
    drawMs*, swapMs*: float
    ticks*: int     ## fixed ticks the frame ran (0 to the accumulator's cap)

var
  tickSamples: seq[TickSample]
  frameSamples: seq[FrameSample]
  ticksAtFrame: seq[int] ## tickSamples.len after each frame, to drop warm-up ticks

proc rulesNanos*(): int64 =
  ## Nanoseconds pararules has spent so far in outermost engine calls: a
  ## running total, so take it before and after a block. Always 0 without
  ## `-d:prof`.
  when defined(prof): profRulesNs else: 0'i64

proc recordTick*(tickMs, rulesMs: float) =
  tickSamples.add TickSample(tickMs: tickMs, rulesMs: rulesMs)

proc recordFrame*(s: FrameSample) =
  frameSamples.add s
  ticksAtFrame.add tickSamples.len

proc resetProf*() =
  ## Forgets every recorded tick and frame.
  tickSamples.setLen 0
  frameSamples.setLen 0
  ticksAtFrame.setLen 0

proc recordedTicks*(): seq[TickSample] = tickSamples
proc recordedFrames*(): seq[FrameSample] = frameSamples
proc frameCount*(): int = frameSamples.len

proc percentile*(xs: openArray[float], p: float): float =
  ## Nearest-rank percentile (`p` in 0..1) of `xs`: `sorted[(len - 1) * p]`,
  ## the rule `para sim`'s p50/p99 use. 0 for no samples.
  if xs.len == 0: return 0.0
  var s = @xs
  s.sort()
  s[int(float(s.len - 1) * p)]

proc fmtMs(x: float): string = formatFloat(x, ffDecimal, 3)

proc zoneRow(name: string, xs: seq[float]): seq[string] =
  var mx = 0.0
  for x in xs: mx = max(mx, x)
  @[name, $xs.len, fmtMs(percentile(xs, 0.5)), fmtMs(percentile(xs, 0.99)), fmtMs(mx)]

proc profSummary*(warmupFrames = profWarmupFrames): string =
  ## The recorded ticks and frames as TOON: one row per zone (tick, rules,
  ## systems, draw, swap, frame) with its sample count, p50, p99 and max in
  ## milliseconds, then the rules share of all tick time. The first
  ## `warmupFrames` frames and the ticks they ran are left out (all of them
  ## when there were no more frames than that).
  let skipFrames = min(warmupFrames, frameSamples.len)
  let skipTicks = if skipFrames == 0: 0 else: ticksAtFrame[skipFrames - 1]
  var tick, rules, systems, draw, swap, frame: seq[float]
  var tickSum, rulesSum = 0.0
  for i in skipTicks ..< tickSamples.len:
    let t = tickSamples[i]
    tick.add t.tickMs
    rules.add t.rulesMs
    systems.add max(0.0, t.tickMs - t.rulesMs)
    tickSum += t.tickMs
    rulesSum += t.rulesMs
  for i in skipFrames ..< frameSamples.len:
    let f = frameSamples[i]
    draw.add f.drawMs
    swap.add f.swapMs
    frame.add f.frameMs
  let share = if tickSum > 0: rulesSum / tickSum * 100 else: 0.0
  result = &"prof: {frame.len} frames and {tick.len} ticks after {skipFrames} warm-up frames, " &
    &"tick budget {fmtMs(fixedDt * 1000)}ms\n"
  result.add "zones[6]{zone,samples,p50_ms,p99_ms,max_ms}:\n"
  for row in [zoneRow("tick", tick), zoneRow("rules", rules), zoneRow("systems", systems),
              zoneRow("draw", draw), zoneRow("swap", swap), zoneRow("frame", frame)]:
    result.add "  " & row.join(",") & "\n"
  result.add &"rules-share: {share:.1f}% of tick time\n"
