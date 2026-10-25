# Tests for the producer's chat inside `para studio` (tools/para/studiochat.nim and its routes in
# studioapi.nim), through the real server on a loopback port and the stand-in `claude`
# (tests/fake_claude.nim). The adapter's own behaviour is test_para_studio_claude.nim; what is
# pinned here:
#
# - every new route keeps the B1 checks (token, Host, Origin, JSON, size), and nothing reaches the
#   agent unless a message is sent: opening the page, polling and every refused request start no
#   turn;
# - a turn end to end: the friend's line, the producer's words, helper cards, the session id kept in
#   tmp/ with the chat's title and times (and nothing else in that file), the next turn resuming it,
#   games kept apart (the list of past chats itself is test_para_studio_chats.nim);
# - one turn at a time (Check and Save wait for it, and it for them), Stop, the time limit, closing
#   the studio, and "fresh conversation";
# - what the page shows can never run: the server only sends JSON, and the page script has no way
#   to put text in as HTML;
# - a key in the environment never appears in anything the server returns.

import std/[unittest, os, strutils, json, times, sequtils, tables, algorithm]
import fake_claude
import fake_codex
import studio_support
import tools/para/agent
import tools/para/agents
import tools/para/studiochat
import tools/para/studiohttp
import tools/para/studioapi
import tools/para/lanecmd

when isMainModule:
  # one program stands in for both agents: codex is started as `app-server ...`, claude as `-p ...`
  if getEnv("PARA_FAKE_CODEX") == "1" and paramCount() > 0 and paramStr(1) == "app-server":
    fakeCodexMain()
  elif getEnv("PARA_FAKE_CLAUDE") == "1":
    fakeClaudeMain()

const
  fixtures = currentSourcePath.parentDir / "fixtures" / "claude-stream"

let startDir = getCurrentDir()
var root: string
var running: Running
var logPath: string

proc jsonOf(r: Reply): JsonNode = parseJson(r.body)

proc post(r: Running, path: string, body: JsonNode): Reply =
  r.request("POST", path, body = $body)

proc newClaudeAdapterFor(exe: string): AgentAdapter = adapterNamed("claude", exe)

proc begin(mode = "normal", fixtureName = "helper_ok.jsonl", games: seq[string] = @["pong"], turnSeconds = defaultTurnSeconds) =
  root = newGameRepo(games)
  logPath = root / "tmp" / "fake.log"
  createDir(root / "tmp")
  putEnv("PARA_FAKE_CLAUDE", "1")
  putEnv("FAKE_CLAUDE_MODE", mode)
  putEnv("FAKE_CLAUDE_FIXTURE", if fixtureName.isAbsolute: fixtureName else: fixtures / fixtureName)
  putEnv("FAKE_CLAUDE_LOG", logPath)
  running = startStudio(root, getAppFilename(), "", newClaudeAdapterFor(getAppFilename()), turnSeconds)

proc finish() =
  running.stop()
  for k in ["PARA_FAKE_CLAUDE", "FAKE_CLAUDE_MODE", "FAKE_CLAUDE_FIXTURE", "FAKE_CLAUDE_LOG", "FAKE_CLAUDE_PIDFILE", "ANTHROPIC_API_KEY"]:
    delEnv(k)
  setCurrentDir(startDir) # a turn leaves this process in the repo it ran in
  removeDir(root)

proc calls(): seq[JsonNode] =
  if not fileExists(logPath): return
  for line in lines(logPath): result.add parseJson(line)

type Chat = object
  events: seq[JsonNode]
  next: int
  running: bool

proc poll(r: Running, c: var Chat, game = "pong") =
  let reply = r.request("GET", "/api/chat?game=" & game & "&since=" & $c.next)
  doAssert reply.status == 200, reply.raw
  let d = jsonOf(reply)
  for e in d["events"]: c.events.add e
  c.next = d["next"].getInt
  c.running = d["running"].getBool

proc kinds(c: Chat): seq[string] = c.events.mapIt(it["kind"].getStr)

proc waitFor(r: Running, c: var Chat, what: proc (c: Chat): bool, seconds = 30, game = "pong") =
  let until = epochTime() + seconds.float
  while epochTime() < until:
    r.poll(c, game)
    if what(c): return
    sleep(50)
  doAssert false, "waited " & $seconds & "s; chat so far: " & $c.kinds

proc finished(c: Chat): bool = "done" in c.kinds

