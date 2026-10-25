# The producer's chat inside `para studio`: any number of chats per game and agent, one turn at a time.
#
# This file knows the agent only through agent.nim's `AgentAdapter`: it hands the adapter the
# friend's message, collects the `UiEvent`s the adapter emits into a numbered list the page polls
# (`GET /api/chat?since=N`, the same polling the Check and Save steps use), keeps each chat's
# session id and its lines in chatstore.nim's files so a restart, a reopened page or picking the
# chat again from the list shows the chat as it was and resumes the same conversation, and stops a
# turn (the Stop button, a timeout, or the studio closing).
#
# A turn runs on its own thread, with a second small thread watching the clock. Nothing is sent to
# the agent unless the friend sends a message: opening the page, polling, even a reload start no
# turn and so cost nothing.
#
# Each agent keeps its own chats (chatstore.nim: `tmp/studio/chats-<game>-<agent>.json`, each chat's
# title, times and session id), and the page lists the chats of the agent the game talks to. One
# agent's id is never handed to another, which could not use it. The agent a game talks to is
# remembered in `tmp/studio/agent-<game>.txt` (its name and nothing else); a game with no pick uses
# the studio's default, the first adapter.
#
# Every line the page shows is also added to its chat's file (chatstore.nim:
# `tmp/studio/chat-<game>-<agent>-<number>.jsonl`, keys taken out), so a chat opened again, or the
# one open when the studio starts, shows its earlier lines read back from that file. A chat from
# before lines were kept has no file: its lines are rebuilt once from the agent's own record of the
# conversation (`AgentAdapter.pastTurns`, read-only, only that one conversation) and written to the
# file; with no such record it gets a plain note instead. These files stay on this computer and
# go when the chat is deleted; no login or key is ever written.

import std/[locks, os, sequtils, strutils, tables, times]
import agent
import chatstore
import savepoint

const
  maxMessageChars* = 8000
  maxEvents = 8000 ## chat lines kept in memory; the oldest go first (a chat opened again is read back from its file)
  defaultTurnSeconds* = 3600

type
  ChatKey = tuple[game, agent: string, chat: int] ## which chat a line belongs to

  ChatEntry = object
    seq: int
    key: ChatKey
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
    turnKey: ChatKey
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
    bookLock: Lock ## the chat lists below and their files; never held together with `lock`
    books: Table[string, ChatBook] ## by "<game>/<agent>", read from disk the first time
    storeLock: Lock ## held while a line is added to memory and its chat's file, or a chat is read back, so the two keep the same order
    noteLock: Lock ## held while owed chats are taken and read back, so no other line gets in between
    notes: seq[ChatKey] ## chats open when their book was read from disk, still owed their earlier lines

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
  initLock(c.bookLock)
  initLock(c.storeLock)
  initLock(c.noteLock)
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

# --- the chat lists ---------------------------------------------------------------

proc bookOf(c: ptr ChatState, game, agent: string): ChatBook =
  ## A copy of `game`'s chats with `agent`. Called with `bookLock` held.
  let k = game & "/" & agent
  if k notin c.books:
    let b = loadBook(c.root, game, agent)
    c.books[k] = b
    if b.find(b.current) >= 0 or fileExists(logPath(c.root, game, agent, b.current)):
      c.notes.add (game, agent, b.current)
  c.books[k]

proc keep(c: ptr ChatState, game, agent: string, b: ChatBook) =
  ## Remembers `b` and writes it down. Called with `bookLock` held.
  c.books[game & "/" & agent] = b
  discard saveBook(c.root, game, agent, b) # if the disk refuses, the chats last until the studio closes

proc readSession*(root, game, agent: string): string =
  ## The session id the next message in `game`'s current chat with `agent` resumes, "" for a new
  ## conversation (read from disk, for tests and tools; the studio itself keeps the list in memory).
  let b = loadBook(root, game, agent)
  let i = b.find(b.current)
  if i >= 0: b.chats[i].session else: ""

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

proc currentKey(c: ptr ChatState, game: string): ChatKey =
  ## The chat `game`'s page shows now: its producer's current chat.
  let agent = agentOf(c, game)
  acquire(c.bookLock)
  let b = c.bookOf(game, agent)
  release(c.bookLock)
  (game, agent, b.current)

# --- the event list -----------------------------------------------------------------

proc push(c: ptr ChatState, key: ChatKey, ev: UiEvent, you = false) =
  ## Puts a line on the page (in memory only).
  acquire(c.lock)
  c.entries.add ChatEntry(seq: c.nextSeq, key: key, you: you, ev: ev)
  inc c.nextSeq
  if c.entries.len > maxEvents: c.entries = c.entries[c.entries.len - maxEvents .. ^1]
  release(c.lock)

const backNote = UiEvent(kind: ukNotice, code: "chat-opened",
  text: "This chat's earlier messages are not kept on this computer. The conversation continues from where it left off, so just carry on.")

