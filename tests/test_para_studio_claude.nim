# Tests for the Claude adapter behind `para studio`'s chat (tools/para/claudeagent.nim, with the
# interface in tools/para/agent.nim):
#
# - the event mapping, from recorded stream-json (tests/fixtures/claude-stream/: trimmed copies of
#   real runs of Claude Code 2.1.296 - a helper that started and finished, a refused tool call, a
#   refusal inside a helper, a background shell command, "not logged in") and from hand-made lines
#   that are malformed or of a type nobody knows;
# - the adapter against a stand-in `claude` (tests/fake_claude.nim, this program started again): a
#   normal turn, the session id and --resume, what is and is not on the command line, cancel
#   (with a grandchild process, killed with the tree), a non-zero exit, claude not found, not
#   signed in, a lost conversation, and that a key placed in the child's environment never comes
#   back out in any event.
#
# The real `claude` is run by hand in the PR's checklist, not here (it costs money).

import std/[unittest, os, strutils, json, tempfiles, times, sequtils]
import fake_claude
import tools/para/agent
import tools/para/claudeagent

when isMainModule:
  if getEnv("PARA_FAKE_CLAUDE") == "1":
    fakeClaudeMain()

const fixtures = currentSourcePath.parentDir / "fixtures" / "claude-stream"

proc fixture(name: string): string = fixtures / name

proc mapFile(name: string, root = "/work/repo"): tuple[events: seq[UiEvent], m: ClaudeMapper] =
  result.m = newClaudeMapper(root)
  for line in lines(fixture(name)):
    result.events.add result.m.mapLine(line)

proc ofKind(events: seq[UiEvent], k: UiKind): seq[UiEvent] =
  events.filterIt(it.kind == k)

