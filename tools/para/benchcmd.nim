# `para bench`: the measurement tool behind the per-game-class performance
# gate. Three subcommands, each printing p50/p99 in milliseconds, resident
# memory and the machine it ran on:
#
# - `rules`: pararules per-tick cost at N entities under K per-entity rules
#   (tools/para/bench/rules_bench.nim), next to the same writes from a plain
#   loop ("systems") and the same arithmetic with no session ("plain"), plus
#   a per-entity least-squares fit of time and memory across the counts (the
#   storage-attribution method).
# - `sprites`: paranim's instanced sprite batch in a hidden window
#   (tools/para/bench/sprite_bench.nim): the CPU add, submit, GPU and wait
#   parts of a frame for N sprites in C draw calls, and the GL renderer.
# - `build`: a game's forced debug and release compile times, an unchanged
#   rebuild, and the binary sizes.
#
# The measuring programs are built here with the `nim` on PATH (release
# unless --debug) into tmp/bench/ and run once per (count, variant, repeat),
# each in a fresh process, so resident memory belongs to one run; a row is
# the median of its repeats. `para` itself never times anything it runs in
# process, so its own debug build does not colour the numbers.
#
# Exit codes: 0 measured; 1 a finding (a row over --budget-ms, a build that
# failed, no display for `sprites`); 2 a usage error.

import std/[os, osproc, strformat, strutils, sequtils, algorithm, tables, monotimes]
import art/[clihelpers, toon]
import nimutil
import games

type Run = clihelpers.Run

const tickMs = 1000.0 / 60.0

const benchHelp* = "para bench <rules|sprites|build> [flags]\n" &
  "  measure what the per-game-class performance gate needs: p50/p99 in ms, resident memory, the machine\n" &
  "  rules [--n 100,300,1000] [--rules 3] [--ticks 300] [--warmup 30] [--repeat 3] [--debug] [--budget-ms X]\n" &
  "    pararules per tick at N entities with K (1-3) per-entity rules fired by one DeltaTime insert, next to\n" &
  "    the systems pattern (a loop writing the same facts) and plain (the same math, no session); a\n" &
  "    per-entity fit across the counts; --budget-ms X: exit 1 when a rules row's p99 is over X\n" &
  "  sprites [--n 1000,5000,10000] [--calls 1] [--frames 90] [--warmup 10] [--repeat 3] [--debug] [--budget-ms X]\n" &
  "    paranim's sprite batch in a hidden 1280x720 window: CPU add, submit, GPU and wait per frame for N\n" &
  "    sprites in C draw calls (each --calls value for each --n); needs a display (exit 1 without one);\n" &
  "    --budget-ms X: exit 1 when a row's p99 frame is over X\n" &
  "  build [--game NAME] [--skip-release]\n" &
  "    forced debug build, unchanged rebuild and forced release build of a game (default hello): seconds\n" &
  "    and binary bytes; --skip-release leaves out the slow forced release build\n" &
  "  the programs are built release (unless --debug) with the nim on PATH into tmp/bench/; each row is\n" &
  "  the median of --repeat fresh-process runs; for steadier numbers close other programs, and on Linux\n" &
  "  set the performance governor and pin a core (taskset -c 2 para bench rules)\n"

# --- machine ------------------------------------------------------------------

proc readFirst(path: string): string =
  try: readFile(path).splitLines[0].strip
  except IOError, OSError, IndexDefect: ""

proc cpuModel(): string =
  try:
    for line in readFile("/proc/cpuinfo").splitLines:
      if line.startsWith("model name"):
        return line.split(":", 1)[1].strip
  except IOError, OSError:
    discard
  when defined(macosx):
    let r = runCaptured("sysctl", @["-n", "machdep.cpu.brand_string"])
    if r.exitCode == 0: return r.output.strip
  getEnv("PROCESSOR_IDENTIFIER", "unknown")

