# `para test`'s file selection (tools/para/testplan.nim): the import-closure
# reader, `--area` and `--filter`. The first suite builds a small module tree
# in a scratch directory and checks every import form the reader understands;
# the rest check a sample repository built below (a game `lab`, its frozen copy
# `lab_v1`, hello and the engine and art tests), so they hold with games/ absent
# and an import that moves a test from one area to another shows up here as a
# diff to this file.

import std/[unittest, os, sets, strutils, sequtils, algorithm]
import tools/para/testplan

proc scratchTree(root: string, files: openArray[(string, string)]) =
  for (rel, src) in files:
    createDir((root / rel).parentDir)
    writeFile(root / rel, src)

const sampleRoot = "tmp" / "testplan_sample"

proc buildSampleTree() =
  ## The repository the suites below read: tests/, hello, a game and its frozen copy, each with
  ## the files a sort by area, balance tag, test group, sidecar or import needs.
  let balance = "suite \"x\":\n  balanceTest \"a\":\n    check true\n"
  var files: seq[(string, string)] = @[
    ("tests/test_sim.nim", "discard\n"), ("tests/test_app.nim", "discard\n"),
    ("tests/test_audio.nim", "discard\n"), ("tests/test_input.nim", "discard\n"),
    ("tests/test_smoke.nim", "discard\n"), ("tests/test_sim_replay.nim", "discard\n"),
    ("tests/test_sim_replay.nims", "discard\n"),
    ("tests/test_art_lint.nim", "import tools/para/art/lint\n"),
    ("tests/test_art_fix_cli.nim", "import tools/para/art/fix\n"),
    ("tests/test_art_tile.nim", "import tools/para/art/sheet\n"),
    ("tests/test_art_toml.nim", "import tools/para/art/toml\n"),
    ("tests/test_para_toon.nim", "import tools/para/art/toon\n"),
    ("tests/test_para_dev_cli.nim", "import examples/hello/hello\n"),
    ("tests/test_para_game.nim", "import games/lab/lab\n" & balance),
    ("tests/test_para_game.nims", "discard\n"),
    ("tools/para/art/lint.nim", "discard\n"), ("tools/para/art/fix.nim", "discard\n"),
    ("tools/para/art/sheet.nim", "discard\n"), ("tools/para/art/toml.nim", "discard\n"),
    ("tools/para/art/toon.nim", "discard\n"),
    ("examples/hello/hello.nim", "discard\n"),
    ("examples/hello/tests/test_hello.nim", "import \"../hello\"\n"),
    ("games/lab/lab.nim", "discard\n"), ("games/lab/tests/casual_bot.nim", "discard\n")]
  for name in ["test_walk", "test_stamp", "test_hud"]:
    files.add ("games/lab/tests/" & name & ".nim", "import \"../lab\"\n")
  for name in ["test_balance", "test_hub_bot", "test_pacing"]:
    files.add ("games/lab/tests/" & name & ".nim", "import \"../lab\"\n" & balance)
  files.add ("games/lab/tests/test_data_pivot.nim", "import \"../lab\"\n" & balance)
  files.add ("games/lab/tests/test_hub_life_script.nim", "import \"../lab\"\n" & balance)
  files.add ("games/lab/tests/test_soft_lock.nim", "import \"../lab\"\n")
  files.add ("games/lab/tests/test_soft_lock.nims", "discard\n")
  files.add ("games/lab/tests/pin_tests.nim", "import test_balance, test_data_pivot, test_hub_bot, test_hub_life_script, test_pacing\n")
  files.add ("games/lab_v1/lab_v1.nim", "discard\n")
  for name in ["test_balance", "test_goldens_script", "test_hub_bot", "test_pacing", "test_soft_lock"]:
    files.add ("games/lab_v1/tests/" & name & ".nim", "import \"../lab_v1\"\n" & balance)
  files.add ("games/lab_v1/tests/pin_tests.nim", "import test_balance, test_goldens_script, test_hub_bot, test_pacing, test_soft_lock\n")
  removeDir(sampleRoot)
  scratchTree(sampleRoot, files)

buildSampleTree()
setCurrentDir(sampleRoot) # every suite reads the sample repository, not the real one

