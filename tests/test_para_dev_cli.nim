# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Tests for `para shot`/`para live` (task 1.8): flag and frame-name
# validation, the pure PNG golden-diff logic, `para shot` rendering hello's
# frames headless and checking them against goldens (needs a display, so
# skipped without one like test_dev.nim's GL suites; without one it must be
# a structured error), and a real `para live` round trip over
# `paraloop/dev`'s control-channel protocol -- a fake handler run from a
# background thread stands in for a game.

import std/[unittest, os, times, strutils]
import stb_image/read as stbi
import stb_image/write as stbw
import tools/para/devclient
import tools/para/shotcmd
import tools/para/hellodriver
import tools/para/livecmd
import tools/para/games
import tools/para/art/toon
import paraloop/dev

const tmpDir = currentSourcePath().parentDir.parentDir / "tmp"

suite "devclient: no live session":
  test "socketExists is false for a path nothing has bound":
    check not socketExists(tmpDir / "test-para-no-such.sock")

  test "sendDevRequest raises IOError naming the missing socket":
    let path = tmpDir / "test-para-no-such.sock"
    expect IOError:
      discard sendDevRequest(path, "ping")
    try:
      discard sendDevRequest(path, "ping")
    except IOError as e:
      check path in e.msg

suite "para shot / para live: no live session is a clean usage error, not a crash":
  test "--help on shot and live prints usage, exit 0, before touching any socket":
    let s = runShot(@["--help"])
    check s.code == 0
    check s.output.startsWith("para shot")
    let l = runLive(@["--help"])
    check l.code == 0
    check l.output.startsWith("para live")

  test "`para live status` with no socket names the socket":
    let sockPath = tmpDir / "test-para-live-missing.sock"
    let r = runLive(@["--sock", sockPath, "status"])
    check r.code == 2
    check r.output.startsWith("error:")
    check sockPath in r.output

  test "bare `para live` is content-first, listing status and shot":
    let r = runLive(@[])
    check r.code == 0
    check r.output.contains("status")
    check r.output.contains("shot")

  test "a flag's value is still required, and unknown flags fail loud":
    check runShot(@["--at"]).code == 2
    check runShot(@["--update-golden"]).code == 2
    check runShot(@["--bogus"]).code == 2
    check runShot(@["--sock", "x"]).code == 2
    check runLive(@["--sock"]).code == 2

suite "para shot: game and frame validation (before any window opens)":
  test "an unknown --game lists the valid games":
    let r = runShot(@["--game", "nope", "--check"])
    check r.code == 2
    check r.output.startsWith("error: unknown game \"nope\"")
    # substring, not exact match: task 1.9's `para new` can leave other
    # games registered alongside hello (e.g. a CI run's games/ci_smoke)
    check r.output.contains("Valid games:")
    check r.output.contains("hello")

  test "a driver's own game is what a --game-less command line renders":
    let r = runShotWith(@["--check"], helloShotDriver(), "nope")
    check r.code == 2
    check r.output.startsWith("error: unknown game \"nope\"")

  test "frame names are title (tick 0) or t<N> (tick N)":
    var frames: seq[Frame]
    check parseFrames("title,t600,t3600", frames).code == 0
    check frames == @[("title", 0), ("t600", 600), ("t3600", 3600)]
    let bad = parseFrames("title,later", frames)
    check bad.code == 2
    check bad.output.contains("unknown frame \"later\"")
    check runShot(@["--at", "t"]).code == 2

  test "--update-golden with --at or --check is a usage error, never a silent no-op":
    check runShot(@["--update-golden", "t5", "--check"]).code == 2
    check runShot(@["--update-golden", "t5", "--at", "t5"]).code == 2

# ---------------------------------------------------------------- pure PNG diff

proc writeTinyPng(path: string, r, g, b: byte) =
  createDir(path.parentDir)
  var pixels = newSeq[byte](4 * 4 * 4)
  for i in 0 ..< 16:
    pixels[i * 4 + 0] = r
    pixels[i * 4 + 1] = g
    pixels[i * 4 + 2] = b
    pixels[i * 4 + 3] = 255
  discard stbw.writePNG(path, 4, 4, 4, pixels)