proc ramGb(): string =
  try:
    for line in readFile("/proc/meminfo").splitLines:
      if line.startsWith("MemTotal:"):
        let kb = line[9 .. ^1].strip.split(' ')[0].parseInt
        return formatFloat(kb.float / 1024 / 1024, ffDecimal, 1) & " GB"
  except IOError, OSError, ValueError:
    discard
  "unknown"

proc firstLine(cmd: string, args: seq[string]): string =
  let r = runCaptured(cmd, args)
  if r.exitCode != 0: return "unknown"
  r.output.splitLines[0].strip

proc machineLine*(): string =
  ## One TOON-ish line naming the machine: CPU, threads, RAM, OS and kernel,
  ## the CPU governor and load average where Linux reports them, and the nim
  ## and C compiler the programs are built with.
  let kernel = readFirst("/proc/sys/kernel/osrelease")
  let governor = readFirst("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
  let load = readFirst("/proc/loadavg").split(' ')[0]
  var nimVer = firstLine("nim", @["--version"])
  let at = nimVer.find("Version ")
  if at >= 0: nimVer = nimVer[at + 8 .. ^1].split(' ')[0]
  let cc = firstLine("gcc", @["-dumpfullversion"])
  result = "machine: cpu " & toonCell(cpuModel()) & &", {countProcessors()} threads, ram {ramGb()}, " &
    &"os {hostOS}" & (if kernel.len > 0: " " & kernel else: "") &
    (if governor.len > 0: ", governor " & governor else: "") &
    (if load.len > 0: ", load " & load else: "") &
    &", nim {nimVer}, gcc {cc}\n"

# --- shared parsing -------------------------------------------------------------

proc parseCounts(flag, s: string, minimum: int, counts: var seq[int]): string =
  ## `"100,300,1000"` -> counts; "" when fine, else the error.
  counts.setLen 0
  for tok in s.split(','):
    let t = tok.strip
    var v: int
    try:
      v = t.parseInt
    except ValueError:
      return &"{flag} takes whole numbers separated by commas, got \"{s}\""
    if v < minimum:
      return &"{flag} values must be at least {minimum}, got {v}"
    counts.add v
  if counts.len == 0:
    return &"{flag} needs at least one number"

proc parseIntFlag(flag, s: string, lo, hi: int, v: var int): string =
  try:
    v = s.parseInt
  except ValueError:
    return &"{flag} takes a whole number, got \"{s}\""
  if v < lo or v > hi:
    return &"{flag} must be between {lo} and {hi}, got {v}"

proc parseResult*(output: string): Table[string, string] =
  ## The `key=value` fields of a measuring program's `result` line (empty
  ## table when there is none).
  for line in output.splitLines:
    if line.startsWith("result "):
      for field in line[7 .. ^1].splitWhitespace:
        let kv = field.split('=', 1)
        if kv.len == 2: result[kv[0]] = kv[1]

proc linePrefixed(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix): return line[prefix.len .. ^1].strip

proc median(xs: seq[float]): float =
  if xs.len == 0: return 0.0
  var s = xs
  s.sort()
  s[(s.len - 1) div 2]

proc fieldF(t: Table[string, string], key: string): float =
  try: t.getOrDefault(key, "nan").parseFloat
  except ValueError: NaN

proc fmt3(x: float): string =
  if x != x: "n/a" else: formatFloat(x, ffDecimal, 3)

proc fmt4(x: float): string =
  if x != x: "n/a" else: formatFloat(x, ffDecimal, 4)

proc fmt1(x: float): string =
  if x != x: "n/a" else: formatFloat(x, ffDecimal, 1)

proc medianOf(runs: seq[Table[string, string]], key: string): float =
  var xs: seq[float]
  for r in runs:
    let v = r.fieldF(key)
    if v == v: xs.add v
  if xs.len == 0: NaN else: median(xs)

type Fit* = tuple[slope, intercept: float]

proc leastSquares*(xs, ys: seq[float]): Fit =
  ## y = intercept + slope * x over the points; (NaN, NaN) with fewer than two
  ## distinct x.
  let n = xs.len.float
  if xs.len < 2 or xs.deduplicate.len < 2: return (NaN, NaN)
  var sx, sy, sxx, sxy = 0.0
  for i in 0 ..< xs.len:
    sx += xs[i]; sy += ys[i]; sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i]
  let slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
  (slope, (sy - slope * sx) / n)

