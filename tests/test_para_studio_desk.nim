# Tests for the studio's desk: the pure core written with eversince (tools/para/studiodesk.nim, its
# model file studiodesk.em) and the shell around it (tools/para/studiochat.nim, chatstore.nim). What
# is pinned here:
#
# - the rules (one turn per game, no message during that game's step, one step at a time, a save
#   needs a note, no producer pick during that game's turn, ...) as scenarios, run by the kit's own
#   runner against the real `decide` and views, and every command and refusal word has one;
# - the chat's lines are the desk's events, written to the chat's own file through the kit's
#   forgetting file store: a key never reaches the file, the oldest lines go when the file is over
#   its size, a deleted chat is gone from the file and from the page, and a restart goes on from
#   where the log was (and a replay rebuilds the page's lines);
# - a file an older studio wrote is read as before and rewritten in the kit's form;
# - there is no gate any more: a turn and a step of the same game, started at the same moment from two
#   threads, are never both accepted, with one lock around the desk and nothing else.

import std/[unittest, os, strutils, json, times, sequtils, atomics, tables]
import eversince
import tools/para/agent
import tools/para/chatstore
import tools/para/studiochat
import tools/para/studiodesk

const
  here = currentSourcePath.parentDir
  scenarioFile = here / "studiodesk" / "scenarios.jsonl"
  modelFile = here.parentDir / "tools" / "para" / "studiodesk.em"
  sevenRules = [
    "a second message to the same game is refused while its turn runs", # one turn per game
    "another game can start a turn meanwhile", # two games may each have a turn
    "a message is refused while a step of the same game runs", # no message while that game's step runs
    "a step for another game does not wait for the turn", # a step does not wait for another game's turn
    "a second step is refused while one runs, whichever game", # one step at a time, all games
    "a save needs a note", # a save needs a note
    "picking a producer is refused while that game's turn runs"] # no producer switch during that game's turn

proc scratchRoot(): string =
  result = getTempDir() / ("para_desk_" & $getCurrentProcessId() & "_" & $epochTime().int64 & "_" & $(epochTime() * 1000).int64)
  createDir(result)

proc scenarios(): seq[JsonNode] =
  for line in lines(scenarioFile):
    if line.strip.len > 0: result.add parseJson(line)

suite "the desk's rules, as scenarios against the real core":
  test "every scenario passes":
    let all = scenarios()
    check all.len >= 50
    for sc in all:
      let verdict = runScenario[StudioDesk](sc)
      if verdict.len > 0: checkpoint sc["name"].getStr
      check verdict == ""

  test "the seven rules each have a scenario":
    let names = scenarios().mapIt(it["name"].getStr)
    for rule in sevenRules: check rule in names

  test "every command has an accepted scenario and every refusal word has a refused one":
    let model = parseModel(readFile(modelFile), "studiodesk.em")
    var accepted: seq[string]
    var refused: seq[(string, string)]
    for sc in scenarios():
      if not sc.hasKey("when"): continue
      let cmd = sc["when"]["command"].getStr
      if sc["then"].hasKey("refused"): refused.add (cmd, sc["then"]["refused"].getStr)
      else: accepted.add cmd
    var commands = 0
    for b in model.blocks:
      if b.kind != "command": continue
      inc commands
      check b.name in accepted
      for code in b.edge("refuses"): check (b.name, code) in refused
    check commands == 18

  test "the model file and the code agree (the build stops when they do not): the blocks are all there":
    check processors(StudioDesk()).len == 0 # no processor: the shell's threads issue the commands back
    check studioDeskCatalog.splitLines.len == 54 # 18 commands, 16 events, 4 views, 4 queries, 12 records

