# The studio's desk: which turn, step, producer pick and chat change may happen now, and what each
# chat has said, written in eversince's vocabulary (https://github.com/PDepaula/eversince; the model
# file is studiodesk.em and the compiler checks the two against each other).
#
# This module is the functional core of the chat slice of `para studio`: no thread, no lock, no
# clock, no file, no process (a `decide`, a view's `on` and a query's `answer` are `func`s with
# `tags: []`, so the compiler refuses any of those). The shell (studiochat.nim, studioapi.nim) owns
# them: it runs the commands of this file under its ONE lock, starts the threads and the child
# processes, and turns an accepted command into those effects.
#
# The rules, each with a scenario in tests/studiodesk/scenarios.jsonl:
#   one turn per game                        StartTurn   refuses busy
#   two games may each have a turn           StartTurn   (a turn of another game does not matter)
#   no message while that game's step runs   StartTurn   refuses busy
#   a step does not wait for another game    StartStep   (only that game's own turn counts)
#   one step at a time, all games            StartStep   refuses busy
#   a save needs a note                      StartStep   refuses needsMessage
#   no producer, speed or chat change while  PickProducer, PickSpeed, NewChat, OpenChat, DeleteChat
#   that game's turn runs                                refuse busy
#   a save's note is one short line          StartStep   refuses badMessage
#   a new game has a name no game has        NewGame     refuses needsName, badName, taken, busy
#   a helper's work lands only if it is      LandLane    refuses noSuchLane, busy
#   one of the game's
#   Play needs the game's source file, and   StartPlay   refuses noSource, busy
#   waits for a step
#   a picture is of the window that is open  TakeShot    refuses otherGame, notRunning
# and, from the shell, "a third game is refused while two have helpers building": the shell looks
# the helpers' folders up and hands the games it found to StartTurn as `busyGames`. The same way, the
# shell looks up what is on disk or in a process and hands it in as a command's field: `existing` (the
# games there are), `lanes` (a game's helpers' work), `hasSource` (the game's source file is there),
# `windowGame` and `windowRunning` (the game window). The desk never looks at a disk or a process.
#
# "A picture is already being taken" stays the shell's `shotLock` (a tryAcquire, not a second lock
# around the desk): it is about the one picture in flight, not about what the desk may start.
#
# The chats' books (each chat's number, title, times and session id, and which one is current), the
# producer and speed picks and what a game's producer last ran with are events too, and they are the
# ones that survive a restart: chatstore.nim writes them to tmp/studio/studio.jsonl, and the shell
# replays that file when the studio starts. The book's rules, each with a scenario:
#   a fresh chat is not listed until a message   NewChat, UseChat
#   a chat's title is the start of its first     UseChat
#   message; the one used last is first in the list
#   deleting the current chat starts a fresh one DeleteChat
#   a session id is one a command line may take  ReportSession refuses badSession
#
# Kept apart on purpose (not events): the HTTP checks, the agent adapters, TurnControl, killing a
# process tree and the 200,000-byte job output buffer.

import std/[os, options, strutils, sequtils]
import eversince
from agent import validSessionToken

const
  maxMessageChars* = 8000   ## the longest message the friend may send
  maxLiveGames* = 2         ## games whose helpers may be building at once; a turn for a third is refused
  maxLines* = 8000          ## chat lines the Chat view holds; the oldest go first (a chat opened again is read back from its file)
  maxGameName* = 40         ## the longest name a new game may get
  maxNoteChars* = 200       ## the longest note a save may carry

record LineBody:
  you: bool                 ## the friend's own message (kind "say")
  kind: string              ## say, activity, helper, refused, notice, error, done, shot
  text: string
  id: string
  role: string
  status: string
  tools: int
  code: string
  detail: string
  url: string
record ChatEntry:
  seq: int
  game: string
  agent: string
  chat: int
  line: LineBody
record ChatCount:
  game: string
  agent: string
  chat: int
  lines: int                ## the number the chat's last kept line has (see `n` of LineAdded)
record GameTurn:
  game: string
  turn: int
record Pick:
  game: string
  agent: string
record SpeedPick:
  game: string
  speed: string
record ChatRecord:
  id: int
  title: string             ## "" for a chat from before there were titles
  started: int              ## seconds since 1970
  updated: int
  session: string           ## the agent's own id for the conversation, "" until it reports one
