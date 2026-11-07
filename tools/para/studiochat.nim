# The producer's chat inside `para studio`: any number of chats per game and agent, one turn at a
# time for each game (two games can each have a turn running; a second message to the same game
# waits for the first).
#
# This file knows the agent only through agent.nim's `AgentAdapter`: it hands the adapter the
# friend's message, collects the `UiEvent`s the adapter emits into a numbered list the page polls
# (`GET /api/chat?since=N`, the same polling the Check and Save steps use), keeps each chat's
# session id (the desk's book, in studio.jsonl) and its lines (its own file, chatstore.nim) so a
# restart, a reopened page or picking the chat again from the list shows the chat as it was and
# resumes the same conversation, and stops a turn (the Stop button, a timeout, or the studio closing).
#
# A turn runs on its own thread, with a second small thread watching the clock; each game's turn
# has threads, a control and a clock of its own, so Stop and the time limit act on that game only. Nothing is sent to
# the agent unless the friend sends a message: opening the page, polling, even a reload start no
# turn and so cost nothing.
#
# The threads are the desk's processors (studiodesk.nim): once the desk accepts a turn, the fact
# TurnStarted makes TurnRunner start the turn thread and TurnClock the clock thread, and the fact
# StopRequested (what the command StopTurn makes, for the Stop button and for the studio closing) makes
# TurnRunner have the turn's child ended; a step's StepStarted does the same for the job thread
# and its clock (studioapi.nim). They run inside the command call, with the one lock held, so each only
# STARTS a thread: ending a child waits for it, so that is a small thread of its own, and no processor
# waits for anything. The turn's record (control, threads, session, speed) is this file's table, `turns`;
# what the processors need of it that the facts do not carry (the message, the session id, the speed)
# is worked out by `startTurn` before the command and handed over in `pending`.
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
# Each agent keeps its own chats (the desk's `ChatBook` view: each chat's title, times and session
# id), and the page lists the chats of the agent the game talks to. One agent's id is never handed to
# another, which could not use it. The agent a game talks to is the desk's `Desk.picks`: the one
# picked for the game, else the studio-wide pick (made in the first-run setup checklist, before any
# game exists), else the first adapter. How hard the producer thinks is the game's "producer speed"
# (quick, standard or deep), the desk's `Desk.speeds` (default standard, which passes no model and no
# effort); each turn takes the speed in force when it starts, and the adapter turns it into its
# agent's own model and effort flags. What was asked for and what the agent then reported are the
# `Producers` view, for the line on the page. The book, the picks and that line are events that
# survive a restart: chatstore.nim keeps them in `tmp/studio/studio.jsonl` and `initChat` replays that
# file (and only that file) when the studio starts, then moves the files older studios kept
# (`chats-*.json`, `session-*.id`, `agent-*.txt`, `speed-*.txt`, `default-agent.txt`) into it, once.
#
# Every line the page shows is also added to its chat's file (chatstore.nim:
# `tmp/studio/chat-<game>-<agent>-<number>.jsonl`, keys taken out), so a chat opened again, or the
# one open when the studio starts, shows its earlier lines read back from that file. A chat from
# before lines were kept has no file: its lines are rebuilt once from the agent's own record of the
# conversation (`AgentAdapter.pastTurns`, read-only, only that one conversation) and written to the
# file; with no such record it gets a plain note instead. These files stay on this computer and
# go when the chat is deleted; no login or key is ever written.