suite "claude events: what recorded runs turn into":
  test "a helper that starts, works and finishes becomes one card; the producer's words come through":
    var (events, m) = mapFile("helper_ok.jsonl")
    check m.sawInit and m.sawResult
    check m.sessionId == sessionId
    let says = events.ofKind(ukSay)
    check says.len == 2
    check says[0].text.startsWith("Hello, director.")
    check says[1].text.startsWith("Helper is back, director.")
    let cards = events.ofKind(ukHelper)
    check cards.mapIt(it.status) == @["started", "working", "done"]
    check cards.mapIt(it.id).deduplicate.len == 1
    check cards[0].role == "helper" # a general-purpose helper whose prompt names no playbook
    check cards[0].text == "List games directory"
    check cards[1].tools == 1
    check cards[2].text == "sandbox probegame"
    # the Agent tool call itself is not an activity line (the card says it), the Read is
    let lines = events.ofKind(ukActivity)
    check lines.len == 1 and lines[0].text.startsWith("Reading ")
    check events.ofKind(ukError).len == 0 and events.ofKind(ukRefused).len == 0
    check m.finish(0, false).len == 0

  test "a refused call in the producer's own turn is told once, in plain words":
    var (events, m) = mapFile("refused_main.jsonl")
    let refusals = events.ofKind(ukRefused)
    check refusals.len == 1 # the live error and the final permission_denials are one refusal
    check refusals[0].text.startsWith("The producer wasn't allowed to run `curl -s -o /dev/null https://example.com")
    check "Ask the producer to do it a different way." in refusals[0].text
    check events.ofKind(ukError).len == 0
    check m.finish(0, false).len == 0

  test "a refusal inside a helper says a helper, and still only once, across two result events":
    var (events, m) = mapFile("refused_in_helper.jsonl")
    let refusals = events.ofKind(ukRefused)
    check refusals.len == 1
    check refusals[0].text.startsWith("A helper wasn't allowed to run `touch helper.txt`.")
    check events.ofKind(ukHelper).mapIt(it.status) == @["started", "working", "done"]
    # the producer's words in the stream come from its own turns only, not from the helper's
    check events.ofKind(ukSay).len == 2
    check m.sawResult and m.errorEmitted == false

  test "a background shell command is a line, never a helper card":
    let (events, _) = mapFile("background_shell.jsonl")
    check events.ofKind(ukHelper).len == 0
    let lines = events.ofKind(ukActivity).mapIt(it.text)
    check "Running in the background: List files in current directory" in lines

  test "not signed in is one error with the way out, not a chat bubble":
    var (events, m) = mapFile("not_signed_in.jsonl")
    check events.ofKind(ukSay).len == 0
    let errs = events.ofKind(ukError)
    check errs.len == 1
    check errs[0].code == "not-signed-in"
    check "type claude" in errs[0].text and "API key" in errs[0].text
    check "never touches your login" in errs[0].text
    check m.finish(1, false).len == 0 # already told

  test "malformed lines, unknown event types and odd shapes are skipped, never fatal":
    var m = newClaudeMapper("/work/repo")
    var events: seq[UiEvent]
    for line in ["{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"" & sessionId & "\"}",
                 "", "   ", "this is not json", "{\"type\":\"mystery\",\"x\":1}", "[1,2,3]", "\"just a string\"",
                 "{\"type\":\"assistant\",\"message\":{\"content\":\"oops\"}}", "{\"type\":\"assist",
                 "{\"type\":\"system\",\"subtype\":\"task_started\"}",
                 "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"still here\"}]},\"parent_tool_use_id\":null}"]:
      events.add m.mapLine(line)
    check events.mapIt(it.text) == @["still here"]
    check m.shapeProblems == 2
    check m.stray.len == 4 # not json, [1,2,3], the string, the half line
    let tail = m.finish(0, false)
    check tail.len == 1 and tail[0].kind == ukNotice and tail[0].code == "partial"

  test "output that is not stream-json at all says the tool changed, a crash says it stopped":
    var m = newClaudeMapper("")
    discard m.mapLine("Welcome to a different program")
    let changed = m.finish(0, false)
    check changed.len == 1 and changed[0].code == "tool-changed"
    var c = newClaudeMapper("")
    discard c.mapLine("claude: something broke")
    let crashed = c.finish(3, false)
    check crashed.len == 1 and crashed[0].code == "crashed"
    check "exit code 3" in crashed[0].text
    check crashed[0].detail == "claude: something broke"
    var gone = newClaudeMapper("")
    check gone.finish(143, true).len == 0 # a stop we asked for is not a crash

  test "the folder-not-trusted warning on stderr becomes one note":
    var m = newClaudeMapper("")
    let first = m.mapLine("Ignoring 2 permissions.allow entries from .claude/settings.json: this workspace has not been trusted. Run Claude Code interactively here once")
    check first.len == 1 and first[0].code == "untrusted-folder"
    check "answer Yes" in first[0].text
    check m.mapLine("Ignoring 2 permissions.allow entries from .claude/settings.json: this workspace has not been trusted.").len == 0

  test "refusal wording seen in real runs is recognised, and a command that merely failed is not":
    for refused in ["Permission to use Bash has been denied. IMPORTANT: You *may* attempt",
                    "This command requires approval",
                    "This Bash command contains multiple operations. The following part requires approval: tmp/para save --list",
                    "A variable in this command can't be checked before it runs",
                    "Claude requested permissions to use Bash, but you haven't granted it yet."]:
      check looksRefused(refused)
    for ran in ["ls: cannot open directory 'x': Permission denied", "error: build failed\nexit code 1", "", "All 12 tests passed"]:
      check not looksRefused(ran)

  test "errors are classified from claude's own words":
    check classifyError("authentication_failed", "").code == "not-signed-in"
    check classifyError("", "Not logged in · Please run /login").code == "not-signed-in"
    check classifyError("", "Invalid API key").code == "not-signed-in"
    check classifyError("billing_error", "").code == "no-credit"
    check classifyError("", "Credit balance is too low").code == "no-credit"
    check classifyError("rate_limit", "").code == "busy"
    check classifyError("", "No conversation found with session ID: x").code == "session-missing"
    check classifyError("", "something odd").code == "agent-error"

  test "helper roles come from the playbook the prompt names":
    check helperRole("general-purpose", "x", "Read .agents/skills/builder/SKILL.md and do it") == "builder"
    check helperRole("general-purpose", "x", "read .agents\\skills\\checker\\SKILL.md") == "checker"
    check helperRole("general-purpose", "Find out how X works", "see .agents/skills/scout/SKILL.md") == "scout"
    check helperRole("general-purpose", "x", ".agents/skills/art/SKILL.md") == "art"
    check helperRole("explorer", "x", "no playbook") == "explorer"
    check helperRole("a<b>c", "x", "") == "helper"
    check helperRole("", "", "") == "helper"

  test "tool calls become light lines with paths relative to the game folder":
    var m = newClaudeMapper("/work/repo")
    let evs = m.mapLine("""{"type":"assistant","message":{"content":[
      {"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/work/repo/games/pong/data.nim"}},
      {"type":"tool_use","id":"t2","name":"Bash","input":{"command":"tmp/para check\n  --game pong"}},
      {"type":"tool_use","id":"t3","name":"TodoWrite","input":{}}]},"parent_tool_use_id":null}""".replace("\n", " "))
    check evs.mapIt(it.text) == @["Changing games/pong/data.nim", "Running: tmp/para check --game pong"]

  test "only a well-formed session id can reach the command line":
    check validSession(sessionId) == sessionId
    for bad in ["", "abc", sessionId & "0", "11111111-2222-4333-8444-55555555555;", "$(reboot)", "--dangerously-skip-permissions",
                "1111111122224333844455555555555555!!", "../../etc/passwd/x/y/z/a/b/c/d/e/f/g/h/i/j"]:
      check validSession(bad) == ""
    check validSessionToken("abc-DEF_123") == "abc-DEF_123"
    check validSessionToken("a b") == "" and validSessionToken("a/b") == "" and validSessionToken("") == ""

  test "a .cmd shim is only run with arguments that cmd.exe cannot read as more":
    check isShim("C:\\Users\\a\\AppData\\Roaming\\npm\\claude.cmd") and isShim("x.BAT") and not isShim("claude.exe")
    check shimSafe(@["-p", "--output-format", "stream-json", "--setting-sources", "project,local", "--resume", sessionId])
    for bad in ["a&b", "a|b", "\"x\"", "a^b", "%PATH%", "a b", "a\nb", "$(x)", "a;b", "a`b"]:
      check not shimSafe(@["-p", bad])