proc send(r: Running, text: string, game = "pong"): Reply =
  r.post("/api/chat/send", %*{"game": game, "text": text})

proc alive(pid: int): bool =
  when defined(linux):
    try:
      let stat = readFile("/proc/" & $pid & "/stat")
      return stat[stat.rfind(')') + 2] notin {'Z', 'X'}
    except IOError, OSError:
      return false
  else:
    return false

suite "para studio chat: the new routes keep every B1 check":
  setup: begin()
  teardown: finish()

  const getRoutes = ["/api/agent", "/api/chat?game=pong&since=0"]
  const postRoutes = ["/api/chat/send", "/api/chat/stop", "/api/chat/new", "/api/agent/pick"]

  test "no token and a wrong token are a 403, and nothing is started":
    for path in getRoutes:
      check running.request("GET", path, withToken = false).status == 403
      check running.request("GET", path, headers = @[("X-Studio-Token", "nope")], withToken = false).status == 403
    for path in postRoutes:
      check running.request("POST", path, body = """{"game":"pong","text":"hi"}""", withToken = false).status == 403
      check running.request("POST", path, body = """{"game":"pong","text":"hi"}""", headers = @[("X-Studio-Token", "nope")], withToken = false).status == 403
    check calls().len == 0

  test "a foreign Host (DNS rebinding) is refused":
    for path in getRoutes:
      check running.request("GET", path, host = "evil.example:80").status == 403
    check running.request("POST", "/api/chat/send", body = """{"game":"pong","text":"hi"}""", host = "evil.example:" & $running.srv.port).status == 403
    check calls().len == 0

  test "a cross-site POST, a non-JSON POST, a huge POST and other methods are refused":
    let body = """{"game":"pong","text":"hi"}"""
    check running.request("POST", "/api/chat/send", body = body, headers = @[("Origin", "https://evil.example")]).status == 403
    check running.request("POST", "/api/chat/send", body = body, headers = @[("Sec-Fetch-Site", "cross-site")]).status == 403
    check running.request("POST", "/api/chat/send", body = body, headers = @[("Content-Type", "text/plain")], jsonBody = false).status == 415
    check running.request("POST", "/api/chat/send", body = "{\"game\":\"pong\",\"text\":\"" & "a".repeat(40_000) & "\"}").status == 413
    check running.request("PUT", "/api/chat/send", body = body).status == 405
    check running.request("GET", "/api/chat/send").status == 404 # send is POST only
    check running.request("GET", "/api/chat/../state").status == 404
    check calls().len == 0

  test "opening the page, the state, the agent and the chat start no turn":
    check running.request("GET", "/?token=" & running.srv.token, withToken = false).status == 200
    check running.request("GET", "/api/state").status == 200
    check running.request("GET", "/api/agent").status == 200
    check running.request("GET", "/api/agent?game=pong").status == 200
    var c: Chat
    running.poll(c)
    check c.events.len == 0 and not c.running
    check calls().len == 0

  test "the agent route says who pays and what the time limit is, and never a key":
    putEnv("ANTHROPIC_API_KEY", "sk-ant-NOT-A-REAL-KEY-0123456789")
    let a = jsonOf(running.request("GET", "/api/agent"))
    check a["installed"].getBool and a["version"].getStr == "2.1.296"
    check a["label"].getStr == "Claude"
    check "never sees or keeps your login" in a["cost"].getStr
    check "your own Claude plan or API credit" in a["cost"].getStr
    check a["timeoutMinutes"].getInt == 60
    check "NOT-A-REAL-KEY" notin $a