import std/[json, locks, os, sequtils, sets, tables, times]
import eversince/[types, runtime, store]
import agent
import chatstore
import savepoint
import studiodesk
from studiodesk import maxMessageChars, validMessage, DeskFacts, JobFacts, StepStarted
export maxMessageChars, validMessage, DeskFacts, JobFacts, StepStarted

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

  PendingTurn = object
    ## What `startTurn` worked out for the turn the desk is about to accept, for the processors to take.
    text: string
    session: string
    speed: Speed

  Turn = object
    ## One game's turn: made by the processors on TurnStarted, kept (finished) until that game's next
    ## turn or the end.
    chat: ptr ChatState
    id: int
    key: ChatKey
    text: string
    session: string
    speed: Speed
    startedAt: float
    stopping: int ## holders of the record while a stop is under way: the stopper thread, a `stopTurn` waiting for it
    cancelling: int ## stopper threads inside `cancel`
    ctl: ptr TurnControl
    turnThread: Thread[ptr Turn]
    watchThread: Thread[ptr Turn]
    stopThread: Thread[ptr Turn]
    turnStarted, watchStarted, stopStarted: bool
    spawnFailed: bool ## a thread of this turn could not be started

  StepHooks* = object
    ## What the shell that runs steps (studioapi.nim) does for the processors StepRunner and StepClock.
    data*: pointer
    run*, watch*: proc (data: pointer, e: StepStarted): bool {.nimcall, gcsafe.} ## start the job thread, and its clock

  ChatState* = object
    lock: Lock ## the ONE lock: it serialises the desk's runtime (`desk`: the rules, the views, the book, the picks) and guards the records below
    desk: Runtime[StudioDesk] ## studiodesk.nim's rules, the views and the chats' lines; only ever touched under `lock`
    adapters: seq[AgentAdapter] ## the first is the default
    root: string
    timeoutSec: int
    files: ChatFilesStore ## the store behind `desk`
    turns: Table[string, ptr Turn] ## by game: the running turn, or the last one that ended
    pending: Table[string, PendingTurn] ## by game: handed to the processors by `startTurn`, for the length of its command (under `lock`)
    ended: seq[ptr Turn] ## the ended turns a new turn of their game replaced, for `startTurn` to reap with the lock free
    steps: StepHooks
    infos: Table[string, tuple[info: AgentInfo, at: float]]
    shown: HashSet[string] ## the chats ("<game>/<agent>/<chat>") whose earlier lines the Chat view holds, or that have none (under `lock`)
    migrated: HashSet[string] ## the books ("<game>/<agent>") already checked for files an older studio left (under `lock`)

  Started* = object
    ok*: bool
    status*: int
    code*, message*: string
    turnId*: int ## StartTurn: the turn's number; StartStep: the step's

proc agentNames*(c: ptr ChatState): seq[string] =
  for a in c.adapters: result.add a.name

proc adapterFor(c: ptr ChatState, name: string): AgentAdapter =
  for a in c.adapters:
    if a.name == name: return a
  c.adapters[0]

proc setHands(c: ptr ChatState) {.gcsafe.}

proc run(c: ptr ChatState, name: string, data: JsonNode): Decision =
  ## One command through the runtime. Called with `lock` held. The processors the command wakes run
  ## inside it, on this thread, and reach this state through `hands`.
  {.cast(gcsafe).}:
    c.setHands()
    result = c.desk.execute(name, data)

proc inject(c: ptr ChatState, kind: string, data: JsonNode) =
  ## An event of an older studio's files, written to the log as it is and folded into the views: it
  ## is a fact that already happened, so no command decides it. Called with `lock` held.
  {.cast(gcsafe).}:
    let e = Envelope(seq: c.desk.seq + 1, at: c.desk.clock(), kind: kind, data: data)
    c.desk.store.append([e])
    c.desk.seq += 1
    try: apply(c.desk.app, e)
    except CatchableError: discard

proc knownAgent(c: ptr ChatState, name: string): bool =
  for a in c.adapters:
    if a.name == name: return true

proc moveOldPicks(c: ptr ChatState) =
  ## The producer and speed picks an older studio kept in `agent-<game>.txt`, `speed-<game>.txt` and
  ## `default-agent.txt` become events, once, and the files go. A name that is not an agent or a
  ## speed is left out (and its file goes too); a pick the log already has is not overwritten.
  let old = oldPicks(c.root)
  c.files.failed = false
  proc have(c: ptr ChatState, game: string): bool =
    for p in c.desk.app.desk.picks:
      if p.game == game: return true
  if old.wide.len > 0 and c.knownAgent(old.wide) and not c.have(""):
    c.inject("AgentPicked", %*{"game": "", "agent": old.wide})
  for (game, name) in old.agents:
    if validGameName(game) and c.knownAgent(name) and not c.have(game):
      c.inject("AgentPicked", %*{"game": game, "agent": name})
  for (game, name) in old.speeds:
    let (ok, speed) = parseSpeed(name)
    var known = false
    for p in c.desk.app.desk.speeds:
      if p.game == game: known = true
    if validGameName(game) and ok and not known:
      c.inject("SpeedPicked", %*{"game": game, "speed": $speed})
  if not c.files.failed: removeOldPicks(c.root)

proc moveOldBook(c: ptr ChatState, game, agent: string) =
  ## `game`'s chats with `agent` as an older studio kept them (a book file, or one session id in a
  ## file of its own) become events, once, and the files go. Called with `lock` held.
  let k = game & "/" & agent
  if k in c.migrated: return
  c.migrated.incl k
  if not hasOldBook(c.root, game, agent): return
  let b = loadBook(c.root, game, agent)
  c.files.failed = false
  for (kind, data) in oldBookEvents(game, agent, b, epochTime().int64): c.inject(kind, data)
  if not c.files.failed: removeOldBook(c.root, game, agent) # if the disk refused, the files stay for the next start

proc moveOldFiles(c: ptr ChatState) =
  ## Everything an older studio kept in files moves into the log. The studio calls it once, at start.
  acquire(c.lock)
  defer: release(c.lock)
  for (game, agent) in oldBooks(c.root): c.moveOldBook(game, agent)
  c.moveOldPicks()

