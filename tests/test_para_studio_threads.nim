# Tests for the studio's threads as the desk's processors, and for Stop as a fact
# (tools/para/studiodesk.nim, tools/para/studiochat.nim, tools/para/studioapi.nim). What is pinned here:
#
# - each processor, run on its own with stand-in hands that start no thread and no child process: which
#   fact wakes it, what it does (a hand, in the order the model's clocks-first rule gives), and the one
#   command it issues when its thread cannot start (TurnRunner and TurnClock: EndTurn failed;
#   StepRunner and StepClock: EndStep with code 1), with the facts' positions in the log;
# - the command StopTurn: refused when the game has no turn, accepted for a running one, and the fact it
#   makes (StopRequested) reaches TurnRunner with the turn's number, in the log's numbering like a turn;
# - the door a thread hands its commands back through (`handBack`): it takes exactly the commands its
#   processor's `issues` line lists, and the compiler refuses any other;
# - the same on the real shell, with a stand-in producer: a stop ends the running turn as "stopped"
#   and nothing else, a stop for a turn that is over (a StopRequested given again) is ignored by the
#   next turn of the game, a timeout ends it as "timeout", and closing the studio stops every running turn.

import std/[unittest, os, strutils, json, times, sequtils, algorithm, atomics]
import eversince
import tools/para/agent
import tools/para/studiochat
import tools/para/studiodesk

const
  here = currentSourcePath.parentDir
  modelFile = here.parentDir / "tools" / "para" / "studiodesk.em"

# --- the processors, with stand-in hands ---------------------------------------------

var seen {.threadvar.}: seq[string] ## what the stand-in hands were asked, in order
var failRunTurn, failWatchTurn, failRunStep, failWatchStep {.threadvar.}: bool

proc standRunTurn(state: pointer, e: TurnStarted): bool {.nimcall, gcsafe.} =
  seen.add "runTurn " & e.game & " " & $e.turn
  not failRunTurn

proc standWatchTurn(state: pointer, e: TurnStarted): bool {.nimcall, gcsafe.} =
  seen.add "watchTurn " & e.game & " " & $e.turn
  not failWatchTurn

proc standEndTurn(state: pointer, e: StopRequested) {.nimcall, gcsafe.} =
  seen.add "endTurn " & e.game & " " & $e.turn

proc standRunStep(state: pointer, e: StepStarted): bool {.nimcall, gcsafe.} =
  seen.add "runStep " & e.game & " " & $e.step & " " & e.kind
  not failRunStep

proc standWatchStep(state: pointer, e: StepStarted): bool {.nimcall, gcsafe.} =
  seen.add "watchStep " & e.game & " " & $e.step & " " & e.kind
  not failWatchStep

proc standIn(): Hands =
  Hands(runTurn: standRunTurn, watchTurn: standWatchTurn, endTurn: standEndTurn,
    runStep: standRunStep, watchStep: standWatchStep)