suite "para studio chat: a turn end to end":
  teardown: finish()

  test "the friend's line, the producer's words, a helper card, then done":
    begin()
    let started = running.send("Hello, producer!")
    check started.status == 200
    var c: Chat
    running.waitFor(c, finished)
    let ks = c.kinds
    check ks[0] == "you" and c.events[0]["text"].getStr == "Hello, producer!"
    check "say" in ks and "helper" in ks and "activity" in ks
    check ks[^1] == "done" and c.events[^1]["text"].getStr == "ok"
    let says = c.events.filterIt(it["kind"].getStr == "say").mapIt(it["text"].getStr)
    check says[0].startsWith("Hello, director.")
    let cards = c.events.filterIt(it["kind"].getStr == "helper")
    check cards.mapIt(it["status"].getStr) == @["started", "working", "done"]
    check cards[0]["role"].getStr == "helper" and cards[0]["id"].getStr.len > 0
    check not c.running
    # seen once: polling again from the end returns nothing new
    var again = Chat(next: c.next)
    running.poll(again)
    check again.events.len == 0
    # the agent ran in the repo root, got the message on stdin and PARALOOP_UI=studio
    let log = calls()
    check log.len == 1
    check log[0]["stdin"].getStr == "Hello, producer!"
    check log[0]["ui"].getStr == "studio"
    check log[0]["cwd"].getStr.expandFilename == root.expandFilename
    check "Hello, producer!" notin $log[0]["args"]

  test "the session id is kept per game in tmp/, with the chat's title and times only, and the next turn resumes it":
    begin()
    var c: Chat
    check running.send("one\nand a second line that is not kept in full because titles are short").status == 200
    running.waitFor(c, finished)
    let file = root / "tmp" / "studio" / "chats-pong-claude.json"
    check fileExists(file)
    let saved = parseJson(readFile(file))
    check saved["chats"].len == 1
    let chat = saved["chats"][0]
    check toSeq(chat.keys) == @["id", "title", "started", "updated", "session"]
    check chat["session"].getStr == sessionId
    check chat["title"].getStr == "one and a second line that is not kept in full because title…"
    check "titles are short" notin readFile(file) # only the start of the first message
    check readSession(root, "pong", "claude") == sessionId
    check readSession(root, "pong", "codex") == "" # another agent's conversation is its own
    # a second turn, from a fresh page (a new Chat view) resumes the same conversation
    check running.send("two").status == 200
    var d: Chat
    running.waitFor(d, proc (c: Chat): bool = c.kinds.count("done") >= 2)
    let args = calls()[1]["args"].getElems.mapIt(it.getStr)
    check args[^2 .. ^1] == @["--resume", sessionId]
    check "--resume" notin calls()[0]["args"].getElems.mapIt(it.getStr)

  test "a session file with anything but an id in it is ignored":
    begin() # the studio reads the chats the first time a game's chat is used, so this is in time
    createDir(root / "tmp" / "studio")
    writeFile(root / "tmp" / "studio" / "session-pong-claude.id", "--dangerously-skip-permissions")
    check readSession(root, "pong", "claude") == ""
    var c: Chat
    check running.send("hi").status == 200
    running.waitFor(c, finished)
    check "--resume" notin calls()[0]["args"].getElems.mapIt(it.getStr)
    check readSession(root, "pong", "claude") == sessionId # replaced by the real one
    # the same in the chats file: a session id that could never be one is dropped
    running.stop()
    let file = root / "tmp" / "studio" / "chats-pong-claude.json"
    writeFile(file, readFile(file).replace(sessionId, "--dangerously-skip-permissions"))
    running = startStudio(root, getAppFilename(), "", newClaudeAdapterFor(getAppFilename()))
    var d = Chat(next: c.next)
    check running.send("again").status == 200
    running.waitFor(d, finished)
    check "--resume" notin calls()[1]["args"].getElems.mapIt(it.getStr)

  test "two games keep separate chats and separate sessions":
    begin(games = @["pong", "tetris"])
    var c: Chat
    check running.send("for pong", "pong").status == 200
    running.waitFor(c, finished)
    var t: Chat
    check running.send("for tetris", "tetris").status == 200
    running.waitFor(t, finished, game = "tetris")
    check c.events[0]["text"].getStr == "for pong" and t.events[0]["text"].getStr == "for tetris"
    var pongAgain: Chat
    running.poll(pongAgain, "pong")
    check pongAgain.events.allIt(it["text"].getStr != "for tetris")
    check readSession(root, "pong", "claude") == sessionId and readSession(root, "tetris", "claude") == sessionId
    check fileExists(root / "tmp" / "studio" / "chats-pong-claude.json") and fileExists(root / "tmp" / "studio" / "chats-tetris-claude.json")
    check running.request("GET", "/api/chat?game=nope&since=0").status == 404
    check running.send("x", "nope").status == 404
    check running.request("GET", "/api/chat?since=0").status == 400 # two games: which one?

  test "a new chat starts a new conversation with an empty page, and keeps the earlier one":
    begin()
    var c: Chat
    check running.send("hi").status == 200
    running.waitFor(c, finished)
    check readSession(root, "pong", "claude") == sessionId
    check running.post("/api/chat/new", %*{"game": "pong"}).status == 200
    check readSession(root, "pong", "claude") == "" # the next message is a new conversation
    var d: Chat
    running.poll(d)
    check d.events.len == 0
    check running.send("hello again").status == 200
    running.waitFor(d, finished)
    check "--resume" notin calls()[1]["args"].getElems.mapIt(it.getStr)
    let list = jsonOf(running.request("GET", "/api/chats?game=pong"))["chats"]
    check list.getElems.mapIt(it["title"].getStr) == @["hello again", "hi"]

  test "messages that cannot be sent are refused in plain words, without starting anything":
    begin()
    for text in ["", "   \n ", "a".repeat(maxMessageChars + 1), "has a \0 nul", "has a \x07 bell"]:
      let r = running.send(text)
      check r.status == 400
      check jsonOf(r)["message"].getStr.len > 0
    check running.post("/api/chat/send", %*{"game": "pong", "text": 42}).status == 400
    check running.post("/api/chat/send", %*[1, 2]).status == 400
    check running.request("POST", "/api/chat/send", body = "not json").status == 400
    check calls().len == 0
    # newlines, tabs and unicode are fine
    check running.send("two lines\n\tand ünïcode 🎮").status == 200
    var c: Chat
    running.waitFor(c, finished)
    check calls()[0]["stdin"].getStr == "two lines\n\tand ünïcode 🎮"