proc initChat*(c: ptr ChatState, root: string, adapters: seq[AgentAdapter], timeoutSec = defaultTurnSeconds) =
  ## `adapters` are the agents the page may pick from, the default first.
  doAssert adapters.len > 0
  initLock(c.lock)
  c.root = root
  c.adapters = adapters
  c.timeoutSec = timeoutSec
  c.files = newChatFiles(root)
  c.desk = Runtime[StudioDesk](store: c.files, clock: proc (): int64 = (epochTime() * 1000).int64)
  for e in c.files.loadStudio(): # the studio's own events only (a few lines per chat and pick); chats are read when opened
    try: apply(c.desk.app, e)
    except CatchableError: discard # an event that does not fit its type is left out: the studio still starts
  c.desk.seq = c.files.highestSeq() # the log goes on from where an earlier run of the studio left it
  c.moveOldFiles() # what an older studio kept in files becomes events, once

# --- the chat lists ---------------------------------------------------------------

proc bookIn(c: ptr ChatState, game, agent: string): Book =
  ## A copy of `game`'s chats with `agent`. Called with `lock` held.
  c.moveOldBook(game, agent) # a file an older studio left since the studio started is moved now
  {.cast(gcsafe).}:
    result = c.desk.app.chatBook.books.bookOf(game, agent)

proc sessionIn(c: ptr ChatState, game, agent: string, chat: int): string =
  ## The session id chat `chat` resumes, "" for a new conversation. It goes on to a command line, so
  ## it passes `validSessionToken` here too, whatever a hand-edited log says. Called with `lock` held.
  let b = c.bookIn(game, agent)
  let i = b.find(chat)
  if i >= 0: validSessionToken(b.chats[i].session) else: ""

proc readSession*(root, game, agent: string): string =
  ## The session id the next message in `game`'s current chat with `agent` resumes, "" for a new
  ## conversation (read from disk, for tests and tools; the studio itself keeps the book in the desk).
  if not validGameName(game) or not validAgentName(agent): return
  var app: StudioDesk
  for e in newChatFiles(root).loadStudio():
    try: apply(app, e)
    except CatchableError: discard
  let book = app.chatBook.books.bookOf(game, agent)
  let at = book.find(book.current)
  if at >= 0: return validSessionToken(book.chats[at].session)
  let b = loadBook(root, game, agent) # a book an older studio kept, not moved yet
  let i = b.find(b.current)
  if i >= 0: b.chats[i].session else: ""

# --- the agent a game talks to ------------------------------------------------------

proc agentIn(c: ptr ChatState, game: string): string =
  ## The agent `game`'s chat talks to: the one the friend picked for it if that still exists, else
  ## the one picked for the whole studio (made before any game exists, in the setup checklist), else
  ## the built-in default. With no game (`""`) it is the studio-wide pick. Called with `lock` held.
  {.cast(gcsafe).}:
    if validGameName(game):
      for p in c.desk.app.desk.picks:
        if p.game == game and c.knownAgent(p.agent): return p.agent
    for p in c.desk.app.desk.picks:
      if p.game == "" and c.knownAgent(p.agent): return p.agent
  c.adapters[0].name

proc agentOf*(c: ptr ChatState, game: string): string =
  acquire(c.lock)
  defer: release(c.lock)
  c.agentIn(game)

# --- the producer's speed for a game -------------------------------------------------

proc speedIn(c: ptr ChatState, game: string): Speed =
  ## The speed `game`'s next turn runs at: the one the friend picked for it, else standard. A game
  ## with no name is standard. Called with `lock` held.
  if validGameName(game):
    {.cast(gcsafe).}:
      for p in c.desk.app.desk.speeds:
        if p.game == game:
          let (ok, sp) = parseSpeed(p.speed)
          if ok: return sp
  spStandard

proc speedOf*(c: ptr ChatState, game: string): Speed =
  acquire(c.lock)
  defer: release(c.lock)
  c.speedIn(game)

proc currentIn(c: ptr ChatState, game: string): ChatKey =
  ## The chat `game`'s page shows now: its producer's current chat. Called with `lock` held.
  let agent = c.agentIn(game)
  (game, agent, c.bookIn(game, agent).current)

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
    of "needsName": (400, "needs-name")
    of "badName": (400, "bad-name")
    of "taken": (409, "exists")
    of "noSuchLane": (404, "no-such-lane")
    of "noSource": (404, "no-source")
    of "otherGame": (409, "other-game")
    of "notRunning": (409, "no-window")
    else: (409, d.code)
  Started(status: status, code: code, message: d.message)

proc nowFacts(c: ptr ChatState, game: string): DeskFacts =
  ## The desk's answer about `game` (and every game, and the step). Called with `lock` held.
  {.cast(gcsafe).}:
    result = answer(DeskNow(game: game), c.desk.app.desk)