record Book:
  game: string
  agent: string
  current: int              ## the chat the next message goes to (it may have no record yet: a fresh chat)
  next: int                 ## the number the next fresh chat gets; numbers are never reused
  chats: seq[ChatRecord]    ## the one used last at the end
record ChatListing:
  agent: string
  current: int
  chats: seq[ChatRecord]    ## newest first
record Ran:
  game: string
  agent: string
  started: bool             ## a turn has run (the fields below mean something)
  speed: string             ## the speed that turn started with
  askedModel: string        ## what the studio passed ("" = left to the agent)
  askedEffort: string
  model: string             ## what the agent reported ("" = it did not say)
  effort: string
record DeskFacts:
  working: seq[string]      ## every game with a turn running, by name
  running: bool             ## the asked game has a turn running
  turn: int                 ## the asked game's running turn, 0 when none
  lastTurn: int             ## the asked game's last turn, running or ended, 0 before its first
  stepRunning: bool
  stepId: int
  stepKind: string
  stepGame: string
  stepCode: int
record ChatPage:
  running: bool
  working: seq[string]
  turn: int
  next: int                 ## the last number handed out: the page asks for more after it
  entries: seq[ChatEntry]

event TurnStarted:
  game: string
  agent: string
  chat: int
  turn: int
event TurnEnded:
  game: string
  agent: string
  chat: int
  turn: int
  outcome: string           ## ok, failed, stopped or timeout
event LineAdded:
  game: string
  agent: string
  chat: int
  n: int                    ## the line's number among the chat's kept lines, 0 for a line that is not kept
  line: LineBody
event ChatRestored:
  game: string
  agent: string
  chat: int
  lastN: int
  lines: seq[LineBody]
event ChatForgotten:
  game: string
  agent: string
  chat: int
event StepStarted:
  game: string
  step: int
  kind: string
event StepEnded:
  step: int
  code: int
event AgentPicked:
  game: string
  agent: string
event SpeedPicked:
  game: string
  speed: string
event ChatStarted:
  game: string
  agent: string
  chat: int                 ## the fresh chat the next message goes to
  at: int
event ChatOpened:
  game: string
  agent: string
  chat: int
  next: int                 ## the number the next fresh chat gets, so a forgotten chat's number is not handed out again
event ChatUsed:
  game: string
  agent: string
  chat: int
  at: int
  title: string             ## the start of the message, which names the chat when it has no record yet
event SessionReported:
  game: string
  agent: string
  chat: int
  session: string
event ModelReported:
  game: string
  agent: string
  speed: string
  askedModel: string
  askedEffort: string
  model: string
  effort: string
event PlayStarted:
  game: string
  run: int                  ## how many times Play was accepted, this one included
event ShotAsked:
  game: string

func keptLine*(line: LineBody): bool =
  ## Whether a line goes into its chat's file: not the end-of-turn marker, and of a helper card only
  ## where it started and how it ended.
  line.kind != "done" and not (line.kind == "helper" and line.status == "working")

func goodGameName*(name: string): bool =
  ## The names `para new` makes (savepoint.nim's `validGameName`, which a test holds this equal to):
  ## small letters, digits and `_`, starting with a letter.
  name.len > 0 and name[0] in {'a'..'z'} and name.allCharsInSet({'a'..'z', '0'..'9', '_'})

func validNote*(note: string): bool =
  ## A save's note: one short line.
  note.len <= maxNoteChars and not note.anyIt(it < ' ' or it == '\x7f')

func validMessage*(text: string): string =
  ## "" when `text` can be sent, else the plain reason it cannot.
  if text.strip.len == 0: return "Write a message first."
  if text.len > maxMessageChars:
    return "That message is too long (up to " & $maxMessageChars & " characters). Send it in smaller pieces."
  for ch in text:
    if ch == '\0' or (ch < ' ' and ch notin {'\n', '\r', '\t'}):
      return "That message has a character the studio can't send."

