# The producer's chat inside `para studio`: one conversation per game and agent, one turn at a time.
#
# This file knows the agent only through agent.nim's `AgentAdapter`: it hands the adapter the
# friend's message, collects the `UiEvent`s the adapter emits into a numbered list the page polls
# (`GET /api/chat?since=N`, the same polling the Check and Save steps use), keeps the agent's
# session id per game and agent in a small file so a restart or a reopened page resumes the same
# conversation, and stops a turn (the Stop button, a timeout, or the studio closing).
#
# A turn runs on its own thread, with a second small thread watching the clock. Nothing is sent to
# the agent unless the friend sends a message: opening the page, polling, even a reload start no
# turn and so cost nothing.
#
# Each agent keeps its own conversation: the session file is `tmp/studio/session-<game>-<agent>.id`
# and holds that agent's session id and nothing else (a newline-free token; `readSession` refuses
# anything that is not one). One agent's id is never handed to another, which could not use it. The
# agent a game talks to is remembered in `tmp/studio/agent-<game>.txt` (its name and nothing else);
# a game with no pick uses the studio's default, the first adapter. The session file Claude used
# before there was a second agent, `session-<game>.id`, is still read for Claude. Nothing the friend
# typed, no transcript, and no login or key is ever written to disk by the studio. The conversation
# shown on the page lives in memory for as long as the studio runs.

import std/[locks, os, strutils, tables, times]
import agent
import savepoint

const
  maxMessageChars* = 8000
  maxEvents = 1500 ## chat lines kept in memory; the oldest go first
  defaultTurnSeconds* = 3600

type
  ChatEntry = object
    seq: int
    game: string
    you: bool
    ev: UiEvent

  ChatState* = object
    lock: Lock
    startLock: Lock ## one `startTurn` at a time
    adapters: seq[AgentAdapter] ## the first is the default
    root: string
    timeoutSec: int
    running: bool
    turnId: int
    turnGame: string
    turnAgent: string
    turnText: string
    turnSession: string
    startedAt: float
    stopping: int ## stop requests currently inside `cancel`
    ctl: ptr TurnControl
    entries: seq[ChatEntry]
    nextSeq: int
    turnThread: Thread[ptr ChatState]
    watchThread: Thread[ptr ChatState]
    threadsStarted: bool
    infos: Table[string, tuple[info: AgentInfo, at: float]]

  Started* = object
    ok*: bool
    status*: int
    code*, message*: string
    turnId*: int

proc initChat*(c: ptr ChatState, root: string, adapters: seq[AgentAdapter], timeoutSec = defaultTurnSeconds) =
  ## `adapters` are the agents the page may pick from, the default first.
  doAssert adapters.len > 0
  initLock(c.lock)
  initLock(c.startLock)
  c.root = root
  c.adapters = adapters
  c.timeoutSec = timeoutSec
  c.nextSeq = 1

proc agentNames*(c: ptr ChatState): seq[string] =
  for a in c.adapters: result.add a.name

proc adapterFor(c: ptr ChatState, name: string): AgentAdapter =
  for a in c.adapters:
    if a.name == name: return a
  c.adapters[0]

# --- the session file ---------------------------------------------------------------

proc sessionPath*(root, game, agent: string): string =
  root / "tmp" / "studio" / ("session-" & game & "-" & agent & ".id")

proc legacySessionPath(root, game: string): string =
  ## Where the one conversation per game was kept before each agent had its own (always Claude's).
  root / "tmp" / "studio" / ("session-" & game & ".id")

proc validAgentName(agent: string): bool =
  agent.len in 1..24 and agent.allCharsInSet({'a'..'z', '0'..'9', '-'})

proc readSession*(root, game, agent: string): string =
  ## The saved session id for `game` with `agent`, "" when there is none or the file holds anything
  ## but an id.
  if not validGameName(game) or not validAgentName(agent): return ""
  var paths = @[sessionPath(root, game, agent)]
  if agent == "claude": paths.add legacySessionPath(root, game)
  for path in paths:
    try:
      let id = validSessionToken(readFile(path).strip)
      if id.len > 0: return id
    except IOError, OSError:
      discard

