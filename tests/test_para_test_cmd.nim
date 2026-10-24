# Tests for `para test`'s output parsing (task 1.8): std/unittest's console
# format and pytest -q's summary line, both turned into `TestSummary`, plus
# `runTest`'s own flag validation. `runTest` itself shells out to `nimble
# test` -- calling it with valid arguments from inside a test that `nimble
# test` runs would recurse forever, so every test below either exercises the
# pure parse functions directly or a flag error `runTest` rejects before
# spawning anything.

import std/[unittest, strutils, os]
import tools/para/testcmd

suite "parseUnittestOutput: std/unittest's console format":
  test "a clean pass: only [OK] lines, no failures":
    var s: TestSummary
    parseUnittestOutput("""
[Suite] dev: TOON fact dump
  [OK] one row per fact
  [OK] another one
""", s)
    check s.passed == 2
    check s.failed == 0
    check s.failures.len == 0

  test "a failing check's checkpoint, printed before its [FAILED] line, gives suite, test and file:line":
    # std/unittest's real order: `fail` prints the checkpoint while the test
    # runs, `testEnded` prints `[FAILED]` after it.
    var s: TestSummary
    parseUnittestOutput("""
[Suite] rules: weapons
  [OK] boomerang flies straight
    tests/test_rules.nim(212, 5): Check failed: p.turned
  [FAILED] boomerang turns around and is caught
""", s)
    check s.passed == 1
    check s.failed == 1
    check s.suites == 1
    check s.failures.len == 1
    check s.failures[0].suite == "rules: weapons"
    check s.failures[0].test == "boomerang turns around and is caught"
    check s.failures[0].at == "tests/test_rules.nim:212"
    check s.failures[0].msg == "Check failed: p.turned"

  test "two failures each keep their own location, never the next one's":
    var s: TestSummary
    parseUnittestOutput("""
[Suite] a
    tests/a.nim(12, 5): Check failed: A
  [FAILED] t1
    tests/a.nim(20, 5): Check failed: B
  [FAILED] t2
""", s)
    check s.failures.len == 2
    check s.failures[0].at == "tests/a.nim:12"
    check s.failures[0].msg == "Check failed: A"
    check s.failures[1].at == "tests/a.nim:20"
    check s.failures[1].msg == "Check failed: B"

  test "an absolute checkpoint path (as unittest prints it) is shown relative to the cwd":
    var s: TestSummary
    parseUnittestOutput("    " & (getCurrentDir() / "tests" / "x.nim") &
      "(7, 10): Check failed: turned\n  [FAILED] t\n", s)
    check s.failures[0].at == "tests" / "x.nim:7"

  test "a failure with no checkpoint line still records suite and test, at empty":
    var s: TestSummary
    parseUnittestOutput("""
[Suite] rules
  [OK] something else
  [FAILED] something raised
""", s)
    check s.failed == 1
    check s.failures[0].at == ""

  test "SKIPPED counts separately and doesn't become a failure":
    var s: TestSummary
    parseUnittestOutput("""
[Suite] dev: needs a display
  [SKIPPED] captureScreenshot writes a PNG
""", s)
    check s.skipped == 1
    check s.failed == 0

  test "the summary counts skipped tests, and says nothing about them when there are none":
    var s: TestSummary
    parseUnittestOutput("""
[Suite] balance: pins
  [SKIPPED] a window
  [SKIPPED] a count
  [OK] an invariant
""", s)
    check countsLine(s) == "1 passed, 0 failed, 2 skipped"
    var clean: TestSummary
    parseUnittestOutput("[Suite] a\n  [OK] one\n", clean)
    check countsLine(clean) == "1 passed, 0 failed"

  test "multiple suites across a whole run accumulate":
    var s: TestSummary
    parseUnittestOutput("""
[Suite] a
  [OK] one
[Suite] b
    tests/test_b.nim(9, 1): Check failed: x
  [FAILED] two
  [OK] three
""", s)
    check s.passed == 2
    check s.failed == 1
    check s.suites == 2
    check s.failures[0].suite == "b"
    check s.failures[0].at == "tests/test_b.nim:9"

suite "failuresTable":
  test "rows are TOON-quoted and each failed check follows its row":
    let t = failuresTable(@[
      TestFailure(suite: "rules: weapons", test: "boomerang, caught", at: "tests/test_rules.nim:212",
                  msg: "Check failed: p.turned"),
      TestFailure(suite: "b", test: "raised", at: "", msg: "")])
    check t == "failures[2]{suite,test,at}:\n" &
      "  \"rules: weapons\",\"boomerang, caught\",\"tests/test_rules.nim:212\"\n" &
      "  check: p.turned\n" &
      "  b,raised,\"\"\n"