view Desk:
  state:
    turns: seq[GameTurn]    ## the turns running now
    last: seq[GameTurn]     ## each game's latest turn, running or ended
    lastTurn: int           ## the number the last turn of any game got
    stepRunning: bool
    stepId: int
    stepKind: string
    stepGame: string
    lastStepCode: int
    picks: seq[Pick]        ## "" for the game: the studio-wide pick
    speeds: seq[SpeedPick]
    playGame: string        ## the game Play was last accepted for
    playRun: int            ## how many times Play was accepted
    shotGame: string        ## the game a picture was last asked for
  on TurnStarted:
    state.turns.add GameTurn(game: e.game, turn: e.turn)
    state.lastTurn = e.turn
    var kept: seq[GameTurn]
    for t in state.last:
      if t.game != e.game: kept.add t
    kept.add GameTurn(game: e.game, turn: e.turn)
    state.last = kept
  on TurnEnded:
    var kept: seq[GameTurn]
    for t in state.turns:
      if t.turn != e.turn: kept.add t
    state.turns = kept
  on StepStarted:
    state.stepRunning = true
    state.stepId = e.step
    state.stepKind = e.kind
    state.stepGame = e.game
  on StepEnded:
    state.stepRunning = false
    state.lastStepCode = e.code
  on AgentPicked:
    var kept: seq[Pick]
    for p in state.picks:
      if p.game != e.game: kept.add p
    kept.add Pick(game: e.game, agent: e.agent)
    state.picks = kept
  on SpeedPicked:
    var kept: seq[SpeedPick]
    for p in state.speeds:
      if p.game != e.game: kept.add p
    kept.add SpeedPick(game: e.game, speed: e.speed)
    state.speeds = kept
  on PlayStarted:
    state.playGame = e.game
    state.playRun = e.run
  on ShotAsked:
    state.shotGame = e.game

func turnOf*(desk: Desk, game: string): int =
  ## The running turn of `game`, 0 when none runs.
  for t in desk.turns:
    if t.game == game: return t.turn

func lastTurnOf*(desk: Desk, game: string): int =
  for t in desk.last:
    if t.game == game: return t.turn

func workingGames*(desk: Desk): seq[string] =
  ## Every game with a turn running, by name.
  for t in desk.turns:
    var at = result.len
    while at > 0 and result[at - 1] > t.game: dec at
    result.insert(t.game, at)

view Chat:
  state:
    lines: seq[ChatEntry]
    last: int               ## the last number handed to a line (numbers start at 1 and are never reused)
    counts: seq[ChatCount]
  on LineAdded:
    state.last += 1
    state.lines.add ChatEntry(seq: state.last, game: e.game, agent: e.agent, chat: e.chat, line: e.line)
    if state.lines.len > maxLines: state.lines = state.lines[state.lines.len - maxLines .. ^1]
    if e.n > 0:
      var found = false
      for c in state.counts.mitems:
        if c.game == e.game and c.agent == e.agent and c.chat == e.chat:
          c.lines = e.n
          found = true
      if not found: state.counts.add ChatCount(game: e.game, agent: e.agent, chat: e.chat, lines: e.n)
  on TurnEnded:
    state.last += 1
    state.lines.add ChatEntry(seq: state.last, game: e.game, agent: e.agent, chat: e.chat,
      line: LineBody(kind: "done", text: e.outcome))
    if state.lines.len > maxLines: state.lines = state.lines[state.lines.len - maxLines .. ^1]
  on ChatRestored:
    var kept: seq[ChatEntry]
    for l in state.lines:
      if not (l.game == e.game and l.agent == e.agent and l.chat == e.chat): kept.add l
    for line in e.lines:
      state.last += 1
      kept.add ChatEntry(seq: state.last, game: e.game, agent: e.agent, chat: e.chat, line: line)
    if kept.len > maxLines: kept = kept[kept.len - maxLines .. ^1]
    state.lines = kept
    var counts: seq[ChatCount]
    for c in state.counts:
      if not (c.game == e.game and c.agent == e.agent and c.chat == e.chat): counts.add c
    if e.lastN > 0: counts.add ChatCount(game: e.game, agent: e.agent, chat: e.chat, lines: e.lastN)
    state.counts = counts
  on ChatForgotten:
    var kept: seq[ChatEntry]
    for l in state.lines:
      if not (l.game == e.game and l.agent == e.agent and l.chat == e.chat): kept.add l
    state.lines = kept
    var counts: seq[ChatCount]
    for c in state.counts:
      if not (c.game == e.game and c.agent == e.agent and c.chat == e.chat): counts.add c
    state.counts = counts

