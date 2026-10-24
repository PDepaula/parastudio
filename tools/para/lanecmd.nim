# `para lane`: a helper's own copy of a game, so two helpers (a builder and the art helper, or two
# builders on steps that touch different files) can work at once without stepping on each other or
# on the game the friend is playing.
#
# A lane is a git worktree of the game's own repository (`games/<game>/.git`, made by `para new`)
# on the branch `lane/<id>`, checked out next to the game as `games/<game>.<id>/`. It sits at the
# same depth as the game because the game reads the engine by a relative path two folders up
# (`staticRead("../../src/...")`); anywhere else it would not compile. `games/*` is ignored by the
# paraloop checkout, so a lane is as invisible to it as the game is, and a lane's name always has a
# dot, which no game name has (`validGameName`), so nothing mistakes it for a game. The compile
# state of a lane is its own: `config.nims` puts its cache in `.nimcache/<target>/lanes/<lane>/`,
# and `para build --lane` and the nimble test task write its programs to `tmp/lanes/<lane>/`.
#
# Landing keeps `para check` and `para save` the only things that commit on the game's own line:
#   1. in the lane, everything the helper changed is committed (a lane commit, not a save point);
#   2. in the lane, the game's line is merged in, so newer save points meet the helper's work there.
#      A conflict stops here: the merge is aborted (the lane is as it was), the game is untouched,
#      and the files are named;
#   3. in the game, `git merge --squash lane/<id>` puts the lane's net change into the game's files
#      as unsaved changes, with no commit. It cannot conflict after step 2; git itself refuses,
#      before touching anything, when a file it would write has unsaved edits in the game;
#   4. the lane is unlocked and removed, and its branch deleted. If removing fails (a file held
#      open), the lane is marked landed and `para lane clean` finishes later.
# A failed `merge --squash` cannot be aborted (there is no MERGE_HEAD), which is why any conflict
# is found in step 2, in the lane, where `merge --abort` is clean.
#
# Nothing here ever deletes work that is not landed: `drop` and `clean` refuse a lane with edits
# or kept steps the game does not have (`git worktree remove` alone would remove a clean lane whose
# commits are not landed), unless `drop --discard --yes`, after the command has said what would be
# lost. A lane is locked (`git worktree lock`) from `start` until it is landed or dropped, so a stray
# `git worktree remove` or `prune` cannot take it either.
#
# What is not in git lives in `tmp/lanes/<game>.<id>.json`: the helper's role, the ticket, when it
# started and whether it landed. Every proc takes the repo `root` (empty means the working
# directory), so tests drive scratch repos without changing directory.

import std/[os, strutils, strformat, json, times, algorithm, sequtils]
import art/[clihelpers, toon]
import nimutil
import savepoint

type Run = clihelpers.Run

const
  laneRoles* = ["builder", "art"]
  maxTicket = 100
  maxLanesPerRole = 9
  laneHelp* = "para lane start <game> --for builder|art [--ticket TEXT]\n" &
    "para lane list [--game NAME]\n" &
    "para lane land <game> <id>\n" &
    "para lane drop <game> <id> [--discard --yes]\n" &
    "para lane clean [--game NAME]\n" &
    "  a lane is a helper's own copy of a game: games/<game>.<id>/, a git worktree of the game's own repository\n" &
    "  on the branch lane/<id>, so helpers can work at once without touching the game or each other\n" &
    "  start  makes one for a helper (the builder gets builder, then builder2, ...; the art helper art) and prints\n" &
    "         its id and folder; a game with no commit yet first gets one (\"<game>: new game\", not a save point)\n" &
    "  list   one row per lane: game, id, role, ticket, files changed, kept steps, state\n" &
    "  land   keeps the helper's work in the lane, brings the game's newer save points into it, then puts the\n" &
    "         result into games/<game> as unsaved changes (then `para check`, then `para save`) and removes the\n" &
    "         lane; refuses, changing nothing in the game, when the helper and the game changed the same lines,\n" &
    "         or when a file the helper changed has unsaved edits in the game\n" &
    "  drop   removes a lane; refuses while it holds work that is not landed, unless --discard --yes\n" &
    "  clean  removes lanes already landed and forgets lane folders deleted by hand\n" &
    "  never commits on the game's own line, pushes, resets or forces\n"