proc writeSession*(root, game, agent, id: string) =
  if not validGameName(game) or not validAgentName(agent) or validSessionToken(id).len == 0: return
  let path = sessionPath(root, game, agent)
  try:
    createDir(path.parentDir)
    let tmpPath = path & ".new"
    writeFile(tmpPath, id)
    moveFile(tmpPath, path)
    if agent == "claude": removeFile(legacySessionPath(root, game)) # the new file now holds it
  except IOError, OSError:
    discard # the conversation still works; it just will not resume after a restart

proc forgetSession*(root, game: string, agent = "") =
  ## Forgets `agent`'s saved conversation for `game`, or every agent's when `agent` is left out.
  if not validGameName(game): return
  try:
    for kind, path in walkDir(root / "tmp" / "studio"):
      let name = path.extractFilename
      if kind != pcFile or not name.startsWith("session-" & game & "-") or not name.endsWith(".id"): continue
      let who = name["session-".len + game.len + 1 ..< name.len - ".id".len]
      if agent.len == 0 or who == agent: removeFile(path)
    if agent.len == 0 or agent == "claude": removeFile(legacySessionPath(root, game))
  except OSError:
    discard

# --- the agent a game talks to ------------------------------------------------------

proc pickPath(root, game: string): string =
  root / "tmp" / "studio" / ("agent-" & game & ".txt")

proc agentOf*(c: ptr ChatState, game: string): string =
  ## The agent `game`'s chat talks to: the one the friend picked if it still exists, else the default.
  if validGameName(game):
    try:
      let name = readFile(pickPath(c.root, game)).strip
      for a in c.adapters:
        if a.name == name: return name
    except IOError, OSError:
      discard
  c.adapters[0].name

# --- the event list -----------------------------------------------------------------

proc add(c: ptr ChatState, game: string, ev: UiEvent, you = false) =
  acquire(c.lock)
  c.entries.add ChatEntry(seq: c.nextSeq, game: game, you: you, ev: ev)
  inc c.nextSeq
  if c.entries.len > maxEvents: c.entries = c.entries[c.entries.len - maxEvents .. ^1]
  release(c.lock)

proc addCard*(c: ptr ChatState, game: string, ev: UiEvent) =
  ## A line the studio itself puts in `game`'s conversation (a screenshot card): not from the
  ## agent, so it works with no turn running.
  c.add(game, ev)

# --- a turn -------------------------------------------------------------------------

proc turnMain(c: ptr ChatState) {.thread.} =
  var adapter: AgentAdapter
  var req: TurnRequest
  var game: string
  var ctl: ptr TurnControl
  var timeoutSec: int
  acquire(c.lock)
  adapter = c.adapterFor(c.turnAgent)
  game = c.turnGame
  req = TurnRequest(text: c.turnText, sessionId: c.turnSession, workDir: c.root)
  ctl = c.ctl
  timeoutSec = c.timeoutSec
  release(c.lock)
  {.cast(gcsafe).}:
    let root = req.workDir
    let agentName = adapter.name
    req.onSession = proc (id: string) = writeSession(root, game, agentName, id)
    var res: TurnResult
    try:
      res = adapter.runTurn(adapter, req, ctl, proc (ev: UiEvent) = c.add(game, ev))
    except CatchableError as e:
      c.add(game, UiEvent(kind: ukError, code: "crashed",
        text: "The studio hit a problem while talking to the producer's tool: " & oneLine(redactSecrets(e.msg), 200)))
    let reason = ctl.cancelReason
    var done = UiEvent(kind: ukTurnDone, text: "")
    if res.cancelled and reason == "timeout":
      c.add(game, UiEvent(kind: ukError, code: "timeout",
        text: "This turn ran longer than " & (if timeoutSec >= 120: $(timeoutSec div 60) & " minutes" elif timeoutSec >= 60: "a minute" else: $timeoutSec & (if timeoutSec == 1: " second" else: " seconds")) & ", so I stopped it. Anything a helper already changed is still in the game folder. Ask the producer where things stand."))
      done.text = "timeout"
    elif res.cancelled:
      c.add(game, UiEvent(kind: ukNotice, code: "stopped",
        text: "Stopped. Anything a helper already changed is still in the game folder. Ask the producer where things stand."))
      done.text = "stopped"
    elif res.ok: done.text = "ok"
    else: done.text = "failed"
    c.add(game, done)
  acquire(c.lock)
  c.running = false
  release(c.lock)