func nextN*(chat: Chat, game, agent: string, id: int): int =
  ## The number the next kept line of that chat gets.
  result = 1
  for c in chat.counts:
    if c.game == game and c.agent == agent and c.chat == id: return c.lines + 1

func freshBook(game, agent: string): Book = Book(game: game, agent: agent, current: 1, next: 2)

func indexOf(books: seq[Book], game, agent: string): int =
  ## The index of `game`'s book for `agent`, -1 when there is none yet.
  result = -1
  for i, b in books:
    if b.game == game and b.agent == agent: return i

func find*(b: Book, id: int): int =
  ## The index of chat `id` in `b.chats`, -1 when it has no record.
  result = -1
  for i, c in b.chats:
    if c.id == id: return i

func bookOf*(view: seq[Book], game, agent: string): Book =
  ## `game`'s chats with `agent`: a fresh book (one empty chat, nothing listed) before there is any.
  let i = view.indexOf(game, agent)
  if i < 0: freshBook(game, agent) else: view[i]

view ChatBook:
  state:
    books: seq[Book]        ## one for each game and agent that has had a chat
  on ChatStarted:
    var i = state.books.indexOf(e.game, e.agent)
    if i < 0:
      state.books.add freshBook(e.game, e.agent)
      i = state.books.high
    state.books[i].current = e.chat
    state.books[i].next = max(state.books[i].next, e.chat + 1)
  on ChatOpened:
    var i = state.books.indexOf(e.game, e.agent)
    if i < 0:
      state.books.add freshBook(e.game, e.agent)
      i = state.books.high
    state.books[i].current = e.chat
    state.books[i].next = max(state.books[i].next, max(e.next, e.chat + 1))
  on ChatUsed:
    var i = state.books.indexOf(e.game, e.agent)
    if i < 0:
      state.books.add freshBook(e.game, e.agent)
      i = state.books.high
    var rec = ChatRecord(id: e.chat, title: e.title, started: e.at, updated: e.at)
    let at = state.books[i].find(e.chat)
    if at >= 0:
      rec = state.books[i].chats[at]
      rec.updated = e.at
      state.books[i].chats.delete(at)
    state.books[i].chats.add rec # the one used last goes at the end
    state.books[i].current = e.chat
    state.books[i].next = max(state.books[i].next, e.chat + 1)
  on SessionReported:
    let i = state.books.indexOf(e.game, e.agent)
    if i >= 0:
      let at = state.books[i].find(e.chat)
      if at >= 0: state.books[i].chats[at].session = e.session
  on ChatForgotten:
    let i = state.books.indexOf(e.game, e.agent)
    if i >= 0:
      let at = state.books[i].find(e.chat)
      if at >= 0:
        state.books[i].chats.delete(at)
        if state.books[i].current == e.chat: # the next message starts a fresh chat
          state.books[i].current = state.books[i].next
          state.books[i].next += 1

view Producers:
  state:
    ran: seq[Ran]           ## what each game's producer (one agent) did its last turn with
  on ModelReported:
    var kept: seq[Ran]
    for r in state.ran:
      if not (r.game == e.game and r.agent == e.agent): kept.add r
    kept.add Ran(game: e.game, agent: e.agent, started: true, speed: e.speed, askedModel: e.askedModel,
      askedEffort: e.askedEffort, model: e.model, effort: e.effort)
    state.ran = kept

func ranOf*(view: seq[Ran], game, agent: string): Ran =
  ## What `game`'s producer `agent` last ran with; every field empty before its first turn.
  result = Ran(game: game, agent: agent)
  for r in view:
    if r.game == game and r.agent == agent: return r

func newestFirst*(b: Book): seq[ChatRecord] =
  ## The chats to list, the one used last first (two used in the same second: the later one).
  for i in countdown(b.chats.high, 0):
    var at = result.len
    while at > 0 and result[at - 1].updated < b.chats[i].updated: dec at
    result.insert(b.chats[i], at)

func goodSession*(session: string): bool =
  ## A session id a command line may take (agent.nim's `validSessionToken`, the only gate before one
  ## reaches a command line; an adapter checks its own stricter shape on top).
  session.len > 0 and session.validSessionToken == session

