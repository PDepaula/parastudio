# Tests for the scout helpers para runs (tools/para/helperrules.nim, helpers.nim, helpercmd.nim).
# Everything runs on scratch folders with a stand-in agent program (a proc that plays a script of events
# and writes the files a real scout would) and a stand-in clock, so no agent is started, no child
# process is made and nothing waits on the wall clock. What is pinned:
#
# - the rules (a report's name, a question, the cap of helpers, one scout per report) and the status
#   line's shape, which the studio's desk and `para helper` share;
# - the three counters (timeout, output silence, tool-call budget) as pure numbers: they are driven
#   with the time given to them, and the first to trip stays tripped;
# - a supervised helper's end: done only with a fresh report and no other file changed, and failed with
#   the counter that tripped, with the agent's own failure, with no report, or with a file besides its
#   report; stopped by a `.stop` file or by the studio's control; its record and its one status line;
# - what a helper is told, and that nothing of the question reaches a command line;
# - the commands: start (refusals, the record, the child it starts), list, stop, and the supervisor's
#   own entry, and the one digest line the producer reads.

import std/[unittest, os, strutils, sequtils, tempfiles, json, atomics, tables]
import tools/para/agent
import tools/para/helperrules
import tools/para/helpers
import tools/para/helpercmd
import tools/para/savepoint

const game = "pong"

# --- the stand-ins -------------------------------------------------------------------------------

type
  Step = object
    ev: UiEvent
    at: float ## the clock reads this when the event arrives

  Script = object
    steps: seq[Step]
    report: string ## written to the game's reports/story.md during the run ("" writes nothing)
    reportTo: string ## where, relative to the game's folder
    extra: string ## a second file written during the run, relative to the game's folder
    stopMark: string ## a file written during the run (the stop request)
    hold: bool ## block until the supervisor ends the run
    jumpTo: float ## the clock jumps here after the steps (-1 = stays)
    ok: bool
    cancelItself: bool ## the run calls the studio's control, as the Stop button does

var script: Script
var fakeMs: Atomic[int64]
var seenText, seenDir: string
var seenSpeed: Speed
var midStatus: string

proc setNow(seconds: float) = fakeMs.store(int64(seconds * 1000))

proc fakeClock(): float {.gcsafe.} = float(fakeMs.load) / 1000.0

proc activity(text: string): UiEvent = UiEvent(kind: ukActivity, text: text)