suite "the processors, with stand-in hands (no thread, no child process)":
  var rt: Runtime[StudioDesk]
  setup:
    rt = Runtime[StudioDesk](store: MemStore(), clock: proc (): int64 = 1_700_000_000_000)
    seen = @[]
    failRunTurn = false
    failWatchTurn = false
    failRunStep = false
    failWatchStep = false
    hands = standIn()
  teardown:
    hands = Hands()

  proc send(game: string): Decision =
    rt.execute("StartTurn", %*{"game": game, "agent": "claude", "chat": 1, "text": "hello", "busyGames": []})
  proc stop(game: string): Decision = rt.execute("StopTurn", %*{"game": game})
  proc endTurn(game: string, turn: int, outcome = "ok"): Decision =
    rt.execute("EndTurn", %*{"game": game, "agent": "claude", "chat": 1, "turn": turn, "outcome": outcome})
  proc kinds(): seq[string] = rt.store.load.mapIt(it.kind)
  proc outcomes(): seq[string] =
    rt.store.load.filterIt(it.kind == "TurnEnded").mapIt(it.data["outcome"].getStr)

  test "a turn wakes its clock and its runner, the clock first, and a thread that starts issues nothing":
    check not send("pong").refused
    check seen == @["watchTurn pong 1", "runTurn pong 1"]
    check kinds() == @["TurnStarted", "LineAdded"]
    check rt.app.desk.turns.len == 1

  test "TurnRunner issues EndTurn failed when the turn thread cannot start":
    failRunTurn = true
    check not send("pong").refused
    check kinds() == @["TurnStarted", "LineAdded", "TurnEnded"]
    check outcomes() == @["failed"]
    check rt.app.desk.turns.len == 0 # the game is free again
    check rt.app.chat.lines[^1].line.kind == "done" and rt.app.chat.lines[^1].line.text == "failed"

  test "TurnClock issues EndTurn failed when the clock cannot start, and the turn ends once":
    failWatchTurn = true
    failRunTurn = true # the runner's own EndTurn comes second and finds the turn over
    check not send("pong").refused
    check outcomes() == @["failed"]
    check rt.app.desk.turns.len == 0

  test "a stop is a fact: StopRequested names the turn, takes the next number, and wakes TurnRunner":
    check not send("pong").refused
    seen = @[]
    let d = stop("pong")
    check not d.refused
    check d.events.len == 1 and d.events[0].kind == "StopRequested"
    check d.events[0].data == %*{"game": "pong", "turn": 1}
    check d.events[0].seq == 3 # the turn's start and the message took 1 and 2
    check seen == @["endTurn pong 1"] # TurnRunner only: no clock, no job processor
    check not endTurn("pong", 1, "stopped").refused
    check rt.store.load.mapIt(it.seq) == @[1'i64, 2, 3, 4]
    check kinds() == @["TurnStarted", "LineAdded", "StopRequested", "TurnEnded"]
    check outcomes() == @["stopped"]

  test "a stop for a game with no turn is refused and wakes nothing":
    check stop("pong").refused
    check stop("pong").code == "idle"
    check seen.len == 0 and kinds().len == 0
    check not send("pong").refused
    check not endTurn("pong", 1).refused
    seen = @[]
    check stop("pong").code == "idle" # the turn is over
    check seen.len == 0

  test "a stop reaches the turn of its own game only":
    check not send("pong").refused
    check not send("dog").refused
    seen = @[]
    check not stop("dog").refused
    check seen == @["endTurn dog 2"]

  test "a step wakes its clock and its runner, for every kind of step":
    check not rt.execute("StartStep", %*{"game": "pong", "kind": "check", "message": ""}).refused
    check seen == @["watchStep pong 1 check", "runStep pong 1 check"]
    check not rt.execute("EndStep", %*{"step": 1, "code": 0}).refused
    seen = @[]
    check not rt.execute("NewGame", %*{"name": "cat", "existing": []}).refused
    check seen == @["watchStep cat 2 new", "runStep cat 2 new"]
    check not rt.execute("EndStep", %*{"step": 2, "code": 0}).refused
    seen = @[]
    check not rt.execute("LandLane", %*{"game": "pong", "lane": "a1", "lanes": ["a1"]}).refused
    check seen == @["watchStep pong 3 land", "runStep pong 3 land"]

  test "StepRunner issues EndStep with code 1 when the job thread cannot start":
    failRunStep = true
    check not rt.execute("StartStep", %*{"game": "pong", "kind": "check", "message": ""}).refused
    check kinds() == @["StepStarted", "StepEnded"]
    check rt.store.load[1].data == %*{"step": 1, "code": 1}
    check not rt.app.desk.stepRunning
    let job = answer(JobNow(), rt.app.desk)
    check job.step == 1 and not job.running and job.code == 1 and job.kind == "check" and job.game == "pong"

  test "StepClock issues EndStep with code 1 when the clock cannot start, and the step ends once":
    failWatchStep = true
    failRunStep = true
    check not rt.execute("StartStep", %*{"game": "pong", "kind": "check", "message": ""}).refused
    check kinds() == @["StepStarted", "StepEnded"]
    check not rt.app.desk.stepRunning

  test "a step that is running answers JobNow, and the next one waits for it":
    check not rt.execute("StartStep", %*{"game": "pong", "kind": "save", "message": "a note"}).refused
    let job = answer(JobNow(), rt.app.desk)
    check job.running and job.step == 1 and job.kind == "save"
    check rt.execute("StartStep", %*{"game": "dog", "kind": "check", "message": ""}).refused

  test "with no hands a processor does nothing, and the facts are the same":
    hands = Hands()
    check not send("pong").refused
    check not stop("pong").refused
    check kinds() == @["TurnStarted", "LineAdded", "StopRequested"]
    check seen.len == 0

suite "the model's processors, and the door a thread hands its commands back through":
  let model = parseModel(readFile(modelFile), "studiodesk.em")

  test "the four threads are processors, and each consumes and issues what the model line says":
    check processors(StudioDesk()).sorted == @["StepClock", "StepRunner", "TurnClock", "TurnRunner"]
    check model.find("TurnRunner").edge("consumes").sorted == @["StopRequested", "TurnStarted"]
    check model.find("TurnRunner").edge("issues").sorted == @["AddLine", "EndTurn", "ReportModel", "ReportSession"]
    check model.find("TurnClock").edge("consumes") == @["TurnStarted"]
    check model.find("TurnClock").edge("issues") == @["EndTurn"]
    check model.find("StepRunner").edge("consumes") == @["StepStarted"]
    check model.find("StepRunner").edge("issues") == @["EndStep"]
    check model.find("StepClock").edge("consumes") == @["StepStarted"]
    check model.find("StepClock").edge("issues") == @["EndStep"]

  test "the turn thread can hand back exactly TurnRunner's commands, and the compiler refuses the rest":
    check compiles(handBack(TurnRunner, AddLine()))
    check compiles(handBack(TurnRunner, ReportSession()))
    check compiles(handBack(TurnRunner, ReportModel()))
    check compiles(handBack(TurnRunner, EndTurn()))
    check not compiles(handBack(TurnRunner, StopTurn()))
    check not compiles(handBack(TurnRunner, EndStep()))
    check not compiles(handBack(TurnRunner, StartTurn()))
    check not compiles(handBack(TurnRunner, RestoreChat()))
    let (name, data) = handBack(TurnRunner, EndTurn(game: "pong", agent: "claude", chat: 1, turn: 3, outcome: "ok"))
    check name == "EndTurn" and data["turn"].getInt == 3

  test "the job thread can hand back EndStep and nothing else":
    check compiles(handBack(StepRunner, EndStep()))
    check not compiles(handBack(StepRunner, EndTurn()))
    check not compiles(handBack(StepRunner, StartStep()))
    check handBack(StepRunner, EndStep(step: 2, code: 0)).name == "EndStep"

# --- the real shell, with a stand-in producer ----------------------------------------

proc scratchRoot(): string =
  result = getTempDir() / ("para_threads_" & $getCurrentProcessId() & "_" & $(epochTime() * 1000).int64)
  createDir(result)

suite "Stop and the time limit on the real shell":
  var gate: Atomic[bool] ## the stand-in producer's turn runs until this is set, or until it is cancelled
  var root: string
  var chat: ptr ChatState

  proc stubTurn(a: AgentAdapter, req: TurnRequest, ctl: ptr TurnControl, emit: EmitProc): TurnResult {.nimcall, gcsafe.} =
    emit(UiEvent(kind: ukSay, text: "on it"))
    {.cast(gcsafe).}:
      while not gate.load and not ctl.isCancelled: sleep(2)
    TurnResult(ok: not ctl.isCancelled, cancelled: ctl.isCancelled)

  proc start(seconds = defaultTurnSeconds) =
    chat = create(ChatState)
    initChat(chat, root, @[AgentAdapter(name: "stub", label: "Stub", runTurn: stubTurn)], seconds)

  proc waitIdle() =
    let until = epochTime() + 10
    while chat.isRunning and epochTime() < until: sleep(2)
    check not chat.isRunning

  proc done(game: string): seq[string] =
    ## The end-of-turn words of `game`'s open chat, oldest first.
    for (_, _, ev) in chat.view(game, 0).entries:
      if ev.kind == ukTurnDone: result.add ev.text

  setup:
    root = scratchRoot()
    gate.store(false)
  teardown:
    gate.store(true)
    shutdownChat(chat)
    removeDir(root)

  test "a stop for a game with no turn is refused, and so is one for a turn that is over":
    start()
    check not chat.stopTurn("pong")
    check chat.startTurn("pong", "hello").ok
    check chat.stopTurn("pong")
    waitIdle()
    check not chat.stopTurn("pong")
    check done("pong") == @["stopped"]

  test "a stop ends the running turn as stopped, with the notice, and no other game's turn":
    start()
    check chat.startTurn("pong", "hello").ok
    check chat.startTurn("dog", "woof").ok
    check chat.stopTurn("pong") # returns once the stand-in has seen the cancel
    let until = epochTime() + 10
    while chat.isRunning("pong") and epochTime() < until: sleep(2)
    check not chat.isRunning("pong")
    check chat.isRunning("dog") # the other game goes on
    let kinds = chat.view("pong", 0).entries.mapIt(it.ev.code)
    check "stopped" in kinds
    gate.store(true)
    waitIdle()
    check done("pong") == @["stopped"]
    check done("dog") == @["ok"]

  test "a stop for a turn that is over is ignored by the game's next turn":
    start()
    check chat.startTurn("pong", "first").ok
    check chat.stopTurn("pong")
    waitIdle()
    check chat.startTurn("pong", "second").ok # turn 2; the stand-in holds it
    # the stop of turn 1 is given to TurnRunner again, as a restart might: it is not this game's turn now
    chat.giveAgain("TurnRunner", Envelope(seq: 99, kind: "StopRequested", data: %*{"game": "pong", "turn": 1}))
    sleep(150)
    check chat.isRunning("pong")
    check chat.deskFacts("pong").turn == 2
    gate.store(true)
    waitIdle()
    check done("pong") == @["stopped", "ok"] # turn 2 ran to its own end

  test "a stop for a turn of a game that has none changes nothing":
    start()
    check chat.startTurn("pong", "hello").ok
    chat.giveAgain("TurnRunner", Envelope(seq: 99, kind: "StopRequested", data: %*{"game": "cat", "turn": 1}))
    sleep(100)
    check chat.isRunning("pong")
    gate.store(true)
    waitIdle()
    check done("pong") == @["ok"]

  test "the time limit ends the turn as timeout, a fact the page and the log both have":
    start(seconds = 1)
    check chat.startTurn("pong", "hello").ok
    let until = epochTime() + 20
    while chat.isRunning("pong") and epochTime() < until: sleep(20)
    check not chat.isRunning("pong")
    check done("pong") == @["timeout"]
    check "timeout" in chat.view("pong", 0).entries.mapIt(it.ev.code)

  test "closing the studio stops every running turn":
    start()
    check chat.startTurn("pong", "hello").ok
    check chat.startTurn("dog", "woof").ok
    check chat.runningGames == @["dog", "pong"]
    shutdownChat(chat)
    check not chat.isRunning
    check done("pong") == @["stopped"]
    check done("dog") == @["stopped"]