command StartTurn:
  fields:
    game: string
    agent: string
    chat: int
    text: string
    busyGames: seq[string]  ## the other games whose helpers are building now (the shell looked them up)
  reads Desk, Chat
  produces TurnStarted, LineAdded
  refuses busy, tooBusy, badMessage
  decide:
    if desk.stepRunning and desk.stepGame == cmd.game:
      refuse busy, "A step (Check, Save or Backup) is still running. Wait for it to finish, then send your message."
    if desk.turnOf(cmd.game) == 0 and cmd.busyGames.len >= maxLiveGames:
      refuse tooBusy, "The helpers on " & cmd.busyGames.join(" and ") & " are building right now, and a third game at once would be too much for this computer. Wait for one of them to finish, or press Stop on one, then send your message."
    let problem = validMessage(cmd.text)
    if problem.len > 0: refuse badMessage, problem
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is still working on this game's last message. Wait for it, or press Stop."
    emit TurnStarted(game: cmd.game, agent: cmd.agent, chat: cmd.chat, turn: desk.lastTurn + 1)
    emit LineAdded(game: cmd.game, agent: cmd.agent, chat: cmd.chat, n: chat.nextN(cmd.game, cmd.agent, cmd.chat),
      line: LineBody(you: true, kind: "say", text: cmd.text.strip))

command EndTurn:
  fields:
    game: string
    agent: string
    chat: int
    turn: int
    outcome: string
  reads Desk
  produces TurnEnded
  refuses staleTurn
  decide:
    if desk.turnOf(cmd.game) != cmd.turn: refuse staleTurn, "That turn is over."
    emit TurnEnded(game: cmd.game, agent: cmd.agent, chat: cmd.chat, turn: cmd.turn, outcome: cmd.outcome)

command AddLine:
  fields:
    game: string
    agent: string
    chat: int
    line: LineBody
  reads Chat
  produces LineAdded
  decide:
    emit LineAdded(game: cmd.game, agent: cmd.agent, chat: cmd.chat,
      n: (if cmd.line.keptLine: chat.nextN(cmd.game, cmd.agent, cmd.chat) else: 0), line: cmd.line)

command StartStep:
  fields:
    game: string
    kind: string
    message: string
  reads Desk
  produces StepStarted
  refuses busy, needsMessage, badMessage
  decide:
    if not cmd.message.validNote:
      refuse badMessage, "Keep the note to one short line (up to " & $maxNoteChars & " characters)."
    if cmd.kind == "save" and cmd.message.strip.len == 0:
      refuse needsMessage, "Write a few words about what changed, then save."
    if cmd.game.len > 0 and desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is working on " & cmd.game & " right now. Wait for it, or press Stop in the chat, then try again."
    if desk.stepRunning:
      refuse busy, "Another step is still running (" & desk.stepKind & "). Wait for it to finish."
    emit StepStarted(game: cmd.game, step: desk.stepId + 1, kind: cmd.kind)

command NewGame:
  fields:
    name: string
    existing: seq[string]   ## the games there already are, as far as the shell looked: it names the one asked about when its folder is there
  reads Desk
  produces StepStarted
  refuses needsName, badName, taken, busy
  decide:
    if cmd.name.len == 0:
      refuse needsName, "Give the game a name first, for example: space_frogs"
    if cmd.name.len > maxGameName or not cmd.name.goodGameName:
      refuse badName, "A game's name uses only small letters (a to z), digits and _, starts with a letter, and is at most " &
        $maxGameName & " characters. For example: space_frogs"
    if cmd.name in cmd.existing:
      refuse taken, "There is already a game called " & cmd.name & ". Pick another name."
    if desk.turnOf(cmd.name) != 0:
      refuse busy, "The producer is working on " & cmd.name & " right now. Wait for it, or press Stop in the chat, then try again."
    if desk.stepRunning:
      refuse busy, "Another step is still running (" & desk.stepKind & "). Wait for it to finish."
    emit StepStarted(game: cmd.name, step: desk.stepId + 1, kind: "new")

command LandLane:
  fields:
    game: string
    lane: string
    lanes: seq[string]      ## the helpers' work this game has (the shell looked at the folders next to it)
  reads Desk
  produces StepStarted
  refuses noSuchLane, busy
  decide:
    if cmd.lane notin cmd.lanes:
      refuse noSuchLane, "That helper's work is not here any more."
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is working on " & cmd.game & " right now. Wait for it, or press Stop in the chat, then try again."
    if desk.stepRunning:
      refuse busy, "Another step is still running (" & desk.stepKind & "). Wait for it to finish."
    emit StepStarted(game: cmd.game, step: desk.stepId + 1, kind: "land")

