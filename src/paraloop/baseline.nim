## Measured baselines for balance tests (S4 of the balance-switch scout): a game
## measures a handful of integer metrics from deterministic bot runs, commits them
## in a TOML file, and a balance test asserts "the metric is still within a stated
## tolerance of the committed number" plus a loose design bound. A legitimate
## balance change then moves the numbers on purpose and the fix is one command
## (the game's balance driver command, `rebase`) and a reviewed diff, not a hunt for hand-typed windows.
##
## Headless and pure: no GL, no file system beyond `loadBaseline`, no clock.
## A metric key is `probe.seed.name` (`pace.s8.lock1_ticks`); a name ending in
## `_ticks` is a tick count (its tolerance band has a floor of a couple of
## seconds), anything else is a plain count.
##
## The file shape (`parseBaseline` / `renderBaseline`), flat so `paraloop/toml`
## reads it:
##
##   tolerance_pct = 10
##   tolerance_floor_ticks = 120
##   tolerance_floor_count = 1
##
##   pace.s8.lock1_ticks = 1980
##   ...

import std/[strutils, strformat, tables, options, os]
import ./toml

type
  Metric* = tuple[key: string, value: int]
  Metrics* = seq[Metric]

  Tolerance* = object
    pct*: int           ## the relative band, percent of the baseline value
    floorTicks*: int    ## the smallest band a `_ticks` metric gets
    floorCount*: int    ## the smallest band any other metric gets

  Baseline* = object
    tol*: Tolerance
    metrics*: Metrics

  Bound* = object
    ## A loose design bound: a fence around the baseline that only moves when a
    ## design target does (so `rebase` refuses to write a baseline outside it).
    pattern*: string    ## a metric key where a `*` part matches any one part (`pace.*.lock1_ticks`)
    lo*, hi*: int
    why*: string

  DriftKind* = enum
    dkSame      ## measured equals the baseline
    dkWithin    ## moved, but inside the tolerance band
    dkOut       ## moved past the band
    dkNew       ## measured, no baseline entry
    dkGone      ## a baseline entry the run did not measure

  Drift* = object
    key*: string
    kind*: DriftKind
    baseline*, measured*: int   ## the side that is absent reads 0
    band*: int                  ## the tolerance band around `baseline` (0 for dkNew/dkGone)

const
  defaultTolerance* = Tolerance(pct: 10, floorTicks: 120, floorCount: 1)
    ## 10% of the baseline, at least 120 ticks (2 s of game time) for a tick
    ## metric, at least 1 for a count. Wide enough that a nudge to a spawn
    ## interval does not ask for a rebase, narrow enough that a real pace change
    ## does (the loose design bounds are the fence against drift that adds up).
  baselineFileName* = "balance.baseline.toml"
    ## Next to the game's `tuning.toml`.

proc probeOf*(key: string): string =
  ## `pace.s8.lock1_ticks` -> `pace`.
  key.split('.')[0]

proc isTicks*(key: string): bool = key.endsWith("_ticks")

proc bandFor*(tol: Tolerance, key: string, baseline: int): int =
  ## The allowed distance from `baseline`: `pct` percent of it, rounded up, and
  ## never below the floor for this kind of metric.
  let floor = if key.isTicks: tol.floorTicks else: tol.floorCount
  max(floor, (abs(baseline) * tol.pct + 99) div 100)

proc keyMatches*(pattern, key: string): bool =
  let p = pattern.split('.')
  let k = key.split('.')
  if p.len != k.len: return false
  for i in 0 ..< p.len:
    if p[i] != "*" and p[i] != k[i]: return false
  true

# --- the file ---------------------------------------------------------------

proc parseBaseline*(content: string): Baseline =
  ## `ValueError` naming the key for a value that is not an integer or a
  ## tolerance that makes no sense.
  let doc = parseToml(content)
  result.tol = defaultTolerance
  for key, raw in doc.top:
    case key
    of "tolerance_pct": result.tol.pct = doc.top.getInt(key, 0)
    of "tolerance_floor_ticks": result.tol.floorTicks = doc.top.getInt(key, 0)
    of "tolerance_floor_count": result.tol.floorCount = doc.top.getInt(key, 0)
    else:
      result.metrics.add (key, doc.top.getInt(key, 0))
  if result.tol.pct < 0 or result.tol.floorTicks < 0 or result.tol.floorCount < 0:
    raise newException(ValueError, "a baseline tolerance cannot be negative")

proc loadBaseline*(path: string): Baseline =
  parseBaseline(readFile(path))

proc renderBaseline*(header: string, tol: Tolerance, metrics: Metrics): string =
  ## The whole file: `header` as `#` lines, the tolerance, then one blank-line
  ## separated block per probe, in the order of `metrics`.
  for line in header.splitLines:
    result.add (if line.len > 0: "# " & line else: "#") & "\n"
  result.add "\n"
  result.add &"tolerance_pct = {tol.pct}\n"
  result.add &"tolerance_floor_ticks = {tol.floorTicks}\n"
  result.add &"tolerance_floor_count = {tol.floorCount}\n"
  var last = ""
  for m in metrics:
    let probe = m.key.probeOf
    if probe != last:
      result.add "\n"
      last = probe
    result.add &"{m.key} = {m.value}\n"

