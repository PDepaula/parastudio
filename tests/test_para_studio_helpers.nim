# Tests for the scout helpers inside `para studio`: the desk's `Helpers` view with its processor
# HelperRunner (tools/para/studiodesk.nim), the shell that runs a helper's supervisor thread
# (tools/para/studiohelpers.nim) and the routes in front of them (tools/para/studioapi.nim). The rules
# are scenarios in tests/studiodesk/scenarios.jsonl; the rules of `para helper` itself (counters, files,
# the status line) are in test_para_helpers.nim. What is pinned here is what those cannot show:
#
# - the processor starts the shell's thread inside the command and issues what the shell could not do
#   (a helper that did not start ends as failed, a stop with nothing left to end it ends it), and does
#   nothing when no shell lent it procs; a thread can hand back EndHelper and nothing else;
# - the real shell, against the real handler on a loopback port, with a stand-in agent program (a proc
#   that plays a script, no process, no network): a helper runs, shows on the page's route, ends, and
#   the studio's journal (studio.jsonl) holds HelperStarted and HelperEnded; Stop ends a helper; a counter
#   ends one as failed; the refusals are 400s and 409s; a helper started from a terminal counts against
#   the cap; closing the studio ends every helper it runs; a restart finds no ghost (what the log says was
#   working is `lost`).
# The only waits are bounded polls for a thread to have finished, never an assertion about time.

import std/[unittest, os, json, strutils, sequtils, algorithm, times]
import eversince
import tools/para/agent
import tools/para/helperrules
import tools/para/helpers
import tools/para/studiochat
import tools/para/studioapi
import tools/para/studiodesk
import studio_support

const game = "pong"

# --- the processor ---------------------------------------------------------------------------------

var opened, stopped: seq[string]
var openAnswer = true
var stopAnswer = true

