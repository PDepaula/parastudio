# What `para check` and `para save` share: picking the game, running git
# with an argument list (never a shell string, so quoting is the same on
# Windows), the "what changed outside games/<game>" scan, the numbering of
# `save-<game>-<n>` tags, and the stamp that tells `para save` the checks
# just passed.
#
# Where a game's saves live: a game made by `para new` is its own git
# repository (`games/<game>/.git`), and every git call here runs INSIDE it, so
# paths are relative to the game and nothing outside it can be "changed". A
# game without its own `.git` is tracked by the repository that contains
# `games/` (a game made before `para new` ran `git init`); git then
# runs at the repo root with the pathspec `games/<game>/`, as it always did.
# `repoDir`, `repoPrefix` and `gameSpec` are the three facts that differ.
#
# The stamp is one line in `tmp/check/<game>.stamp` (under the paraloop
# checkout, in both modes): a digest of the current HEAD of the game's
# repository plus the name and bytes of every file under games/<game> that git
# would add (tracked or untracked, not ignored). `para check` writes it when
# every step passed; `para save` recomputes it and refuses on any difference,
# so an edit to the game after the checks, or a new save, makes it stale.
# The digest is FNV-1a over the bytes: it only has to notice an accidental
# change, not resist an attacker, and it needs no dependency.
#
# `gitQuick`, `gameChanges` and `listSavePoints` are also what the session-start
# digest (`para producer-context`) asks git: they never wait long and the caller
# treats any failure as "unknown".
#
# Every proc takes the repo `root` (empty means the working directory), so
# tests drive a scratch repo without changing directory.

import std/[os, strutils, strformat, algorithm]
import art/clihelpers
import nimutil

type Run = clihelpers.Run

const
  gamesDir* = "games"
  planFile* = "PLAN.md"

proc validGameName*(name: string): bool =
  ## The names `para new` makes: lowercase letters, digits and `_`, starting
  ## with a letter. It is also what keeps a name safe inside a path and a tag.
  name.len > 0 and name[0] in {'a'..'z'} and
    name.allCharsInSet({'a'..'z', '0'..'9', '_'})

proc gameDirOf*(root, game: string): string =
  root / gamesDir / game

proc gamePrefix*(game: string): string =
  ## How the paraloop checkout spells every path of the game, on every platform.
  gamesDir & "/" & game & "/"

proc ownRepo*(root, game: string): bool =
  ## `games/<game>` is a git repository of its own (`.git` there, a folder or,
  ## for a linked worktree, a file).
  let g = gameDirOf(root, game) / ".git"
  dirExists(g) or fileExists(g)

proc repoDir*(root, game: string): string =
  ## Where git runs for the game: its own folder, else the repo root.
  if ownRepo(root, game): gameDirOf(root, game) else: root

proc repoPrefix*(root, game: string): string =
  ## How the game's repository spells the game's paths: "" inside its own
  ## repository, `games/<game>/` in the root repo.
  if ownRepo(root, game): "" else: gamePrefix(game)

proc gameSpec*(root, game: string): string =
  ## The git pathspec of the whole game inside its repository.
  if ownRepo(root, game): "." else: gamePrefix(game)

proc playCommand*(game: string): string =
  "nim c -r -d:dev " & gamesDir & "/" & game & "/" & game & ".nim"

proc gameTag*(game: string, n: int): string =
  &"save-{game}-{n}"

proc gamesWithPlan*(root: string): seq[string] =
  ## The games a producer is working on: `games/<name>/PLAN.md` exists. A helper's lane
  ## (`games/<game>.<id>/`, a copy of the game with its PLAN.md) is not a game: its name has a dot,
  ## which no game name has.
  let base = root / gamesDir
  if not dirExists(base): return
  for kind, path in walkDir(base):
    let name = path.extractFilename
    if kind == pcDir and validGameName(name) and fileExists(path / planFile):
      result.add name
  result.sort()

# --- lanes -------------------------------------------------------------------
#
# A lane is a helper's own copy of a game: a git worktree of the game's repository on the branch
# `lane/<id>`, checked out next to the game as `games/<game>.<id>/` (the same depth, so the game's
# `../../src` paths still compile). tools/para/lanecmd.nim makes, lands and removes them.

proc validLaneId*(id: string): bool =
  ## A lane id: a role (`builder`, `art`) and an optional number, lowercase letters and digits.
  id.len > 0 and id.len <= 20 and id[0] in {'a'..'z'} and id.allCharsInSet({'a'..'z', '0'..'9'})

