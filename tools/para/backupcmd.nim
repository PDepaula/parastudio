# `para backup`: puts a copy of a friend's saved work in their OWN private
# online repository, and nowhere else. Uploading is outward-facing, so this
# command is built to refuse rather than guess:
#
# - it works on the game's own repository (`games/<game>/.git`, see
#   savepoint.nim); a game without one is part of the repository that contains
#   `games/`, and that one is used instead;
# - it only ever pushes to the git remote named `backup`, never to `origin` or
#   any other remote, and refuses when `backup` points at the same repository
#   as another remote of this copy or at the Para Studio upstream (`upstreamRepo`);
# - it refuses an http:// or https:// remote address with anything before the
#   host (`user@`, `user:password@`, `token@`): a login in the address is kept in
#   plain text in the repo's config, and belongs in the friend's own
#   `gh auth login` or git credential manager. ssh addresses (`git@host:path`,
#   `ssh://git@host/path`) carry no secret and are accepted;
# - it needs `--yes`, which the producer passes only after the friend said yes
#   to that upload; without it the command only explains what would go where;
# - the repository must be private: with `gh` installed and a github.com
#   address, `gh repo view` has to say so (public, or no answer, stops it);
#   without `gh`, or for another host, `gh` cannot check, so the friend has to
#   have seen "Private" on the repository's page, and the producer passes
#   `--is-private` for them;
# - it pushes the current branch and the `save-*` tags, nothing else, never
#   with force, and never sets an upstream. Nothing here runs by itself: no
#   hook calls it.
#
# `gh` is a parameter so tests drive a fake one; `root` is the paraloop checkout
# (empty means the working directory).

import std/[os, strutils, strformat, sequtils]
import art/[clihelpers, toon]
import nimutil
import savepoint

type Run = clihelpers.Run

const
  backupRemote* = "backup"
  upstreamRepo* = "pdepaula/parastudio" ## lowercase `owner/repo` of the engine's own repository
  ghHost = "github.com" # the only host `gh repo view` can be asked about
  ghTimeoutMs = 30_000
  pushTimeoutMs = 300_000

const backupHelp* = "para backup [--game NAME]\n" &
  "para backup [--game NAME] --push --yes [--is-private]\n" &
  "  with no flags: says whether the game has a private online backup set up (changes nothing)\n" &
  "  --game NAME  the game under games/; left out, the only game with a PLAN.md. The backup is of that\n" &
  "               game's own git repository (games/<game>/.git)\n" &
  "  --push       upload the current branch and its save points to the git remote named \"backup\"\n" &
  "  --yes        the friend said yes to that upload; without it nothing is uploaded and the command explains\n" &
  "  --is-private the friend saw \"Private\" on the repository's page (only needed when `gh` cannot say)\n" &
  "  refuses unless the repository is private, when \"backup\" points at origin, another remote or the\n" &
  "  Para Studio upstream, or when its http/https address has a login, password or token in it; never forces, never pushes to origin\n"

proc refuse(lines: varargs[string]): Run =
  ## A refusal: exit 1, and nothing has been uploaded or changed.
  result.output = lines.join("\n") & "\n"
  result.code = 1

# --- addresses ----------------------------------------------------------------

proc schemeEnd(u: string): int =
  ## Where the address starts after `scheme://`, or 0 when it has no scheme.
  let i = u.find("://")
  if i > 0: i + 3 else: 0

proc withoutUserinfo(rest: string): string =
  ## `user:pw@host/path` -> `host/path` (only before the first `/`).
  let slash = rest.find('/')
  let hostPart = if slash < 0: rest else: rest[0 ..< slash]
  let at = hostPart.rfind('@')
  if at < 0: rest else: rest[at + 1 .. ^1]

