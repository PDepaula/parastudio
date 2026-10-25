# The routes behind `para studio`'s page (the HTTP checks are in studiohttp.nim and have already
# passed by the time a request gets here).
#
# Reading is done in this process with the same code the terminal verbs use: the resume facts are
# producercmd's own readers, the save points are savepoint.nim's `listSavePoints`, the backup
# status is backupcmd's `backupFacts`. Anything that changes the friend's files or sends
# something away is not done here at all: it is the same `para` binary run as a child process with
# the same arguments a terminal would use (`para check`, `para save -m`, `para backup --push
# --yes`), so the guards live in those verbs and are inherited, not copied: a save still needs a
# fresh passing check, a backup still only goes to the remote named "backup" and still refuses a
# public repository. The child is started with an argument list (no shell, nothing quoted by
# hand), in the repository root, and its output is collected for the page to poll.
#
# One such job runs at a time (a second one is refused, not queued). The job runs on its own
# thread so the server stays responsive; the page polls `GET /api/job?id=N&since=K`.
#
# Routes (all JSON; the page is `GET /`):
#   GET  /api/state?game=NAME   games, the chosen game and the resume facts, the helpers' lanes, the current job
#   GET  /api/lanes?game=NAME   just the helpers' lanes (the page polls it while a turn runs)
#   GET  /api/savepoints?game=  the save points, oldest first
#   GET  /api/backup?game=      whether a private online backup is set up for the game's own repository, and where
#   GET  /api/job?id=&since=    a job's progress: its output from byte `since`, and whether it ended
#   POST /api/check             {game}: run `para check`
#   POST /api/save              {game, message}: run `para save -m`
#   POST /api/backup            {game, confirm: true, isPrivate?: bool}: run `para backup --game G --push --yes`
#   POST /api/new               {name}: run `para new NAME` (a new game from template/, with its own git repository)
#   POST /api/lane/land         {game, id}: run `para lane land GAME ID` (a helper's work goes into the game, unsaved)
#   GET  /api/agent?game=       the producer's tool for this game (installed? version?), who pays, the turn time
#                               limit, and `agents`: every producer the page may pick, with `current` named
#   GET  /api/preflight?game=   setup checks for the producer this game talks to (installed, signed in, folder trusted, edits allowed in games/): `ready`, and each check's state and, when not ok, one plain fix line; the optional programs (Lavish, for visual boards: `ok` or `absent`, never in `ready`) with the command that adds one; also this folder and whether the page may offer to open a terminal in it
#   POST /api/terminal          {}: open a terminal window in this folder, where the system has one standard way to (macOS only); else 501
#   POST /api/agent/pick        {game, agent}: talk to this producer from the next message on (each keeps its own conversation)
#   GET  /api/chat?game=&since= the open chat's lines after number `since`, which chat that is, and whether a turn is running
#   GET  /api/chats?game=       the game's past chats with its producer, the one used last first: number, title, times, which one is open
#   POST /api/chat/send         {game, text}: one turn with the producer in the open chat (one at a time)
#   POST /api/chat/stop         {}: end the running turn and everything it started
#   POST /api/chat/new          {game}: the next message starts a new chat; the earlier ones stay in the list
#   POST /api/chat/open         {game, id}: open an earlier chat, its lines read back; the next message continues its conversation
#   POST /api/chat/delete       {game, id, confirm: true}: forget a chat (its title, times, session id and kept lines); nothing in the game's folder changes
#   GET  /api/play              the game window: idle, building, starting, running, failed or exited, in plain words
#   POST /api/play/start        {game}: build the game with its dev channel and open its native window (a second one restarts it)
#   POST /api/play/stop         {}: close the game window, or stop its build
#   POST /api/play/shot         {game}: ask the open window for a picture and put it in the chat as a card
#   GET  /api/shot?name=        one of the studio's own pictures (image/png); only names the studio made, only from its folder
#
# The chat is studiochat.nim (turns, the list of chats, stopping) on top of agent.nim's adapter
# interface; nothing in this file knows which agent it is. A Check, Save or Backup step and a chat
# turn do not run at the same time: starting one while the other runs is refused with a 409.
#
# The game window is studioplay.nim (the build, the window's process, stopping it) and the
# pictures are studioshot.nim (asking the window, keeping the file, serving it back). Play is
# refused while a Check, Save or Backup step runs (a check builds the game too); it does not wait
# for a chat turn, since the producer's helpers change files while the friend watches.
#
# A helper's lane (lanecmd.nim: its own copy of the game, next to it) is listed in plain facts: its
# role, its ticket, how many files it changed, and `live` while a chat turn runs (the helpers are
# part of a turn, so with no turn running every lane is left over from an earlier one). The page
# says it in words and never shows a folder or branch name. Landing one is a job like Check, so it
# is refused while a turn or another step runs.
#
# Not here (on purpose, this update): going back to an earlier save point and setting work aside.
# They are one more child process each and can follow the same way.