command StartPlay:
  fields:
    game: string
    hasSource: bool         ## games/<game>/<game>.nim is there (the shell looked)
  reads Desk
  produces PlayStarted
  refuses noSource, busy
  decide:
    if not cmd.hasSource:
      refuse noSource, "There is no game to play yet: games/" & cmd.game & "/" & cmd.game & ".nim is not there. Ask the producer to build the first version."
    if desk.stepRunning:
      refuse busy, "A step (Check, Save or Backup) is still running, and it builds the game too. Wait for it to finish, then press Play."
    emit PlayStarted(game: cmd.game, run: desk.playRun + 1)

command TakeShot:
  fields:
    game: string
    windowGame: string      ## the game of the window that is starting or running, "" when none (the shell looked)
    windowRunning: bool     ## the window answers on its channel (the shell looked)
  produces ShotAsked
  refuses otherGame, notRunning
  decide:
    if cmd.windowGame.len > 0 and cmd.windowGame != cmd.game:
      refuse otherGame, "The game window that is open is " & cmd.windowGame & ", not " & cmd.game & ". Pick " & cmd.windowGame &
        " to take its picture, or press Play for " & cmd.game & " first."
    if not cmd.windowRunning:
      refuse notRunning, "There is no game window open to take a picture of. Press Play first."
    emit ShotAsked(game: cmd.game)

command EndStep:
  fields:
    step: int
    code: int
  reads Desk
  produces StepEnded
  refuses staleStep
  decide:
    if not desk.stepRunning or cmd.step != desk.stepId: refuse staleStep, "That step is over."
    emit StepEnded(step: cmd.step, code: cmd.code)

command PickProducer:
  fields:
    game: string            ## "" for the studio-wide pick, which waits for every turn
    agent: string
  reads Desk
  produces AgentPicked
  refuses busy
  decide:
    if (if cmd.game.len == 0: desk.turns.len > 0 else: desk.turnOf(cmd.game) != 0):
      refuse busy, "The producer is working on this game's last message. Wait for it, or press Stop, then pick again."
    for p in desk.picks:
      if p.game == cmd.game and p.agent == cmd.agent: return # the same pick again changes nothing
    emit AgentPicked(game: cmd.game, agent: cmd.agent)

command PickSpeed:
  fields:
    game: string
    speed: string
  reads Desk
  produces SpeedPicked
  refuses busy
  decide:
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is working on this game's last message. Wait for it, or press Stop, then pick again."
    var now = "standard"
    for p in desk.speeds:
      if p.game == cmd.game: now = p.speed
    if now == cmd.speed: return # the same speed again changes nothing
    emit SpeedPicked(game: cmd.game, speed: cmd.speed)

command NewChat:
  fields:
    game: string
    agent: Option[string]   ## the producer the game talks to now (the shell knows the default one)
  reads Desk, ChatBook
  produces ChatStarted
  refuses busy
  decide:
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is still working on this game. Stop the turn first."
    let agent = cmd.agent.get("")
    let book = chatBook.books.bookOf(cmd.game, agent)
    if book.find(book.current) >= 0: # a fresh chat is already the current one: nothing to change
      emit ChatStarted(game: cmd.game, agent: agent, chat: book.next, at: int(ctx.now div 1000))

command OpenChat:
  fields:
    game: string
    chat: int
    agent: Option[string]   ## the producer the game talks to now
  reads Desk, ChatBook
  produces ChatOpened
  refuses busy
  decide:
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is working on this game's last message. Wait for it, or press Stop, then open the chat."
    let agent = cmd.agent.get("")
    let book = chatBook.books.bookOf(cmd.game, agent)
    if book.find(cmd.chat) >= 0 and book.current != cmd.chat: # a chat with no record, or the open one: nothing to change
      emit ChatOpened(game: cmd.game, agent: agent, chat: cmd.chat, next: book.next)

command DeleteChat:
  fields:
    game: string
    agent: string
    chat: int
  reads Desk, ChatBook
  produces ChatForgotten, ChatStarted
  refuses busy
  decide:
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is working on this game's last message. Wait for it, or press Stop, then delete the chat."
    let book = chatBook.books.bookOf(cmd.game, cmd.agent)
    emit ChatForgotten(game: cmd.game, agent: cmd.agent, chat: cmd.chat) # the lines and the id go whether or not the chat had a record
    if book.find(cmd.chat) >= 0 and book.current == cmd.chat: # the next message starts a fresh chat
      emit ChatStarted(game: cmd.game, agent: cmd.agent, chat: book.next, at: int(ctx.now div 1000))