suite "shotcmd: pure golden diff (no socket, no GL)":
  test "identical images diff to 0 changed pixels":
    let a = tmpDir / "test-shot-diff-a.png"
    let b = tmpDir / "test-shot-diff-b.png"
    writeTinyPng(a, 10, 20, 30)
    writeTinyPng(b, 10, 20, 30)
    check diffPixelCount(decodePng(a), decodePng(b)) == 0

  test "every differing pixel is counted":
    let a = tmpDir / "test-shot-diff-c.png"
    let b = tmpDir / "test-shot-diff-d.png"
    writeTinyPng(a, 10, 20, 30)
    writeTinyPng(b, 200, 20, 30)
    check diffPixelCount(decodePng(a), decodePng(b)) == 16

  test "writeDiffPng marks changed pixels red and dims the unchanged golden":
    let a = tmpDir / "test-shot-diff-g.png"
    let b = tmpDir / "test-shot-diff-h.png"
    writeTinyPng(a, 90, 60, 30)
    writeTinyPng(b, 90, 60, 30)
    var frame = decodePng(a)
    frame.pixels[0] = 0 # one changed pixel
    let diffPath = tmpDir / "test-shot-diff.diff.png"
    writeDiffPng(frame, decodePng(b), diffPath)
    let d = decodePng(diffPath)
    check d.pixels[0 .. 3] == @[255'u8, 0, 0, 255]
    check d.pixels[4 .. 7] == @[30'u8, 20, 10, 255]

  test "a size mismatch reports -1, never a false 0":
    let a = tmpDir / "test-shot-diff-e.png"
    createDir(a.parentDir)
    var pixels8 = newSeq[byte](8 * 4 * 4)
    discard stbw.writePNG(a, 8, 4, 4, pixels8)
    let b = tmpDir / "test-shot-diff-f.png"
    writeTinyPng(b, 0, 0, 0)
    check diffPixelCount(decodePng(a), decodePng(b)) == -1

# ---------------------------------------------------------------- real round trip

proc waitForSocket(path: string, timeoutMs = 2000) =
  let started = epochTime()
  while not socketExists(path):
    doAssert (epochTime() - started) * 1000 <= float(timeoutMs), "socket " & path & " never appeared"
    sleep(5)

type ServerArgs = tuple[sockPath, shotPath: string, requests: int]

proc serveFakeGame(args: ServerArgs) {.thread.} =
  ## Stands in for a `-d:dev` game's control-channel handler
  ## (`paraloop/dev`'s module doc: `ok <text>` / `error <message>`, one line
  ## in, one out): `ping`, `shot` (replies with a path that already exists,
  ## since real capture is paraloop/dev's own tested job, not this CLI's),
  ## and `boom` (an error reply), so `para live`'s generic passthrough has
  ## something to forward too. Exits after `args.requests` (or 5s, whichever
  ## first) so `joinThread` doesn't sit through an idle deadline.
  let server = newDevServer(args.sockPath)
  defer: server.close()
  let handler = proc (r: string): string =
    case r.strip
    of "ping": "ok pong"
    of "shot": "ok " & args.shotPath
    of "boom": "error kaboom"
    else: "error unknown \"" & r.strip & "\""
  let deadline = epochTime() + 5.0
  var handled = 0
  while handled < args.requests and epochTime() < deadline:
    var got = false
    {.cast(gcsafe).}:
      got = server.poll(handler)
    if got: inc handled
    else: sleep(10)

suite "para live: a real round trip over the control channel":
  test "status, shot and a generic passthrough":
    let sockPath = tmpDir / "test-para-live.sock"
    let shotPath = tmpDir / "test-para-live-shot.png"
    removeFile(shotPath)
    writeTinyPng(shotPath, 5, 6, 7)

    var t: Thread[ServerArgs]
    createThread(t, serveFakeGame, (sockPath, shotPath, 3))
    defer: joinThread(t)
    waitForSocket(sockPath)

    let status = runLive(@["--sock", sockPath, "status"])
    check status.code == 0
    check status.output.contains("live: up")

    let liveShot = runLive(@["--sock", sockPath, "shot"])
    check liveShot.code == 0
    check liveShot.output.contains(toonCell(shotPath))

    let passthrough = runLive(@["--sock", sockPath, "boom"])
    check passthrough.code == 1
    check passthrough.output.contains("error kaboom")

    removeFile(shotPath)

# ---------------------------------------------------------------- headless render

suite "para shot: hello's frames rendered headless":
  test "without a display it is a structured error, not a crash, and a --check records `check failed`":
    # An unset DISPLAY means "no display" only on X11 systems; Windows and
    # macOS never set it, and GLFW there may abort rather than return nil.
    if existsEnv("DISPLAY") or not defined(linux):
      skip()
    else:
      let r = runShot(@["--at", "title"])
      check r.code == 2
      check r.output.startsWith("error: cannot open a hidden GL window")
      let scratch = tmpDir / "test-para-shot-nodisplay"
      let cwd = getCurrentDir()
      removeDir(scratch)
      createDir(scratch)
      try:
        setCurrentDir(scratch)
        recordStatus("hello", "goldens", "0 changed")
        check shoot(("hello", scratch / "game"), @[("title", 0)], smCheck, helloShotDriver()).code == 2
        check readStatus("hello", "goldens") == "check failed"
      finally:
        setCurrentDir(cwd)
        removeDir(scratch)

  test "--check: no golden, then --update-golden, then identical; a changed golden gets a diff":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      # hello, with its goldens in a scratch dir instead of examples/hello/goldens.
      let game: Game = ("hello", tmpDir / "test-para-shot-game")
      removeDir(game.dir)
      let statusPath = "tmp" / "status" / "hello" / "goldens"
      let hadStatus = fileExists(statusPath)
      let savedStatus = if hadStatus: readFile(statusPath) else: ""
      defer:
        if hadStatus: writeFile(statusPath, savedStatus) else: removeFile(statusPath)
      var frames: seq[Frame]
      check parseFrames("title,t30", frames).code == 0

      let miss = shoot(game, frames, smCheck, helloShotDriver())
      check miss.code == 1
      check miss.output.contains("frames[2]{name,tick,path,diff}:")
      check miss.output.contains("  title,0," & ("tmp" / "frames" / "hello_title.png") & ",no golden\n")
      check miss.output.contains("changed: 2 of 2 frames\n")
      check miss.output.contains("--update-golden title,t30")

      check shoot(game, frames, smUpdate, helloShotDriver()).code == 0
      check fileExists(game.dir / "goldens" / "t30.png")

      let same = shoot(game, frames, smCheck, helloShotDriver())
      check same.code == 0
      check same.output.contains("  t30,30," & ("tmp" / "frames" / "hello_t30.png") & ",identical\n")
      check same.output.contains("changed: 0 of 2 frames\n")

      let golden = decodePng(game.dir / "goldens" / "t30.png")
      discard stbw.writePNG(game.dir / "goldens" / "t30.png", golden.w, golden.h, 4,
                            newSeq[byte](golden.pixels.len))
      let changed = shoot(game, frames, smCheck, helloShotDriver())
      check changed.code == 1
      check changed.output.contains(" px changed\n")
      check changed.output.contains("changed: 1 of 2 frames\n")
      let diffPath = "tmp" / "frames" / "hello_t30.diff.png"
      check changed.output.contains("Read " & ("tmp" / "frames" / "hello_t30.png") & " and " & diffPath)
      var w, h, ch: int
      discard stbi.load(diffPath, w, h, ch, stbi.RGBA)
      check w == golden.w
      check h == golden.h

      removeDir(game.dir)

  test "a frame that cannot be written is an error, never last run's frame diffed as identical":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      # Run from a scratch dir whose tmp/frames holds a previous run's frame
      # (matching its golden) but is read-only, so no new frame can land.
      let scratch = tmpDir / "test-para-shot-stale"
      let game: Game = ("hello", scratch / "game")
      let cwd = getCurrentDir()
      removeDir(scratch)
      writeTinyPng(game.dir / "goldens" / "title.png", 9, 9, 9)
      writeTinyPng(scratch / "tmp" / "frames" / "hello_title.png", 9, 9, 9)
      setFilePermissions(scratch / "tmp" / "frames", {fpUserRead, fpUserExec})
      try:
        setCurrentDir(scratch)
        let r = shoot(game, @[("title", 0)], smCheck, helloShotDriver())
        check r.code == 2
        check r.output.startsWith("error: could not capture frame \"title\"")
        check not r.output.contains("identical")
        check readStatus("hello", "goldens") == "check failed"
      finally:
        setCurrentDir(cwd)
        setFilePermissions(scratch / "tmp" / "frames", {fpUserRead, fpUserWrite, fpUserExec})
        removeDir(scratch)
