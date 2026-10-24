# `para save`: keeps a game's work as a numbered save point (a git commit
# tagged `save-<game>-<n>`) without the producer writing any git. The commit
# goes in the game's own repository (`games/<game>/.git`, made by `para new`);
# a game without one is committed in the repository that contains `games/`
# (see savepoint.nim). It only ever stages the game (`git add -- .` inside its
# repository, or `-- games/<game>/` in the outer one, never -A), and never
# pushes, switches branch, resets, forces or rewrites history.
#
# It refuses, touching nothing, when git is detached, when any file outside
# the game has changes (only possible in the outer repository), or (for a
# save) when `para check` has not passed for the game exactly as it is now
# (the stamp, see savepoint.nim).
#
# `--set-aside` is for work that is not finished (a session that stopped half
# way through a step): it keeps the games/<game> files as they are now as a
# numbered save point that was not checked, then does a `--back` to the save
# point before it. The game is whole again, and the unfinished work is one
# `--back` away. It needs an earlier save point to go back to.
#
# `--back N` does not move anything backwards: it makes a NEW save point whose
# games/<game> is what save point N held, which undoes the later saves while
# every old one stays reachable. Only the game's directory is restored, so a
# change to anything else in the repo is never undone by it.

import std/[strformat, strutils, sequtils]
import art/[clihelpers, toon]
import nimutil
import savepoint

type Run = clihelpers.Run

const saveHelp* = "para save [--game NAME] -m \"what changed\"\n" &
  "para save [--game NAME] --list\n" &
  "para save [--game NAME] --back N --yes\n" &
  "para save [--game NAME] --set-aside\n" &
  "  saves games/<game> as the next numbered save point (a git commit in the game's own repository,\n" &
  "  games/<game>/.git, tagged save-<game>-<n>)\n" &
  "  --game NAME  the game under games/; left out, the only game with a PLAN.md\n" &
  "  -m TEXT      the save point's note, in plain words\n" &
  "  --list       show the save points of the game\n" &
  "  --back N     add a new save point that puts the game back as it was at save point N\n" &
  "               (nothing is deleted; the later save points stay); only with --yes\n" &
  "  --set-aside  keep unfinished work as a save point that was not checked, then put the game back\n" &
  "               as it was at the save point before (nothing is deleted; needs an earlier save point,\n" &
  "               and no passing check)\n" &
  "  refuses, and changes nothing, when git is detached, when a file outside games/<game> has\n" &
  "  changes (a game without its own repository), or when `para check` has not just passed for\n" &
  "  the game as it is now\n" &
  "  never pushes, switches branch, resets or forces\n"

const maxListed = 10

proc refuse(lines: varargs[string]): Run =
  ## A refusal: exit 1 (the command found something that stops it), and
  ## nothing has been changed.
  result.output = lines.join("\n") & "\n"
  result.code = 1

proc failedGit(what: string, r: ProcResult): Run =
  if gitMissing(r):
    return refuse("error: git is not installed, or is not on the PATH",
                  "Nothing was saved.")
  result.output = &"error: {what} failed\n" & lastLines(r.output, 10)
  result.code = 1

proc preflight(root, game: string): Run =
  ## The refusals both a save and a go-back share: not a git copy, detached,
  ## files outside the game changed. Code 0 when none applies.
  let repo = repoDir(root, game)
  var ok: bool
  let changed = changedPaths(repo, ok)
  if not ok:
    let probe = git(repo, "status")
    if gitMissing(probe): return failedGit("looking at the files", probe)
    return refuse("This folder is not a git copy, so there is nowhere to save to.",
                  "Nothing was saved.")
  if isDetached(repo):
    return refuse("Git says this copy is not on a named line of work (detached), so I won't save here.",
                  "Nothing was saved. Ask for help getting back to the main line first.")
  let foreign = outsideGame(root, changed, game)
  if foreign.len > 0:
    var lines = @["There are changes outside games/" & game & " that were not made while building the game:"]
    for p in foreign[0 ..< min(foreign.len, maxListed)]:
      lines.add "  " & p
    if foreign.len > maxListed:
      lines.add &"  ...and {foreign.len - maxListed} more"
    lines.add "Nothing was saved. Look at these first; they are not part of the game."
    return refuse(lines)
  ("", 0)