proc jobNow*(c: ptr ChatState): JobFacts =
  ## The step the desk knows of: running now, or the last one that ended (step 0 before the first).
  acquire(c.lock)
  defer: release(c.lock)
  {.cast(gcsafe).}:
    result = answer(JobNow(), c.desk.app.desk)

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

proc keyOf(key: ChatKey): string = key.game & "/" & key.agent & "/" & $key.chat

proc restore(c: ptr ChatState, key: ChatKey) =
  ## Shows chat `key` as its file has it: whatever the page held of it is replaced by the lines read
  ## back. A listed chat with no file (one from before lines were kept) gets its lines rebuilt from
  ## the agent's own record of the conversation, or the plain note when there is none, and either is
  ## written to the file so this happens once. A fresh chat with no file shows nothing. Called with
  ## `lock` free.
  acquire(c.lock)
  let b = c.bookIn(key.game, key.agent)
  let i = b.find(key.chat)
  let listed = i >= 0
  let session = if listed: c.sessionIn(key.game, key.agent, key.chat) else: ""
  var read = readChat(c.root, key.game, key.agent, key.chat)
  if read.found or not listed:
    c.restoreLocked(key, read, persist = false)
    c.shown.incl key.keyOf
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
  c.shown.incl key.keyOf

proc settle(c: ptr ChatState, game: string): ChatKey =
  ## The chat `game`'s page shows now, with its earlier lines read back first when this run has not
  ## yet (the Chat view starts empty: a chat's lines come from its file when it is first looked at).
  ## Called with `lock` free, before anything is added to that chat.
  acquire(c.lock)
  let key = c.currentIn(game)
  var owed = false
  if key.keyOf notin c.shown:
    owed = c.bookIn(key.game, key.agent).find(key.chat) >= 0 or fileExists(logPath(c.root, key.game, key.agent, key.chat))
    if not owed: c.shown.incl key.keyOf # a fresh chat has nothing to read back
  release(c.lock)
  if owed: c.restore(key)
  key

proc addLocked(c: ptr ChatState, key: ChatKey, ev: UiEvent, you = false) =
  ## Puts a line on the page and in its chat's file. Called with `lock` held.
  discard c.run("AddLine", %*{"game": key.game, "agent": key.agent, "chat": key.chat,
    "line": lineBody((you: you, ev: ev))})

proc add(c: ptr ChatState, key: ChatKey, ev: UiEvent, you = false) =
  ## Puts a line on the page and in its chat's file. Called with `lock` free.
  acquire(c.lock)
  defer: release(c.lock)
  c.addLocked(key, ev, you)

proc addCard*(c: ptr ChatState, game: string, ev: UiEvent) =
  ## A line the studio itself puts in `game`'s current chat (a screenshot card): not from the
  ## agent, so it works with no turn running.
  c.add(c.settle(game), ev)

proc giveBack(c: ptr ChatState, who: typedesc, cmd: auto): Decision =
  ## A processor's thread gives a command back, through that processor's one door (`handBack` in
  ## studiodesk.nim: only the commands its `issues` line lists go in). Called with `lock` held.
  let (name, data) = handBack(who, cmd)
  c.run(name, data)

proc reportSession(c: ptr ChatState, key: ChatKey, id: string) =
  ## The agent named its session: the desk keeps it (and refuses an id a command line could not take).
  acquire(c.lock)
  defer: release(c.lock)
  discard c.giveBack(TurnRunner, ReportSession(game: key.game, agent: key.agent, chat: key.chat, session: id))

proc ranWith(r: Ran): RanWith =
  let (ok, speed) = parseSpeed(r.speed)
  RanWith(started: r.started, speed: if ok: speed else: spStandard, askedModel: r.askedModel, askedEffort: r.askedEffort,
    model: r.model, effort: r.effort)

proc ranIn(c: ptr ChatState, game, agent: string): RanWith =
  ## What `agent` did `game`'s last turn with, from the desk's `Producers` view. Called with `lock` held.
  {.cast(gcsafe).}:
    result = ranWith(answer(ProducerNow(game: game, agent: agent), c.desk.app.producers))

proc reportAsked(c: ptr ChatState, key: ChatKey, speed: Speed, model, effort: string) =
  ## A new turn: what it asked for is known now; what the agent says follows.
  acquire(c.lock)
  defer: release(c.lock)
  discard c.giveBack(TurnRunner, ReportModel(game: key.game, agent: key.agent, speed: $speed, askedModel: model,
    askedEffort: effort, model: "", effort: ""))