proc kept(ev: UiEvent): bool =
  ## Whether a line goes into its chat's file: not the end-of-turn marker, and of a helper card only
  ## where it started and how it ended.
  ev.kind != ukTurnDone and not (ev.kind == ukHelper and ev.status == "working")

proc restore(c: ptr ChatState, key: ChatKey) =
  ## Shows chat `key` as its file has it: whatever memory holds of it is replaced by the lines read
  ## back. A listed chat with no file (one from before lines were kept) gets its lines rebuilt from
  ## the agent's own record of the conversation, or the plain note when there is none, and either is
  ## written to the file so this happens once. A fresh chat with no file shows nothing.
  acquire(c.bookLock)
  let b = c.bookOf(key.game, key.agent)
  let i = b.find(key.chat)
  let listed = i >= 0
  let session = if listed: b.chats[i].session else: ""
  release(c.bookLock)
  acquire(c.storeLock)
  defer: release(c.storeLock)
  var (found, lines) = readLines(c.root, key.game, key.agent, key.chat)
  if not found and listed:
    let a = c.adapterFor(key.agent)
    if session.len > 0 and a.name == key.agent and not a.pastTurns.isNil:
      {.cast(gcsafe).}:
        try: lines = a.pastTurns(a, c.root, session)
        except CatchableError: lines = @[]
    if lines.len == 0: lines = @[(you: false, ev: backNote)]
    lines = lines.mapIt(asKept(it)) # as the file has them: keys out, long ones cut
    discard writeLines(c.root, key.game, key.agent, key.chat, lines) # if the disk refuses, this runs again next time
  acquire(c.lock)
  var others: seq[ChatEntry]
  for e in c.entries:
    if e.key != key: others.add e
  c.entries = others
  release(c.lock)
  for line in lines: c.push(key, line.ev, line.you)

proc flushNotes(c: ptr ChatState) =
  ## Reads back the chats owed their earlier lines, so those come before any other line.
  acquire(c.noteLock)
  defer: release(c.noteLock)
  acquire(c.bookLock)
  let owed = c.notes
  c.notes = @[]
  release(c.bookLock)
  for key in owed: c.restore(key)

proc add(c: ptr ChatState, key: ChatKey, ev: UiEvent, you = false) =
  ## Puts a line on the page and in its chat's file.
  c.flushNotes()
  acquire(c.storeLock)
  c.push(key, ev, you)
  if ev.kept: discard appendLine(c.root, key.game, key.agent, key.chat, (you: you, ev: ev)) # if the disk refuses, it shows until the studio closes
  release(c.storeLock)

proc addCard*(c: ptr ChatState, game: string, ev: UiEvent) =
  ## A line the studio itself puts in `game`'s current chat (a screenshot card): not from the
  ## agent, so it works with no turn running.
  c.add(c.currentKey(game), ev)

proc setChatSession(c: ptr ChatState, key: ChatKey, id: string) =
  acquire(c.bookLock)
  var b = c.bookOf(key.game, key.agent)
  if b.setSession(key.chat, id): c.keep(key.game, key.agent, b)
  release(c.bookLock)

# --- a turn -------------------------------------------------------------------------

proc turnMain(c: ptr ChatState) {.thread.} =
  var adapter: AgentAdapter
  var req: TurnRequest
  var key: ChatKey
  var ctl: ptr TurnControl
  var timeoutSec: int
  acquire(c.lock)
  adapter = c.adapterFor(c.turnKey.agent)
  key = c.turnKey
  req = TurnRequest(text: c.turnText, sessionId: c.turnSession, workDir: c.root)
  ctl = c.ctl
  timeoutSec = c.timeoutSec
  release(c.lock)
  {.cast(gcsafe).}:
    req.onSession = proc (id: string) = c.setChatSession(key, id)
    var res: TurnResult
    try:
      res = adapter.runTurn(adapter, req, ctl, proc (ev: UiEvent) = c.add(key, ev))
    except CatchableError as e:
      c.add(key, UiEvent(kind: ukError, code: "crashed",
        text: "The studio hit a problem while talking to the producer's tool: " & oneLine(redactSecrets(e.msg), 200)))
    let reason = ctl.cancelReason
    var done = UiEvent(kind: ukTurnDone, text: "")
    if res.cancelled and reason == "timeout":
      c.add(key, UiEvent(kind: ukError, code: "timeout",
        text: "This turn ran longer than " & (if timeoutSec >= 120: $(timeoutSec div 60) & " minutes" elif timeoutSec >= 60: "a minute" else: $timeoutSec & (if timeoutSec == 1: " second" else: " seconds")) & ", so I stopped it. Anything a helper already changed is still in the game folder. Ask the producer where things stand."))
      done.text = "timeout"
    elif res.cancelled:
      c.add(key, UiEvent(kind: ukNotice, code: "stopped",
        text: "Stopped. Anything a helper already changed is still in the game folder. Ask the producer where things stand."))
      done.text = "stopped"
    elif res.ok: done.text = "ok"
    else: done.text = "failed"
    c.add(key, done)
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
  acquire(c.bookLock)
  var b = c.bookOf(game, agentName)
  let session = b.noteMessage(text, epochTime().int64)
  c.keep(game, agentName, b)
  release(c.bookLock)
  let key: ChatKey = (game, agentName, b.current)
  acquire(c.lock)
  c.running = true
  inc c.turnId
  c.turnKey = key
  c.turnText = text
  c.turnSession = session
  c.startedAt = epochTime()
  c.ctl = newTurnControl()
  result = Started(ok: true, status: 200, turnId: c.turnId)
  release(c.lock)
  c.add(key, UiEvent(kind: ukSay, text: text.strip), you = true)
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
  ## The next message in `game` starts a new chat with its producer; the earlier ones stay in the
  ## list. False while a turn runs.
  if not validGameName(game): return false
  acquire(c.startLock)
  defer: release(c.startLock)
  if isRunning(c): return false
  let agent = agentOf(c, game)
  acquire(c.bookLock)
  var b = c.bookOf(game, agent)
  b.freshChat()
  c.keep(game, agent, b)
  release(c.bookLock)
  true