command UseChat:
  fields:
    game: string
    agent: string
    chat: int
    title: string           ## the start of the message just sent, which names the chat if it is new
  produces ChatUsed
  decide:
    emit ChatUsed(game: cmd.game, agent: cmd.agent, chat: cmd.chat, at: int(ctx.now div 1000), title: cmd.title)

command ReportSession:
  fields:
    game: string
    agent: string
    chat: int
    session: string         ## the agent's own id for the conversation
  reads ChatBook
  produces SessionReported
  refuses badSession
  decide:
    if not cmd.session.goodSession:
      refuse badSession, "That is not a session id the studio can keep."
    let book = chatBook.books.bookOf(cmd.game, cmd.agent)
    let at = book.find(cmd.chat)
    if at >= 0 and book.chats[at].session != cmd.session: # a chat with no record has nothing to resume
      emit SessionReported(game: cmd.game, agent: cmd.agent, chat: cmd.chat, session: cmd.session)

command ReportModel:
  fields:
    game: string
    agent: string
    speed: string
    askedModel: string
    askedEffort: string
    model: string
    effort: string
  reads Producers
  produces ModelReported
  decide:
    let was = producers.ran.ranOf(cmd.game, cmd.agent)
    if was.started and was.speed == cmd.speed and was.askedModel == cmd.askedModel and was.askedEffort == cmd.askedEffort and
        was.model == cmd.model and was.effort == cmd.effort:
      return # the same words again change nothing
    emit ModelReported(game: cmd.game, agent: cmd.agent, speed: cmd.speed, askedModel: cmd.askedModel,
      askedEffort: cmd.askedEffort, model: cmd.model, effort: cmd.effort)

command RestoreChat:
  fields:
    game: string
    agent: string
    chat: int
    lines: seq[LineBody]    ## the chat's lines as its file has them (or as just rebuilt)
    lastN: int
    persist: bool           ## the lines were rebuilt and are not in the file yet: write them too
  reads Chat
  produces ChatRestored, LineAdded
  decide:
    if cmd.persist:
      emit ChatRestored(game: cmd.game, agent: cmd.agent, chat: cmd.chat, lastN: 0, lines: @[])
      var n = 0
      for line in cmd.lines:
        if line.keptLine:
          n += 1
          emit LineAdded(game: cmd.game, agent: cmd.agent, chat: cmd.chat, n: n, line: line)
    else:
      emit ChatRestored(game: cmd.game, agent: cmd.agent, chat: cmd.chat, lastN: cmd.lastN, lines: cmd.lines)

query DeskNow:
  fields:
    game: string
  reads Desk
  returns DeskFacts
  answer:
    result.working = desk.workingGames
    result.turn = desk.turnOf(q.game)
    result.running = result.turn != 0
    result.lastTurn = desk.lastTurnOf(q.game)
    result.stepRunning = desk.stepRunning
    result.stepId = desk.stepId
    result.stepKind = desk.stepKind
    result.stepGame = desk.stepGame
    result.stepCode = desk.lastStepCode

query ChatSince:
  fields:
    game: string
    agent: string
    chat: int
    since: int
  reads Chat, Desk
  returns ChatPage
  answer:
    result.running = desk.turnOf(q.game) != 0
    result.working = desk.workingGames
    result.turn = desk.lastTurnOf(q.game)
    result.next = chat.last
    for l in chat.lines:
      if l.seq > q.since and l.game == q.game and l.agent == q.agent and l.chat == q.chat: result.entries.add l

query ChatList:
  fields:
    game: string
    agent: string
  reads ChatBook
  returns ChatListing
  answer:
    let book = chatBook.books.bookOf(q.game, q.agent)
    result.agent = q.agent
    result.current = book.current
    result.chats = book.newestFirst

query ProducerNow:
  fields:
    game: string
    agent: string
  reads Producers
  returns Ran
  answer:
    result = producers.ran.ranOf(q.game, q.agent)

sealModel(StudioDesk, currentSourcePath().parentDir / "studiodesk.em")