proc standIn(a: AgentAdapter, req: TurnRequest, ctl: ptr TurnControl, emit: EmitProc): TurnResult {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    seenText = req.text
    seenDir = req.workDir
    seenSpeed = req.speed
    let gameDir = req.workDir / "games" / game
    for st in script.steps:
      setNow(st.at)
      emit st.ev
    if script.jumpTo >= 0: setNow(script.jumpTo)
    midStatus = try: readFile(req.workDir / "tmp" / "helpers" / (game & ".scout.status")) except IOError: ""
    if script.report.len > 0:
      createDir((gameDir / script.reportTo).parentDir)
      writeFile(gameDir / script.reportTo, script.report)
    if script.extra.len > 0:
      createDir((gameDir / script.extra).parentDir)
      writeFile(gameDir / script.extra, "changed")
    if script.stopMark.len > 0: writeFile(script.stopMark, "stop\n")
    if script.cancelItself: ctl.cancel("stop")
    if script.hold:
      while not ctl.isCancelled: sleep(1)
    result = TurnResult(ok: script.ok and not ctl.isCancelled, cancelled: ctl.isCancelled)

proc standInAdapter(): AgentAdapter =
  AgentAdapter(name: "claude", label: "Claude", runTurn: standIn)

proc resetScript() =
  script = Script(reportTo: "reports/story.md", jumpTo: -1, ok: true)
  seenText = ""
  seenDir = ""
  midStatus = ""
  setNow(1000)

proc scratch(): string =
  ## A checkout with games/pong/ (a rules file and a PLAN.md) and nothing else.
  result = createTempDir("para_helpers_", "")
  createDir(result / "games" / game)
  writeFile(result / "games" / game / "rules.nim", "# rules\n")
  writeFile(result / "games" / game / "PLAN.md", "# plan\n")

proc newRecord(root: string, topic = "story", limits = defaultLimits): HelperRecord =
  let made = prepareHelper(root, game, "scout", topic, "how do sounds work?", "claude", "quick", limits, 1000)
  doAssert made.ok
  made.rec

proc supervise(root: string, rec: HelperRecord, tickMs = 1): HelperEnd =
  let ctl = newTurnControl()
  defer: freeTurnControl(ctl)
  superviseHelper(SuperviseSpec(root: root, rec: rec, adapter: standInAdapter(), speed: spQuick, clock: fakeClock, tickMs: tickMs), ctl)

# --- the rules -----------------------------------------------------------------------------------

suite "the rules a helper starts under":
  test "a report's name is a plain name":
    for ok in ["story", "art", "menu-ui", "level_2", "a", "x".repeat(maxTopicChars)]: check goodTopic(ok)
    for bad in ["", "Story", "2fast", "-x", "a b", "../story", "a/b", "a.md", "é", "x".repeat(maxTopicChars + 1), "story\n"]:
      check not goodTopic(bad)

  test "a helper's id is a role and a number, like a lane's":
    for ok in ["scout", "scout2", "scout12"]: check goodHelperId(ok)
    for bad in ["", "builder", "scout0", "scout02", "scout2x", "../scout", "scout.1", "scout12345"]: check not goodHelperId(bad)
    check roleOfHelper("scout3") == "scout"

  test "a question is one to answer: not empty, not long, no control characters":
    check validBrief("how do sounds work?") == ""
    check validBrief("two\nlines are fine\tand tabs") == ""
    check validBrief("   ").len > 0
    check validBrief("x".repeat(maxBriefChars + 1)).len > 0
    check validBrief("bell\x07").len > 0
    check validBrief("nul\0").len > 0

  test "the refusals come in a fixed order, each with a code and plain words":
    check startRefusal("scout", "story", "q?", 0, [], game).code == ""
    check startRefusal("builder", "story", "q?", 0, [], game).code == "badRole"
    check startRefusal("scout", "../x", "q?", 0, [], game).code == "badTopic"
    check startRefusal("scout", "story", " ", 0, [], game).code == "badBrief"
    check startRefusal("scout", "story", "q?", 1, ["pong/story"], game).code == "topicTaken"
    check startRefusal("scout", "story", "q?", maxLiveHelpers, [], game).code == "tooMany"
    check startRefusal("scout", "story", "q?", 1, ["tank/story"], game).code == "" # another game's report is not in the way
    check startRefusal("scout", "story", "q?", maxLiveHelpers, ["pong/story"], game).code == "topicTaken" # the report first
    for r in [startRefusal("builder", "story", "q?", 0, [], game), startRefusal("scout", "x y", "q?", 0, [], game),
              startRefusal("scout", "story", "", 0, [], game), startRefusal("scout", "story", "q?", 9, [], game)]:
      check r.message.len > 0 and "\n" notin r.message

suite "the one status line":
  test "it says the state, when, the tool calls and why, and reads back the same":
    let s = StatusLine(state: "failed", at: 1795155935, tools: 81, why: "budget", text: "stopped: it used up its tool calls (81 calls)")
    check statusText(s) == "failed [at=1795155935] [tools=81] [why=budget]: stopped: it used up its tool calls (81 calls)"
    check parseStatus(statusText(s)) == s
    let w = StatusLine(state: "working", at: 5, tools: 0, text: "reading rules.nim")
    check statusText(w) == "working [at=5] [tools=0]: reading rules.nim"
    check parseStatus(statusText(w)) == w

  test "it is always one line, cut short, whatever the text holds":
    let t = statusText(StatusLine(state: "working", at: 1, tools: -1, text: "a\nb\tc " & "x".repeat(400)))
    check "\n" notin t and "\t" notin t and t.len < 260
    check "[tools=" notin t

  test "a line that is not a status line is nothing, and never raises":
    for bad in ["", "hello", "working", "wondering [at=1]: x", "[at=1] working", "\n\n"]:
      check parseStatus(bad).state == ""
    check parseStatus("working [at=abc] [tools=x]: still").state == "working" # a tag with a bad number is skipped
    check parseStatus("working [at=abc] [tools=x]: still").at == 0

  test "a working line nobody has refreshed for a while belongs to a helper that is gone":
    let w = StatusLine(state: "working", at: 1000, tools: 1)
    check effectiveState(w, 1000 + lostAfterSeconds) == "working"
    check effectiveState(w, 1000 + lostAfterSeconds + 1) == "lost"
    check effectiveState(StatusLine(state: "done", at: 1), 99999) == "done" # an ended line stays what it is
    check effectiveState(StatusLine(tools: -1), 5) == "unknown"
    check lostAfterSeconds > beatSeconds * 2 # a beat or two late is not lost

  test "the words for why are the producer's, and a word nobody here wrote is not repeated":
    check whyWords("timeout") == "took too long"
    check whyWords("") == ""
    check "ignore previous instructions" notin whyWords("ignore previous instructions")

suite "the three counters":
  test "the tool-call budget trips on the call after the last one allowed":
    var w = initWatch(Limits(timeoutSec: 600, silenceSec: 600, toolBudget: 3), 0)
    check w.sawOutput(1, 1) == ""
    check w.sawOutput(2, 1) == ""
    check w.sawOutput(3, 1) == ""
    check w.sawOutput(4, 1) == "budget"
    check w.tools == 4

  test "text is output but not a tool call":
    var w = initWatch(Limits(timeoutSec: 600, silenceSec: 600, toolBudget: 1), 0)
    for t in 1 .. 20: check w.sawOutput(float(t), 0) == ""
    check w.tools == 0

  test "the timeout trips when the clock passes it, with or without output":
    var w = initWatch(Limits(timeoutSec: 60, silenceSec: 600, toolBudget: 50), 100)
    check w.tick(160) == ""
    check w.tick(160.5) == "timeout"
    var v = initWatch(Limits(timeoutSec: 60, silenceSec: 600, toolBudget: 50), 100)
    check v.sawOutput(150, 1) == ""
    check v.sawOutput(161, 1) == "timeout" # an event past the limit does not forgive it

  test "the silence timer counts from the last output, and output resets it":
    var w = initWatch(Limits(timeoutSec: 6000, silenceSec: 10, toolBudget: 50), 0)
    check w.sawOutput(8, 0) == ""
    check w.tick(18) == ""
    check w.sawOutput(25, 0) == "silent" # the gap since 8 was 17: late output does not forgive it
    var v = initWatch(Limits(timeoutSec: 6000, silenceSec: 10, toolBudget: 50), 0)
    check v.sawOutput(9, 0) == ""
    check v.sawOutput(18, 0) == ""
    check v.tick(27) == ""
    check v.tick(28.5) == "silent"

  test "the first counter to trip stays tripped, and a tripped watch counts no more":
    var w = initWatch(Limits(timeoutSec: 60, silenceSec: 10, toolBudget: 2), 0)
    check w.tick(11) == "silent"
    check w.sawOutput(12, 1) == "silent"
    check w.tick(100) == "silent" # not timeout: it was silence first
    check w.tools == 0

  test "a limit of zero is no limit":
    var w = initWatch(Limits(), 0)
    check w.sawOutput(99999, 500) == ""
    check w.tick(999999) == ""

# --- the files at the edge -------------------------------------------------------------------------

suite "a helper's files":
  var root: string
  setup:
    root = scratch()
    resetScript()
  teardown: removeDir(root)

  test "a new helper gets a record and one working line, and the first id is the role":
    let r = newRecord(root)
    check r.id == "scout" and r.report == "games/pong/reports/story.md" and r.role == "scout"
    check fileExists(root / "tmp" / "helpers" / "pong.scout.json")
    let line = readStatus(root, game, "scout")
    check line.state == "working" and line.at == 1000 and line.tools == 0
    let back = readRecord(root, game, "scout")
    check back.found and back.rec == r
    check readFile(root / "tmp" / "helpers" / "pong.scout.status").count('\n') == 1

  test "the next ids count up, and an ended helper on the same topic is replaced":
    discard newRecord(root, "story")
    check newRecord(root, "art").id == "scout2"
    check newRecord(root, "menu").id == "scout3"
    var done = readRecord(root, game, "scout").rec
    done.outcome = "done"
    check writeRecord(root, done)
    discard writeStatus(root, game, "scout", StatusLine(state: "done", at: 1100, tools: 4, text: "report ready"))
    let again = newRecord(root, "story") # re-run: the old record (done) goes, the id is the next free one
    check again.id == "scout4"
    check not readRecord(root, game, "scout").found and not fileExists(root / "tmp" / "helpers" / "pong.scout.status")
    check listHelpers(root, 1000).mapIt(it.rec.id) == @["scout2", "scout3", "scout4"]

  test "a record is trusted only for the game and id its file name says, and only with a plain topic":
    let r = newRecord(root)
    var j = parseJson(readFile(recordFile(root, game, "scout")))
    j["topic"] = %"../../etc/x"
    writeFile(recordFile(root, game, "scout"), $j)
    check not readRecord(root, game, "scout").found
    j["topic"] = %"story"
    j["game"] = %"tank"
    writeFile(recordFile(root, game, "scout"), $j)
    check not readRecord(root, game, "scout").found
    writeFile(recordFile(root, game, "scout"), "not json")
    check not readRecord(root, game, "scout").found
    check listHelpers(root, 1000).len == 0
    check r.id == "scout"

  test "the list shows a working helper as lost once its line is stale, and an ended record settles a cut-short line":
    let r = newRecord(root)
    check listHelpers(root, 1000)[0].state == "working"
    check listHelpers(root, 1000 + lostAfterSeconds + 1)[0].state == "lost"
    check liveHelpers(root, 1000).count == 1 and liveHelpers(root, 1000).topics == @["pong/story"]
    check liveHelpers(root, 1000 + lostAfterSeconds + 1).count == 0
    var ended = r
    ended.outcome = "failed"
    ended.why = "timeout"
    check writeRecord(root, ended) # the line still says working (the supervisor was killed between its two writes)
    check listHelpers(root, 1001)[0].state == "failed"

  test "forgetting removes the record, the line and a stop request, and leaves the report alone":
    createDir(root / "games" / game / "reports")
    writeFile(root / "games" / game / "reports" / "story.md", "kept")
    discard newRecord(root)
    writeFile(stopFile(root, game, "scout"), "stop\n")
    forgetHelper(root, game, "scout")
    check not fileExists(recordFile(root, game, "scout")) and not fileExists(statusFile(root, game, "scout")) and
      not fileExists(stopFile(root, game, "scout"))
    check readFile(root / "games" / game / "reports" / "story.md") == "kept"

suite "watching the game's folder":
  var dir: string
  setup:
    dir = createTempDir("para_listing_", "")
    writeFile(dir / "a.nim", "one")
    createDir(dir / "reports")
    writeFile(dir / "reports" / "story.md", "old")
    createDir(dir / ".git")
    writeFile(dir / ".git" / "HEAD", "ref")
  teardown: removeDir(dir)

  test "a file added, changed or removed is a difference, git's own folder is not looked at":
    let before = listGame(dir)
    check before.complete and before.sigs.len == 2 and ".git/HEAD" notin before.sigs
    writeFile(dir / "b.nim", "new")
    writeFile(dir / "a.nim", "changed!") # a different size, so it differs whatever the clock says
    removeFile(dir / "reports" / "story.md")
    writeFile(dir / ".git" / "HEAD", "other")
    check differences(before, listGame(dir)) == @["a.nim", "b.nim", "reports/story.md"]

  test "nothing changed is no difference":
    let before = listGame(dir)
    check differences(before, listGame(dir)).len == 0

  test "a folder with more files than the cap is not claimed about at all":
    for i in 1 .. 5: writeFile(dir / ("f" & $i & ".txt"), "x")
    let big = listGame(dir, cap = 3)
    check not big.complete
    writeFile(dir / "late.txt", "y")
    check differences(big, listGame(dir, cap = 3)).len == 0
    check differences(listGame(dir), big).len == 0

# --- running one helper ---------------------------------------------------------------------------

suite "supervising a helper":
  var root: string
  setup:
    root = scratch()
    resetScript()
  teardown: removeDir(root)

  test "a report written and nothing else changed: done, with the record and the line to say so":
    script.steps = @[Step(ev: activity("Reading rules.nim"), at: 1001), Step(ev: UiEvent(kind: ukSay, text: "found it"), at: 1002),
                     Step(ev: activity("Searching the project"), at: 1003)]
    script.report = "# story\n"
    let rec = newRecord(root)
    let ended = supervise(root, rec)
    check ended.outcome == "done" and ended.why == "" and ended.tools == 2 and ended.report == "games/pong/reports/story.md"
    let line = readStatus(root, game, "scout")
    check line.state == "done" and line.tools == 2 and line.text == "report ready: games/pong/reports/story.md"
    let back = readRecord(root, game, "scout").rec
    check back.outcome == "done" and back.tools == 2 and back.ended == 1003 and back.started == 1000
    check listHelpers(root, 1004)[0].state == "done"

  test "what the helper is told: the playbook, the topic, its one file, and the question; never on a command line":
    script.report = "# story\n"
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    discard supervise(root, newRecord(root))
    check "You are a scout helper" in seenText and "not the producer" in seenText
    check ".agents/skills/scout/SKILL.md" in seenText
    check "Write only games/pong/reports/story.md" in seenText
    check seenText.endsWith("Question:\nhow do sounds work?\n")
    check seenDir == root and seenSpeed == spQuick
    check "director" notin seenText.replace("do not talk to the director", "") # no studio voice in the prompt

  test "the status line is rewritten as tool calls pile up":
    for i in 1 .. 6: script.steps.add Step(ev: activity("call " & $i), at: 1000.0 + i.float)
    script.report = "# story\n"
    discard supervise(root, newRecord(root))
    let mid = parseStatus(midStatus)
    check mid.state == "working" and mid.tools == 5 and mid.text == "call 5" # rewritten at the fifth call, not on every one

  test "the tool-call budget stops a helper that keeps calling tools, and the line says why":
    for i in 1 .. 9: script.steps.add Step(ev: activity("call " & $i), at: 1000.0 + i.float)
    script.hold = true
    script.report = "# partial\n"
    let rec = newRecord(root, limits = Limits(timeoutSec: 600, silenceSec: 600, toolBudget: 4))
    let ended = supervise(root, rec)
    check ended.outcome == "failed" and ended.why == "budget" and ended.tools == 5
    let line = readStatus(root, game, "scout")
    check line.state == "failed" and line.why == "budget" and "stopped: it used up its tool calls" in line.text
    check readRecord(root, game, "scout").rec.why == "budget"

  test "the silence timer stops a helper that goes quiet":
    script.steps = @[Step(ev: activity("Reading rules.nim"), at: 1010)]
    script.jumpTo = 1400 # nothing more arrives, and the clock moves on past the silence limit
    script.hold = true
    let ended = supervise(root, newRecord(root, limits = Limits(timeoutSec: 6000, silenceSec: 300, toolBudget: 50)))
    check ended.outcome == "failed" and ended.why == "silent"
    check "went quiet" in readStatus(root, game, "scout").text

  test "the wall-clock timeout stops a helper that is still producing output":
    script.steps = @[Step(ev: activity("one"), at: 1010), Step(ev: activity("two"), at: 1090), Step(ev: activity("three"), at: 1700)]
    script.hold = true
    let ended = supervise(root, newRecord(root, limits = Limits(timeoutSec: 600, silenceSec: 6000, toolBudget: 50)))
    check ended.outcome == "failed" and ended.why == "timeout" and ended.tools == 2 # the third call came too late to count

  test "a helper that ends without a report did not finish":
    script.steps = @[Step(ev: activity("Reading rules.nim"), at: 1001)]
    let ended = supervise(root, newRecord(root))
    check ended.outcome == "failed" and ended.why == "no-report"
    check "ended without writing its report" in readStatus(root, game, "scout").text

  test "a report left from an earlier run is not this run's report":
    createDir(root / "games" / game / "reports")
    writeFile(root / "games" / game / "reports" / "story.md", "# old\n")
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    let ended = supervise(root, newRecord(root))
    check ended.outcome == "failed" and ended.why == "no-report"

  test "a re-run that rewrites the report is done":
    createDir(root / "games" / game / "reports")
    writeFile(root / "games" / game / "reports" / "story.md", "# old\n")
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    script.report = "# new and longer\n"
    check supervise(root, newRecord(root)).outcome == "done"

  test "an empty report is no report":
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    script.report = " "
    check supervise(root, newRecord(root)).outcome == "done" # one space is a file with content
    resetScript()
    createDir(root / "games" / game / "reports")
    writeFile(root / "games" / game / "reports" / "story.md", "")
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    check supervise(root, newRecord(root, "other")).why == "no-report"

  test "a file changed besides the report is named on a finished helper, as a caution and not a failure; nothing is reverted":
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    script.report = "# story\n"
    script.extra = "rules.nim"
    let ended = supervise(root, newRecord(root))
    check ended.outcome == "done" and ended.why == "touched-files" and ended.touched == @["rules.nim"]
    let line = readStatus(root, game, "scout")
    check line.state == "done" and line.why == "touched-files" and "rules.nim" in line.text and "your own edits" in line.text
    check readRecord(root, game, "scout").rec.touched == @["rules.nim"]
    check readFile(root / "games" / game / "reports" / "story.md") == "# story\n"
    check readFile(root / "games" / game / "rules.nim") == "changed"
    check listHelpers(root, 1004)[0].state == "done"

  test "another scout's report, written meanwhile, is not a change to the game":
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    script.report = "# story\n"
    script.extra = "reports/art.md" # a second scout finishing beside this one
    let ended = supervise(root, newRecord(root))
    check ended.outcome == "done" and ended.why == "" and ended.touched.len == 0

  test "the agent's own failure is the helper's, with what it said, redacted":
    script.steps = @[Step(ev: UiEvent(kind: ukError, text: "Claude stopped. Bearer abcdefghijklmnop"), at: 1001)]
    script.ok = false
    let ended = supervise(root, newRecord(root))
    check ended.outcome == "failed" and ended.why == "agent-error"
    let text = readStatus(root, game, "scout").text
    check "Claude stopped" in text and "abcdefghijklmnop" notin text

  test "a stop request file ends the helper as stopped, and the file is cleaned up":
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    script.stopMark = stopFile(root, game, "scout")
    script.hold = true
    script.report = "# partial\n"
    let ended = supervise(root, newRecord(root))
    check ended.outcome == "stopped" and ended.why == ""
    check readStatus(root, game, "scout").state == "stopped"
    check not fileExists(stopFile(root, game, "scout"))

  test "the studio's control ends the helper as stopped too":
    script.steps = @[Step(ev: activity("x"), at: 1001)]
    script.cancelItself = true
    check supervise(root, newRecord(root)).outcome == "stopped"

  test "a counter that tripped wins over a stop that came after it":
    for i in 1 .. 4: script.steps.add Step(ev: activity("call " & $i), at: 1000.0 + i.float)
    script.cancelItself = true
    script.hold = true
    let ended = supervise(root, newRecord(root, limits = Limits(timeoutSec: 600, silenceSec: 600, toolBudget: 2)))
    check ended.why == "budget"

# --- the one line the producer reads --------------------------------------------------------------

suite "the digest line":
  var root: string
  setup:
    root = scratch()
    resetScript()
  teardown: removeDir(root)

  proc endWith(topic, outcome, why: string) =
    let r = newRecord(root, topic)
    var e = r
    e.outcome = outcome
    e.why = why
    discard writeRecord(root, e)
    discard writeStatus(root, game, r.id, StatusLine(state: outcome, at: 1001, tools: 3, why: why, text: "x"))

  test "no helpers is no line":
    check helperDigest(root, game, 1000) == ""

  test "reports ready, helpers that did not finish and helpers still working, each named":
    endWith("story", "done", "")
    endWith("art", "done", "")
    endWith("menu", "failed", "timeout")
    endWith("levels", "failed", "budget")
    endWith("sound", "stopped", "")
    discard newRecord(root, "ui") # working
    let line = helperDigest(root, game, 1001)
    check line.startsWith("Scouts: 2 reports ready (story, art); 3 did not finish (menu: took too long, levels: used up its tool calls, sound: stopped); 1 still working (ui).")
    check "\n" notin line and "tmp/para helper list" in line

  test "a finished helper that left other files changed is still ready, with the caution beside it":
    endWith("story", "done", "")
    endWith("art", "done", "touched-files")
    let line = helperDigest(root, game, 1001)
    check line.startsWith("Scouts: 2 reports ready (story, art); files besides the report changed while art ran (")
    check "\n" notin line

  test "a helper whose line went stale is one that did not finish":
    discard newRecord(root, "ui")
    check helperDigest(root, game, 1000).contains("1 still working (ui)")
    check helperDigest(root, game, 1000 + lostAfterSeconds + 1).contains("1 did not finish (ui: disappeared before it finished")

  test "only that game's helpers, and a long list is cut":
    endWith("story", "done", "")
    createDir(root / "games" / "tank")
    check helperDigest(root, "tank", 1001) == ""
    for t in ["a", "b", "c", "d", "e", "f", "g"]: endWith(t, "done", "")
    check "and 3 more" in helperDigest(root, game, 1001)

# --- the command -----------------------------------------------------------------------------------

var spawned: seq[seq[string]]
var spawnAnswer = ""
var installedAgents = @["claude", "codex"]

proc fakeSpawn(root, game, id: string): string {.gcsafe.} =
  {.cast(gcsafe).}:
    spawned.add @[game, id]
    spawnAnswer

proc testEnv(): HelperEnv =
  HelperEnv(
    now: proc (): int64 {.closure, gcsafe.} = {.cast(gcsafe).}: int64(fakeMs.load div 1000),
    spawn: fakeSpawn,
    installed: proc (name: string): bool {.closure, gcsafe.} = {.cast(gcsafe).}: name in installedAgents,
    adapter: proc (name: string): AgentAdapter {.closure, gcsafe.} = standInAdapter(),
    clock: fakeClock, tickMs: 1, stopPolls: 0, stopPollMs: 0)

suite "para helper":
  var root: string
  setup:
    root = scratch()
    resetScript()
    spawned = @[]
    spawnAnswer = ""
    installedAgents = @["claude", "codex"]
  teardown: removeDir(root)

  proc helper(args: varargs[string]): tuple[output: string, code: int] =
    runHelperWith(root, testEnv(), @args)

  test "help, and an unknown command or flag is a usage error":
    check helper().code == 0 and helper("--help").output.startsWith("para helper start <game>")
    check helper("bogus").code == 2 and "Valid commands: helper start, helper list, helper stop" in helper("bogus").output
    check helper("start", game, "--bogus").code == 2
    check helper("start").code == 2 and helper("start", game).code == 2
    check helper("start", game, "--for", "scout", "--topic", "story", "--tools", "0").code == 2
    check helper("start", game, "--for", "scout", "--topic", "story", "--timeout", "999").code == 2
    check helper("stop", game).code == 2 and helper("list", "x").code == 2

  test "start: the record, the status line, the child, and the facts the producer needs":
    let r = helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "how do sounds work?")
    check r.code == 0
    check r.output.startsWith("helper: scout\ngame: pong\nrole: scout\ntopic: story\nreport: games/pong/reports/story.md\n" &
      "status: tmp/helpers/pong.scout.status\nagent: claude (quick)\nlimits: 15 min, 5 min without output, 80 tool calls\n")
    check spawned == @[@[game, "scout"]]
    let rec = readRecord(root, game, "scout").rec
    check rec.brief == "how do sounds work?" and rec.agent == "claude" and rec.speed == "quick" and rec.limits == defaultLimits
    check readStatus(root, game, "scout").state == "working"

  test "start: the flags set the agent, the speed and the three limits":
    let r = helper("start", game, "--for", "scout", "--topic", "art", "--ticket", "q?", "--agent", "codex", "--speed", "deep",
                   "--timeout", "30", "--silence", "2", "--tools", "12")
    check r.code == 0 and "agent: codex (deep)" in r.output and "limits: 30 min, 2 min without output, 12 tool calls" in r.output
    let rec = readRecord(root, game, "scout").rec
    check rec.limits == Limits(timeoutSec: 1800, silenceSec: 120, toolBudget: 12) and rec.speed == "deep"

  test "start: with no --agent, the first installed one":
    installedAgents = @["codex"]
    check helper("start", game, "--for", "scout", "--topic", "art", "--ticket", "q?").output.contains("agent: codex (quick)")

  test "start: refusals say why and start nothing":
    for (args, words) in [
        (@["start", game, "--for", "builder", "--topic", "story", "--ticket", "q"], "Only a scout"),
        (@["start", game, "--for", "scout", "--topic", "../x", "--ticket", "q"], "A report's name"),
        (@["start", game, "--for", "scout", "--topic", "story"], "Say what the helper should find out"),
        (@["start", "tank", "--for", "scout", "--topic", "story", "--ticket", "q"], "there is no game called"),
        (@["start", game, "--for", "scout", "--topic", "story", "--ticket", "q", "--agent", "gpt"], "there is no agent"),
        (@["start", game, "--for", "scout", "--topic", "story", "--ticket", "q", "--speed", "warp"], "--speed")]:
      let r = helper(args)
      check r.code in [1, 2]
      check words in r.output
    check spawned.len == 0 and listHelpers(root, 1000).len == 0

  test "start: not installed is a refusal that names the agent":
    installedAgents = @[]
    let r = helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "q")
    check r.code == 1 and "claude program is not installed" in r.output
    check spawned.len == 0 and listHelpers(root, 1000).len == 0

  test "start: one scout per report, and no more than the cap at once":
    check helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "q").code == 0
    let again = helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "q")
    check again.code == 1 and "already writing games/pong/reports/story.md" in again.output
    check helper("start", game, "--for", "scout", "--topic", "art", "--ticket", "q").code == 0
    check helper("start", game, "--for", "scout", "--topic", "menu", "--ticket", "q").code == 0
    let full = helper("start", game, "--for", "scout", "--topic", "levels", "--ticket", "q")
    check full.code == 1 and "3 helpers are working already" in full.output
    check spawned.len == 3
    # a helper whose line went stale is not working, so it does not count against the cap
    setNow(1000 + float(lostAfterSeconds) + 5)
    check helper("start", game, "--for", "scout", "--topic", "levels", "--ticket", "q").code == 0

  test "start: a child that cannot be started leaves a failed record, not a ghost that counts as working":
    spawnAnswer = "no such program"
    let r = helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "q")
    check r.code == 1 and "no such program" in r.output
    check readStatus(root, game, "scout").state == "failed" and liveHelpers(root, 1000).count == 0
    check readRecord(root, game, "scout").rec.outcome == "failed"

  test "list: a row for each helper, its state and what it left":
    check helper("list").output.startsWith("helpers[0]{game,id,role,topic,state,tools,left}:")
    discard helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "q")
    discard helper("start", game, "--for", "scout", "--topic", "art", "--ticket", "q")
    var done = readRecord(root, game, "scout").rec
    done.outcome = "done"
    discard writeRecord(root, done)
    discard writeStatus(root, game, "scout", StatusLine(state: "done", at: 1001, tools: 4, text: "report ready"))
    let r = helper("list")
    check r.code == 0 and r.output.startsWith("helpers[2]{game,id,role,topic,state,tools,left}:")
    check "pong,scout,scout,story,done,4,games/pong/reports/story.md" in r.output
    check "pong,scout2,scout,art,working,0,starting" in r.output
    check helper("list", "--game", game).output == r.output
    check helper("list", "--game", "tank").code == 2

  test "stop: on a working helper it asks, and the supervisor's own look ends it":
    discard helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "q")
    let r = helper("stop", game, "scout")
    check r.code == 0 and "asked helper scout (story) to stop" in r.output
    check fileExists(stopFile(root, game, "scout"))
    check readRecord(root, game, "scout").found # not forgotten: it is still working

  test "stop: on an ended helper it forgets the record and leaves the report":
    createDir(root / "games" / game / "reports")
    writeFile(root / "games" / game / "reports" / "story.md", "kept")
    discard helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "q")
    var done = readRecord(root, game, "scout").rec
    done.outcome = "failed"
    done.why = "timeout"
    discard writeRecord(root, done)
    discard writeStatus(root, game, "scout", StatusLine(state: "failed", at: 1001, tools: 4, why: "timeout", text: "x"))
    let r = helper("stop", game, "scout")
    check r.code == 0 and "forgot helper scout (story), which did not finish" in r.output
    check not readRecord(root, game, "scout").found
    check readFile(root / "games" / game / "reports" / "story.md") == "kept"

  test "stop: on a lost helper it forgets too, and an id nobody has is a plain refusal":
    discard helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "q")
    setNow(1000 + float(lostAfterSeconds) + 5)
    check "forgot helper scout" in helper("stop", game, "scout").output
    let none = helper("stop", game, "scout")
    check none.code == 1 and "there is no helper scout for pong" in none.output
    check helper("stop", game, "../scout").code == 2

  test "run: the supervisor's own entry runs the helper to its end, prints nothing, and leaves the line":
    discard helper("start", game, "--for", "scout", "--topic", "story", "--ticket", "how do sounds work?")
    script.steps = @[Step(ev: activity("Reading rules.nim"), at: 1001)]
    script.report = "# story\n"
    let r = helper("run", game, "scout")
    check r == ("", 0)
    check readStatus(root, game, "scout").state == "done" and readRecord(root, game, "scout").rec.outcome == "done"
    check helper("run", game, "scout") == ("", 1) # it already ended: nothing to supervise
    check helper("run", game, "nope") == ("", 2)
    check helper("run", game) == ("", 2)
