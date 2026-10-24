# Which test files `para test` runs: discovery, the `--filter` substring and
# the `--area` selector. Pure file and string work (no processes), so the
# selection is unit-tested and `para test` can hand the result to
# `nimble test` as a plan file.
#
# An area is a set of source roots; a test file is in it when its transitive
# import closure (the repo `.nim` files it pulls in, found by reading its
# `import`/`from`/`include` lines -- no compile) touches one of the roots.
# That is the property that makes skipping the rest safe: a test whose
# closure misses every changed file cannot see the change. The closure is
# computed from the imports on each run, so the map cannot rot as tests and
# modules move (tests/test_para_testplan.nim also pins today's map).
#
# A selection that holds every test file of a test group runs them as one
# program (`planEntries`, below): the same tests, one compile.

import std/[os, strutils, sets, sequtils, algorithm]

type Area* = enum
  arGame = "game"       ## games/<name>/: the game's code, its tests
  arEngine = "engine"   ## everything else that is code or build config
  arArt = "art"         ## the art pipeline: `para art`, tools/art, art fixtures
  arAll = "all"         ## the whole suite

const
  areaRoots*: array[Area, seq[string]] = [
    arGame: @["games/"],
    arEngine: @[],       # engine changes run everything: see `selectTests`
    # The art pipeline's own code and fixtures. tools/para/art/clihelpers.nim
    # and toon.nim are left out on purpose: every `para` command imports them,
    # so a change there is an engine change.
    arArt: @["tools/para/artcmd.nim", "tools/para/art/fix.nim",
             "tools/para/art/lint.nim", "tools/para/art/profile.nim",
             "tools/para/art/sheet.nim", "tools/para/art/sidecar.nim",
             "tools/para/art/toml.nim", "tools/art/", "tests/fixtures/art/"],
    arAll: @[]]

  pytestId* = "pytest tools/art/tests"
    ## The plan entry for the Python unit tests; every other entry is a
    ## `test_*.nim` path.
  paraBuildId* = "build tools/para/para.nim"
    ## The plan entry for the final `para` build (`nimble test`'s last step).

proc parseAreas*(s: string, areas: var set[Area]): string =
  ## `"game,art"` -> `{arGame, arArt}`; "" when fine, else the bad token.
  for tok in s.split(','):
    let t = tok.strip
    if t.len == 0: continue
    var found = false
    for a in Area:
      if $a == t:
        areas.incl a
        found = true
    if not found: return t

proc discoverTests*(): seq[string] =
  ## Every `test_*.nim` the full suite runs, in `nimble test`'s order:
  ## tests/, then examples/<name>/tests/, then games/<name>/tests/ (each
  ## directory sorted by file name).
  proc sweep(dir: string): seq[string] =
    if not dirExists(dir): return
    var files: seq[string]
    for kind, f in walkDir(dir):
      if kind == pcFile: files.add f
    for f in files.sorted:
      let name = f.extractFilename
      if name.startsWith("test_") and name.endsWith(".nim"):
        result.add f.replace('\\', '/')
  result.add sweep("tests")
  for base in ["examples", "games"]:
    if not dirExists(base): continue
    var dirs: seq[string]
    for kind, gameDir in walkDir(base):
      if kind == pcDir: dirs.add gameDir
    for gameDir in dirs.sorted:
      result.add sweep(gameDir / "tests")

# --- import closure ---------------------------------------------------------

proc stripComments(src: string): string =
  ## Drops `#` line comments and `#[ ... ]#` block comments (outside string
  ## literals well enough for import lines; a stray `#` inside a string only
  ## ever hides the tail of one line).
  var i = 0
  var depth = 0
  var inStr = false
  while i < src.len:
    let c = src[i]
    if depth > 0:
      if c == '#' and i + 1 < src.len and src[i + 1] == ']': dec depth; i += 2; continue
      if c == '#' and i + 1 < src.len and src[i + 1] == '[': inc depth; i += 2; continue
      if c == '\n': result.add c
      inc i
    elif inStr:
      result.add c
      if c == '"' or c == '\n': inStr = false
      inc i
    elif c == '"':
      inStr = true; result.add c; inc i
    elif c == '#':
      if i + 1 < src.len and src[i + 1] == '[':
        inc depth; i += 2
      else:
        while i < src.len and src[i] != '\n': inc i
    else:
      result.add c; inc i