proc normUrl*(url: string): string =
  ## One spelling for "the same repository": lowercase, no scheme, no login,
  ## `host:owner/repo` written as `host/owner/repo`, no trailing `/` or `.git`.
  var u = url.strip().toLowerAscii().replace('\\', '/')
  let start = schemeEnd(u)
  let hasScheme = start > 0
  u = withoutUserinfo(u[start .. ^1])
  if not hasScheme:
    let colon = u.find(':')
    let slash = u.find('/')
    if colon > 0 and (slash < 0 or colon < slash): u[colon] = '/'
  while u.endsWith("/"): u.setLen(u.len - 1)
  if u.endsWith(".git"): u.setLen(u.len - 4)
  u

proc hostOf*(url: string): string =
  let n = normUrl(url)
  let slash = n.find('/')
  if slash < 0: n else: n[0 ..< slash]

proc hasCredentials*(url: string): bool =
  ## An http:// or https:// address with anything before the host:
  ## `https://user@host/..`, `https://user:pw@host/..`, `https://token@host/..`.
  let u = url.strip()
  let lower = u.toLowerAscii()
  if not (lower.startsWith("http://") or lower.startsWith("https://")): return false
  let rest = u[schemeEnd(u) .. ^1]
  let slash = rest.find('/')
  let hostPart = if slash < 0: rest else: rest[0 ..< slash]
  '@' in hostPart

proc shown*(url: string): string =
  ## The address as it may be printed: the login part left out.
  let u = url.strip()
  let start = schemeEnd(u)
  if start > 0: u[0 ..< start] & withoutUserinfo(u[start .. ^1]) else: u

proc urlProblem*(backupUrls, otherUrls: seq[string]): string =
  ## Why the `backup` remote's address(es) must not be pushed to, or "".
  if backupUrls.len == 0: return "the \"backup\" remote has no address"
  let others = otherUrls.mapIt(normUrl(it))
  for u in backupUrls:
    if hasCredentials(u):
      return "the http/https address of the \"backup\" remote has a login, password or token in it; log in with `gh auth login` (or the git credential manager) yourself and use the plain address"
    let n = normUrl(u)
    if n.len == 0: return "the \"backup\" remote has an empty address"
    if n in others:
      return "the \"backup\" remote points at the same repository as another remote of this copy (" & shown(u) & ")"
    let parts = n.split('/')
    if parts.len >= 2 and parts[^2] & "/" & parts[^1] == upstreamRepo:
      return "the \"backup\" remote points at the Para Studio project itself (" & shown(u) & "), not at a repository of your own"
  ""

# --- the pieces that ask git and gh -------------------------------------------

proc remoteNames(repo: string): seq[string] =
  let r = git(repo, "remote")
  if r.exitCode == 0:
    for l in r.output.splitLines:
      if l.strip.len > 0: result.add l.strip

proc remoteUrls(repo, name: string): seq[string] =
  ## The fetch and push address(es) of a remote (git applies `insteadOf` and
  ## `pushurl` here), without repeats.
  for flags in [@["--all"], @["--push", "--all"]]:
    let r = git(repo, @["remote", "get-url"] & flags & @[name])
    if r.exitCode == 0:
      for l in r.output.splitLines:
        let u = l.strip
        if u.len > 0 and u notin result: result.add u

type Privacy = enum
  privateYes, privatePublic, privateUnknown, cannotCheck

proc ghPrivacy(gh, url: string): Privacy =
  ## What `gh` says about the repository: private, public, no answer (not
  ## logged in, no access, a network problem), or `cannotCheck` (no `gh`
  ## here, or the address is not on github.com).
  if hostOf(url) != ghHost or gh.len == 0 or (findExe(gh).len == 0 and not fileExists(gh)):
    return cannotCheck
  let r = runCaptured(gh, @["repo", "view", url, "--json", "isPrivate", "--jq", ".isPrivate"],
                      timeoutMs = ghTimeoutMs)
  if r.exitCode == 127: return cannotCheck
  if r.exitCode != 0: return privateUnknown
  case r.output.strip
  of "true": privateYes
  of "false": privatePublic
  else: privateUnknown

