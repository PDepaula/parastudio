# `para test`: wraps `nimble test` (engine report §5.3 rank 2) with a TOON
# summary instead of ~60 lines of `[OK]`/pytest noise -- 0 lines beyond the
# summary on a pass, a `failures[N]{suite,test,at}` table naming exactly what
# broke on a fail. nimble 0.22.2 exits 0 even when a task fails (AGENTS.md),
# so pass/fail comes from whether `tmp/tests-passed` was (re)written, not from
# `nimble`'s own exit code. `--filter` and `--area` narrow which test files
# run (testplan.nim picks them, the nimble task runs exactly that plan, so
# the files left out are never compiled). A full run records its outcome as the
# `tests` status of every game under examples/ (the games the repo suite in
# tests/ covers); a narrowed run records nothing, since it did not cover them.
# `--skip-balance` / `--only-balance` set PARALOOP_BALANCE for the run
# (paraloop/testkit reads it): the balance pins come back as `[SKIPPED]`, or
# are the only tests that run.
#
# Progress streams while nimble runs: the `test` task echoes `running <entry>`
# before each plan entry, and a finished entry's pass/fail line goes to stderr
# as soon as the next one starts (stdout stays the one TOON result), so a long
# run is visible, and a caller that cuts it off at a time cap keeps the lines
# so far. There is no timeout in here: the caller owns the cap.
#
# A selection that holds every test file of a test group (testplan.nim) runs
# them as that one program: one compile instead of one a file. The count, the
# progress lines and the failures table are still per test file: the task
# echoes `building <group>`, then the program prints `running <file>` as each
# file's tests start and `finished <group>` after the last.

import std/[os, strutils, strformat, sequtils, times]
import art/[clihelpers, toon]
import nimutil
import games
import testplan
from paraloop/testkit import balanceEnv, runningPrefix, finishedPrefix

type
  Run = clihelpers.Run

  TestFailure* = object
    suite*, test*, at*, msg*: string

  TestSummary* = object
    passed*, failed*, skipped*, suites*: int
    failures*: seq[TestFailure]

proc parseCheckpointAt(line: string): tuple[at, msg: string] =
  ## `"<file>.nim(<line>, <col>): <rest>"` -> `("file:line", rest)`, or
  ## `("", "")` when `line` isn't a checkpoint (std/unittest's `check` prints
  ## its failure checkpoint exactly this way -- `lineinfo & ": Check failed: " & callLit`).
  let sline = line.strip
  let nimIdx = sline.find(".nim(")
  if nimIdx < 0: return ("", "")
  var file = sline[0 .. nimIdx + 3]
  if file.isAbsolute: file = file.relativePath(getCurrentDir())
  let afterParen = sline[nimIdx + 5 .. ^1]
  let closeIdx = afterParen.find(')')
  if closeIdx < 0: return ("", "")
  let lc = afterParen[0 ..< closeIdx].split(',')
  if lc.len < 1: return ("", "")
  var rest = afterParen[closeIdx + 1 .. ^1]
  if rest.startsWith(":"): rest = rest[1 .. ^1]
  (file & ":" & lc[0].strip, rest.strip)

proc parseUnittestOutput*(output: string, summary: var TestSummary) =
  ## std/unittest's console formatter: `[Suite] name`, then per test
  ## `[OK]`/`[FAILED]`/`[SKIPPED] name`. A failing check prints its
  ## checkpoint (`file(line, col): Check failed: ...`) while the test runs,
  ## so before that test's `[FAILED]` line (`failureOccurred`, then
  ## `testEnded`): the first checkpoint since the previous result or suite
  ## line belongs to the next `[FAILED]`.
  var currentSuite = ""
  var pending: tuple[at, msg: string]
  for rawLine in output.splitLines:
    let line = rawLine.strip
    if line.startsWith("[Suite] "):
      currentSuite = line["[Suite] ".len .. ^1]
      inc summary.suites
      pending = ("", "")
    elif line.startsWith("[OK] "):
      inc summary.passed
      pending = ("", "")
    elif line.startsWith("[SKIPPED] "):
      inc summary.skipped
      pending = ("", "")
    elif line.startsWith("[FAILED] "):
      inc summary.failed
      summary.failures.add TestFailure(suite: currentSuite, test: line["[FAILED] ".len .. ^1],
                                       at: pending.at, msg: pending.msg)
      pending = ("", "")
    elif pending.at.len == 0:
      pending = parseCheckpointAt(line)