import std/[json, os, strutils, locks, sequtils]
import nimutil
import savepoint
import producercmd
import lanecmd
import backupcmd
import studiohttp
import preflight
import agent
import agents
import studiochat
import studioplay
import studioshot
import studiofonts
import boardcmd

const
  indexHtml = staticRead("studio" / "index.html").replace("/*__FONTS__*/", fontFaces)
  nonceMarker = "__NONCE__"
  maxGameName = 40
  maxMessage = 200
  maxJobOutput = 200_000 ## bytes of a job's output kept; the oldest go first

type
  Studio* = object
    root*: string ## the repository: every child process runs here
    paraExe*: string ## the para binary the jobs run (the studio's own, unless a test says otherwise)
    defaultGame*: string
    lock: Lock
    startGate: Lock ## held while deciding whether a job or a chat turn may start: only one of them can win
    jobId: int
    jobKind, jobGame: string
    jobRunning: bool
    jobCode: int
    jobOutput: string
    jobDropped: int ## bytes cut from the front of jobOutput so far
    jobArgs: seq[string]
    jobThread: Thread[ptr Studio]
    jobThreadStarted: bool
    chat: ChatState
    play: Play
    shotLock: Lock ## one picture at a time

proc newStudio*(root, paraExe: string, defaultGame = "", adapter = defaultAdapter(),
                turnSeconds = defaultTurnSeconds, planner: Planner = defaultPlan,
                others: seq[AgentAdapter] = @[]): ptr Studio =
  ## `adapter` is the agent the chat talks to unless a game was given another (tests pass a
  ## stand-in program), `others` are the further agents the page may pick; `turnSeconds` is how
  ## long one chat turn may run before the studio stops it; `planner` says what Play builds and
  ## opens (tests pass a stand-in game).
  result = create(Studio)
  result.root = root
  result.paraExe = paraExe
  result.defaultGame = defaultGame
  initLock(result.lock)
  initLock(result.startGate)
  initLock(result.shotLock)
  initChat(addr result.chat, root, adapter & others, turnSeconds)
  initPlay(addr result.play, root, planner)

proc shutdownStudio*(st: ptr Studio) =
  ## The studio is closing: end a running chat turn and the game window, so nothing is left running.
  shutdownChat(addr st.chat)
  shutdownPlay(addr st.play)

# --- small helpers -------------------------------------------------------------

proc jsonResponse(status: int, node: JsonNode): Response =
  Response(status: status, contentType: "application/json; charset=utf-8", body: $node & "\n")

proc fail(status: int, message: string, code = "error"): Response =
  jsonResponse(status, %*{"error": code, "message": message})

proc bodyObject(req: Request, obj: var JsonNode): Response =
  ## Status 0 and `obj` set, or a 400.
  try:
    obj = parseJson(req.body)
  except CatchableError:
    return fail(400, "The studio could not read that request.")
  if obj.kind != JObject: return fail(400, "The studio could not read that request.")
  Response()

proc fieldString(obj: JsonNode, key: string): string =
  if obj.hasKey(key) and obj[key].kind == JString: obj[key].getStr else: ""