proc watchMain(c: ptr ChatState) {.thread.} =
  var ctl: ptr TurnControl
  var until: float
  acquire(c.lock)
  ctl = c.ctl
  until = c.startedAt + c.timeoutSec.float
  release(c.lock)
  while true:
    sleep(200)
    acquire(c.lock)
    let still = c.running
    release(c.lock)
    if not still: return
    if epochTime() > until:
      ctl.cancel("timeout")
      return

proc reap(c: ptr ChatState) =
  ## Joins the last turn's threads and frees its control. Only called when no turn is running.
  while true:
    acquire(c.lock)
    let busy = c.stopping > 0
    release(c.lock)
    if not busy: break
    sleep(10)
  if c.threadsStarted:
    joinThread(c.turnThread)
    joinThread(c.watchThread)
    c.threadsStarted = false
  if c.ctl != nil:
    freeTurnControl(c.ctl)
    c.ctl = nil

proc isRunning*(c: ptr ChatState): bool =
  acquire(c.lock)
  result = c.running
  release(c.lock)

proc validMessage*(text: string): string =
  ## "" when `text` can be sent, else the plain reason it cannot.
  if text.strip.len == 0: return "Write a message first."
  if text.len > maxMessageChars:
    return "That message is too long (up to " & $maxMessageChars & " characters). Send it in smaller pieces."
  for ch in text:
    if ch == '\0' or (ch < ' ' and ch notin {'\n', '\r', '\t'}):
      return "That message has a character the studio can't send."

proc startTurn*(c: ptr ChatState, game, text: string): Started =
  acquire(c.startLock)
  defer: release(c.startLock)
  let problem = validMessage(text)
  if problem.len > 0: return Started(status: 400, code: "bad-message", message: problem)
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  acquire(c.lock)
  if c.running:
    release(c.lock)
    return Started(status: 409, code: "busy", message: "The producer is still working on your last message. Wait for it, or press Stop.")
  release(c.lock)
  reap(c)
  let agentName = agentOf(c, game)
  let session = readSession(c.root, game, agentName)
  acquire(c.lock)
  c.running = true
  inc c.turnId
  c.turnGame = game
  c.turnAgent = agentName
  c.turnText = text
  c.turnSession = session
  c.startedAt = epochTime()
  c.ctl = newTurnControl()
  result = Started(ok: true, status: 200, turnId: c.turnId)
  release(c.lock)
  c.add(game, UiEvent(kind: ukSay, text: text.strip), you = true)
  try:
    createThread(c.turnThread, turnMain, c)
    createThread(c.watchThread, watchMain, c)
    c.threadsStarted = true
  except CatchableError:
    acquire(c.lock)
    c.running = false
    release(c.lock)
    return Started(status: 500, code: "spawn", message: "The studio could not start that turn.")

proc stopTurn*(c: ptr ChatState): bool =
  ## True when there was a turn to stop. Returns once the child is gone (or after a short grace).
  var ctl: ptr TurnControl
  acquire(c.lock)
  if c.running and c.ctl != nil:
    ctl = c.ctl
    inc c.stopping
  release(c.lock)
  if ctl == nil: return false
  ctl.cancel("stop")
  acquire(c.lock)
  dec c.stopping
  release(c.lock)
  true