suite "secrets stay out of anything shown":
  test "redactSecrets removes env-held secrets, sk- keys and bearer tokens, and leaves plain text alone":
    putEnv("ANTHROPIC_API_KEY", "fake-key-value-0123456789")
    putEnv("SOME_AUTH_TOKEN", "tok_abcdef123456")
    defer:
      delEnv("ANTHROPIC_API_KEY")
      delEnv("SOME_AUTH_TOKEN")
    let shown = redactSecrets("a fake-key-value-0123456789 b sk-ant-api03-abcDEF_123-xyz c Bearer abc.def-ghi d tok_abcdef123456 e")
    check "fake-key-value" notin shown and "sk-ant" notin shown and "abc.def" notin shown and "tok_abcdef" notin shown
    check shown.count("[hidden]") == 4
    check redactSecrets("Fixed the ship; ask-me-later is fine, task-3 too") == "Fixed the ship; ask-me-later is fine, task-3 too"

# --- the adapter against the stand-in -------------------------------------------------

var scratch: string
var logPath: string
let startDir = getCurrentDir() # a turn leaves this process in the folder it ran in; go back before deleting it

proc begin(mode: string, fixtureName = "helper_ok.jsonl") =
  scratch = createTempDir("para_claude_", "")
  logPath = scratch / "fake.log"
  putEnv("PARA_FAKE_CLAUDE", "1")
  putEnv("FAKE_CLAUDE_MODE", mode)
  putEnv("FAKE_CLAUDE_FIXTURE", fixture(fixtureName))
  putEnv("FAKE_CLAUDE_LOG", logPath)

proc finish() =
  for k in ["PARA_FAKE_CLAUDE", "FAKE_CLAUDE_MODE", "FAKE_CLAUDE_FIXTURE", "FAKE_CLAUDE_LOG", "FAKE_CLAUDE_PIDFILE", "ANTHROPIC_API_KEY"]:
    delEnv(k)
  setCurrentDir(startDir)
  removeDir(scratch)

type Collected = ref object
  events: seq[UiEvent]
  sessions: seq[string]

proc fakeAdapter(): AgentAdapter = newClaudeAdapter(getAppFilename())

