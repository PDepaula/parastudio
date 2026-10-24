## Smallest possible paraloop game: a sprite the arrow keys move, an atlas
## icon and a line of text, drawn every frame. Proves `paraloop/app`'s window
## + fixed-timestep loop + `Game` contract, `paraloop/input`'s `engineKeys`,
## and `paraloop/render2d`'s batches, compile-time atlas manifest, text,
## camera and `zoomFor` end to end (task 1.5's acceptance target). Runs
## native and (`-d:emscripten`) web. A replay script drives `step` headless
## the same way (`tests/test_hello.nim`).
##
## The sprite's position is its whole game state, kept as facts in a
## `paraloop/sim` `Sim` (the `sim` field), so under `-d:dev` `paraloop/dev`'s
## F9 capture of it replays to the same `stateHash` (`tests/test_dev.nim`).
##
## A short beep plays each time an arrow key goes down from rest: the one
## sound, through `paraloop/audio`'s Recipe -> Backend path (a native window
## plays it through miniaudio, the web build through Web Audio once the page has
## seen a key press or click). Headless runs have no backend and stay silent.
##
## The atlas icon comes from `assets/icons.png` + `assets/icons.txt` (two
## flat-colour squares, generated for this example -- see
## `paraloop/render2d`'s module doc for the manifest format). The font is
## Roboto (Google, Apache 2.0), carried over from parasurvivors' assets into
## `src/paraloop/assets/`.

import pararules
import paranim/opengl
import paranim/gl
import paraloop/app
import paraloop/audio
import paraloop/input
import paraloop/render2d
import paraloop/sim
when isMainModule:
  import paraloop/audio_device
when defined(dev):
  import std/[strutils, times, os]
  import paranim/glfw
  import paraloop/dev

const
  spriteSize = 64
  moveSpeed* = 4 ## world units per tick an arrow key moves the sprite
  referenceHeight = 768.0
  iconPng = staticRead("assets/icons.png")
  iconManifest = staticRead("assets/icons.txt")
  fontTtf = staticRead("../../src/paraloop/assets/Roboto-Regular.ttf")

type
  Icon* = enum
    ## Manifest name = the enum value, lower-cased (see `paraloop/render2d`).
    IconRed, IconBlue

const icons* = parseAtlas(Icon, iconManifest, iconPng) ## a bad manifest fails right here, at compile time

const
  beepSlot = 0 ## the beep's index in `helloSounds`
  helloSounds* = [Recipe(name: "beep", tones: @[tone(Square, 0, 90, 76.0, noteEnd = 83.0, gain = 0.25)])]

let spritePixels = block:
  ## A flat orange square, generated instead of loaded so the sprite batch
  ## needs no binary asset -- `assets/icons.png` exercises the real
  ## `staticRead` + atlas path below.
  var data: seq[byte]
  for _ in 0 ..< spriteSize * spriteSize:
    data.add(230); data.add(126); data.add(34); data.add(255)
  data

type
  HelloId* = enum
    Player
  HelloAttr* = enum
    PosX, PosY ## sprite offset from the window centre, in world units (y down)

schema HelloFact(HelloId, HelloAttr):
  PosX: int
  PosY: int

let (initSession, helloRules) =
  staticRuleset(HelloFact, HelloFactMatch):
    rule player(HelloFact):
      what:
        (Player, PosX, x)
        (Player, PosY, y)

type
  HelloGame* = object of RootGame
    sprite: Sheet
    icons: Sheet
    text: TextBatch
    audio*: Audio ## silent until `initAudio` gives it a backend
    moving: bool ## an arrow key was down last tick (the beep plays on the edge)
    sim*: Sim[HelloFact, HelloFactMatch]

proc newHelloSession*(): Session[HelloFact, HelloFactMatch] =
  ## A fresh session with hello's rule and the sprite centred -- the
  ## `newSession` factory `paraloop/sim.restore` takes.
  result = initSession()
  for r in helloRules.fields:
    result.add(r)
  result.insert(Player, PosX, 0)
  result.insert(Player, PosY, 0)

