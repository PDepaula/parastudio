# Tests for where a game's saves live: `games/<game>/.git`, the game's own
# repository, versus the repository that contains `games/` (the mode every
# game had before `para new` ran `git init`).
# `test_para_save_cmd.nim` and `test_para_backup_cmd.nim` cover the second
# mode; this file covers the first and the two side by side, on scratch trees
# in a temp directory: no compiler, no network, no timing. The end-to-end run
# with `para new` is in `test_para_new_cmd.nim`.

import std/[unittest, os, strutils, sequtils, tempfiles, algorithm]
import tools/para/nimutil
import tools/para/art/clihelpers
import tools/para/savepoint
import tools/para/checkcmd
import tools/para/savecmd
import tools/para/backupcmd

const
  game = "pong"
  noGh = "/nonexistent/para-test-gh"
  fakeUrl = "https://github.com/alice/pong-backup"

proc gitOk(dir: string, args: varargs[string]): string =
  let r = runCaptured("git", @args, dir)
  doAssert r.exitCode == 0, "git " & args.join(" ") & ": " & r.output
  r.output.strip

proc put(root, rel, body: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, body)

proc initRepo(dir: string) =
  createDir(dir)
  discard gitOk(dir, "init", "-q")
  discard gitOk(dir, "symbolic-ref", "HEAD", "refs/heads/main")
  discard gitOk(dir, "config", "user.name", "Scratch")
  discard gitOk(dir, "config", "user.email", "scratch@example.com")
  discard gitOk(dir, "config", "commit.gpgsign", "false")

proc newCheckout(): string =
  ## A paraloop checkout (`README.md`, `tmp/` ignored, `games/` ignored like in
  ## the public tool) holding `games/pong`, a repository of its own with one
  ## commit, and nothing else.
  result = createTempDir("para_game_repo_", "")
  result.initRepo()
  result.put(".gitignore", "tmp/\ngames/\n")
  result.put("README.md", "engine\n")
  discard gitOk(result, "add", ".")
  discard gitOk(result, "commit", "-q", "-m", "engine")
  let g = result / "games" / game
  g.initRepo()
  g.put(".gitignore", "tmp/\n")
  g.put("PLAN.md", "# plan\n")
  g.put("pong.nim", "echo 1\n")
  discard gitOk(g, "add", ".")
  discard gitOk(g, "commit", "-q", "-m", "start")

proc repoOf(root: string): string = root / "games" / game

proc passSteps(): seq[CheckStep] =
  @[("tests", proc (g: string): Run = ("", 0)), ("build", proc (g: string): Run = ("", 0))]

proc checked(root: string, g = game) =
  doAssert runCheckWith(@["--game", g], passSteps(), root).code == 0

proc tags(repo: string): seq[string] =
  gitOk(repo, "tag", "--list", "save-*").splitLines.filterIt(it.len > 0).sorted

proc commitCount(repo: string): int =
  parseInt(gitOk(repo, "rev-list", "--count", "HEAD"))

