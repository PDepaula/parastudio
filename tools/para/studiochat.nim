# The producer's chat inside `para studio`: any number of chats per game and agent, one turn at a
# time for each game (two games can each have a turn running; a second message to the same game
# waits for the first).
#
# This file knows the agent only through agent.nim's `AgentAdapter`: it hands the adapter the
# friend's message, collects the `UiEvent`s the adapter emits into a numbered list the page polls
# (`GET /api/chat?since=N`, the same polling the Check and Save steps use), keeps each chat's
# session id and its lines in chatstore.nim's files so a restart, a reopened page or picking the
# chat again from the list shows the chat as it was and resumes the same conversation, and stops a
# turn (the Stop button, a timeout, or the studio closing).
#
# A turn runs on its own thread, with a second small thread watching the clock; each game's turn
# has threads, a control and a clock of its own, so Stop and the time limit act on that game only. Nothing is sent to
# the agent unless the friend sends a message: opening the page, polling, even a reload start no
# turn and so cost nothing.
#
# What may happen now (one turn per game, no message while that game's step runs, no producer, speed
# or chat change during that game's turn, ...) is decided by the desk in studiodesk.nim, a pure core
# written with eversince. This file is its shell: ONE lock (`ChatState.lock`) serialises the desk's
# runtime, every command is `execute`d and every question `answer`ed under it, and the shell's own
# threads (a turn thread, its clock) hand their results back as commands (`AddLine`, `EndTurn`).
# Only plain values leave the lock: no JSON tree is ever handed to another thread. A chat's lines are
# the desk's events; chatstore.nim's `ChatFilesStore` keeps them in the chat's file (keys out, size
# cap, forgotten with the chat).
#
# Each agent keeps its own chats (chatstore.nim: `tmp/studio/chats-<game>-<agent>.json`, each chat's
# title, times and session id), and the page lists the chats of the agent the game talks to. One
# agent's id is never handed to another, which could not use it. The agent a game talks to is
# remembered in `tmp/studio/agent-<game>.txt` (its name and nothing else); a game with no pick uses
# the studio-wide pick in `tmp/studio/default-agent.txt` (made in the first-run setup checklist,
# before any game exists), else the first adapter. How hard the producer thinks is the game's
# "producer speed" (quick, standard or deep), remembered the same way in `tmp/studio/speed-<game>.txt`
# (default standard, which passes no model and no effort); each turn takes the speed in force when
# it starts, and the adapter turns it into its agent's own model and effort flags. What was asked
# for and what the agent then reported are kept for each game and agent, for the line on the page.
#
# Every line the page shows is also added to its chat's file (chatstore.nim:
# `tmp/studio/chat-<game>-<agent>-<number>.jsonl`, keys taken out), so a chat opened again, or the
# one open when the studio starts, shows its earlier lines read back from that file. A chat from
# before lines were kept has no file: its lines are rebuilt once from the agent's own record of the
# conversation (`AgentAdapter.pastTurns`, read-only, only that one conversation) and written to the
# file; with no such record it gets a plain note instead. These files stay on this computer and
# go when the chat is deleted; no login or key is ever written.

import std/[json, locks, os, sequtils, strutils, tables, times]
import eversince/[types, runtime]
import agent
import chatstore
import savepoint
import studiodesk
from studiodesk import maxMessageChars, validMessage, DeskFacts
export maxMessageChars, validMessage, DeskFacts

const
  defaultTurnSeconds* = 3600