suite "importClosure: the import forms":
  let root = "tmp" / "testplan_scratch"
  let origin = getCurrentDir()
  setup:
    removeDir(root)
    scratchTree(root, {
      "t/test_a.nim": """
import std/[os,
  strutils] # a trailing comment, with import b in it
import "../lib/up", lib/plain
from lib/fromonly import thing
import lib/aliased as al, lib/hidden except gone
import lib/pkg/[one, two]
import lib/oneliner from lib/second import nil
include lib/included
#[ block comment
import lib/commented ]#
# import lib/lineComment
let notImport = "import lib/inString"
""",
      "lib/up.nim": "import deep\n",
      "lib/deep.nim": "discard\n",
      "lib/plain.nim": "discard\n",
      "lib/fromonly.nim": "discard\n",
      "lib/aliased.nim": "discard\n",
      "lib/hidden.nim": "discard\n",
      "lib/pkg/one.nim": "discard\n",
      "lib/pkg/two.nim": "discard\n",
      "lib/oneliner.nim": "discard\n",
      "lib/second.nim": "discard\n",
      "lib/included.nim": "discard\n",
      "lib/commented.nim": "discard\n",
      "lib/lineComment.nim": "discard\n",
      "lib/inString.nim": "discard\n"})
    setCurrentDir(root)
  teardown:
    setCurrentDir(origin)
    removeDir(root)

  test "every import form is followed; the stdlib and comments are not":
    let c = importClosure("t/test_a.nim")
    for want in ["t/test_a.nim", "lib/up.nim", "lib/deep.nim", "lib/plain.nim",
                 "lib/fromonly.nim", "lib/aliased.nim", "lib/hidden.nim",
                 "lib/pkg/one.nim", "lib/pkg/two.nim", "lib/oneliner.nim",
                 "lib/second.nim", "lib/included.nim"]:
      check want in c
    for notWant in ["lib/commented.nim", "lib/lineComment.nim", "lib/inString.nim"]:
      check notWant notin c
    check c.len == 12

  test "a missing module is skipped, not an error":
    writeFile("t/test_b.nim", "import nothere/at/all\nimport lib/plain\n")
    check importClosure("t/test_b.nim") == ["t/test_b.nim", "lib/plain.nim"].toHashSet

suite "parseAreas":
  test "names combine; an unknown one is reported":
    var a: set[Area]
    check parseAreas("game, art", a) == ""
    check a == {arGame, arArt}
    var b: set[Area]
    check parseAreas("game,nope", b) == "nope"

suite "selectTests on the sample repository":
  let all = discoverTests()

  test "discovery finds tests/, games/<name>/tests/ and no helpers":
    check "tests/test_sim.nim" in all
    check "games/lab/tests/test_walk.nim" in all
    check "games/lab/tests/casual_bot.nim" notin all
    check all.allIt(it.extractFilename.startsWith("test_"))

  test "no area, `engine` and `all` keep every file":
    check selectTests(all, {}) == all
    check selectTests(all, {arEngine}) == all
    check selectTests(all, {arAll, arGame}) == all

  test "game: the game's tests and the para tests that link it, nothing else":
    let g = selectTests(all, {arGame})
    check "games/lab/tests/test_stamp.nim" in g
    check "games/lab/tests/test_hud.nim" in g
    check "tests/test_para_game.nim" in g # imports games/lab
    check "tests/test_sim.nim" notin g
    check "tests/test_art_lint.nim" notin g
    check "tests/test_para_toon.nim" notin g
    # every file that reaches games/ is in, by construction
    for f in all:
      check (f in g) == importClosure(f).anyIt(it.startsWith("games/"))

  test "art: the art tests, not the game's and not the engine's":
    let a = selectTests(all, {arArt})
    check "tests/test_art_lint.nim" in a
    check "tests/test_art_fix_cli.nim" in a
    check "tests/test_art_tile.nim" in a
    check "games/lab/tests/test_stamp.nim" notin a
    check "tests/test_sim.nim" notin a
    # toon.nim and clihelpers.nim are every command's: not art's alone
    check "tests/test_para_toon.nim" notin a

  test "a game change cannot reach an engine-only test":
    let g = selectTests(all, {arGame})
    for f in ["tests/test_app.nim", "tests/test_audio.nim", "tests/test_input.nim",
              "tests/test_sim_replay.nim", "tests/test_smoke.nim"]:
      check f notin g

  test "areas union":
    let both = selectTests(all, {arGame, arArt})
    check "tests/test_art_lint.nim" in both
    check "games/lab/tests/test_stamp.nim" in both

  test "--filter keeps only the paths that contain the substring (case-insensitive)":
    check selectTests(all, {}, "test_walk") == @["games/lab/tests/test_walk.nim"]
    check selectTests(all, {}, "TEST_WALK") == @["games/lab/tests/test_walk.nim"]
    check selectTests(all, {}, "no-such-file").len == 0

  test "--filter inside an area intersects":
    check selectTests(all, {arArt}, "test_walk").len == 0
    check selectTests(all, {arGame}, "test_walk").len == 1

  test "pytest and the para build ride with the full suite only":
    check wantsPytest({}, "")
    check wantsPytest({arArt}, "")
    check not wantsPytest({arGame}, "")
    check not wantsPytest({}, "test_walk")
    check wantsPytest({}, "tools/art")
    check wantsParaBuild({}, "")
    check wantsParaBuild({arEngine}, "")
    check not wantsParaBuild({arGame}, "")
    check not wantsParaBuild({}, "test_walk")

