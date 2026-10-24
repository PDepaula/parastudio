# Tests for `para save` (and the stamp `para check` leaves for it), driven on
# a scratch git repo in a temp directory: detached HEAD, files outside the
# game, a missing or stale check, tag numbering, `--list` and the go-back
# path. No timing, no network, no compiler: the check steps are fakes.

import std/[unittest, os, strutils, sequtils, tempfiles, algorithm]
import tools/para/nimutil
import tools/para/art/clihelpers
import tools/para/savepoint
import tools/para/checkcmd
import tools/para/savecmd

const game = "pong"

proc git(root: string, args: varargs[string]): ProcResult =
  runCaptured("git", @args, root)

proc gitOk(root: string, args: varargs[string]): string =
  let r = runCaptured("git", @args, root)
  doAssert r.exitCode == 0, "git " & args.join(" ") & ": " & r.output
  r.output.strip

proc put(root, rel, body: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, body)

proc newRepo(): string =
  ## A scratch repo with one save already on `main`: games/pong/ (PLAN.md and
  ## code), a second game, a README, and `tmp/` ignored like the real repo.
  result = createTempDir("para_save_", "")
  discard gitOk(result, "init", "-q")
  discard gitOk(result, "symbolic-ref", "HEAD", "refs/heads/main")
  discard gitOk(result, "config", "user.name", "Scratch")
  discard gitOk(result, "config", "user.email", "scratch@example.com")
  discard gitOk(result, "config", "commit.gpgsign", "false")
  result.put(".gitignore", "tmp/\n")
  result.put("README.md", "engine\n")
  result.put("games/other/other.nim", "echo 1\n")
  result.put("games/pong/PLAN.md", "# plan\n")
  result.put("games/pong/pong.nim", "echo 1\n")
  discard gitOk(result, "add", ".")
  discard gitOk(result, "commit", "-q", "-m", "start")

proc passSteps(): seq[CheckStep] =
  @[("tests", proc (g: string): Run = ("", 0)), ("build", proc (g: string): Run = ("", 0))]

proc checked(root: string) =
  ## `para check` passed for the game as it is.
  doAssert runCheckWith(@["--game", game], passSteps(), root).code == 0

proc commitCount(root: string): int =
  parseInt(gitOk(root, "rev-list", "--count", "HEAD"))

proc tags(root: string): seq[string] =
  gitOk(root, "tag", "--list", "save-*").splitLines.filterIt(it.len > 0).sorted

suite "para save: refusals change nothing":
  var root: string
  setup: root = newRepo()
  teardown: removeDir(root)

  test "a detached HEAD is refused":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    discard gitOk(root, "checkout", "-q", "--detach")
    let before = commitCount(root)
    let r = runSaveWith(@["--game", game, "-m", "more"], root)
    check r.code == 1
    check "detached" in r.output
    check "Nothing was saved" in r.output
    check commitCount(root) == before
    check tags(root).len == 0

  test "changes outside the game are listed and stop the save":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    root.put("README.md", "engine, edited\n")
    root.put("games/other/new.nim", "echo 2\n")
    root.put("loose.txt", "x\n")
    let before = commitCount(root)
    let r = runSaveWith(@["--game", game, "-m", "more"], root)
    check r.code == 1
    check "  README.md\n" in r.output
    check "  games/other/new.nim\n" in r.output
    check "  loose.txt\n" in r.output
    check "pong.nim" notin r.output
    check commitCount(root) == before
    check tags(root).len == 0
    # nothing was staged either
    check gitOk(root, "diff", "--cached", "--name-only") == ""

  test "no check yet is refused, and an edit after the check makes it stale":
    root.put("games/pong/pong.nim", "echo 2\n")
    let first = runSaveWith(@["--game", game, "-m", "more"], root)
    check first.code == 1
    check "checks have not passed" in first.output
    root.checked
    root.put("games/pong/pong.nim", "echo 3\n") # after the check
    let stale = runSaveWith(@["--game", game, "-m", "more"], root)
    check stale.code == 1
    check "checks have not passed" in stale.output
    check tags(root).len == 0
    check commitCount(root) == 1

  test "a new untracked file after the check also makes it stale":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    root.put("games/pong/extra.nim", "echo 9\n")
    check runSaveWith(@["--game", game, "-m", "more"], root).code == 1

  test "a failed check leaves no stamp to save with":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    let failing: seq[CheckStep] = @[("tests", proc (g: string): Run = ("boom", 1))]
    check runCheckWith(@["--game", game], failing, root).code == 1
    check runSaveWith(@["--game", game, "-m", "more"], root).code == 1

  test "nothing changed in the game is not an error and saves nothing":
    let r = runSaveWith(@["--game", game, "-m", "more"], root)
    check r.code == 0
    check "Nothing new to save" in r.output
    check tags(root).len == 0

  test "a missing note, a bad flag and a conflicting mix are usage errors":
    check runSaveWith(@["--game", game], root).code == 2
    check runSaveWith(@["--game", game, "-m"], root).code == 2
    check runSaveWith(@["--bogus"], root).code == 2
    check runSaveWith(@["--game", game, "--yes"], root).code == 2
    check runSaveWith(@["--game", game, "--list", "-m", "x"], root).code == 2
    check runSaveWith(@["--game", game, "--back", "x", "--yes"], root).code == 2
    check runSaveWith(@["--game", game, "--back", "0", "--yes"], root).code == 2

