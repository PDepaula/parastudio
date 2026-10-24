# A stand-in for the `claude` program, for the `para studio` chat tests. It is the test program
# itself, started again with PARA_FAKE_CLAUDE=1 (the same trick test_para_studio_api.nim uses for
# `para`), so it is a Nim binary that nimble builds and runs on every platform and needs no shell.
# Not a test file itself (no `test_` prefix).
#
# A test sets PARA_FAKE_CLAUDE=1, FAKE_CLAUDE_MODE and, for modes that replay a real recorded run,
# FAKE_CLAUDE_FIXTURE (a file in tests/fixtures/claude-stream/), then points the adapter at
# getAppFilename(). The environment passes through the adapter to this program unchanged, which is
# how the tests also see what the adapter put in it. Every run appends one JSON line to
# FAKE_CLAUDE_LOG: the arguments, what arrived on standard input, PARALOOP_UI and the working
# directory.
#
# Modes:
#   normal          replay the fixture, exit 0
#   crash           print the first two lines of the fixture, then exit 3 with a note on stderr
#   badlines        mix junk, an unknown event type and a half line in with the fixture, exit 0
#   resume-missing  with --resume: say there is no such conversation and exit 1; else as normal
#   untrusted       print claude's "workspace not trusted" warning first, then as normal
#   secret          print the value of ANTHROPIC_API_KEY on a stray line, inside a result error
#                   and on stderr, exit 1
#   hang            print an init line, start a grandchild (pid in FAKE_CLAUDE_PIDFILE), then wait
#   sleep           wait FAKE_CLAUDE_SLEEP_MS (default two minutes), then exit 0: the grandchild of
#                   `hang`, or a stand-in for a long `para check`
#   garbage         print text that is not stream-json at all, exit 0
#   noversion       `--version` prints something that is not a version

import std/[os, json, osproc, strtabs, strutils]

const sessionId* = "11111111-2222-4333-8444-555555555555"

proc emit(line: string) =
  stdout.write(line & "\n")
  stdout.flushFile()

proc replay(path: string) =
  for line in lines(path):
    emit line

proc fakeClaudeMain*() =
  let args = commandLineParams()
  let mode = getEnv("FAKE_CLAUDE_MODE", "normal")
  if args == @["--version"]:
    emit(if mode == "noversion": "who knows" else: "2.1.296 (Claude Code)")
    quit 0
  if mode == "sleep":
    sleep(parseInt(getEnv("FAKE_CLAUDE_SLEEP_MS", "120000")))
    quit 0
  let input = stdin.readAll()
  let logPath = getEnv("FAKE_CLAUDE_LOG")
  if logPath.len > 0:
    let f = open(logPath, fmAppend)
    f.writeLine($(%*{"args": args, "stdin": input, "ui": getEnv("PARALOOP_UI"), "cwd": getCurrentDir()}))
    f.close()
  let fixture = getEnv("FAKE_CLAUDE_FIXTURE")
  case mode
  of "normal", "noversion":
    replay fixture
  of "crash":
    var n = 0
    for line in lines(fixture):
      if n >= 2: break
      emit line
      inc n
    stderr.write "claude: something broke\n"
    quit 3
  of "badlines":
    emit "this is not json"
    emit "{\"type\":\"mystery\",\"x\":1}"
    emit "[1,2,3]"
    emit "{\"type\":\"assistant\",\"message\":{\"content\":\"oops\"}}"
    emit "{\"type\":\"assist"
    replay fixture
  of "resume-missing":
    if "--resume" in args:
      emit "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"errors\":[\"No conversation found with session ID: " & args[args.find("--resume") + 1] & "\"]}"
      quit 1
    replay fixture
  of "untrusted":
    stderr.write "Ignoring 2 permissions.allow entries from .claude/settings.json: this workspace has not been trusted. Run Claude Code interactively here once and accept the trust dialog.\n"
    replay fixture
  of "secret":
    let key = getEnv("ANTHROPIC_API_KEY")
    emit "debug: using key " & key
    emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"request failed for key " & key & " (Bearer " & key & ")\"}"
    stderr.write "key was " & key & "\n"
    quit 1
  of "hang":
    emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"" & sessionId & "\"}"
    var env = newStringTable(modeCaseSensitive)
    for (k, v) in envPairs(): env[k] = v
    env["FAKE_CLAUDE_MODE"] = "sleep"
    let child = startProcess(getAppFilename(), args = @[], env = env)
    let pidFile = getEnv("FAKE_CLAUDE_PIDFILE")
    if pidFile.len > 0:
      writeFile(pidFile & ".tmp", $child.processID & " " & $getCurrentProcessId())
      moveFile(pidFile & ".tmp", pidFile)
    sleep(120_000)
  of "sleep": discard # handled above, before reading stdin
  of "garbage":
    emit "Welcome to a different program"
    emit "nothing here is JSON"
  else:
    stderr.write "fake claude: unknown mode " & mode & "\n"
    quit 9
  quit 0