proc reportRan(c: ptr ChatState, key: ChatKey, speed: Speed, model, effort: string) =
  ## The agent said what it runs this turn with; what was asked for stays.
  acquire(c.lock)
  defer: release(c.lock)
  let was = c.ranIn(key.game, key.agent)
  discard c.giveBack(TurnRunner, ReportModel(game: key.game, agent: key.agent, speed: $speed, askedModel: was.askedModel,
    askedEffort: was.askedEffort, model: model, effort: effort))

# --- a turn -------------------------------------------------------------------------
# TurnRunner and TurnClock (studiodesk.nim) start these threads; `turnMain` and `watchMain` are what
# they run, and `stopMain` is what ends a turn's child when StopRequested says so.

proc addFromTurn(c: ptr ChatState, key: ChatKey, ev: UiEvent) =
  ## The turn thread puts a line on the page and in its chat's file.
  acquire(c.lock)
  defer: release(c.lock)
  discard c.giveBack(TurnRunner, AddLine(game: key.game, agent: key.agent, chat: key.chat, line: lineBody((you: false, ev: ev)).to(LineBody)))

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
    req.onSession = proc (id: string) = c.reportSession(key, id)
    let speed = req.speed
    req.onAsked = proc (model, effort: string) = c.reportAsked(key, speed, model, effort)
    req.onModel = proc (model, effort: string) = c.reportRan(key, speed, model, effort)
    var res: TurnResult
    try:
      res = adapter.runTurn(adapter, req, ctl, proc (ev: UiEvent) = c.addFromTurn(key, ev))
    except CatchableError as e:
      c.addFromTurn(key, UiEvent(kind: ukError, code: "crashed",
        text: "The studio hit a problem while talking to the producer's tool: " & oneLine(redactSecrets(e.msg), 200)))
    let reason = ctl.cancelReason
    var outcome = ""
    if res.cancelled and reason == "timeout":
      c.addFromTurn(key, UiEvent(kind: ukError, code: "timeout",
        text: "This turn ran longer than " & (if timeoutSec >= 120: $(timeoutSec div 60) & " minutes" elif timeoutSec >= 60: "a minute" else: $timeoutSec & (if timeoutSec == 1: " second" else: " seconds")) & ", so I stopped it. Anything a helper already changed is still in the game folder. Ask the producer where things stand."))
      outcome = "timeout"
    elif res.cancelled:
      c.addFromTurn(key, UiEvent(kind: ukNotice, code: "stopped",
        text: "Stopped. Anything a helper already changed is still in the game folder. Ask the producer where things stand."))
      outcome = "stopped"
    elif res.ok: outcome = "ok"
    else: outcome = "failed"
    # the turn is over: the game is free and the page gets its end-of-turn line, in one command
    acquire(c.lock)
    discard c.giveBack(TurnRunner, EndTurn(game: key.game, agent: key.agent, chat: key.chat, turn: t.id, outcome: outcome))
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

proc stopMain(t: ptr Turn) {.thread.} =
  ## Ends the turn's child. `cancel` waits for it (up to a short grace), so this is a thread and not
  ## the processor, which runs under the lock and may not wait.
  let c = t.chat
  var ctl: ptr TurnControl
  acquire(c.lock)
  ctl = t.ctl
  release(c.lock)
  {.cast(gcsafe).}:
    ctl.cancel("stop")
  acquire(c.lock)
  dec t.cancelling
  dec t.stopping
  release(c.lock)

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
  if t.turnStarted: joinThread(t.turnThread)
  if t.watchStarted: joinThread(t.watchThread)
  if t.stopStarted: joinThread(t.stopThread)
  t.turnStarted = false
  t.watchStarted = false
  t.stopStarted = false
  if t.ctl != nil:
    freeTurnControl(t.ctl)
    t.ctl = nil
  t.text = ""
  t.session = ""
  t.key = (game: "", agent: "", chat: 0)
  dealloc(t)

proc turnFor(c: ptr ChatState, e: TurnStarted): ptr Turn =
  ## The shell's record of turn `e`: made on first use from what `startTurn` handed over, and the same
  ## record for the second processor that asks. nil for a turn `startTurn` did not prepare. The game's
  ## earlier, ended turn is set aside for `startTurn` to reap once the lock is free. Called with `lock` held.
  result = c.turns.getOrDefault(e.game, nil)
  if result != nil and result.id == e.turn: return
  if e.game notin c.pending: return nil
  let p = c.pending[e.game]
  if result != nil: c.ended.add result
  let t = create(Turn)
  t.chat = c
  t.key = (e.game, e.agent, e.chat)
  t.text = p.text
  t.session = p.session
  t.speed = p.speed
  t.startedAt = epochTime()
  t.ctl = newTurnControl()
  t.id = e.turn
  c.turns[e.game] = t
  result = t

