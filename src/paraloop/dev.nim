# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
## paraloop/dev: agent-facing dev tooling for the live window, compiled only
## into a game that opts in with `-d:dev` (report §3.3 `paraloop/dev` row),
## so a release build carries none of it -- a game's import of this module is
## meant to sit behind `when defined(dev):` at the call site (see
## `examples/hello/hello.nim`). The `para` CLI, not a game, imports it
## directly to read bug captures and to capture the frames `para shot`
## renders.
##
## In-process capture
## -------------------
## `captureScreenshot(path, width, height)` reads the current framebuffer
## with `glReadPixels` and writes a PNG with `stb_image/write` (report §3.4
## R4): no compositor, works the same behind a hidden GLFW window
## (`GLFWVisible = false`) as on a real one, native or (eventually) wasm.
## Call it after a frame is drawn but before `swapBuffers`. The PNG is
## written beside `path` and renamed onto it, so `path` only ever appears
## complete; an empty framebuffer (a minimized window) writes nothing and
## returns `false`, for the caller to try again on the next frame. A write
## that fails is logged, leaves nothing behind and still returns `true`: the
## capture is done, and the dev session carries on.
##
## Fact dump
## ---------
## `toonFacts(sim, Id, Attr)` renders `paraloop/sim`'s `dumpFacts` as a small
## TOON table (AXI-style: a header naming the row count and columns, then one
## row per fact) -- an agent-readable state dump alongside a screenshot. Ids
## and attributes print as their enum names (an allocated id past the `Id`
## enum as its number) and values as the fact's own value; a field holding
## the delimiter, a quote, a backslash, a colon, a control character or
## edge whitespace, or empty, is a double-quoted JSON-style string.
##
## App-loop hook (F9, F3)
## ----------------------
## Under `-d:dev`, `paraloop/app` calls `devTick(game, tick)` after every
## `step` and `devFrame(game)` after every `draw` (`app.stepTick` /
## `app.drawFrame`), so every game gets F9 and F3 with no code of its own:
##
## - every tick's `engineKeys` state goes into a ring of the last
##   `inputHistoryTicks` (1800, 30 s) ticks;
## - a game with a `sim*: Sim[T, MatchT]` field also gets a rolling
##   snapshot of it, with that tick's key state, every `snapshotEvery`
##   ticks, the oldest kept one no more than `inputHistoryTicks` ticks old,
##   so the ring always holds every tick since it; a game that changes its
##   sim outside the key history calls `freshSnapshot`, which restarts the
##   ring from the changed state;
## - F3 (`wasPressed`) toggles the stats overlay, drawn by `devFrame`;
## - F9 (`wasPressed`) writes a bug directory (below) from the oldest kept
##   snapshot and the input since it, and `devFrame` adds the frame drawn
##   right after; a directory that cannot be written is logged, and the
##   game runs on.
##
## Bug capture
## -----------
## A bug directory, `bugRoot/<bugStamp()>/` (`tmp/bugs/<stamp>/`, report
## §4.4), holds:
##
##     snapshot.json   -- `std/marshal`'s `$$` of the whole `Snapshot[T]`
##                         (tick, seed, RNG state, id allocator, facts,
##                         pending rule work) at the start of the input
##                         history. It round-trips through `to[Snapshot[T]]`
##                         (`readBugSnapshot`) and `paraloop/sim.restore` --
##                         report §3.4 R3's "a serializer (std/marshal or
##                         jsony) works on the generated Fact variant".
##     input.txt       -- the key state the game observed, one line per
##                         tick: `<i> down=<codes> pressed=<codes>`, GLFW
##                         key codes (`isDown`, `wasPressed`), comma-
##                         separated and ascending. Line 0 is the snapshot's
##                         own tick, line `i` what `step(game, from + i)`
##                         saw. F3 and F9 are left out.
##     replay.txt      -- `seed: <n>`, `from: <n>`, `ticks: <n>` and
##                         `hash: <n>`: restore the snapshot, taken after
##                         loop tick `from`, and `engineKeys` to line 0 of
##                         `readBugInput`, then for `i` in `1 .. ticks` set
##                         `engineKeys` to line `i` and `step(game, from +
##                         i)`; `stateHash` is then `hash`, the hash when F9
##                         was pressed.
##     shot.png        -- the frame drawn after the F9 tick.
##
## `readBugSnapshot(dir, T)` and `readBugInput(dir)` read it back; task
## 1.8's `para sim --from` wraps the replay above (`tests/test_dev.nim` runs
## it on `hello`). A bug capture records key state rather than a
## `paraloop/input` script of presses and releases, which is for
## hand-written input: replay sets each tick's state exactly as it was, so a
## key held across the snapshot, a tap shorter than a tick or a key with no
## script name all replay as the game saw them.
##
## Control channel
## ----------------
## Native: a line-oriented request/response server over a unix socket (on
## Windows a loopback TCP listener, with the port written to the same path;
## see `paraloop/devsock`), `tmp/dev.sock` by default (one line in, one line
## out, then the connection closes). `newDevServer` binds it non-blocking; `poll` accepts at most one
## pending connection per call (a no-op when none is waiting) and waits at
## most `requestTimeoutMs` for its line, so a game calls it once per tick
## without the frame loop ever stalling on an idle socket or a silent
## client. The request format is deliberately tiny so task 1.8's `para` CLI
## can wrap it directly:
##
##     request  := one line of text, whatever `handler` accepts
##     response := "ok " <text> | "error " <message>
##
## This module defines no commands of its own beyond that framing -- a game
## wires its own `handler` (see `examples/hello/hello.nim`'s `-d:dev` block
## and `tests/test_dev.nim`), so `paraloop/dev` stays free of any one game's
## schema or command vocabulary.
##
## A reply naming a file a later frame writes (hello's `shot`) is sent
## before that file exists: a client waits for the path to appear, and it
## appears complete (see In-process capture).
##
## Web has no unix sockets; the same role is the C export `devCommand`, a
## KEEPALIVE function JS calls as `Module._devCommand` (task 1.7 wires it
## into the browser). Its returned string stays valid until the next call.
## The Nim `devCommand` below is that export's body, factored out so a
## native test can exercise it ahead of that wiring: a game sets
## `webDevHandler` once (the same `handler` shape `poll` takes), and both
## dispatch to it.
##
## F3 overlay
## ----------
## `toggleStats`/`recordStats`/`drawStats` are parasurvivors' F3 stats
## overlay (`render.nim:207-240`), carried over onto `paraloop/render2d`'s
## `TextBatch` instead of a direct session read (report §3.3 R7). `run`
## feeds `recordStats` each frame; `devFrame` draws it in
## `assets/Roboto-Regular.ttf`.