proc overBudget*(rows: seq[seq[string]], p99Col: int, budgetMs: float, onlyVariant = ""): seq[int] =
  ## The indices of `rows` whose p99 (column `p99Col`, in ms) is over
  ## `budgetMs`; with `onlyVariant`, only rows whose column 2 is that variant.
  for i, row in rows:
    if onlyVariant.len > 0 and row[2] != onlyVariant: continue
    let v = try: row[p99Col].parseFloat except ValueError: NaN
    if v == v and v > budgetMs: result.add i

# --- building the measuring programs ----------------------------------------------

proc buildProgram(name: string, debug: bool, outPath: var string): Run =
  ## Compiles tools/para/bench/<name>.nim to tmp/bench/<name>_<r|d>; code 0, or
  ## the compiler's errors (exit 1).
  createDir("tmp" / "bench")
  outPath = "tmp" / "bench" / (name & (if debug: "_d" else: "_r") & ExeExt)
  var args = @["c", "--hints:off"]
  if not debug: args.add "-d:release"
  args.add @["-o:" & outPath, "tools" / "para" / "bench" / (name & ".nim")]
  let res = runCaptured("nim", args)
  if res.exitCode == 0: return ("", 0)
  let diags = parseNimDiagnostics(res.output).filterIt(it.severity == "Error")
  if diags.len > 0:
    result.output = &"error: the {name} program failed to build\n" &
      toonTable("errors", ["at", "msg"], diags.mapIt(@[it.at, it.msg]))
  else:
    result.output = &"error: the {name} program failed to build\n" & lastLines(res.output, 20)
  result.code = 1

# --- rules ----------------------------------------------------------------------