suite "para save: saving and numbering":
  var root: string
  setup: root = newRepo()
  teardown: removeDir(root)

  test "a save commits only games/<game>, tags it save-pong-1 and says so":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.put("games/pong/new.nim", "echo 3\n")
    root.put("tmp/scratch.txt", "ignored\n") # ignored files stay out
    root.checked
    let r = runSaveWith(@["--game", game, "-m", "ship moves"], root)
    check r.code == 0
    check r.output.startsWith("Saved as save point 1.\n")
    check "nim c -r -d:dev games/pong/pong.nim" in r.output
    check tags(root) == @["save-pong-1"]
    check gitOk(root, "log", "-1", "--format=%s") == "ship moves"
    check gitOk(root, "rev-parse", "save-pong-1") == gitOk(root, "rev-parse", "HEAD")
    check gitOk(root, "show", "--name-only", "--format=", "HEAD").splitLines.len == 2
    check gitOk(root, "status", "--porcelain") == ""

  test "the game is picked from its PLAN.md when --game is left out":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    let r = runSaveWith(@["-m", "ship moves"], root)
    check r.code == 0
    check tags(root) == @["save-pong-1"]

  test "numbers count up from 1 and the stamp is spent by each save":
    for n in 1 .. 3:
      root.put("games/pong/pong.nim", "echo " & $(n + 1) & "\n")
      root.checked
      let r = runSaveWith(@["--game", game, "-m", "step " & $n], root)
      check r.output.startsWith("Saved as save point " & $n & ".")
    check tags(root) == @["save-pong-1", "save-pong-2", "save-pong-3"]
    root.put("games/pong/pong.nim", "echo 9\n")
    check runSaveWith(@["--game", game, "-m", "again"], root).code == 1 # needs a new check

  test "another game's save points do not count, and 10 sorts after 9":
    discard gitOk(root, "tag", "save-other-7")
    for n in 1 .. 10:
      discard gitOk(root, "tag", "save-pong-" & $n)
    check nextSavePoint(root, game) == 11
    check nextSavePoint(root, "other") == 8
    check nextSavePoint(root, "fresh") == 1

  test "--list shows the save points in order":
    check runSaveWith(@["--game", game, "--list"], root).output.startsWith("No save points yet")
    for n in 1 .. 2:
      root.put("games/pong/pong.nim", "echo " & $(n + 1) & "\n")
      root.checked
      discard runSaveWith(@["--game", game, "-m", "note " & $n], root)
    let r = runSaveWith(@["--game", game, "--list"], root)
    check r.code == 0
    check r.output.startsWith("saves[2]{point,saved,note}:")
    let rows = r.output.splitLines
    check rows[1].strip.startsWith("1,")
    check rows[1].endsWith("note 1")
    check rows[2].strip.startsWith("2,")
    check rows[2].endsWith("note 2")