import std/[net, nativesockets, os, times, strutils, marshal, math, deques, sets, algorithm, hashes, sequtils]
from std/json import escapeJson
import paranim/opengl
import paranim/glfw
import stb_image/write as stbw
import paraloop/sim
import paraloop/input
import paraloop/render2d
import paraloop/devsock

# ---------------------------------------------------------------- capture

proc ensureParentDir(path: string) =
  let d = path.parentDir
  if d.len > 0:
    createDir(d)

proc captureScreenshot*(path: string, width, height: int): bool =
  ## Reads the current framebuffer and writes it to `path` as a PNG,
  ## returning `true` once the capture is done (written, or failed and
  ## logged); `false`, writing nothing, when `width` or `height` is not
  ## positive. `width`/`height` are the framebuffer size in pixels
  ## (`paraloop/app.windowSize()`); `paraloop/dev` takes no dependency on
  ## `paraloop/app` itself, so this can be driven against any current GL
  ## context (a test's hidden window included).
  if width <= 0 or height <= 0:
    return false
  var pixels = newSeq[byte](width * height * 4)
  glReadPixels(0, 0, GLsizei width, GLsizei height, GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)
  # glReadPixels reads bottom-to-top (OpenGL's origin is bottom-left); PNG
  # rows are stored top-to-bottom, so flip before writing.
  var flipped = newSeq[byte](pixels.len)
  let stride = width * 4
  for row in 0 ..< height:
    let src = row * stride
    let dst = (height - 1 - row) * stride
    for i in 0 ..< stride:
      flipped[dst + i] = pixels[src + i]
  let partial = path & ".tmp"
  try:
    ensureParentDir(path)
    if not stbw.writePNG(partial, width, height, 4, flipped):
      raise newException(IOError, "cannot write " & partial)
    moveFile(partial, path)
  except OSError, IOError:
    discard tryRemoveFile(partial)
    echo "paraloop/dev: capture to ", path, " failed: ", getCurrentExceptionMsg()
  true

# ---------------------------------------------------------------- fact dump

proc toonField(s: string): string =
  ## `s` as one TOON field: bare when it is unambiguous, otherwise quoted.
  let bare = s.len > 0 and s == s.strip and
    not s.anyIt(it in {',', '"', '\\', ':'} or it < ' ' or it == '\x7f')
  if bare: s else: s.escapeJson