type
  LaneInfo* = object
    game*, id*, role*, ticket*, started*: string
    folder*: bool          ## games/<game>.<id>/ is there
    branch*: bool          ## lane/<id> is in the game's repository
    locked*: bool
    landed*: bool          ## landed already; only the removal is left
    known*: bool           ## git could say what is in it
    edited*: seq[string]   ## files with edits not yet kept in the lane
    kept*: seq[string]     ## files the lane's kept steps change that the game's line does not have yet
    steps*: int            ## commits in the lane the game's line does not have (merges not counted)

proc refuse(lines: varargs[string]): Run =
  ## A refusal: exit 1, and nothing in the game has been changed.
  result.output = lines.join("\n") & "\n"
  result.code = 1

proc oneLine(s: string, cap: int): string =
  for c in s:
    if c >= ' ' and c != '\x7f': result.add c
  result = result.strip
  if result.len > cap: result = result[0 ..< cap].strip

proc roleOf*(id: string): string =
  ## `builder2` -> `builder`.
  var n = id.len
  while n > 0 and id[n - 1] in Digits: dec n
  id[0 ..< n]

proc roleWords*(role: string): string =
  case role
  of "builder": "the builder"
  of "art": "the art helper"
  else: "a helper"

# --- the record in tmp/lanes --------------------------------------------------------

proc metaFile*(root, game, id: string): string =
  root / "tmp" / "lanes" / (laneName(game, id) & ".json")

proc laneOutDir*(root, game, id: string): string =
  ## Where a lane's compiled programs go (`para build --lane`, the nimble test task).
  root / "tmp" / "lanes" / laneName(game, id)

proc readMeta(root, game, id: string): JsonNode =
  try:
    let f = metaFile(root, game, id)
    if fileExists(f):
      let j = parseJson(readFile(f))
      if j.kind == JObject: return j
  except CatchableError: discard
  newJObject()

proc writeMeta(root, game, id: string, j: JsonNode) =
  let f = metaFile(root, game, id)
  createDir(f.parentDir)
  writeFile(f, j.pretty & "\n")

proc str(j: JsonNode, key: string): string =
  if j.hasKey(key) and j[key].kind == JString: j[key].getStr else: ""

# --- asking git -----------------------------------------------------------------------

proc ask(quick: bool, dir: string, args: varargs[string]): ProcResult =
  if quick: gitQuick(dir, args) else: git(dir, args)

proc lines(r: ProcResult, sep = '\n'): seq[string] =
  if r.exitCode != 0: return
  for l in r.output.split(sep):
    if l.strip.len > 0: result.add l.strip(leading = false, chars = {'\n', '\r'})

proc mainBranch(repo: string, quick = false): string =
  ## The game's own line of work (normally `main`), or "" when git is detached or cannot say.
  let r = ask(quick, repo, "symbolic-ref", "--short", "-q", "HEAD")
  if r.exitCode == 0: r.output.strip else: ""

proc branchExists(repo, id: string, quick = false): bool =
  ask(quick, repo, "rev-parse", "--verify", "-q", "refs/heads/" & laneBranch(id)).exitCode == 0

type Worktree = object
  path, branch: string
  locked: bool

proc worktrees(repo: string, quick = false): seq[Worktree] =
  ## `git worktree list --porcelain`: one block per worktree, blank-line separated.
  let r = ask(quick, repo, "worktree", "list", "--porcelain")
  if r.exitCode != 0: return
  var cur: Worktree
  for raw in r.output.splitLines & @[""]:
    let l = raw.strip(leading = false)
    if l.len == 0:
      if cur.path.len > 0: result.add cur
      cur = Worktree()
    elif l.startsWith("worktree "): cur.path = l[9 .. ^1]
    elif l.startsWith("branch refs/heads/"): cur.branch = l[18 .. ^1]
    elif l == "locked" or l.startsWith("locked "): cur.locked = true

