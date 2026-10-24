# Tests for `para lane` (tools/para/lanecmd.nim): a helper's own copy of a game, a git worktree of
# the game's repository at `games/<game>.<id>/`. Everything runs on scratch checkouts in a temp
# directory (an outer repository that ignores games/, holding one game that is a repository of its
# own), so no test touches a real game: no compiler, no network, no timing. The compiled run of two
# lanes at once, on a game `para new` made, is in test_para_new_cmd.nim; the Studio's view of a
# lane left over from a closed session is in test_para_studio_api.nim.

import std/[unittest, os, strutils, sequtils, tempfiles, json, algorithm]
import tools/para/nimutil
import tools/para/art/clihelpers
import tools/para/savepoint
import tools/para/checkcmd
import tools/para/savecmd
import tools/para/lanecmd

const game = "pong"

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

proc newCheckout(commit = true): string =
  ## A paraloop checkout (`games/*` ignored, like the real one) holding `games/pong`, a repository
  ## of its own: one commit, or none at all (as `para new` leaves it) when `commit` is false.
  result = createTempDir("para_lane_", "")
  result.initRepo()
  result.put(".gitignore", "tmp/\ngames/*\n")
  result.put("README.md", "engine\n")
  discard gitOk(result, "add", ".")
  discard gitOk(result, "commit", "-q", "-m", "engine")
  let g = result / "games" / game
  g.initRepo()
  g.put(".gitignore", "tmp/\n")
  g.put("PLAN.md", "# plan\nIn progress:\n")
  g.put("pong.nim", "echo 1\n")
  g.put("rules.nim", "# rules\nlet speed = 1\n")
  g.put("data.nim", "# data\nlet lives = 3\n")
  if commit:
    discard gitOk(g, "add", ".")
    discard gitOk(g, "commit", "-q", "-m", "start")

proc repoOf(root: string): string = root / "games" / game
proc laneOf(root, id: string): string = root / "games" / (game & "." & id)

proc lane(root: string, args: varargs[string]): Run = runLaneIn(root, @args)

proc passSteps(): seq[CheckStep] =
  @[("tests", proc (g: string): Run = ("", 0)), ("build", proc (g: string): Run = ("", 0))]

proc status(dir: string): string =
  ## `git status --porcelain`, its leading spaces kept (they say staged or not).
  runCaptured("git", @["status", "--porcelain"], dir).output.strip(leading = false)

proc outerUntouched(root: string): bool =
  ## The repository around games/ never sees a lane.
  status(root) == "" and gitOk(root, "rev-list", "--count", "HEAD") == "1"

suite "para lane start":
  var root: string
  setup: root = newCheckout()
  teardown: removeDir(root)

  test "makes games/<game>.<id>/ on lane/<id>, locked, with a record, and prints the id and folder":
    let r = root.lane("start", game, "--for", "builder", "--ticket", "ship moves")
    check r.code == 0
    check r.output.startsWith("lane: builder\nfolder: games/pong.builder/\nrole: builder\nticket: ship moves\n")
    check fileExists(root.laneOf("builder") / "pong.nim")
    check fileExists(root.laneOf("builder") / ".git") # a linked worktree: a file, not a folder
    check gitOk(root.laneOf("builder"), "symbolic-ref", "--short", "HEAD") == "lane/builder"
    check "locked" in gitOk(root.repoOf, "worktree", "list", "--porcelain")
    let meta = parseJson(readFile(root / "tmp" / "lanes" / "pong.builder.json"))
    check meta["role"].getStr == "builder"
    check meta["ticket"].getStr == "ship moves"
    check root.outerUntouched
    check status(root.repoOf) == ""

  test "the second builder gets builder2, the art helper art":
    check root.lane("start", game, "--for", "builder").output.startsWith("lane: builder\n")
    check root.lane("start", game, "--for", "builder").output.startsWith("lane: builder2\n")
    check root.lane("start", game, "--for", "art").output.startsWith("lane: art\n")
    check lanesOf(root, game).mapIt(it.id) == @["art", "builder", "builder2"]

  test "a game with no commit yet first gets one, so the lane is not an empty orphan":
    let fresh = newCheckout(commit = false)
    defer: removeDir(fresh)
    check headSha(fresh.repoOf).len == 0
    check fresh.lane("start", game, "--for", "builder").code == 0
    check gitOk(fresh.repoOf, "log", "--format=%s") == "pong: new game"
    check gitOk(fresh.repoOf, "tag", "--list").len == 0 # not a save point
    check fileExists(fresh.laneOf("builder") / "rules.nim")

  test "refuses a game that is not a repository of its own, a detached game, and bad arguments":
    let bare = createTempDir("para_lane_bare_", "")
    defer: removeDir(bare)
    bare.put("games/pong/PLAN.md", "# plan\n")
    check bare.lane("start", game, "--for", "builder").code == 1
    check root.lane("start", game).code == 2
    check root.lane("start", game, "--for", "checker").code == 2
    check root.lane("start", "nope", "--for", "builder").code == 2
    check root.lane("start", "--for", "builder").code == 2
    check root.lane("bogus").code == 2
    check root.lane("--help").output.startsWith("para lane start")
    discard gitOk(root.repoOf, "checkout", "-q", "--detach")
    check root.lane("start", game, "--for", "builder").code == 1
    check not dirExists(root.laneOf("builder"))