proc parsePytestSummary*(output: string, summary: var TestSummary) =
  ## `tools/art/`'s python tests run as `pytest -q`, whose only summary line
  ## looks like `16 passed in 0.42s` or `2 failed, 14 passed in 1.23s`.
  for rawLine in output.splitLines:
    let line = rawLine.strip
    let cut = line.rfind(" in ")
    if cut < 0: continue
    let tail = line[cut + 4 .. ^1]
    if tail.len < 2 or tail[^1] != 's': continue
    let durDigits = tail[0 ..< ^1].replace(".", "")
    if durDigits.len == 0 or not durDigits.allCharsInSet(Digits): continue
    var any = false
    for tok in line[0 ..< cut].split(", "):
      let parts = tok.strip.split(' ')
      if parts.len == 2 and parts[0].len > 0 and parts[0].allCharsInSet(Digits):
        let n = parts[0].parseInt
        case parts[1]
        of "passed": summary.passed += n; any = true
        of "failed", "error", "errors": summary.failed += n; any = true
        of "skipped": summary.skipped += n; any = true
        else: discard
    if any: break # the first (only, with -q) matching summary line

const testHelp = "para test [--filter SUBSTR] [--area AREA[,AREA...]] [--skip-balance | --only-balance] [--shard I/N] [--full]\n" &
  "  wraps `nimble test`; bare, it runs every test file\n" &
  "  --filter SUBSTR  run only the test files whose path contains SUBSTR (the rest are not compiled)\n" &
  "  --area AREA      run only the test files that reach that part of the repo: game, art,\n" &
  "                   engine or all (engine and all run everything)\n" &
  "  --skip-balance   skip the balance pins (numeric windows and counts tagged with paraloop/testkit's\n" &
  "                   balanceTest/playtestRule); the true invariants still run. Skipped tests print as\n" &
  "                   [SKIPPED] and the summary counts them. For a change whose balance you playtest yourself\n" &
  "  --only-balance   run only the files that tag balance pins, and in them only those tests\n" &
  "  --shard I/N      run the I-th of N slices of the selection (after --area/--filter/the balance\n" &
  "                   flags); the N shards together are exactly the unsharded selection; pytest rides\n" &
  "                   with shard 1 only and the final para build with none (CI builds para first)\n" &
  "  --full           append the whole output\n" &
  "  progress: one `progress I/N: <entry>: pass|FAIL` line per test file goes to stderr as the run\n" &
  "                   goes (no timeout here: split a long run with --filter)\n" &
  "  groups: a selection with every test file of a test group (games/<game>/tests/pin_tests.nim:\n" &
  "                   the balance pin files) builds them as that one program; --filter one to build it alone\n" &
  "  goldens: a failing golden is not fixed locally; CI or a human re-renders them\n" &
  "  PARALOOP_BALANCE=skip|only does the same for a bare `nimble test`; the flags set it for you\n"

proc countsLine*(summary: TestSummary): string =
  ## `N passed, N failed`, plus `, N skipped` once a test skipped itself (a
  ## balance pin under `--skip-balance`), so a skip is never silent.
  result = &"{summary.passed} passed, {summary.failed} failed"
  if summary.skipped > 0: result.add &", {summary.skipped} skipped"

const planFile = "tmp" / "test-plan.txt"

const buildingPrefix = "building "
  ## What paraloop.nimble's `test` task echoes before it builds a test group
  ## (`runningPrefix`, from testkit, is what it echoes before any other entry).

type ProgressTracker* = object
  ## Turns the task's output, one line at a time, into one pass/fail line per
  ## test file (or pytest, or the para build). An entry fails when a `[FAILED]`
  ## line came out of it, or when the whole run did not pass and it was still
  ## in flight at the end (nimble stops at the first failing exec: a compile
  ## error or a crash has no `[FAILED]`). A test group's files each get their
  ## own line; the group itself gets one only when its build is what failed.
  current: string
  failed: bool
  building: bool ## `current` is a group being built: no test file of it has started
  done: int
  total: int

proc initProgress*(total: int): ProgressTracker =
  ProgressTracker(total: total)

proc progressLine*(index, total: int, entry: string, ok: bool): string =
  ## `progress 3/12: tests/test_life.nim: pass` (`FAIL` for a failure).
  &"progress {index}/{total}: {entry}: " & (if ok: "pass" else: "FAIL")

proc close(t: var ProgressTracker, ok: bool): string =
  ## The line of the entry in flight ("" when there is none); none is after.
  if t.current.len == 0: return ""
  inc t.done
  result = progressLine(t.done, t.total, t.current, ok)
  t.current = ""