suite "parsePytestSummary: tools/art's `pytest -q` summary line":
  test "an all-pass summary":
    var s: TestSummary
    parsePytestSummary("....\n16 passed in 0.42s\n", s)
    check s.passed == 16
    check s.failed == 0

  test "a mixed summary":
    var s: TestSummary
    parsePytestSummary(".F..\n2 failed, 14 passed in 1.23s\n", s)
    check s.passed == 14
    check s.failed == 2

  test "skipped and errors are counted without inflating passed":
    var s: TestSummary
    parsePytestSummary("1 failed, 2 passed, 1 skipped in 0.10s\n", s)
    check s.passed == 2
    check s.failed == 1
    check s.skipped == 1

  test "unrelated lines that happen to contain \" in \" are not mistaken for the summary":
    var s: TestSummary
    parsePytestSummary("running tests/test_foo.nim in this worktree\n", s)
    check s.passed == 0
    check s.failed == 0

  test "no pytest output at all leaves the summary untouched":
    var s: TestSummary
    parsePytestSummary("", s)
    check s.passed == 0
    check s.failed == 0

suite "runTest: flag validation (no subprocess spawned)":
  test "--help prints usage, exit 0, before anything runs":
    let r = runTest(@["--help"])
    check r.code == 0
    check r.output.startsWith("para test")

  test "an unknown flag is a usage error, exit 2, before anything runs":
    let r = runTest(@["--nonsense"])
    check r.code == 2
    check r.output.startsWith("error:")

  test "--filter with no value is a usage error":
    let r = runTest(@["--filter"])
    check r.code == 2
    check r.output.startsWith("error:")

  test "--area with no value, or an unknown area, is a usage error naming the valid ones":
    let none = runTest(@["--area"])
    check none.code == 2
    let bad = runTest(@["--area", "nope"])
    check bad.code == 2
    check bad.output.contains("unknown area \"nope\"")
    check bad.output.contains("game, art, engine, all")

  test "a --filter that matches no test file is a usage error, before nimble runs":
    let r = runTest(@["--filter", "no-such-test-file-anywhere"])
    check r.code == 2
    check r.output.contains("no test file matches")

  test "a --filter that matches no file inside the --area says so":
    let r = runTest(@["--area", "art", "--filter", "test_walk"])
    check r.code == 2
    check r.output.contains("in that area")

  test "--skip-balance and --only-balance together are a usage error, before anything runs":
    let r = runTest(@["--skip-balance", "--only-balance"])
    check r.code == 2
    check r.output.contains("contradict")

  test "--only-balance with a --filter that tags no pin is a usage error, before nimble runs":
    let r = runTest(@["--only-balance", "--filter", "test_walk"])
    check r.code == 2
    check r.output.contains("no test file with balance pins matches")
    check r.output.contains("test_walk")

  test "--shard with no value, or a malformed one, is a usage error, before anything runs":
    let none = runTest(@["--shard"])
    check none.code == 2
    check "INDEX/COUNT" in none.output
    for bad in ["0/4", "5/4", "4", "a/b", "1/0"]:
      let r = runTest(@["--shard", bad])
      check r.code == 2
      check "bad --shard" in r.output

  test "--shard on a --filter that matches nothing is still the filter's usage error":
    let r = runTest(@["--filter", "no-such-test-file-anywhere", "--shard", "1/4"])
    check r.code == 2
    check "no test file matches" in r.output

  test "--help documents --shard":
    let r = runTest(@["--help"])
    check "--shard I/N" in r.output

  test "--help documents both balance flags":
    let r = runTest(@["--help"])
    check r.output.contains("--skip-balance")
    check r.output.contains("--only-balance")