suite "para lane: a lane is not a game":
  var root: string
  setup: root = newCheckout()
  teardown: removeDir(root)

  test "gamesWithPlan skips lanes, pickGame refuses a lane's name, and check still finds the one game":
    discard root.lane("start", game, "--for", "builder")
    discard root.lane("start", game, "--for", "art")
    check fileExists(root.laneOf("builder") / "PLAN.md")
    check gamesWithPlan(root) == @[game]
    var picked: string
    check pickGame(root, "pong.builder", picked).code == 2
    check pickGame(root, "", picked).code == 0 and picked == game
    check runCheckWith(@[], passSteps(), root).output.startsWith("game: pong\n")

suite "para lane land":
  var root: string
  setup: root = newCheckout()
  teardown: removeDir(root)

  test "the helper's work becomes unsaved changes in the game; the producer's own edit stays; the lane goes":
    discard root.lane("start", game, "--for", "builder", "--ticket", "ship moves")
    root.put("games/pong/PLAN.md", "# plan\nIn progress: 1. ship moves\n") # the producer, on main, unsaved
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    root.put("games/pong.builder/systems.nim", "# systems\n")
    let head = headSha(root.repoOf)
    let r = root.lane("land", game, "builder")
    check r.code == 0
    check r.output.startsWith("landed: builder (the builder), 2 files now unsaved in games/pong/: rules.nim, systems.nim\n")
    check "para check --game pong" in r.output
    check headSha(root.repoOf) == head # nothing committed on the game's line
    check readFile(root.repoOf / "rules.nim") == "# rules\nlet speed = 2\n"
    check readFile(root.repoOf / "PLAN.md") == "# plan\nIn progress: 1. ship moves\n"
    check status(root.repoOf).splitLines.sorted == @[" M PLAN.md", "A  systems.nim", "M  rules.nim"]
    check not dirExists(root.laneOf("builder"))
    check gitOk(root.repoOf, "branch", "--list", "lane/*") == ""
    check not fileExists(root / "tmp" / "lanes" / "pong.builder.json")
    check lanesOf(root, game).len == 0
    check root.outerUntouched
    # and the existing check and save flow keeps it as the next save point
    check runCheckWith(@["--game", game], passSteps(), root).code == 0
    check runSaveWith(@["--game", game, "-m", "ship moves"], root).output.startsWith("Saved as save point 1.")
    check status(root.repoOf) == ""

  test "after a save on the game's line, the lane brings it in first, then lands":
    discard root.lane("start", game, "--for", "builder")
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    root.put("games/pong/data.nim", "# data\nlet lives = 5\n")
    check runCheckWith(@["--game", game], passSteps(), root).code == 0
    check runSaveWith(@["--game", game, "-m", "more lives"], root).code == 0
    let r = root.lane("land", game, "builder")
    check r.code == 0
    check "1 file now unsaved" in r.output
    check readFile(root.repoOf / "data.nim") == "# data\nlet lives = 5\n"
    check readFile(root.repoOf / "rules.nim") == "# rules\nlet speed = 2\n"
    check status(root.repoOf) == "M  rules.nim"

  test "two lanes at once, on different files, both land, then one check and one save":
    discard root.lane("start", game, "--for", "builder", "--ticket", "faster ship")
    discard root.lane("start", game, "--for", "art", "--ticket", "ship sprite")
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    root.put("games/pong.art/assets/ship.png", "png")
    check lanesOf(root, game).mapIt(changedFiles(it)) == @[@["assets/ship.png"], @["rules.nim"]]
    check root.lane("land", game, "art").code == 0
    check root.lane("land", game, "builder").code == 0
    check status(root.repoOf).splitLines.sorted == @["A  assets/ship.png", "M  rules.nim"]
    check lanesOf(root, game).len == 0
    check runCheckWith(@["--game", game], passSteps(), root).code == 0
    check runSaveWith(@["--game", game, "-m", "both"], root).code == 0

  test "a conflict: the merge is aborted in the lane, the game is untouched, the files are named":
    discard root.lane("start", game, "--for", "builder")
    root.put("games/pong.builder/data.nim", "# data\nlet lives = 9\n")
    root.put("games/pong/data.nim", "# data\nlet lives = 5\n")
    check runCheckWith(@["--game", game], passSteps(), root).code == 0
    check runSaveWith(@["--game", game, "-m", "more lives"], root).code == 0
    let head = headSha(root.repoOf)
    let r = root.lane("land", game, "builder")
    check r.code == 1
    check r.output.startsWith("The helper and the game both changed data.nim since the helper started")
    check "nothing in the game was changed" in r.output
    check headSha(root.repoOf) == head
    check status(root.repoOf) == ""
    check readFile(root.repoOf / "data.nim") == "# data\nlet lives = 5\n"
    # the lane is as the helper left it, its work kept, and no merge is half done there
    check readFile(root.laneOf("builder") / "data.nim") == "# data\nlet lives = 9\n"
    check status(root.laneOf("builder")) == ""
    check runCaptured("git", @["rev-parse", "-q", "--verify", "MERGE_HEAD"], root.laneOf("builder")).exitCode != 0
    check lanesOf(root, game)[0].kept == @["data.nim"]

  test "an unsaved edit in the game to a file the helper changed: refused, nothing changes":
    discard root.lane("start", game, "--for", "builder")
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    root.put("games/pong/rules.nim", "# rules\nlet speed = 3\n") # the producer's number tweak, not saved
    let r = root.lane("land", game, "builder")
    check r.code == 1
    check r.output.startsWith("These files have changes in the game that are not saved yet, and the helper changed them too: rules.nim.")
    check readFile(root.repoOf / "rules.nim") == "# rules\nlet speed = 3\n"
    check status(root.repoOf) == " M rules.nim"
    check dirExists(root.laneOf("builder"))
    check lanesOf(root, game)[0].kept == @["rules.nim"]
    # saved first, the same land then stops at the conflict instead, still changing nothing
    check runCheckWith(@["--game", game], passSteps(), root).code == 0
    check runSaveWith(@["--game", game, "-m", "speed 3"], root).code == 0
    check root.lane("land", game, "builder").output.startsWith("The helper and the game both changed rules.nim")

  test "a lane with nothing in it lands as nothing and is removed":
    discard root.lane("start", game, "--for", "builder")
    let r = root.lane("land", game, "builder")
    check r.code == 0
    check r.output.startsWith("lane builder: nothing to land")
    check not dirExists(root.laneOf("builder"))
    check status(root.repoOf) == ""

  test "an unknown lane is a usage error":
    check root.lane("land", game, "builder").code == 2
    check root.lane("land", game).code == 2