type RaceCall = tuple[port: int, token: string, slot: int, path, body: string]

var statuses: array[2, int]

proc raceMain(c: RaceCall) {.thread.} =
  let lines = ["POST " & c.path & " HTTP/1.1", "Host: 127.0.0.1:" & $c.port, "X-Studio-Token: " & c.token,
               "Content-Type: application/json", "Content-Length: " & $c.body.len]
  let reply = rawRequest(c.port, lines.join("\r\n") & "\r\n\r\n" & c.body)
  {.cast(gcsafe).}:
    statuses[c.slot] = reply.status

suite "para studio chat: two agents, each with its own conversation":
  const codexFixtures = currentSourcePath.parentDir / "fixtures" / "codex-appserver"
  var codexLog: string
  let codexThread = "01a166dd-e2b4-7ce0-97ad-2a5dada08c07"

  var turnsDone = 0

  proc beginBoth(defaultName = "claude", games: seq[string] = @["pong"]) =
    ## Both stand-ins are this test program; `defaultName` is the one the studio starts with.
    turnsDone = 0
    root = newGameRepo(games)
    logPath = root / "tmp" / "fake.log"
    codexLog = root / "tmp" / "fake-codex.log"
    createDir(root / "tmp")
    putEnv("PARA_FAKE_CLAUDE", "1")
    putEnv("FAKE_CLAUDE_MODE", "normal")
    putEnv("FAKE_CLAUDE_FIXTURE", fixtures / "helper_ok.jsonl")
    putEnv("FAKE_CLAUDE_LOG", logPath)
    putEnv("PARA_FAKE_CODEX", "1")
    putEnv("FAKE_CODEX_MODE", "normal")
    putEnv("FAKE_CODEX_FIXTURE", "turn_ok.jsonl")
    putEnv("FAKE_CODEX_LOG", codexLog)
    let claude = adapterNamed("claude", getAppFilename())
    let codex = adapterNamed("codex", getAppFilename())
    running = if defaultName == "codex": startStudio(root, getAppFilename(), "", codex, others = @[claude])
              else: startStudio(root, getAppFilename(), "", claude, others = @[codex])

  proc codexCalls(): seq[JsonNode] =
    if not fileExists(codexLog): return
    for line in lines(codexLog): result.add parseJson(line)

  proc pick(agent: string, game = "pong"): Reply =
    running.post("/api/agent/pick", %*{"game": game, "agent": agent})

  proc currentAgent(game = "pong"): string =
    jsonOf(running.request("GET", "/api/agent?game=" & game))["current"].getStr

  proc turn(text: string) =
    ## One whole turn: waits for its "done", whichever producer's chat the page shows.
    var c: Chat
    running.poll(c)
    c.events = @[]
    check running.send(text).status == 200
    inc turnsDone
    running.waitFor(c, finished)

  teardown:
    finish()
    for k in ["PARA_FAKE_CODEX", "FAKE_CODEX_MODE", "FAKE_CODEX_FIXTURE", "FAKE_CODEX_LOG"]: delEnv(k)

  test "the agent route lists both producers, the default first, with who pays and what to expect":
    beginBoth()
    let a = jsonOf(running.request("GET", "/api/agent?game=pong"))
    check a["current"].getStr == "claude" and a["name"].getStr == "claude" # the first fields are the current agent's
    check a["agents"].mapIt(it["name"].getStr) == @["claude", "codex"]
    check a["agents"].mapIt(it["label"].getStr) == @["Claude", "Codex"]
    let codex = a["agents"][1]
    check "ChatGPT plan" in codex["cost"].getStr and "never sees or keeps your login" in codex["cost"].getStr
    check "Plus" in codex["about"].getStr and "making pictures is verified" in codex["about"].getStr
    check "Claude stays the default" in codex["about"].getStr
    check calls().len == 0 and codexCalls().len == 0 # looking never starts a turn

  test "a studio whose default producer is Codex uses it for a game nobody has picked for":
    beginBoth("codex")
    check currentAgent() == "codex"
    let a = jsonOf(running.request("GET", "/api/agent"))
    check a["agents"].mapIt(it["name"].getStr) == @["codex", "claude"] and a["name"].getStr == "codex"
    turn("hello")
    check calls().len == 0 and codexCalls().len > 0

  test "picking switches the producer from the next message on, remembered per game":
    beginBoth(games = @["pong", "tetris"])
    check currentAgent() == "claude"
    let r = pick("codex")
    check r.status == 200 and jsonOf(r)["current"].getStr == "codex"
    check currentAgent("pong") == "codex" and currentAgent("tetris") == "claude"
    check readFile(root / "tmp" / "studio" / "agent-pong.txt") == "codex"
    check not fileExists(root / "tmp" / "studio" / "agent-tetris.txt")
    var c: Chat
    running.poll(c)
    check c.events.len == 1 and c.events[0]["kind"].getStr == "notice" and c.events[0]["code"].getStr == "agent-picked"
    check "Codex is the producer" in c.events[0]["text"].getStr and "PLAN.md" in c.events[0]["text"].getStr
    check pick("codex").status == 200 # picking the same one again says nothing more
    running.poll(c)
    check c.events.len == 1
    check calls().len == 0 and codexCalls().len == 0
    # a studio started again on the same folder remembers it
    running.stop()
    running = startStudio(root, getAppFilename(), "", adapterNamed("claude", getAppFilename()), others = @[adapterNamed("codex", getAppFilename())])
    check currentAgent() == "codex"

  test "a pick that cannot be made is refused in plain words":
    beginBoth()
    for (body, status) in [(%*{"game": "pong", "agent": "gemini"}, 400), (%*{"game": "pong"}, 400), (%*{"game": "pong", "agent": "../etc"}, 400),
                           (%*{"game": "nope", "agent": "codex"}, 404)]:
      let r = running.post("/api/agent/pick", body)
      check r.status == status
      check jsonOf(r)["error"].getStr.len > 0
    check currentAgent() == "claude"
    check not fileExists(root / "tmp" / "studio" / "agent-pong.txt")

  test "each agent keeps its own conversation, and switching back resumes it":
    beginBoth()
    turn("one with claude")
    check readSession(root, "pong", "claude") == sessionId
    check pick("codex").status == 200
    turn("two with codex")
    check readSession(root, "pong", "codex") == codexThread
    check readSession(root, "pong", "claude") == sessionId # untouched
    # the codex turn started a new thread and never saw claude's id, and claude was not run again
    let first = codexCalls().filterIt(it.hasKey("method")).mapIt(it["method"].getStr)
    check "thread/start" in first and "thread/resume" notin first
    check codexCalls()[0]["args"].getElems.mapIt(it.getStr) == @["app-server", "--listen", "stdio://"]
    check calls().len == 1
    check pick("claude").status == 200
    turn("three with claude")
    check calls().len == 2
    check calls()[1]["args"].getElems.mapIt(it.getStr)[^2 .. ^1] == @["--resume", sessionId] # not codex's id
    check pick("codex").status == 200
    turn("four with codex")
    let methods = codexCalls().filterIt(it.hasKey("method")).mapIt(it["method"].getStr)
    check methods.count("thread/start") == 1 and methods.count("thread/resume") == 1
    let resume = codexCalls().filterIt(it{"method"}.getStr == "thread/resume")[0]
    check resume["params"]["threadId"].getStr == codexThread

  test "a pick is refused while a turn runs":
    beginBoth()
    putEnv("FAKE_CLAUDE_MODE", "hang")
    putEnv("FAKE_CLAUDE_PIDFILE", root / "tmp" / "pids.txt")
    check running.send("go").status == 200
    let until = epochTime() + 20
    while not fileExists(root / "tmp" / "pids.txt") and epochTime() < until: sleep(50)
    let r = pick("codex")
    check r.status == 409 and jsonOf(r)["error"].getStr == "busy"
    check currentAgent() == "claude"
    check running.post("/api/chat/stop", %*{}).status == 200
    var c: Chat
    running.waitFor(c, finished, 20)

  test "a new chat is for the producer the game talks to now; the other one's chat stays open":
    beginBoth()
    turn("one")
    check pick("codex").status == 200
    turn("two")
    check running.post("/api/chat/new", %*{"game": "pong"}).status == 200
    check readSession(root, "pong", "codex") == "" and readSession(root, "pong", "claude") == sessionId
    check currentAgent() == "codex"
    # each producer lists its own chats
    check jsonOf(running.request("GET", "/api/chats?game=pong"))["chats"].getElems.mapIt(it["title"].getStr) == @["two"]
    check pick("claude").status == 200
    check jsonOf(running.request("GET", "/api/chats?game=pong"))["chats"].getElems.mapIt(it["title"].getStr) == @["one"]

  test "the one conversation per game that claude had before there were two is still resumed, and moved":
    beginBoth()
    createDir(root / "tmp" / "studio")
    writeFile(root / "tmp" / "studio" / "session-pong.id", sessionId)
    check readSession(root, "pong", "claude") == sessionId
    check readSession(root, "pong", "codex") == "" # it was never codex's
    turn("again")
    check calls()[0]["args"].getElems.mapIt(it.getStr)[^2 .. ^1] == @["--resume", sessionId]
    check fileExists(root / "tmp" / "studio" / "chats-pong-claude.json") and not fileExists(root / "tmp" / "studio" / "session-pong.id")

  test "a pick file with anything but an agent's name in it is ignored":
    beginBoth()
    createDir(root / "tmp" / "studio")
    for junk in ["gemini", "codex; reboot", "", "../claude"]:
      writeFile(root / "tmp" / "studio" / "agent-pong.txt", junk)
      check currentAgent() == "claude"

