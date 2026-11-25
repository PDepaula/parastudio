# `para bench rules`'s measuring program (tools/para/benchcmd.nim builds and
# runs it; it is not a game and not part of `para`). One run measures one
# variant at one entity count and prints one `result` line of `key=value`
# fields, so `para` can run each (count, variant, repeat) in a fresh process:
# the resident memory it reports then belongs to that variant alone.
#
# The schema is the performance scout's churn bench, widened to the per-game
# class shape (several per-entity rules): every entity has PosX, PosY, VelX,
# VelY, Age and Heat; the tick is one `insert(Global, DeltaTime, dt)` with
# autoFire on, which fires each per-entity rule once per entity. Each rule is
# the template's canonical shape: the entity's own attrs first, each with
# `then = false`, and `(Global, DeltaTime, dt)` last as the one trigger.
#
# Variants:
# - rules:   `--rules K` (1 to 3) per-entity rules: `move` (writes PosX and
#            PosY), `age` (writes Age), `cool` (writes Heat). K rules make
#            N * K firings and N * (K + 1) inserts a tick.
# - systems: no per-entity rule; a plain loop reads every entity through the
#            `bodies` getter and writes the facts K rules would write (the
#            "systems pattern": facts stay the store, logic leaves the rules).
# Every session variant also holds the `bodies` getter (all six attrs), as a
# game's draw or systems read would.
# - plain:   the same arithmetic over a plain `seq` of objects, no session.
#
# Fields: entities, rules, variant, ticks, warmup, setup_ms (inserting the
# starting facts), p50_ms, p99_ms (per tick, nearest rank), heap_mb (Nim's
# occupied heap after the run), rss_mb and hwm_mb (VmRSS and VmHWM from
# /proc/self/status; "n/a" where there is no /proc).

import std/[monotimes, algorithm, os, strutils, strformat]
import pararules
from pararules/engine import nil
static: doAssert declared(engine.paraloopEnginePatched), "patched engine not applied (run from the repo root)"

type
  Id = enum Global
  Attr = enum DeltaTime, PosX, PosY, VelX, VelY, Age, Heat

schema Fact(Id, Attr):
  DeltaTime: float
  PosX: float
  PosY: float
  VelX: float
  VelY: float
  Age: float
  Heat: float

let (newRawSession, rules) =
  staticRuleset(Fact, FactMatch):
    rule bodies(Fact):
      what:
        (id, PosX, x)
        (id, PosY, y)
        (id, VelX, vx)
        (id, VelY, vy)
        (id, Age, a)
        (id, Heat, h)
    rule move(Fact):
      what:
        (id, PosX, x, then = false)
        (id, PosY, y, then = false)
        (id, VelX, vx, then = false)
        (id, VelY, vy, then = false)
        (Global, DeltaTime, dt)
      then:
        session.insert(id, PosX, x + vx * dt)
        session.insert(id, PosY, y + vy * dt)
    rule age(Fact):
      what:
        (id, Age, a, then = false)
        (Global, DeltaTime, dt)
      then:
        session.insert(id, Age, a + dt)
    rule cool(Fact):
      what:
        (id, Heat, h, then = false)
        (id, VelX, vx, then = false)
        (Global, DeltaTime, dt)
      then:
        session.insert(id, Heat, max(0.0, h - dt) + abs(vx) * 0.001)

const dt = 1.0 / 60.0

proc msSince(t: MonoTime): float = float(getMonoTime().ticks - t.ticks) / 1e6

proc pct(xs: var seq[float], p: float): float =
  xs.sort()
  xs[int(float(xs.high) * p)]

proc memLine(key: string): string =
  ## A /proc/self/status field in MB ("n/a" without /proc).
  try:
    for line in readFile("/proc/self/status").splitLines:
      if line.startsWith(key & ":"):
        let kb = line[key.len + 1 .. ^1].strip.split(' ')[0].parseInt
        return formatFloat(kb.float / 1024, ffDecimal, 1)
  except IOError, OSError, ValueError:
    discard
  "n/a"

