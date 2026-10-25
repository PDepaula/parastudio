# Tests for the Studio's past chats: the store (tools/para/chatstore.nim) on its own, and the list,
# open and delete routes (studiochat.nim, studioapi.nim) through the real server on a loopback port
# and the stand-in `claude` (tests/fake_claude.nim). What is pinned here:
#
# - many chats per game and producer, newest first, each with a title from its first message, and
#   numbers that are never reused;
# - opening an older chat resumes that chat's own conversation, not the newest one;
# - the list, the open chat and every chat's session survive closing and starting the studio again;
# - the one conversation an older studio kept loads as one chat, and a file the studio did not
#   write is read as far as it makes sense, never trusted;
# - deleting needs an explicit yes, is refused while a turn runs, and never touches the game's
#   folder.

import std/[unittest, os, strutils, json, times, sequtils, algorithm]
import fake_claude
import studio_support
import tools/para/agent
import tools/para/agents
import tools/para/chatstore
import tools/para/studiochat

when isMainModule:
  if getEnv("PARA_FAKE_CLAUDE") == "1":
    fakeClaudeMain()

proc scratchRoot(): string =
  result = getTempDir() / ("para_chats_" & $getCurrentProcessId() & "_" & $epochTime().int64)
  createDir(result)

suite "the chat store":
  var root: string
  setup: root = scratchRoot()
  teardown: removeDir(root)

  test "a game with no chats has one fresh chat and lists nothing":
    let b = loadBook(root, "pong", "claude")
    check b.chats.len == 0 and b.current == 1
    check b.newestFirst.len == 0
    check not fileExists(chatsPath(root, "pong", "claude")) # reading writes nothing

  test "many chats per game: each gets its title from its first message, newest first":
    var b = loadBook(root, "pong", "claude")
    check b.noteMessage("Make the ship move", 100) == ""
    check b.setSession(b.current, "aaaa-1")
    b.freshChat()
    check b.noteMessage("Add a score\nthat counts up", 200) == ""
    check b.setSession(b.current, "bbbb-2")
    b.freshChat()
    check b.noteMessage("Hello", 300) == ""
    check b.chats.len == 3
    check b.newestFirst.mapIt(it.title) == @["Hello", "Add a score that counts up", "Make the ship move"]
    check b.newestFirst.mapIt(it.id) == @[3, 2, 1]
    # a later message in an older chat moves it to the top and keeps its title
    check b.openChat(1)
    check b.noteMessage("And make it faster", 400) == "aaaa-1"
    check b.newestFirst.mapIt(it.id) == @[1, 3, 2]
    check b.chats[b.find(1)].title == "Make the ship move"
    check b.chats[b.find(1)].started == 100 and b.chats[b.find(1)].updated == 400

  test "New chat on a chat with no message yet changes nothing, and numbers are never reused":
    var b = loadBook(root, "pong", "claude")
    b.freshChat()
    check b.current == 1 # still fresh: nothing to start over from
    discard b.noteMessage("one", 1)
    b.freshChat()
    check b.current == 2
    discard b.noteMessage("two", 2)
    check b.dropChat(2)
    check b.current == 3 # deleting the open chat opens a fresh one, with a new number
    check b.chats.mapIt(it.id) == @[1]
    discard b.noteMessage("three", 3)
    check b.chats.mapIt(it.id) == @[1, 3]
    check not b.dropChat(2) and not b.openChat(2) and not b.setSession(2, "x")

  test "the chats, the open one and each session survive a restart (the file)":
    var b = loadBook(root, "pong", "claude")
    discard b.noteMessage("first", 10)
    check b.setSession(1, "s-first")
    b.freshChat()
    discard b.noteMessage("second", 20)
    check b.setSession(2, "s-second")
    check b.openChat(1)
    check saveBook(root, "pong", "claude", b)
    let again = loadBook(root, "pong", "claude")
    check again == b
    check again.current == 1 and again.chats[again.find(1)].session == "s-first"
    check readSession(root, "pong", "claude") == "s-first"
    # the next fresh chat after a restart still gets a new number
    var c = again
    c.freshChat()
    check c.current == 3

  test "games and agents keep separate lists":
    var b = loadBook(root, "pong", "claude")
    discard b.noteMessage("pong with claude", 1)
    check saveBook(root, "pong", "claude", b)
    check loadBook(root, "pong", "codex").chats.len == 0
    check loadBook(root, "tetris", "claude").chats.len == 0
    check loadBook(root, "pong", "claude").chats.len == 1

  test "names that are not ones the studio makes are never a path":
    for (game, agent) in [("../x", "claude"), ("pong", "../claude"), ("Pong", "claude"), ("pong", "")]:
      check not saveBook(root, game, agent, ChatBook(current: 1, next: 2))
      check loadBook(root, game, agent).chats.len == 0
    check toSeq(walkDirRec(root)).len == 0

  test "the one conversation an older studio kept loads as one chat, and is moved on the next save":
    createDir(root / "tmp" / "studio")
    let old = root / "tmp" / "studio" / "session-pong-claude.id"
    writeFile(old, sessionId)
    var b = loadBook(root, "pong", "claude")
    check b.chats.len == 1 and b.current == 1
    check b.chats[0].session == sessionId and b.chats[0].title == ""
    check b.chats[0].updated > 0 # the file's own time
    check readSession(root, "pong", "claude") == sessionId
    b.freshChat()
    check saveBook(root, "pong", "claude", b)
    check not fileExists(old)
    check loadBook(root, "pong", "claude").chats[0].session == sessionId

  test "Claude's file from before there were two agents loads too, for Claude only":
    createDir(root / "tmp" / "studio")
    writeFile(root / "tmp" / "studio" / "session-pong.id", sessionId)
    check loadBook(root, "pong", "claude").chats.len == 1
    check loadBook(root, "pong", "codex").chats.len == 0

  test "a file the studio did not write is read as far as it makes sense":
    createDir(root / "tmp" / "studio")
    let path = chatsPath(root, "pong", "claude")
    for junk in ["", "not json", "[1, 2]", "{\"chats\": 3}", "{\"current\": \"7\"}"]:
      writeFile(path, junk)
      let b = loadBook(root, "pong", "claude")
      check b.chats.len == 0 and b.current >= 1
    writeFile(path, $(%*{"current": 2, "next": 1, "chats": [
      {"id": 1, "title": "ok", "started": 5, "updated": 6, "session": "--dangerously-skip-permissions"},
      {"id": 1, "title": "same number again", "updated": 7},
      {"id": -4, "title": "bad number"},
      {"id": 2, "title": 42, "updated": "soon", "session": "good-id"},
      "not a chat"]}))
    let b = loadBook(root, "pong", "claude")
    check b.chats.mapIt(it.id) == @[1, 2]
    check b.chats[0].session == "" # could never be a session id
    check b.chats[1].title == "" and b.chats[1].updated == 0 and b.chats[1].session == "good-id"
    check b.current == 2 and b.next == 3

  test "a title is one short line, cut on a letter, with keys taken out":
    check titleOf("  two\n\tlines  ") == "two lines"
    let long = "é".repeat(maxTitleRunes + 10)
    check titleOf(long) == "é".repeat(maxTitleRunes) & "…"
    check titleOf("use sk-ant-REALLOOKINGKEY0123456789 please") == "use [hidden] please"
    check titleOf("") == ""

