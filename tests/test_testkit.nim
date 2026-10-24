# paraloop/testkit's balance switch: the mode parser, and (through a fixture
# compiled and run as a child, so the real unittest formatter prints the
# result) which test kinds run or skip in each PARALOOP_BALANCE mode. Also the
# test-group line: a program that holds several test files names each as its
# tests start.

import std/unittest except test
import std/[os, osproc, strutils]
import paraloop/testkit
import tools/para/testcmd

suite "parseBalanceMode":
  test "unset, empty and `on` run everything":
    check parseBalanceMode("") == bmAll
    check parseBalanceMode("on") == bmAll

  test "skip and only, whatever the case or padding":
    check parseBalanceMode("skip") == bmSkip
    check parseBalanceMode(" Only ") == bmOnly

  test "anything else is an error, so a typo never silently runs the wrong set":
    expect ValueError: discard parseBalanceMode("skp")
    expect ValueError: discard parseBalanceMode("off")

suite "the tags, run by a child process":
  const fixture = "tests/fixtures/testkit/balance_tags.nim"
  const outDir = "tmp" / "testkit_fixture"

  proc runFixture(mode: string): string =
    ## The fixture's whole output under `PARALOOP_BALANCE=mode` ("" = unset).
    createDir(outDir)
    let exe = outDir / "balance_tags"
    let build = execCmdEx("nim c --hints:off --outdir:" & outDir & " " & fixture)
    doAssert build.exitCode == 0, build.output
    let had = existsEnv(balanceEnv)
    let was = getEnv(balanceEnv)
    defer:
      if had: putEnv(balanceEnv, was) else: delEnv(balanceEnv)
    if mode.len == 0: delEnv(balanceEnv) else: putEnv(balanceEnv, mode)
    let r = execCmdEx(exe)
    doAssert r.exitCode == 0, r.output
    r.output

  proc ran(output, what: string): bool = ("RAN " & what) in output

  test "default: every kind runs, nothing is skipped":
    let o = runFixture("")
    for what in ["invariant", "pin", "rule", "mixed invariant half", "mixed pin half"]:
      check o.ran(what)
    check "[SKIPPED]" notin o

  test "skip: the pins and the captain's rules are [SKIPPED] and never run; invariants still do":
    let o = runFixture("skip")
    check o.ran("invariant")
    check o.ran("mixed invariant half")
    check not o.ran("pin")
    check not o.ran("rule")
    check not o.ran("mixed pin half")
    check "[SKIPPED] pin" in o
    check "[SKIPPED] rule" in o
    var s: TestSummary
    parseUnittestOutput(o, s)
    check s.skipped == 2
    check s.failed == 0
    check countsLine(s) == "2 passed, 0 failed, 2 skipped"

  test "only: just the pins run; a plain test is [SKIPPED]":
    let o = runFixture("only")
    check o.ran("pin")
    check o.ran("rule")
    check o.ran("mixed pin half")
    check not o.ran("invariant")
    check "[SKIPPED] invariant" in o
    var s: TestSummary
    parseUnittestOutput(o, s)
    check s.skipped == 1

suite "a test group names each of its files, run by a child process":
  # tests/fixtures/testkit/group.nim imports grouped_a .. grouped_d, whose first tests are
  # a playtestRule, a balanceTest, a mixedTest and a plain test: each tag has to name the
  # file it was written in, not this module or the one before.
  const dir = "tests/fixtures/testkit"
  const outDir = "tmp" / "testkit_group_fixture"

  proc runProgram(name: string): string =
    ## The whole output of `dir/name.nim`, built and run with the balance switch unset.
    createDir(outDir)
    let build = execCmdEx("nim c --hints:off --outdir:" & outDir & " " & dir / (name & ".nim"))
    doAssert build.exitCode == 0, build.output
    let had = existsEnv(balanceEnv)
    let was = getEnv(balanceEnv)
    defer:
      if had: putEnv(balanceEnv, was) else: delEnv(balanceEnv)
    delEnv(balanceEnv)
    let r = execCmdEx(outDir / name)
    doAssert r.exitCode == 0, r.output
    r.output

  proc stripped(output: string): seq[string] =
    ## The non-empty lines of `output`, each stripped.
    for line in output.splitLines:
      if line.strip.len > 0: result.add line.strip

  test "one `running <file>` line a file, before its first test, in import order; `finished` is last":
    let o = stripped(runProgram("group"))
    var named: seq[string]
    for line in o:
      if line.startsWith(runningPrefix): named.add line[runningPrefix.len .. ^1]
    check named == @[dir & "/grouped_a.nim", dir & "/grouped_b.nim", dir & "/grouped_c.nim",
                     dir & "/grouped_d.nim"]
    for (file, first) in [("a", "a rule"), ("b", "b pin"), ("c", "c mixed"), ("d", "d invariant")]:
      let at = o.find(runningPrefix & dir & "/grouped_" & file & ".nim")
      check at >= 0
      check o.find("RAN " & first) > at
      check o.find("[OK] " & file & " second") > at
      # the next file is named only after this one's last test
      let next = o.find(runningPrefix & dir & "/grouped_" & chr(ord(file[0]) + 1) & ".nim")
      if next >= 0: check o.find("[OK] " & file & " second") < next
    check o[^1] == finishedPrefix & dir & "/group.nim"

  test "`para test`'s progress reads it as one line a file":
    let output = runProgram("group")
    var progress = initProgress(4)
    var shown: seq[string]
    for line in stripped("building " & dir & "/group.nim\n" & output):
      let p = progress.feed(line)
      if p.len > 0: shown.add p
    check progress.finish(true) == ""
    check shown == @[
      "progress 1/4: " & dir & "/grouped_a.nim: pass", "progress 2/4: " & dir & "/grouped_b.nim: pass",
      "progress 3/4: " & dir & "/grouped_c.nim: pass", "progress 4/4: " & dir & "/grouped_d.nim: pass"]
    var s: TestSummary
    parseUnittestOutput(output, s)
    check countsLine(s) == "8 passed, 0 failed"
    check s.suites == 4

  test "a file of the group run on its own prints no such line and runs the same tests":
    let o = stripped(runProgram("grouped_a"))
    for line in o:
      check not line.startsWith(runningPrefix)
      check not line.startsWith(finishedPrefix)
    check "RAN a rule" in o
    check "[OK] a second" in o