proc runRules(args: seq[string]): Run =
  var counts = @[100, 300, 1000]
  var k = 3
  var ticks = 300
  var warmup = 30
  var repeat = 3
  var debug = false
  var budget = 0.0
  var i = 0
  while i < args.len:
    let a = args[i]
    let v = if i + 1 < args.len: args[i + 1] else: ""
    var bad = ""
    case a
    of "--help", "-h": return (benchHelp, 0)
    of "--n":
      if v.len == 0: return errorOut("--n needs entity counts, e.g. --n 100,300,1000", @[])
      bad = parseCounts("--n", v, 1, counts); inc i
    of "--rules":
      if v.len == 0: return errorOut("--rules needs a number from 1 to 3", @[])
      bad = parseIntFlag("--rules", v, 1, 3, k); inc i
    of "--ticks":
      if v.len == 0: return errorOut("--ticks needs a number", @[])
      bad = parseIntFlag("--ticks", v, 1, 1_000_000, ticks); inc i
    of "--warmup":
      if v.len == 0: return errorOut("--warmup needs a number", @[])
      bad = parseIntFlag("--warmup", v, 0, 1_000_000, warmup); inc i
    of "--repeat":
      if v.len == 0: return errorOut("--repeat needs a number", @[])
      bad = parseIntFlag("--repeat", v, 1, 99, repeat); inc i
    of "--debug": debug = true
    of "--budget-ms":
      if v.len == 0: return errorOut("--budget-ms needs a number of milliseconds", @[])
      try: budget = v.parseFloat
      except ValueError: return errorOut(&"--budget-ms takes a number, got \"{v}\"", @[])
      if not (budget > 0 and budget < Inf): return errorOut(&"--budget-ms must be above 0, got \"{v}\"", @[])
      inc i
    else:
      return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --n N[,N...], --rules K, --ticks N, --warmup N, --repeat N, --debug, --budget-ms X"])
    if bad.len > 0: return errorOut(bad, @[])
    inc i

  var exe: string
  let built = buildProgram("rules_bench", debug, exe)
  if built.code != 0: return built

  var rows: seq[seq[string]]
  var fitN, fitP50, fitP99, fitRss: seq[float]
  for n in counts:
    for variant in ["rules", "systems", "plain"]:
      var runs: seq[Table[string, string]]
      for r in 1 .. repeat:
        let res = runCaptured(exe.absolutePath, @["--n", $n, "--rules", $k, "--ticks", $ticks,
                                                  "--warmup", $warmup, "--variant", variant])
        let fields = parseResult(res.output)
        if res.exitCode != 0 or fields.len == 0:
          return (&"error: rules_bench failed at {n} entities, {variant}\n" & lastLines(res.output, 20), 1)
        runs.add fields
      let p50 = runs.medianOf("p50_ms")
      let p99 = runs.medianOf("p99_ms")
      let rss = runs.medianOf("rss_mb")
      rows.add @[$n, $k, variant, fmt4(p50), fmt4(p99), fmt1(p99 / tickMs * 100),
                 fmt3(runs.medianOf("setup_ms")), fmt1(rss), fmt1(runs.medianOf("heap_mb"))]
      if variant == "rules":
        fitN.add n.float; fitP50.add p50; fitP99.add p99; fitRss.add rss

  let mode = if debug: "debug" else: "release"
  result.output = &"bench: rules, {mode} build, {ticks} ticks after {warmup} warm-up, median of {repeat} " &
    &"run{(if repeat == 1: \"\" else: \"s\")}, dt 1/60s (tick {fmt3(tickMs)}ms)\n"
  result.output.add machineLine()
  result.output.add toonTable("results",
    ["entities", "rules", "variant", "p50_ms", "p99_ms", "p99_tick_pct", "setup_ms", "rss_mb", "heap_mb"], rows)
  let t50 = leastSquares(fitN, fitP50)
  let t99 = leastSquares(fitN, fitP99)
  let mem = leastSquares(fitN, fitRss)
  if t50.slope == t50.slope:
    result.output.add &"fit: rules variant per entity under {k} rule{(if k == 1: \"\" else: \"s\")} (least squares over {fitN.len} counts): " &
      &"p50 {fmt3(t50.slope * 1000)}us, p99 {fmt3(t99.slope * 1000)}us, " &
      &"rss {(if mem.slope == mem.slope: fmt1(mem.slope * 1024) & \"KB\" else: \"n/a\")}\n"
  if budget > 0:
    let over = overBudget(rows, 4, budget, "rules")
    if over.len > 0:
      result.output.add &"gate: rules p99 under {fmt3(budget)}ms: FAIL at " &
        over.mapIt(rows[it][0] & " entities").join(", ") & "\n"
      result.code = 1
    else:
      result.output.add &"gate: rules p99 under {fmt3(budget)}ms: pass\n"
  result.output.add toonHelp(@[
    "Run `para bench sprites` for the draw side and `para bench build` for compile times",
    "A game's own split of a tick into rules and systems: build its driver with -d:prof (paraloop/prof)"])

# --- sprites --------------------------------------------------------------------