type
  ChatKey = tuple[game, agent: string, chat: int] ## which chat a line belongs to

  RanWith* = object
    ## What a game's producer (one agent) did its last turn with.
    started*: bool         ## a turn has run (the fields below mean something)
    speed*: Speed          ## the speed that turn started with
    askedModel*, askedEffort*: string ## what the studio passed ("" = left to the agent)
    model*, effort*: string ## what the agent reported ("" = it did not say)

  Turn = object
    ## One game's turn: made by `startTurn`, kept (finished) until that game's next turn or the end.
    chat: ptr ChatState
    id: int
    key: ChatKey
    text: string
    session: string
    speed: Speed
    startedAt: float
    stopping: int ## stop requests currently inside `cancel`
    ctl: ptr TurnControl
    turnThread: Thread[ptr Turn]
    watchThread: Thread[ptr Turn]
    threadsStarted: bool

  ChatState* = object
    lock: Lock ## the ONE lock: it serialises the desk's runtime (`desk`) and guards the records below
    desk: Runtime[StudioDesk] ## studiodesk.nim's rules, the views and the chats' lines; only ever touched under `lock`
    adapters: seq[AgentAdapter] ## the first is the default
    root: string
    timeoutSec: int
    turns: Table[string, ptr Turn] ## by game: the running turn, or the last one that ended
    infos: Table[string, tuple[info: AgentInfo, at: float]]
    models: Table[string, RanWith] ## by "<game>/<agent>": what its last turn asked for and said it ran with (under `lock`)
    bookLock: Lock ## the chat lists below and their files; never held together with `lock`
    books: Table[string, ChatBook] ## by "<game>/<agent>", read from disk the first time
    noteLock: Lock ## held while owed chats are taken and read back, so no other line gets in between
    notes: seq[ChatKey] ## chats open when their book was read from disk, still owed their earlier lines

  Started* = object
    ok*: bool
    status*: int
    code*, message*: string
    turnId*: int ## StartTurn: the turn's number; StartStep: the step's

proc initChat*(c: ptr ChatState, root: string, adapters: seq[AgentAdapter], timeoutSec = defaultTurnSeconds) =
  ## `adapters` are the agents the page may pick from, the default first.
  doAssert adapters.len > 0
  initLock(c.lock)
  initLock(c.bookLock)
  initLock(c.noteLock)
  c.root = root
  c.adapters = adapters
  c.timeoutSec = timeoutSec
  let files = newChatFiles(root)
  c.desk = Runtime[StudioDesk](store: files, clock: proc (): int64 = (epochTime() * 1000).int64)
  c.desk.seq = files.highestSeq() # the log goes on from where an earlier run of the studio left it

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

proc defaultPickPath(root: string): string =
  ## Where the studio-wide pick lives. It does not start with "agent-", so no game's name can reach it.
  root / "tmp" / "studio" / "default-agent.txt"

proc pickedIn(c: ptr ChatState, path: string): string =
  ## The agent named in the file at `path` if it still exists, else "".
  try:
    let name = readFile(path).strip
    for a in c.adapters:
      if a.name == name: return name
  except IOError, OSError:
    discard

proc agentOf*(c: ptr ChatState, game: string): string =
  ## The agent `game`'s chat talks to: the one the friend picked for it if that still exists, else
  ## the one picked for the whole studio (made before any game exists, in the setup checklist), else
  ## the built-in default. With no game (`""`) it is the studio-wide pick.
  if validGameName(game):
    let own = pickedIn(c, pickPath(c.root, game))
    if own.len > 0: return own
  let studioWide = pickedIn(c, defaultPickPath(c.root))
  if studioWide.len > 0: return studioWide
  c.adapters[0].name

# --- the producer's speed for a game -------------------------------------------------

proc speedPath(root, game: string): string =
  root / "tmp" / "studio" / ("speed-" & game & ".txt")

proc speedOf*(c: ptr ChatState, game: string): Speed =
  ## The speed `game`'s next turn runs at: the one the friend picked for it, else standard. A game
  ## with no name (or a file that says something else) is standard.
  if validGameName(game):
    try:
      let (ok, sp) = parseSpeed(readFile(speedPath(c.root, game)).strip)
      if ok: return sp
    except IOError, OSError:
      discard
  spStandard

proc currentKey(c: ptr ChatState, game: string): ChatKey =
  ## The chat `game`'s page shows now: its producer's current chat.
  let agent = agentOf(c, game)
  acquire(c.bookLock)
  let b = c.bookOf(game, agent)
  release(c.bookLock)
  (game, agent, b.current)

# --- the desk ------------------------------------------------------------------------
# Everything below that asks "may this happen?" asks the desk, with `lock` held.

proc refusal(d: Decision): Started =
  ## A refused command as the studio's answer: the one table from a refusal's word to the status and
  ## the word the page acts on.
  let (status, code) = case d.code
    of "busy": (409, "busy")
    of "tooBusy": (409, "too-busy")
    of "badMessage": (400, "bad-message")
    of "needsMessage": (400, "needs-message")
    of "staleTurn", "staleStep": (409, "busy")
    else: (409, d.code)
  Started(status: status, code: code, message: d.message)

