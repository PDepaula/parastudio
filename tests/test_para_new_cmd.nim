# Tests for `para new` (task 1.9): flag/name validation, collision
# detection, and a real generation + compile of the game and its own test
# (the same acceptance the games/ci_smoke CI job runs at a larger scale --
# see .github/workflows/ci.yml). Every test that writes games/<name>/ cleans
# it up immediately: other CLI tests (test_para_build_cmd.nim and siblings)
# assert `Valid games: hello` verbatim, which a leftover directory could
# break for the rest of this `nimble test` run.

import std/[unittest, os, strutils]
import tools/para/nimutil
import tools/para/art/clihelpers
import tools/para/newcmd
import tools/para/savepoint
import tools/para/checkcmd
import tools/para/savecmd

const scratchGame = "zzz_para_new_scratch"

proc cleanup() =
  if dirExists("games" / scratchGame):
    removeDir("games" / scratchGame)
  removeStamp("", scratchGame)

proc gameGit(args: varargs[string]): string =
  ## `git <args>` inside the scratch game, output trimmed.
  let r = runCaptured("git", @args, "games" / scratchGame)
  doAssert r.exitCode == 0, "git " & args.join(" ") & ": " & r.output
  r.output.strip

suite "runNew: flags and validation":
  test "--help prints usage, exit 0":
    let r = runNew(@["--help"])
    check r.code == 0
    check r.output.startsWith("para new")

  test "no game name is a usage error, exit 2":
    let r = runNew(@[])
    check r.code == 2
    check r.output.startsWith("error: para new needs a game name")

  test "more than one positional argument is a usage error":
    let r = runNew(@["a", "b"])
    check r.code == 2

  test "an unknown flag is a usage error":
    let r = runNew(@["--bogus"])
    check r.code == 2

  test "an uppercase or otherwise invalid name is rejected":
    for bad in ["MyGame", "1game", "my-game", "", "-game"]:
      let r = runNew(@[bad])
      check r.code == 2
      check r.output.startsWith("error:")

  test "an existing game's name is a collision, exit 2":
    let r = runNew(@["hello"])
    check r.code == 2
    check r.output.startsWith("error: \"hello\" already exists")

suite "runNew: generates a game that builds and tests clean":
  setup: cleanup()
  teardown: cleanup()

  test "para new writes games/<name>/ with the renamed entry point and test":
    let r = runNew(@[scratchGame])
    check r.code == 0
    check r.output.contains("new: wrote " & ("games" / scratchGame))
    check fileExists("games" / scratchGame / (scratchGame & ".nim"))
    check fileExists("games" / scratchGame / "rules.nim")
    check fileExists("games" / scratchGame / "data.nim")
    check fileExists("games" / scratchGame / "AGENTS.md")
    check fileExists("games" / scratchGame / "reports" / "README.md")
    # the producer's plain-words files, all of them, ready to be filled in
    for f in ["PITCH.md", "PLAN.md", "CHOICES.md", "DESIGN.md", "PLAYTEST.md", "NOTES.md"]:
      check fileExists("games" / scratchGame / f)
    check fileExists("games" / scratchGame / "tests" / ("test_" & scratchGame & ".nim"))
    # the placeholder is gone everywhere it was substituted
    for f in ["rules.nim", "data.nim", (scratchGame & ".nim"), "AGENTS.md", "reports" / "README.md",
              "PLAN.md", "NOTES.md"]:
      check "__GAME__" notin readFile("games" / scratchGame / f)
    check "__GAME__" notin readFile("games" / scratchGame / "tests" / ("test_" & scratchGame & ".nim"))

  test "NOTES.md has its three sections, and PLAN.md an empty In progress line":
    discard runNew(@[scratchGame])
    let notes = readFile("games" / scratchGame / "NOTES.md")
    check notes.startsWith("# " & scratchGame & ": notes")
    for h in ["## What works", "## What to avoid", "## Friend's taste"]:
      check h in notes
    check "director" notin notes # plain words only: no voice in files
    let plan = readFile("games" / scratchGame / "PLAN.md")
    check "\nIn progress:\n" in plan

  test "next steps filter the tests to the game and point at its reports folder":
    let r = runNew(@[scratchGame])
    check r.output.contains("para test --filter games/" & scratchGame & "/")
    check "Run `para test` to" notin r.output
    check r.output.contains("games/" & scratchGame & "/reports/")

  test "a second para new with the same name is a collision":
    discard runNew(@[scratchGame])
    let r = runNew(@[scratchGame])
    check r.code == 2
    check r.output.startsWith("error: \"" & scratchGame & "\" already exists")

  test "the generated game compiles natively":
    discard runNew(@[scratchGame])
    let src = "games" / scratchGame / (scratchGame & ".nim")
    let res = runCaptured("nim", @["c", "--hints:off", "--outdir:tmp", src])
    check res.exitCode == 0
    check fileExists("tmp" / scratchGame)

  test "the generated game's own test compiles and passes":
    discard runNew(@[scratchGame])
    let testFile = "games" / scratchGame / "tests" / ("test_" & scratchGame & ".nim")
    let res = runCaptured("nim", @["c", "-r", "--hints:off", "--outdir:tmp", testFile])
    check res.exitCode == 0
    check "[OK]" in res.output
    check "[FAILED]" notin res.output