proc toonValue[V](v: V): string =
  when V is string:
    v
  elif V is ref:
    if v.isNil: "nil" else: toonValue(v[])
  else:
    $v

proc toonFacts*[T, MatchT, I, A](sim: Sim[T, MatchT], idType: typedesc[I],
                                 attrType: typedesc[A]): string =
  ## Every fact as a TOON table: `facts[N]{id,attr,value}:` then one row per
  ## fact, in `dumpFacts`' deterministic `(id, attr)` order. `idType` and
  ## `attrType` are the schema's `Id` and `Attr` enums, for their names.
  let facts = sim.dumpFacts
  result = "facts[" & $facts.len & "]{id,attr,value}:\n"
  for f in facts:
    let id = if f.id in I.low.ord .. I.high.ord: $I(f.id) else: $f.id
    var value = ""
    for name, slot in fieldPairs(f.value):
      when name != "kind":
        value = toonValue(slot)
    result.add "  " & toonField(id) & "," & toonField($A(f.attr)) & "," &
      toonField(value) & "\n"

# ---------------------------------------------------------------- bug capture

var bugRoot* = "tmp" / "bugs"
  ## Where F9 writes its bug directories; a test points it at its own dir.

proc bugStamp*(): string =
  ## `YYYYMMDD-HHMMSS-mmm` (UTC), the directory name under `bugRoot`.
  now().utc.format("yyyyMMdd-HHmmss-fff")

const devKeys = [KeyF3, KeyF9]

proc codesText(keys: HashSet[int]): string =
  var codes: seq[int]
  for key in keys:
    if key notin devKeys:
      codes.add key
  codes.sorted.join(",")

proc codesOf(text: string): HashSet[int] =
  for code in text.split(','):
    if code.len > 0:
      result.incl code.parseInt

proc writeBugCapture*[T](snap: Snapshot[T], input: openArray[KeyState], fromTick: int,
                         hash: Hash, dir = bugRoot / bugStamp()): string =
  ## Writes a bug directory (see the module doc) at `dir` holding
  ## `snapshot.json` (`snap` marshaled), `input.txt` (`input`, the key state
  ## at `snap`'s tick and then at each tick after it) and `replay.txt`
  ## (`snap`'s seed, `fromTick` -- the loop tick `snap` was taken after --
  ## the ticks after it `input` covers, and `hash`), and returns `dir`. F9
  ## calls it with the rolling snapshot and the input since it; `devFrame`
  ## then adds `shot.png`.
  createDir(dir)
  writeFile(dir / "snapshot.json", $$snap)
  var lines: seq[string]
  for i, keys in input:
    lines.add $i & " down=" & codesText(keys.pressed) & " pressed=" & codesText(keys.justPressed)
  writeFile(dir / "input.txt", lines.join("\n") & "\n")
  writeFile(dir / "replay.txt", "seed: " & $snap.seed & "\nfrom: " & $fromTick &
            "\nticks: " & $(input.len - 1) & "\nhash: " & $hash & "\n")
  dir

proc readBugInput*(dir: string): seq[KeyState] =
  ## Parses `dir/input.txt` back into its key states, one per line (line 0
  ## the snapshot's tick), raising `ValueError` on a malformed line.
  for line in readFile(dir / "input.txt").splitLines:
    if line.len == 0:
      continue
    let f = line.split(' ')
    if f.len != 3 or f[0] != $result.len or not f[1].startsWith("down=") or
        not f[2].startsWith("pressed="):
      raise newException(ValueError, "input.txt line " & $result.len & ": malformed \"" &
                         line & "\" (expected <i> down=<codes> pressed=<codes>)")
    result.add KeyState(pressed: codesOf(f[1]["down=".len .. ^1]),
                        justPressed: codesOf(f[2]["pressed=".len .. ^1]))

proc readBugSnapshot*[T](dir: string, _: typedesc[T]): Snapshot[T] =
  ## Parses `dir/snapshot.json` back into a `Snapshot[T]` -- the read side of
  ## `writeBugCapture`, for a headless replay: `restore` it into a fresh
  ## session (`paraloop/sim.restore`) and compare `stateHash` against the
  ## sim `writeBugCapture` was called on.
  to[Snapshot[T]](readFile(dir / "snapshot.json"))

const
  inputHistoryTicks* = 1800 ## 30 s of ticks at 60 Hz: how far back F9's input history reaches
  snapshotEvery* = 60       ## ticks between the rolling snapshots F9 replays from