proc laneName*(game, id: string): string =
  game & "." & id

proc laneDir*(root, game, id: string): string =
  root / gamesDir / laneName(game, id)

proc lanePrefix*(game, id: string): string =
  ## How the paraloop checkout spells every path of the lane, on every platform.
  gamesDir & "/" & laneName(game, id) & "/"

proc laneBranch*(id: string): string =
  "lane/" & id

proc pickGame*(root, requested: string, game: var string): Run =
  ## `--game NAME` when given, else the only game with a PLAN.md. Code 0 and
  ## `game` set, or a usage error (2) saying what to do.
  if requested.len > 0:
    if not validGameName(requested) or not dirExists(gameDirOf(root, requested)):
      let plans = gamesWithPlan(root)
      return errorOut(&"there is no game called \"{requested}\" in {gamesDir}/",
        if plans.len > 0: @["Games with a plan: " & plans.join(", ")] else: @[])
    game = requested
    return ("", 0)
  let plans = gamesWithPlan(root)
  case plans.len
  of 0:
    errorOut(&"no game in {gamesDir}/ has a {planFile} yet", @["Say which game with --game <name>"])
  of 1:
    game = plans[0]
    ("", 0)
  else:
    errorOut("more than one game has a " & planFile & ": " & plans.join(", "),
             @["Say which one with --game <name>"])

# --- git ---------------------------------------------------------------------

proc gitArgs*(root: string, args: seq[string]): ProcResult =
  ## `git <args>` in `root`: stdout and stderr together, the real exit code,
  ## 127 when git cannot be started.
  runCaptured("git", args, root)

proc git*(root: string, args: varargs[string]): ProcResult =
  gitArgs(root, @args)

proc gitMissing*(r: ProcResult): bool =
  r.exitCode == 127

var quickGitMs* = 3000 ## how long a session-start question to git may take (a var so a test can shorten it)

proc gitQuick*(root: string, args: varargs[string]): ProcResult =
  ## `git <args>` for a question asked at session start: it takes no optional
  ## lock (so it never gets in the way of another git) and is stopped after
  ## `quickGitMs` (the exit code is then `timedOutCode`).
  runCaptured("git", @["--no-optional-locks"] & @args, root, timeoutMs = quickGitMs)

proc isDetached*(root: string): bool =
  ## HEAD is not on a named line of work (`symbolic-ref` fails).
  git(root, "symbolic-ref", "-q", "HEAD").exitCode != 0

proc headSha*(root: string): string =
  ## The current commit, or "" before the first one.
  let r = git(root, "rev-parse", "--verify", "-q", "HEAD")
  if r.exitCode == 0: r.output.strip else: ""

proc changedPaths*(root: string, ok: var bool): seq[string] =
  ## Every path git reports as changed (staged, unstaged or untracked, one
  ## per file), in `/` form. `ok` is false when git could not say.
  let r = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")
  ok = r.exitCode == 0
  if not ok: return
  for entry in r.output.split('\0'):
    if entry.len > 3: result.add entry[3 .. ^1]

proc nestedGameRepo(root, p: string): bool =
  ## `p` (a path in the root repo) is a whole other game that is a repository of
  ## its own, which the root repo only sees as one untracked folder: not a
  ## change to the root repo's own files.
  let prefix = gamesDir & "/"
  if not p.startsWith(prefix) or p.len == prefix.len: return false
  let rest = p[prefix.len .. ^1]
  let slash = rest.find('/')
  ownRepo(root, if slash < 0: rest else: rest[0 ..< slash])

proc outsideGame*(root: string, paths: seq[string], game: string): seq[string] =
  ## The changed paths (as the game's repository spells them) that are not the
  ## game's. Inside the game's own repository there are none.
  let prefix = repoPrefix(root, game)
  for p in paths:
    if not p.startsWith(prefix) and not nestedGameRepo(root, p): result.add p

proc insideGame*(root: string, paths: seq[string], game: string): seq[string] =
  let prefix = repoPrefix(root, game)
  for p in paths:
    if p.startsWith(prefix): result.add p