suite "para studio chat: one turn at a time, stopping, the time limit":
  teardown: finish()

  test "while a turn runs a helper's lane is live and cannot be landed; after it, it is left over":
    begin("hang")
    # the game as `para new` makes it: a repository of its own, which the outer one ignores
    discard gitOk(root, "rm", "-r", "-q", "--cached", "games")
    root.put(".gitignore", "tmp/\ngames/*\n")
    let g = root / "games" / "pong"
    discard gitOk(g, "init", "-q")
    discard gitOk(g, "config", "user.name", "Scratch")
    discard gitOk(g, "config", "user.email", "scratch@example.com")
    discard gitOk(g, "config", "commit.gpgsign", "false")
    check runLaneIn(root, @["start", "pong", "--for", "builder", "--ticket", "ship moves"]).code == 0
    let lanes = proc (): JsonNode = jsonOf(running.request("GET", "/api/lanes?game=pong"))["lanes"]
    check not lanes()[0]["live"].getBool
    let pidFile = root / "tmp" / "pids.txt"
    putEnv("FAKE_CLAUDE_PIDFILE", pidFile)
    check running.send("build the ship").status == 200
    let until = epochTime() + 20
    while not fileExists(pidFile) and epochTime() < until: sleep(50)
    check lanes()[0]["live"].getBool
    check jsonOf(running.request("GET", "/api/state?game=pong"))["lanes"][0]["live"].getBool
    let land = running.post("/api/lane/land", %*{"game": "pong", "id": "builder"})
    check land.status == 409 and jsonOf(land)["error"].getStr == "busy"
    check running.post("/api/chat/stop", %*{}).status == 200
    var c: Chat
    running.waitFor(c, finished, 20)
    check not lanes()[0]["live"].getBool
    check dirExists(root / "games" / "pong.builder") # nothing removed it

  test "while a turn runs a second message, a Check and a fresh start are refused; Stop ends it":
    begin("hang")
    let pidFile = root / "tmp" / "pids.txt"
    putEnv("FAKE_CLAUDE_PIDFILE", pidFile)
    check running.send("go").status == 200
    let until = epochTime() + 20
    while not fileExists(pidFile) and epochTime() < until: sleep(50)
    check fileExists(pidFile)
    let pids = readFile(pidFile).split(' ').mapIt(parseInt(it))
    var c: Chat
    running.poll(c)
    check c.running
    let second = running.send("again")
    check second.status == 409 and jsonOf(second)["error"].getStr == "busy"
    check running.post("/api/check", %*{"game": "pong"}).status == 409
    check running.post("/api/chat/new", %*{"game": "pong"}).status == 409
    when not defined(windows):
      check pids.allIt(alive(it))
    let stop = running.post("/api/chat/stop", %*{})
    check stop.status == 200 and jsonOf(stop)["stopped"].getBool
    running.waitFor(c, finished, 20)
    check c.events.anyIt(it["kind"].getStr == "notice" and it["code"].getStr == "stopped")
    check c.events[^1]["text"].getStr == "stopped"
    check not c.events.anyIt(it["kind"].getStr == "error")
    when not defined(windows):
      var gone = false
      for _ in 0 ..< 60:
        if pids.allIt(not alive(it)):
          gone = true
          break
        sleep(50)
      check gone # the child and its grandchild
    check not jsonOf(running.post("/api/chat/stop", %*{}))["stopped"].getBool
    # and the next message is accepted
    putEnv("FAKE_CLAUDE_MODE", "normal")
    check running.send("after the stop").status == 200
    var d: Chat
    running.waitFor(d, proc (c: Chat): bool = c.kinds.count("done") >= 2)

  test "a Check running blocks a message, in plain words, and the message goes through once it ends":
    begin()
    # the job child is this program too: in "sleep" mode it just waits a moment, like a long check
    putEnv("FAKE_CLAUDE_MODE", "sleep")
    putEnv("FAKE_CLAUDE_SLEEP_MS", "1500")
    defer: delEnv("FAKE_CLAUDE_SLEEP_MS")
    let started = running.post("/api/check", %*{"game": "pong"})
    check started.status == 200
    let id = jsonOf(started)["job"]["id"].getInt
    let refused = running.send("hi")
    check refused.status == 409 and "Check" in jsonOf(refused)["message"].getStr
    check calls().len == 0
    let until = epochTime() + 20
    var ended = false
    while epochTime() < until:
      if not jsonOf(running.request("GET", "/api/job?id=" & $id & "&since=0"))["running"].getBool:
        ended = true
        break
      sleep(50)
    check ended
    putEnv("FAKE_CLAUDE_MODE", "normal")
    check running.send("hi").status == 200
    var c: Chat
    running.waitFor(c, finished)

  test "a message and a Check sent at the same instant: exactly one starts, the other is refused":
    for round in 1 .. 8:
      begin()
      putEnv("FAKE_CLAUDE_MODE", "sleep")
      putEnv("FAKE_CLAUDE_SLEEP_MS", "1500")
      var threads: array[2, Thread[RaceCall]]
      statuses[0] = 0
      statuses[1] = 0
      let port = running.srv.port
      let token = running.srv.token
      createThread(threads[0], raceMain, (port, token, 0, "/api/chat/send", $(%*{"game": "pong", "text": "hi"})))
      createThread(threads[1], raceMain, (port, token, 1, "/api/check", $(%*{"game": "pong"})))
      joinThreads(threads)
      check sorted(@statuses) == @[200, 409]
      delEnv("FAKE_CLAUDE_SLEEP_MS")
      finish()
    begin() # the teardown below expects a studio to stop

  test "a turn that runs past the limit is stopped with a clear message":
    begin("hang", turnSeconds = 1)
    putEnv("FAKE_CLAUDE_PIDFILE", root / "tmp" / "pids.txt")
    check running.send("go").status == 200
    var c: Chat
    running.waitFor(c, finished, 30)
    let err = c.events.filterIt(it["kind"].getStr == "error")
    check err.len == 1 and err[0]["code"].getStr == "timeout"
    check "longer than 1 second," in err[0]["text"].getStr
    check c.events[^1]["text"].getStr == "timeout"
    check not c.running

  test "closing the studio ends a turn that is still running, with its whole tree":
    begin("hang")
    let pidFile = root / "tmp" / "pids.txt"
    putEnv("FAKE_CLAUDE_PIDFILE", pidFile)
    check running.send("go").status == 200
    let until = epochTime() + 20
    while not fileExists(pidFile) and epochTime() < until: sleep(50)
    check fileExists(pidFile)
    let pids = readFile(pidFile).split(' ').mapIt(parseInt(it))
    let t0 = epochTime()
    running.st.shutdownStudio()
    check epochTime() - t0 < 15
    when not defined(windows):
      var gone = false
      for _ in 0 ..< 60:
        if pids.allIt(not alive(it)):
          gone = true
          break
        sleep(50)
      check gone