suite "para save --back: a new save point that undoes the later ones":
  var root: string
  setup:
    root = newRepo()
    # save point 1: pong.nim says 2; save point 2: edited, one file gone, one added
    root.put("games/pong/pong.nim", "echo 2\n")
    root.put("games/pong/keep.nim", "echo keep\n")
    root.checked
    discard runSaveWith(@["--game", game, "-m", "one"], root)
    root.put("games/pong/pong.nim", "echo 3\n")
    removeFile(root / "games/pong/keep.nim")
    root.put("games/pong/added.nim", "echo added\n")
    root.checked
    discard runSaveWith(@["--game", game, "-m", "two"], root)
  teardown: removeDir(root)

  test "without --yes it explains and changes nothing":
    let before = gitOk(root, "rev-parse", "HEAD")
    let r = runSaveWith(@["--game", game, "--back", "1"], root)
    check r.code == 1
    check "--yes" in r.output
    check "Nothing is deleted" in r.output
    check gitOk(root, "rev-parse", "HEAD") == before
    check readFile(root / "games/pong/pong.nim") == "echo 3\n"

  test "with --yes the game goes back, as a third save point; history only grows":
    let two = gitOk(root, "rev-parse", "HEAD")
    let r = runSaveWith(@["--game", game, "--back", "1", "--yes"], root)
    check r.code == 0
    check "back as it was at save point 1" in r.output
    check "Saved as save point 3." in r.output
    check readFile(root / "games/pong/pong.nim") == "echo 2\n"
    check readFile(root / "games/pong/keep.nim") == "echo keep\n"
    check not fileExists(root / "games/pong/added.nim")
    check tags(root) == @["save-pong-1", "save-pong-2", "save-pong-3"]
    check gitOk(root, "log", "-1", "--format=%s") == "pong: went back to save point 1"
    # nothing reset: save point 2 is still the parent of the new one
    check gitOk(root, "rev-parse", "save-pong-2") == two
    check gitOk(root, "rev-parse", "HEAD~1") == two
    check gitOk(root, "status", "--porcelain") == ""
    check gitOk(root, "diff", "save-pong-1", "HEAD", "--", "games/pong") == ""

  test "only the game is put back: other files keep their later state":
    root.put("README.md", "engine v2\n")
    discard gitOk(root, "add", "README.md")
    discard gitOk(root, "commit", "-q", "-m", "engine moved on")
    check runSaveWith(@["--game", game, "--back", "1", "--yes"], root).code == 0
    check readFile(root / "README.md") == "engine v2\n"

  test "unsaved work in the game, a detached HEAD or foreign changes stop it":
    root.put("games/pong/pong.nim", "echo unsaved\n")
    let unsaved = runSaveWith(@["--game", game, "--back", "1", "--yes"], root)
    check unsaved.code == 1
    check "not saved yet" in unsaved.output
    check readFile(root / "games/pong/pong.nim") == "echo unsaved\n"
    discard gitOk(root, "checkout", "-q", "--", "games/pong/pong.nim")
    root.put("README.md", "stray\n")
    check "README.md" in runSaveWith(@["--game", game, "--back", "1", "--yes"], root).output
    discard gitOk(root, "checkout", "-q", "--", "README.md")
    discard gitOk(root, "checkout", "-q", "--detach")
    check "detached" in runSaveWith(@["--game", game, "--back", "1", "--yes"], root).output
    check tags(root).len == 2

  test "a go-back that cannot commit puts the game back as it was and says so":
    let two = gitOk(root, "rev-parse", "HEAD")
    root.put(".git/hooks/pre-commit", "#!/bin/sh\nexit 1\n")
    setFilePermissions(root / ".git/hooks/pre-commit", {fpUserRead, fpUserWrite, fpUserExec})
    let r = runSaveWith(@["--game", game, "--back", "1", "--yes"], root)
    check r.code == 1
    check "untouched" notin r.output
    check "back as it was before" in r.output
    check gitOk(root, "rev-parse", "HEAD") == two
    check tags(root) == @["save-pong-1", "save-pong-2"]
    check gitOk(root, "status", "--porcelain") == ""
    check readFile(root / "games/pong/pong.nim") == "echo 3\n"
    check not fileExists(root / "games/pong/keep.nim")
    check readFile(root / "games/pong/added.nim") == "echo added\n"

  test "a go-back that is committed but cannot be numbered says the work is saved":
    let two = gitOk(root, "rev-parse", "HEAD")
    root.put(".git/refs/tags/save-pong-3.lock", "")
    let r = runSaveWith(@["--game", game, "--back", "1", "--yes"], root)
    check r.code == 1
    check "untouched" notin r.output
    check "no save point number" in r.output
    check gitOk(root, "rev-parse", "HEAD~1") == two
    check readFile(root / "games/pong/pong.nim") == "echo 2\n"

  test "a save point that does not exist is a usage error":
    let r = runSaveWith(@["--game", game, "--back", "9", "--yes"], root)
    check r.code == 2
    check "no save point 9" in r.output

  test "going back to the latest save point has nothing to undo":
    let r = runSaveWith(@["--game", game, "--back", "2", "--yes"], root)
    check r.code == 0
    check "nothing to undo" in r.output
    check tags(root).len == 2