suite "--only-balance: the files that tag a balance pin":
  let all = discoverTests()
  let root = "tmp" / "testplan_balance_scratch"

  test "the sample's balance suite is selected":
    check "games/lab/tests/test_balance.nim" in selectTests(all, {}, "", onlyBalance = true)

  test "it intersects with --filter and --area":
    check selectTests(all, {}, "test_pacing", onlyBalance = true) ==
      @["games/lab/tests/test_pacing.nim", "games/lab_v1/tests/test_pacing.nim"]
    check selectTests(all, {}, "test_walk", onlyBalance = true).len == 0
    check selectTests(all, {arArt}, "", onlyBalance = true).len == 0
    check "tests/test_para_game.nim" in selectTests(all, {arGame}, "", onlyBalance = true)

  test "without the flag the selection is unchanged":
    check selectTests(all, {}, "", onlyBalance = false) == all

  test "only a tag at the start of a line counts: a comment, a string or a plain test does not":
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    writeFile(root / "plain.nim", "suite \"x\":\n  test \"a\":\n    check true\n")
    writeFile(root / "commented.nim", "# balanceTest \"a\":\n  # playtestRule \"b\"\n#[ balance: ]#\n")
    writeFile(root / "pin.nim", "suite \"x\":\n  balanceTest \"a\":\n    check true\n")
    writeFile(root / "rule.nim", "suite \"x\":\n  playtestRule \"a\":\n    check true\n")
    writeFile(root / "mixed.nim", "suite \"x\":\n  mixedTest \"a\":\n    balance:\n      check true\n")
    check not hasBalanceTests(root / "plain.nim")
    check not hasBalanceTests(root / "commented.nim")
    check hasBalanceTests(root / "pin.nim")
    check hasBalanceTests(root / "rule.nim")
    check hasBalanceTests(root / "mixed.nim")
    check not hasBalanceTests(root / "missing.nim")

  test "--only-balance never runs pytest or the para build":
    check not wantsPytest({}, "", onlyBalance = true)
    check not wantsPytest({arArt}, "", onlyBalance = true)
    check not wantsParaBuild({}, "", onlyBalance = true)
    check wantsPytest({}, "")