proc initHelloGame*(seed = 0'i64): HelloGame =
  HelloGame(sim: initSim(newHelloSession(), seed = seed, idType = HelloId))

proc pos*(game: HelloGame): tuple[x, y: int] =
  ## The sprite's offset from the window centre, in world units (y down).
  let p = game.sim.session.query(helloRules.player)
  (p.x, p.y)

when defined(dev):
  when not defined(emscripten):
    var gDevServer: DevServer
  var
    gShotPending: bool
    gShotPath: string
    gShotCount: int

  proc handleDevCommand(request: string): string =
    ## `paraloop/dev`'s minimal control-channel vocabulary for `hello`:
    ## `ping` (liveness) and `shot` (task 1.6's acceptance target -- `para
    ## live shot` wraps this, task 1.8). Capture is
    ## deferred to the end of this tick's `draw`, matching the report's "the
    ## game writes its own back buffer at the next tick" -- `step` (where
    ## commands are polled) always runs before `draw` for the same tick.
    ## So the `ok <path>` reply comes first: a client waits for `<path>` to
    ## appear, and `captureScreenshot` only ever makes it appear complete
    ## (a minimized window defers it to the first non-empty frame). Each
    ## capture gets a fresh path, so it never names an older frame; `shot`s
    ## that arrive before the same `draw` share its path. A path that cannot
    ## be prepared (say `tmp/frames` is a regular file, or cannot be created)
    ## is logged and answered `error <reason>`, with no capture pending.
    case request.strip
    of "ping":
      "ok pong"
    of "shot":
      if not gShotPending:
        inc gShotCount
        let path = "tmp" / "frames" / "hello_" &
          now().utc.format("yyyyMMdd-HHmmss-fff") & "_" & $gShotCount & ".png"
        try:
          createDir(path.parentDir)
          removeFile(path)
        except OSError, IOError:
          # One reply line: OSError messages carry a newline before their
          # "Additional info".
          let reason = "cannot prepare " & path & ": " &
            getCurrentExceptionMsg().splitLines.join(" ")
          echo "hello: shot failed: ", reason
          return "error " & reason
        gShotPath = path
        gShotPending = true
      "ok " & gShotPath
    else:
      "error unknown command \"" & request.strip & "\""

proc init*(game: var HelloGame) =
  doAssert glInit()
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  game.sprite = initSheet(game, spritePixels, spriteSize, spriteSize)
  game.icons = loadSheet(game, iconPng)
  game.text = loadFont(game, fontTtf, 24.0)
  when defined(dev) and not defined(emscripten):
    gDevServer = newDevServer()

proc step*(game: var HelloGame, tick: int) =
  ## Move the sprite `moveSpeed` world units per tick for each arrow key held in
  ## `engineKeys`.
  var (x, y) = game.pos
  if engineKeys.isDown(KeyLeft): x -= moveSpeed
  if engineKeys.isDown(KeyRight): x += moveSpeed
  if engineKeys.isDown(KeyUp): y -= moveSpeed
  if engineKeys.isDown(KeyDown): y += moveSpeed
  let moving = (x, y) != game.pos
  if moving and not game.moving:
    game.audio.play(beepSlot)
  game.moving = moving
  inc game.sim.tick
  game.sim.session.insert(Player, PosX, x)
  game.sim.session.insert(Player, PosY, y)
  when defined(dev) and not defined(emscripten):
    discard gDevServer.poll(handleDevCommand)

proc draw*(game: var HelloGame, alpha: float) =
  let (ww, wh) = windowSize()
  glClearColor(0.10, 0.11, 0.15, 1.0)
  glClear(GL_COLOR_BUFFER_BIT)
  glViewport(0, 0, GLsizei ww, GLsizei wh)

  # World content (the sprite): sized and positioned in world units, at a
  # fixed camera -- `zoomFor` scales world units to screen pixels via the
  # world extent handed to `flush`, so a short window zooms out instead of
  # cropping, and `moveSpeed` stays a constant world-unit speed regardless.
  let zoom = zoomFor(wh, referenceHeight)
  let worldW = float(ww) / zoom
  let worldH = float(wh) / zoom
  let camera = mat3f(1) # fixed: world (0, 0) is the screen's top-left corner
  let (x, y) = game.pos
  game.sprite.addCell(0, 0, worldW / 2 + float(x), worldH / 2 + float(y),
                       float spriteSize, float spriteSize)
  game.sprite.flush(game, worldW, worldH, camera)

  # HUD content (the atlas icons and text): screen pixels, identity camera.
  game.icons.addRegion(icons.rects[IconRed], float(ww) / 2 - 48, float(wh) / 2 + 70, 32)
  game.icons.addRegion(icons.rects[IconBlue], float(ww) / 2 + 48, float(wh) / 2 + 70, 32)
  game.icons.flush(game, float ww, float wh, mat3f(1))

  game.text.drawText(game, "paraloop hello", 20, 20, float ww, float wh)

  when defined(dev):
    if gShotPending:
      # The framebuffer's own size, not `windowSize()`: a test may drive
      # `draw` against a window `paraloop/app.run` never set up (its cached
      # size stays 0), and the two agree whenever `run` did set it up.
      var fbWidth, fbHeight: int32
      glfwGetCurrentContext().getFramebufferSize(fbWidth.addr, fbHeight.addr)
      if captureScreenshot(gShotPath, fbWidth.int, fbHeight.int):
        gShotPending = false

when isMainModule:
  var game = initHelloGame()
  game.audio = initAudio(openDevice(), helloSounds, configuredMaster(0.5))
  run(game, title = "paraloop hello")