proc fieldInt(obj: JsonNode, key: string): int =
  ## A whole number from 1 to 999999999, else 0.
  if obj.hasKey(key) and obj[key].kind == JInt and obj[key].getBiggestInt in 1'i64 .. 999_999_999'i64: obj[key].getInt else: 0

proc pickGame(st: ptr Studio, asked: string, game: var string): Response =
  ## The game a request is about: the one asked for, else the one the studio was started for, else
  ## the only one there is. Status 0 and `game` set, or a refusal.
  let plans = gamesWithPlan(st.root)
  var name = asked
  if name.len == 0: name = st.defaultGame
  if name.len == 0 and plans.len == 1: name = plans[0]
  if name.len == 0:
    return fail(400, "Say which game this is about.", "which-game")
  if name notin plans:
    return fail(404, "There is no game called \"" & name.cleanValue & "\" with a PLAN.md here.", "no-such-game")
  game = name
  Response()

# --- facts ---------------------------------------------------------------------

proc gameFacts(root, game: string): JsonNode =
  ## The resume digest of `para producer-context`, as data. A fact that could not be found is null.
  let dir = gameDirOf(root, game)
  let header = parseHeader(readOrEmpty(dir / planFile))
  let choices = openChoiceCount(readOrEmpty(dir / choicesFile))
  let playtest = lastPlaytestLine(readOrEmpty(dir / playtestFile))
  let notes = notesSummary(readOrEmpty(dir / notesFile))
  let step = nowStep(readOrEmpty(dir / planFile))
  result = newJObject()
  result["now"] = if step.len > 0: %step else: newJNull()
  result["inProgress"] = if header.inProgress.len > 0: %header.inProgress else: newJNull()
  result["openChoices"] = if choices >= 0: %choices else: newJNull()
  result["playtest"] = if playtest.len > 0: %playtest else: newJNull()
  result["notes"] = if notes.len > 0: %notes else: newJNull()
  let (res, points) = listSavePoints(root, game, quick = true)
  result["lastSave"] = newJNull()
  if res.exitCode == 0 and points.len > 0:
    let last = points[^1]
    result["lastSave"] = %*{"n": last.n, "saved": cleanValue(last.saved), "note": cleanValue(last.note, maxFact)}
  result["savePointCount"] = if res.exitCode == 0: %points.len else: newJNull()
  var ok: bool
  let changed = gameChanges(root, game, ok)
  result["unsaved"] = newJNull()
  if ok:
    result["unsaved"] = %*{"count": changed.len, "names": changed[0 ..< min(changed.len, 3)].mapIt(cleanValue(it))}
  result["checked"] = %(try: checksJustPassed(root, game) except CatchableError: false)

proc lanesJson(st: ptr Studio, game: string): JsonNode =
  ## The game's lanes, as the page needs them; a lane git could not read is still listed.
  result = newJArray()
  let live = isRunning(addr st.chat)
  for l in lanesOf(st.root, game, quick = true):
    result.add %*{"id": l.id, "role": l.role, "ticket": cleanValue(l.ticket, maxFact), "started": l.started,
                  "files": changedFiles(l).len, "commits": l.steps, "live": live and not l.landed,
                  "landed": l.landed, "known": l.known}

proc jobSummary(st: ptr Studio): JsonNode =
  ## Lock must be held.
  if st.jobId == 0: return newJNull()
  %*{"id": st.jobId, "kind": st.jobKind, "game": st.jobGame, "running": st.jobRunning,
     "code": (if st.jobRunning: newJNull() else: %st.jobCode)}

proc stateJson(st: ptr Studio, asked: string): Response =
  let plans = gamesWithPlan(st.root)
  var game = ""
  let picked = pickGame(st, asked, game)
  if picked.status == 404: return picked # a game that is not there; "which game?" is just a state
  var node = %*{"games": plans, "game": (if game.len > 0: %game else: newJNull()),
                "friend": "", "producer": "", "facts": newJNull(), "lanes": newJArray()}
  if game.len > 0:
    let header = parseHeader(readOrEmpty(gameDirOf(st.root, game) / planFile))
    node["friend"] = %header.friend
    node["producer"] = %header.producer
    node["facts"] = gameFacts(st.root, game)
    node["lanes"] = lanesJson(st, game)
  acquire(st.lock)
  node["job"] = jobSummary(st)
  release(st.lock)
  jsonResponse(200, node)