suite "a game that is a repository of its own":
  var root: string
  setup: root = newCheckout()
  teardown: removeDir(root)

  test "it is told apart from a game the outer repository tracks":
    check ownRepo(root, game)
    check repoDir(root, game) == root / "games" / game
    check repoPrefix(root, game) == ""
    check gameSpec(root, game) == "."
    check not ownRepo(root, "nope")
    check repoDir(root, "nope") == root
    check gameSpec(root, "nope") == "games/nope/"

  test "a save commits inside the game's repository and tags it save-pong-1 there":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.put("games/pong/new.nim", "echo 3\n")
    root.put("games/pong/tmp/scratch.txt", "ignored\n")
    root.checked
    let outerBefore = gitOk(root, "rev-parse", "HEAD")
    let r = runSaveWith(@["--game", game, "-m", "ship moves"], root)
    check r.code == 0
    check r.output.startsWith("Saved as save point 1.\n")
    check tags(repoOf(root)) == @["save-pong-1"]
    check gitOk(repoOf(root), "log", "-1", "--format=%s") == "ship moves"
    check gitOk(repoOf(root), "show", "--name-only", "--format=", "HEAD").splitLines.sorted == @["new.nim", "pong.nim"]
    check gitOk(repoOf(root), "status", "--porcelain") == ""
    # the repository around games/ saw nothing: no commit, no tag, no change
    check gitOk(root, "rev-parse", "HEAD") == outerBefore
    check gitOk(root, "tag", "--list").len == 0
    check gitOk(root, "status", "--porcelain") == ""

  test "changes in the outer repository are not the game's business":
    root.put("README.md", "engine, edited\n")
    root.put("loose.txt", "x\n")
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    let r = runSaveWith(@["--game", game, "-m", "more"], root)
    check r.code == 0
    check "README.md" notin r.output
    check gitOk(root, "status", "--porcelain").splitLines.len == 2 # still just the two stray files

  test "a detached HEAD in the game, no check and a stale check are refused":
    root.put("games/pong/pong.nim", "echo 2\n")
    let unchecked = runSaveWith(@["--game", game, "-m", "more"], root)
    check unchecked.code == 1
    check "checks have not passed" in unchecked.output
    root.checked
    root.put("games/pong/pong.nim", "echo 3\n")
    check "checks have not passed" in runSaveWith(@["--game", game, "-m", "more"], root).output
    root.checked
    discard gitOk(repoOf(root), "checkout", "-q", "--detach")
    let detached = runSaveWith(@["--game", game, "-m", "more"], root)
    check detached.code == 1
    check "detached" in detached.output
    check commitCount(repoOf(root)) == 1
    check tags(repoOf(root)).len == 0

  test "an outer repository's HEAD does not matter: detached there, saving still works":
    discard gitOk(root, "checkout", "-q", "--detach")
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    check runSaveWith(@["--game", game, "-m", "more"], root).code == 0

  test "nothing to save is not an error":
    let r = runSaveWith(@["--game", game, "-m", "more"], root)
    check r.code == 0
    check "Nothing new to save" in r.output

  test "numbers count up inside the game; --list shows them":
    check runSaveWith(@["--game", game, "--list"], root).output.startsWith("No save points yet")
    for n in 1 .. 3:
      root.put("games/pong/pong.nim", "echo " & $(n + 1) & "\n")
      root.checked
      check runSaveWith(@["--game", game, "-m", "step " & $n], root).output.startsWith("Saved as save point " & $n & ".")
    check tags(repoOf(root)) == @["save-pong-1", "save-pong-2", "save-pong-3"]
    let listed = runSaveWith(@["--game", game, "--list"], root)
    check listed.output.startsWith("saves[3]{point,saved,note}:")
    check listed.output.splitLines[3].endsWith("step 3")

  test "--back adds a save point that undoes the later ones, only in the game":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.put("games/pong/keep.nim", "echo keep\n")
    root.checked
    check runSaveWith(@["--game", game, "-m", "one"], root).code == 0
    root.put("games/pong/pong.nim", "echo 3\n")
    removeFile(root / "games/pong/keep.nim")
    root.put("games/pong/added.nim", "echo added\n")
    root.checked
    check runSaveWith(@["--game", game, "-m", "two"], root).code == 0
    let two = gitOk(repoOf(root), "rev-parse", "HEAD")
    let asks = runSaveWith(@["--game", game, "--back", "1"], root)
    check asks.code == 1
    check "--yes" in asks.output
    let r = runSaveWith(@["--game", game, "--back", "1", "--yes"], root)
    check r.code == 0
    check "Saved as save point 3." in r.output
    check readFile(root / "games/pong/pong.nim") == "echo 2\n"
    check readFile(root / "games/pong/keep.nim") == "echo keep\n"
    check not fileExists(root / "games/pong/added.nim")
    check tags(repoOf(root)) == @["save-pong-1", "save-pong-2", "save-pong-3"]
    check gitOk(repoOf(root), "rev-parse", "HEAD~1") == two
    check gitOk(repoOf(root), "status", "--porcelain") == ""

  test "--back refuses unsaved work in the game":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    check runSaveWith(@["--game", game, "-m", "one"], root).code == 0
    root.put("games/pong/pong.nim", "echo unsaved\n")
    let r = runSaveWith(@["--game", game, "--back", "1", "--yes"], root)
    check r.code == 1
    check "not saved yet" in r.output
    check readFile(root / "games/pong/pong.nim") == "echo unsaved\n"

  test "--set-aside keeps unfinished work as a save point, then puts the game back":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    check runSaveWith(@["--game", game, "-m", "one"], root).code == 0
    root.put("games/pong/pong.nim", "echo half\n")
    root.put("games/pong/half.nim", "echo new\n")
    let r = runSaveWith(@["--game", game, "--set-aside"], root)
    check r.code == 0
    check "kept as save point 2" in r.output
    check tags(repoOf(root)) == @["save-pong-1", "save-pong-2", "save-pong-3"]
    check readFile(root / "games/pong/pong.nim") == "echo 2\n"
    check not fileExists(root / "games/pong/half.nim")
    check gitOk(repoOf(root), "show", "save-pong-2:half.nim") == "echo new"
    check gitOk(root, "tag", "--list").len == 0

  test "the stamp follows the game's repository: a new save makes it stale":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked
    check checksJustPassed(root, game)
    check runSaveWith(@["--game", game, "-m", "one"], root).code == 0
    check not checksJustPassed(root, game)
    root.checked
    check checksJustPassed(root, game)
    root.put("games/pong/extra.nim", "echo 9\n")
    check not checksJustPassed(root, game)

  test "the session-start facts (changes, save points) come from the game's repository":
    var ok: bool
    check gameChanges(root, game, ok).len == 0
    check ok
    root.put("games/pong/pong.nim", "echo 2\n")
    root.put("games/pong/sub/new.nim", "echo 3\n")
    check gameChanges(root, game, ok).sorted == @["pong.nim", "sub/new.nim"]
    root.checked
    check runSaveWith(@["--game", game, "-m", "one"], root).code == 0
    let (res, points) = listSavePoints(root, game, quick = true)
    check res.exitCode == 0
    check points.mapIt(it.n) == @[1]
    check points[0].note == "one"
    check gameChanges(root, game, ok).len == 0

  test "a game folder with no git yet answers like a missing repository, and never uses the outer one":
    removeDir(repoOf(root) / ".git")
    check not ownRepo(root, game)
    # the root repo ignores games/, so there is nothing it could save: "Nothing new"
    root.put("games/pong/pong.nim", "echo 2\n")
    let r = runSaveWith(@["--game", game, "-m", "more"], root)
    check r.code == 0
    check "Nothing new to save" in r.output
    check tags(root).len == 0