proc runTurnThread(state: pointer, e: TurnStarted): bool {.nimcall, gcsafe.} =
  ## TurnRunner on TurnStarted: starts the turn thread. False when it could not. Lock held; never waits.
  let c = cast[ptr ChatState](state)
  let t = c.turnFor(e)
  if t == nil or t.spawnFailed: return true # nothing prepared, or the clock could not start and so the turn does not run
  try:
    createThread(t.turnThread, turnMain, t)
    t.turnStarted = true
  except CatchableError:
    t.spawnFailed = true
    return false
  true

proc watchTurnThread(state: pointer, e: TurnStarted): bool {.nimcall, gcsafe.} =
  ## TurnClock on TurnStarted: starts the clock thread. False when it could not. Lock held; never waits.
  let c = cast[ptr ChatState](state)
  let t = c.turnFor(e)
  if t == nil: return true
  try:
    createThread(t.watchThread, watchMain, t)
    t.watchStarted = true
  except CatchableError:
    t.spawnFailed = true
    return false
  true

proc stopTurnChild(state: pointer, e: StopRequested) {.nimcall, gcsafe.} =
  ## TurnRunner on StopRequested: has that turn's child ended, by a thread of its own (`cancel` waits
  ## for the child). A request for a turn that is not this game's running one, or already over, or that
  ## never ran, is ignored. Lock held; never waits.
  let c = cast[ptr ChatState](state)
  let t = c.turns.getOrDefault(e.game, nil)
  if t == nil or t.id != e.turn or t.ctl == nil or not t.turnStarted or t.stopStarted: return
  if c.desk.app.desk.turnOf(e.game) != e.turn: return
  inc t.stopping
  inc t.cancelling
  try:
    createThread(t.stopThread, stopMain, t)
    t.stopStarted = true
  except CatchableError:
    dec t.stopping
    dec t.cancelling

proc runStepThread(state: pointer, e: StepStarted): bool {.nimcall, gcsafe.} =
  let c = cast[ptr ChatState](state)
  c.steps.run == nil or c.steps.run(c.steps.data, e)

proc watchStepThread(state: pointer, e: StepStarted): bool {.nimcall, gcsafe.} =
  let c = cast[ptr ChatState](state)
  c.steps.watch == nil or c.steps.watch(c.steps.data, e)

proc setHands(c: ptr ChatState) =
  ## What the desk's processors do, for the command about to run on this thread.
  hands = Hands(state: c, runTurn: runTurnThread, watchTurn: watchTurnThread, endTurn: stopTurnChild,
    runStep: runStepThread, watchStep: watchStepThread)

proc setSteps*(c: ptr ChatState, hooks: StepHooks) =
  ## The shell that runs steps says how StepRunner and StepClock start theirs (studioapi.nim).
  acquire(c.lock)
  defer: release(c.lock)
  c.steps = hooks

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
  ## accepted is then done here: the chat's title, and the processors (they run inside the command)
  ## start the turn's threads from the record this makes ready.
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  discard c.settle(game) # the chat's earlier lines come first
  acquire(c.lock)
  let agentName = c.agentIn(game)
  let b = c.bookIn(game, agentName)
  c.pending[game] = PendingTurn(text: text, session: c.sessionIn(game, agentName, b.current), speed: c.speedIn(game))
  let decision = c.run("StartTurn", %*{"game": game, "agent": agentName, "chat": b.current, "text": text, "busyGames": busyGames})
  c.pending.del(game)
  if decision.refused:
    release(c.lock)
    return refusal(decision)
  # accepted: the game's turn is now the desk's, so no other change to this game gets in
  let turnId = decision.events[0].data["turn"].getInt
  discard c.run("UseChat", %*{"game": game, "agent": agentName, "chat": b.current, "title": titleOf(text)}) # names a new chat, marks it used now
  var dead = c.ended # the turns this one replaced
  c.ended = @[]
  let t = c.turns.getOrDefault(game, nil)
  let spawned = t != nil and t.id == turnId and not t.spawnFailed
  if not spawned and t != nil and t.id == turnId: # a thread could not be started: the processors ended the turn as failed
    dead.add c.takeEnded(game)
  release(c.lock)
  for d in dead: reap(d)
  if not spawned:
    return Started(status: 500, code: "spawn", message: "The studio could not start that turn.")
  Started(ok: true, status: 200, turnId: turnId)

proc stopTurn*(c: ptr ChatState, game: string): bool =
  ## True when `game` had a turn to stop (other games' turns go on): the command StopTurn is accepted,
  ## and TurnRunner has that turn's child ended. Returns once the child is gone (or after a short grace).
  acquire(c.lock)
  let decision = c.run("StopTurn", %*{"game": game})
  if decision.refused:
    release(c.lock)
    return false
  let t = c.turns.getOrDefault(game, nil)
  if t != nil: inc t.stopping # the record stays while this waits for the stop
  release(c.lock)
  if t == nil: return true
  while true: # the stopper thread does the waiting; this only watches it, with the lock free
    acquire(c.lock)
    let going = t.cancelling > 0
    release(c.lock)
    if not going: break
    sleep(10)
  acquire(c.lock)
  dec t.stopping
  release(c.lock)
  true