proc run(c: ptr ChatState, name: string, data: JsonNode): Decision =
  ## One command through the runtime. Called with `lock` held.
  {.cast(gcsafe).}:
    result = c.desk.execute(name, data)

proc nowFacts(c: ptr ChatState, game: string): DeskFacts =
  ## The desk's answer about `game` (and every game, and the step). Called with `lock` held.
  {.cast(gcsafe).}:
    result = answer(DeskNow(game: game), c.desk.app.desk)

proc deskFacts*(c: ptr ChatState, game = ""): DeskFacts =
  ## What the desk says now: every game with a turn, `game`'s turn, the step. Plain values.
  acquire(c.lock)
  defer: release(c.lock)
  c.nowFacts(game)

# --- the event list -----------------------------------------------------------------

const backNote = UiEvent(kind: ukNotice, code: "chat-opened",
  text: "This chat's earlier messages are not kept on this computer. The conversation continues from where it left off, so just carry on.")

proc restoreLocked(c: ptr ChatState, key: ChatKey, read: ChatRead, persist: bool) =
  ## The page shows chat `key` as `read` has it: whatever the Chat view held of it is replaced.
  ## Called with `lock` held.
  discard c.run("RestoreChat", %*{"game": key.game, "agent": key.agent, "chat": key.chat,
    "lines": read.lines.mapIt(lineBody(it)), "lastN": read.lastN, "persist": persist})

proc restore(c: ptr ChatState, key: ChatKey) =
  ## Shows chat `key` as its file has it: whatever the page held of it is replaced by the lines read
  ## back. A listed chat with no file (one from before lines were kept) gets its lines rebuilt from
  ## the agent's own record of the conversation, or the plain note when there is none, and either is
  ## written to the file so this happens once. A fresh chat with no file shows nothing.
  acquire(c.bookLock)
  let b = c.bookOf(key.game, key.agent)
  let i = b.find(key.chat)
  let listed = i >= 0
  let session = if listed: b.chats[i].session else: ""
  release(c.bookLock)
  acquire(c.lock)
  var read = readChat(c.root, key.game, key.agent, key.chat)
  if read.found or not listed:
    c.restoreLocked(key, read, persist = false)
    release(c.lock)
    return
  release(c.lock) # the agent's record can take a moment to read: not under the lock
  var lines: seq[ChatLine]
  let a = c.adapterFor(key.agent)
  if session.len > 0 and a.name == key.agent and not a.pastTurns.isNil:
    {.cast(gcsafe).}:
      try: lines = a.pastTurns(a, c.root, session)
      except CatchableError: lines = @[]
  if lines.len == 0: lines = @[(you: false, ev: backNote)]
  lines = lines.mapIt(asKept(it)) # as the file has them: keys out, long ones cut
  acquire(c.lock)
  defer: release(c.lock)
  read = readChat(c.root, key.game, key.agent, key.chat) # a line may have been written meanwhile
  if read.found:
    c.restoreLocked(key, read, persist = false)
  else:
    c.restoreLocked(key, ChatRead(lines: lines), persist = true) # the desk writes them as new lines

proc flushNotes(c: ptr ChatState) =
  ## Reads back the chats owed their earlier lines, so those come before any other line. Called
  ## with `lock` free.
  acquire(c.noteLock)
  defer: release(c.noteLock)
  acquire(c.bookLock)
  let owed = c.notes
  c.notes = @[]
  release(c.bookLock)
  for key in owed: c.restore(key)

proc addLocked(c: ptr ChatState, key: ChatKey, ev: UiEvent, you = false) =
  ## Puts a line on the page and in its chat's file. Called with `lock` held.
  discard c.run("AddLine", %*{"game": key.game, "agent": key.agent, "chat": key.chat,
    "line": lineBody((you: you, ev: ev))})

proc add(c: ptr ChatState, key: ChatKey, ev: UiEvent, you = false) =
  ## Puts a line on the page and in its chat's file. Called with `lock` free.
  c.flushNotes()
  acquire(c.lock)
  defer: release(c.lock)
  c.addLocked(key, ev, you)

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