proc importStatements(src: string): seq[string] =
  ## Each top-of-line `import`/`from`/`include`/`export` statement as one
  ## string with its continuation lines (open brackets, trailing comma)
  ## joined.
  let lines = stripComments(src).splitLines
  var i = 0
  while i < lines.len:
    let l = lines[i]
    let t = l.strip
    if l.len > 0 and l[0] notin {' ', '\t'} and
       (t.startsWith("import ") or t.startsWith("from ") or t.startsWith("include ") or
        t.startsWith("export ")):
      var stmt = t
      proc open(s: string): bool =
        s.count('[') > s.count(']') or s.strip.endsWith(",")
      while open(stmt) and i + 1 < lines.len:
        inc i
        stmt.add " " & lines[i].strip
      result.add stmt
    inc i

proc expandSpec(spec: string): seq[string] =
  ## `std/[a, b]` -> `std/a`, `std/b`; `x as y`/`x except z` -> `x`.
  var s = spec.strip
  for kw in [" as ", " except "]:
    let k = s.find(kw)
    if k >= 0: s = s[0 ..< k].strip
  let lb = s.find('[')
  if lb >= 0:
    let rb = s.rfind(']')
    let prefix = s[0 ..< lb]
    for part in s[lb + 1 ..< rb].split(','):
      result.add expandSpec(prefix & part.strip)
  elif s.len > 0:
    result.add s.strip(chars = {'"'})

proc splitTopLevel(s: string): seq[string] =
  var depth = 0
  var cur = ""
  for c in s:
    if c == '[': inc depth
    elif c == ']': dec depth
    if c == ',' and depth == 0:
      result.add cur; cur = ""
    else: cur.add c
  if cur.strip.len > 0: result.add cur

proc moduleSpecs(stmt: string): tuple[specs: seq[string], isInclude: bool] =
  ## The module names one statement refers to. `from X import y` names X;
  ## `import X, Y` names each. A one-liner such as `import a from b import
  ## nil` names both, so the statement is first cut at every ` from `.
  var rest = stmt
  var pieces: seq[string]
  # pararules' own `import pararules from pararules/engine import nil`
  let parts = rest.split(" from ")
  for idx, p in parts:
    let q = if idx == 0: p else: "from " & p
    pieces.add q
  for p in pieces:
    var t = p.strip
    if t.startsWith("import "):
      t = t["import ".len .. ^1]
      for sp in splitTopLevel(t): result.specs.add expandSpec(sp)
    elif t.startsWith("include "):
      result.isInclude = true
      for sp in splitTopLevel(t["include ".len .. ^1]): result.specs.add expandSpec(sp)
    elif t.startsWith("from "):
      t = t["from ".len .. ^1]
      let k = t.find(" import ")
      if k >= 0: t = t[0 ..< k]
      result.specs.add expandSpec(t)
    elif t.startsWith("export "):
      for sp in splitTopLevel(t["export ".len .. ^1]):
        discard sp # exports re-name already-imported modules

proc resolveModule(spec, fromFile: string): string =
  ## The repo file `spec` names when imported from `fromFile`, or "" for the
  ## stdlib and nimble packages (not repo sources). Nim finds a module next
  ## to the importer first, then through the `--path`s (the repo root, set by
  ## tests/config.nims and the compile's cwd, and `src`, set by config.nims);
  ## all three are tried here.
  let rel = if spec.endsWith(".nim"): spec else: spec & ".nim"
  for base in [fromFile.parentDir, ".", "src"]:
    let cand = normalizedPath(base / rel).replace('\\', '/')
    let clean = if cand.startsWith("./"): cand[2 .. ^1] else: cand
    if fileExists(clean) and not clean.startsWith("..") and not clean.isAbsolute:
      return clean

proc importClosure*(file: string): HashSet[string] =
  ## `file` plus every repo `.nim` file it imports or includes, transitively,
  ## as repo-relative `/` paths.
  var todo = @[file.replace('\\', '/')]
  while todo.len > 0:
    let f = todo.pop()
    if f in result: continue
    result.incl f
    var src: string
    try: src = readFile(f)
    except IOError: continue
    for stmt in importStatements(src):
      for spec in moduleSpecs(stmt).specs:
        let r = resolveModule(spec, f)
        if r.len > 0 and r notin result: todo.add r

proc inRoots(path: string, roots: seq[string]): bool =
  roots.anyIt(path == it or (it.endsWith("/") and path.startsWith(it)))