proc savePointsJson(st: ptr Studio, asked: string): Response =
  var game: string
  let picked = pickGame(st, asked, game)
  if picked.status != 0: return picked
  let (res, points) = listSavePoints(st.root, game, quick = true)
  if res.exitCode != 0:
    return fail(500, "Git could not list the save points just now.", "git")
  var rows = newJArray()
  for p in points:
    rows.add %*{"n": p.n, "saved": cleanValue(p.saved), "note": cleanValue(p.note, maxFact)}
  jsonResponse(200, %*{"game": game, "points": rows})

proc backupGame(st: ptr Studio, asked: string, game: var string): Response =
  ## The game whose repository a backup is about. With no game anywhere (no PLAN.md yet) it is
  ## the repository that contains games/, as before games had their own.
  if asked.len == 0 and st.defaultGame.len == 0 and gamesWithPlan(st.root).len == 0:
    return Response()
  pickGame(st, asked, game)

proc backupJson(st: ptr Studio, asked: string): Response =
  var game: string
  let picked = backupGame(st, asked, game)
  if picked.status != 0: return picked
  let f = backupFacts(st.root, game)
  jsonResponse(200, %*{"game": f.game, "own": f.own, "setUp": f.setUp, "url": f.url,
                       "branch": f.branch, "problem": f.problem, "steps": f.steps})

# --- jobs ----------------------------------------------------------------------

proc jobMain(st: ptr Studio) {.thread.} =
  var exe, root: string
  var args: seq[string]
  acquire(st.lock)
  exe = st.paraExe
  root = st.root
  args = st.jobArgs
  release(st.lock)
  var code = 1
  {.cast(gcsafe).}:
    try:
      let r = runStreamed(exe, args, proc (line: string) =
        acquire(st.lock)
        st.jobOutput.add line & "\n"
        if st.jobOutput.len > maxJobOutput:
          let cut = st.jobOutput.len - maxJobOutput div 2
          st.jobOutput = st.jobOutput[cut .. ^1]
          st.jobDropped += cut
        release(st.lock), root)
      code = r.exitCode
    except CatchableError as e:
      acquire(st.lock)
      st.jobOutput.add "error: could not run the step: " & e.msg & "\n"
      release(st.lock)
  acquire(st.lock)
  st.jobCode = code
  st.jobRunning = false
  release(st.lock)

proc startJob(st: ptr Studio, kind, game: string, args: seq[string]): Response =
  acquire(st.startGate)
  defer: release(st.startGate)
  if isRunning(addr st.chat):
    return fail(409, "The producer is working on your last message. Wait for it, or press Stop in the chat, then try again.", "busy")
  acquire(st.lock)
  defer: release(st.lock)
  if st.jobRunning:
    return fail(409, "Another step is still running (" & st.jobKind & "). Wait for it to finish.", "busy")
  if st.jobThreadStarted:
    joinThread(st.jobThread) # it set jobRunning = false as its last act, so this returns at once
    st.jobThreadStarted = false
  inc st.jobId
  st.jobKind = kind
  st.jobGame = game
  st.jobCode = 0
  st.jobOutput = ""
  st.jobDropped = 0
  st.jobArgs = args
  st.jobRunning = true
  try:
    createThread(st.jobThread, jobMain, st)
    st.jobThreadStarted = true
  except CatchableError:
    st.jobRunning = false
    return fail(500, "The studio could not start that step.", "spawn")
  jsonResponse(200, %*{"job": jobSummary(st)})

