# `para bench sprites`'s measuring program (tools/para/benchcmd.nim builds and
# runs it; it is not a game and not part of `para`). It opens a hidden
# 1280x720 GL 3.3 window (paraloop/app.openHeadlessWindow), makes one 32 px
# sprite sheet (paraloop/render2d), then for each measured frame adds `--n`
# sprites with `addCell` and draws them in `--calls` flushes, timing four
# parts of the frame: add (Nim-side per-sprite work in render2d/paranim),
# submit (the flushes: instance upload and draw calls), gpu (a GL_TIME_ELAPSED
# query around the draws) and wait (glFinish). One `result` line of
# `key=value` fields, after a `renderer:` and a `gl-version:` line, so the
# numbers say which GPU and driver made them. Exit 3 when no window can be opened (no
# display).
#
# Fields: sprites, calls, frames, warmup, add_ms, submit_ms, gpu_ms, wait_ms
# (each a p50), p50_ms and p99_ms (the whole frame: add + submit + wait), and
# rss_mb (VmRSS from /proc/self/status after the run; "n/a" without /proc).

import std/[monotimes, algorithm, os, strutils, strformat]
import paranim/glfw
import paranim/gl
import paranim/opengl
import paranim/math as pmath
import paraloop/app
import paraloop/render2d

type Bench = object of RootGame

const
  W = 1280
  H = 720
  spriteSize = 32

proc msSince(t: MonoTime): float = float(getMonoTime().ticks - t.ticks) / 1e6

proc pct(xs: var seq[float], p: float): float =
  xs.sort()
  xs[int(float(xs.high) * p)]

proc rssMb(): string =
  try:
    for line in readFile("/proc/self/status").splitLines:
      if line.startsWith("VmRSS:"):
        return formatFloat(line[6 .. ^1].strip.split(' ')[0].parseInt.float / 1024, ffDecimal, 1)
  except IOError, OSError, ValueError:
    discard
  "n/a"

proc main() =
  var n = 5000
  var calls = 1
  var frames = 90
  var warmup = 10
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let v = if i + 1 < args.len: args[i + 1] else: ""
    case args[i]
    of "--n": n = v.parseInt
    of "--calls": calls = v.parseInt
    of "--frames": frames = v.parseInt
    of "--warmup": warmup = v.parseInt
    else:
      stderr.writeLine "sprite_bench: unknown argument " & args[i]
      quit 2
    i += 2
  if n < 1 or calls < 1 or calls > n or frames < 1 or warmup < 0:
    stderr.writeLine "sprite_bench: bad arguments"
    quit 2

  let win = openHeadlessWindow(W, H)
  if win == nil:
    echo "error no display: GLFW could not open a hidden GL 3.3 window"
    quit 3
  doAssert glInit()
  glfwSwapInterval(0)
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  var pixels: seq[byte]
  for _ in 0 ..< spriteSize * spriteSize:
    pixels.add 52; pixels.add 152; pixels.add 219; pixels.add 200
  var g = Bench()
  var sheet = initSheet(g, pixels, spriteSize, spriteSize)
  echo "renderer: ", $cast[cstring](glGetString(GL_RENDERER))
  echo "gl-version: ", $cast[cstring](glGetString(GL_VERSION))

  # Positions from a fixed LCG, so every run draws the same scene.
  var xs = newSeq[float](n)
  var ys = newSeq[float](n)
  var state = 7'u32
  proc next(): float =
    state = state * 1664525'u32 + 1013904223'u32
    float(state shr 8) / float(1 shl 24)
  for j in 0 ..< n:
    xs[j] = next() * float(W)
    ys[j] = next() * float(H)

  var q: GLuint
  glGenQueries(1, q.addr)
  let (ww, wh) = windowSize()
  let camera = mat3f(1)
  var addMs, submitMs, gpuMs, waitMs, totalMs: seq[float]
  for f in 0 ..< warmup + frames:
    glClearColor(0.1, 0.1, 0.15, 1.0)
    glClear(GL_COLOR_BUFFER_BIT)
    let t0 = getMonoTime()
    glBeginQuery(GL_TIME_ELAPSED, q)
    var addT, subT = 0.0
    var k = 0
    for b in 0 ..< calls:
      let upto = if b == calls - 1: n else: (b + 1) * (n div calls)
      let a0 = getMonoTime()
      while k < upto:
        sheet.addCell(0, 0, xs[k] + float(f mod 16), ys[k], float spriteSize, float spriteSize)
        inc k
      addT += msSince(a0)
      let s0 = getMonoTime()
      sheet.flush(g, float ww, float wh, camera)
      subT += msSince(s0)
    glEndQuery(GL_TIME_ELAPSED)
    let w0 = getMonoTime()
    glFinish()
    let waitT = msSince(w0)
    var gpuNs: GLuint64 = 0
    glGetQueryObjectui64v(q, GL_QUERY_RESULT, gpuNs.addr)
    let total = msSince(t0)
    if f >= warmup:
      addMs.add addT
      submitMs.add subT
      gpuMs.add gpuNs.float / 1e6
      waitMs.add waitT
      totalMs.add total
  let p50 = pct(totalMs, 0.5)
  let p99 = pct(totalMs, 0.99)
  echo &"result sprites={n} calls={calls} frames={frames} warmup={warmup} " &
    &"add_ms={pct(addMs, 0.5):.4f} submit_ms={pct(submitMs, 0.5):.4f} gpu_ms={pct(gpuMs, 0.5):.4f} " &
    &"wait_ms={pct(waitMs, 0.5):.4f} p50_ms={p50:.4f} p99_ms={p99:.4f} rss_mb={rssMb()}"
  win.destroyWindow()
  glfwTerminate()

main()