suite "test groups: several test files as one program":
  let all = discoverTests()
  let groups = discoverGroups()
  let pins = "games/lab/tests/pin_tests.nim"
  let frozenPins = "games/lab_v1/tests/pin_tests.nim"
  let root = "tmp" / "testplan_group_scratch"
  let origin = getCurrentDir()

  proc expanded(entries: seq[string]): seq[string] =
    ## The test files `entries` run: a group is its members.
    for e in entries:
      if e in groups: result.add groupMembers(e) else: result.add e

  test "the sample's groups are the game's and the frozen copy's balance pin files, each a discovered test file":
    check groups == @[pins, frozenPins]
    check groupMembers(pins) == @[
      "games/lab/tests/test_balance.nim",
      "games/lab/tests/test_data_pivot.nim",
      "games/lab/tests/test_hub_bot.nim",
      "games/lab/tests/test_hub_life_script.nim",
      "games/lab/tests/test_pacing.nim"]
    check groupMembers(frozenPins) == @[
      "games/lab_v1/tests/test_balance.nim",
      "games/lab_v1/tests/test_goldens_script.nim",
      "games/lab_v1/tests/test_hub_bot.nim",
      "games/lab_v1/tests/test_pacing.nim",
      "games/lab_v1/tests/test_soft_lock.nim"]
    for group in [pins, frozenPins]:
      for member in groupMembers(group):
        check member in all
        check hasBalanceTests(member) # or --only-balance would leave it out, and the group with it
      check group notin all # the group is not itself a test file

  test "--only-balance (CI's balance job) runs each group in place of its files":
    let files = selectTests(all, {}, "", onlyBalance = true)
    check planEntries(files, groups) ==
      @["tests/test_para_game.nim", pins, frozenPins]
    check planEntries(selectTests(all, {arGame}, "", onlyBalance = true), groups) ==
      @["tests/test_para_game.nim", pins, frozenPins]

  test "whatever the selection, the plan runs exactly its files: none dropped, none twice":
    var selections = @[all, selectTests(all, {arGame}), selectTests(all, {arArt}),
                       selectTests(all, {}, "", onlyBalance = true),
                       selectTests(all, {}, "test_pacing"), selectTests(all, {}, "games/lab")]
    for n in [2, 4]:
      for i in 1 .. n: selections.add shardOf(all, Shard(index: i, count: n))
    for files in selections:
      let entries = planEntries(files, groups)
      check expanded(entries).sorted == files.sorted
      check entries.deduplicate.len == entries.len

  test "a selection that holds only some of a group's files runs them on their own":
    let members = groupMembers(pins)
    check planEntries(members, groups) == @[pins]
    check planEntries(members[0 .. ^2], groups) == members[0 .. ^2]
    check planEntries(@[members[3]], groups) == @[members[3]]
    check planEntries(selectTests(all, {}, "test_pacing"), groups) ==
      @["games/lab/tests/test_pacing.nim", "games/lab_v1/tests/test_pacing.nim"]
    # a shard deals the files over the runners, so no shard holds the whole group
    for i in 1 .. 4:
      check pins notin planEntries(shardOf(all, Shard(index: i, count: 4)), groups)
      check frozenPins notin planEntries(shardOf(all, Shard(index: i, count: 4)), groups)

  test "the group stands at its first member's place; the other files keep their order":
    let members = groupMembers(pins)
    let files = @["tests/test_a.nim", members[0], "games/lab/tests/test_b.nim"] &
      members[1 .. ^1] & @["games/lab/tests/test_z.nim"]
    check planEntries(files, groups) ==
      @["tests/test_a.nim", pins, "games/lab/tests/test_b.nim", "games/lab/tests/test_z.nim"]
    check planEntries(files, @[]) == files

  test "members are the group's own test_* imports, in order: other imports and other directories are not":
    removeDir(root)
    scratchTree(root, {
      "games/g/tests/pin_tests.nim": """
{.warning[UnusedImport]: off.}
import paraloop/testkit
import test_b, test_a # two on a line
import helper
import "../other/test_elsewhere"
# import test_commented
import test_c
""",
      "games/g/tests/test_a.nim": "discard\n",
      "games/g/tests/test_b.nim": "discard\n",
      "games/g/tests/test_c.nim": "discard\n",
      "games/g/tests/test_commented.nim": "discard\n",
      "games/g/tests/helper.nim": "discard\n",
      "games/g/other/test_elsewhere.nim": "discard\n",
      "games/h/tests/test_d.nim": "discard\n",
      "tests/test_e.nim": "discard\n"})
    setCurrentDir(root)
    defer:
      setCurrentDir(origin)
      removeDir(root)
    check discoverGroups() == @["games/g/tests/pin_tests.nim"]
    check groupMembers("games/g/tests/pin_tests.nim") ==
      @["games/g/tests/test_b.nim", "games/g/tests/test_a.nim", "games/g/tests/test_c.nim"]
    check groupMembers("games/h/tests/pin_tests.nim").len == 0
    # a group with no member is never an entry
    writeFile("games/h/tests/pin_tests.nim", "import helper\n")
    check planEntries(@["games/h/tests/test_d.nim"], discoverGroups()) == @["games/h/tests/test_d.nim"]