const fixtures = currentSourcePath.parentDir / "fixtures" / "claude-stream"

var root: string
var running: Running
var logPath: string
var scratch: seq[string]

proc jsonOf(r: Reply): JsonNode = parseJson(r.body)
proc post(r: Running, path: string, body: JsonNode): Reply = r.request("POST", path, body = $body)

proc fixtureFor(session: string): string =
  ## A recorded turn whose conversation is `session`, so a test can tell chats apart.
  result = getTempDir() / ("para_chats_fixture_" & session & ".jsonl")
  writeFile(result, "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"" & session & "\"}\n" &
    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Hello, director.\"}]},\"parent_tool_use_id\":null}\n" &
    "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\"}\n")
  scratch.add result

proc startHere() =
  running = startStudio(root, getAppFilename(), "", adapterNamed("claude", getAppFilename()))

proc begin() =
  root = newGameRepo(@["pong"])
  logPath = root / "tmp" / "fake.log"
  createDir(root / "tmp")
  putEnv("PARA_FAKE_CLAUDE", "1")
  putEnv("FAKE_CLAUDE_MODE", "normal")
  putEnv("FAKE_CLAUDE_FIXTURE", fixtures / "helper_ok.jsonl")
  putEnv("FAKE_CLAUDE_LOG", logPath)
  startHere()

proc finish() =
  running.stop()
  for k in ["PARA_FAKE_CLAUDE", "FAKE_CLAUDE_MODE", "FAKE_CLAUDE_FIXTURE", "FAKE_CLAUDE_LOG", "FAKE_CLAUDE_PIDFILE"]:
    delEnv(k)
  for f in scratch: removeFile(f)
  scratch = @[]
  removeDir(root)

proc calls(): seq[JsonNode] =
  if not fileExists(logPath): return
  for line in lines(logPath): result.add parseJson(line)

proc lastArgs(): seq[string] = calls()[^1]["args"].getElems.mapIt(it.getStr)