proc runTurn(a: AgentAdapter, text: string, session = "", ctl: ptr TurnControl = nil): tuple[res: TurnResult, got: Collected] =
  let c = if ctl.isNil: newTurnControl() else: ctl
  var got = Collected()
  let req = TurnRequest(text: text, sessionId: session, workDir: scratch,
                        onSession: proc (id: string) {.closure, gcsafe.} = {.cast(gcsafe).}: got.sessions.add id)
  let res = a.runTurn(a, req, c, proc (ev: UiEvent) {.closure, gcsafe.} = {.cast(gcsafe).}: got.events.add ev)
  (res, got)

proc logged(): seq[JsonNode] =
  for line in lines(logPath): result.add parseJson(line)

suite "claude adapter: a turn against a stand-in claude":
  teardown: finish()

  test "a normal turn: events, the session id, and exactly what is on the command line":
    begin("normal")
    let message = "make it red; $(reboot) \"quoted\" & `x` | y\nsecond line ünïcode"
    let (res, got) = runTurn(fakeAdapter(), message)
    check res.ok and not res.cancelled and res.exitCode == 0
    check res.sessionId == sessionId
    check got.sessions == @[sessionId]
    check got.events.ofKind(ukSay).len == 2
    check got.events.ofKind(ukHelper).len == 3
    let calls = logged()
    check calls.len == 1
    let args = calls[0]["args"].getElems.mapIt(it.getStr)
    check args == @["-p", "--output-format", "stream-json", "--verbose", "--setting-sources", "project,local"]
    for a in args:
      check message notin a and "--bare" != a and "--dangerously-skip-permissions" != a and "--permission-mode" != a
    check calls[0]["stdin"].getStr == message # the message travels on standard input, whole
    check calls[0]["ui"].getStr == "studio"
    check calls[0]["cwd"].getStr.expandFilename == scratch.expandFilename

  test "a later turn resumes the session; a session id that is not a UUID is dropped":
    begin("normal")
    let a = fakeAdapter()
    discard runTurn(a, "one", sessionId)
    discard runTurn(a, "two", "x; rm -rf /")
    let calls = logged()
    check calls[0]["args"].getElems.mapIt(it.getStr)[^2 ..< ^0] == @["--resume", sessionId]
    check "--resume" notin calls[1]["args"].getElems.mapIt(it.getStr)

  test "the rest of the environment passes through unchanged":
    begin("normal")
    putEnv("PARA_TEST_PASSTHROUGH", "kept")
    putEnv("PARALOOP_UI", "terminal") # the studio sets its own value
    defer:
      delEnv("PARA_TEST_PASSTHROUGH")
      delEnv("PARALOOP_UI")
    discard runTurn(fakeAdapter(), "hi")
    check logged()[0]["ui"].getStr == "studio"
    check getEnv("PARALOOP_UI") == "terminal" # our own environment is untouched

  test "a non-zero exit ends the turn with a plain message":
    begin("crash")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check not res.ok and res.exitCode == 3
    let errs = got.events.ofKind(ukError)
    check errs.len == 1 and errs[0].code == "crashed"
    check "exit code 3" in errs[0].text
    check errs[0].detail == "claude: something broke"

  test "not signed in":
    begin("normal", "not_signed_in.jsonl")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check not res.ok
    check got.events.ofKind(ukError).mapIt(it.code) == @["not-signed-in"]

  test "malformed lines and unknown events in the stream do not stop the turn":
    begin("badlines")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check res.ok
    check got.events.ofKind(ukSay).len == 2
    check got.events.ofKind(ukNotice).mapIt(it.code) == @["partial"]

  test "output that is not stream-json says the tool changed":
    begin("garbage")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check not res.ok
    check got.events.ofKind(ukError).mapIt(it.code) == @["tool-changed"]

  test "the untrusted-folder warning is shown once as a note and the turn goes on":
    begin("untrusted")
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check res.ok
    check got.events.ofKind(ukNotice).mapIt(it.code) == @["untrusted-folder"]

  test "a lost conversation starts a fresh one once, and says so":
    begin("resume-missing")
    let (res, got) = runTurn(fakeAdapter(), "hi", sessionId)
    check res.ok
    check got.events.ofKind(ukNotice).mapIt(it.code) == @["fresh-start"]
    check got.events.ofKind(ukError).len == 0
    check got.events.ofKind(ukSay).len == 2
    let calls = logged()
    check calls.len == 2
    check "--resume" in calls[0]["args"].getElems.mapIt(it.getStr)
    check "--resume" notin calls[1]["args"].getElems.mapIt(it.getStr)
    check res.sessionId == sessionId

  test "claude not on the path: plain install help, nothing run":
    begin("normal")
    let oldPath = getEnv("PATH")
    putEnv("PATH", scratch) # a folder with no claude in it
    defer: putEnv("PATH", oldPath)
    let a = newClaudeAdapter() # looks claude up on PATH
    let info = a.describe(a)
    check not info.installed and info.version == ""
    check "Anthropic's setup page" in info.note and "Windows" in info.note
    check info.url == "https://code.claude.com/docs/en/setup"
    let (res, got) = runTurn(a, "hi")
    check not res.ok
    let errs = got.events.ofKind(ukError)
    check errs.len == 1 and errs[0].code == "not-installed" and errs[0].url == info.url
    check not fileExists(logPath)

  test "a program that cannot be started is a plain error":
    begin("normal")
    let (res, got) = runTurn(newClaudeAdapter(scratch / "no-such-claude"), "hi")
    check not res.ok
    check got.events.ofKind(ukError).mapIt(it.code) == @["cannot-start"]

  test "the version is read from claude --version, and a version that cannot be read is a note":
    begin("normal")
    let info = fakeAdapter().describe(fakeAdapter())
    check info.installed and info.version == "2.1.296" and info.note == ""
    putEnv("FAKE_CLAUDE_MODE", "noversion")
    let odd = fakeAdapter().describe(fakeAdapter())
    check odd.installed and odd.version == "" and "couldn't read Claude's version" in odd.note

  test "a key in the child's environment never comes back out in any event":
    begin("secret")
    let key = "sk-ant-FAKEKEY-0123456789abcdef"
    putEnv("ANTHROPIC_API_KEY", key)
    let (res, got) = runTurn(fakeAdapter(), "hi")
    check not res.ok
    check got.events.len > 0
    for ev in got.events:
      for field in [ev.text, ev.detail, ev.id, ev.role, ev.code, ev.url]:
        check key notin field and "0123456789abcdef" notin field
    check got.events.ofKind(ukError).len == 1