proc giveAgain*(c: ptr ChatState, processor: string, e: Envelope) =
  ## Gives one fact to one processor again, whatever its position, and handles the commands it issues
  ## (the kit's `redeliver`: what a restart does behind the scenes). A StopRequested for a turn that is
  ## over, or no longer that game's, changes nothing; this is how a test shows it.
  acquire(c.lock)
  defer: release(c.lock)
  {.cast(gcsafe).}:
    c.setHands()
    c.desk.redeliver(processor, e)

proc shutdownChat*(c: ptr ChatState) =
  ## The studio is closing: end every running turn so no claude is left behind.
  for game in c.runningGames: discard stopTurn(c, game)
  for _ in 0 ..< 100: # up to 10 s for the turn threads to wind down
    if not isRunning(c): break
    sleep(100)
  if not isRunning(c):
    acquire(c.lock)
    var ended = c.ended
    c.ended = @[]
    for game, t in c.turns: ended.add t
    c.turns.clear()
    release(c.lock)
    for t in ended: reap(t)
    acquire(c.lock)
    c.files.close() # every file the studio holds open is let go (a later write opens it again)
    release(c.lock)

proc newConversation*(c: ptr ChatState, game: string): bool =
  ## The next message in `game` starts a new chat with its producer; the earlier ones stay in the
  ## list. False while this game's turn runs.
  if not validGameName(game): return false
  acquire(c.lock)
  defer: release(c.lock)
  not c.run("NewChat", %*{"game": game, "agent": c.agentIn(game)}).refused

proc openChat*(c: ptr ChatState, game: string, id: int): Started =
  ## The next message in `game` goes to chat `id` and resumes its conversation, and the page shows
  ## its earlier lines, read back from its file. Refused while this game's turn runs.
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  acquire(c.lock)
  let agent = c.agentIn(game)
  let b = c.bookIn(game, agent)
  let listed = b.find(id) >= 0
  let was = b.current
  let decision = c.run("OpenChat", %*{"game": game, "chat": id, "agent": agent})
  release(c.lock)
  if decision.refused: return refusal(decision)
  if not listed:
    return Started(status: 404, code: "no-such-chat", message: "That chat is not in the list any more.")
  if was != id: c.restore((game, agent, id))
  Started(ok: true, status: 200)

proc deleteChat*(c: ptr ChatState, game: string, id: int): Started =
  ## Forgets chat `id` from `game`'s list (its title, times and session id) and its lines, on the
  ## page and in its file. Nothing in the game's folder is touched, nor the agent's own record of
  ## the conversation. Refused while this game's turn runs.
  if not validGameName(game):
    return Started(status: 400, code: "which-game", message: "Say which game this is about.")
  discard c.settle(game) # the chat's earlier lines are read back first, so none of them comes back after the delete
  acquire(c.lock)
  defer: release(c.lock)
  let agent = c.agentIn(game)
  let listed = c.bookIn(game, agent).find(id) >= 0
  let decision = c.run("DeleteChat", %*{"game": game, "agent": agent, "chat": id}) # the lines and the id go with this command
  if decision.refused: return refusal(decision)
  c.shown.excl (game, agent, id).keyOf
  if not listed:
    return Started(status: 404, code: "no-such-chat", message: "That chat is not in the list any more.")
  Started(ok: true, status: 200)

type
  ChatList* = object
    agent*: string
    current*: int
    chats*: seq[studiodesk.ChatRecord] ## newest first