proc shutdownChat*(c: ptr ChatState) =
  ## The studio is closing: end a running turn so no claude is left behind.
  discard stopTurn(c)
  for _ in 0 ..< 100: # up to 10 s for the turn thread to wind down
    if not isRunning(c): break
    sleep(100)
  if not isRunning(c): reap(c)

proc newConversation*(c: ptr ChatState, game: string): bool =
  ## Forgets the saved session for `game` and clears its lines from the page. False while a turn runs.
  if not validGameName(game): return false
  acquire(c.lock)
  defer: release(c.lock)
  if c.running: return false
  var kept: seq[ChatEntry]
  for e in c.entries:
    if e.game != game: kept.add e
  c.entries = kept
  forgetSession(c.root, game)
  true

# --- what the page reads ------------------------------------------------------------

type
  ChatView* = object
    running*: bool
    turnId*: int
    next*: int
    entries*: seq[tuple[seq: int, you: bool, ev: UiEvent]]

proc view*(c: ptr ChatState, game: string, since: int): ChatView =
  acquire(c.lock)
  defer: release(c.lock)
  result.running = c.running
  result.turnId = c.turnId
  result.next = c.nextSeq - 1
  for e in c.entries:
    if e.seq > since and e.game == game: result.entries.add (e.seq, e.you, e.ev)

proc agentInfo*(c: ptr ChatState, name: string): AgentInfo =
  ## What `describe` says about `name`, looked up at most every 20 seconds (it may start the program
  ## to ask its version). Called with the lock free: the lookup can take a moment.
  let adapter = c.adapterFor(name)
  acquire(c.lock)
  let known = c.infos.getOrDefault(adapter.name)
  let fresh = known.at > 0 and epochTime() - known.at < 20
  release(c.lock)
  if fresh: return known.info
  {.cast(gcsafe).}:
    result = adapter.describe(adapter)
  acquire(c.lock)
  c.infos[adapter.name] = (result, epochTime())
  release(c.lock)

proc agentPreflight*(c: ptr ChatState, name: string): seq[PreflightCheck] =
  ## The startup checks for `name` (see preflight.nim). Not kept: each call asks again, so "Check
  ## again" on the page sees what the friend just fixed. Called with the lock free: a probe can take a moment.
  let adapter = c.adapterFor(name)
  if adapter.preflight.isNil: return
  {.cast(gcsafe).}:
    result = adapter.preflight(adapter, c.root)

proc agentLabel*(c: ptr ChatState, name: string): string = c.adapterFor(name).label
proc agentCost*(c: ptr ChatState, name: string): string = c.adapterFor(name).cost
proc agentAbout*(c: ptr ChatState, name: string): string = c.adapterFor(name).about
proc timeoutMinutes*(c: ptr ChatState): int = c.timeoutSec div 60

proc pickAgent*(c: ptr ChatState, game, name: string): Started =
  ## Makes `name` the agent `game`'s chat talks to, from the next message on. Each agent keeps its
  ## own conversation, so switching back later picks up where that agent left off. Refused while a
  ## turn runs (it would be talking to the other one).
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  if name notin c.agentNames:
    return Started(status: 400, code: "which-agent", message: "That is not one of the producers this studio knows.")
  acquire(c.startLock)
  defer: release(c.startLock)
  if isRunning(c):
    return Started(status: 409, code: "busy", message: "The producer is working on your last message. Wait for it, or press Stop, then pick again.")
  if agentOf(c, game) == name: return Started(ok: true, status: 200)
  let path = pickPath(c.root, game)
  try:
    createDir(path.parentDir)
    writeFile(path & ".new", name)
    moveFile(path & ".new", path)
  except IOError, OSError:
    return Started(status: 500, code: "cannot-save", message: "I could not remember that pick (is the disk full?).")
  c.add(game, UiEvent(kind: ukNotice, code: "agent-picked",
    text: "From your next message on, " & c.adapterFor(name).label & " is the producer. It has its own conversation, so it reads the game's notes (PLAN.md) to pick things up; it can't see what the other one said."))
  Started(ok: true, status: 200)