proc runSprites(args: seq[string]): Run =
  var counts = @[1000, 5000, 10000]
  var calls = @[1]
  var frames = 90
  var warmup = 10
  var repeat = 3
  var debug = false
  var budget = 0.0
  var i = 0
  while i < args.len:
    let a = args[i]
    let v = if i + 1 < args.len: args[i + 1] else: ""
    var bad = ""
    case a
    of "--help", "-h": return (benchHelp, 0)
    of "--n":
      if v.len == 0: return errorOut("--n needs sprite counts, e.g. --n 1000,5000", @[])
      bad = parseCounts("--n", v, 1, counts); inc i
    of "--calls":
      if v.len == 0: return errorOut("--calls needs draw call counts, e.g. --calls 1,10,100", @[])
      bad = parseCounts("--calls", v, 1, calls); inc i
    of "--frames":
      if v.len == 0: return errorOut("--frames needs a number", @[])
      bad = parseIntFlag("--frames", v, 1, 1_000_000, frames); inc i
    of "--warmup":
      if v.len == 0: return errorOut("--warmup needs a number", @[])
      bad = parseIntFlag("--warmup", v, 0, 1_000_000, warmup); inc i
    of "--repeat":
      if v.len == 0: return errorOut("--repeat needs a number", @[])
      bad = parseIntFlag("--repeat", v, 1, 99, repeat); inc i
    of "--debug": debug = true
    of "--budget-ms":
      if v.len == 0: return errorOut("--budget-ms needs a number of milliseconds", @[])
      try: budget = v.parseFloat
      except ValueError: return errorOut(&"--budget-ms takes a number, got \"{v}\"", @[])
      if not (budget > 0 and budget < Inf): return errorOut(&"--budget-ms must be above 0, got \"{v}\"", @[])
      inc i
    else:
      return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --n N[,N...], --calls C[,C...], --frames N, --warmup N, --repeat N, --debug, --budget-ms X"])
    if bad.len > 0: return errorOut(bad, @[])
    inc i
  for n in counts:
    for c in calls:
      if c > n: return errorOut(&"--calls {c} is more draw calls than --n {n} sprites", @[])

  var exe: string
  let built = buildProgram("sprite_bench", debug, exe)
  if built.code != 0: return built

  var rows: seq[seq[string]]
  var renderer, glVersion = ""
  for n in counts:
    for c in calls:
      var runs: seq[Table[string, string]]
      for r in 1 .. repeat:
        let res = runCaptured(exe.absolutePath, @["--n", $n, "--calls", $c, "--frames", $frames,
                                                  "--warmup", $warmup])
        if res.exitCode == 3:
          return ("error: no display: `para bench sprites` draws in a hidden GL 3.3 window\n" &
            toonHelp(@["Run it in a desktop session, or under a virtual display (xvfb-run para bench sprites)"]), 1)
        let fields = parseResult(res.output)
        if res.exitCode != 0 or fields.len == 0:
          return (&"error: sprite_bench failed at {n} sprites, {c} calls\n" & lastLines(res.output, 20), 1)
        if renderer.len == 0:
          renderer = linePrefixed(res.output, "renderer:")
          glVersion = linePrefixed(res.output, "gl-version:")
        runs.add fields
      let p99 = runs.medianOf("p99_ms")
      rows.add @[$n, $c, fmt3(runs.medianOf("add_ms")), fmt3(runs.medianOf("submit_ms")),
                 fmt3(runs.medianOf("gpu_ms")), fmt3(runs.medianOf("wait_ms")),
                 fmt3(runs.medianOf("p50_ms")), fmt3(p99), fmt1(runs.medianOf("rss_mb"))]

  let mode = if debug: "debug" else: "release"
  result.output = &"bench: sprites, {mode} build, 1280x720 hidden window, 32px sprites, vsync off, " &
    &"{frames} frames after {warmup} warm-up, median of {repeat} run{(if repeat == 1: \"\" else: \"s\")}\n"
  result.output.add machineLine()
  result.output.add "gpu: renderer " & toonCell(renderer) & ", gl " & toonCell(glVersion) & "\n"
  result.output.add toonTable("results",
    ["sprites", "calls", "add_ms", "submit_ms", "gpu_ms", "wait_ms", "p50_ms", "p99_ms", "rss_mb"], rows)
  if budget > 0:
    let over = overBudget(rows, 7, budget)
    if over.len > 0:
      result.output.add &"gate: frame p99 under {fmt3(budget)}ms: FAIL at " &
        over.mapIt(rows[it][0] & " sprites in " & rows[it][1] & " calls").join(", ") & "\n"
      result.code = 1
    else:
      result.output.add &"gate: frame p99 under {fmt3(budget)}ms: pass\n"
  result.output.add toonHelp(@[
    "add_ms is Nim-side work per sprite before OpenGL; gpu_ms is the GL_TIME_ELAPSED query; p50/p99 are the whole draw",
    "A game's own windowed frame split: build it with -d:prof (paraloop/prof), which prints a summary on close"])

