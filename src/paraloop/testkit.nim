# Headless test helpers: stepTicks, replay runner, PNG/pixel asserts, golden compare.
# Placeholder (report §3.3) for those; what is here today is the balance switch.
#
# The balance switch marks a test as a numeric pin (a window, a count, a knob
# value the tests restate) so a change that moves balance on purpose can run
# everything else. `PARALOOP_BALANCE` picks the mode and `para test
# --skip-balance` / `--only-balance` set it:
#
#   unset, `on`  every test runs (the default, today's behaviour)
#   `skip`       balance tests are `[SKIPPED]`; the true invariants still run
#   `only`       only balance tests run; every plain `test` is `[SKIPPED]`
#
# A test file opts in with `import std/unittest except test` plus
# `import paraloop/testkit`, so the `test` it sees is the one below. Four tags:
#
#   test         a true invariant (determinism, no soft-lock, reachability, ...):
#                runs unless the mode is `only`; never skippable by `skip`
#   balanceTest  a numeric pin (a tick window, a count, a restated knob): the
#                whole test is skipped under `skip`
#   playtestRule the captain's own playtest rules (standing still dies, only the
#                wolf outruns you, ...): behaves as `balanceTest`, but is named
#                apart so a rule of his can only be skipped through the switch,
#                never loosened or deleted to make a change pass
#   mixedTest    one bot run feeds both an invariant and a pin, so the test
#                always runs and its `balance:` blocks are the part `skip` drops
#                (under `only` the whole test runs, invariants included)
#
# Skipping means the body does not execute, so a skipped test costs nothing.
# Suite-level setup that is expensive must be lazy for the same reason.
#
# A test group is one program that imports several test files, so they share one
# compile (a game's tests/pin_tests.nim; tools/para/testplan.nim picks when
# it runs in their place). Built with `-d:paraloopTestGroup`, each of the four tags
# prints `running <test file>` before the first test of its file, the line
# paraloop.nimble's `test` task echoes before a file it runs on its own, so `para
# test`'s progress and a reader of the output still see which file a test is from.

import std/[unittest, os, strutils]

type BalanceMode* = enum
  bmAll = "on"
  bmSkip = "skip"
  bmOnly = "only"

const balanceEnv* = "PARALOOP_BALANCE"
  ## The environment variable `para test --skip-balance|--only-balance` sets.

proc parseBalanceMode*(s: string): BalanceMode =
  ## `""`/`on` -> every test, `skip` -> no pins, `only` -> just the pins.
  ## Anything else raises, so a typo cannot silently run (or skip) the wrong set.
  case s.strip.toLowerAscii
  of "", "on": bmAll
  of "skip": bmSkip
  of "only": bmOnly
  else: raise newException(ValueError,
    balanceEnv & " must be on, skip or only, got \"" & s & "\"")

proc balanceMode*(): BalanceMode =
  parseBalanceMode(getEnv(balanceEnv))

const
  runningPrefix* = "running "
    ## Starts the line that names the test file whose tests come next: paraloop.nimble's
    ## `test` task echoes it before a file, a test group prints it itself (below).
  finishedPrefix* = "finished "
    ## Starts the line a test group prints once every file in it has run.
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir

var announcedFile = ""

proc announceTestFile*(path: string) =
  ## Prints `running <path from the repo root>` when `path` is not the test file the last
  ## call named, so each file of a test group is named once, before its first test.
  if path != announcedFile:
    announcedFile = path
    echo runningPrefix, path.relativePath(repoRoot).replace('\\', '/')

template announceHere() =
  ## Names the test file the calling tag was written in. `instantiationInfo(-2)`: -1 is
  ## this template's own call, inside the tag; -2 is the tag's call, in the test file.
  when defined(paraloopTestGroup):
    announceTestFile(instantiationInfo(-2, fullPaths = true).filename)

template test*(name: string, body: untyped) =
  ## `unittest.test`, skipped under `only`: a plain test is not a balance pin.
  announceHere()
  unittest.test name:
    if balanceMode() == bmOnly: skip() else: body

template pinTest(name: string, body: untyped) =
  unittest.test name:
    if balanceMode() == bmSkip: skip() else: body

template balanceTest*(name: string, body: untyped) =
  ## A numeric pin: the whole test is skipped under `skip`.
  announceHere()
  pinTest name, body

template playtestRule*(name: string, body: untyped) =
  ## The captain's playtest rule: skipped under `skip` like `balanceTest`.
  announceHere()
  pinTest name, body

template mixedTest*(name: string, body: untyped) =
  ## Always runs; put the pin half inside `balance:`.
  announceHere()
  unittest.test name:
    body

template balance*(body: untyped) =
  ## The pin half of a `mixedTest`: dropped under `skip`.
  if balanceMode() != bmSkip:
    body

template checkNoProblems*(problems: seq[string]) =
  ## Fails listing every line of `problems` (the baseline and design-bound findings of a
  ## balance test, a game's `baselineProblems` in its balance probe); passes on none. The
  ## failure reads like a failed `check`, at the call site, so `para test` shows the findings.
  let found = problems
  if found.len > 0:
    let at = instantiationInfo(-1, fullPaths = true)
    checkpoint(at.filename & "(" & $at.line & ", " & $at.column & "): Check failed: " &
      found.join("; "))
    fail()