proc commitAndTag(root, game, message: string): tuple[run: Run, n: int, committed: bool] =
  ## Commits what is staged, then tags it as the next save point.
  let repo = repoDir(root, game)
  let c = git(repo, "commit", "-m", message)
  if c.exitCode != 0:
    var r = failedGit("saving", c)
    if "tell me who you are" in c.output or "Author identity unknown" in c.output:
      r.output.add toonHelp(@["Git needs a name and email once: git config user.name \"Your Name\" and git config user.email you@example.com"])
    return (r, 0, false)
  let n = nextSavePoint(root, game)
  let t = git(repo, "tag", gameTag(game, n))
  if t.exitCode != 0:
    var r = failedGit(&"naming save point {n}", t)
    r.output.add toonHelp(@["The work was saved, but it has no save point number, so `para save --list` will not show it"])
    return (r, 0, true)
  (("", 0), n, true)

proc undoRestore(root, game: string, failed: Run): Run =
  ## A go-back that stopped part way: put games/<game> back as the last save
  ## left it, in the files and in what is staged.
  result = failed
  let r = git(repoDir(root, game), "restore", "--staged", "--worktree", "--source=HEAD", "--", gameSpec(root, game))
  if r.exitCode == 0:
    result.output.add "Nothing was saved, and games/" & game & " is back as it was before.\n"
  else:
    result.output.add "games/" & game & " may be half put back; ask for help before saving anything.\n"

proc savedOutput(game: string, n: int, lead = ""): string =
  result = lead & &"Saved as save point {n}.\n"
  result.add toonHelp(@["Play it: " & playCommand(game)])

proc listSaves(root, game: string): Run =
  let (res, points) = listSavePoints(root, game)
  if res.exitCode != 0: return failedGit("listing the save points", res)
  if points.len == 0:
    return (&"No save points yet for {game}.\n", 0)
  (toonTable("saves", ["point", "saved", "note"],
             points.mapIt(@[$it.n, it.saved, it.note])), 0)

proc goBack(root, game: string, n: int, yes: bool): Run =
  let tag = gameTag(game, n)
  let repo = repoDir(root, game)
  let spec = gameSpec(root, game)
  if git(repo, "rev-parse", "-q", "--verify", "refs/tags/" & tag).exitCode != 0:
    return errorOut(&"there is no save point {n} for {game}", @["Run `para save --list` to see them"])
  let pre = preflight(root, game)
  if pre.code != 0: return pre
  var ok: bool
  if insideGame(root, changedPaths(repo, ok), game).len > 0:
    return refuse(&"There are changes in games/{game} that are not saved yet.",
                  "Going back would lose them. Save them first, then go back.",
                  "Nothing was changed.")
  let diff = git(repo, "diff", "--quiet", tag, "HEAD", "--", spec)
  if diff.exitCode == 0:
    return (&"{game} is already exactly as it was at save point {n}; nothing to undo.\n", 0)
  if diff.exitCode != 1: return failedGit("comparing with the save point", diff)
  if not yes:
    return refuse(&"Going back to save point {n} adds a new save point that undoes everything saved after it.",
                  "Nothing is deleted: the later save points stay, and you could return to any of them.",
                  &"Nothing was changed. To do it, run: para save --game {game} --back {n} --yes")

  # files the game has gained since the save point go; the rest come back
  let added = git(repo, "diff", "--no-renames", "--name-only", "-z", "--diff-filter=A",
                  tag, "HEAD", "--", spec)
  if added.exitCode != 0: return failedGit("comparing with the save point", added)
  let restore = git(repo, "checkout", tag, "--", spec)
  if restore.exitCode != 0:
    return undoRestore(root, game, failedGit(&"putting back save point {n}", restore))
  let gone = added.output.split('\0').filterIt(it.len > 0)
  var i = 0
  while i < gone.len:
    let batch = gone[i ..< min(i + 50, gone.len)]
    let rm = gitArgs(repo, @["rm", "-q", "-f", "--"] & batch)
    if rm.exitCode != 0:
      return undoRestore(root, game, failedGit(&"putting back save point {n}", rm))
    i += 50

  let done = commitAndTag(root, game, &"{game}: went back to save point {n}")
  if done.run.code != 0:
    return if done.committed: done.run else: undoRestore(root, game, done.run)
  removeStamp(root, game)
  (savedOutput(game, done.n, &"{game} is back as it was at save point {n}.\n"), 0)