# --- build ----------------------------------------------------------------------

proc timedBuild(args: seq[string], seconds: var float): ProcResult =
  let t0 = getMonoTime()
  result = runCaptured("nim", args)
  seconds = float(getMonoTime().ticks - t0.ticks) / 1e9

proc runBuildBench(args: seq[string]): Run =
  var gameName = "hello"
  var skipRelease = false
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h": return (benchHelp, 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      gameName = args[i]
    of "--skip-release": skipRelease = true
    else:
      return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --game NAME, --skip-release"])
    inc i
  var game: Game
  let notFound = resolveGame(gameName, game)
  if notFound.code != 0: return notFound

  let outDir = "tmp" / "bench" / "build"
  createDir(outDir)
  let dbg = outDir / (gameName & "_d" & ExeExt)
  let rel = outDir / (gameName & "_r" & ExeExt)
  var steps = @[("debug forced", @["c", "-f", "--hints:off", "-o:" & dbg, game.source], dbg),
                ("debug unchanged rebuild", @["c", "--hints:off", "-o:" & dbg, game.source], dbg)]
  if not skipRelease:
    steps.add ("release forced", @["c", "-f", "--hints:off", "-d:release", "-o:" & rel, game.source], rel)
  var rows: seq[seq[string]]
  for (label, nimArgs, outPath) in steps:
    var secs: float
    let res = timedBuild(nimArgs, secs)
    if res.exitCode != 0:
      let diags = parseNimDiagnostics(res.output).filterIt(it.severity == "Error")
      result.output = &"error: {gameName} failed to build ({label})\n"
      if diags.len > 0: result.output.add toonTable("errors", ["at", "msg"], diags.mapIt(@[it.at, it.msg]))
      else: result.output.add lastLines(res.output, 20)
      result.code = 1
      return
    rows.add @[label, formatFloat(secs, ffDecimal, 2), $getFileSize(outPath)]
  if not skipRelease and findExe("strip").len > 0:
    let stripped = outDir / (gameName & "_r_stripped" & ExeExt)
    let res = runCaptured("strip", @["-o", stripped, rel])
    if res.exitCode == 0:
      rows.add @["release stripped", "n/a", $getFileSize(stripped)]

  result.output = &"bench: build, {gameName} ({game.source}), into {outDir}/\n"
  result.output.add machineLine()
  result.output.add toonTable("builds", ["build", "seconds", "bytes"], rows)
  result.output.add toonHelp(@[
    "A forced build recompiles everything, the standard library included; an unchanged rebuild is the floor of an edit-and-run loop"])

# --- dispatch -------------------------------------------------------------------

proc runBench*(args: seq[string]): Run =
  ## `para bench rules|sprites|build`: bare or `--help` prints the usage, exit 0.
  if args.len == 0 or args[0] in ["--help", "-h"]:
    return (benchHelp, 0)
  let rest = args[1 .. ^1]
  case args[0]
  of "rules": runRules(rest)
  of "sprites": runSprites(rest)
  of "build": runBuildBench(rest)
  else:
    if args[0].startsWith("-"):
      errorOut(&"unknown flag \"{args[0]}\"", @["Valid commands: bench rules, bench sprites, bench build"])
    else:
      errorOut(&"unknown command \"bench {args[0]}\"", @["Valid commands: bench rules, bench sprites, bench build"])
