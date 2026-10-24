# Tests for `para studio`'s Play panel: building and opening the game window as a program the
# studio owns (tools/para/studioplay.nim), screenshots in the chat (tools/para/studioshot.nim) and
# the routes in front of them (tools/para/studioapi.nim), against the real handler on a loopback
# port.
#
# No compiler and no window: the "build" and the "game" are this test program started again with
# `--fake-build MODE` / `--fake-game MODE` (a stand-in the planner hands the studio, the same trick
# test_para_studio_api.nim plays for `para check`). The fake game does what a real one does over the
# dev control channel: it listens at `tmp/dev.sock` in its working directory (a unix socket, or on
# Windows a loopback port written to that file, through paraloop/devsock), answers `ping`, and
# answers `shot` with the path of a file it writes a moment AFTER replying, as paraloop/dev does. Its
# other modes are the ways a real window fails (no display, no OpenGL, a crash, closing itself) and
# the ways a game could misname a picture. A real native window through the studio was tried by hand;
# see the PR.

import std/[unittest, os, osproc, strutils, json, net, nativesockets, times, sequtils, algorithm, tables]
when not defined(windows):
  from std/posix import kill, Pid
import paraloop/devsock

const pngBytes = "\x89PNG\r\n\x1a\nfake-picture-bytes"

proc say(line: string) =
  echo line
  flushFile(stdout)

proc runFakeBuild(mode: string) =
  createDir("tmp")
  writeFile("tmp" / "fake-build.pid", $getCurrentProcessId())
  case mode
  of "fail":
    say "Hint: used config file 'config.nims'"
    say "games/pong/pong.nim(3, 5) Error: undeclared identifier: 'foo'"
    quit 1
  of "no-compiler":
    say "Error: execution of an external program failed: 'gcc -c pong.c'"
    say "sh: gcc: command not found"
    quit 1
  of "slow":
    say "CC: games/pong/pong.nim"
    sleep 60_000
    quit 0
  else:
    say "Hint: build ok"
    quit 0

proc runFakeGame(mode: string) =
  createDir("tmp")
  writeFile("tmp" / "fake-game.pid", $getCurrentProcessId())
  case mode
  of "display":
    say "X11: The DISPLAY environment variable is missing"
    quit 1
  of "gl":
    say "GLFW error 65542: WGL: The driver does not appear to support OpenGL"
    quit 1
  of "crash":
    say "something went wrong inside the game"
    quit 3
  else: discard
  say "fake game: the window is open"
  var server: Socket
  if mode != "no-channel":
    try: removeFile("tmp" / "dev.sock")
    except OSError: discard
    server = listenDev("tmp" / "dev.sock")
    server.getFd().setBlocking(false)
  let started = epochTime()
  var shots = 0
  while true:
    if mode == "quit-soon" and epochTime() - started > 1.5: quit 0
    if mode == "crash-later" and epochTime() - started > 1.5: quit 5
    if server != nil:
      var client: Socket
      var address: string
      try: server.acceptAddr(client, address)
      except OSError: client = nil
      if client != nil:
        client.getFd().setBlocking(true)
        var line = ""
        try: line = client.recvLine(timeout = 200)
        except TimeoutError, OSError: discard
        var reply = "error unknown request"
        var pendingPath, pendingBody = ""
        case line.strip
        of "ping": reply = "ok pong"
        of "shot":
          inc shots
          case mode
          of "shot-error": reply = "error no frame yet"
          of "shot-outside": reply = "ok games/pong/leak.png"
          of "shot-climb": reply = "ok tmp/../games/pong/leak.png"
          of "shot-text": reply = "ok tmp/frames/name.txt"
          of "shot-never": reply = "ok tmp/frames/never.png"
          of "shot-notpng":
            pendingPath = "tmp/frames/notpng.png"
            pendingBody = "this is not a picture"
            reply = "ok " & pendingPath
          else:
            pendingPath = "tmp/frames/fake_" & $shots & ".png"
            pendingBody = pngBytes
            reply = "ok " & pendingPath
        try: client.send(reply & "\n")
        except OSError: discard
        client.close()
        if pendingPath.len > 0: # after the reply, as the real game does; and only ever complete
          createDir(pendingPath.parentDir)
          writeFile(pendingPath & ".part", pendingBody)
          moveFile(pendingPath & ".part", pendingPath)
    sleep 10