suite "para lane: never removes work that is not landed":
  var root: string
  setup: root = newCheckout()
  teardown: removeDir(root)

  test "drop refuses a lane with edits, and one with kept steps, saying what is in it":
    discard root.lane("start", game, "--for", "builder")
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    let dirty = root.lane("drop", game, "builder")
    check dirty.code == 1
    check dirty.output.startsWith("The lane builder of pong holds work that is not landed: 1 file (rules.nim).")
    check "Nothing was removed." in dirty.output
    check dirExists(root.laneOf("builder"))
    discard gitOk(root.laneOf("builder"), "commit", "-qam", "kept step")
    check status(root.laneOf("builder")) == ""
    check root.lane("drop", game, "builder").code == 1 # clean, but its commit is not landed
    check root.lane("drop", game, "builder", "--discard").code == 1 # says what would go, removes nothing
    check root.lane("drop", game, "builder", "--yes").code == 2
    check root.lane("clean").output == "clean: nothing to do\n"
    check dirExists(root.laneOf("builder"))
    check gitOk(root.repoOf, "branch", "--list", "lane/builder").len > 0

  test "git alone would remove a locked lane only by force; a stray remove is refused":
    discard root.lane("start", game, "--for", "builder")
    let r = runCaptured("git", @["worktree", "remove", root.laneOf("builder")], root.repoOf)
    check r.exitCode != 0
    check dirExists(root.laneOf("builder"))

  test "abort: drop --discard --yes removes the lane and its branch, and the game is as it was":
    discard root.lane("start", game, "--for", "builder")
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    root.put("games/pong.builder/new.nim", "# new\n")
    let r = root.lane("drop", game, "builder", "--discard", "--yes")
    check r.code == 0
    check "its work is gone, as asked" in r.output
    check not dirExists(root.laneOf("builder"))
    check gitOk(root.repoOf, "branch", "--list", "lane/*") == ""
    check gitOk(root.repoOf, "worktree", "list").splitLines.len == 1
    check status(root.repoOf) == ""
    check readFile(root.repoOf / "rules.nim") == "# rules\nlet speed = 1\n"

  test "an empty lane drops without --discard":
    discard root.lane("start", game, "--for", "art")
    check root.lane("drop", game, "art").code == 0
    check not dirExists(root.laneOf("art"))