suite "the desk on the chats' own files":
  var root: string
  var store: ChatFilesStore
  var rt: Runtime[StudioDesk]
  setup:
    root = scratchRoot()
    store = newChatFiles(root)
    rt = Runtime[StudioDesk](store: store, clock: proc (): int64 = 1_700_000_000_000)
  teardown:
    store.close()
    removeDir(root)

  proc send(game, text: string, chat = 1): Decision =
    rt.execute("StartTurn", %*{"game": game, "agent": "claude", "chat": chat, "text": text, "busyGames": []})
  proc say(game, text: string, chat = 1, agent = "claude"): Decision =
    rt.execute("AddLine", %*{"game": game, "agent": agent, "chat": chat,
      "line": lineBody((you: false, ev: UiEvent(kind: ukSay, text: text)))})
  proc raw(game: string, chat = 1): string =
    let path = logPath(root, game, "claude", chat)
    if fileExists(path): readFile(path) else: ""
  proc kept(game: string, chat = 1): seq[string] =
    ## The lines of a chat's file.
    raw(game, chat).splitLines.filterIt(it.len > 0)

  test "a message is one line in the chat's file, and nothing else about the turn is kept":
    check not send("pong", "Make the ship move").refused
    check kept("pong").len == 1
    let e = fromLine(kept("pong")[0])
    check e.kind == "LineAdded" and e.data["n"].getInt == 1
    check e.seq == 2 # the turn's start took position 1: it is in the log's numbering, not in the file
    check e.data["line"]["you"].getBool and e.data["line"]["text"].getStr == "Make the ship move"
    check rt.app.desk.turns.len == 1 # the desk knows the turn, the file does not
    check readChat(root, "pong", "claude", 1).lines.mapIt(it.ev.text) == @["Make the ship move"]

  test "a key is taken out of the file's line and of the stored event, not of what the page showed":
    check not send("pong", "my key is sk-ant-REALLOOKINGKEY0123456789").refused
    check "REALLOOKINGKEY" notin raw("pong")
    check "[hidden]" in raw("pong")
    check "REALLOOKINGKEY" notin $store.load.mapIt(it.data)
    check "REALLOOKINGKEY" in rt.app.chat.lines[0].line.text # the page saw the line before it was cleaned
    check not say("pong", "Bearer abcdef123456 and sk-ant-SECONDKEY0123456789").refused
    check "SECONDKEY" notin raw("pong") and "abcdef123456" notin raw("pong")

  test "a line that is not kept (a helper still working) shows on the page and is never written":
    check not say("pong", "kept").refused
    let working = UiEvent(kind: ukHelper, id: "t1", role: "builder", status: "working", text: "Ship", tools: 1)
    check not rt.execute("AddLine", %*{"game": "pong", "agent": "claude", "chat": 1, "line": lineBody((you: false, ev: working))}).refused
    check rt.app.chat.lines.len == 2
    check kept("pong").len == 1

  test "deleting a chat takes its lines out of the file and the page, and no other chat's":
    check not send("pong", "secret plans").refused
    check not say("pong", "kept in chat two", chat = 2).refused
    check not say("dog", "other game").refused
    check fileExists(logPath(root, "pong", "claude", 1))
    check not rt.execute("EndTurn", %*{"game": "pong", "agent": "claude", "chat": 1, "turn": 1, "outcome": "ok"}).refused
    let d = rt.execute("DeleteChat", %*{"game": "pong", "agent": "claude", "chat": 1})
    check not d.refused
    check not fileExists(logPath(root, "pong", "claude", 1))
    check "secret plans" notin $rt.app.chat.lines.mapIt(it.line.text)
    check "secret plans" notin $store.load.mapIt(it.data)
    check readChat(root, "pong", "claude", 2).lines.len == 1 and readChat(root, "dog", "claude", 1).lines.len == 1
    check rt.app.chat.lines.filterIt(it.game == "pong").len == 1 # only chat two's line
    # a new line in the deleted chat starts it over, from one
    check not say("pong", "again").refused
    check fromLine(kept("pong")[0]).data["n"].getInt == 1

  test "a chat cannot be deleted while its game's turn runs, and its file stays":
    check not send("pong", "working on it").refused
    check rt.execute("DeleteChat", %*{"game": "pong", "agent": "claude", "chat": 1}).refused
    check fileExists(logPath(root, "pong", "claude", 1))

  test "a chat's file past its size keeps the newest lines, behind one note, and the numbers go on":
    let long = "x".repeat(10_000)
    for i in 1 .. 60: check not say("pong", $i & " " & long).refused
    check getFileSize(logPath(root, "pong", "claude", 1)) <= maxLogBytes
    let back = readChat(root, "pong", "claude", 1)
    check back.lines[0].ev.code == "chat-trimmed"
    check back.lines.countIt(it.ev.code == "chat-trimmed") == 1
    check back.lines[^1].ev.text.startsWith("60 ") and back.lastN == 60
    check rt.app.chat.lines.len == 60 # the page still holds them all

  test "after a restart the log goes on from where it was, and a replay rebuilds the page's lines":
    check not send("pong", "first").refused
    check not say("pong", "reply").refused
    check not say("dog", "woof").refused
    store.close()
    let again = newChatFiles(root)
    check again.highestSeq == 4 # the turn's start, the message, the reply, the other game's line
    var rt2 = replay[StudioDesk](again)
    check rt2.app.chat.lines.mapIt(it.line.text) == @["first", "reply", "woof"]
    check rt2.app.desk.turns.len == 0 # a turn is not kept: a restart has none running
    rt2.clock = proc (): int64 = 1
    check not rt2.execute("AddLine", %*{"game": "pong", "agent": "claude", "chat": 1,
      "line": lineBody((you: false, ev: UiEvent(kind: ukSay, text: "later")))}).refused
    check rt2.seq == 5
    check fromLine(kept("pong")[^1]).seq == 5
    check fromLine(kept("pong")[^1]).data["n"].getInt == 3 # the chat's third kept line
    again.close()

  test "a file an older studio wrote is read as before, and rewritten in the kit's form once":
    createDir(root / "tmp" / "studio")
    let path = logPath(root, "pong", "claude", 1)
    writeFile(path, "{\"kind\":\"you\",\"text\":\"old message\"}\nnot json\n{\"kind\":\"say\",\"text\":\"old reply\"}\n")
    check readChat(root, "pong", "claude", 1).lines.mapIt(it.ev.text) == @["old message", "old reply"] # before any rewrite
    let s2 = newChatFiles(root)
    check s2.highestSeq == 2
    check path.readFile.splitLines.filterIt(it.len > 0).allIt(it.startsWith("{\"seq\":"))
    check readChat(root, "pong", "claude", 1).lines.mapIt((it.you, it.ev.text)) == @[(true, "old message"), (false, "old reply")]
    check readChat(root, "pong", "claude", 1).lastN == 2
    s2.close()