proc turnMain(t: ptr Turn) {.thread.} =
  let c = t.chat
  var adapter: AgentAdapter
  var req: TurnRequest
  var key: ChatKey
  var ctl: ptr TurnControl
  var timeoutSec: int
  acquire(c.lock)
  adapter = c.adapterFor(t.key.agent)
  key = t.key
  req = TurnRequest(text: t.text, sessionId: t.session, workDir: c.root, speed: t.speed)
  ctl = t.ctl
  timeoutSec = c.timeoutSec
  release(c.lock)
  {.cast(gcsafe).}:
    req.onSession = proc (id: string) = c.setChatSession(key, id)
    let ranKey = key.game & "/" & key.agent
    let speed = req.speed
    req.onAsked = proc (model, effort: string) =
      acquire(c.lock)
      # a new turn: what it asked for is known now; what the agent says follows
      c.models[ranKey] = RanWith(started: true, speed: speed, askedModel: model, askedEffort: effort)
      release(c.lock)
    req.onModel = proc (model, effort: string) =
      acquire(c.lock)
      var r = c.models.getOrDefault(ranKey)
      r.started = true
      r.speed = speed
      r.model = model
      r.effort = effort
      c.models[ranKey] = r
      release(c.lock)
    var res: TurnResult
    try:
      res = adapter.runTurn(adapter, req, ctl, proc (ev: UiEvent) = c.add(key, ev))
    except CatchableError as e:
      c.add(key, UiEvent(kind: ukError, code: "crashed",
        text: "The studio hit a problem while talking to the producer's tool: " & oneLine(redactSecrets(e.msg), 200)))
    let reason = ctl.cancelReason
    var outcome = ""
    if res.cancelled and reason == "timeout":
      c.add(key, UiEvent(kind: ukError, code: "timeout",
        text: "This turn ran longer than " & (if timeoutSec >= 120: $(timeoutSec div 60) & " minutes" elif timeoutSec >= 60: "a minute" else: $timeoutSec & (if timeoutSec == 1: " second" else: " seconds")) & ", so I stopped it. Anything a helper already changed is still in the game folder. Ask the producer where things stand."))
      outcome = "timeout"
    elif res.cancelled:
      c.add(key, UiEvent(kind: ukNotice, code: "stopped",
        text: "Stopped. Anything a helper already changed is still in the game folder. Ask the producer where things stand."))
      outcome = "stopped"
    elif res.ok: outcome = "ok"
    else: outcome = "failed"
    # the turn is over: the game is free and the page gets its end-of-turn line, in one command
    acquire(c.lock)
    discard c.run("EndTurn", %*{"game": key.game, "agent": key.agent, "chat": key.chat, "turn": t.id, "outcome": outcome})
    release(c.lock)

proc watchMain(t: ptr Turn) {.thread.} =
  let c = t.chat
  var ctl: ptr TurnControl
  var until: float
  var game: string
  acquire(c.lock)
  ctl = t.ctl
  until = t.startedAt + c.timeoutSec.float
  game = t.key.game
  release(c.lock)
  while true:
    sleep(200)
    acquire(c.lock)
    let still = c.nowFacts(game).turn == t.id # the desk says whether this turn still runs
    release(c.lock)
    if not still: return
    if epochTime() > until:
      ctl.cancel("timeout")
      return

proc reap(t: ptr Turn) =
  ## Joins an ended turn's threads, frees its control and the turn itself. Only called for a turn
  ## that is no longer running and no longer in `turns`.
  let c = t.chat
  while true:
    acquire(c.lock)
    let busy = t.stopping > 0
    release(c.lock)
    if not busy: break
    sleep(10)
  if t.threadsStarted:
    joinThread(t.turnThread)
    joinThread(t.watchThread)
    t.threadsStarted = false
  if t.ctl != nil:
    freeTurnControl(t.ctl)
    t.ctl = nil
  t.text = ""
  t.session = ""
  t.key = (game: "", agent: "", chat: 0)
  dealloc(t)

proc takeEnded(c: ptr ChatState, game: string): ptr Turn =
  ## The ended turn `game` last had, taken out of the list (nil when it has none). Called with `lock`
  ## held and no turn of `game` running.
  result = c.turns.getOrDefault(game, nil)
  if result != nil: c.turns.del(game)