proc seed(s: var auto, n: int) =
  for i in 0 ..< n:
    let id = 1 + i
    s.insert(id, PosX, float(i))
    s.insert(id, PosY, float(i) * 0.5)
    s.insert(id, VelX, 1.0)
    s.insert(id, VelY, -1.0)
    s.insert(id, Age, 0.0)
    s.insert(id, Heat, float(i mod 7))

type Ent = object
  x, y, vx, vy, age, heat: float

proc main() =
  var n = 300
  var k = 3
  var ticks = 300
  var warmup = 30
  var variant = "rules"
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let v = if i + 1 < args.len: args[i + 1] else: ""
    case args[i]
    of "--n": n = v.parseInt
    of "--rules": k = v.parseInt
    of "--ticks": ticks = v.parseInt
    of "--warmup": warmup = v.parseInt
    of "--variant": variant = v
    else:
      stderr.writeLine "rules_bench: unknown argument " & args[i]
      quit 2
    i += 2
  if n < 1 or k notin 1 .. 3 or ticks < 1 or warmup < 0 or variant notin ["rules", "systems", "plain"]:
    stderr.writeLine "rules_bench: bad arguments"
    quit 2

  var times: seq[float]
  var setupMs = 0.0
  case variant
  of "rules":
    var s = newRawSession()
    s.add(rules.bodies)
    s.add(rules.move)
    if k >= 2: s.add(rules.age)
    if k >= 3: s.add(rules.cool)
    let t0 = getMonoTime()
    s.seed(n)
    setupMs = msSince(t0)
    for t in 0 ..< warmup + ticks:
      let a = getMonoTime()
      s.insert(Global, DeltaTime, dt) # autoFire: each rule fires once per entity
      let ms = msSince(a)
      if t >= warmup: times.add ms
    doAssert s.queryAll(rules.bodies).len == n
  of "systems":
    var s = newRawSession()
    s.add(rules.bodies)
    let t0 = getMonoTime()
    s.seed(n)
    setupMs = msSince(t0)
    for t in 0 ..< warmup + ticks:
      let a = getMonoTime()
      for m in s.queryAll(rules.bodies):
        s.insert(m.id, PosX, m.x + m.vx * dt)
        s.insert(m.id, PosY, m.y + m.vy * dt)
        if k >= 2: s.insert(m.id, Age, m.a + dt)
        if k >= 3: s.insert(m.id, Heat, max(0.0, m.h - dt) + abs(m.vx) * 0.001)
      let ms = msSince(a)
      if t >= warmup: times.add ms
  else:
    let t0 = getMonoTime()
    var ents = newSeq[Ent](n)
    for j in 0 ..< n:
      ents[j] = Ent(x: float(j), y: float(j) * 0.5, vx: 1.0, vy: -1.0, heat: float(j mod 7))
    setupMs = msSince(t0)
    var sink = 0.0
    for t in 0 ..< warmup + ticks:
      let a = getMonoTime()
      for e in ents.mitems:
        e.x += e.vx * dt
        e.y += e.vy * dt
        if k >= 2: e.age += dt
        if k >= 3: e.heat = max(0.0, e.heat - dt) + abs(e.vx) * 0.001
      sink += ents[t mod n].x
      let ms = msSince(a)
      if t >= warmup: times.add ms
    doAssert sink != 0.0

  let heap = getOccupiedMem().float / (1024 * 1024)
  let p50 = pct(times, 0.5)
  let p99 = pct(times, 0.99)
  echo &"result entities={n} rules={k} variant={variant} ticks={ticks} warmup={warmup} " &
    &"setup_ms={setupMs:.3f} p50_ms={p50:.4f} p99_ms={p99:.4f} heap_mb={heap:.1f} " &
    &"rss_mb={memLine(\"VmRSS\")} hwm_mb={memLine(\"VmHWM\")}"

main()