var
  inputHistory: Deque[tuple[tick: int, keys: KeyState]]
  pendingFrame = "" ## where `devFrame` writes the next drawn frame, after an F9
  freshSnapshotWanted = false ## `freshSnapshot` was called since the last `devTick`

proc freshSnapshot*() =
  ## A game calls this (from its `step`) when it changes its sim state in a way
  ## the recorded key history cannot replay -- a tuning dial set over the dev
  ## channel. The next `devTick` drops the rolling snapshots, which predate the
  ## change, and takes one of the changed state, so an F9 capture replays from
  ## there to the same `stateHash`.
  freshSnapshotWanted = true

proc snapshotRing[S](): var Deque[tuple[tick: int, snap: S, keys: KeyState]] =
  ## The rolling snapshots of one game's `sim` (one ring per `Snapshot[T]`),
  ## each with its tick's key state.
  var ring {.global.}: Deque[tuple[tick: int, snap: S, keys: KeyState]]
  ring

proc inputAfter(fromTick: int): seq[KeyState] =
  ## `inputHistory`'s key states for the ticks after `fromTick`, in order.
  for (tick, keys) in inputHistory:
    if tick > fromTick:
      result.add keys

# ---------------------------------------------------------------- control channel (native)

type
  DevHandler* = proc (request: string): string {.closure.}
    ## Turns one request line into one response line. `paraloop/dev` does
    ## not parse the request itself (see the module doc's `ok`/`error`
    ## convention) -- a game's command vocabulary lives entirely here.

  DevServer* = object
    sock: Socket
    path*: string

proc newDevServer*(path = "tmp" / "dev.sock"): DevServer =
  ## Binds a non-blocking unix-socket listener at `path`, removing a stale
  ## socket file a crashed previous run left behind first (each worktree
  ## owns its own `tmp/`, so this never touches another lane's socket).
  ## `fileExists` cannot see it (the stdlib defines a socket special file as
  ## not "existing" for that check), so removal is unconditional and ignores
  ## a missing file rather than checking for one first.
  ensureParentDir(path)
  try:
    removeFile(path)
  except OSError:
    discard
  var sock = listenDev(path)
  sock.getFd().setBlocking(false)
  DevServer(sock: sock, path: path)

proc close*(server: DevServer) =
  ## Closes the listening socket and removes its file.
  server.sock.close()
  try:
    removeFile(server.path)
  except OSError:
    discard

const requestTimeoutMs* = 50
  ## How long `poll` waits for an accepted client's request line before
  ## dropping it.

proc poll*(server: DevServer, handler: DevHandler): bool =
  ## Call once per tick. Accepts at most one pending connection
  ## non-blockingly -- a no-op, returning `false`, when none is waiting --
  ## reads one line (dropping the client, `false`, when none arrives within
  ## `requestTimeoutMs`), passes it to `handler`, and sends back the line
  ## `handler` returns before closing the connection. Returns `true` when a
  ## request was handled and answered (`false` when the OS reports the client
  ## left before its reply). A `DevServer` never bound (`newDevServer`) has nothing to
  ## accept.
  if server.sock.isNil:
    return false
  var client: Socket
  var address: string
  try:
    server.sock.acceptAddr(client, address)
  except OSError:
    return false
  defer: client.close()
  client.getFd().setBlocking(true) # a plain, brief read of one request line
  var line: string
  try:
    line = client.recvLine(timeout = requestTimeoutMs)
  except TimeoutError, OSError:
    return false
  if line.len == 0:
    return false
  # No `SafeDisconn`: with it, `send` to a client already gone loops forever
  # on EPIPE instead of raising.
  try:
    client.send(handler(line) & "\n", flags = {})
  except OSError:
    return false
  true

# ---------------------------------------------------------------- control channel (web)

var webDevHandler*: DevHandler = nil
  ## A game sets this once (the same `handler` shape `poll` takes) and
  ## `devCommand`/the web `_devCommand` export dispatch to it -- one command
  ## vocabulary works on both platforms. Left `nil` until a game installs
  ## one; task 1.7 wires the browser call site, this module only proves the
  ## export's shape (see `tests/test_dev.nim`).

proc devCommand*(request: string): string =
  ## The body behind the web KEEPALIVE export below, factored out so a
  ## native test can call it directly ahead of 1.7's browser wiring.
  if webDevHandler == nil:
    return "error no handler installed"
  webDevHandler(request)