suite "para save --set-aside: unfinished work kept, the game whole again":
  var root: string
  setup:
    root = newRepo()
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    discard runSaveWith(@["--game", game, "-m", "one"], root)
  teardown: removeDir(root)

  test "the unfinished files become an unchecked save point, then the game goes back":
    root.put("games/pong/pong.nim", "echo half\n")
    root.put("games/pong/half.nim", "echo new\n")
    removeFile(root / "games/pong/PLAN.md")
    let one = gitOk(root, "rev-parse", "save-pong-1")
    let r = runSaveWith(@["--game", game, "--set-aside"], root)
    check r.code == 0
    check "kept as save point 2" in r.output
    check "not checked" in r.output
    check "back as it was at save point 1" in r.output
    check "--back 2 --yes" in r.output
    check tags(root) == @["save-pong-1", "save-pong-2", "save-pong-3"]
    # the game is whole again, as at save point 1
    check readFile(root / "games/pong/pong.nim") == "echo 2\n"
    check fileExists(root / "games/pong/PLAN.md")
    check not fileExists(root / "games/pong/half.nim")
    check gitOk(root, "status", "--porcelain") == ""
    check gitOk(root, "diff", "save-pong-1", "HEAD", "--", "games/pong") == ""
    # and nothing is lost: save point 2 holds exactly the unfinished files
    check gitOk(root, "show", "save-pong-2:games/pong/pong.nim") == "echo half"
    check gitOk(root, "show", "save-pong-2:games/pong/half.nim") == "echo new"
    check gitOk(root, "log", "-1", "--format=%s", "save-pong-2") == "pong: unfinished work set aside (not checked)"
    check gitOk(root, "rev-parse", "save-pong-2~1") == one # history only grows

  test "the unfinished work comes back with --back, as one more save point":
    root.put("games/pong/pong.nim", "echo half\n")
    check runSaveWith(@["--game", game, "--set-aside"], root).code == 0
    let back = runSaveWith(@["--game", game, "--back", "2", "--yes"], root)
    check back.code == 0
    check readFile(root / "games/pong/pong.nim") == "echo half\n"
    check tags(root).len == 4

  test "no checks are needed, and a stale or missing check does not matter":
    root.put("games/pong/pong.nim", "this does not even compile\n")
    check runSaveWith(@["--game", game, "--set-aside"], root).code == 0

  test "nothing unsaved: nothing to set aside":
    let r = runSaveWith(@["--game", game, "--set-aside"], root)
    check r.code == 0
    check "nothing to set aside" in r.output
    check tags(root) == @["save-pong-1"]

  test "a game with no save point yet is refused, and its files stay":
    discard gitOk(root, "tag", "-d", "save-pong-1")
    root.put("games/pong/pong.nim", "echo half\n")
    let before = commitCount(root)
    let r = runSaveWith(@["--game", game, "--set-aside"], root)
    check r.code == 1
    check "no earlier save point" in r.output
    check "Nothing was changed" in r.output
    check readFile(root / "games/pong/pong.nim") == "echo half\n"
    check commitCount(root) == before

  test "a detached HEAD or changes outside the game are refused, nothing touched":
    root.put("games/pong/pong.nim", "echo half\n")
    root.put("README.md", "stray\n")
    let stray = runSaveWith(@["--game", game, "--set-aside"], root)
    check stray.code == 1
    check "README.md" in stray.output
    discard gitOk(root, "checkout", "-q", "--", "README.md")
    discard gitOk(root, "checkout", "-q", "--detach")
    let detached = runSaveWith(@["--game", game, "--set-aside"], root)
    check detached.code == 1
    check "detached" in detached.output
    check readFile(root / "games/pong/pong.nim") == "echo half\n"
    check tags(root) == @["save-pong-1"]

  test "a commit that cannot be made loses nothing":
    root.put("games/pong/pong.nim", "echo half\n")
    root.put(".git/hooks/pre-commit", "#!/bin/sh\nexit 1\n")
    setFilePermissions(root / ".git/hooks/pre-commit", {fpUserRead, fpUserWrite, fpUserExec})
    let r = runSaveWith(@["--game", game, "--set-aside"], root)
    check r.code == 1
    check "nothing was lost" in r.output
    check readFile(root / "games/pong/pong.nim") == "echo half\n"
    check tags(root) == @["save-pong-1"]

  test "it stands alone: -m, --back, --yes and --list do not go with it":
    for extra in [@["-m", "x"], @["--back", "1"], @["--yes"], @["--list"]]:
      check runSaveWith(@["--game", game, "--set-aside"] & extra, root).code == 2