proc jobJson(st: ptr Studio, req: Request): Response =
  let idText = req.queryValue("id")
  let sinceText = req.queryValue("since")
  if idText.len == 0 or idText.len > 9 or not idText.allCharsInSet(Digits) or
     sinceText.len > 9 or not sinceText.allCharsInSet(Digits):
    return fail(400, "That job request was not understood.")
  acquire(st.lock)
  defer: release(st.lock)
  if st.jobId == 0 or parseInt(idText) != st.jobId:
    return fail(404, "That step is no longer here.", "no-such-job")
  let since = max(if sinceText.len > 0: parseInt(sinceText) else: 0, st.jobDropped)
  let at = since - st.jobDropped
  let slice = if at <= st.jobOutput.len: st.jobOutput[at .. ^1] else: ""
  var node = jobSummary(st)
  node["output"] = %slice
  node["next"] = %(st.jobDropped + st.jobOutput.len)
  jsonResponse(200, node)

# --- the chat ------------------------------------------------------------------

proc kindName(you: bool, k: UiKind): string =
  if you: return "you"
  case k
  of ukSay: "say"
  of ukActivity: "activity"
  of ukHelper: "helper"
  of ukRefused: "refused"
  of ukNotice: "notice"
  of ukError: "error"
  of ukTurnDone: "done"
  of ukShot: "shot"

proc entryJson(seqNo: int, you: bool, ev: UiEvent): JsonNode =
  result = %*{"seq": seqNo, "kind": kindName(you, ev.kind), "text": ev.text}
  case ev.kind
  of ukHelper:
    result["id"] = %ev.id
    result["role"] = %ev.role
    result["status"] = %ev.status
    result["tools"] = %ev.tools
  of ukNotice, ukError:
    result["code"] = %ev.code
    if ev.detail.len > 0: result["detail"] = %ev.detail
    if ev.url.startsWith("https://"): result["url"] = %ev.url
  of ukRefused:
    result["code"] = %ev.code
  of ukShot:
    result["name"] = %ev.text
  else: discard

proc agentRow(st: ptr Studio, name: string): JsonNode =
  let info = agentInfo(addr st.chat, name)
  %*{"name": info.name, "label": info.label, "installed": info.installed,
     "version": info.version, "note": info.note, "url": info.url,
     "cost": agentCost(addr st.chat, name), "about": agentAbout(addr st.chat, name)}

proc agentJson(st: ptr Studio, req: Request): Response =
  ## The first fields describe the agent this game talks to (what the page showed before there was
  ## a choice); `agents` lists everyone the page may pick from.
  let asked = req.queryValue("game")
  let current = if asked.len > 0 and validGameName(asked): agentOf(addr st.chat, asked)
                else: agentNames(addr st.chat)[0]
  var node = agentRow(st, current)
  node["timeoutMinutes"] = %timeoutMinutes(addr st.chat)
  node["current"] = %current
  var rows = newJArray()
  for name in agentNames(addr st.chat): rows.add agentRow(st, name)
  node["agents"] = rows
  jsonResponse(200, node)

proc terminalCommand*(root: string): seq[string] =
  ## The argument list that opens a terminal window in `root`, or nothing where the system has no
  ## one standard way to. Only macOS does (`open -a Terminal`); Linux has no standard terminal and
  ## Windows has several, so there the page only offers the command to copy.
  when defined(macosx): @["open", "-a", "Terminal", root]
  else: @[]

proc preflightJson(st: ptr Studio, req: Request): Response =
  ## Read-only and free: nothing here calls a model, writes a file or returns anything the agent
  ## program keeps secret (see preflight.nim). Works with no game picked yet, for the default producer.
  let asked = req.queryValue("game")
  let current = if asked.len > 0 and validGameName(asked): agentOf(addr st.chat, asked)
                else: agentNames(addr st.chat)[0]
  let checks = agentPreflight(addr st.chat, current)
  var rows = newJArray()
  for c in checks:
    var row = %*{"id": c.id, "state": stateName(c.state), "label": c.label}
    if c.state != csOk:
      row["problem"] = %c.problem
      row["fix"] = %c.fix
    rows.add row
  # optional programs: shown under their own heading, never in `ready` or the count
  var optional = newJArray()
  let boards = boardCheck()
  var row = %*{"id": boards.id, "state": (if boards.state == csOk: "ok" else: "absent"), "label": boards.label}
  if boards.state != csOk:
    row["problem"] = %boards.problem
    row["command"] = %boardInstallCommand
    row["about"] = %(lavishProgram & " " & lavishTested & " from the npm registry (" & lavishPage & "), MIT licence, no account; needs Node.js " & $nodeNeeded & " or newer")
  optional.add row
  jsonResponse(200, %*{"agent": current, "label": agentLabel(addr st.chat, current),
                        "ready": allOk(checks), "checks": rows, "optional": optional,
                        "folder": st.root, "terminal": terminalCommand(st.root).len > 0})