proc fakeOpen(state: pointer, e: HelperStarted): bool {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    opened.add e.game & "/" & e.helper
    result = openAnswer

proc fakeStop(state: pointer, e: HelperStopRequested): bool {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    stopped.add e.game & "/" & e.helper
    result = stopAnswer

suite "the processor HelperRunner":
  var rt: Runtime[StudioDesk]
  setup:
    opened = @[]
    stopped = @[]
    openAnswer = true
    stopAnswer = true
    hands = Hands(openHelper: fakeOpen, stopHelper: fakeStop)
    rt = Runtime[StudioDesk](store: MemStore(), clock: proc (): int64 = 1_700_000_000_000)
  teardown:
    hands = Hands()

  proc start(topic = "story", count = 0, topics: seq[string] = @[]): Decision =
    rt.execute("StartHelper", %*{"game": game, "helper": "scout", "role": "scout", "topic": topic, "brief": "q?",
                                 "liveCount": count, "liveTopics": topics})
  proc rows(): seq[HelperRow] = answer(HelpersNow(game: ""), rt.app.helpers).rows

  test "a start the desk accepts is handed to the shell inside the command":
    check not start().refused
    check opened == @["pong/scout"]
    check rows().len == 1 and rows()[0].state == "working" and rows()[0].topic == "story"

  test "a start the desk refuses opens nothing":
    check start(topic = "../x").refused
    check start(count = maxLiveHelpers).refused
    check opened.len == 0 and rows().len == 0

  test "a thread that did not start ends the helper as failed":
    openAnswer = false
    check not start().refused
    check rows()[0].state == "failed" and rows()[0].why == "agent-error"

  test "Stop is handed to the shell, and the helper's own end follows":
    check not start().refused
    check not rt.execute("StopHelper", %*{"game": game, "helper": "scout"}).refused
    check stopped == @["pong/scout"] and rows()[0].stopping
    check not rt.execute("EndHelper", %*{"game": game, "helper": "scout", "outcome": "stopped", "why": "", "tools": 2, "report": ""}).refused
    check rows()[0].state == "stopped" and not rows()[0].stopping and rows()[0].tools == 2

  test "Stop with nothing left to end the helper ends it itself":
    check not start().refused
    stopAnswer = false
    check not rt.execute("StopHelper", %*{"game": game, "helper": "scout"}).refused
    check rows()[0].state == "stopped"

  test "a second stop while one is under way asks the shell once":
    check not start().refused
    check not rt.execute("StopHelper", %*{"game": game, "helper": "scout"}).refused
    check not rt.execute("StopHelper", %*{"game": game, "helper": "scout"}).refused
    check stopped.len == 1

  test "with no shell the desk alone still decides, and the processor does nothing":
    hands = Hands()
    check not start().refused
    check rows()[0].state == "working"
    check not rt.execute("StopHelper", %*{"game": game, "helper": "scout"}).refused
    check rows()[0].stopping

  test "the helpers' names the desk holds are capped, the oldest ended ones going first":
    for i in 1 .. maxHelperRows + 5:
      let id = "scout" & $i
      check not rt.execute("StartHelper", %*{"game": game, "helper": id, "role": "scout", "topic": "t" & $i, "brief": "q",
                                              "liveCount": 0, "liveTopics": []}).refused
      check not rt.execute("EndHelper", %*{"game": game, "helper": id, "outcome": "done", "why": "", "tools": 1, "report": "r"}).refused
    check rows().len == maxHelperRows
    check rows()[0].helper == "scout6" and rows()[^1].helper == "scout" & $(maxHelperRows + 5)

suite "the door a helper's thread hands its commands back through":
  test "it can hand back EndHelper and nothing else":
    check compiles(handBack(HelperRunner, EndHelper()))
    check not compiles(handBack(HelperRunner, StopHelper()))
    check not compiles(handBack(HelperRunner, StartHelper()))
    check not compiles(handBack(HelperRunner, EndPlay()))
    check handBack(HelperRunner, EndHelper(game: "pong", helper: "scout", outcome: "done")).name == "EndHelper"

  test "the model line says what it consumes and issues":
    let model = parseModel(readFile(currentSourcePath.parentDir.parentDir / "tools" / "para" / "studiodesk.em"), "studiodesk.em")
    check model.find("HelperRunner").edge("consumes").sorted == @["HelperStarted", "HelperStopRequested"]
    check model.find("HelperRunner").edge("issues") == @["EndHelper"]

  test "the desk's rules about a helper are the ones `para helper` uses":
    for (role, topic, brief, count, topics) in [("scout", "story", "q?", 0, @[""]), ("builder", "story", "q?", 0, @[""]),
        ("scout", "S t", "q?", 0, @[""]), ("scout", "story", "", 0, @[""]), ("scout", "story", "q?", 1, @["pong/story"]),
        ("scout", "story", "q?", maxLiveHelpers, @[""])]:
      var rt = Runtime[StudioDesk](store: MemStore(), clock: proc (): int64 = 0)
      let d = rt.execute("StartHelper", %*{"game": game, "helper": "scout", "role": role, "topic": topic, "brief": brief,
                                           "liveCount": count, "liveTopics": topics})
      check d.code == startRefusal(role, topic, brief, count, topics, game).code

# --- the real shell --------------------------------------------------------------------------------

type Script = object
  activities: int ## tool calls to report
  report: string ## written to games/pong/reports/<topic>.md ("" writes nothing)
  hold: bool ## block until ended
  touch: string ## a file besides the report, changed during the run (relative to the game's folder)

var script: Script

proc standIn(a: AgentAdapter, req: TurnRequest, ctl: ptr TurnControl, emit: EmitProc): TurnResult {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    # the topic is in the prompt: "Topic: <topic>"
    var topic = "story"
    for line in req.text.splitLines:
      let at = line.find("Topic: ")
      if at >= 0: topic = line[at + 7 .. ^1].strip
    for i in 1 .. script.activities:
      if ctl.isCancelled: break
      emit UiEvent(kind: ukActivity, text: "call " & $i)
    if script.report.len > 0 and not ctl.isCancelled:
      createDir(req.workDir / "games" / game / "reports")
      writeFile(req.workDir / "games" / game / "reports" / (topic & ".md"), script.report)
    if script.touch.len > 0: writeFile(req.workDir / "games" / game / script.touch, "changed by the scout")
    if script.hold:
      while not ctl.isCancelled: sleep(1)
    result = TurnResult(ok: not ctl.isCancelled, cancelled: ctl.isCancelled)

proc adapter(): AgentAdapter = AgentAdapter(name: "claude", label: "Claude", runTurn: standIn)

proc helpersOf(r: Running): JsonNode =
  parseJson(r.request("GET", "/api/helpers?game=" & game).body)

proc stateOf(r: Running, id: string): string =
  for h in r.helpersOf["helpers"]:
    if h["id"].getStr == id: return h["state"].getStr

proc waitFor(r: Running, id, want: string): bool =
  ## A bounded poll for the helper's thread to have reported (10 s at most): the test asserts what it
  ## reported, never how long it took.
  for _ in 0 ..< 2000:
    if r.stateOf(id) == want: return true
    sleep(5)

proc post(r: Running, path: string, body: JsonNode): Reply =
  r.request("POST", path, body = $body)

proc startScout(r: Running, topic: string, extra: JsonNode = newJObject()): Reply =
  var b = %*{"game": game, "topic": topic, "ticket": "how do sounds work?"}
  for k, v in extra: b[k] = v
  r.post("/api/helper/start", b)

proc journal(root: string): seq[JsonNode] =
  let f = root / "tmp" / "studio" / "studio.jsonl"
  if fileExists(f):
    for line in lines(f):
      if line.strip.len > 0: result.add parseJson(line)

proc kinds(root: string): seq[string] =
  for e in journal(root):
    if e["kind"].getStr in ["HelperStarted", "HelperEnded"]: result.add e["kind"].getStr

suite "the studio runs a helper":
  var root: string
  var r: Running
  setup:
    script = Script(activities: 3, report: "# story\n")
    root = newGameRepo(game)
    r = startStudio(root, "unused", game, adapter = adapter(), helperTickMs = 2)
  teardown:
    r.stop()
    removeDir(root)

  test "a scout runs, writes its report, and is done; the journal tells it as two facts":
    let s = r.startScout("story")
    check s.status == 200
    let j = parseJson(s.body)
    check j["id"].getStr == "scout" and j["report"].getStr == "games/pong/reports/story.md"
    check r.waitFor("scout", "done")
    let h = r.helpersOf["helpers"][0]
    check h["topic"].getStr == "story" and h["tools"].getInt == 3 and h["report"].getStr == "games/pong/reports/story.md" and h["why"].getStr == ""
    check readFile(root / "games" / game / "reports" / "story.md") == "# story\n"
    check kinds(root) == @["HelperStarted", "HelperEnded"]
    let ended = journal(root).filterIt(it["kind"].getStr == "HelperEnded")[0]["data"]
    check ended["outcome"].getStr == "done" and ended["tools"].getInt == 3 and ended["report"].getStr == "games/pong/reports/story.md"
    check readStatus(root, game, "scout").state == "done" # the same fact at the edge, as plain text
    check helperDigest(root, game, int64(readStatus(root, game, "scout").at)).startsWith("Scouts: 1 report ready (story)")

  test "the question reaches the agent's standard input and nowhere else; the journal never holds it":
    check r.startScout("story").status == 200
    check r.waitFor("scout", "done")
    check readRecord(root, game, "scout").rec.brief == "how do sounds work?"
    for e in journal(root): check "how do sounds" notin $e

  test "Stop ends a helper that is working, and the report is not touched":
    script.hold = true
    script.report = ""
    check r.startScout("story").status == 200
    check r.waitFor("scout", "working")
    check parseJson(r.post("/api/helper/stop", %*{"game": game, "id": "scout"}).body)["stopped"].getBool
    check r.waitFor("scout", "stopped")
    check readStatus(root, game, "scout").state == "stopped"
    check kinds(root) == @["HelperStarted", "HelperEnded"]
    check parseJson(r.post("/api/helper/stop", %*{"game": game, "id": "scout"}).body)["stopped"].getBool == false # nothing left to stop

  test "a counter ends a helper as failed, and the journal says why":
    script.activities = 200 # the default budget is 80 tool calls
    script.hold = true
    check r.startScout("story").status == 200
    check r.waitFor("scout", "failed")
    let h = r.helpersOf["helpers"][0]
    check h["why"].getStr == "budget" and h["tools"].getInt == defaultToolBudget + 1
    let ended = journal(root).filterIt(it["kind"].getStr == "HelperEnded")[0]["data"]
    check ended["why"].getStr == "budget"

  test "a helper that wrote no report did not finish":
    script.report = ""
    check r.startScout("story").status == 200
    check r.waitFor("scout", "failed")
    check r.helpersOf["helpers"][0]["why"].getStr == "no-report"

  test "a helper that changed another file in the game failed, and the journal says why":
    script.touch = "rules.nim"
    check r.startScout("story").status == 200
    check r.waitFor("scout", "failed")
    check r.helpersOf["helpers"][0]["why"].getStr == "touched-files"
    let ended = journal(root).filterIt(it["kind"].getStr == "HelperEnded")[0]["data"]
    check ended["why"].getStr == "touched-files"

  test "the refusals are plain 400s and 409s, and nothing is started":
    check r.startScout("../x").status == 400
    check parseJson(r.startScout("../x").body)["error"].getStr == "bad-topic"
    check r.post("/api/helper/start", %*{"game": game, "topic": "story", "ticket": " "}).status == 400
    check parseJson(r.post("/api/helper/start", %*{"game": game, "topic": "story", "ticket": " "}).body)["error"].getStr == "bad-brief"
    check parseJson(r.startScout("story", %*{"agent": "gpt"}).body)["error"].getStr == "bad-agent"
    check parseJson(r.startScout("story", %*{"speed": "warp"}).body)["error"].getStr == "bad-speed"
    check r.post("/api/helper/start", %*{"game": "tank", "topic": "story", "ticket": "q"}).status == 404
    check r.request("GET", "/api/helpers?game=tank").status == 404
    check kinds(root).len == 0 and listHelpers(root, 1000).len == 0

  test "one scout per report, and no more than the cap at once":
    script.hold = true
    script.report = ""
    check r.startScout("story").status == 200
    let same = r.startScout("story")
    check same.status == 409 and parseJson(same.body)["error"].getStr == "topic-taken"
    check r.startScout("art").status == 200
    check r.startScout("menu").status == 200
    let full = r.startScout("levels")
    check full.status == 409 and parseJson(full.body)["error"].getStr == "too-many"
    check r.helpersOf["working"].getInt == 3
    check r.helpersOf["helpers"].mapIt(it["id"].getStr) == @["scout", "scout2", "scout3"]

  test "a helper started from a terminal counts against the cap, and so does its report":
    script.hold = true
    script.report = ""
    for topic in ["a", "b", "c"]:
      let rec = planHelper(root, game, "scout", topic, "q", "claude", "quick", defaultLimits, int64(epochTime()))
      check beginHelper(root, rec, int64(epochTime()))
    let full = r.startScout("story")
    check full.status == 409 and parseJson(full.body)["error"].getStr == "too-many"
    forgetHelper(root, game, "scout")
    check parseJson(r.startScout("b").body)["error"].getStr == "topic-taken"
    check r.startScout("story").status == 200

  test "closing the studio ends the helpers it runs":
    script.hold = true
    script.report = ""
    check r.startScout("story").status == 200
    check r.waitFor("scout", "working")
    shutdownStudio(r.st)
    check readStatus(root, game, "scout").state == "stopped"
    check kinds(root) == @["HelperStarted", "HelperEnded"]

suite "a restart finds no ghost":
  test "a helper the log says was working is ended as lost, once, and the page agrees":
    script = Script(activities: 0)
    let root = newGameRepo(game)
    defer: removeDir(root)
    createDir(root / "tmp" / "studio")
    writeFile(root / "tmp" / "studio" / "studio.jsonl",
      $(%*{"seq": 1, "at": 1, "kind": "HelperStarted", "data": {"game": game, "helper": "scout", "role": "scout", "topic": "story"}}) & "\n" &
      $(%*{"seq": 2, "at": 2, "kind": "HelperStarted", "data": {"game": game, "helper": "scout2", "role": "scout", "topic": "art"}}) & "\n" &
      $(%*{"seq": 3, "at": 3, "kind": "HelperEnded", "data": {"game": game, "helper": "scout2", "outcome": "done", "why": "", "tools": 4, "report": "games/pong/reports/art.md"}}) & "\n")
    var first = startStudio(root, "unused", game, adapter = adapter(), helperTickMs = 2)
    check first.stateOf("scout") == "lost" and first.stateOf("scout2") == "done"
    check journal(root).filterIt(it["kind"].getStr == "HelperEnded").len == 2
    first.stop()
    var second = startStudio(root, "unused", game, adapter = adapter(), helperTickMs = 2) # a second restart changes nothing
    check second.stateOf("scout") == "lost"
    check journal(root).filterIt(it["kind"].getStr == "HelperEnded").len == 2
    check journal(root).mapIt(it["seq"].getInt).sorted.deduplicate.len == 4 # the log went on from where it was
    second.stop()
