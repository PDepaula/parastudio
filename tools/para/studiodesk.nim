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
# Kept apart on purpose (not events): the HTTP checks, the agent adapters, TurnControl, killing a
# process tree, the 200,000-byte job output buffer, the chats' titles and session ids (chatstore.nim's
# books), and what a game's producer was last asked to run with.

import std/[os, strutils, sequtils]
import eversince

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
    emit SpeedPicked(game: cmd.game, speed: cmd.speed)

command NewChat:
  fields:
    game: string
  reads Desk
  refuses busy
  decide:
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is still working on this game. Stop the turn first."

command OpenChat:
  fields:
    game: string
    chat: int
  reads Desk
  refuses busy
  decide:
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is working on this game's last message. Wait for it, or press Stop, then open the chat."

command DeleteChat:
  fields:
    game: string
    agent: string
    chat: int
  reads Desk
  produces ChatForgotten
  refuses busy
  decide:
    if desk.turnOf(cmd.game) != 0:
      refuse busy, "The producer is working on this game's last message. Wait for it, or press Stop, then delete the chat."
    emit ChatForgotten(game: cmd.game, agent: cmd.agent, chat: cmd.chat)

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

sealModel(StudioDesk, currentSourcePath().parentDir / "studiodesk.em")