proc terminalRoute(st: ptr Studio): Response =
  ## Opens a terminal in this folder and nothing else: a fixed program, a fixed folder, no shell,
  ## nothing from the request. The friend types `claude` there themself.
  let cmd = terminalCommand(st.root)
  if cmd.len == 0:
    return fail(501, "This computer has no standard terminal the studio can open. Copy the command and paste it into a terminal you open yourself.", "no-terminal")
  let r = runCaptured(cmd[0], cmd[1 .. ^1], timeoutMs = 10000)
  if r.exitCode != 0:
    return fail(500, "The terminal did not open. Copy the command and paste it into a terminal you open yourself.", "terminal")
  jsonResponse(200, %*{"ok": true})

proc newGameRoute(st: ptr Studio, body: JsonNode): Response =
  ## `para new NAME` as a job, with the name checked first so a mistake is told in plain words.
  let name = body.fieldString("name").strip()
  if name.len == 0:
    return fail(400, "Give the game a name first, for example: space_frogs", "needs-name")
  if name.len > maxGameName or not validGameName(name):
    return fail(400, "A game's name uses only small letters (a to z), digits and _, starts with a letter, and is at most " &
      $maxGameName & " characters. For example: space_frogs", "bad-name")
  if dirExists(gameDirOf(st.root, name)):
    return fail(409, "There is already a game called " & name & ". Pick another name.", "exists")
  startJob(st, "new", name, @["new", name])

proc agentPickJson(st: ptr Studio, body: JsonNode): Response =
  var game: string
  let picked = pickGame(st, body.fieldString("game"), game)
  if picked.status != 0: return picked
  acquire(st.startGate)
  defer: release(st.startGate)
  let r = pickAgent(addr st.chat, game, body.fieldString("agent"))
  if not r.ok: return fail(r.status, r.message, r.code)
  jsonResponse(200, %*{"current": agentOf(addr st.chat, game)})

proc chatJson(st: ptr Studio, req: Request): Response =
  let sinceText = req.queryValue("since")
  if sinceText.len > 9 or not sinceText.allCharsInSet(Digits):
    return fail(400, "That chat request was not understood.")
  var game: string
  let picked = pickGame(st, req.queryValue("game"), game)
  if picked.status != 0: return picked
  let v = view(addr st.chat, game, if sinceText.len > 0: parseInt(sinceText) else: 0)
  var rows = newJArray()
  for (n, you, ev) in v.entries: rows.add entryJson(n, you, ev)
  jsonResponse(200, %*{"game": game, "chat": v.chat, "running": v.running, "turn": v.turnId, "next": v.next, "events": rows})

proc chatsJson(st: ptr Studio, req: Request): Response =
  var game: string
  let picked = pickGame(st, req.queryValue("game"), game)
  if picked.status != 0: return picked
  let l = listChats(addr st.chat, game)
  var rows = newJArray()
  for c in l.chats:
    rows.add %*{"id": c.id, "title": c.title, "started": c.started, "updated": c.updated, "open": c.id == l.current}
  jsonResponse(200, %*{"game": game, "agent": l.agent, "current": l.current, "chats": rows})