proc chatNow(): JsonNode = jsonOf(running.request("GET", "/api/chat?game=pong&since=0"))
proc chats(): JsonNode = jsonOf(running.request("GET", "/api/chats?game=pong"))
proc titles(): seq[string] = chats()["chats"].getElems.mapIt(it["title"].getStr)
proc idOf(title: string): int =
  for c in chats()["chats"]:
    if c["title"].getStr == title: return c["id"].getInt

proc turn(text: string, session = "") =
  ## One whole turn in the open chat; `session` is the conversation the stand-in reports.
  if session.len > 0: putEnv("FAKE_CLAUDE_FIXTURE", fixtureFor(session))
  let before = calls().len
  check running.post("/api/chat/send", %*{"game": "pong", "text": text}).status == 200
  let until = epochTime() + 30
  while epochTime() < until:
    if calls().len > before and not chatNow()["running"].getBool: return
    sleep(50)
  doAssert false, "the turn did not end"

proc gameFiles(): seq[(string, string)] =
  for f in walkDirRec(root / "games"): result.add (f.relativePath(root), readFile(f))
  result.sort()

suite "para studio chats: the list, opening and deleting":
  setup: begin()
  teardown: finish()

  test "a new game lists no chats, and looking starts nothing":
    let d = chats()
    check d["agent"].getStr == "claude" and d["chats"].len == 0 and d["current"].getInt == 1
    check chatNow()["chat"].getInt == 1
    check calls().len == 0

  test "New chat keeps the earlier ones: three chats, newest first, each resuming its own conversation":
    turn("Make the ship move", "aaaaaaaa-0000-4000-8000-000000000001")
    check running.post("/api/chat/new", %*{"game": "pong"}).status == 200
    check chatNow()["events"].len == 0 # the page starts empty
    turn("Add a score", "aaaaaaaa-0000-4000-8000-000000000002")
    check "--resume" notin lastArgs() # a new chat is a new conversation
    check running.post("/api/chat/new", %*{"game": "pong"}).status == 200
    turn("Hello, producer! Where did we leave off?", "aaaaaaaa-0000-4000-8000-000000000003")
    check titles() == @["Hello, producer! Where did we leave off?", "Add a score", "Make the ship move"]
    let d = chats()
    check d["chats"][0]["open"].getBool and not d["chats"][1]["open"].getBool
    check d["chats"].getElems.allIt(it["started"].getInt > 0 and it["updated"].getInt >= it["started"].getInt)
    check "session" notin $d # the page never needs the agent's own id
    # open the oldest: the next message resumes that one's conversation
    let first = idOf("Make the ship move")
    check running.post("/api/chat/open", %*{"game": "pong", "id": first}).status == 200
    check chatNow()["chat"].getInt == first
    check chatNow()["events"].getElems.mapIt(it["text"].getStr)[0] == "Make the ship move" # its lines, still in memory
    turn("And faster")
    check lastArgs()[^2 .. ^1] == @["--resume", "aaaaaaaa-0000-4000-8000-000000000001"]
    check titles()[0] == "Make the ship move" # used last, so first
    let second = idOf("Add a score")
    check running.post("/api/chat/open", %*{"game": "pong", "id": second}).status == 200
    turn("Score in gold")
    check lastArgs()[^2 .. ^1] == @["--resume", "aaaaaaaa-0000-4000-8000-000000000002"]

  test "after a restart the chats, the open one and their conversations are all still there":
    turn("Make the ship move", "aaaaaaaa-0000-4000-8000-000000000001")
    check running.post("/api/chat/new", %*{"game": "pong"}).status == 200
    turn("Add a score", "aaaaaaaa-0000-4000-8000-000000000002")
    let first = idOf("Make the ship move")
    check running.post("/api/chat/open", %*{"game": "pong", "id": first}).status == 200
    let before = chats()
    running.stop()
    startHere()
    check chats() == before
    check chatNow()["chat"].getInt == first
    check chatNow()["events"].len == 0 # the lines lived in memory
    turn("Carry on")
    check lastArgs()[^2 .. ^1] == @["--resume", "aaaaaaaa-0000-4000-8000-000000000001"]
    # opening the other one after a restart says why its earlier lines are not shown
    check running.post("/api/chat/open", %*{"game": "pong", "id": idOf("Add a score")}).status == 200
    let ev = chatNow()["events"]
    check ev.len == 1 and ev[0]["kind"].getStr == "notice" and ev[0]["code"].getStr == "chat-opened"
    turn("More")
    check lastArgs()[^2 .. ^1] == @["--resume", "aaaaaaaa-0000-4000-8000-000000000002"]

  test "the one conversation an older studio kept shows as one chat and is resumed":
    running.stop()
    createDir(root / "tmp" / "studio")
    writeFile(root / "tmp" / "studio" / "session-pong-claude.id", sessionId)
    startHere()
    let d = chats()
    check d["chats"].len == 1 and d["chats"][0]["title"].getStr == "" and d["chats"][0]["open"].getBool
    turn("Where were we?")
    check lastArgs()[^2 .. ^1] == @["--resume", sessionId]
    check not fileExists(root / "tmp" / "studio" / "session-pong-claude.id")
    check chats()["chats"][0]["title"].getStr == "" # it keeps no title it never had

  test "deleting needs a yes, forgets only that chat, and never touches the game's folder":
    turn("Make the ship move", "aaaaaaaa-0000-4000-8000-000000000001")
    check running.post("/api/chat/new", %*{"game": "pong"}).status == 200
    turn("Add a score", "aaaaaaaa-0000-4000-8000-000000000002")
    let files = gameFiles()
    let first = idOf("Make the ship move")
    for body in [%*{"game": "pong", "id": first}, %*{"game": "pong", "id": first, "confirm": false},
                 %*{"game": "pong", "id": first, "confirm": "yes"}]:
      let r = running.post("/api/chat/delete", body)
      check r.status == 400 and jsonOf(r)["error"].getStr == "needs-confirm"
    check titles().len == 2
    check running.post("/api/chat/delete", %*{"game": "pong", "id": first, "confirm": true}).status == 200
    check titles() == @["Add a score"]
    check gameFiles() == files
    let r = running.post("/api/chat/open", %*{"game": "pong", "id": first})
    check r.status == 404 and jsonOf(r)["error"].getStr == "no-such-chat"
    # deleting the open chat leaves a fresh one open; the next message is a new conversation
    let second = idOf("Add a score")
    check running.post("/api/chat/delete", %*{"game": "pong", "id": second, "confirm": true}).status == 200
    check chats()["chats"].len == 0
    check chatNow()["events"].len == 0
    turn("Start again", "aaaaaaaa-0000-4000-8000-000000000003")
    check "--resume" notin lastArgs()
    check gameFiles() == files
    running.stop()
    startHere()
    check titles() == @["Start again"] # gone for good, after a restart too

  test "requests that cannot be done are refused in plain words":
    turn("one")
    for (path, body, status) in [
        ("/api/chat/open", %*{"game": "pong"}, 400), ("/api/chat/open", %*{"game": "pong", "id": "1"}, 400),
        ("/api/chat/open", %*{"game": "pong", "id": 0}, 400), ("/api/chat/open", %*{"game": "pong", "id": 1.5}, 400),
        ("/api/chat/open", %*{"game": "pong", "id": 99}, 404), ("/api/chat/open", %*{"game": "nope", "id": 1}, 404),
        ("/api/chat/delete", %*{"game": "pong", "id": 99, "confirm": true}, 404),
        ("/api/chat/delete", %*{"game": "pong", "confirm": true}, 400)]:
      let r = running.post(path, body)
      check r.status == status
      check jsonOf(r)["message"].getStr.len > 0
    check running.request("GET", "/api/chats?game=nope").status == 404
    check running.request("GET", "/api/chats", withToken = false).status == 403
    check running.request("POST", "/api/chat/delete", body = $(%*{"game": "pong", "id": 1, "confirm": true}), withToken = false).status == 403
    check running.request("POST", "/api/chat/delete", body = $(%*{"game": "pong", "id": 1, "confirm": true}),
                          headers = @[("Origin", "https://evil.example")]).status == 403
    check titles() == @["one"]

  test "while a turn runs a chat cannot be opened, started or deleted":
    turn("one", "aaaaaaaa-0000-4000-8000-000000000001")
    check running.post("/api/chat/new", %*{"game": "pong"}).status == 200
    turn("two", "aaaaaaaa-0000-4000-8000-000000000002")
    putEnv("FAKE_CLAUDE_MODE", "hang")
    putEnv("FAKE_CLAUDE_PIDFILE", root / "tmp" / "pids.txt")
    check running.post("/api/chat/send", %*{"game": "pong", "text": "go"}).status == 200
    let until = epochTime() + 20
    while not fileExists(root / "tmp" / "pids.txt") and epochTime() < until: sleep(50)
    let first = idOf("one")
    for (path, body) in [("/api/chat/open", %*{"game": "pong", "id": first}),
                         ("/api/chat/delete", %*{"game": "pong", "id": first, "confirm": true}),
                         ("/api/chat/new", %*{"game": "pong"})]:
      let r = running.post(path, body)
      check r.status == 409 and jsonOf(r)["error"].getStr == "busy"
    check titles() == @["two", "one"]
    check running.post("/api/chat/stop", %*{}).status == 200
    let stopUntil = epochTime() + 20
    while chatNow()["running"].getBool and epochTime() < stopUntil: sleep(50)
    check running.post("/api/chat/open", %*{"game": "pong", "id": first}).status == 200