proc setAside(root, game: string): Run =
  let pre = preflight(root, game)
  if pre.code != 0: return pre
  let repo = repoDir(root, game)
  var ok: bool
  if insideGame(root, changedPaths(repo, ok), game).len == 0:
    return (&"Nothing unsaved in {game}; there is nothing to set aside.\n", 0)
  let earlier = savePointNumbers(root, game)
  if earlier.len == 0:
    return refuse(&"{game} has no earlier save point to go back to, so I won't set the work aside.",
                  "Nothing was changed. Check and save it, or keep working on it.")
  let add = git(repo, "add", "--", gameSpec(root, game))
  if add.exitCode != 0: return failedGit("getting the files ready", add)
  let kept = commitAndTag(root, game, &"{game}: unfinished work set aside (not checked)")
  if kept.run.code != 0:
    var r = kept.run
    r.output.add "The files in games/" & game & " are still there; nothing was lost.\n"
    return r
  let lead = &"The unfinished work in games/{game} is kept as save point {kept.n} (it was not checked and may not run).\n"
  let back = goBack(root, game, earlier[^1], true)
  if back.code != 0:
    return (lead & "But putting the game back failed, so the files are as they were:\n" & back.output, back.code)
  (lead & back.output & &"To get the unfinished work back later: para save --game {game} --back {kept.n} --yes\n", 0)

proc runSaveWith*(args: seq[string], root = ""): Run =
  var requested, message = ""
  var list, yes, hasMessage, aside = false
  var back = 0
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (saveHelp, 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      requested = args[i]
    of "-m", "--message":
      inc i
      if i >= args.len: return errorOut(&"{a} needs the note for the save point", @[])
      message = args[i].strip
      hasMessage = true
    of "--list":
      list = true
    of "--back":
      inc i
      if i >= args.len or args[i].len notin 1..6 or not args[i].allCharsInSet(Digits) or parseInt(args[i]) < 1:
        return errorOut("--back needs a save point number, like --back 3", @["Run `para save --list` to see them"])
      back = parseInt(args[i])
    of "--yes":
      yes = true
    of "--set-aside":
      aside = true
    else:
      return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --game NAME, -m TEXT, --list, --back N, --yes, --set-aside"])
    inc i

  if list and (back > 0 or hasMessage or yes or aside):
    return errorOut("--list stands on its own", @[])
  if aside and (back > 0 or hasMessage or yes):
    return errorOut("--set-aside writes its own note and goes back by itself, so -m, --back and --yes do not go with it", @[])
  if back > 0 and hasMessage:
    return errorOut("--back writes its own note, so -m does not go with it", @[])
  if yes and back == 0:
    return errorOut("--yes only goes with --back", @[])
  if not list and not aside and back == 0 and message.len == 0:
    return errorOut("para save needs a note: -m \"what changed\"", @["Run `para save --help`"])

  var game: string
  let picked = pickGame(root, requested, game)
  if picked.code != 0: return picked

  if list: return listSaves(root, game)
  if aside: return setAside(root, game)
  if back > 0: return goBack(root, game, back, yes)

  let pre = preflight(root, game)
  if pre.code != 0: return pre
  let repo = repoDir(root, game)
  var ok: bool
  if insideGame(root, changedPaths(repo, ok), game).len == 0:
    return (&"Nothing new to save in {game}.\n", 0)
  if not checksJustPassed(root, game):
    return refuse(&"The checks have not passed for {game} as it is now.",
                  "Nothing was saved.",
                  &"Run `para check --game {game}` first, and save once it passes.")
  let add = git(repo, "add", "--", gameSpec(root, game))
  if add.exitCode != 0: return failedGit("getting the files ready", add)
  let done = commitAndTag(root, game, message)
  if done.run.code != 0: return done.run
  removeStamp(root, game)
  (savedOutput(game, done.n), 0)

proc runSave*(args: seq[string]): Run =
  runSaveWith(args)
