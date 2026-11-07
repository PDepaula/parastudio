# Tests for what Para Studio remembers across a restart, as events: each chat's book (number, title,
# times, session id, which chat is open), the producer and speed picks, and what a producer last ran
# with. They are the desk's `ChatBook`, `Desk` and `Producers` views (tools/para/studiodesk.nim) and
# the kit's forgetting file store `tmp/studio/studio.jsonl` (tools/para/chatstore.nim), replayed when
# the studio starts. What is pinned here (the book's rules themselves are scenarios in
# tests/studiodesk/scenarios.jsonl, run by test_para_studio_desk.nim):
#
# - a book, the picks and "what ran" come back after a restart, and the studio reads nothing but
#   studio.jsonl to get them;
# - a fresh chat is not listed, a title comes from the first message, the list is newest first, the
#   open chat can be deleted (the next message starts a fresh one) and a forgotten chat's number is
#   not handed out again;
# - a session id that a command line could not take is never kept, nor written;
# - deleting a chat takes its title, session id and lines out of the file; a key in a message never
#   reaches the file;
# - the files older studios kept (`chats-*.json`, `session-*.id`, `agent-*.txt`, `speed-*.txt`,
#   `default-agent.txt`) are moved into the log once, with nothing asked of the friend, and removed;
# - an event stored before it had a field replays with that field's default, an extra field is
#   ignored, and a line that cannot be an event never stops the studio from starting;
# - there is one lock.

import std/[unittest, os, strutils, json, times, sequtils, algorithm]
import tools/para/agent
import tools/para/agents
import tools/para/chatstore
import tools/para/studiochat
import tools/para/studiodesk

var
  sayingSession = ""        ## the session id the stand-in producer reports ("" says none)
  seenSessions: seq[string] ## the session id each turn was asked to resume ("" for a new conversation)