suite "runNew: the game is a git repository of its own":
  setup: cleanup()
  teardown: cleanup()

  test "games/<name>/.git exists, and git there is that repository, not the one around it":
    let r = runNew(@[scratchGame])
    check r.code == 0
    check dirExists("games" / scratchGame / ".git")
    check "git repository of its own" in r.output
    check expandFilename(gameGit("rev-parse", "--show-toplevel")) == expandFilename("games" / scratchGame)
    check gameGit("symbolic-ref", "--short", "HEAD") == "main"
    # no first commit: the first `para save` is the first save point
    check runCaptured("git", @["rev-parse", "--verify", "-q", "HEAD"], "games" / scratchGame).exitCode != 0

  test "the .gitignore keeps scratch space, caches and compiled files out, and sources in":
    discard runNew(@[scratchGame])
    check "__GAME__" notin readFile("games" / scratchGame / ".gitignore")
    writeFile("games" / scratchGame / "tmp.keep", "x")
    createDir("games" / scratchGame / "tmp")
    writeFile("games" / scratchGame / "tmp" / "scratch.txt", "x")
    createDir("games" / scratchGame / ".nimcache")
    writeFile("games" / scratchGame / ".nimcache" / "a.c", "x")
    writeFile("games" / scratchGame / scratchGame, "binary")
    writeFile("games" / scratchGame / "tests" / ("test_" & scratchGame), "binary")
    let listed = gameGit("ls-files", "--cached", "--others", "--exclude-standard").splitLines
    check scratchGame & ".nim" in listed
    check ".gitignore" in listed
    check "tests/test_" & scratchGame & ".nim" in listed
    check "reports/README.md" in listed
    check "tmp.keep" in listed
    for hidden in ["tmp/scratch.txt", ".nimcache/a.c", scratchGame, "tests/test_" & scratchGame]:
      check hidden notin listed

  test "para new never touches the repository around games/":
    let before = runCaptured("git", @["status", "--porcelain", "--", ":!games/" & scratchGame]).output
    let head = runCaptured("git", @["rev-parse", "HEAD"]).output
    discard runNew(@[scratchGame])
    check runCaptured("git", @["status", "--porcelain", "--", ":!games/" & scratchGame]).output == before
    check runCaptured("git", @["rev-parse", "HEAD"]).output == head
    check runCaptured("git", @["ls-files", "--", "games/" & scratchGame]).output.strip.len == 0

  test "check then save, end to end: the save point is in the game's repository only":
    discard runNew(@[scratchGame])
    discard gameGit("config", "user.name", "Scratch")
    discard gameGit("config", "user.email", "scratch@example.com")
    discard gameGit("config", "commit.gpgsign", "false")
    let outerHead = runCaptured("git", @["rev-parse", "HEAD"]).output
    let outerTags = runCaptured("git", @["tag", "--list"]).output
    # checks that pass without a compiler; the real steps are `para test`/`para build`
    let steps: seq[CheckStep] = @[("tests", proc (g: string): Run = ("", 0)),
                                  ("build", proc (g: string): Run = ("", 0))]
    check runSaveWith(@["--game", scratchGame, "-m", "first"]).code == 1 # needs a check first
    let checked = runCheckWith(@["--game", scratchGame], steps)
    check checked.code == 0
    let first = runSaveWith(@["--game", scratchGame, "-m", "the template, as it came"])
    check first.code == 0
    check first.output.startsWith("Saved as save point 1.")
    check gameGit("tag", "--list", "save-*") == "save-" & scratchGame & "-1"
    check gameGit("status", "--porcelain") == ""
    check "PLAN.md" in gameGit("show", "--name-only", "--format=", "HEAD")
    # and a second save point after an edit
    writeFile("games" / scratchGame / "NOTES.md", readFile("games" / scratchGame / "NOTES.md") & "- 2026-10-23 a lesson\n")
    check runCheckWith(@["--game", scratchGame], steps).code == 0
    check runSaveWith(@["--game", scratchGame, "-m", "a lesson"]).output.startsWith("Saved as save point 2.")
    let listed = runSaveWith(@["--game", scratchGame, "--list"])
    check listed.output.startsWith("saves[2]{point,saved,note}:")
    # the repository around games/ saw none of it
    check runCaptured("git", @["rev-parse", "HEAD"]).output == outerHead
    check runCaptured("git", @["tag", "--list"]).output == outerTags
    check runCaptured("git", @["ls-files", "--", "games/" & scratchGame]).output.strip.len == 0