proc currentBranch(repo: string): string =
  let r = git(repo, "symbolic-ref", "--short", "-q", "HEAD")
  if r.exitCode == 0: r.output.strip else: ""

proc setupSteps(gh, source: string): seq[string] =
  ## The plain steps for making the friend's own private repository. `source`
  ## is the folder of the repository to back up, as seen from the paraloop
  ## checkout ("." for the checkout itself).
  let gitIn = if source == ".": "git" else: "git -C " & source
  if gh.len > 0 and findExe(gh).len > 0:
    @["With gh installed (log in yourself first: `gh auth login`): gh repo create <a-name> --private --source " & source & " --remote " & backupRemote,
      "Or on the website: make a new PRIVATE repository, then: " & gitIn & " remote add " & backupRemote & " <its address>"]
  else:
    @["On the website (GitHub, GitLab, ...) make a new repository, empty, set to PRIVATE",
      "Copy its address, then" & (if source == ".": " in this folder" else: "") & ": " & gitIn & " remote add " & backupRemote & " <its address>",
      "Logging in is yours to do when git asks; I never ask for or handle passwords or tokens"]

proc sourceOf(root, game: string): string =
  ## The repository's folder for the friend to point git at.
  if game.len > 0 and ownRepo(root, game): gamesDir & "/" & game else: "."

proc backupRepo(root, requested: string, game: var string): Run =
  ## Which game's repository is backed up. `--game NAME` when given, else the
  ## only game with a PLAN.md; with none (or several, none of them a repository
  ## of its own) the repository that contains `games/` itself, as before games
  ## had their own.
  if requested.len > 0:
    return pickGame(root, requested, game)
  let plans = gamesWithPlan(root)
  if plans.len == 1:
    game = plans[0]
  elif plans.len > 1 and plans.anyIt(ownRepo(root, it)):
    return errorOut("more than one game has a " & planFile & ": " & plans.join(", "),
                    @["Say which one with --game <name>"])
  ("", 0)

# --- the commands -------------------------------------------------------------

type BackupFacts* = object
  ## What `para backup` (no flags) knows, for a page that shows it: the pieces of the status text.
  game*: string ## the game whose repository this is, "" for the repository that contains games/
  own*: bool ## that repository is the game's own (games/<game>/.git)
  setUp*: bool ## a remote named "backup" exists
  url*: string ## its address, login left out
  branch*: string ## the current branch, "" when git is detached
  problem*: string ## why it must not be uploaded to, "" when nothing stands in the way
  steps*: seq[string] ## how to set one up (only when `setUp` is false)

proc backupFacts*(root: string, game = "", gh = "gh"): BackupFacts =
  ## `game` "" asks the repository that contains `games/`.
  let repo = if game.len > 0: repoDir(root, game) else: root
  let urls = remoteUrls(repo, backupRemote)
  result.game = game
  result.own = game.len > 0 and ownRepo(root, game)
  result.branch = currentBranch(repo)
  if urls.len == 0:
    result.steps = setupSteps(gh, sourceOf(root, game))
    return
  result.setUp = true
  result.url = shown(urls[0])
  let others = remoteNames(repo).filterIt(it != backupRemote).mapIt(remoteUrls(repo, it)).concat
  result.problem = urlProblem(urls, others)

proc status(root, game, gh: string): Run =
  let f = backupFacts(root, game, gh)
  if not f.setUp:
    result.output = "backup: not set up\n"
    result.output.add toonHelp(f.steps)
    return
  result.output = &"backup: remote \"{backupRemote}\" is set to {f.url}\n"
  if f.problem.len > 0:
    result.output.add "problem: " & f.problem & "\n"
    result.code = 1
    return
  result.output.add (if f.branch.len > 0: &"branch: {f.branch}\n" else: "branch: none (git is detached)\n")
  result.output.add toonHelp(@["To upload (only after the friend says yes): para backup --push --yes"])