proc touchesArea*(closure: HashSet[string], areas: set[Area]): bool =
  ## True when `closure` has a file under one of `areas`' roots.
  for a in areas:
    for f in closure:
      if inRoots(f, areaRoots[a]): return true

# --- balance tags -----------------------------------------------------------

proc hasBalanceTests*(file: string): bool =
  ## True when the test file tags a test as a balance pin with
  ## `paraloop/testkit`: a `balanceTest`/`playtestRule` test or a `balance:`
  ## block, found at the start of a line (comments do not count). A file that
  ## only has plain tests has nothing for `--only-balance` to run.
  var src: string
  try: src = readFile(file)
  except IOError: return false
  for line in stripComments(src).splitLines:
    let t = line.strip
    if t.startsWith("balanceTest ") or t.startsWith("playtestRule ") or t == "balance:":
      return true

proc laneFolder*(f: string): string =
  ## `<game>.<id>` for a test file in a helper's lane (`games/<game>.<id>/...`,
  ## tools/para/lanecmd.nim), else "".
  let parts = f.replace('\\', '/').split('/')
  if parts.len > 2 and parts[0] == "games" and '.' in parts[1]: parts[1] else: ""

proc selectTests*(all: seq[string], areas: set[Area], filter = "",
                  onlyBalance = false): seq[string] =
  ## The test files to run: `all` narrowed by the areas (none given, `engine`
  ## or `all` keep every file -- an engine change can reach any test), then
  ## by the `filter` substring of the path, then, for `onlyBalance`, to the
  ## files that tag a balance pin. The input order is kept. A lane's copy of
  ## a game's tests runs only for a filter that names the lane's folder.
  let everything = areas == {} or arAll in areas or arEngine in areas
  let needle = filter.toLowerAscii
  for f in all:
    if needle.len > 0 and needle notin f.toLowerAscii: continue
    let lane = laneFolder(f)
    if lane.len > 0 and lane.toLowerAscii notin needle: continue
    if onlyBalance and not hasBalanceTests(f): continue
    if everything or touchesArea(importClosure(f), areas):
      result.add f

proc wantsPytest*(areas: set[Area], filter: string, onlyBalance = false): bool =
  ## The Python tests run on a full run and for the art area; a `--filter`
  ## run names Nim test files, so it skips them unless it matches the id.
  ## They hold no balance pin, so `onlyBalance` never runs them.
  if onlyBalance: return false
  if filter.len > 0: return filter.toLowerAscii in pytestId
  areas == {} or arAll in areas or arEngine in areas or arArt in areas

proc wantsParaBuild*(areas: set[Area], filter: string, onlyBalance = false): bool =
  ## The final `para` build only matters when the whole suite runs (the
  ## engine can break it); area, filter and `onlyBalance` runs leave it to
  ## CI's own build.
  not onlyBalance and filter.len == 0 and (areas == {} or arAll in areas or arEngine in areas)

# --- test groups ------------------------------------------------------------
#
# A test group is one program that imports several test files of its directory,
# so they share one compile of what they all link (a game: the Nim front-end
# alone is most of a minute a program). The files stay ordinary test files: each
# still compiles and runs on its own, and that is what runs whenever a selection
# holds only some of them (`--filter`, a shard). When a selection holds every
# member, the plan names the group in their place and `nimble test` builds and
# runs that one program; it prints `running <member>` as each member's tests
# start (paraloop/testkit), so progress and failures still name the test file.
# The members are read from the group's own `import` lines: one list, the
# program's.

const groupFileName* = "pin_tests.nim"
  ## The group program of a tests directory, when it has one. Not a `test_*`
  ## name, so discovery never takes it for a test file.

proc discoverGroups*(): seq[string] =
  ## Every group program, in `discoverTests`' directory order.
  var dirs = @["tests"]
  for base in ["examples", "games"]:
    if not dirExists(base): continue
    var games: seq[string]
    for kind, gameDir in walkDir(base):
      if kind == pcDir: games.add gameDir
    for gameDir in games.sorted:
      dirs.add gameDir / "tests"
  for dir in dirs:
    let group = (dir / groupFileName).replace('\\', '/')
    if fileExists(group): result.add group

proc groupMembers*(group: string): seq[string] =
  ## The test files `group` runs: the `test_*` modules of its own directory it
  ## imports, in import order (the order their tests run in).
  var src: string
  try: src = readFile(group)
  except IOError: return
  let dir = group.replace('\\', '/').parentDir
  for stmt in importStatements(src):
    for spec in moduleSpecs(stmt).specs:
      let member = resolveModule(spec, group)
      if member.parentDir == dir and member.extractFilename.startsWith("test_") and
         member notin result:
        result.add member