when isMainModule:
  let argv = commandLineParams()
  if argv.len >= 1 and argv[0] == "--fake-build": runFakeBuild(if argv.len > 1: argv[1] else: "ok")
  elif argv.len >= 1 and argv[0] == "--fake-game": runFakeGame(if argv.len > 1: argv[1] else: "ok")
  elif argv.len >= 1 and argv[0] == "check":
    sleep 1500 # a Check step that takes a moment
    quit 0

import studio_support
import tools/para/studiohttp
import tools/para/studioapi
import tools/para/studioplay
import tools/para/studioshot
import tools/para/agent

proc fakePlan(root, game: string): PlayLaunch {.nimcall, gcsafe.} =
  PlayLaunch(buildExe: getAppFilename(), buildArgs: @["--fake-build", getEnv("FAKE_BUILD", "ok")],
             gameExe: getAppFilename(), gameArgs: @["--fake-game", getEnv("FAKE_GAME", "ok")])

proc jsonOf(r: Reply): JsonNode = parseJson(r.body)

proc post(r: Running, path: string, body: JsonNode = %*{}): Reply =
  r.request("POST", path, body = $body)

proc playState(r: Running): JsonNode =
  let reply = r.request("GET", "/api/play")
  doAssert reply.status == 200, reply.raw
  jsonOf(reply)

proc waitState(r: Running, wanted: openArray[string], seconds = 30): JsonNode =
  let until = epochTime() + seconds.float
  while epochTime() < until:
    result = playState(r)
    if result["state"].getStr in wanted: return
    sleep 50
  doAssert false, "the game window never reached " & $wanted & "; last answer: " & $result

proc startAndWait(r: Running) =
  doAssert r.post("/api/play/start", %*{"game": "pong"}).status == 200
  discard r.waitState(["running"])

proc pidOf(root, file: string): int =
  try: parseInt(readFile(root / "tmp" / file).strip) except CatchableError: 0

proc pidAlive(pid: int): bool =
  when defined(windows): true # no cheap check here; the dev channel's silence is tested instead
  else: pid > 0 and kill(Pid(pid), 0) == 0

proc waitGone(pid: int, seconds = 10): bool =
  let until = epochTime() + seconds.float
  while epochTime() < until:
    if not pidAlive(pid): return true
    sleep 50
  false

var root: string
var running: Running
var spawned: seq[Process]

proc begin(games: varargs[string]) =
  delEnv("FAKE_BUILD")
  delEnv("FAKE_GAME")
  root = newGameRepo(if games.len > 0: @games else: @["pong"])
  running = startStudio(root, getAppFilename(), planner = fakePlan)

proc finish() =
  for p in spawned:
    terminateTree(p.processID, true)
    discard p.waitForExit(2000)
    p.close()
  spawned = @[]
  running.stop()
  removeDir(root)
  delEnv("FAKE_BUILD")
  delEnv("FAKE_GAME")

proc spawnFake(mode: string): Process =
  ## A fake game started by the test itself in the repository root, for the tests that call the
  ## screenshot code directly.
  result = startProcess(getAppFilename(), workingDir = root, args = @["--fake-game", mode],
                        options = {poStdErrToStdOut, poDaemon})
  spawned.add result
  let until = epochTime() + 20
  while epochTime() < until and not pingGame(root): sleep 50
  doAssert pingGame(root), "the fake game never answered"

# --- the words and the file names (no process, no socket) -------------------------------------