when defined(emscripten):
  {.emit: "#include <emscripten.h>".}

  var lastDevResponse: string

  proc devCommandExport(request: cstring): cstring
      {.exportc: "devCommand", codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
    lastDevResponse = devCommand($request)
    lastDevResponse.cstring

# ---------------------------------------------------------------- F3 overlay

var
  statsVisible = false
  statsDt = 0.0   ## seconds/frame, smoothed
  statsWork = 0.0 ## seconds of sim per tick, smoothed
  statsLabel = ""

proc toggleStats*() =
  statsVisible = not statsVisible

proc statsShown*(): bool =
  statsVisible

proc recordStats*(dt, work: float, label = "") =
  ## Feeds one tick's frame time (`dt`) and sim work time (both seconds) to
  ## the F3 overlay, each smoothed with roughly a half-second exponential
  ## moving average (parasurvivors `render.nim:207-240`, carried over
  ## unchanged). `label` is appended as-is -- a game's own per-tick count,
  ## e.g. `"142 enemies"`.
  if dt <= 0:
    return
  let a = min(1.0, dt / 0.5)
  statsDt = if statsDt == 0.0: dt else: statsDt + (dt - statsDt) * a
  statsWork = statsWork + (work - statsWork) * a
  statsLabel = label

proc drawStats*[G](t: var TextBatch, game: G, ww, wh: float) =
  ## Draws the F3 overlay's one line, bottom-right, when `toggleStats` has
  ## turned it on and at least one `recordStats` has run. A no-op otherwise.
  if not statsVisible or statsDt <= 0:
    return
  var s = $int(round(1.0 / statsDt)) & " fps   " &
          formatFloat(statsDt * 1000, ffDecimal, 1) & " ms   sim " &
          formatFloat(statsWork * 1000, ffDecimal, 2) & " ms"
  if statsLabel.len > 0:
    s.add "   " & statsLabel
  drawText(t, game, s, ww - t.textWidth(s, 0.8) - 10, wh - 26, ww, wh, scale = 0.8)

# ---------------------------------------------------------------- app-loop hook

proc devTick*[G](game: var G, tick: int) =
  ## `paraloop/app`'s per-tick dev hook, run after `game.step(tick)` and
  ## before `endTick(engineKeys)`: records the tick's input, keeps the
  ## rolling snapshot of `game.sim` (when the game has one), and handles F3
  ## and F9 (see the module doc). A tick not after the last one recorded
  ## starts a new run, dropping the history.
  let newRun = inputHistory.len > 0 and tick <= inputHistory.peekLast.tick
  if newRun:
    inputHistory.clear()
  inputHistory.addLast (tick, engineKeys)
  while inputHistory.len > inputHistoryTicks:
    inputHistory.popFirst()
  when compiles(game.sim.snapshot()):
    template ring: untyped = snapshotRing[typeof(game.sim.snapshot())]()
    if newRun or freshSnapshotWanted:
      ring.clear()
    if ring.len == 0 or tick mod snapshotEvery == 0:
      ring.addLast (tick, game.sim.snapshot(), engineKeys)
    while ring[0].tick < tick - inputHistoryTicks:
      ring.popFirst()
  freshSnapshotWanted = false
  if engineKeys.wasPressed(KeyF3):
    toggleStats()
  if engineKeys.wasPressed(KeyF9):
    when compiles(game.sim.snapshot()):
      let (fromTick, snap, snapKeys) = ring[0]
      try:
        let dir = writeBugCapture(snap, @[snapKeys] & inputAfter(fromTick), fromTick,
                                  game.sim.stateHash())
        pendingFrame = dir / "shot.png"
        echo "paraloop/dev: F9 bug capture in ", dir
      except OSError, IOError:
        echo "paraloop/dev: F9 bug capture failed: ", getCurrentExceptionMsg()
    else:
      echo "paraloop/dev: F9 needs a `sim` field on the game; nothing captured"

const statsTtf = staticRead("assets/Roboto-Regular.ttf")

var
  statsText: TextBatch
  statsTextLoaded = false

proc devFrame*[G](game: var G) =
  ## `paraloop/app`'s per-frame dev hook, run after `game.draw` and before
  ## the buffer swap: writes the frame to the bug directory the last F9
  ## opened, then draws the F3 overlay on top. While the framebuffer is
  ## empty (a minimized window) a pending frame waits for a real one.
  var width, height: int32
  glfwGetCurrentContext().getFramebufferSize(width.addr, height.addr)
  if pendingFrame.len > 0 and captureScreenshot(pendingFrame, width.int, height.int):
    pendingFrame = ""
  if statsVisible:
    if not statsTextLoaded:
      statsText = loadFont(game, statsTtf, 24.0)
      statsTextLoaded = true
    drawStats(statsText, game, float width, float height)