suite "--shard I/N: the slices CI runs on separate runners":
  let all = discoverTests()

  proc shards(files: seq[string], n: int, class: proc(f: string): int = shardClass): seq[seq[string]] =
    for i in 1 .. n: result.add shardOf(files, Shard(index: i, count: n), class)

  test "parseShard: I/N with 1 <= I <= N; anything else says what is wrong":
    var s: Shard
    check parseShard("2/4", s) == ""
    check s == Shard(index: 2, count: 4)
    check parseShard(" 1 / 1 ", s) == ""
    check s == noShard
    for bad in ["", "2", "2/", "/4", "a/b", "0/4", "5/4", "1/0", "-1/4", "1/2/3"]:
      check parseShard(bad, s) != ""

  test "the shards together are exactly the selection: no file dropped, none twice, order kept":
    for n in 1 .. 6:
      let parts = shards(all, n)
      check parts.len == n
      var union: seq[string]
      for p in parts:
        union.add p
        # each shard keeps `all`'s order (a subsequence of it)
        check p == all.filterIt(it in p)
      check union.sorted == all.sorted
      check union.len == all.len
      check union.deduplicate.len == all.len

  test "1/1 is the whole selection; more shards than files leaves some empty, still a partition":
    check shardOf(all, noShard) == all
    let few = all[0 .. 2]
    let parts = shards(few, 5)
    check parts.filterIt(it.len == 0).len == 2
    var union: seq[string]
    for p in parts: union.add p
    check union.sorted == few.sorted
    check shards(@[], 4).allIt(it.len == 0)

  test "the classes come from the sources: a .nims sidecar, a game in the import closure, the rest":
    check shardClass("games/lab/tests/test_soft_lock.nim") == 0  # test_soft_lock.nims
    check shardClass("tests/test_sim_replay.nim") == 0                    # test_sim_replay.nims
    check shardClass("games/lab/tests/test_walk.nim") == 1       # the game, no sidecar
    check shardClass("tests/test_para_game.nim") == 0                     # links the game, has a sidecar
    check shardClass("tests/test_para_dev_cli.nim") == 1                  # links the game
    check shardClass("tests/test_art_toml.nim") == 2
    check shardClass("tests/test_sim.nim") == 2
    check linksGame("games/lab/tests/test_walk.nim")
    check not linksGame("tests/test_art_toml.nim")

  test "each class is spread evenly over the shards (give or take one)":
    for c in 0 .. 2:
      check all.countIt(shardClass(it) == c) > 0
    for n in [2, 3, 4]:
      for c in 0 .. 2:
        let total = all.countIt(shardClass(it) == c)
        for p in shards(all, n):
          check p.countIt(shardClass(it) == c) in [total div n, total div n + 1]

  test "the assignment is a pure function of the list: a synthetic list, dealt by class in order":
    # digits are class 0, upper case class 1, lower case class 2
    let files = @["a", "B", "1", "c", "D", "e", "2", "F", "g", "3"]
    proc class(f: string): int =
      if f[0].isDigit: 0 elif f[0].isUpperAscii: 1 else: 2
    let parts = shards(files, 2, class)
    # 1, 2, 3 go 1, 2, 1; B, D, F go 1, 2, 1; a, c, e, g go 1, 2, 1, 2
    check parts[0] == @["a", "B", "1", "e", "F", "3"]
    check parts[1] == @["c", "D", "2", "g"]
    check shards(files, 2, class) == parts  # the same every time

  test "pytest rides with shard 1 only, so it runs once":
    check noShard.shardCarriesExtras
    check Shard(index: 1, count: 4).shardCarriesExtras
    check not Shard(index: 2, count: 4).shardCarriesExtras
    check not Shard(index: 4, count: 4).shardCarriesExtras