suite "play: plain words for what went wrong":
  test "the default plan builds with the dev channel into the studio's own folder":
    let plan = defaultPlan("/r", "mygame")
    check plan.buildExe == "nim"
    check "-d:dev" in plan.buildArgs
    check "--hint:CC:on" in plan.buildArgs # progress: one `CC: module` line at a time
    check "--hints:off" notin plan.buildArgs
    check plan.buildArgs[^1] == "games" / "mygame" / "mygame.nim"
    check plan.gameExe == playBinary("/r", "mygame")
    check plan.gameExe.startsWith("/r" / "tmp" / "studio" / "play")
    check plan.gameExe != "/r" / "tmp" / "mygame" # never the `para build` binary
    check "--out:" & plan.gameExe in plan.buildArgs
    check plan.gameArgs.len == 0

  test "a build that fails to start says Nim was not found":
    let why = classifyBuildFailure(@["cannot run nim: No such file or directory"], true)
    check why.code == "no-nim"
    check "nim --version" in why.message

  test "compiler errors are the detail, and the message says what to do":
    let why = classifyBuildFailure(@["Hint: x", "games/pong/pong.nim(3, 5) Error: undeclared identifier: 'foo'", "Hint: y"], false)
    check why.code == "build"
    check why.detail == "games/pong/pong.nim:3: undeclared identifier: 'foo'"
    check "Ask the producer" in why.message and "press Play again" in why.message

  test "a missing C compiler is told apart from a compile error":
    let why = classifyBuildFailure(@["Error: execution of an external program failed: 'gcc x.c'", "sh: gcc: command not found"], false)
    check why.code == "no-compiler"

  test "a window that ends before it answers: no display, no OpenGL, or a crash":
    check classifyGameExit(@["X11: The DISPLAY environment variable is missing"], 1, true).code == "no-display"
    check classifyGameExit(@["Failed to open display :0"], 1, true).code == "no-display"
    let gl = classifyGameExit(@["GLFW error 65542: WGL: The driver does not appear to support OpenGL"], 1, true)
    check gl.code == "no-graphics"
    check "graphics driver" in gl.message
    check classifyGameExit(@["Error: unhandled exception"], 3, true).code == "crashed"
    # the engine quits with -1 and no words when GLFW cannot make a window
    check classifyGameExit(@[], 255, true).code == "no-window"
    check classifyGameExit(@[], -1, true).code == "no-window"
    check classifyGameExit(@[], 255, true, noDisplayEnv = true).code == "no-display"
    check "graphics driver" in classifyGameExit(@[], 255, true).message
    # both window failures lead with the same plain sentence and say what to send the captain
    for why in [gl, classifyGameExit(@[], 255, true)]:
      check why.message.startsWith("Your computer could not open the game window. This is usually a graphics or display problem")
      check "send the captain this message" in why.message
    check classifyGameExit(@[], 255, false).code == "crashed-later"
    check classifyGameExit(@[], 0, true).code == "closed-early"

  test "a window that was open and closed is not an error; a crash later is":
    check classifyGameExit(@[], 0, false).code == "closed"
    let late = classifyGameExit(@["boom"], 5, false)
    check late.code == "crashed-later"
    check "code 5" in late.message

  test "a secret in the game's output never reaches the page":
    putEnv("PLAY_TEST_API_KEY", "sk-test-0123456789abcdef")
    defer: delEnv("PLAY_TEST_API_KEY")
    let why = classifyGameExit(@["key is sk-test-0123456789abcdef"], 2, true)
    check "sk-test" notin why.detail