suite "one lock, no gate":
  var gate: Atomic[bool] ## the stand-in producer's turn runs until this is set
  var root: string
  var chat: ptr ChatState

  proc stubTurn(a: AgentAdapter, req: TurnRequest, ctl: ptr TurnControl, emit: EmitProc): TurnResult {.nimcall, gcsafe.} =
    emit(UiEvent(kind: ukSay, text: "on it"))
    {.cast(gcsafe).}:
      while not gate.load: sleep(1)
    TurnResult(ok: true)

  type Racer = object
    chat: ptr ChatState
    go: ptr Atomic[bool]
    asTurn: bool
    ok: bool

  proc racer(r: ptr Racer) {.thread.} =
    while not r.go[].load: discard
    if r.asTurn: r.ok = r.chat.startTurn("pong", "hello").ok
    else: r.ok = r.chat.startStep("pong", "check", "").ok

  setup:
    root = scratchRoot()
    gate.store(false)
    chat = create(ChatState)
    initChat(chat, root, @[AgentAdapter(name: "stub", label: "Stub", runTurn: stubTurn)])
  teardown:
    gate.store(true)
    shutdownChat(chat)
    removeDir(root)

  proc settle() =
    ## Lets the stand-in turn end and waits until the desk says nothing runs.
    gate.store(true)
    let until = epochTime() + 10
    while chat.isRunning and epochTime() < until: sleep(2)
    check not chat.isRunning

  test "a turn and a step of one game started together are never both accepted":
    var turnWon, stepWon = 0
    for i in 1 .. 40:
      gate.store(false)
      var go: Atomic[bool]
      go.store(false)
      var a = Racer(chat: chat, go: addr go, asTurn: true)
      var b = Racer(chat: chat, go: addr go, asTurn: false)
      var ta, tb: Thread[ptr Racer]
      createThread(ta, racer, addr a)
      createThread(tb, racer, addr b)
      go.store(true)
      joinThread(ta)
      joinThread(tb)
      check a.ok != b.ok # exactly one of the two
      if a.ok: inc turnWon else: inc stepWon
      if b.ok: chat.endStep(chat.deskFacts("pong").stepId, 0)
      settle()
    check turnWon + stepWon == 40

  test "a turn and a step of different games run side by side, and a second step waits":
    check chat.startTurn("pong", "hello").ok
    let step = chat.startStep("dog", "check", "")
    check step.ok
    check not chat.startStep("cat", "check", "").ok # one step at a time, all games
    check chat.deskFacts("pong").running and chat.deskFacts("dog").stepRunning
    chat.endStep(step.turnId, 0)
    check chat.startStep("cat", "save", "a note").ok
    check chat.startStep("cat", "save", "").code == "needs-message" # a save needs a note, before anything else is asked
    settle()

  test "a second message to a running game is refused, another game's is not":
    check chat.startTurn("pong", "hello").ok
    let second = chat.startTurn("pong", "again")
    check not second.ok and second.status == 409 and second.code == "busy"
    check chat.startTurn("dog", "woof").ok
    check chat.runningGames == @["dog", "pong"]
    settle()
    check chat.startTurn("pong", "once more").ok # the next turn of the game gets its turn
    settle()