suite "para lane: after a crash":
  var root: string
  setup: root = newCheckout()
  teardown: removeDir(root)

  test "a lane left with edits is listed with its work, and lands later":
    discard root.lane("start", game, "--for", "builder", "--ticket", "rocks")
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    # the session ends here: nothing landed. A new one finds the lane as it was.
    let listed = root.lane("list", "--game", game)
    check listed.code == 0
    check listed.output.startsWith("lanes[1]{game,id,role,ticket,files,steps,state}:\n  pong,builder,builder,rocks,1,0,has work\n")
    let info = lanesOf(root, game)[0]
    check info.hasWork and info.edited == @["rules.nim"] and info.ticket == "rocks"
    check root.lane("land", game, "builder").code == 0
    check status(root.repoOf) == "M  rules.nim"

  test "a lane folder deleted by hand: clean forgets it, its kept steps stay, and land brings them back":
    discard root.lane("start", game, "--for", "builder")
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    discard gitOk(root.laneOf("builder"), "commit", "-qam", "kept step")
    discard root.lane("start", game, "--for", "art") # an empty one, deleted too
    removeDir(root.laneOf("builder"))
    removeDir(root.laneOf("art"))
    let cleaned = root.lane("clean", "--game", game)
    check cleaned.code == 0
    check "pong,art,\"removed (folder gone, nothing in it)\"" in cleaned.output
    check "pong,builder,\"folder gone; 1 file not landed kept: land or drop it\"" in cleaned.output
    check "pong.builder" notin gitOk(root.repoOf, "worktree", "list")
    check lanesOf(root, game).mapIt(it.id) == @["builder"]
    check root.lane("drop", game, "builder").code == 1
    let r = root.lane("land", game, "builder")
    check r.code == 0
    check readFile(root.repoOf / "rules.nim") == "# rules\nlet speed = 2\n"
    check lanesOf(root, game).len == 0

  test "a lane landed but not removed (a file held open) is finished by clean":
    discard root.lane("start", game, "--for", "builder")
    root.put("games/pong.builder/rules.nim", "# rules\nlet speed = 2\n")
    discard gitOk(root.laneOf("builder"), "commit", "-qam", "kept step")
    discard gitOk(root.repoOf, "merge", "--squash", "lane/builder")
    let meta = parseJson(readFile(root / "tmp" / "lanes" / "pong.builder.json"))
    meta["landed"] = %true
    writeFile(root / "tmp" / "lanes" / "pong.builder.json", $meta)
    check lanesOf(root, game)[0].stateWords == "landed, removal pending"
    check not lanesOf(root, game)[0].hasWork
    check "pong,builder,removed (landed)" in root.lane("clean").output.replace("\"", "")
    check not dirExists(root.laneOf("builder"))
    check status(root.repoOf) == "M  rules.nim"
