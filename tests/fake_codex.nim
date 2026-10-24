# A stand-in for the `codex` program, for the `para studio` Codex tests. It is the test program
# itself, started again with PARA_FAKE_CODEX=1 (the same trick fake_claude.nim uses), so it is a Nim
# binary that nimble builds and runs on every platform and needs no shell. Not a test file itself
# (no `test_` prefix).
#
# It plays the app-server's side of the conversation: it answers `initialize`, `thread/start`,
# `thread/resume` and `turn/start` with the recorded answers in tests/fixtures/codex-appserver/
# (handshake.jsonl: three responses, the thread id rewritten to the one asked for on a resume) and
# then replays the notifications of a fixture. Every message that arrives on standard input is
# appended to FAKE_CODEX_LOG as one JSON line (with the arguments, PARALOOP_UI and the working
# directory on the first), so a test sees exactly what the adapter sent.
#
# A test sets PARA_FAKE_CODEX=1, FAKE_CODEX_MODE and FAKE_CODEX_FIXTURE (the notifications to replay
# after `turn/start`: a file name in tests/fixtures/codex-appserver/), then points the adapter at
# getAppFilename().
#
# Modes:
#   normal          replay the fixture, then wait for standard input to close and exit 0
#   interrupt       replay the fixture, then wait for `turn/interrupt`, answer it and replay
#                   interrupt_post.jsonl (what the real app-server sent back)
#   deaf            replay the fixture, start a grandchild (pid in FAKE_CODEX_PIDFILE) and answer
#                   nothing after: only killing the tree ends it
#   resume-missing  `thread/resume` is answered with an error; everything else as normal
#   crash           exit 3 with a note on stderr right after `initialize`
#   garbage         print text that is not JSON at all, exit 0
#   secret          the turn fails with a message holding the value of OPENAI_API_KEY
#   approval        after `turn/start`, ask for an approval and a login-token refresh, wait for both
#                   answers, then replay the fixture
#   sleep           wait FAKE_CODEX_SLEEP_MS (default two minutes), then exit 0: the grandchild of `deaf`
#   noversion       `--version` prints something that is not a version
#
# FAKE_CODEX_HOME is the `codexHome` the stand-in reports (default /home/friend/.codex); the line
# `__SAVED__` in a fixture is replaced by FAKE_CODEX_SAVED.

import std/[os, json, osproc, strtabs, strutils]

const threadFixtureDir = currentSourcePath.parentDir / "fixtures" / "codex-appserver"

proc emit(line: string) =
  stdout.write(line & "\n")
  stdout.flushFile()

proc replay(name: string) =
  for line in lines(threadFixtureDir / name):
    if line.strip.len > 0:
      emit line.replace("__SAVED__", escapeJsonUnquoted(getEnv("FAKE_CODEX_SAVED")))

proc handshake(): seq[JsonNode] =
  for line in lines(threadFixtureDir / "handshake.jsonl"):
    if line.strip.len > 0: result.add parseJson(line)

proc answer(base: JsonNode, id: JsonNode): string =
  var r = base.copy
  r["id"] = id
  $r

proc fakeCodexMain*() =
  let args = commandLineParams()
  let mode = getEnv("FAKE_CODEX_MODE", "normal")
  if args == @["--version"]:
    emit(if mode == "noversion": "who knows" else: "codex-cli 0.159.2")
    quit 0
  if mode == "sleep":
    sleep(parseInt(getEnv("FAKE_CODEX_SLEEP_MS", "120000")))
    quit 0
  let logPath = getEnv("FAKE_CODEX_LOG")
  proc record(node: JsonNode) =
    if logPath.len == 0: return
    let f = open(logPath, fmAppend)
    f.writeLine($node)
    f.close()
  record(%*{"args": args, "ui": getEnv("PARALOOP_UI"), "cwd": getCurrentDir()})
  let hs = handshake()
  let fixture = getEnv("FAKE_CODEX_FIXTURE", "turn_ok.jsonl")
  var line: string
  var waitingApprovals = 0
  var pendingTurn = false
  while stdin.readLine(line):
    if line.strip.len == 0: continue
    var msg: JsonNode
    try: msg = parseJson(line)
    except CatchableError: continue
    record(msg)
    let meth = msg{"method"}.getStr
    let id = msg{"id"}
    if meth.len == 0:
      # an answer to something we asked (the approval and the token refresh)
      if pendingTurn and id != nil:
        dec waitingApprovals
        if waitingApprovals == 0:
          pendingTurn = false
          replay fixture
      continue
    case meth
    of "initialize":
      if mode == "crash":
        stderr.write "codex: something broke\n"
        quit 3
      if mode == "garbage":
        emit "Welcome to a different program"
        emit "nothing here is JSON"
        quit 0
      var r = hs[0]
      r["result"]["codexHome"] = %getEnv("FAKE_CODEX_HOME", "/home/friend/.codex")
      emit answer(r, id)
    of "thread/start":
      emit answer(hs[1], id)
    of "thread/resume":
      if mode == "resume-missing":
        emit $(%*{"id": id, "error": {"code": -32600, "message": "no rollout found for thread id " & msg{"params"}{"threadId"}.getStr}})
      else:
        var r = hs[1]
        r["result"]["thread"]["id"] = msg{"params"}{"threadId"}
        emit answer(r, id)
    of "turn/start":
      emit answer(hs[2], id)
      case mode
      of "secret":
        let key = getEnv("OPENAI_API_KEY")
        emit $(%*{"method": "turn/completed", "params": {"threadId": hs[1]["result"]["thread"]["id"], "turn": {
          "id": hs[2]["result"]["turn"]["id"], "items": [], "status": "failed", "error": {
            "message": "request failed for key " & key & " (Bearer " & key & ")", "codexErrorInfo": "other"}}}})
        stderr.write "key was " & key & "\n"
      of "approval":
        emit $(%*{"id": 77, "method": "item/commandExecution/requestApproval", "params": {
          "threadId": "x", "turnId": "y", "itemId": "z", "command": "/usr/bin/bash -lc 'rm -rf /'"}})
        emit $(%*{"id": 78, "method": "account/chatgptAuthTokens/refresh", "params": {"reason": "unauthorized"}})
        waitingApprovals = 2
        pendingTurn = true
      of "deaf":
        replay fixture
        var env = newStringTable(modeCaseSensitive)
        for (k, v) in envPairs(): env[k] = v
        env["FAKE_CODEX_MODE"] = "sleep"
        let child = startProcess(getAppFilename(), args = @[], env = env)
        let pidFile = getEnv("FAKE_CODEX_PIDFILE")
        if pidFile.len > 0:
          writeFile(pidFile & ".tmp", $child.processID & " " & $getCurrentProcessId())
          moveFile(pidFile & ".tmp", pidFile)
        # and carry on reading (the log shows what was asked of it) without ever answering
      else:
        replay fixture
    of "turn/interrupt":
      if mode == "interrupt":
        emit $(%*{"id": id, "result": {}})
        replay "interrupt_post.jsonl"
    else: discard
  quit 0