proc laneIds(root, game: string, quick = false): seq[string] =
  ## Every lane of the game: a `lane/<id>` branch, a record in tmp/lanes, or a `<game>.<id>` folder.
  let repo = gameDirOf(root, game)
  for b in ask(quick, repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/lane/").lines:
    let id = b.strip
    if id.startsWith("lane/") and validLaneId(id[5 .. ^1]): result.add id[5 .. ^1]
  let metaDir = root / "tmp" / "lanes"
  if dirExists(metaDir):
    for kind, path in walkDir(metaDir):
      let name = path.extractFilename
      if kind == pcFile and name.startsWith(game & ".") and name.endsWith(".json"):
        let id = name[game.len + 1 ..< name.len - 5]
        if validLaneId(id): result.add id
  let base = root / gamesDir
  if dirExists(base):
    for kind, path in walkDir(base):
      let name = path.extractFilename
      if kind == pcDir and name.startsWith(game & ".") and validLaneId(name[game.len + 1 .. ^1]) and
         (fileExists(path / ".git") or dirExists(path / ".git")):
        result.add name[game.len + 1 .. ^1]
  result = result.deduplicate
  result.sort()

proc laneInfo*(root, game, id: string, quick = false): LaneInfo =
  let repo = gameDirOf(root, game)
  let dir = laneDir(root, game, id)
  let meta = readMeta(root, game, id)
  result = LaneInfo(game: game, id: id, ticket: meta.str("ticket"), started: meta.str("started"),
                    landed: meta.hasKey("landed") and meta["landed"].kind == JBool and meta["landed"].getBool)
  result.role = meta.str("role")
  if result.role.len == 0: result.role = roleOf(id)
  result.folder = dirExists(dir)
  result.branch = branchExists(repo, id, quick)
  for w in worktrees(repo, quick):
    if w.branch == laneBranch(id): result.locked = w.locked
  let main = mainBranch(repo, quick)
  if main.len == 0: return
  result.known = true
  if result.folder:
    let st = ask(quick, dir, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")
    if st.exitCode != 0: result.known = false
    for entry in st.output.split('\0'):
      if st.exitCode == 0 and entry.len > 3: result.edited.add entry[3 .. ^1]
  if result.branch:
    let lane = laneBranch(id)
    # the files the lane changed since it forked whose content the game's line does not have yet
    let since = ask(quick, repo, "diff", "--name-only", "-z", "--no-renames", main & "..." & lane)
    let differ = ask(quick, repo, "diff", "--name-only", "-z", "--no-renames", main, lane)
    if since.exitCode != 0 or differ.exitCode != 0: result.known = false
    let now = differ.lines('\0')
    for f in since.lines('\0'):
      if f in now: result.kept.add f
    let count = ask(quick, repo, "rev-list", "--count", "--no-merges", main & ".." & lane)
    if count.exitCode == 0:
      try: result.steps = parseInt(count.output.strip)
      except ValueError: discard

proc hasWork*(l: LaneInfo): bool =
  ## Something in the lane the game does not have: edits not kept yet, or kept steps not landed.
  ## A lane git could not read counts as holding work, so nothing removes it.
  not l.known or l.edited.len > 0 or (l.kept.len > 0 and not l.landed)

proc changedFiles*(l: LaneInfo): seq[string] =
  ## Every file the lane changes, kept or not, sorted.
  result = (l.kept & l.edited).deduplicate
  result.sort()

proc lanesOf*(root, game: string, quick = false): seq[LaneInfo] =
  ## Every lane of one game, by id. Nothing for a game that is not a repository of its own.
  if not validGameName(game) or not ownRepo(root, game): return
  for id in laneIds(root, game, quick):
    result.add laneInfo(root, game, id, quick)

proc allLanes*(root: string, quick = false): seq[LaneInfo] =
  let base = root / gamesDir
  if not dirExists(base): return
  var games: seq[string]
  for kind, path in walkDir(base):
    let name = path.extractFilename
    if kind == pcDir and validGameName(name): games.add name
  games.sort()
  for g in games: result.add lanesOf(root, g, quick)

# --- the steps ------------------------------------------------------------------------

proc identityHelp(r: ProcResult): seq[string] =
  if "tell me who you are" in r.output or "Author identity unknown" in r.output:
    @["Git needs a name and email once: git config user.name \"Your Name\" and git config user.email you@example.com"]
  else: @[]

proc gitFailed(what: string, r: ProcResult): Run =
  if gitMissing(r):
    return refuse("error: git is not installed, or is not on the PATH", "Nothing was changed in the game.")
  result.output = &"error: {what} failed\n" & lastLines(r.output, 10) & toonHelp(identityHelp(r))
  result.code = 1

proc plural(n: int, word: string): string =
  $n & " " & word & (if n == 1: "" else: "s")

proc namesList(files: seq[string], cap = 5): string =
  result = files[0 ..< min(files.len, cap)].join(", ")
  if files.len > cap: result.add &", and {files.len - cap} more"

proc gameChecks(root, game: string, main: var string): Run =
  ## The refusals every lane command shares: no such game, no repository of its own, detached.
  if not validGameName(game) or not dirExists(gameDirOf(root, game)):
    return errorOut(&"there is no game called \"{game}\" in {gamesDir}/", @[])
  if not ownRepo(root, game):
    return refuse(&"{game} has no git repository of its own (a game made by `para new` has one), so it cannot have lanes.",
                  "Nothing was changed.")
  let repo = gameDirOf(root, game)
  let probe = git(repo, "status", "--porcelain")
  if gitMissing(probe): return gitFailed("looking at the game", probe)
  main = mainBranch(repo)
  if main.len == 0:
    return refuse("Git says the game is not on a named line of work (detached), so I won't make or land a lane.",
                  "Nothing was changed. Ask for help getting back to the main line first.")
  ("", 0)

proc removeLane(root, game, id: string, force: bool): tuple[ok: bool, why: string] =
  ## Unlock, remove the worktree, delete the branch and the record. The caller has already made
  ## sure nothing in it is lost.
  let repo = gameDirOf(root, game)
  let dir = absolutePath(laneDir(root, game, id))
  if dirExists(dir):
    discard git(repo, "worktree", "unlock", dir)
    let r = if force: git(repo, "worktree", "remove", "--force", "--force", dir)
            else: git(repo, "worktree", "remove", dir)
    if r.exitCode != 0:
      discard git(repo, "worktree", "lock", "--reason", "landed, removal pending", dir)
      return (false, lastLines(r.output, 3).strip)
  else:
    discard git(repo, "worktree", "unlock", dir)
    discard git(repo, "worktree", "prune")
  if branchExists(repo, id):
    let b = git(repo, "branch", "-D", laneBranch(id))
    if b.exitCode != 0: return (false, lastLines(b.output, 3).strip)
  discard tryRemoveFile(metaFile(root, game, id))
  (true, "")

proc startLane(root, game, role, ticket: string): Run =
  var main: string
  let ok = gameChecks(root, game, main)
  if ok.code != 0: return ok
  let repo = gameDirOf(root, game)
  # a game `para new` just made has no commit yet, and a worktree of it would be an empty orphan
  if headSha(repo).len == 0:
    discard git(repo, "add", "-A")
    let c = git(repo, "commit", "-q", "-m", game & ": new game")
    if c.exitCode != 0: return gitFailed("keeping the game's first version", c)
  let taken = laneIds(root, game)
  var id = ""
  for n in 1 .. maxLanesPerRole:
    let candidate = if n == 1: role else: role & $n
    if candidate in taken or dirExists(laneDir(root, game, candidate)) or branchExists(repo, candidate):
      continue
    let dir = absolutePath(laneDir(root, game, candidate))
    let add = git(repo, "worktree", "add", "-q", "-b", laneBranch(candidate), dir, main)
    if add.exitCode == 0:
      id = candidate
      break
    if gitMissing(add) or not (dirExists(dir) or branchExists(repo, candidate)):
      return gitFailed("making the helper's lane", add)
  if id.len == 0:
    return refuse(&"{game} already has {maxLanesPerRole} lanes for {roleWords(role)}. Land or drop some first.",
                  "Nothing was changed.")
  let dir = absolutePath(laneDir(root, game, id))
  discard git(repo, "worktree", "lock", "--reason", "helper " & role & " working", dir)
  writeMeta(root, game, id, %*{"role": role, "ticket": ticket, "base": headSha(repo),
                               "started": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")})
  let prefix = lanePrefix(game, id)
  result.output = &"lane: {id}\nfolder: {prefix}\nrole: {role}\n"
  if ticket.len > 0: result.output.add "ticket: " & toonCell(ticket) & "\n"
  result.output.add toonHelp(@[
    &"The helper edits only files under {prefix} and runs `para test --filter {prefix} --skip-balance` and `para build --game {game} --lane {id}`",
    &"When it is back: `para lane land {game} {id}`, then `para check --game {game}` and `para save --game {game} -m \"...\"`"])

proc landLane(root, game, id: string): Run =
  var main: string
  let ok = gameChecks(root, game, main)
  if ok.code != 0: return ok
  if not validLaneId(id): return errorOut(&"\"{id}\" is not a lane id", @["List them with `para lane list --game " & game & "`"])
  let repo = gameDirOf(root, game)
  let lane = laneBranch(id)
  let dir = absolutePath(laneDir(root, game, id))
  let meta = readMeta(root, game, id)
  if not branchExists(repo, id):
    if dirExists(dir) or fileExists(metaFile(root, game, id)):
      return refuse(&"The lane {id} of {game} has lost its branch ({lane}), so there is nothing git can land.",
                    "Nothing was changed. Ask for help.")
    return errorOut(&"{game} has no lane called \"{id}\"", @["List them with `para lane list --game " & game & "`"])
  if not dirExists(dir):
    # the folder was deleted by hand: its kept steps are still on the branch, so check it out again
    discard git(repo, "worktree", "unlock", dir)
    discard git(repo, "worktree", "prune")
    let add = git(repo, "worktree", "add", "-q", dir, lane)
    if add.exitCode != 0: return gitFailed("getting the lane's folder back", add)
  # 1. keep everything the helper changed, as a commit in the lane
  let added = git(dir, "add", "-A")
  if added.exitCode != 0: return gitFailed("looking at the helper's files", added)
  if git(dir, "diff", "--cached", "--quiet").exitCode != 0:
    let ticket = meta.str("ticket")
    let c = git(dir, "commit", "-q", "-m",
                &"{game}: " & (if ticket.len > 0: ticket else: "helper work") & &" (lane {id})")
    if c.exitCode != 0: return gitFailed("keeping the helper's work in its lane", c)
  var info = laneInfo(root, game, id)
  if info.kept.len == 0:
    let removed = removeLane(root, game, id, force = false)
    result.output = &"lane {id}: nothing to land ({roleWords(info.role)} changed nothing the game does not have)\n"
    if not removed.ok:
      result.output.add &"the lane could not be removed yet ({removed.why}); `para lane clean` removes it later\n"
    return
  # 2. bring the game's newer save points into the lane; a conflict stops here, in the lane
  let merged = git(dir, "merge", "--no-edit", "-q", main)
  if merged.exitCode != 0:
    let both = git(dir, "diff", "--name-only", "--diff-filter=U").lines
    if git(dir, "rev-parse", "-q", "--verify", "MERGE_HEAD").exitCode == 0:
      discard git(dir, "merge", "--abort")
    if both.len > 0:
      return refuse(
        &"The helper and the game both changed {namesList(both)} since the helper started, in ways git cannot put together.",
        &"The helper's work is kept in its lane ({id}); nothing in the game was changed.",
        toonHelp(@["Save what is in the game, then start a fresh lane for this step (the helper can read this one's files in " &
                   lanePrefix(game, id) & "), and drop this one once that has landed: `para lane drop " & game & " " & id &
                   " --discard --yes` (that loses its work)"]).strip)
    return gitFailed("bringing the game's save points into the lane", merged)
  # 3. put the lane's net change into the game's files, unsaved; git refuses before touching anything
  let squash = git(repo, "merge", "--squash", lane)
  if squash.exitCode != 0:
    if "would be overwritten" in squash.output:
      var files: seq[string]
      for l in squash.output.splitLines:
        if l.startsWith("\t"): files.add l.strip
      return refuse(
        &"These files have changes in the game that are not saved yet, and the helper changed them too: {namesList(files)}.",
        &"Nothing was changed: the helper's work is kept in its lane ({id}).",
        toonHelp(@["Check and save the game first (`para check --game " & game & "`, then `para save --game " & game &
                   " -m \"...\"`), then land again"]).strip)
    return gitFailed("putting the helper's work into the game", squash)
  # 4. the work is in the game now: remove the lane, or mark it landed so `clean` finishes later
  info = laneInfo(root, game, id)
  let changed = info.kept
  meta["landed"] = %true
  writeMeta(root, game, id, meta)
  let verified = changed.len == 0 or git(repo, @["diff", "--quiet", lane, "--"] & changed).exitCode == 0
  let removed = if verified: removeLane(root, game, id, force = false) else: (false, "the game's files do not match the lane")
  result.output = &"landed: {id} ({roleWords(info.role)}), {plural(changed.len, \"file\")} now unsaved in {gamePrefix(game)}: {namesList(changed)}\n"
  if not removed.ok:
    result.output.add &"the lane is kept for now ({removed.why}); `para lane clean --game {game}` removes it later\n"
  result.output.add toonHelp(@[&"Run `para check --game {game}`, then `para save --game {game} -m \"what changed\"` to keep it as a save point"])

proc dropLane(root, game, id: string, discardWork, yes: bool): Run =
  var main: string
  let ok = gameChecks(root, game, main)
  if ok.code != 0: return ok
  if not validLaneId(id) or id notin laneIds(root, game):
    return errorOut(&"{game} has no lane called \"{id}\"", @["List them with `para lane list --game " & game & "`"])
  let info = laneInfo(root, game, id)
  if info.hasWork:
    let what = if not info.known: "work git could not read just now"
               else: "work that is not landed: " & plural(changedFiles(info).len, "file") & " (" & namesList(changedFiles(info)) & ")"
    if not (discardWork and yes):
      return refuse(&"The lane {id} of {game} holds {what}.",
        "Nothing was removed.",
        toonHelp(@[&"Land it with `para lane land {game} {id}`, or remove it and lose that work with `para lane drop {game} {id} --discard --yes`"]).strip)
  let removed = removeLane(root, game, id, force = discardWork and yes)
  if not removed.ok:
    return refuse(&"The lane {id} of {game} could not be removed: {removed.why}",
                  "Close anything that has a file open in it, then try again.")
  result.output = &"dropped: {id} of {game}" & (if info.hasWork: " (its work is gone, as asked)" else: "") & "\n"

proc cleanLanes(root: string, onlyGame: string): Run =
  var games: seq[string]
  if onlyGame.len > 0:
    if not validGameName(onlyGame) or not dirExists(gameDirOf(root, onlyGame)):
      return errorOut(&"there is no game called \"{onlyGame}\" in {gamesDir}/", @[])
    games = @[onlyGame]
  else:
    let base = root / gamesDir
    if dirExists(base):
      for kind, path in walkDir(base):
        if kind == pcDir and validGameName(path.extractFilename): games.add path.extractFilename
    games.sort()
  var rows: seq[seq[string]]
  for game in games:
    if not ownRepo(root, game): continue
    let repo = gameDirOf(root, game)
    # a lane folder deleted by hand: forget the worktree (unlocked first: git never prunes a locked one)
    for w in worktrees(repo):
      if w.branch.startsWith("lane/") and not dirExists(w.path):
        discard git(repo, "worktree", "unlock", w.path)
    discard git(repo, "worktree", "prune")
    for info in lanesOf(root, game):
      if info.landed and info.known and info.edited.len == 0:
        let removed = removeLane(root, game, info.id, force = false)
        rows.add @[game, info.id, if removed.ok: "removed (landed)" else: "kept: " & removed.why]
      elif not info.folder and info.known and not info.hasWork:
        let removed = removeLane(root, game, info.id, force = false)
        rows.add @[game, info.id, if removed.ok: "removed (folder gone, nothing in it)" else: "kept: " & removed.why]
      elif not info.folder and info.branch:
        rows.add @[game, info.id, "folder gone; " & plural(info.kept.len, "file") & " not landed kept: land or drop it"]
  if rows.len == 0:
    result.output = "clean: nothing to do\n"
  else:
    result.output = toonTable("lanes", ["game", "id", "result"], rows)

proc stateWords*(l: LaneInfo): string =
  if l.landed: "landed, removal pending"
  elif not l.folder: "folder gone"
  elif not l.known: "unknown"
  elif l.hasWork: "has work"
  else: "empty"

proc listLanes(root, onlyGame: string): Run =
  var lanes: seq[LaneInfo]
  if onlyGame.len > 0:
    if not validGameName(onlyGame) or not dirExists(gameDirOf(root, onlyGame)):
      return errorOut(&"there is no game called \"{onlyGame}\" in {gamesDir}/", @[])
    lanes = lanesOf(root, onlyGame)
  else:
    lanes = allLanes(root)
  var rows: seq[seq[string]]
  for l in lanes:
    rows.add @[l.game, l.id, l.role, l.ticket, $changedFiles(l).len, $l.steps, stateWords(l)]
  result.output = toonTable("lanes", ["game", "id", "role", "ticket", "files", "steps", "state"], rows)
  if lanes.len > 0:
    result.output.add toonHelp(@["Land one with `para lane land <game> <id>`; folders are games/<game>.<id>/"])

# --- the command ----------------------------------------------------------------------

proc runLaneIn*(root: string, args: seq[string]): Run =
  if args.len == 0 or args[0] in ["--help", "-h"]:
    return (laneHelp, 0)
  let sub = args[0]
  var positional: seq[string]
  var role, ticket, gameFlag: string
  var discardWork, yes = false
  var i = 1
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h": return (laneHelp, 0)
    of "--for":
      inc i
      if i >= args.len: return errorOut("--for needs a role", @["Valid roles: " & laneRoles.join(", ")])
      role = args[i]
    of "--ticket":
      inc i
      if i >= args.len: return errorOut("--ticket needs the step in a few words", @[])
      ticket = oneLine(args[i], maxTicket)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      gameFlag = args[i]
    of "--discard": discardWork = true
    of "--yes": yes = true
    else:
      if a.startsWith("-"):
        return errorOut(&"unknown flag \"{a}\"", @["Run `para lane --help` for the flags of each lane command"])
      positional.add a
    inc i
  case sub
  of "start":
    if positional.len != 1: return errorOut("para lane start needs the game", @["para lane start <game> --for builder|art"])
    if role notin laneRoles: return errorOut("para lane start needs --for builder or --for art", @["Valid roles: " & laneRoles.join(", ")])
    startLane(root, positional[0], role, ticket)
  of "list":
    if positional.len > 0: return errorOut("para lane list takes no names; use --game NAME", @[])
    listLanes(root, gameFlag)
  of "land":
    if positional.len != 2: return errorOut("para lane land needs the game and the lane id", @["para lane land <game> <id>"])
    landLane(root, positional[0], positional[1])
  of "drop":
    if positional.len != 2: return errorOut("para lane drop needs the game and the lane id", @["para lane drop <game> <id> [--discard --yes]"])
    if yes and not discardWork: return errorOut("--yes goes with --discard", @["para lane drop <game> <id> --discard --yes"])
    dropLane(root, positional[0], positional[1], discardWork, yes)
  of "clean":
    if positional.len > 0: return errorOut("para lane clean takes no names; use --game NAME", @[])
    cleanLanes(root, gameFlag)
  else:
    errorOut(&"unknown command \"lane {sub}\"", @["Valid commands: lane start, lane list, lane land, lane drop, lane clean"])

proc runLane*(args: seq[string]): Run =
  runLaneIn("", args)