suite "shots: names and paths":
  test "only the exact name the studio makes is valid":
    let made = newShotName()
    check validShotName(made)
    check made.len == 31
    check validShotName("shot-20261021-120000-000001.png")
    for bad in ["", "shot-1.png", "../shot-20261021-120000-000001.png", "shot-20261021-120000-000001.png/", "/shot-20261021-120000-000001.png",
                "shot-20261021-120000-000001.PNG", "shot-20261021-120000-000001.jpg", "shot-20261021-120000-000001.png.exe",
                "shot-20261021-120000-00001.png", "shot-20261021-120000-0000001.png", "shot-2026102a-120000-000001.png",
                "shot-20261021-120000-000001.png\0", "shot-20261021-120000-000001.pn%67", "shot-20261021-120000-000001%2epng",
                "shot\\20261021-120000-000001.png", "shot-20261021-120000-000001.png ", " shot-20261021-120000-000001.png",
                "x" & "shot-20261021-120000-000001.png", "secret.png", "..", "."]:
      check not validShotName(bad)

  test "names sort oldest first even within one second":
    var names: seq[string]
    for _ in 1 .. 12: names.add newShotName()
    check names == names.sorted
    check names.deduplicate.len == names.len

  test "the game may only name a .png inside the repository's tmp/ folder":
    let r = "/work/repo"
    check resolveFrame(r, "tmp/frames/a.png") == "/work/repo/tmp/frames/a.png".normalizedPath
    check resolveFrame(r, "tmp/frames/A.PNG") != ""
    check resolveFrame(r, "/work/repo/tmp/frames/a.png") != ""
    check resolveFrame(r, "games/pong/a.png") == ""
    check resolveFrame(r, "tmp/../games/pong/a.png") == ""
    check resolveFrame(r, "tmp/../../etc/passwd.png") == ""
    check resolveFrame(r, "/etc/passwd") == ""
    check resolveFrame(r, "/etc/hosts.png") == ""
    check resolveFrame(r, "/work/repo/tmp.png") == ""
    check resolveFrame(r, "/work/repo/tmpx/a.png") == ""
    check resolveFrame(r, "tmp/frames/a.txt") == ""
    check resolveFrame(r, "tmp") == ""
    check resolveFrame(r, "") == ""
    check resolveFrame(r, "tmp/frames/a\nb.png") == ""

suite "shots: the folder":
  setup: begin("pong")
  teardown: finish()

  test "past the cap the oldest pictures are deleted, the rest kept":
    createDir(shotsDir(root))
    for i in 1 .. maxShots + 5:
      writeFile(shotsDir(root) / ("shot-20261021-120000-" & align($i, 6, '0') & ".png"), pngBytes)
    writeFile(shotsDir(root) / "notes.txt", "not ours") # never touched
    pruneShots(root)
    let kept = shotNames(root)
    check kept.len == maxShots
    check kept[0] == "shot-20261021-120000-000006.png"
    check kept[^1] == "shot-20261021-120000-" & align($(maxShots + 5), 6, '0') & ".png"
    check fileExists(shotsDir(root) / "notes.txt")

  test "readShot returns only the studio's own files":
    createDir(shotsDir(root))
    let good = "shot-20261021-120000-000001.png"
    writeFile(shotsDir(root) / good, pngBytes)
    writeFile(shotsDir(root) / "secret.png", "nope")
    check readShot(root, good) == pngBytes
    check readShot(root, "secret.png") == ""
    check readShot(root, "../../paraloop.nimble") == ""
    check readShot(root, "shot-20261021-120000-000002.png") == "" # not there
    when not defined(windows):
      createSymlink(root / "paraloop.nimble", shotsDir(root) / "shot-20261021-120000-000003.png")
      check readShot(root, "shot-20261021-120000-000003.png") == "" # a link is not a picture