proc isRunning*(c: ptr ChatState, game: string): bool =
  ## Whether `game` has a turn running.
  c.deskFacts(game).running

proc runningGames*(c: ptr ChatState): seq[string] =
  ## The games that have a turn running, by name.
  c.deskFacts().working

proc isRunning*(c: ptr ChatState): bool = c.runningGames.len > 0

proc startTurn*(c: ptr ChatState, game, text: string, busyGames: seq[string] = @[]): Started =
  ## One turn of `game`'s producer. `busyGames` are the other games whose helpers are building (the
  ## caller looked them up: that is on disk, not a fact the desk has). The desk decides; what is
  ## accepted is then done here: the chat's title, the turn's record, its threads.
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  discard c.currentKey(game) # reads the game's chat list, and so queues the earlier lines it owes
  c.flushNotes()
  acquire(c.lock)
  let agentName = agentOf(c, game)
  acquire(c.bookLock)
  var b = c.bookOf(game, agentName)
  release(c.bookLock)
  let decision = c.run("StartTurn", %*{"game": game, "agent": agentName, "chat": b.current, "text": text, "busyGames": busyGames})
  if decision.refused:
    release(c.lock)
    return refusal(decision)
  # accepted: the game's turn is now the desk's, so no other change to this game gets in
  let turnId = decision.events[0].data["turn"].getInt
  acquire(c.bookLock)
  b = c.bookOf(game, agentName)
  let session = b.noteMessage(text, epochTime().int64)
  c.keep(game, agentName, b)
  release(c.bookLock)
  let key: ChatKey = (game, agentName, b.current)
  let was = c.takeEnded(game)
  let t = create(Turn)
  t.chat = c
  t.key = key
  t.text = text
  t.session = session
  t.speed = speedOf(c, game)
  t.startedAt = epochTime()
  t.ctl = newTurnControl()
  t.id = turnId
  c.turns[game] = t
  release(c.lock)
  if was != nil: reap(was)
  try:
    createThread(t.turnThread, turnMain, t)
    createThread(t.watchThread, watchMain, t)
    t.threadsStarted = true
  except CatchableError:
    acquire(c.lock)
    discard c.run("EndTurn", %*{"game": game, "agent": agentName, "chat": key.chat, "turn": turnId, "outcome": "failed"})
    discard c.takeEnded(game)
    release(c.lock)
    reap(t)
    return Started(status: 500, code: "spawn", message: "The studio could not start that turn.")
  Started(ok: true, status: 200, turnId: turnId)

proc stopTurn*(c: ptr ChatState, game: string): bool =
  ## True when `game` had a turn to stop (other games' turns go on). Returns once the child is gone
  ## (or after a short grace).
  var ctl: ptr TurnControl
  var t: ptr Turn
  acquire(c.lock)
  t = c.turns.getOrDefault(game, nil)
  if t != nil and t.ctl != nil and c.nowFacts(game).turn == t.id:
    ctl = t.ctl
    inc t.stopping
  release(c.lock)
  if ctl == nil: return false
  ctl.cancel("stop")
  acquire(c.lock)
  dec t.stopping
  release(c.lock)
  true

proc shutdownChat*(c: ptr ChatState) =
  ## The studio is closing: end every running turn so no claude is left behind.
  for game in c.runningGames: discard stopTurn(c, game)
  for _ in 0 ..< 100: # up to 10 s for the turn threads to wind down
    if not isRunning(c): break
    sleep(100)
  if not isRunning(c):
    acquire(c.lock)
    var ended: seq[ptr Turn]
    for game, t in c.turns: ended.add t
    c.turns.clear()
    release(c.lock)
    for t in ended: reap(t)

proc newConversation*(c: ptr ChatState, game: string): bool =
  ## The next message in `game` starts a new chat with its producer; the earlier ones stay in the
  ## list. False while this game's turn runs.
  if not validGameName(game): return false
  acquire(c.lock)
  defer: release(c.lock)
  if c.run("NewChat", %*{"game": game}).refused: return false
  let agent = agentOf(c, game)
  acquire(c.bookLock)
  var b = c.bookOf(game, agent)
  b.freshChat()
  c.keep(game, agent, b)
  release(c.bookLock)
  true