proc valueOf*(metrics: Metrics, key: string): Option[int] =
  for m in metrics:
    if m.key == key: return some(m.value)

proc merged*(old, fresh: Metrics, probes: seq[string]): Metrics =
  ## `old` with the metrics of `probes` replaced by `fresh` (all of `old` is
  ## replaced when `probes` is empty). Keys keep `fresh`'s order inside a probe;
  ## a probe `old` lacks goes last.
  if probes.len == 0: return fresh
  var order: seq[string]
  for m in old & fresh:
    if m.key.probeOf notin order: order.add m.key.probeOf
  for probe in order:
    if probe in probes:
      for m in fresh:
        if m.key.probeOf == probe: result.add m
    else:
      for m in old:
        if m.key.probeOf == probe: result.add m

# --- comparing ----------------------------------------------------------------

proc compare*(base: Baseline, measured: Metrics, scopes: seq[string] = @[]): seq[Drift] =
  ## One `Drift` per measured metric, then one `dkGone` per baseline entry in
  ## `scopes` (key prefixes such as `hub.s7.`; every entry when empty) that
  ## `measured` lacks.
  var seen: Table[string, bool]
  for m in measured:
    seen[m.key] = true
    let was = base.metrics.valueOf(m.key)
    if was.isNone:
      result.add Drift(key: m.key, kind: dkNew, measured: m.value)
      continue
    let band = base.tol.bandFor(m.key, was.get)
    let kind =
      if m.value == was.get: dkSame
      elif abs(m.value - was.get) <= band: dkWithin
      else: dkOut
    result.add Drift(key: m.key, kind: kind, baseline: was.get, measured: m.value, band: band)
  for b in base.metrics:
    if b.key in seen: continue
    var inScope = scopes.len == 0
    for s in scopes:
      if b.key.startsWith(s): inScope = true
    if inScope:
      result.add Drift(key: b.key, kind: dkGone, baseline: b.value)

proc deltaText*(d: Drift): string =
  ## `+210 (+9.5%)`; `-` for a metric on one side only.
  if d.kind in {dkNew, dkGone}: return "-"
  let diff = d.measured - d.baseline
  let sign = if diff >= 0: "+" else: ""
  if d.baseline == 0: return &"{sign}{diff}"
  let pct = diff.float * 100.0 / abs(d.baseline).float
  &"{sign}{diff} ({sign}{formatFloat(pct, ffDecimal, 1)}%)"

proc describe*(d: Drift, tol: Tolerance): string =
  ## One line a failing test prints.
  case d.kind
  of dkSame, dkWithin: &"{d.key}: {d.baseline} -> {d.measured} (within the band)"
  of dkOut:
    &"{d.key}: baseline {d.baseline}, measured {d.measured}, {d.deltaText}, past the band of +-{d.band} " &
      &"({tol.pct}%)"
  of dkNew: &"{d.key}: measured {d.measured}, but the baseline has no entry for it"
  of dkGone: &"{d.key}: the baseline has {d.baseline}, but this run did not measure it " &
    "(the event never happened inside the probe's tick budget, or the probe changed)"

proc drifted*(drifts: seq[Drift]): seq[Drift] =
  ## The ones a check fails on.
  for d in drifts:
    if d.kind in {dkOut, dkNew, dkGone}: result.add d

# --- bounds -------------------------------------------------------------------

proc boundFor*(bounds: seq[Bound], key: string): Option[Bound] =
  for b in bounds:
    if b.pattern.keyMatches(key): return some(b)

proc violations*(bounds: seq[Bound], measured: Metrics): seq[string] =
  ## A line per measured metric outside the bound its key matches.
  for m in measured:
    let b = bounds.boundFor(m.key)
    if b.isSome and m.value notin b.get.lo .. b.get.hi:
      result.add &"{m.key}: {m.value} is outside the design bound {b.get.lo} .. {b.get.hi} ({b.get.why})"

proc problems*(base: Baseline, bounds: seq[Bound], measured: Metrics,
               scopes: seq[string] = @[]): seq[string] =
  ## Everything a balance test fails on for `measured`, one line each: a metric
  ## past its band, one the baseline has never seen, a baseline entry in
  ## `scopes` that was not measured, and a metric outside its design bound.
  for d in base.compare(measured, scopes).drifted:
    result.add d.describe(base.tol)
  result.add bounds.violations(measured)

proc rebaseHint*(path: string): string =
  &"if it moved on purpose and stays inside the design bounds: " &
    &"the game's balance driver `rebase` command, then review `git diff {path.extractFilename}`"