suite "shots: asking a window directly":
  setup: begin("pong")
  teardown: finish()

  test "no window open: a plain answer, nothing written":
    let shot = takeShot(root)
    check not shot.ok
    check shot.code == "no-window"
    check "Press Play" in shot.message
    check not dirExists(shotsDir(root))

  test "a picture is moved into the studio's folder under the studio's own name":
    discard spawnFake("ok")
    let shot = takeShot(root)
    check shot.ok
    check validShotName(shot.name)
    check readShot(root, shot.name) == pngBytes
    check not fileExists(root / "tmp" / "frames" / "fake_1.png") # moved, not copied
    check shotNames(root) == @[shot.name]

  test "a name outside tmp/ is refused and that file is left alone":
    discard spawnFake("shot-outside")
    writeFile(root / "games" / "pong" / "leak.png", pngBytes)
    let shot = takeShot(root, 400)
    check not shot.ok and shot.code == "odd-path"
    check fileExists(root / "games" / "pong" / "leak.png")
    check shotNames(root).len == 0

  test "a name that climbs out of tmp/ is refused too":
    discard spawnFake("shot-climb")
    writeFile(root / "games" / "pong" / "leak.png", pngBytes)
    let shot = takeShot(root, 400)
    check not shot.ok and shot.code == "odd-path"
    check fileExists(root / "games" / "pong" / "leak.png")

  test "a file that is not a picture is refused and not kept":
    discard spawnFake("shot-notpng")
    let shot = takeShot(root)
    check not shot.ok and shot.code == "odd-path"
    check shotNames(root).len == 0

  test "a name that is not a .png is refused":
    discard spawnFake("shot-text")
    let shot = takeShot(root, 400)
    check not shot.ok and shot.code == "odd-path"

  test "the game saying no, or never writing the file, gives a plain answer":
    discard spawnFake("shot-error")
    let refused = takeShot(root)
    check not refused.ok and refused.code == "refused"
    check "no frame yet" in refused.message
    for p in spawned:
      terminateTree(p.processID, true)
      discard p.waitForExit(2000)
    spawned = @[]
    discard spawnFake("shot-never")
    let never = takeShot(root, 300)
    check not never.ok and never.code == "no-picture"

  when not defined(windows):
    test "a link named by the game is refused":
      discard spawnFake("shot-never")
      createDir(root / "tmp" / "frames")
      # this fake names tmp/frames/never.png and never writes it, so nothing can replace the link
      createSymlink(root / "paraloop.nimble", root / "tmp" / "frames" / "never.png")
      let shot = takeShot(root)
      check not shot.ok and shot.code == "odd-path"
      check shotNames(root).len == 0

# --- the routes -------------------------------------------------------------------------------

