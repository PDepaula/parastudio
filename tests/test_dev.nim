# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Tests for paraloop/dev (task 1.6): fact dump, bug capture/replay, F9 and
# F3 through the app loop's dev hook on `hello`, the unix-socket control
# channel, the web command dispatch it shares with the native channel, and
# (where a display is available, same guard as test_app.nim /
# test_render2d.nim) in-process capture, F9's frame, the F3 overlay and an
# end-to-end `shot` request against the running `hello` example -- this
# file's proof of task 1.6's acceptance target. Compiled with `-d:dev` via
# test_dev.nims, since `paraloop/dev` is meant to be used only behind that
# define.

import std/[unittest, os, net, intsets, sets, strutils, random, tables, sequtils, json, times]
import pararules
from pararules/engine import nil
import paraloop/sim
import paraloop/input
import paraloop/app
import paraloop/dev
import paraloop/devsock
import examples/hello/hello as hello

static: doAssert declared(engine.paraloopEnginePatched),
  "patches/pararules/engine.nim is not applied; check patchFile in config.nims"

const tmpDir = currentSourcePath().parentDir.parentDir / "tmp"

# ---------------------------------------------------------------- a tiny schema
# Mirrors test_sim.nim's mix of attribute types (a plain int, a `ref seq` and
# an `IntSet`) so the bug-capture round trip below exercises the same
# marshal-friendly shapes report §8's risk table calls out.

type
  Tags = ref seq[int]
  Id = enum
    Global
  Attr = enum
    Tick, Count, Name, Members, TagList

schema Fact(Id, Attr):
  Tick: int
  Count: int
  Name: string
  Members: IntSet
  TagList: Tags

let (initSession, rulesInternal) =
  staticRuleset(Fact, FactMatch):
    rule getTick(Fact):
      what:
        (Global, Tick, tick)
    rule getCount(Fact):
      what:
        (id, Count, count)

proc newTestSession(): Session[Fact, FactMatch] =
  result = initSession(autoFire = false)
  for r in rulesInternal.fields: result.add(r)
  var tags: Tags
  new(tags)
  tags[] = @[1, 2, 3]
  result.insert(Global, Tick, 0)
  result.insert(Global, Count, 0)
  result.insert(Global, Name, "start")
  result.insert(Global, Members, initIntSet())
  result.insert(Global, TagList, tags)

proc stepSim(s: var Sim[Fact, FactMatch]) =
  inc s.tick
  let roll = s.rng.rand(100)
  var members = initIntSet()
  members.incl(roll mod 37)
  s.session.insert(Global, Tick, s.tick)
  s.session.insert(Global, Count, s.tick + roll)
  s.session.insert(Global, Members, members)

proc parseToonRow(row: string): seq[string] =
  ## One TOON table row's comma-separated fields, each bare or a
  ## double-quoted JSON-style string.
  var i = 0
  while i <= row.len:
    if i < row.len and row[i] == '"':
      var j = i + 1
      while row[j] != '"':
        j += (if row[j] == '\\': 2 else: 1)
      result.add parseJson(row[i .. j]).getStr
      i = j + 1
    else:
      var j = i
      while j < row.len and row[j] != ',':
        inc j
      result.add row[i ..< j]
      i = j
    doAssert i == row.len or row[i] == ','
    inc i