proc openChat*(c: ptr ChatState, game: string, id: int): Started =
  ## The next message in `game` goes to chat `id` and resumes its conversation, and the page shows
  ## its earlier lines, read back from its file. Refused while this game's turn runs.
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  acquire(c.lock)
  let decision = c.run("OpenChat", %*{"game": game, "chat": id})
  if decision.refused:
    release(c.lock)
    return refusal(decision)
  let agent = agentOf(c, game)
  acquire(c.bookLock)
  var b = c.bookOf(game, agent)
  let was = b.current
  let found = b.openChat(id)
  if found and was != id: c.keep(game, agent, b)
  release(c.bookLock)
  release(c.lock)
  if not found:
    return Started(status: 404, code: "no-such-chat", message: "That chat is not in the list any more.")
  if was != id:
    c.flushNotes()
    c.restore((game, agent, id))
  Started(ok: true, status: 200)

proc deleteChat*(c: ptr ChatState, game: string, id: int): Started =
  ## Forgets chat `id` from `game`'s list (its title, times and session id) and its lines, on the
  ## page and in its file. Nothing in the game's folder is touched, nor the agent's own record of
  ## the conversation. Refused while this game's turn runs.
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  discard c.currentKey(game) # reads the game's chat list, and so queues the earlier lines it owes...
  c.flushNotes() # ...which are read back first, so none of them comes back after the delete
  acquire(c.lock)
  defer: release(c.lock)
  let agent = agentOf(c, game)
  let decision = c.run("DeleteChat", %*{"game": game, "agent": agent, "chat": id}) # the lines go with this command
  if decision.refused: return refusal(decision)
  acquire(c.bookLock)
  var b = c.bookOf(game, agent)
  let found = b.dropChat(id)
  if found: c.keep(game, agent, b)
  release(c.bookLock)
  if not found:
    return Started(status: 404, code: "no-such-chat", message: "That chat is not in the list any more.")
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
    running*: bool ## whether the asked game has a turn running
    working*: seq[string] ## every game with a turn running
    turnId*: int ## the asked game's last turn (0 before its first)
    next*: int
    chat*: int ## the chat these lines are from
    model*, effort*: string ## what the producer of this chat said it ran its last turn with; "" until it has run one
    speed*: string ## the speed the game's next turn runs at
    ran*: RanWith ## the game's producer's last turn: the speed it started with, what was asked for, what it reported
    entries*: seq[tuple[seq: int, you: bool, ev: UiEvent]]

proc view*(c: ptr ChatState, game: string, since: int): ChatView =
  ## The lines after `since` of the chat `game`'s page shows now.
  let key = c.currentKey(game)
  c.flushNotes()
  acquire(c.lock)
  defer: release(c.lock)
  var page: ChatPage
  {.cast(gcsafe).}:
    page = answer(ChatSince(game: key.game, agent: key.agent, chat: key.chat, since: since), c.desk.app.chat, c.desk.app.desk)
  result.running = page.running
  result.turnId = page.turn
  result.working = page.working
  result.next = page.next
  result.speed = $speedOf(c, game)
  result.chat = key.chat
  result.ran = c.models.getOrDefault(key.game & "/" & key.agent)
  result.model = result.ran.model
  result.effort = result.ran.effort
  for e in page.entries:
    var line: ChatLine
    if lineOfBody(%e.line, line, allowDone = true): result.entries.add (e.seq, line.you, line.ev)

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

proc agentModel*(c: ptr ChatState, game, name: string): RanWith =
  ## What `name` did `game`'s last turn in this run of the studio with: the speed it started at, the
  ## model and effort the studio asked for, and the ones the agent reported. Empty before the first
  ## message.
  let adapter = c.adapterFor(name)
  acquire(c.lock)
  result = c.models.getOrDefault(game & "/" & adapter.name)
  release(c.lock)

proc speedAbout*(c: ptr ChatState, name: string, speed: Speed): string =
  ## What `speed` asks of agent `name`, in a few plain words ("" for an agent with no speeds).
  let adapter = c.adapterFor(name)
  if adapter.speedAbout.isNil: "" else: adapter.speedAbout(speed)