suite "play: the page and the routes":
  setup: begin("pong")
  teardown: finish()

  test "the page has the Play panel and may show its own pictures, and still nothing outside":
    let r = running.request("GET", "/?token=" & running.srv.token, withToken = false)
    check r.status == 200
    for needle in ["id=\"play-btn\"", "Show me a screenshot", "Stop game", "id=\"stop-game-btn\""]:
      check needle in r.body
    let csp = r.headers["content-security-policy"]
    check "img-src data: blob:" in csp
    check "default-src 'none'" in csp and "connect-src 'self'" in csp
    check "https://" notin r.body

  test "before Play: idle, and a picture has nowhere to come from":
    let s = playState(running)
    check s["state"].getStr == "idle"
    check s["live"].getBool == false
    let shot = running.post("/api/play/shot", %*{"game": "pong"})
    check shot.status == 409
    check jsonOf(shot)["error"].getStr == "no-window"
    check "Press Play" in jsonOf(shot)["message"].getStr

  test "Play builds, opens the window, and reports it live; Stop ends it and everything it started":
    let started = running.post("/api/play/start", %*{"game": "pong"})
    check started.status == 200
    check jsonOf(started)["state"].getStr in ["building", "starting", "running"]
    let up = running.waitState(["running"])
    check up["live"].getBool
    check up["game"].getStr == "pong"
    check up["message"].getStr == "The game window is open."
    let pid = pidOf(root, "fake-game.pid")
    check pid > 0
    check pidAlive(pid)
    check pingGame(root)
    let stopped = running.post("/api/play/stop")
    check stopped.status == 200
    check jsonOf(stopped)["stopped"].getBool
    check running.playState["state"].getStr == "idle"
    check running.playState["message"].getStr == "The game was stopped."
    check waitGone(pid)
    check not pingGame(root)
    check not jsonOf(running.post("/api/play/stop"))["stopped"].getBool # nothing left to stop

  when tcpChannel:
    test "on the loopback route the channel path is a file holding the port":
      startAndWait(running)
      let port = parseInt(readFile(root / "tmp" / "dev.sock").strip)
      check port in 1 .. 65535
      check pingGame(root)

  test "a second Play restarts: a new window, the old one gone":
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    let first = running.waitState(["running"])
    let pid1 = pidOf(root, "fake-game.pid")
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    let second = running.waitState(["running"])
    check second["run"].getInt == first["run"].getInt + 1
    let pid2 = pidOf(root, "fake-game.pid")
    check pid2 > 0 and pid2 != pid1
    check waitGone(pid1)
    check pidAlive(pid2)
    check pingGame(root)

  test "a build that fails shows the compiler's words and what to do, and opens no window":
    putEnv("FAKE_BUILD", "fail")
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    let s = running.waitState(["failed"])
    check s["code"].getStr == "build"
    check "Ask the producer" in s["message"].getStr
    check "undeclared identifier: 'foo'" in s["detail"].getStr
    check pidOf(root, "fake-game.pid") == 0 # the game never started
    check not pingGame(root)

  test "a missing C compiler is named":
    putEnv("FAKE_BUILD", "no-compiler")
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    check running.waitState(["failed"])["code"].getStr == "no-compiler"

  test "no display, no OpenGL and a crash each get their own plain sentence":
    for (mode, code, words) in [("display", "no-display", "no screen"), ("gl", "no-graphics", "graphics driver"),
                                ("crash", "crashed", "code 3")]:
      putEnv("FAKE_GAME", mode)
      check running.post("/api/play/start", %*{"game": "pong"}).status == 200
      let s = running.waitState(["failed"])
      check s["code"].getStr == code
      check words in s["message"].getStr
      check s["detail"].getStr.len > 0

  test "a window the friend closes is not an error":
    putEnv("FAKE_GAME", "quit-soon")
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    discard running.waitState(["running"])
    let s = running.waitState(["exited"])
    check s["code"].getStr == "closed"
    check s["message"].getStr == "The game window was closed."

  test "a window that crashes after it was open says so":
    putEnv("FAKE_GAME", "crash-later")
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    discard running.waitState(["running"])
    let s = running.waitState(["exited"])
    check s["code"].getStr == "crashed-later"
    check "code 5" in s["message"].getStr

  test "stopping during the build ends the compiler and opens nothing":
    putEnv("FAKE_BUILD", "slow")
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    let s = running.waitState(["building"])
    check s["message"].getStr.startsWith("Building the game")
    # wait for the compiler to be there and say something
    let until = epochTime() + 15
    var progress = ""
    while epochTime() < until and progress.len == 0:
      progress = playState(running)["progress"].getStr
      sleep 50
    check progress == "CC: games/pong/pong.nim"
    let pid = pidOf(root, "fake-build.pid")
    check pid > 0 and pidAlive(pid)
    let t0 = epochTime()
    check jsonOf(running.post("/api/play/stop"))["stopped"].getBool
    check epochTime() - t0 < 10
    check running.playState["state"].getStr == "idle"
    check waitGone(pid)
    check pidOf(root, "fake-game.pid") == 0

  test "a window with no dev channel is starting, then open but not answering, and has no picture to give":
    putEnv("FAKE_GAME", "no-channel")
    let was = startWaitSeconds
    startWaitSeconds = 1.0
    defer: startWaitSeconds = was
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    check running.waitState(["starting", "running"])["live"].getBool == false
    let s = running.waitState(["running"])
    check s["live"].getBool == false
    check s["code"].getStr == "not-answering"
    check "not answering" in s["message"].getStr
    let shot = running.post("/api/play/shot", %*{"game": "pong"})
    check shot.status == 409
    check jsonOf(shot)["error"].getStr == "no-window"

  test "closing the studio closes the game window":
    check running.post("/api/play/start", %*{"game": "pong"}).status == 200
    discard running.waitState(["running"])
    let pid = pidOf(root, "fake-game.pid")
    running.stop()
    check waitGone(pid)
    check not pingGame(root)
    # finish() stops the studio again: make that a fresh, harmless one
    running = startStudio(root, getAppFilename(), planner = fakePlan)

  test "Play is refused while a Check is running, and a game with no code yet is a plain 404":
    let check1 = running.post("/api/check", %*{"game": "pong"})
    check check1.status == 200
    let busy = running.post("/api/play/start", %*{"game": "pong"})
    check busy.status == 409
    check jsonOf(busy)["error"].getStr == "busy"
    check "Check" in jsonOf(busy)["message"].getStr
    let jobId = jsonOf(check1)["job"]["id"].getInt
    let until = epochTime() + 20
    while epochTime() < until and jsonOf(running.request("GET", "/api/job?id=" & $jobId & "&since=0"))["running"].getBool:
      sleep 50
    removeFile(root / "games" / "pong" / "pong.nim")
    let none = running.post("/api/play/start", %*{"game": "pong"})
    check none.status == 404
    check jsonOf(none)["error"].getStr == "no-source"
    let nogame = running.post("/api/play/start", %*{"game": "nothere"})
    check nogame.status == 404