proc chatPickJson(st: ptr Studio, body: JsonNode, delete: bool): Response =
  var game: string
  let picked = pickGame(st, body.fieldString("game"), game)
  if picked.status != 0: return picked
  let id = body.fieldInt("id")
  if id == 0: return fail(400, "Say which chat.", "which-chat")
  if delete and not (body.hasKey("confirm") and body["confirm"].kind == JBool and body["confirm"].getBool):
    return fail(400, "A chat is only deleted after you say yes to it.", "needs-confirm")
  let r = if delete: deleteChat(addr st.chat, game, id) else: openChat(addr st.chat, game, id)
  if not r.ok: return fail(r.status, r.message, r.code)
  jsonResponse(200, %*{"ok": true})

proc sendJson(st: ptr Studio, body: JsonNode): Response =
  var game: string
  let picked = pickGame(st, body.fieldString("game"), game)
  if picked.status != 0: return picked
  acquire(st.startGate)
  defer: release(st.startGate)
  acquire(st.lock)
  let jobBusy = st.jobRunning
  release(st.lock)
  if jobBusy:
    return fail(409, "A step (Check, Save or Backup) is still running. Wait for it to finish, then send your message.", "busy")
  let started = startTurn(addr st.chat, game, body.fieldString("text"))
  if not started.ok: return fail(started.status, started.message, started.code)
  jsonResponse(200, %*{"turn": started.turnId})

# --- the game window -----------------------------------------------------------

proc playJson(st: ptr Studio): Response =
  let v = playView(addr st.play)
  jsonResponse(200, %*{"state": v.state, "game": v.game, "run": v.run, "message": v.message, "code": v.code,
                       "detail": v.detail, "progress": v.progress, "live": v.live})

proc playStartJson(st: ptr Studio, body: JsonNode): Response =
  var game: string
  let picked = pickGame(st, body.fieldString("game"), game)
  if picked.status != 0: return picked
  if not fileExists(gameDirOf(st.root, game) / (game & ".nim")):
    return fail(404, "There is no game to play yet: games/" & game & "/" & game & ".nim is not there. Ask the producer to build the first version.", "no-source")
  acquire(st.lock)
  let jobBusy = st.jobRunning
  release(st.lock)
  if jobBusy:
    return fail(409, "A step (Check, Save or Backup) is still running, and it builds the game too. Wait for it to finish, then press Play.", "busy")
  if not startPlay(addr st.play, game):
    return fail(500, "The studio could not close the game window it opened before. Close that window yourself, then press Play again.", "restart")
  playJson(st)

proc shotRoute(st: ptr Studio, body: JsonNode): Response =
  var game: string
  let picked = pickGame(st, body.fieldString("game"), game)
  if picked.status != 0: return picked
  let window = playView(addr st.play)
  if window.state in ["starting", "running"] and window.game != game:
    return fail(409, "The game window that is open is " & window.game & ", not " & game & ". Pick " & window.game & " to take its picture, or press Play for " & game & " first.", "other-game")
  if not tryAcquire(st.shotLock):
    return fail(409, "A picture is already being taken. Wait a moment.", "busy")
  defer: release(st.shotLock)
  let shot = takeShot(st.root)
  if not shot.ok:
    return fail(if shot.code in ["odd-path", "cannot-save"]: 500 else: 409, shot.message, shot.code)
  addCard(addr st.chat, game, UiEvent(kind: ukShot, text: shot.name))
  jsonResponse(200, %*{"name": shot.name})

proc shotImage(st: ptr Studio, req: Request): Response =
  ## Only a name of the exact shape the studio makes is looked up, and only in the studio's own folder.
  let bytes = readShot(st.root, req.queryValue("name"))
  if bytes.len == 0: return fail(404, "That picture is not kept any more.", "no-such-shot")
  Response(status: 200, contentType: "image/png", body: bytes)

# --- the routes ----------------------------------------------------------------

proc pageResponse(): Response =
  let nonce = newToken()
  Response(status: 200, contentType: "text/html; charset=utf-8",
           body: indexHtml.replace(nonceMarker, nonce),
           headers: @[("Content-Security-Policy",
             "default-src 'none'; script-src 'nonce-" & nonce & "'; style-src 'nonce-" & nonce &
             "'; connect-src 'self'; img-src data: blob:; font-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")])