proc pickSpeed*(c: ptr ChatState, game, name: string): Started =
  ## Makes `name` ("quick", "standard" or "deep") the speed of `game`'s producer, from the next
  ## message on. Refused while this game's turn runs (it keeps the speed it started with).
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  let (ok, speed) = parseSpeed(name)
  if not ok:
    return Started(status: 400, code: "which-speed", message: "That is not one of the speeds: Quick, Standard or Deep.")
  discard c.currentKey(game)
  c.flushNotes()
  acquire(c.lock)
  defer: release(c.lock)
  let decision = c.run("PickSpeed", %*{"game": game, "speed": $speed})
  if decision.refused: return refusal(decision)
  if speedOf(c, game) == speed: return Started(ok: true, status: 200)
  let path = speedPath(c.root, game)
  try:
    createDir(path.parentDir)
    writeFile(path & ".new", $speed)
    moveFile(path & ".new", path)
  except IOError, OSError:
    return Started(status: 500, code: "cannot-save", message: "I could not remember that pick (is the disk full?).")
  let agent = agentOf(c, game)
  let about = c.speedAbout(agent, speed)
  c.addLocked(c.currentKey(game), UiEvent(kind: ukNotice, code: "speed-picked",
    text: "From your next message on, the producer runs at " & speedLabels[speed] & " speed" & (if about.len > 0: ": " & about else: "") & "."))
  Started(ok: true, status: 200)

proc agentLabel*(c: ptr ChatState, name: string): string = c.adapterFor(name).label
proc agentCost*(c: ptr ChatState, name: string): string = c.adapterFor(name).cost
proc agentAbout*(c: ptr ChatState, name: string): string = c.adapterFor(name).about
proc timeoutMinutes*(c: ptr ChatState): int = c.timeoutSec div 60

proc pickAgent*(c: ptr ChatState, game, name: string): Started =
  ## Makes `name` the agent `game`'s chat talks to, from the next message on. Each agent keeps its
  ## own chats, so switching back later picks up where that agent left off. Refused while this game's
  ## turn runs (it would be talking to the other one).
  let wide = game.len == 0 # no game: the pick for the whole studio, used until a game has its own
  if not wide and not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  if name notin c.agentNames:
    return Started(status: 400, code: "which-agent", message: "That is not one of the producers this studio knows.")
  if not wide:
    discard c.currentKey(game)
    c.flushNotes()
  acquire(c.lock)
  defer: release(c.lock)
  let decision = c.run("PickProducer", %*{"game": game, "agent": name}) # the studio-wide pick waits for every turn
  if decision.refused: return refusal(decision)
  if agentOf(c, game) == name: return Started(ok: true, status: 200)
  let path = if wide: defaultPickPath(c.root) else: pickPath(c.root, game)
  try:
    createDir(path.parentDir)
    writeFile(path & ".new", name)
    moveFile(path & ".new", path)
  except IOError, OSError:
    return Started(status: 500, code: "cannot-save", message: "I could not remember that pick (is the disk full?).")
  if wide: return Started(ok: true, status: 200)
  c.addLocked(c.currentKey(game), UiEvent(kind: ukNotice, code: "agent-picked",
    text: "From your next message on, " & c.adapterFor(name).label & " is the producer. It has its own chats, so it reads the game's notes (PLAN.md) to pick things up; it can't see what the other one said."))
  Started(ok: true, status: 200)

# --- the steps -------------------------------------------------------------------------
# A Check, Save, Land, Backup or New step is run by studioapi.nim (a child process on its own
# thread); whether it may start, and when it is over, is the desk's, so a step and a turn never
# decide at the same moment.

proc startStep*(c: ptr ChatState, game, kind, message: string): Started =
  ## The desk's answer to "may this step start": `turnId` is the step's number when it may.
  acquire(c.lock)
  defer: release(c.lock)
  let decision = c.run("StartStep", %*{"game": game, "kind": kind, "message": message})
  if decision.refused: return refusal(decision)
  Started(ok: true, status: 200, turnId: decision.events[0].data["step"].getInt)

proc endStep*(c: ptr ChatState, step, code: int) =
  ## Step `step` is over (a number that is not the running step is ignored).
  acquire(c.lock)
  defer: release(c.lock)
  discard c.run("EndStep", %*{"step": step, "code": code})