suite "progress: one pass/fail line per plan entry, streamed as the task echoes it":
  test "the line format: index/total, entry, pass or FAIL":
    check progressLine(3, 12, "tests/test_life.nim", true) == "progress 3/12: tests/test_life.nim: pass"
    check progressLine(4, 12, "tests/test_hub.nim", false) == "progress 4/12: tests/test_hub.nim: FAIL"

  test "a finished entry's line comes out when the next one starts, the last on finish":
    var t = initProgress(3)
    check t.feed("running tests/test_a.nim") == ""
    check t.feed("[Suite] a") == ""
    check t.feed("  [OK] one") == ""
    check t.feed("running tests/test_b.nim") == "progress 1/3: tests/test_a.nim: pass"
    check t.feed("  [OK] two") == ""
    check t.feed("running build tools/para/para.nim") == "progress 2/3: tests/test_b.nim: pass"
    check t.finish(true) == "progress 3/3: build tools/para/para.nim: pass"
    check t.finish(true) == ""

  test "a [FAILED] line fails its own entry only":
    var t = initProgress(3)
    discard t.feed("running tests/test_a.nim")
    discard t.feed("  [FAILED] broken")
    check t.feed("running tests/test_b.nim") == "progress 1/3: tests/test_a.nim: FAIL"
    discard t.feed("  [OK] fine")
    check t.finish(true) == "progress 2/3: tests/test_b.nim: pass"

  test "a run that did not pass fails the last entry started, even with no [FAILED] line":
    var t = initProgress(2)
    discard t.feed("running tests/test_a.nim")
    check t.feed("running tests/test_b.nim") == "progress 1/2: tests/test_a.nim: pass"
    discard t.feed("tests/test_b.nim(4, 1) Error: undeclared identifier: 'x'")
    check t.finish(false) == "progress 2/2: tests/test_b.nim: FAIL"

  test "output before the first `running` line (pytest's own, a nimble banner) is ignored":
    var t = initProgress(1)
    check t.feed("  [FAILED] stray") == ""
    check t.feed("running tests/test_a.nim") == ""
    check t.finish(true) == "progress 1/1: tests/test_a.nim: pass"

  test "nothing ran: nothing to finish":
    var t = initProgress(0)
    check t.finish(false) == ""

  # A test group: nimble echoes `building <group>`, the program prints `running <file>` as
  # each of its files starts and `finished <group>` after the last.
  test "a group's files each get their own line; its build gets none":
    var t = initProgress(4)
    check t.feed("running tests/test_a.nim") == ""
    check t.feed("building games/g/tests/pin_tests.nim") == "progress 1/4: tests/test_a.nim: pass"
    check t.feed("[Suite] one") == ""
    check t.feed("running games/g/tests/test_b.nim") == ""
    check t.feed("  [OK] b") == ""
    check t.feed("[Suite] two") == ""
    check t.feed("running games/g/tests/test_c.nim") == "progress 2/4: games/g/tests/test_b.nim: pass"
    check t.feed("  [OK] c") == ""
    check t.feed("finished games/g/tests/pin_tests.nim") == "progress 3/4: games/g/tests/test_c.nim: pass"
    check t.feed("running tests/test_z.nim") == ""
    check t.finish(true) == "progress 4/4: tests/test_z.nim: pass"

  test "a [FAILED] in one file of a group fails that file, not the ones that ran after it":
    var t = initProgress(3)
    discard t.feed("building games/g/tests/pin_tests.nim")
    discard t.feed("running games/g/tests/test_a.nim")
    discard t.feed("  [FAILED] broken")
    check t.feed("running games/g/tests/test_b.nim") == "progress 1/3: games/g/tests/test_a.nim: FAIL"
    discard t.feed("  [OK] fine")
    check t.feed("running games/g/tests/test_c.nim") == "progress 2/3: games/g/tests/test_b.nim: pass"
    discard t.feed("  [OK] fine too")
    # the program exits 1 for test_a's failure, so the run did not pass: test_c still passed
    check t.feed("finished games/g/tests/pin_tests.nim") == "progress 3/3: games/g/tests/test_c.nim: pass"
    check t.finish(false) == ""

  test "a group that dies part-way fails the file that was running":
    var t = initProgress(3)
    discard t.feed("building games/g/tests/pin_tests.nim")
    discard t.feed("running games/g/tests/test_a.nim")
    check t.feed("running games/g/tests/test_b.nim") == "progress 1/3: games/g/tests/test_a.nim: pass"
    discard t.feed("SIGSEGV: Illegal storage access.")
    check t.finish(false) == "progress 2/3: games/g/tests/test_b.nim: FAIL"

  test "a group that does not build fails under its own name, not the entry before it":
    var t = initProgress(3)
    discard t.feed("running tests/test_a.nim")
    check t.feed("building games/g/tests/pin_tests.nim") == "progress 1/3: tests/test_a.nim: pass"
    discard t.feed("games/g/tests/test_b.nim(4, 1) Error: undeclared identifier: 'x'")
    check t.finish(false) == "progress 2/3: games/g/tests/pin_tests.nim: FAIL"

  test "--help says a selection that holds a whole group builds it as one program":
    check runTest(@["--help"]).output.contains("pin_tests.nim")

  test "--help documents the progress lines and that goldens are not fixed locally":
    let r = runTest(@["--help"])
    check r.output.contains("progress I/N")
    check r.output.contains("stderr")
    check r.output.contains("CI or a human re-renders")

suite "a failing golden says it is not fixed locally":
  test "a golden suite failure carries the do-not-fix-locally help line":
    let f = @[TestFailure(suite: "goldens: the seed-7 replay script", test: "the run opens on Title",
                          at: "games/lab/tests/test_goldens_script.nim:120")]
    check goldenFailureHelp(f) == @[goldenHelp]
    check goldenHelp.contains("do not re-render")
    check goldenHelp.contains("CI or a human re-renders goldens")

  test "a failed check on the golden directory counts, whatever the suite is called":
    let f = @[TestFailure(suite: "fixture: the hub frames", test: "the hub's frames are these ten fixtures",
                          at: "games/lab/tests/test_fixture.nim:198",
                          msg: "Check failed: fileExists(goldensDir / (name & \".png\"))")]
    check goldenFailureHelp(f) == @[goldenHelp]

  test "a failure that is not about goldens adds no help line":
    let f = @[TestFailure(suite: "rules: weapons", test: "boomerang turns around",
                          at: "tests/test_rules.nim:212", msg: "Check failed: p.turned")]
    check goldenFailureHelp(f).len == 0
    check goldenFailureHelp(@[]).len == 0
