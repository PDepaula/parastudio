## __GAME__: a paraloop game started from `template/` (task 1.9). Same shape
## as `examples/hello`: a `paraloop/app.Game` (`init`/`step`/`draw`), state
## kept as facts in a `paraloop/sim.Sim` (see `rules.nim`), moved by the
## arrow keys and driven headless by a tick-indexed replay
## (`tests/test___GAME__.nim`).
##
## Runs native and (`-d:emscripten`) web. Under `-d:dev`: F3/F9 and a bug
## capture that replays to the same `stateHash` come free from
## `paraloop/app`/`paraloop/dev` for any game with a `sim*: Sim[T, MatchT]`
## field; `handleDevCommand` below adds `para live shot`/`ping`.

import pararules
import paranim/opengl
import paranim/gl
import paraloop/app
import paraloop/input
import paraloop/render2d
import paraloop/sim
import rules
import data
when defined(dev):
  import std/[strutils, times, os]
  import paranim/glfw
  import paraloop/dev

const
  gameName = "__GAME__"
  spriteSize = 64
  moveSpeed* = 4 ## world units per tick an arrow key moves the sprite
  referenceWidth = 1024.0
  referenceHeight = 768.0
  fontTtf = staticRead("../../src/paraloop/assets/Roboto-Regular.ttf")

let spritePixels = block:
  ## A flat colour square, generated instead of loaded so a new game needs
  ## no binary asset to compile and draw something (swap in a real sheet via
  ## `paraloop/render2d.loadSheet` when there's art to load).
  var pixels: seq[byte]
  for _ in 0 ..< spriteSize * spriteSize:
    pixels.add(52); pixels.add(152); pixels.add(219); pixels.add(255)
  pixels

type
  Game* = object of RootGame
    sprite: Sheet
    text: TextBatch
    sim*: Sim[Fact, FactMatch]

proc newGameSession*(): Session[Fact, FactMatch] =
  ## A fresh session with every rule added and the standard attrs (report
  ## §4.2) at their starting values -- the zero-arg session factory
  ## `paraloop/sim.restore` takes as its `newSession` argument.
  result = newRawSession()
  for r in gameRules.fields:
    result.add(r)
  result.insert(Global, TotalTime, 0.0)
  result.insert(Global, WorldWidth, referenceWidth)
  result.insert(Global, WorldHeight, referenceHeight)
  result.insert(Global, Phase, Playing)
  result.insert(Player, PosX, 0)
  result.insert(Player, PosY, 0)

proc initGame*(): Game =
  Game(sim: initSim(newGameSession(), seed = 0'i64, idType = Id))

proc player(game: Game): tuple[x, y: int, phase: GamePhase] =
  game.sim.session.query(gameRules.player)

proc pos*(game: Game): tuple[x, y: int] =
  ## The sprite's offset from the window centre, in world units (y down).
  let p = game.player
  (p.x, p.y)

when defined(dev):
  when not defined(emscripten):
    var gDevServer: DevServer
  var
    gShotPending: bool
    gShotPath: string
    gShotCount: int

  proc handleDevCommand(request: string): string =
    ## `paraloop/dev`'s control-channel vocabulary for this game: `ping`
    ## (liveness) and `shot` (`para live shot`, task 1.6/1.8's acceptance
    ## target), the same pattern as `examples/hello`. Capture is deferred to
    ## the end of this tick's `draw`: `step` (where commands are polled)
    ## always runs before `draw` for the same tick, so the `ok <path>` reply
    ## comes first and a client waiting on `<path>` only ever sees it
    ## complete.
    case request.strip
    of "ping":
      "ok pong"
    of "shot":
      if not gShotPending:
        inc gShotCount
        let path = "tmp" / "frames" / gameName & "_" &
          now().utc.format("yyyyMMdd-HHmmss-fff") & "_" & $gShotCount & ".png"
        try:
          createDir(path.parentDir)
          removeFile(path)
        except OSError, IOError:
          let reason = "cannot prepare " & path & ": " &
            getCurrentExceptionMsg().splitLines.join(" ")
          echo gameName, ": shot failed: ", reason
          return "error " & reason
        gShotPath = path
        gShotPending = true
      "ok " & gShotPath
    else:
      "error unknown command \"" & request.strip & "\""

proc init*(game: var Game) =
  doAssert glInit()
  glEnable(GL_BLEND)
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
  game.sprite = initSheet(game, spritePixels, spriteSize, spriteSize)
  game.text = loadFont(game, fontTtf, 24.0)
  when defined(dev) and not defined(emscripten):
    gDevServer = newDevServer()

proc step*(game: var Game, tick: int) =
  ## Turn the arrow keys held in `engineKeys` into a `Step` of `moveSpeed`
  ## world units per key and pulse it as a command (`rules.nim`'s `move`
  ## moves the sprite), then close the tick with `DeltaTime` -- the per-tick
  ## rule's one trigger, so it stays the last insert (`rules.nim`'s
  ## `tickTime`). The shell maps keys to the command; the rule decides what
  ## it does. The window's size is not a fact: `draw` reads it.
  var by: Step
  if engineKeys.isDown(KeyLeft): by.dx -= moveSpeed
  if engineKeys.isDown(KeyRight): by.dx += moveSpeed
  if engineKeys.isDown(KeyUp): by.dy -= moveSpeed
  if engineKeys.isDown(KeyDown): by.dy += moveSpeed
  inc game.sim.tick
  if by != (dx: 0, dy: 0):
    game.sim.pulse(Global, MoveCommand, by)
  game.sim.session.insert(Global, DeltaTime, fixedDt)
  when defined(dev) and not defined(emscripten):
    discard gDevServer.poll(handleDevCommand)

proc draw*(game: var Game, alpha: float) =
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
  let p = game.player
  game.sprite.addCell(0, 0, worldW / 2 + float(p.x), worldH / 2 + float(p.y),
                       float spriteSize, float spriteSize)
  game.sprite.flush(game, worldW, worldH, camera)

  # HUD content: screen pixels, identity camera. `phaseDefs` (data.nim) is
  # the "content is table rows" recipe -- adding a phase never adds a `case`.
  game.text.drawText(game, "paraloop " & gameName & " -- " & phaseDefs[p.phase].label,
                      20, 20, float ww, float wh)

  when defined(dev):
    if gShotPending:
      # The framebuffer's own size, not `windowSize()`: a test may drive
      # `draw` against a window `paraloop/app.run` never set up.
      var fbWidth, fbHeight: int32
      glfwGetCurrentContext().getFramebufferSize(fbWidth.addr, fbHeight.addr)
      if captureScreenshot(gShotPath, fbWidth.int, fbHeight.int):
        gShotPending = false

when isMainModule:
  run(initGame(), title = "paraloop " & gameName)