proc gameChanges*(root, game: string, ok: var bool): seq[string] =
  ## Every path of the game that git reports as changed (staged, unstaged or
  ## untracked, one per file), relative to the game's folder. `ok` is false
  ## when git could not say.
  let prefix = repoPrefix(root, game)
  let r = gitQuick(repoDir(root, game), "status", "--porcelain=v1", "-z", "--untracked-files=all",
                   "--no-renames", "--", gameSpec(root, game))
  ok = r.exitCode == 0
  if not ok: return
  for entry in r.output.split('\0'):
    if entry.len > 3:
      let path = entry[3 .. ^1]
      result.add(if path.startsWith(prefix): path[prefix.len .. ^1] else: path)

type SavePoint* = object
  n*: int
  saved*, note*: string ## the date (YYYY-MM-DD) and the note it was saved with

proc listSavePoints*(root, game: string, quick = false): tuple[res: ProcResult, points: seq[SavePoint]] =
  ## Every `save-<game>-<n>` tag of the game's repository with its date and
  ## note, ascending by n;
  ## `res` is git's answer (nonzero when it could not list). `para save --list`
  ## prints this, and the session-start digest reads the last one. `quick` is
  ## for the hook: it never waits long (see `gitQuick`).
  let prefix = &"refs/tags/save-{game}-"
  let fmt = "--format=%(refname)%09%(creatordate:short)%09%(contents:subject)"
  let repo = repoDir(root, game)
  result.res = if quick: gitQuick(repo, "for-each-ref", fmt, prefix & "*")
               else: git(repo, "for-each-ref", fmt, prefix & "*")
  if result.res.exitCode != 0: return
  for line in result.res.output.splitLines:
    let parts = line.split('\t')
    if parts.len < 3 or not parts[0].startsWith(prefix): continue
    let digits = parts[0][prefix.len .. ^1]
    if digits.len == 0 or not digits.allCharsInSet(Digits): continue
    result.points.add SavePoint(n: parseInt(digits), saved: parts[1], note: parts[2 .. ^1].join("\t"))
  result.points.sort(proc (a, b: SavePoint): int = cmp(a.n, b.n))

proc savePointNumbers*(root, game: string): seq[int] =
  ## The n of every `save-<game>-<n>` tag, ascending.
  let prefix = &"save-{game}-"
  let r = git(repoDir(root, game), "tag", "--list", prefix & "*")
  if r.exitCode != 0: return
  for line in r.output.splitLines:
    let t = line.strip
    if t.startsWith(prefix):
      let digits = t[prefix.len .. ^1]
      if digits.len > 0 and digits.allCharsInSet(Digits):
        result.add parseInt(digits)
  result.sort()

proc nextSavePoint*(root, game: string): int =
  let nums = savePointNumbers(root, game)
  if nums.len == 0: 1 else: nums[^1] + 1

# --- the stamp ---------------------------------------------------------------

proc fnv(h: var uint64, s: string) =
  for c in s:
    h = (h xor uint64(ord(c))) * 1099511628211'u64

proc gameFiles(root, game: string): seq[string] =
  ## Paths (relative to the game's repository, `/` form, sorted) of the files
  ## `git add` of the game would take; without git, every file under the game.
  let repo = repoDir(root, game)
  let r = git(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
              "--", gameSpec(root, game))
  if r.exitCode == 0:
    for p in r.output.split('\0'):
      if p.len > 0 and fileExists(repo / p): result.add p
  else:
    for p in walkDirRec(gameDirOf(root, game), yieldFilter = {pcFile}):
      result.add p.relativePath(repo).replace('\\', '/')
  result.sort()

proc gameDigest*(root, game: string): string =
  var h = 14695981039346656037'u64
  let repo = repoDir(root, game)
  let head = headSha(repo)
  fnv(h, $head.len & ":" & head)
  for p in gameFiles(root, game):
    let body = readFile(repo / p)
    fnv(h, $p.len & ":" & p & $body.len & ":")
    fnv(h, body)
  toHex(cast[int64](h), 16).toLowerAscii

proc stampFile*(root, game: string): string =
  root / "tmp" / "check" / (game & ".stamp")

proc writeStamp*(root, game, digest: string) =
  createDir(stampFile(root, game).parentDir)
  writeFile(stampFile(root, game), digest & "\n")

proc removeStamp*(root, game: string) =
  discard tryRemoveFile(stampFile(root, game))

proc checksJustPassed*(root, game: string): bool =
  ## The stamp exists and still matches the game as it is now.
  let f = stampFile(root, game)
  fileExists(f) and readFile(f).strip == gameDigest(root, game)