suite "claude adapter: stopping a turn":
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

  test "cancel ends the child and everything it started, and the turn reports it was cancelled":
    when defined(windows):
      skip() # the tree kill (taskkill /T) is not exercised on Windows here; see the PR's checklist
    else:
      begin("hang")
      let pidFile = scratch / "pids.txt"
      putEnv("FAKE_CLAUDE_PIDFILE", pidFile)
      var done = false
      var cancelled = false
      let ctl = newTurnControl()
      var job = Job(adapter: fakeAdapter(), ctl: ctl, done: addr done, cancelled: addr cancelled)
      gotEvents = @[]
      createThread(jobThread, jobMain, addr job)
      let until = epochTime() + 20
      while not fileExists(pidFile) and epochTime() < until: sleep(50)
      check fileExists(pidFile)
      let pids = readFile(pidFile).split(' ').mapIt(parseInt(it))
      let grandchild = pids[0]
      let child = pids[1]
      check alive(child) and alive(grandchild)
      let t0 = epochTime()
      ctl.cancel("stop")
      joinThread(jobThread)
      check epochTime() - t0 < 10
      check done and cancelled
      check ctl.isCancelled and ctl.cancelReason == "stop"
      var gone = false
      for _ in 0 ..< 60:
        if not alive(child) and not alive(grandchild):
          gone = true
          break
        sleep(50)
      check gone
      check gotEvents.ofKind(ukError).len == 0 # a stop we asked for is not an error
      freeTurnControl(ctl)

  test "a cancel that arrives before the child is attached still ends it":
    when defined(windows):
      skip()
    else:
      begin("hang")
      putEnv("FAKE_CLAUDE_PIDFILE", scratch / "pids2.txt")
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