suite "an own-repository game and an outer-tracked game side by side":
  var root: string
  setup:
    root = newCheckout()
    # `old` is tracked by the outer repository, as an older game is
    root.put("games/old/PLAN.md", "# plan\n")
    root.put("games/old/old.nim", "echo 1\n")
    root.put(".gitignore", "tmp/\n") # games/ is not ignored in this tree
    discard gitOk(root, "add", ".gitignore", "games/old")
    discard gitOk(root, "commit", "-q", "-m", "old game")
  teardown: removeDir(root)

  test "each saves in its own repository, with tags that cannot collide":
    root.put("games/old/old.nim", "echo 2\n")
    root.put("games/pong/pong.nim", "echo 2\n")
    root.checked("old")
    root.checked(game)
    check runSaveWith(@["--game", "old", "-m", "old one"], root).code == 0
    check runSaveWith(@["--game", game, "-m", "pong one"], root).code == 0
    check tags(root) == @["save-old-1"]
    check tags(repoOf(root)) == @["save-pong-1"]
    check gitOk(root, "log", "-1", "--format=%s") == "old one"
    check gitOk(repoOf(root), "log", "-1", "--format=%s") == "pong one"
    check gitOk(root, "show", "--name-only", "--format=", "HEAD") == "games/old/old.nim"

  test "the outer-tracked game is not blocked by the other game's folder, a repository the outer repo sees as one entry":
    root.put("games/old/old.nim", "echo 2\n")
    root.put("games/pong/pong.nim", "echo unsaved\n")
    root.checked("old")
    check "games/pong/" in gitOk(root, "status", "--porcelain", "--untracked-files=all")
    check runSaveWith(@["--game", "old", "-m", "old one"], root).code == 0
    check tags(root) == @["save-old-1"]

  test "a real change to another outer file still stops the outer-tracked game":
    root.put("games/old/old.nim", "echo 2\n")
    root.checked("old")
    root.put("README.md", "engine, edited\n")
    let r = runSaveWith(@["--game", "old", "-m", "old one"], root)
    check r.code == 1
    check "  README.md\n" in r.output
    check "games/pong" notin r.output