suite "play: screenshots through the studio":
  setup: begin("pong", "tank")
  teardown: finish()

  test "the button's route takes a picture, shows it as a card in the chat, and serves it as image/png":
    startAndWait(running)
    let shot = running.post("/api/play/shot", %*{"game": "pong"})
    check shot.status == 200
    let name = jsonOf(shot)["name"].getStr
    check validShotName(name)
    let chat = jsonOf(running.request("GET", "/api/chat?game=pong&since=0"))
    let cards = chat["events"].getElems.filterIt(it["kind"].getStr == "shot")
    check cards.len == 1
    check cards[0]["name"].getStr == name
    let img = running.request("GET", "/api/shot?name=" & name)
    check img.status == 200
    check img.headers["content-type"] == "image/png"
    check img.headers["x-content-type-options"] == "nosniff"
    check img.headers["cache-control"] == "no-store"
    check img.body == pngBytes
    check img.raw.contains("Cross-Origin-Resource-Policy: same-origin")

  test "the card belongs to the game's own chat":
    startAndWait(running)
    check running.post("/api/play/shot", %*{"game": "pong"}).status == 200
    let other = jsonOf(running.request("GET", "/api/chat?game=tank&since=0"))
    check other["events"].getElems.filterIt(it["kind"].getStr == "shot").len == 0
    let own = jsonOf(running.request("GET", "/api/chat?game=pong&since=0"))
    check own["events"].getElems.filterIt(it["kind"].getStr == "shot").len == 1

  test "a picture asked for as another game is refused, kept nowhere and put in no chat":
    startAndWait(running)
    let shot = running.post("/api/play/shot", %*{"game": "tank"})
    check shot.status == 409
    check jsonOf(shot)["error"].getStr == "other-game"
    check "pong" in jsonOf(shot)["message"].getStr and "tank" in jsonOf(shot)["message"].getStr
    check shotNames(root).len == 0
    for game in ["pong", "tank"]:
      let chat = jsonOf(running.request("GET", "/api/chat?game=" & game & "&since=0"))
      check chat["events"].getElems.filterIt(it["kind"].getStr == "shot").len == 0
    check running.post("/api/play/shot", %*{"game": "pong"}).status == 200

  test "only the studio's own pictures are served: odd names, traversal and other files are refused":
    startAndWait(running)
    let name = jsonOf(running.post("/api/play/shot", %*{"game": "pong"}))["name"].getStr
    writeFile(shotsDir(root) / "secret.png", "not for the page")
    writeFile(root / "secret.txt", "not for the page")
    for bad in ["../../paraloop.nimble", "..%2F..%2Fparaloop.nimble", "secret.png", "../secret.txt", "", "shot-1.png",
                name & "x", name.toUpperAscii, "%2e%2e%2fsecret.txt", "tmp/studio/shots/" & name, name.replace(".png", ".PNG"),
                "shot-20261021-120000-999999.png"]:
      let r = running.request("GET", "/api/shot?name=" & bad)
      check r.status == 404
      check "not for the page" notin r.raw
    # a name in the path is a different, unknown route
    check running.request("GET", "/api/shot/" & name).status == 404
    check running.request("GET", "/api/shot/../" & name).status == 404
    check running.request("GET", "/shots/" & name).status == 404
    check running.request("GET", "/tmp/studio/shots/" & name).status == 404
    # and no name at all
    check running.request("GET", "/api/shot").status == 404
    # the real one still works
    check running.request("GET", "/api/shot?name=" & name).status == 200

  test "every B1 check still applies: token, Host and Origin, content type":
    startAndWait(running)
    let name = jsonOf(running.post("/api/play/shot", %*{"game": "pong"}))["name"].getStr
    let path = "/api/shot?name=" & name
    check running.request("GET", path, withToken = false).status == 403
    check running.request("GET", path, headers = @[("X-Studio-Token", "wrong")]).status == 403
    check running.request("GET", path, host = "evil.example:" & $running.srv.port).status == 403
    check running.request("GET", path, host = "127.0.0.1:1").status == 403
    check running.request("GET", path & "&token=" & running.srv.token, withToken = false).status == 403 # a query key only opens the page
    for route in ["/api/play/shot", "/api/play/start", "/api/play/stop"]:
      check running.request("POST", route, body = "{\"game\":\"pong\"}", withToken = false).status == 403
      check running.request("POST", route, body = "{\"game\":\"pong\"}", headers = @[("Origin", "http://evil.example")]).status == 403
      check running.request("POST", route, body = "{\"game\":\"pong\"}", headers = @[("Sec-Fetch-Site", "cross-site")]).status == 403
      check running.request("POST", route, body = "game=pong", jsonBody = false,
                            headers = @[("Content-Type", "application/x-www-form-urlencoded")]).status == 415
    check running.request("GET", "/api/play", withToken = false).status == 403
    check running.request("GET", "/api/play", host = "evil.example").status == 403
    # nothing but the one picture was taken by all that
    check shotNames(root).len == 1

  test "a body that is too large is refused before anything runs":
    let big = "{\"game\":\"pong\",\"pad\":\"" & 'x'.repeat(40_000) & "\"}"
    check running.request("POST", "/api/play/start", body = big).status == 413
    check playState(running)["state"].getStr == "idle"

  test "only so many pictures are kept; the oldest go":
    startAndWait(running)
    var names: seq[string]
    for _ in 1 .. maxShots + 3:
      let shot = running.post("/api/play/shot", %*{"game": "pong"})
      check shot.status == 200
      names.add jsonOf(shot)["name"].getStr
    let kept = shotNames(root)
    check kept.len == maxShots
    check kept == names[3 .. ^1]
    check running.request("GET", "/api/shot?name=" & names[0]).status == 404
    check running.request("GET", "/api/shot?name=" & names[^1]).status == 200
    # tmp/frames holds nothing left over
    check toSeq(walkFiles(root / "tmp" / "frames" / "*")).len == 0

  test "a game that names a file outside tmp/ gets a refusal and nothing is served":
    putEnv("FAKE_GAME", "shot-outside")
    startAndWait(running)
    writeFile(root / "games" / "pong" / "leak.png", pngBytes)
    let shot = running.post("/api/play/shot", %*{"game": "pong"})
    check shot.status == 500
    check jsonOf(shot)["error"].getStr == "odd-path"
    check fileExists(root / "games" / "pong" / "leak.png")
    check shotNames(root).len == 0

  test "the game must be one with a plan":
    startAndWait(running)
    check running.post("/api/play/shot", %*{"game": "nothere"}).status == 404
    check running.post("/api/play/shot", %*{"game": "../pong"}).status == 404
    check shotNames(root).len == 0