suite "dev: TOON fact dump":
  test "one row per fact, each parsing back to enum names and the plain value":
    var sim = initSim(newTestSession(), seed = 1'i64, idType = Id)
    var members = initIntSet()
    members.incl 1
    members.incl 2
    sim.session.insert(Global, Name, "a, \"b\"\nc")
    sim.session.insert(Global, Members, members)
    let entity = sim.nextId()
    sim.session.insert(entity, Count, 7)

    let dump = toonFacts(sim, Id, Attr)
    let lines = dump.strip(leading = false, trailing = true).splitLines
    check lines[0] == "facts[6]{id,attr,value}:"
    check lines.len == 7
    var rows: seq[seq[string]]
    for line in lines[1 .. ^1]:
      check line.startsWith("  ")
      rows.add parseToonRow(line[2 .. ^1])
    check rows == @[
      @["Global", "Tick", "0"],
      @["Global", "Count", "0"],
      @["Global", "Name", "a, \"b\"\nc"],
      @["Global", "Members", "{1, 2}"],
      @["Global", "TagList", "@[1, 2, 3]"],
      @["1", "Count", "7"]]

proc readReplayMeta(dir: string): Table[string, string] =
  ## `replay.txt`'s `key: value` lines.
  for line in readFile(dir / "replay.txt").splitLines:
    if line.len > 0:
      let kv = line.split(": ", 1)
      result[kv[0]] = kv[1]

suite "dev: bug capture / replay":
  test "writeBugCapture + readBugSnapshot round-trips a marshaled snapshot":
    var sim = initSim(newTestSession(), seed = 42'i64, idType = Id)
    for i in 1 .. 50:
      sim.stepSim()
    let beforeHash = sim.stateHash()

    let dir = tmpDir / "test-bug-capture"
    removeDir(dir)
    let input = [
      newKeyState(),
      KeyState(pressed: [KeyA, 340].toHashSet, justPressed: [340, KeyF9].toHashSet),
      KeyState(pressed: [KeyF3].toHashSet, justPressed: [KeyD].toHashSet)]
    let written = writeBugCapture(sim.snapshot(), input, 50, beforeHash, dir = dir)
    check written == dir
    check readBugInput(dir) == @[
      newKeyState(),
      KeyState(pressed: [KeyA, 340].toHashSet, justPressed: [340].toHashSet),
      KeyState(pressed: initHashSet[int](), justPressed: [KeyD].toHashSet)]
    check readReplayMeta(dir) ==
      {"seed": "42", "from": "50", "ticks": "2", "hash": $beforeHash}.toTable

    let snap = readBugSnapshot(dir, Fact)
    var restored = restore(snap, newTestSession, Attr)
    check restored.stateHash() == beforeHash
    check restored.tick == sim.tick
    removeDir(dir)

  test "writeBugCapture without dir uses bugRoot/<stamp>":
    var sim = initSim(newTestSession(), seed = 7'i64, idType = Id)
    sim.stepSim()
    let dir = writeBugCapture(sim.snapshot(), [newKeyState()], 1, sim.stateHash())
    check dir.startsWith("tmp" / "bugs")
    check dirExists(dir)
    removeDir(dir)

proc replayBug[G, T, MatchT, A](game: var G, dir: string,
                                newSession: proc (): Session[T, MatchT], attrType: typedesc[A]) =
  ## Replays a bug directory onto `game` as its `replay.txt` says: restore
  ## `snapshot.json` and `input.txt`'s line 0, then set each later line's
  ## key state and `step` from `from`.
  let fromTick = readReplayMeta(dir)["from"].parseInt
  game.sim = restore(readBugSnapshot(dir, T), newSession, A)
  let input = readBugInput(dir)
  engineKeys = input[0]
  for i in 1 ..< input.len:
    engineKeys = input[i]
    game.step(fromTick + i)

proc replayHelloBug(dir: string): HelloGame =
  result = initHelloGame()
  result.replayBug(dir, newHelloSession, HelloAttr)

type KeyGame = object
  ## A game whose state depends on `wasPressed` and on a key with no
  ## `paraloop/input` script name: a press of space rolls the RNG, and a
  ## held left shift (GLFW key 340) allocates an id every tick.
  sim*: Sim[Fact, FactMatch]

proc step(game: var KeyGame, tick: int) =
  game.sim.stepSim()
  if engineKeys.wasPressed(KeySpace):
    discard game.sim.rng.rand(100)
  if engineKeys.isDown(340):
    discard game.sim.nextId()

proc runHello(script: string, lastTick: int): HelloGame =
  ## Drives `hello` through `app.stepTick` -- its step plus paraloop/dev's
  ## per-tick hook -- with `script` standing in for key events.
  engineKeys = newKeyState()
  result = initHelloGame()
  let replay = newReplay(parseScript(script))
  for tick in 1 .. lastTick:
    replay.step(engineKeys, tick)
    result.stepTick(tick)

suite "dev: F9 bug capture and F3 through the app loop":
  test "a scripted F9 on hello writes tmp/bugs/<stamp>/ that replays to the same stateHash":
    bugRoot = tmpDir / "test-f9-bugs"
    removeDir(bugRoot)
    defer:
      removeDir(bugRoot)
      bugRoot = "tmp" / "bugs"
    # Past inputHistoryTicks, so the capture replays from a rolling snapshot
    # well after the start; the moves inside the window make it non-trivial.
    const script = "100:right:40,1000:left:300,1700:up:50,1900:right:60,1985:down:6,1990:f9"
    let live = runHello(script, 1990)
    let liveHash = live.sim.stateHash()

    let dirs = toSeq(walkDirs(bugRoot / "*"))
    check dirs.len == 1
    let dir = dirs[0]
    for f in ["snapshot.json", "input.txt", "replay.txt"]:
      check fileExists(dir / f)
    check not fileExists(dir / "shot.png") # written by the next drawn frame

    let meta = readReplayMeta(dir)
    check meta["seed"] == $live.sim.seed
    check meta["hash"] == $liveHash
    let ticks = meta["ticks"].parseInt
    check ticks > inputHistoryTicks - snapshotEvery
    check ticks <= inputHistoryTicks
    let fromTick = meta["from"].parseInt
    check fromTick == 1990 - ticks

    let snap = readBugSnapshot(dir, HelloFact)
    check restore(snap, newHelloSession, HelloAttr).stateHash() != liveHash
    let input = readBugInput(dir)
    check input.len == ticks + 1
    check input.allIt(KeyF9 notin it.pressed + it.justPressed)

    let replayed = replayHelloBug(dir)
    check replayed.pos == live.pos
    check replayed.sim.stateHash() == liveHash

  test "keys tapped between two ticks replay as the game saw them, to the same stateHash":
    bugRoot = tmpDir / "test-f9-taps"
    removeDir(bugRoot)
    defer:
      removeDir(bugRoot)
      bugRoot = "tmp" / "bugs"
    # Live key events, as the window callback delivers them between ticks: a
    # press and release before the same tick is a tap `isDown` never sees.
    engineKeys = newKeyState()
    var live = initHelloGame()
    for tick in 1 .. 200:
      case tick
      of 50: keyDown(KeyRight)
      of 80: keyUp(KeyRight); keyDown(KeyRight); keyUp(KeyRight)
      of 120: keyDown(KeyLeft); keyUp(KeyLeft)
      of 150: keyDown(KeyDown)
      of 151: keyUp(KeyDown); keyDown(KeyUp); keyUp(KeyUp)
      of 200: keyDown(KeyF9); keyUp(KeyF9)
      else: discard
      live.stepTick(tick)
    check live.pos == (x: 30 * moveSpeed, y: moveSpeed)

    let dirs = toSeq(walkDirs(bugRoot / "*"))
    check dirs.len == 1
    let replayed = replayHelloBug(dirs[0])
    check replayed.pos == live.pos
    check replayed.sim.stateHash() == live.sim.stateHash()

  test "a key held across the snapshot and an unnamed key replay to the same stateHash":
    bugRoot = tmpDir / "test-f9-held"
    removeDir(bugRoot)
    defer:
      removeDir(bugRoot)
      bugRoot = "tmp" / "bugs"
    engineKeys = newKeyState()
    var live = KeyGame(sim: initSim(newTestSession(), seed = 3'i64, idType = Id))
    for tick in 1 .. 2000:
      case tick
      of 50: keyDown(KeySpace)
      of 1500: keyDown(340)
      of 1600: keyUp(340)
      of 1800: keyUp(KeySpace)
      of 1850: keyDown(KeySpace)
      of 1860: keyUp(KeySpace)
      of 2000: keyDown(KeyF9); keyUp(KeyF9)
      else: discard
      live.stepTick(tick)

    let dirs = toSeq(walkDirs(bugRoot / "*"))
    check dirs.len == 1
    check readReplayMeta(dirs[0])["from"].parseInt > 50 # space is held across the snapshot
    var replayed = KeyGame()
    replayed.replayBug(dirs[0], newTestSession, Attr)
    check replayed.sim.stateHash() == live.sim.stateHash()

  test "an F9 whose bug directory cannot be written is logged, not raised":
    let blocker = tmpDir / "test-f9-blocker"
    writeFile(blocker, "")
    bugRoot = blocker / "bugs" # its parent is a regular file
    defer:
      removeFile(blocker)
      bugRoot = "tmp" / "bugs"
    let game = runHello("3:f9,5:right", 6)
    check game.pos == (x: moveSpeed, y: 0)
    check not dirExists(bugRoot)

  test "a scripted F3 toggles the overlay":
    check not statsShown()
    discard runHello("2:f3", 2)
    check statsShown()
    discard runHello("2:f3", 2)
    check not statsShown()

proc pathExists(path: string): bool =
  ## `os.fileExists` reports a unix socket special file as not existing (it
  ## only recognizes regular files and symlinks), so the control-channel
  ## tests below check for the socket file this way instead.
  try:
    discard getFileInfo(path)
    true
  except OSError:
    false

suite "dev: control channel (native)":
  test "poll is a no-op with nothing pending":
    let server = newDevServer(tmpDir / "test-dev-idle.sock")
    defer: server.close()
    var called = false
    let handled = server.poll(proc (r: string): string = (called = true; "ok"))
    check not handled
    check not called

  test "a request line round-trips through handler to the client":
    let server = newDevServer(tmpDir / "test-dev-echo.sock")
    defer: server.close()

    var client = connectDev(tmpDir / "test-dev-echo.sock")
    client.send("ping\n")

    var seen = ""
    let handled = server.poll(proc (r: string): string =
      seen = r
      "ok pong")
    check handled
    check seen == "ping"
    check client.recvLine() == "ok pong"
    client.close()

  test "a client that sends no full line is dropped instead of stalling poll":
    let path = tmpDir / "test-dev-silent.sock"
    let server = newDevServer(path)
    defer: server.close()
    for partial in ["", "pi"]:
      var client = connectDev(path)
      if partial.len > 0:
        client.send(partial)
      var called = false
      let started = epochTime()
      let handled = server.poll(proc (r: string): string = (called = true; "ok"))
      check not handled
      check not called
      check epochTime() - started < 1.0
      client.close()

  test "a client that closes before its reply does not hang poll":
    let path = tmpDir / "test-dev-gone.sock"
    let server = newDevServer(path)
    defer: server.close()
    var client = connectDev(path)
    client.send("shot\n")
    client.close()
    let started = epochTime()
    let handled = server.poll(proc (r: string): string = "ok " & r)
    # Over TCP the first send to a closed peer succeeds (the reset only
    # shows on the next one), so only the unix route reports it as unhandled.
    when not tcpChannel:
      check not handled
    check epochTime() - started < 1.0

    var next = connectDev(path)
    next.send("ping\n")
    check server.poll(proc (r: string): string = "ok pong")
    check next.recvLine() == "ok pong"
    next.close()

  test "close removes the socket file":
    let path = tmpDir / "test-dev-close.sock"
    let server = newDevServer(path)
    check pathExists(path)
    server.close()
    check not pathExists(path)

suite "dev: in-process capture (no display needed)":
  test "captureScreenshot of an empty framebuffer writes nothing and reports it":
    let path = tmpDir / "test-dev-capture-empty.png"
    removeFile(path)
    check not captureScreenshot(path, 0, 0)
    check not captureScreenshot(path, 32, 0)
    check not fileExists(path)

suite "dev: control channel (web dispatch)":
  test "devCommand errors with no handler installed":
    webDevHandler = nil
    check devCommand("status") == "error no handler installed"

  test "devCommand dispatches to webDevHandler, the same shape poll uses":
    webDevHandler = proc (r: string): string = "ok got " & r
    check devCommand("status") == "ok got status"
    webDevHandler = nil

# ---------------------------------------------------------------- GL-dependent
# Needs a real (if hidden) GL context, so guarded the same way as
# test_app.nim / test_render2d.nim: skip at runtime without a DISPLAY, rather
# than compiling these suites out (existsEnv is not compile-time evaluable).

import paranim/glfw
import paranim/gl
import paranim/opengl
import stb_image/read as stbi
import paraloop/render2d

const repoRoot = currentSourcePath().parentDir.parentDir

type CaptureGame = object of RootGame

proc newHiddenWindow(w, h: int): GLFWWindow =
  doAssert glfwInit()
  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFWTrue)
  glfwWindowHint(GLFWOpenglProfile, GLFWOpenglCoreProfile)
  glfwWindowHint(GLFWVisible, GLFWFalse)
  result = glfwCreateWindow(int32 w, int32 h, "paraloop dev test")
  doAssert result != nil
  result.makeContextCurrent()
  doAssert glInit()

suite "dev: in-process capture (needs a display)":
  test "captureScreenshot writes a PNG matching the cleared framebuffer":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      let win = newHiddenWindow(32, 24)
      discard CaptureGame() # unused; glInit() is enough to read the framebuffer
      glClearColor(0.2, 0.4, 0.6, 1.0)
      glClear(GL_COLOR_BUFFER_BIT)
      glFinish()

      let path = tmpDir / "test-dev-capture.png"
      removeFile(path)
      check captureScreenshot(path, 32, 24)
      check fileExists(path)
      check not fileExists(path & ".tmp")

      var w, h, channels: int
      let pixels = stbi.load(path, w, h, channels, stbi.RGBA)
      check w == 32
      check h == 24
      # Center pixel should match the clear color (0-255, with rounding slack).
      let idx = (h div 2) * w * 4 + (w div 2) * 4
      check abs(int(pixels[idx + 0]) - 51) <= 2   # 0.2 * 255
      check abs(int(pixels[idx + 1]) - 102) <= 2  # 0.4 * 255
      check abs(int(pixels[idx + 2]) - 153) <= 2  # 0.6 * 255

      removeFile(path)
      win.destroyWindow()
      glfwTerminate()

  test "a capture that cannot be written is logged and done, not raised":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      let win = newHiddenWindow(8, 8)
      let blocker = tmpDir / "test-dev-capture-blocker"
      writeFile(blocker, "")
      let path = blocker / "shot.png" # its parent is a regular file
      check captureScreenshot(path, 8, 8)
      check not fileExists(path)
      check not fileExists(path & ".tmp")

      removeFile(blocker)
      win.destroyWindow()
      glfwTerminate()

  test "F9 then drawFrame writes the drawn frame into the bug directory":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      let win = newHiddenWindow(48, 40)
      bugRoot = tmpDir / "test-f9-frame"
      removeDir(bugRoot)
      var game = runHello("3:f9", 3)
      game.init()
      game.drawFrame(0.0)
      let dirs = toSeq(walkDirs(bugRoot / "*"))
      check dirs.len == 1
      var w, h, channels: int
      discard stbi.load(dirs[0] / "shot.png", w, h, channels, stbi.RGBA)
      check w == 48
      check h == 40

      removeDir(bugRoot)
      bugRoot = "tmp" / "bugs"
      win.destroyWindow()
      glfwTerminate()

suite "dev: F3 overlay (needs a display)":
  test "toggleStats flips visibility and drawStats does not crash once shown":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      let win = newHiddenWindow(64, 64)
      var game = CaptureGame()
      let ttf = readFile(repoRoot / "src" / "paraloop" / "assets" / "Roboto-Regular.ttf")
      var text = loadFont(game, ttf, 12.0)

      check not statsShown()
      toggleStats()
      check statsShown()
      recordStats(1.0 / 60.0, 0.001, "3 things")
      drawStats(text, game, 64.0, 64.0) # must not crash
      toggleStats()
      check not statsShown()

      win.destroyWindow()
      glfwTerminate()

suite "dev: end-to-end shot request against running hello":
  test "a `shot` request over the socket returns a valid PNG of hello's framebuffer":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      let sockPath = tmpDir / "dev.sock"
      removeFile(sockPath)
      let win = newHiddenWindow(128, 96)

      var game = initHelloGame()
      game.init() # binds the dev-command socket at the default tmp/dev.sock

      var tick = 0
      proc requestShot(): string =
        ## Sends `shot`, lets one `step` poll it, and returns the replied path.
        var client = connectDev(sockPath)
        client.send("shot\n")
        inc tick
        game.step(tick) # polls the socket, replies with the path, defers the capture
        let reply = client.recvLine()
        client.close()
        check reply.startsWith("ok ")
        reply["ok ".len .. ^1]

      let shotPath = requestShot()
      check requestShot() == shotPath # both are answered by the next draw
      check not fileExists(shotPath)

      game.draw(0.0) # performs the deferred capture

      check fileExists(shotPath)
      var w, h, channels: int
      discard stbi.load(shotPath, w, h, channels, stbi.RGBA)
      check w == 128
      check h == 96

      let nextPath = requestShot()
      check nextPath != shotPath
      check not fileExists(nextPath)
      game.draw(0.0)
      check fileExists(nextPath)

      removeFile(shotPath)
      removeFile(nextPath)
      win.destroyWindow()
      glfwTerminate()

  test "a `shot` whose path cannot be prepared replies `error ...` instead of nothing":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      let sockPath = tmpDir / "dev.sock"
      removeFile(sockPath)
      let win = newHiddenWindow(32, 24)
      var game = initHelloGame()
      game.init() # binds the dev-command socket at the default tmp/dev.sock

      # hello's shot paths are relative (tmp/frames/...): run from a scratch
      # directory whose tmp/frames is a regular file, then from one whose
      # tmp/ is read-only so tmp/frames cannot be created.
      let scratch = tmpDir / "test-dev-shot-blocked"
      let cwd = getCurrentDir()
      var tick = 0
      proc request(line: string): string =
        ## Sends `line`, lets one `step` poll it, and returns the reply.
        var client = connectDev(sockPath)
        client.send(line & "\n")
        inc tick
        game.step(tick)
        result = client.recvLine()
        client.close()
      try:
        for readOnlyTmp in [false, true]:
          removeDir(scratch)
          createDir(scratch / "tmp")
          if readOnlyTmp:
            setFilePermissions(scratch / "tmp", {fpUserRead, fpUserExec})
          else:
            writeFile(scratch / "tmp" / "frames", "")
          setCurrentDir(scratch)
          check request("shot").startsWith("error ")
          game.draw(0.0) # no capture is pending, so nothing is written or raised
          check request("ping") == "ok pong" # the game keeps running
          check fileExists("tmp" / "frames") == not readOnlyTmp
          setCurrentDir(cwd)
      finally:
        setCurrentDir(cwd)
        removeDir(scratch)
        win.destroyWindow()
        glfwTerminate()