proc planEntries*(files, groups: seq[string]): seq[string] =
  ## `files` as `nimble test` runs them: every group whose members are all in
  ## `files` stands in for them, at its first member's place. A group with a
  ## member left out (or with no member at all) is not used, so the entries
  ## always cover `files` exactly: no file dropped, none run twice.
  var groupOf = newSeq[string](files.len)
  for group in groups:
    let members = groupMembers(group)
    if members.len == 0 or not members.allIt(it in files): continue
    for i, f in files:
      if f in members and groupOf[i].len == 0: groupOf[i] = group
  for i, f in files:
    if groupOf[i].len == 0: result.add f
    elif groupOf[i] notin result: result.add groupOf[i]

# --- shards (`--shard I/N`) -------------------------------------------------
#
# CI runs the suite as N jobs on N runners (one `para test --shard i/N` each,
# .github/workflows/ci.yml's `test-shard` matrix). The split is applied after
# `--area`, `--filter` and the balance flags, and is a pure function of the
# selected file list, so the N shards together are exactly the unsharded
# selection (tests/test_para_testplan.nim proves it). Balance: the files are
# dealt round-robin in sorted order, one class at a time, so every shard gets
# the same number of each class, give or take one. The classes come from the
# sources, not a committed weight table that could go stale: a test file with
# a `.nims` sidecar is a heavy simulation test (the sidecar exists to build it
# -O1; these run 10-50 s each and dominate a warm run), a file whose import
# closure reaches a game compiles the whole game (8-13 s cold), everything
# else is light (about 1 s).

type Shard* = object
  ## This run's slice of the selection: the `index`-th (1-based) of `count`.
  ## `count == 1` is the whole selection (no sharding).
  index*, count*: int

const noShard* = Shard(index: 1, count: 1)

proc parseShard*(s: string, shard: var Shard): string =
  ## `"2/4"` -> index 2 of 4. Returns "" when fine, else what is wrong with
  ## `s` (for the usage error).
  let parts = s.split('/')
  if parts.len != 2: return "want INDEX/COUNT, e.g. 2/4"
  var i, n: int
  try:
    i = parseInt(parts[0].strip)
    n = parseInt(parts[1].strip)
  except ValueError:
    return "want two numbers INDEX/COUNT, e.g. 2/4"
  if n < 1: return "COUNT must be at least 1"
  if i < 1 or i > n: return "INDEX must be between 1 and " & $n
  shard = Shard(index: i, count: n)

proc linksGame*(file: string): bool =
  ## True when the test file's import closure reaches a game (games/ or
  ## examples/): it compiles the whole game.
  for f in importClosure(file):
    if inRoots(f, @["games/", "examples/"]): return true

proc shardClass*(file: string): int =
  ## The class `shardOf` deals `file` in: 0 for a heavy simulation test (one
  ## with a `test_<name>.nims` sidecar beside it), 1 for a file that links a
  ## game, 2 for the rest. Dealt class by class, the long-running and the
  ## slow-to-compile files each spread over every shard.
  if fileExists(file.changeFileExt("nims")): 0
  elif linksGame(file): 1
  else: 2

proc shardOf*(files: seq[string], shard: Shard,
              class: proc(f: string): int = shardClass): seq[string] =
  ## The files `shard` runs, in `files`' order. Each class (`class`, 0 to 2)
  ## is dealt round-robin on its own (the k-th file of a class goes to shard
  ## `k mod count + 1`), so every file lands in exactly one shard and the
  ## shards together are `files` exactly. `count == 1` returns `files`.
  if shard.count <= 1: return files
  var picked = newSeq[bool](files.len)
  let classes = files.mapIt(class(it))
  for c in 0 .. 2:
    var k = 0
    for idx in 0 ..< files.len:
      if classes[idx] == c:
        if k mod shard.count == shard.index - 1: picked[idx] = true
        inc k
  for idx, f in files:
    if picked[idx]: result.add f

proc shardCarriesExtras*(shard: Shard): bool =
  ## Whether this shard runs the plan entry that is not a test file (pytest):
  ## only the first shard does, so it runs once. (The suite's final `para`
  ## build is left out of every shard: a sharded run is CI's, and CI builds
  ## `para` itself first, since it needs the binary to run the shard.)
  shard.index == 1