proc listChats*(c: ptr ChatState, game: string): ChatList =
  ## `game`'s chats with the producer it talks to now, the one used last first.
  acquire(c.lock)
  defer: release(c.lock)
  let agent = c.agentIn(game)
  discard c.bookIn(game, agent)
  var l: ChatListing
  {.cast(gcsafe).}:
    l = answer(studiodesk.ChatList(game: game, agent: agent), c.desk.app.chatBook)
  ChatList(agent: l.agent, current: l.current, chats: l.chats)

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
  let key = c.settle(game)
  acquire(c.lock)
  defer: release(c.lock)
  var page: ChatPage
  {.cast(gcsafe).}:
    page = answer(ChatSince(game: key.game, agent: key.agent, chat: key.chat, since: since), c.desk.app.chat, c.desk.app.desk)
  result.running = page.running
  result.turnId = page.turn
  result.working = page.working
  result.next = page.next
  result.speed = $c.speedIn(game)
  result.chat = key.chat
  result.ran = c.ranIn(key.game, key.agent)
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
  ## What `name` did `game`'s last turn with (it survives a restart): the speed it started at, the
  ## model and effort the studio asked for, and the ones the agent reported. Empty before the first
  ## message.
  let adapter = c.adapterFor(name)
  acquire(c.lock)
  result = c.ranIn(game, adapter.name)
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
  discard c.settle(game)
  acquire(c.lock)
  defer: release(c.lock)
  c.files.failed = false
  let decision = c.run("PickSpeed", %*{"game": game, "speed": $speed})
  if decision.refused: return refusal(decision)
  if decision.events.len == 0: return Started(ok: true, status: 200) # the same speed again says nothing more
  if c.files.failed:
    return Started(status: 500, code: "cannot-save", message: "I could not remember that pick (is the disk full?).")
  let agent = c.agentIn(game)
  let about = c.speedAbout(agent, speed)
  c.addLocked(c.currentIn(game), UiEvent(kind: ukNotice, code: "speed-picked",
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
  if not wide: discard c.settle(game)
  acquire(c.lock)
  defer: release(c.lock)
  let before = c.agentIn(game)
  c.files.failed = false
  let decision = c.run("PickProducer", %*{"game": game, "agent": name}) # the studio-wide pick waits for every turn
  if decision.refused: return refusal(decision)
  if decision.events.len == 0 or before == name: return Started(ok: true, status: 200) # the same pick again says nothing more
  if c.files.failed:
    return Started(status: 500, code: "cannot-save", message: "I could not remember that pick (is the disk full?).")
  if wide: return Started(ok: true, status: 200)
  c.addLocked(c.currentIn(game), UiEvent(kind: ukNotice, code: "agent-picked",
    text: "From your next message on, " & c.adapterFor(name).label & " is the producer. It has its own chats, so it reads the game's notes (PLAN.md) to pick things up; it can't see what the other one said."))
  Started(ok: true, status: 200)

# --- the steps -------------------------------------------------------------------------
# A Check, Save, Land, Backup or New step is run by studioapi.nim (a child process on its own
# thread); whether it may start, and when it is over, is the desk's, so a step and a turn never
# decide at the same moment.

proc startedStep(c: ptr ChatState, name: string, data: JsonNode): Started =
  ## One of the commands that starts a step, through the desk. Called with `lock` held.
  let decision = c.run(name, data)
  if decision.refused: return refusal(decision)
  Started(ok: true, status: 200, turnId: decision.events[0].data["step"].getInt)

proc startStep*(c: ptr ChatState, game, kind, message: string): Started =
  ## The desk's answer to "may this step start": `turnId` is the step's number when it may.
  acquire(c.lock)
  defer: release(c.lock)
  c.startedStep("StartStep", %*{"game": game, "kind": kind, "message": message})

proc startNewGame*(c: ptr ChatState, name: string, existing: seq[string]): Started =
  ## The desk's answer to "may a game called `name` be made": `existing` are the games there are
  ## (the caller looked in the games folder).
  acquire(c.lock)
  defer: release(c.lock)
  c.startedStep("NewGame", %*{"name": name, "existing": existing})

proc startLand*(c: ptr ChatState, game, lane: string, lanes: seq[string]): Started =
  ## The desk's answer to "may this helper's work go into the game": `lanes` are the game's helpers'
  ## work (the caller looked next to the game's folder).
  acquire(c.lock)
  defer: release(c.lock)
  c.startedStep("LandLane", %*{"game": game, "lane": lane, "lanes": lanes})

proc askPlay*(c: ptr ChatState, game: string, hasSource: bool): Started =
  ## The desk's answer to "may Play open this game": `hasSource` is whether its source file is there.
  acquire(c.lock)
  defer: release(c.lock)
  let decision = c.run("StartPlay", %*{"game": game, "hasSource": hasSource})
  if decision.refused: return refusal(decision)
  Started(ok: true, status: 200, turnId: decision.events[0].data["run"].getInt)

proc askShot*(c: ptr ChatState, game, windowGame: string, windowRunning: bool): Started =
  ## The desk's answer to "may a picture be asked of the game window": `windowGame` is the game of
  ## the window that is starting or running ("" when none) and `windowRunning` whether it answers.
  acquire(c.lock)
  defer: release(c.lock)
  let decision = c.run("TakeShot", %*{"game": game, "windowGame": windowGame, "windowRunning": windowRunning})
  if decision.refused: return refusal(decision)
  Started(ok: true, status: 200)

proc endStep*(c: ptr ChatState, step, code: int) =
  ## Step `step` is over (a number that is not the running step is ignored): the job thread hands
  ## EndStep back, through StepRunner's one door.
  acquire(c.lock)
  defer: release(c.lock)
  discard c.giveBack(StepRunner, EndStep(step: step, code: code))