proc stubTurn(a: AgentAdapter, req: TurnRequest, ctl: ptr TurnControl, emit: EmitProc): TurnResult {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    seenSessions.add req.sessionId
    if sayingSession.len > 0 and not req.onSession.isNil: req.onSession(sayingSession)
    if not req.onAsked.isNil: req.onAsked("sonnet", "medium")
    if not req.onModel.isNil: req.onModel("claude-x", "high")
  emit(UiEvent(kind: ukSay, text: "on it"))
  TurnResult(ok: true)

let stubs = @[AgentAdapter(name: "stub", label: "Stub", runTurn: stubTurn),
              AgentAdapter(name: "other", label: "Other", runTurn: stubTurn)]

proc scratchRoot(): string =
  result = getTempDir() / ("para_book_" & $getCurrentProcessId() & "_" & $(epochTime() * 1000).int64)
  createDir(result)

var root: string
var chat: ptr ChatState

proc open() =
  chat = create(ChatState)
  initChat(chat, root, stubs)

proc restart() =
  shutdownChat(chat)
  open()

proc turn(game, text: string): Started =
  result = chat.startTurn(game, text)
  check result.ok
  let until = epochTime() + 10
  while chat.isRunning and epochTime() < until: sleep(2)
  check not chat.isRunning

proc studioFile(): string = root / "tmp" / "studio" / "studio.jsonl"

proc studioLog(): seq[JsonNode] =
  if fileExists(studioFile()):
    for line in lines(studioFile()):
      if line.len > 0: result.add parseJson(line)

proc studioEvents(kind: string): seq[JsonNode] = studioLog().filterIt(it["kind"].getStr == kind)

proc titles(game: string): seq[string] = chat.listChats(game).chats.mapIt(it.title)

proc ids(game: string): seq[int] = chat.listChats(game).chats.mapIt(it.id)

suite "the book, the picks and what ran survive a restart":
  setup:
    root = scratchRoot()
    sayingSession = "sess-one"
    seenSessions = @[]
    open()
  teardown:
    shutdownChat(chat)
    removeDir(root)

  test "a fresh chat is not listed, a title is the first message on one line, the list is newest first":
    check chat.listChats("pong").chats.len == 0 and chat.listChats("pong").current == 1
    discard turn("pong", "Make the ship\nmove")
    check titles("pong") == @["Make the ship move"]
    check chat.newConversation("pong")
    check chat.listChats("pong").current == 2 and titles("pong") == @["Make the ship move"] # fresh: not listed
    check chat.newConversation("pong") # asked twice: still the same fresh chat
    check chat.listChats("pong").current == 2
    discard turn("pong", "Add a score")
    check titles("pong") == @["Add a score", "Make the ship move"] and ids("pong") == @[2, 1]
    check chat.openChat("pong", 1).ok
    discard turn("pong", "And faster")
    check ids("pong") == @[1, 2] # the chat used last is first, and keeps its first title
    check titles("pong") == @["Make the ship move", "Add a score"]
    check seenSessions == @["", "", "sess-one"] # the third turn resumed chat 1's conversation, the second was a new one
    check chat.openChat("pong", 9).status == 404

  test "a long chat keeps its first title, start time and session id past the old 64 KB cap":
    discard turn("pong", "The very first message")
    let first = chat.listChats("pong").chats[0]
    check first.session == "sess-one"
    for i in 1 .. 300:
      discard turn("pong", "message number " & $i)
    check getFileSize(studioFile()) > 64 * 1024 and getFileSize(studioFile()) < 1024 * 1024
    restart()
    let list = chat.listChats("pong")
    check list.chats.len == 1
    check list.chats[0].title == "The very first message"
    check list.chats[0].started == first.started
    check list.chats[0].session == "sess-one"

  test "the book comes back after a restart, from studio.jsonl alone":
    discard turn("pong", "Make the ship move")
    check chat.newConversation("pong")
    discard turn("pong", "Add a score")
    check chat.openChat("pong", 1).ok
    restart()
    let list = chat.listChats("pong")
    check list.agent == "stub" and list.current == 1
    check list.chats.mapIt(it.title) == @["Add a score", "Make the ship move"]
    check list.chats.mapIt(it.session) == @["sess-one", "sess-one"]
    check readSession(root, "pong", "stub") == "sess-one"
    discard turn("pong", "after the restart") # resumes chat 1's conversation
    check seenSessions[^1] == "sess-one"
    check titles("pong") == @["Make the ship move", "Add a score"]

  test "a number the book handed out is not handed out again, even after a delete and a restart":
    discard turn("pong", "one")
    check chat.newConversation("pong")
    discard turn("pong", "two")
    check chat.openChat("pong", 1).ok
    check chat.deleteChat("pong", 2).ok # the newest number goes, chat 1 stays open
    restart()
    check ids("pong") == @[1]
    check chat.newConversation("pong") # the open chat is used, so a fresh one is made: number 3, not 2
    check chat.listChats("pong").current == 3

  test "deleting the open chat starts a fresh one, which a restart still has":
    discard turn("pong", "one")
    check chat.newConversation("pong")
    discard turn("pong", "two")
    check chat.deleteChat("pong", 2).ok
    check ids("pong") == @[1] and chat.listChats("pong").current == 3
    check chat.deleteChat("pong", 2).status == 404 # it is not in the list any more
    restart()
    check ids("pong") == @[1] and chat.listChats("pong").current == 3
    discard turn("pong", "three")
    check ids("pong") == @[3, 1]

  test "the producer and the speed picked for a game, and the studio-wide pick, come back":
    check chat.pickAgent("", "other").ok # the studio-wide pick
    check chat.pickAgent("pong", "stub").ok
    check chat.pickSpeed("pong", "deep").ok
    restart()
    check chat.agentOf("pong") == "stub" and chat.agentOf("tetris") == "other" and chat.agentOf("") == "other"
    check chat.speedOf("pong") == spDeep and chat.speedOf("tetris") == spStandard
    check chat.pickSpeed("pong", "standard").ok
    restart()
    check chat.speedOf("pong") == spStandard

  test "what the producer last ran with comes back, for its game and producer only":
    discard turn("pong", "go")
    let ran = chat.agentModel("pong", "stub")
    check ran.started and ran.askedModel == "sonnet" and ran.askedEffort == "medium" and ran.model == "claude-x" and ran.effort == "high"
    restart()
    let again = chat.agentModel("pong", "stub")
    check again.started and again.speed == spStandard and again.askedModel == "sonnet" and again.model == "claude-x" and again.effort == "high"
    check not chat.agentModel("pong", "other").started and not chat.agentModel("tetris", "stub").started

  test "a session id a command line could not take is never kept, and never written":
    sayingSession = "--dangerously-skip-permissions"
    discard turn("pong", "one")
    check readSession(root, "pong", "stub") == ""
    check "dangerously" notin readFile(studioFile())
    check chat.listChats("pong").chats[0].session == ""
    sayingSession = "abc-123_X"
    discard turn("pong", "two")
    check readSession(root, "pong", "stub") == "abc-123_X"
    sayingSession = "a b/c"
    discard turn("pong", "three")
    check readSession(root, "pong", "stub") == "abc-123_X" # the odd one changed nothing
    check studioEvents("SessionReported").mapIt(it["data"]["session"].getStr) == @["abc-123_X"]
    # a log edited by hand cannot make one reach a command line either
    shutdownChat(chat)
    writeFile(studioFile(), readFile(studioFile()).replace("abc-123_X", "--evil"))
    open()
    check readSession(root, "pong", "stub") == ""
    discard turn("pong", "four")
    check seenSessions[^1] == ""

  test "deleting a chat takes its title, session id and lines out of the file, and a key never gets in":
    discard turn("pong", "my key is sk-ant-REALLOOKINGKEY0123456789")
    check "REALLOOKINGKEY" notin readFile(studioFile())
    check "[hidden]" in readFile(studioFile()) # the title, with the key taken out
    check chat.newConversation("pong")
    discard turn("pong", "second chat")
    check "sess-one" in readFile(studioFile()) and fileExists(logPath(root, "pong", "stub", 1))
    check chat.deleteChat("pong", 1).ok
    let left = readFile(studioFile())
    check "hidden" notin left and "my key" notin left # chat 1's title is gone
    check studioEvents("SessionReported").len == 1 and studioEvents("ChatUsed").len == 1 # only chat 2's remain
    check studioEvents("ChatUsed")[0]["data"]["chat"].getInt == 2
    check not fileExists(logPath(root, "pong", "stub", 1))
    check readFile(logPath(root, "pong", "stub", 2)).len > 0 # no other chat's file is touched

suite "older studios' files move into the log, once":
  setup:
    root = scratchRoot()
    sayingSession = ""
    seenSessions = @[]
    createDir(root / "tmp" / "studio")
  teardown:
    shutdownChat(chat)
    removeDir(root)

  proc oldFile(name, text: string) = writeFile(root / "tmp" / "studio" / name, text)
  proc exists(name: string): bool = fileExists(root / "tmp" / "studio" / name)

  test "a book file, a session file, the picks and the speeds become events, and the files go":
    oldFile("chats-pong-stub.json", $(%*{"current": 3, "next": 4, "chats": [
      {"id": 1, "title": "Make the ship move", "started": 100, "updated": 150, "session": "aaaa-1"},
      {"id": 2, "title": "Add a score", "started": 200, "updated": 200, "session": ""}]}))
    oldFile("session-tetris.id", "bbbb-2") # claude's, from before there were two producers
    oldFile("agent-pong.txt", "other")
    oldFile("speed-pong.txt", "deep")
    oldFile("default-agent.txt", "other")
    open()
    for name in ["chats-pong-stub.json", "session-tetris.id", "agent-pong.txt", "speed-pong.txt", "default-agent.txt"]:
      check not exists(name)
    check chat.agentOf("pong") == "other" and chat.agentOf("tetris") == "other" and chat.agentOf("") == "other"
    check chat.speedOf("pong") == spDeep
    let list = chat.listChats("pong") # "other" is the pick: pong's chats with it are none, those with stub are below
    check list.agent == "other" and list.chats.len == 0
    check chat.pickAgent("pong", "stub").ok
    let book = chat.listChats("pong")
    check book.current == 3 and book.chats.mapIt(it.title) == @["Add a score", "Make the ship move"]
    check book.chats.mapIt(it.started) == @[200, 100] and book.chats.mapIt(it.updated) == @[200, 150]
    check readSession(root, "pong", "stub") == "" # the open chat (3) is a fresh one
    check book.chats.mapIt(it.session) == @["", "aaaa-1"]
    restart() # the same book from the log alone
    check chat.listChats("pong").chats.mapIt(it.title) == @["Add a score", "Make the ship move"]
    check chat.agentOf("pong") == "stub" # the pick made after the move is the later one
    check not exists("chats-pong-stub.json")

  test "a studio with nothing old and nothing yet makes no file at all":
    open()
    check chat.listChats("pong").chats.len == 0 and chat.agentOf("pong") == "stub"
    check not fileExists(studioFile())

  test "junk in the old files is left out, and the files go all the same":
    oldFile("agent-pong.txt", "gemini")
    oldFile("speed-pong.txt", "ludicrous")
    oldFile("default-agent.txt", "codex; reboot")
    oldFile("chats-pong-stub.json", "not json at all")
    oldFile("session-pong-stub.id", "--dangerously-skip-permissions")
    open()
    check chat.agentOf("pong") == "stub" and chat.speedOf("pong") == spStandard
    check chat.listChats("pong").chats.len == 0
    for name in ["agent-pong.txt", "speed-pong.txt", "default-agent.txt", "chats-pong-stub.json", "session-pong-stub.id"]:
      check not exists(name)
    check not fileExists(studioFile()) or "dangerously" notin readFile(studioFile())

  test "a file an older studio left after the studio started is moved when its book is first used":
    open()
    oldFile("session-pong-stub.id", "cccc-3")
    check readSession(root, "pong", "stub") == "cccc-3" # tools can still read it
    check chat.listChats("pong").chats.mapIt(it.session) == @["cccc-3"]
    check not exists("session-pong-stub.id")
    check readSession(root, "pong", "stub") == "cccc-3" # now from the log

suite "what an event looked like when it was stored":
  setup:
    root = scratchRoot()
    createDir(root / "tmp" / "studio")
    sayingSession = ""
  teardown:
    shutdownChat(chat)
    removeDir(root)

  test "an event stored before it had a field replays with that field's default; an extra field is ignored":
    # ChatUsed as it would have been written before `title` existed, and with a field it no longer has
    writeFile(studioFile(), "{\"seq\":4,\"at\":1,\"kind\":\"ChatUsed\",\"data\":{\"game\":\"pong\",\"agent\":\"stub\",\"chat\":1,\"at\":100,\"gone\":true}}\n")
    open()
    let list = chat.listChats("pong")
    check list.chats.len == 1 and list.chats[0].title == "" and list.chats[0].started == 100
    discard turn("pong", "after") # the log goes on past the position it held
    check studioEvents("ChatUsed").mapIt(it["seq"].getInt).sorted.deduplicate.len == 2
    check studioEvents("ChatUsed")[^1]["seq"].getInt > 4

  test "a line that is not an event, or whose field has the wrong type, never stops the studio from starting":
    writeFile(studioFile(), "not json at all\n" &
      "{\"seq\":1,\"at\":1,\"kind\":\"ChatUsed\",\"data\":{\"game\":\"pong\",\"agent\":\"stub\",\"chat\":1,\"at\":100,\"title\":\"kept\"}}\n" &
      "{\"seq\":2,\"at\":1,\"kind\":\"ChatUsed\",\"data\":{\"game\":\"pong\",\"agent\":\"stub\",\"chat\":2,\"at\":\"yesterday\",\"title\":\"wrong type\"}}\n" &
      "{\"seq\":3,\"at\":1,\"kind\":\"SomethingNew\",\"data\":{}}\n")
    open()
    check chat.listChats("pong").chats.mapIt(it.title) == @["kept"]
    discard turn("pong", "still works")
    check chat.listChats("pong").chats.mapIt(it.title) == @["kept"] # chat 1 was used again; the line with the wrong type left nothing

suite "the desk's own copy of the session shape, and the one lock":
  test "a session id is good to the desk exactly when `validSessionToken` accepts it":
    for id in ["", "a", "abc-DEF_123", "-x", "a b", "a/b", "é", "x".repeat(64), "x".repeat(65), "a\nb", "--dangerously-skip-permissions"]:
      check studiodesk.goodSession(id) == (id.len > 0 and validSessionToken(id) == id)

  test "the chat shell has the one lock, and no book or note lock":
    let src = readFile(currentSourcePath.parentDir.parentDir / "tools" / "para" / "studiochat.nim")
    check src.count("initLock(") == 1
    check "bookLock" notin src and "noteLock" notin src
    check "flushNotes" notin src