proc feed*(t: var ProgressTracker, line: string): string =
  ## The progress line to print now, or "" when `line` finishes no entry.
  let s = line.strip
  if s.startsWith(runningPrefix):
    # a group's build ends when its first file starts: the build has no line of its own
    if t.building: t.current = ""
    result = t.close(not t.failed)
    t.current = s[runningPrefix.len .. ^1].strip
    t.failed = false
    t.building = false
  elif s.startsWith(buildingPrefix):
    result = t.close(not t.failed)
    t.current = s[buildingPrefix.len .. ^1].strip
    t.failed = false
    t.building = true
  elif s.startsWith(finishedPrefix):
    # a group ran to its end: its last file is over, whatever the run's outcome
    result = t.close(not t.failed)
  elif t.current.len > 0 and s.startsWith("[FAILED] "):
    t.failed = true

proc finish*(t: var ProgressTracker, runPassed: bool): string =
  ## The line of the entry still in flight once the run is over ("" if none is).
  t.close(runPassed and not t.failed)

const goldenHelp* = "A failing golden is not fixed locally: do not re-render or `para shot --update-golden`; " &
  "CI or a human re-renders goldens"

proc goldenFailureHelp*(failures: seq[TestFailure]): seq[string] =
  ## The help line to print when a failure is about golden frames, else none.
  ## A failure is about goldens when its suite, test, test file or failed
  ## check names them (`goldens: ...` suites, `goldensDir` checks).
  for f in failures:
    if "golden" in toLowerAscii(f.suite & " " & f.test & " " & f.at & " " & f.msg):
      return @[goldenHelp]

const checkPrefix = "Check failed: "

proc failuresTable*(failures: seq[TestFailure]): string =
  ## `failures[N]{suite,test,at}`, each row followed by its failed check (as
  ## the engine report's §5.3 sample shows) when the checkpoint names one.
  result = "failures[" & $failures.len & "]{suite,test,at}:\n"
  for f in failures:
    result.add "  " & toonRow(@[f.suite, f.test, f.at]) & "\n"
    if f.msg.startsWith(checkPrefix):
      result.add "  check: " & f.msg[checkPrefix.len .. ^1] & "\n"