proc push(root, game, gh: string, yes, isPrivate: bool): Run =
  let repo = if game.len > 0: repoDir(root, game) else: root
  let urls = remoteUrls(repo, backupRemote)
  if urls.len == 0:
    return refuse(&"There is no \"{backupRemote}\" remote, so there is nowhere to upload to.", "Nothing was uploaded.",
                  toonHelp(setupSteps(gh, sourceOf(root, game))).strip)
  var others: seq[string]
  for name in remoteNames(repo):
    if name != backupRemote: others.add remoteUrls(repo, name)
  let problem = urlProblem(urls, others)
  if problem.len > 0:
    return refuse("I won't upload: " & problem & ".", "Nothing was uploaded.")
  let branch = currentBranch(repo)
  if branch.len == 0:
    return refuse("Git says this copy is not on a named line of work (detached), so I won't upload.",
                  "Nothing was uploaded.")
  if not yes:
    let what = if game.len > 0 and ownRepo(root, game): &"of {game}" else: "and the engine's files that come with this copy"
    return refuse(&"Uploading puts a copy of your saved work (the line \"{branch}\", every save point, {what}) online at {shown(urls[0])}.",
                  "Unsaved changes, and files git ignores (tmp/, .nimcache/), are not part of it.",
                  &"Nothing was uploaded. To do it, run: para backup" & (if game.len > 0: " --game " & game else: "") & " --push --yes")
  case ghPrivacy(gh, urls[0])
  of privateYes: discard
  of privatePublic:
    return refuse(&"gh says {shown(urls[0])} is PUBLIC. I only upload to a private repository.",
                  "Nothing was uploaded. Make it private on the website, or make a new private one.")
  of privateUnknown:
    return refuse(&"gh is installed but could not say whether {shown(urls[0])} is private (not logged in, or no access).",
                  "Nothing was uploaded. Log in yourself with `gh auth login`, then try again.")
  of cannotCheck:
    if not isPrivate:
      return refuse(&"I can't check from here whether {shown(urls[0])} is private (gh is not installed, or this is not a github.com address).",
                    "Nothing was uploaded. Open the repository's page: if it says \"Private\", run again with --is-private.")
  putEnv("GIT_TERMINAL_PROMPT", "0") # no login question that nobody can answer: fail instead
  let r = git(repo, @["push", backupRemote,
                      &"refs/heads/{branch}:refs/heads/{branch}",
                      "refs/tags/save-*:refs/tags/save-*"])
  if r.exitCode != 0:
    result.output = "error: the upload failed, nothing on your computer changed\n" & lastLines(r.output, 8)
    result.output.add toonHelp(@["If it asked for a login: log in yourself (`gh auth login`, or the git credential manager), then run it again",
                                 "If it says the online copy has changes this copy lacks, ask for help; I never force an upload"])
    result.code = 1
    return
  result.output = &"Backed up: the line \"{branch}\" and its save points are online at {shown(urls[0])}.\n"
  result.output.add toonHelp(@["Only saved work is in it; changes not yet saved are not",
                               "Run this again after more saves (ask the friend first)"])

proc runBackupWith*(args: seq[string], root = "", gh = "gh"): Run =
  var doPush, yes, isPrivate = false
  var requested = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h": return (backupHelp, 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      requested = args[i]
    of "--push": doPush = true
    of "--yes": yes = true
    of "--is-private": isPrivate = true
    else:
      return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --game NAME, --push, --yes, --is-private"])
    inc i
  if (yes or isPrivate) and not doPush:
    return errorOut("--yes and --is-private only go with --push", @["Run `para backup --help`"])
  var game: string
  let picked = backupRepo(root, requested, game)
  if picked.code != 0: return picked
  if not doPush: return status(root, game, gh)
  push(root, game, gh, yes, isPrivate)

proc runBackup*(args: seq[string]): Run =
  runBackupWith(args)
