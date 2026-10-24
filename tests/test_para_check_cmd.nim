# Tests for `para check`: which commands it runs (the anchored test filter
# and the game's own build), the pass/fail lines and verdict, the exit code,
# and the stamp it leaves for `para save`. The steps are fakes, so nothing
# compiles; tests/test_para_save_cmd.nim covers what save does with the stamp.

import std/[unittest, os, strutils, tempfiles]
import tools/para/art/clihelpers
import tools/para/savepoint
import tools/para/checkcmd

proc put(root, rel, body: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, body)

proc newRoot(): string =
  ## Not a git repo on purpose: check works without git (the digest falls back
  ## to walking the game's files).
  result = createTempDir("para_check_", "")
  result.put("games/pong/PLAN.md", "# plan\n")
  result.put("games/pong/pong.nim", "echo 1\n")

proc fake(name: string, code: int, output = "", log: ref seq[string] = nil,
          touch = ""): CheckStep =
  (name, proc (game: string): Run =
    if log != nil: log[].add name & ":" & game
    if touch.len > 0: writeFile(touch, "changed\n")
    (output, code))

suite "para check: what it runs":
  test "the tests are filtered to the game's own directory, anchored by the slash":
    check testArgs("pong") == @["--filter", "games/pong/", "--skip-balance"]
    check testArgs("pong2") == @["--filter", "games/pong2/", "--skip-balance"]
    check buildArgs("pong") == @["--game", "pong"]

  test "a lane's steps run on its folder: the filter is the lane's, the build names the lane":
    check testArgs("pong.builder") == @["--filter", "games/pong.builder/", "--skip-balance"]
    check buildArgs("pong.builder") == @["--game", "pong", "--lane", "builder"]

  test "the real steps are the tests, then the build":
    let steps = realSteps()
    check steps.len == 2
    check steps[0].name == "tests"
    check steps[1].name == "build"

suite "para check: result and stamp":
  var root: string
  setup: root = newRoot()
  teardown: removeDir(root)

  test "both steps pass: one line each, a verdict, exit 0, a fresh stamp":
    let log = new seq[string]
    let r = runCheckWith(@["--game", "pong"], @[fake("tests", 0, log = log), fake("build", 0, log = log)], root)
    check r.code == 0
    check r.output.startsWith("game: pong\ntests: pass\nbuild: pass\ncheck: pass\n")
    check log[] == @["tests:pong", "build:pong"]
    check checksJustPassed(root, "pong")

  test "the game is picked from its PLAN.md when --game is left out":
    let r = runCheckWith(@[], @[fake("tests", 0)], root)
    check r.code == 0
    check r.output.startsWith("game: pong\n")

  test "a failing step fails the verdict, shows its output and still runs the build":
    let log = new seq[string]
    let r = runCheckWith(@["--game", "pong"],
      @[fake("tests", 1, "tests: 1 failed\nfailures[1]{suite,test,at}:\n  a,b,c\n", log), fake("build", 0, log = log)], root)
    check r.code == 1
    check "tests: FAIL\n" in r.output
    check "build: pass\n" in r.output
    check "check: FAIL (tests)\n" in r.output
    check "tests output:\n  tests: 1 failed\n  failures[1]{suite,test,at}:\n    a,b,c\n" in r.output
    check log[] == @["tests:pong", "build:pong"]
    check not checksJustPassed(root, "pong")

  test "both failing are both named":
    let r = runCheckWith(@["--game", "pong"], @[fake("tests", 1), fake("build", 1)], root)
    check r.code == 1
    check "check: FAIL (tests, build)\n" in r.output

  test "a failure removes the stamp an earlier pass left":
    check runCheckWith(@["--game", "pong"], @[fake("tests", 0)], root).code == 0
    check checksJustPassed(root, "pong")
    check runCheckWith(@["--game", "pong"], @[fake("tests", 1)], root).code == 1
    check not checksJustPassed(root, "pong")

  test "any edit to the game makes the stamp stale; other files do not":
    check runCheckWith(@["--game", "pong"], @[fake("tests", 0)], root).code == 0
    root.put("README.md", "elsewhere\n")
    root.put("games/other/x.nim", "echo 2\n")
    check checksJustPassed(root, "pong")
    root.put("games/pong/pong.nim", "echo 2\n")
    check not checksJustPassed(root, "pong")

  test "an edit while the steps run is not a pass":
    let r = runCheckWith(@["--game", "pong"],
      @[fake("tests", 0, touch = root / "games/pong/pong.nim"), fake("build", 0)], root)
    check r.code == 1
    check "tests: pass\nbuild: pass\n" in r.output
    check "changed while it was being checked" in r.output
    check not checksJustPassed(root, "pong")

suite "para check --lane: a rehearsal on a helper's lane":
  var root: string
  setup:
    root = newRoot()
    root.put("games/pong.builder/pong.nim", "echo 2\n")
    root.put("games/pong.builder/PLAN.md", "# plan\n")
  teardown: removeDir(root)

  test "runs both steps on the lane, passes, and leaves no stamp for save":
    let log = new seq[string]
    let r = runCheckWith(@["--game", "pong", "--lane", "builder"],
                         @[fake("tests", 0, log = log), fake("build", 0, log = log)], root)
    check r.code == 0
    check r.output.startsWith("game: pong\nlane: builder\ntests: pass\nbuild: pass\ncheck: pass (the lane only")
    check log[] == @["tests:pong.builder", "build:pong.builder"]
    check not fileExists(stampFile(root, "pong"))
    check not checksJustPassed(root, "pong")

  test "a lane check does not take away the game's own pass":
    check runCheckWith(@["--game", "pong"], @[fake("tests", 0)], root).code == 0
    check runCheckWith(@["--game", "pong", "--lane", "builder"], @[fake("tests", 1)], root).code == 1
    check checksJustPassed(root, "pong")

  test "the game is still picked from its PLAN.md (the lane's copy is not a second game)":
    check runCheckWith(@["--lane", "builder"], @[fake("tests", 0)], root).output.startsWith("game: pong\nlane: builder\n")

  test "an unknown lane or a missing id is a usage error that runs nothing":
    let log = new seq[string]
    check runCheckWith(@["--game", "pong", "--lane", "art"], @[fake("tests", 0, log = log)], root).code == 2
    check runCheckWith(@["--game", "pong", "--lane", "../x"], @[fake("tests", 0, log = log)], root).code == 2
    check runCheckWith(@["--game", "pong", "--lane"], @[fake("tests", 0, log = log)], root).code == 2
    check log[].len == 0

suite "para check: flags and game choice":
  test "--help is exit 0; unknown flags and a missing name are usage errors":
    check runCheckWith(@["--help"], @[]).code == 0
    check runCheckWith(@["--help"], @[]).output.startsWith("para check")
    check runCheckWith(@["--bogus"], @[]).code == 2
    check runCheckWith(@["--game"], @[]).code == 2

  test "an unknown game, no PLAN.md and several PLAN.md files are exit 2 and run nothing":
    let root = newRoot()
    defer: removeDir(root)
    let log = new seq[string]
    let steps = @[fake("tests", 0, log = log)]
    check runCheckWith(@["--game", "nope"], steps, root).code == 2
    root.put("games/other/PLAN.md", "# plan\n")
    let several = runCheckWith(@[], steps, root)
    check several.code == 2
    check "other, pong" in several.output
    removeFile(root / "games/other/PLAN.md")
    removeFile(root / "games/pong/PLAN.md")
    check runCheckWith(@[], steps, root).code == 2
    check log[].len == 0