proc runTest*(args: seq[string]): Run =
  var full = false
  var filter = ""
  var areas: set[Area]
  var skipBalance, onlyBalance = false
  var shard = noShard
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (testHelp, 0)
    of "--full":
      full = true
    of "--filter":
      inc i
      if i >= args.len: return errorOut("--filter needs a substring", @[])
      filter = args[i]
    of "--area":
      inc i
      if i >= args.len: return errorOut("--area needs a name", @["Valid areas: game, art, engine, all"])
      let bad = parseAreas(args[i], areas)
      if bad.len > 0:
        return errorOut(&"unknown area \"{bad}\"", @["Valid areas: game, art, engine, all"])
    of "--skip-balance":
      skipBalance = true
    of "--only-balance":
      onlyBalance = true
    of "--shard":
      inc i
      if i >= args.len: return errorOut("--shard needs INDEX/COUNT", @["Example: --shard 2/4 runs the second of four slices"])
      let bad = parseShard(args[i], shard)
      if bad.len > 0:
        return errorOut(&"bad --shard \"{args[i]}\": {bad}", @["Example: --shard 2/4 runs the second of four slices"])
    else:
      return errorOut(&"unknown flag \"{a}\"",
        @["Valid flags: --filter SUBSTR, --area AREA, --skip-balance, --only-balance, --shard I/N, --full"])
    inc i
  if skipBalance and onlyBalance:
    return errorOut("--skip-balance and --only-balance contradict each other",
      @["Pass one: --skip-balance runs everything but the pins, --only-balance runs just the pins"])

  let allFiles = discoverTests()
  let selected = selectTests(allFiles, areas, filter, onlyBalance)
  let sharded = shard.count > 1
  # pytest is not per-file work: on a sharded run only shard 1 carries it
  # (shardCarriesExtras), so it still runs exactly once. The final para build
  # is left out of a sharded run altogether: CI builds para before every shard.
  let pytest = wantsPytest(areas, filter, onlyBalance) and shard.shardCarriesExtras
  let paraBuild = wantsParaBuild(areas, filter, onlyBalance) and not sharded
  let narrowed = sharded or onlyBalance or filter.len > 0 or
    not (areas == {} or arAll in areas or arEngine in areas)
  # An empty *selection* is a usage error (a --filter that matches nothing);
  # an empty *shard* of a non-empty selection is not: fewer files than shards
  # is fine, and that shard passes with nothing to run.
  if selected.len == 0 and not wantsPytest(areas, filter, onlyBalance):
    if onlyBalance:
      return errorOut("no test file with balance pins matches" &
        (if filter.len > 0: &" --filter \"{filter}\"" else: "") &
        (if areas != {}: " in that area" else: ""),
        @["Balance pins are tagged with balanceTest/playtestRule from paraloop/testkit"])
    return errorOut(&"no test file matches --filter \"{filter}\"" &
      (if areas != {}: " in that area" else: ""),
      @["Run `para test --filter walk` for a substring of a path under tests/ or games/*/tests/"])
  let files = shardOf(selected, shard)

  if not dirExists("tmp"): createDir("tmp")
  discard tryRemoveFile("tmp" / "tests-passed")

  # A full run is the nimble task's own default; a narrowed one is a plan
  # file the task follows line by line.
  if narrowed:
    var plan: seq[string]
    if pytest: plan.add pytestId
    plan.add planEntries(files, discoverGroups())
    if paraBuild: plan.add paraBuildId
    writeFile(planFile, plan.join("\n") & "\n")
    putEnv("PARALOOP_TEST_PLAN", planFile)
  else:
    delEnv("PARALOOP_TEST_PLAN")

  # The flags override a PARALOOP_BALANCE the caller exported; with neither,
  # the caller's value (if any) passes through to the tests untouched.
  let balanceWas = getEnv(balanceEnv)
  let hadBalance = existsEnv(balanceEnv)
  if skipBalance: putEnv(balanceEnv, "skip")
  elif onlyBalance: putEnv(balanceEnv, "only")

  var progress = initProgress(files.len + ord(pytest) + ord(paraBuild))
  proc show(line: string) =
    if line.len > 0:
      stderr.writeLine line
      stderr.flushFile
  let started = epochTime()
  let p = runStreamed("nimble", @["test"], proc (line: string) = show(progress.feed(line)))
  let elapsed = epochTime() - started
  show(progress.finish(fileExists("tmp" / "tests-passed")))
  delEnv("PARALOOP_TEST_PLAN")
  if hadBalance: putEnv(balanceEnv, balanceWas) else: delEnv(balanceEnv)

  var summary: TestSummary
  parsePytestSummary(p.output, summary)
  parseUnittestOutput(p.output, summary)

  let shown = summary.failures
  let shardNote = if sharded: &" (shard {shard.index}/{shard.count})" else: ""
  let scope =
    if narrowed: &"{files.len} of {allFiles.len} test files{shardNote}" & (if pytest: " + pytest" else: "")
    else: &"all {allFiles.len} test files + pytest"

  let counts = countsLine(summary)
  let balanceLine =
    if skipBalance: "balance: pins skipped (--skip-balance)\n"
    elif onlyBalance: "balance: pins only (--only-balance)\n"
    else: ""
  let ok = fileExists("tmp" / "tests-passed") and summary.failed == 0
  var status: string
  if ok:
    result.output = &"tests: {counts} ({summary.suites} suites, {elapsed:.1f}s)\n"
    result.output.add &"ran: {scope}\n" & balanceLine
    result.code = 0
    status = &"{summary.passed} passed"
  elif summary.failures.len > 0:
    result.output = &"tests: {counts} ({summary.suites} suites, {elapsed:.1f}s)\n"
    result.output.add &"ran: {scope}\n" & balanceLine
    result.output.add failuresTable(shown)
    result.output.add toonHelp(@["Run `para test --filter <test file substring> --full` to rerun just that file with its whole output"] &
                               goldenFailureHelp(shown))
    result.code = 1
    status = counts
  else:
    result.output = &"error: `nimble test` failed with no unittest failure to list ({counts})\n"
    let diags = parseNimDiagnostics(p.output).filterIt(it.severity == "Error")
    if diags.len > 0:
      result.output.add toonTable("errors", ["at", "msg"], diags.mapIt(@[it.at, it.msg]))
    else:
      result.output.add lastLines(p.output, 20)
    result.output.add toonHelp(@["Run `para test --full` to see the whole output"])
    result.code = 1
    status = "failed"

  if not narrowed:
    for g in listGames():
      if g.dir.parentDir == "examples":
        recordStatus(g.name, "tests", status)

  if full:
    result.output.add "\nfull output:\n" & p.output