suite "para studio chat: when things go wrong":
  teardown: finish()

  proc endsWith(mode, fixtureName, code: string) =
    begin(mode, fixtureName)
    check running.send("hi").status == 200
    var c: Chat
    running.waitFor(c, finished)
    let err = c.events.filterIt(it["kind"].getStr == "error")
    check err.len == 1 and err[0]["code"].getStr == code
    check c.events[^1]["text"].getStr == "failed"
    check not c.running

  test "a crash ends the turn with a plain message":
    endsWith("crash", "helper_ok.jsonl", "crashed")

  test "claude not signed in ends the turn with the way out":
    endsWith("normal", "not_signed_in.jsonl", "not-signed-in")

  test "a tool that no longer speaks stream-json is called out":
    endsWith("garbage", "helper_ok.jsonl", "tool-changed")

  test "claude missing: the agent route and the chat both say so, with the install page":
    begin()
    let oldPath = getEnv("PATH")
    putEnv("PATH", root / "tmp")
    defer: putEnv("PATH", oldPath)
    running.st.shutdownStudio()
    running.stop()
    running = startStudio(root, getAppFilename(), "", adapterNamed("claude"), defaultTurnSeconds)
    let a = jsonOf(running.request("GET", "/api/agent"))
    check not a["installed"].getBool
    check "setup page" in a["note"].getStr and "Windows" in a["note"].getStr
    check a["url"].getStr == "https://code.claude.com/docs/en/setup"
    check running.send("hi").status == 200
    var c: Chat
    running.waitFor(c, finished)
    let err = c.events.filterIt(it["kind"].getStr == "error")
    check err.len == 1 and err[0]["code"].getStr == "not-installed" and err[0]["url"].getStr.startsWith("https://")
    check calls().len == 0

  test "a key in the environment never appears in anything the server returns":
    begin("secret")
    let key = "sk-ant-FAKEKEY-0123456789abcdef"
    putEnv("ANTHROPIC_API_KEY", key)
    check running.send("hi").status == 200
    var c: Chat
    running.waitFor(c, finished)
    check c.events.anyIt(it["kind"].getStr == "error")
    for path in ["/api/chat?game=pong&since=0", "/api/agent", "/api/state", "/api/savepoints", "/api/backup"]:
      let r = running.request("GET", path)
      check key notin r.raw and "0123456789abcdef" notin r.raw
    check "[hidden]" in $c.events or c.events.allIt("FAKEKEY" notin $it)
    # and nothing was written to disk with it either
    for f in walkDirRec(root / "tmp"):
      if f != logPath: check "FAKEKEY" notin readFile(f)