suite "para backup of a game's own repository":
  var root, bare, other: string
  setup:
    root = newCheckout()
    bare = createTempDir("para_game_bare_", "")
    discard gitOk(bare, "init", "-q", "--bare")
    other = createTempDir("para_game_other_", "")
    discard gitOk(other, "init", "-q", "--bare")
    discard gitOk(repoOf(root), "tag", "save-pong-1")
    discard gitOk(repoOf(root), "tag", "v1.0")
    discard gitOk(repoOf(root), "branch", "scratch-work")
    # a backup remote on the outer repository must never be what a game's backup looks at
    discard gitOk(root, "remote", "add", "backup", other)
  teardown:
    removeDir(root)
    removeDir(bare)
    removeDir(other)

  proc refsOf(b: string): seq[string] =
    gitOk(b, "for-each-ref", "--format=%(refname)").splitLines.filterIt(it.len > 0).sorted

  test "no backup remote in the game: says so and names the game's folder in the steps":
    let r = runBackupWith(@["--game", game], root, noGh)
    check r.code == 0
    check "backup: not set up" in r.output
    check "git -C games/pong remote add backup" in r.output

  test "the game is picked from its PLAN.md when --game is left out":
    check "git -C games/pong remote add backup" in runBackupWith(@[], root, noGh).output
    root.put("games/other/PLAN.md", "# plan\n")
    discard gitOk(root / "games" / "other", "init", "-q")
    let several = runBackupWith(@[], root, noGh)
    check several.code == 2
    check "other, pong" in several.output

  test "with yes and Private: the game's branch and save points go to the game's backup, nothing else":
    discard gitOk(repoOf(root), "remote", "add", "backup", bare)
    let r = runBackupWith(@["--game", game, "--push", "--yes", "--is-private"], root, noGh)
    check r.code == 0
    check "Backed up" in r.output
    check refsOf(bare) == @["refs/heads/main", "refs/tags/save-pong-1"]
    check refsOf(other).len == 0 # the outer repo's backup remote was not touched

  test "without --yes nothing is uploaded, and the command says what would go where":
    discard gitOk(repoOf(root), "remote", "add", "backup", bare)
    let r = runBackupWith(@["--game", game, "--push", "--is-private"], root, noGh)
    check r.code == 1
    check "Nothing was uploaded" in r.output
    check "--game pong" in r.output
    check "engine" notin r.output
    check refsOf(bare).len == 0

  test "the refusals of para backup hold for the game's repository":
    # a password in the address
    discard gitOk(repoOf(root), "remote", "add", "backup", "https://alice:ghp_secret@github.com/alice/pong-backup")
    let creds = runBackupWith(@["--game", game, "--push", "--yes", "--is-private"], root, noGh)
    check creds.code == 1
    check "password" in creds.output
    check "ghp_secret" notin creds.output
    # the same repository as origin
    discard gitOk(repoOf(root), "remote", "set-url", "backup", bare)
    discard gitOk(repoOf(root), "remote", "add", "origin", bare)
    let same = runBackupWith(@["--game", game, "--push", "--yes", "--is-private"], root, noGh)
    check same.code == 1
    check "same repository" in same.output
    discard gitOk(repoOf(root), "remote", "remove", "origin")
    # the Para Studio project itself
    discard gitOk(repoOf(root), "remote", "set-url", "backup", "https://github.com/PDepaula/parastudio")
    let upstream = runBackupWith(@["--game", game, "--push", "--yes", "--is-private"], root, noGh)
    check upstream.code == 1
    check "Para Studio project" in upstream.output
    # nothing but the private answer lets it through
    discard gitOk(repoOf(root), "remote", "set-url", "backup", bare)
    let unknown = runBackupWith(@["--game", game, "--push", "--yes"], root, noGh)
    check unknown.code == 1
    check refsOf(bare).len == 0

  test "a detached game is refused":
    discard gitOk(repoOf(root), "remote", "add", "backup", bare)
    discard gitOk(repoOf(root), "checkout", "-q", "--detach")
    let r = runBackupWith(@["--game", game, "--push", "--yes", "--is-private"], root, noGh)
    check r.code == 1
    check "detached" in r.output
    check refsOf(bare).len == 0

  test "backupFacts tells the page whose repository it is":
    let none = backupFacts(root, game, noGh)
    check none.own
    check none.game == game
    check not none.setUp
    discard gitOk(repoOf(root), "remote", "add", "backup", fakeUrl)
    let set = backupFacts(root, game, noGh)
    check set.setUp
    check set.url == fakeUrl
    check set.branch == "main"
    # asked without a game, it is the outer repository, which has its own backup remote
    let outer = backupFacts(root, "", noGh)
    check not outer.own
    check outer.setUp
    check outer.url == other