proc handle(st: ptr Studio, req: Request): Response =
  if req.meth == "GET":
    case req.path
    of "/": return pageResponse()
    of "/api/state": return stateJson(st, req.queryValue("game"))
    of "/api/savepoints": return savePointsJson(st, req.queryValue("game"))
    of "/api/backup": return backupJson(st, req.queryValue("game"))
    of "/api/job": return jobJson(st, req)
    of "/api/agent": return agentJson(st, req)
    of "/api/preflight": return preflightJson(st, req)
    of "/api/chat": return chatJson(st, req)
    of "/api/chats": return chatsJson(st, req)
    of "/api/play": return playJson(st)
    of "/api/lanes":
      var game: string
      let picked = pickGame(st, req.queryValue("game"), game)
      if picked.status != 0: return picked
      return jsonResponse(200, %*{"game": game, "lanes": lanesJson(st, game)})
    of "/api/shot": return shotImage(st, req)
    else: return fail(404, "Not found.", "not-found")
  var body: JsonNode
  let parsed = bodyObject(req, body)
  if parsed.status != 0: return parsed
  var game: string
  case req.path
  of "/api/check":
    let picked = pickGame(st, body.fieldString("game"), game)
    if picked.status != 0: return picked
    startJob(st, "check", game, @["check", "--game", game])
  of "/api/save":
    let picked = pickGame(st, body.fieldString("game"), game)
    if picked.status != 0: return picked
    let message = body.fieldString("message").strip()
    if message.len == 0:
      return fail(400, "Write a few words about what changed, then save.", "needs-message")
    if message.len > maxMessage or message.anyIt(it < ' ' or it == '\x7f'):
      return fail(400, "Keep the note to one short line (up to " & $maxMessage & " characters).", "bad-message")
    startJob(st, "save", game, @["save", "--game", game, "-m", message])
  of "/api/new": newGameRoute(st, body)
  of "/api/lane/land":
    let picked = pickGame(st, body.fieldString("game"), game)
    if picked.status != 0: return picked
    let id = body.fieldString("id")
    if not validLaneId(id) or id notin lanesOf(st.root, game, quick = true).mapIt(it.id):
      return fail(404, "That helper's work is not here any more.", "no-such-lane")
    startJob(st, "land", game, @["lane", "land", game, id])
  of "/api/terminal": terminalRoute(st)
  of "/api/play/start": playStartJson(st, body)
  of "/api/play/stop":
    jsonResponse(200, %*{"stopped": stopPlay(addr st.play)})
  of "/api/play/shot": shotRoute(st, body)
  of "/api/agent/pick": agentPickJson(st, body)
  of "/api/chat/send": sendJson(st, body)
  of "/api/chat/stop":
    jsonResponse(200, %*{"stopped": stopTurn(addr st.chat)})
  of "/api/chat/new":
    let picked = pickGame(st, body.fieldString("game"), game)
    if picked.status != 0: return picked
    if not newConversation(addr st.chat, game):
      return fail(409, "The producer is still working. Stop the turn first.", "busy")
    jsonResponse(200, %*{"ok": true})
  of "/api/chat/open": chatPickJson(st, body, delete = false)
  of "/api/chat/delete": chatPickJson(st, body, delete = true)
  of "/api/backup":
    if not (body.hasKey("confirm") and body["confirm"].kind == JBool and body["confirm"].getBool):
      return fail(400, "A backup uploads your saved work, so it only runs after you say yes to it.", "needs-confirm")
    let isPrivate = body.hasKey("isPrivate") and body["isPrivate"].kind == JBool and body["isPrivate"].getBool
    let picked = backupGame(st, body.fieldString("game"), game)
    if picked.status != 0: return picked
    startJob(st, "backup", game,
             @["backup"] & (if game.len > 0: @["--game", game] else: @[]) & @["--push", "--yes"] &
             (if isPrivate: @["--is-private"] else: @[]))
  else:
    fail(404, "Not found.", "not-found")

proc studioHandler*(ctx: pointer, req: Request): Response {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    handle(cast[ptr Studio](ctx), req)