suite "para studio chat: what the page shows can never run":
  test "the server answers JSON only, marked nosniff, and passes the producer's text through as data":
    let scratchFixture = getTempDir() / "para_chat_xss_fixture.jsonl"
    writeFile(scratchFixture, """{"type":"system","subtype":"init","session_id":"11111111-2222-4333-8444-555555555555"}
{"type":"assistant","message":{"content":[{"type":"text","text":"<img src=x onerror=alert(1)></script><script>alert(2)</script>"}]},"parent_tool_use_id":null}
{"type":"result","subtype":"success","is_error":false,"result":"x"}
""")
    defer: removeFile(scratchFixture)
    begin(fixtureName = scratchFixture)
    defer: finish()
    check running.send("hi").status == 200
    var c: Chat
    running.waitFor(c, finished)
    let r = running.request("GET", "/api/chat?game=pong&since=0")
    check r.headers["content-type"].startsWith("application/json")
    check r.headers["x-content-type-options"] == "nosniff"
    check "onerror=alert(1)" in jsonOf(r)["events"][1]["text"].getStr # untouched text, as data
    # the page itself is served with a policy that allows only its own nonce'd script
    let page = running.request("GET", "/?token=" & running.srv.token, withToken = false)
    check "script-src 'nonce-" in page.headers["content-security-policy"]
    check "unsafe-inline" notin page.headers["content-security-policy"] and "unsafe-eval" notin page.headers["content-security-policy"]
