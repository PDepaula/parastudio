# Tests for the game window as the desk's `PlayWindow` view (tools/para/studiodesk.nim) and the one
# lock around it (tools/para/studiochat.nim). The scenarios in tests/studiodesk/scenarios.jsonl hold
# the rules; what is pinned here is what a scenario cannot show:
#
# - the processor PlayRunner calls the shell's two procs inside the command, and issues what the shell
#   could not do (the end of a run that did not start, "starting" for a run with nothing to build, the
#   end of a stop with nothing left to end it), and does nothing when no shell lent it procs;
# - Play and a step are decided under the same lock: started together from two threads they are never
#   both accepted, and a step is refused while Play builds (and Play while a step runs);
# - the thread's reports (PlayPhase, EndPlay) are refused once a second Play has replaced the run.
# test_para_studio_play.nim runs the real thing against the real handler.

import std/[unittest, os, json, times, atomics, strutils, algorithm]
import eversince
import tools/para/agent
import tools/para/studiochat
import tools/para/studiodesk

const startedMessage = "Building the game… the first time takes a few minutes."

var opened, stopped: seq[(string, int)]
var openAnswer = "building"
var stopAnswer = true

proc fakeOpen(state: pointer, e: PlayStarted): string {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    opened.add (e.game, e.run)
    result = openAnswer

proc fakeStop(state: pointer, e: PlayStopRequested): bool {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    stopped.add ("", e.run)
    result = stopAnswer

proc scratchRoot(): string =
  result = getTempDir() / ("para_playwin_" & $getCurrentProcessId() & "_" & $(epochTime() * 1000).int64)
  createDir(result)

suite "the processor PlayRunner":
  var rt: Runtime[StudioDesk]
  setup:
    opened = @[]
    stopped = @[]
    openAnswer = "building"
    stopAnswer = true
    hands = Hands(openPlay: fakeOpen, stopPlay: fakeStop)
    rt = Runtime[StudioDesk](store: MemStore(), clock: proc (): int64 = 1_700_000_000_000)
  teardown:
    hands = Hands()

  proc play(game = "pong"): Decision = rt.execute("StartPlay", %*{"game": game, "hasSource": true})
  proc window(): PlayFacts = answer(PlayNow(), rt.app.playWindow)

  test "Play accepted: the shell opens the run's thread, and the window is building":
    check not play().refused
    check opened == @[("pong", 1)]
    let w = window()
    check w.state == "building" and w.game == "pong" and w.run == 1 and w.message == startedMessage

  test "a refused Play opens nothing":
    check rt.execute("StartPlay", %*{"game": "pong", "hasSource": false}).refused
    check opened.len == 0
    check window().state == "idle"

  test "nothing to build: the processor moves the run to starting at once":
    openAnswer = "starting"
    check not play().refused
    check window().state == "starting" and window().message == "Opening the game window…"

  test "a thread that did not start ends the run as failed":
    openAnswer = ""
    check not play().refused
    let w = window()
    check w.state == "failed" and w.code == "studio-error" and w.message == "The studio could not start the game."

  test "Stop: the shell is handed the run's number, and the thread ends the run":
    check not play().refused
    check not rt.execute("PlayPhase", %*{"run": 1, "phase": "starting", "message": "", "code": ""}).refused
    check not rt.execute("StopPlay", %*{}).refused
    check stopped == @[("", 1)]
    check window().code == "stopping" and window().state == "starting"
    check not rt.execute("EndPlay", %*{"run": 1, "code": "", "message": "The game was stopped.", "detail": ""}).refused
    check window().state == "idle" and window().message == "The game was stopped."

  test "Stop with no thread left to end the run ends it itself":
    check not play().refused
    stopAnswer = false
    check not rt.execute("StopPlay", %*{}).refused
    let w = window()
    check w.state == "idle" and w.message == "The game was stopped." and w.code == ""

  test "a second Play replaces the run: the old thread's end is refused, and nobody waits for it":
    check not play().refused
    check not play().refused
    check opened == @[("pong", 1), ("pong", 2)]
    check rt.execute("EndPlay", %*{"run": 1, "code": "", "message": "The game was stopped.", "detail": ""}).code == "staleRun"
    check window().state == "building" and window().run == 2

  test "with no shell the desk alone still decides, and the processor does nothing":
    hands = Hands()
    check not play().refused
    check window().state == "building"
    check not rt.execute("StopPlay", %*{}).refused
    check window().code == "stopping"

suite "the door the Play run's thread hands its commands back through":
  test "it can hand back PlayPhase and EndPlay and nothing else":
    check compiles(handBack(PlayRunner, PlayPhase()))
    check compiles(handBack(PlayRunner, EndPlay()))
    check not compiles(handBack(PlayRunner, StopPlay()))
    check not compiles(handBack(PlayRunner, EndStep()))
    check not compiles(handBack(PlayRunner, StartPlay()))
    check handBack(PlayRunner, EndPlay(run: 2, code: "closed")).name == "EndPlay"

  test "the model line says what it consumes and issues":
    let model = parseModel(readFile(currentSourcePath.parentDir.parentDir / "tools" / "para" / "studiodesk.em"), "studiodesk.em")
    check model.find("PlayRunner").edge("consumes").sorted == @["PlayStarted", "PlayStopRequested"]
    check model.find("PlayRunner").edge("issues").sorted == @["EndPlay", "PlayPhase"]

suite "Play and the steps share the one lock":
  var root: string
  var chat: ptr ChatState
  setup:
    hands = Hands()
    root = scratchRoot()
    chat = create(ChatState)
    initChat(chat, root, @[AgentAdapter(name: "stub", label: "Stub")])
  teardown:
    shutdownChat(chat)
    removeDir(root)

  type Racer = object
    chat: ptr ChatState
    go: ptr Atomic[bool]
    asPlay: bool
    ok: bool

  proc racer(r: ptr Racer) {.thread.} =
    while not r.go[].load: discard
    if r.asPlay: r.ok = r.chat.askPlay("pong", true).ok
    else: r.ok = r.chat.startStep("pong", "check", "").ok

  proc endPlay(code = "closed") =
    chat.lockDesk()
    discard chat.endPlayLocked(chat.windowLocked.run, code, "The game window was closed.", "")
    chat.unlockDesk()

  test "Play and a step started together are never both accepted":
    var playWon, stepWon = 0
    for i in 1 .. 40:
      var go: Atomic[bool]
      go.store(false)
      var a = Racer(chat: chat, go: addr go, asPlay: true)
      var b = Racer(chat: chat, go: addr go, asPlay: false)
      var ta, tb: Thread[ptr Racer]
      createThread(ta, racer, addr a)
      createThread(tb, racer, addr b)
      go.store(true)
      joinThread(ta)
      joinThread(tb)
      check a.ok != b.ok # exactly one of the two
      if a.ok:
        inc playWon
        endPlay()
      else:
        inc stepWon
        chat.endStep(chat.deskFacts("pong").stepId, 0)
    check playWon + stepWon == 40

  test "a step is refused while Play builds, with the words that say why, and goes ahead once the window opens":
    check chat.askPlay("pong", true).ok
    let refused = chat.startStep("pong", "check", "")
    check not refused.ok and refused.status == 409 and refused.code == "busy"
    check "built for Play" in refused.message
    check not chat.startNewGame("cat", @[]).ok
    check not chat.startLand("pong", "ab12", @["ab12"]).ok
    chat.lockDesk()
    discard chat.phasePlayLocked(chat.windowLocked.run, "starting", "Opening the game window…", "")
    chat.unlockDesk()
    let step = chat.startStep("pong", "check", "")
    check step.ok
    chat.endStep(step.turnId, 0)

  test "Play is refused while a step runs, and goes ahead when it is over":
    let step = chat.startStep("pong", "check", "")
    check step.ok
    let refused = chat.askPlay("pong", true)
    check not refused.ok and refused.status == 409 and refused.code == "busy"
    chat.endStep(step.turnId, 0)
    check chat.askPlay("pong", true).ok

  test "the window answers from the view: building, then a stop, then idle":
    check chat.window.state == "idle"
    check chat.askPlay("pong", true).ok
    check chat.window.state == "building"
    check chat.askStopPlay()
    check chat.window.code == "stopping"
    chat.lockDesk()
    check chat.endPlayLocked(chat.windowLocked.run, "", "The game was stopped.", "")
    chat.unlockDesk()
    check chat.window.state == "idle"
    check not chat.askStopPlay() # nothing left to stop