suite "an engine update merged into a friend's copy":
  # The playbook's "Bringing in engine updates": a merge, not a rebase, so
  # the saves and their numbers survive and saving goes on working.
  test "saves, numbering, --list and --back all keep working after the merge":
    let up = createTempDir("para_save_up_", "")
    defer: removeDir(up)
    discard gitOk(up, "init", "-q", "--bare")
    discard gitOk(up, "symbolic-ref", "HEAD", "refs/heads/main")
    let root = newRepo()
    defer: removeDir(root)
    discard gitOk(root, "remote", "add", "origin", up)
    discard gitOk(root, "push", "-q", "origin", "main")
    for n in 1 .. 2:
      root.put("games/pong/pong.nim", "echo " & $(n + 1) & "\n")
      root.checked
      check runSaveWith(@["--game", game, "-m", "step " & $n], root).code == 0
    # the engine moves on, upstream, in files the friend never touches
    let other = createTempDir("para_save_other_", "")
    defer: removeDir(other)
    discard gitOk(other, "clone", "-q", up, "work")
    let work = other / "work"
    discard gitOk(work, "config", "user.name", "Upstream")
    discard gitOk(work, "config", "user.email", "up@example.com")
    discard gitOk(work, "config", "commit.gpgsign", "false")
    work.put("README.md", "engine v2\n")
    work.put("paraloop/new.nim", "echo new\n")
    discard gitOk(work, "add", ".")
    discard gitOk(work, "commit", "-q", "-m", "engine update")
    discard gitOk(work, "push", "-q", "origin", "main")
    # the playbook's steps
    check gitOk(root, "status", "--short") == ""
    discard gitOk(root, "fetch", "-q", "origin")
    discard gitOk(root, "merge", "--no-ff", "--no-edit", "-q", "origin/main")
    let merged = gitOk(root, "rev-parse", "HEAD")
    check readFile(root / "README.md") == "engine v2\n"
    check readFile(root / "games/pong/pong.nim") == "echo 3\n"
    check tags(root) == @["save-pong-1", "save-pong-2"]
    # saving still works, and numbers carry on
    root.put("games/pong/pong.nim", "echo 4\n")
    root.checked
    check runSaveWith(@["--game", game, "-m", "after the update"], root).output.startsWith("Saved as save point 3.")
    check runSaveWith(@["--game", game, "--list"], root).output.startsWith("saves[3]")
    check runSaveWith(@["--game", game, "--back", "1", "--yes"], root).code == 0
    check readFile(root / "games/pong/pong.nim") == "echo 2\n"
    check readFile(root / "README.md") == "engine v2\n" # only the game goes back
    # and the playbook's undo for a merge that broke something (here later saves came after it)
    discard gitOk(root, "revert", "-m", "1", "--no-edit", merged)
    check not fileExists(root / "paraloop/new.nim")

suite "game choice":
  test "--game names a game that exists; PLAN.md picks one; several are listed":
    let root = newRepo()
    defer: removeDir(root)
    var g: string
    check pickGame(root, "pong", g).code == 0
    check g == "pong"
    check pickGame(root, "", g).code == 0
    check pickGame(root, "nope", g).code == 2
    check pickGame(root, "../x", g).code == 2
    root.put("games/other/PLAN.md", "# plan\n")
    let several = pickGame(root, "", g)
    check several.code == 2
    check "other, pong" in several.output
    removeFile(root / "games/other/PLAN.md")
    removeFile(root / "games/pong/PLAN.md")
    check pickGame(root, "", g).code == 2