proc openChat*(c: ptr ChatState, game: string, id: int): Started =
  ## The next message in `game` goes to chat `id` and resumes its conversation, and the page shows
  ## its earlier lines, read back from its file. Refused while a turn runs.
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  acquire(c.startLock)
  defer: release(c.startLock)
  if isRunning(c):
    return Started(status: 409, code: "busy", message: "The producer is working on your last message. Wait for it, or press Stop, then open the chat.")
  let agent = agentOf(c, game)
  acquire(c.bookLock)
  var b = c.bookOf(game, agent)
  let was = b.current
  let found = b.openChat(id)
  if found and was != id: c.keep(game, agent, b)
  release(c.bookLock)
  if not found:
    return Started(status: 404, code: "no-such-chat", message: "That chat is not in the list any more.")
  if was != id:
    c.flushNotes()
    c.restore((game, agent, id))
  Started(ok: true, status: 200)

proc deleteChat*(c: ptr ChatState, game: string, id: int): Started =
  ## Forgets chat `id` from `game`'s list (its title, times and session id) and its lines, on the
  ## page and in its file. Nothing in the game's folder is touched, nor the agent's own record of
  ## the conversation. Refused while a turn runs.
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  acquire(c.startLock)
  defer: release(c.startLock)
  if isRunning(c):
    return Started(status: 409, code: "busy", message: "The producer is working on your last message. Wait for it, or press Stop, then delete the chat.")
  let agent = agentOf(c, game)
  acquire(c.bookLock)
  var b = c.bookOf(game, agent)
  let found = b.dropChat(id)
  if found: c.keep(game, agent, b)
  release(c.bookLock)
  if not found:
    return Started(status: 404, code: "no-such-chat", message: "That chat is not in the list any more.")
  c.flushNotes()
  let key: ChatKey = (game, agent, id)
  acquire(c.storeLock)
  dropLines(c.root, game, agent, id)
  acquire(c.lock)
  var others: seq[ChatEntry]
  for e in c.entries:
    if e.key != key: others.add e
  c.entries = others
  release(c.lock)
  release(c.storeLock)
  Started(ok: true, status: 200)

type
  ChatList* = object
    agent*: string
    current*: int
    chats*: seq[ChatRecord] ## newest first

proc listChats*(c: ptr ChatState, game: string): ChatList =
  ## `game`'s chats with the producer it talks to now, the one used last first.
  let agent = agentOf(c, game)
  acquire(c.bookLock)
  let b = c.bookOf(game, agent)
  release(c.bookLock)
  ChatList(agent: agent, current: b.current, chats: b.newestFirst)

# --- what the page reads ------------------------------------------------------------

type
  ChatView* = object
    running*: bool
    turnId*: int
    next*: int
    chat*: int ## the chat these lines are from
    entries*: seq[tuple[seq: int, you: bool, ev: UiEvent]]

proc view*(c: ptr ChatState, game: string, since: int): ChatView =
  ## The lines after `since` of the chat `game`'s page shows now.
  let key = c.currentKey(game)
  c.flushNotes()
  acquire(c.lock)
  defer: release(c.lock)
  result.running = c.running
  result.turnId = c.turnId
  result.next = c.nextSeq - 1
  result.chat = key.chat
  for e in c.entries:
    if e.seq > since and e.key == key: result.entries.add (e.seq, e.you, e.ev)

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
  ## own chats, so switching back later picks up where that agent left off. Refused while a turn
  ## runs (it would be talking to the other one).
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
  c.add(c.currentKey(game), UiEvent(kind: ukNotice, code: "agent-picked",
    text: "From your next message on, " & c.adapterFor(name).label & " is the producer. It has its own chats, so it reads the game's notes (PLAN.md) to pick things up; it can't see what the other one said."))
  Started(ok: true, status: 200)
