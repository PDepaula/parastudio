## Window, HiDPI, emscripten main loop, and the
## `Game` contract every paraloop game implements: a type `G` with
## `init(game: var G)`, `step(game: var G, tick: int)` and
## `draw(game: var G, alpha: float)`. `run` drives it and feeds window key
## events into `paraloop/input`'s `engineKeys` and the cursor and mouse buttons
## into its `enginePointer` (framebuffer pixels from the top-left; the web shell
## writes the same state through `Module._psPointer`/`_psButton`, so the native
## callbacks are not installed under emscripten); nothing here reads or writes a
## pararules session, so outside `-d:dev` (below) it has no dependency on
## `paraloop/sim`.
##
## The fixed-timestep accumulator (`fixedDt`, `Accumulator`) lives in
## `paraloop/clock`, which has no window dependency so headless code can use
## it; this module re-exports it, so `import paraloop/app` still gives both.
##
## Window creation, HiDPI density tracking and the emscripten main-loop shim
## are carried over from parasurvivors (`src/parasurvivors.nim`), which ran
## unchanged on native and web builds.
##
## Under `-d:dev`, `stepTick` and `drawFrame` also run `paraloop/dev`'s
## per-tick and per-frame hooks, so every game gets its F9 bug capture and
## F3 overlay (see that module's doc).

import paranim/glfw
import paraloop/clock
from paraloop/input import engineKeys, enginePointer, keyDown, keyUp, endTick, pointerMove,
                           buttonDown, buttonUp
export clock
when defined(dev):
  import paraloop/dev

proc stepTick*[G](game: var G, tick: int) =
  ## One fixed tick the way `run` drives it: `game.step(tick)`, then (under
  ## `-d:dev`) `paraloop/dev.devTick`, then `endTick` on `engineKeys` and
  ## `enginePointer`. A headless replay can call it in place of `run`.
  game.step(tick)
  when defined(dev):
    devTick(game, tick)
  endTick(engineKeys)
  endTick(enginePointer)

proc drawFrame*[G](game: var G, alpha: float) =
  ## One frame's drawing the way `run` does it: `game.draw(alpha)`, then
  ## (under `-d:dev`) `paraloop/dev.devFrame`.
  game.draw(alpha)
  when defined(dev):
    devFrame(game)

# ---------------------------------------------------------------- window / HiDPI

var
  gWindow: GLFWWindow
  gDensity = 1.0 ## framebuffer pixels per layout pixel (HiDPI screens, and the web's devicePixelRatio)
  gFbWidth, gFbHeight: int

var gQuit = false

proc requestQuit*() =
  ## Ends `run` after the current frame (a game's "quit" option): natively the
  ## loop exits and the window is destroyed the same way closing it does. Under
  ## emscripten it stops the main loop, leaving the last frame on the page.
  gQuit = true

proc resetQuit*() =
  ## Clears a `requestQuit`, for headless tests that drive a game's quit path
  ## more than once in one process.
  gQuit = false

proc quitRequested*(): bool =
  ## Whether `requestQuit` was called since the program started.
  gQuit

proc windowSize*(): tuple[width, height: int] =
  ## Current framebuffer size in pixels (already HiDPI-scaled).
  (gFbWidth, gFbHeight)

proc density*(): float =
  ## Framebuffer pixels per layout pixel, for renderers that lay things out
  ## in CSS/layout pixels and need to scale up for a sharp HiDPI framebuffer.
  gDensity

proc frameSizeCallback(window: GLFWWindow, width, height: int32) {.cdecl.} =
  gFbWidth = width.int
  gFbHeight = height.int

proc keyCallback(window: GLFWWindow, key, scancode, action, mods: int32) {.cdecl.} =
  # GLFWRepeat is ignored: a held key stays down without re-marking `justPressed`.
  if action == GLFWPress:
    keyDown(key.int)
  elif action == GLFWRelease:
    keyUp(key.int)

when not defined(emscripten):
  proc cursorPosCallback(window: GLFWWindow, xpos, ypos: float64) {.cdecl.} =
    ## The cursor in framebuffer pixels: GLFW reports window coordinates, which a
    ## HiDPI framebuffer has more of (the same ratio `density` holds).
    var winWidth, winHeight, fbWidth, fbHeight: int32
    window.getWindowSize(winWidth.addr, winHeight.addr)
    window.getFramebufferSize(fbWidth.addr, fbHeight.addr)
    if winWidth > 0 and winHeight > 0:
      pointerMove(int(xpos * float(fbWidth) / float(winWidth)),
                  int(ypos * float(fbHeight) / float(winHeight)))

  proc mouseButtonCallback(window: GLFWWindow, button, action, mods: int32) {.cdecl.} =
    if action == GLFWPress:
      buttonDown(button.int)
    elif action == GLFWRelease:
      buttonUp(button.int)

when defined(emscripten):
  {.emit: "#include <emscripten.h>".}
  proc emscripten_set_main_loop(f: proc() {.cdecl.}, fps: cint, simulateInfiniteLoop: bool) {.importc.}
  proc emscripten_cancel_main_loop() {.importc.}
  proc emscripten_get_canvas_element_size(target: cstring, width: ptr cint, height: ptr cint): cint {.importc.}
  proc emscripten_get_element_css_size(target: cstring, width: ptr float64, height: ptr float64): cint {.importc.}
  var canvasWidth, canvasHeight: cint
    ## The browser resizes the canvas via CSS, not GLFW, so the
    ## framebuffer-size callback never fires there; poll the canvas each
    ## frame and forward real changes (same shim as parasurvivors).

proc createWindow(title: string, width, height: int, visible: bool): GLFWWindow =
  ## GLFW started, a GL 3.3 core window made current, and `windowSize` /
  ## `density` set from it; nil when GLFW cannot start or make the window.
  if not glfwInit():
    return nil

  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFWTrue) # needed on Mac
  glfwWindowHint(GLFWOpenglProfile, GLFWOpenglCoreProfile)
  glfwWindowHint(GLFWResizable, GLFWTrue)
  if not visible:
    glfwWindowHint(GLFWVisible, GLFWFalse)

  result = glfwCreateWindow(int32 width, int32 height, title)
  if result == nil:
    glfwTerminate()
    return nil

  result.makeContextCurrent()

  var fbWidth, fbHeight: int32
  result.getFramebufferSize(fbWidth.addr, fbHeight.addr)
  var winWidth, winHeight: int32
  result.getWindowSize(winWidth.addr, winHeight.addr)
  gDensity = max(1.0, float(fbWidth) / float(winWidth))
  gFbWidth = fbWidth.int
  gFbHeight = fbHeight.int

proc openHeadlessWindow*(width = 1024, height = 768): GLFWWindow =
  ## A hidden window for drawing a game without showing it (`para shot`):
  ## its GL context is current and `windowSize()` is its framebuffer, so
  ## `init`, `stepTick` and `drawFrame` run as under `run`. Nil when GLFW
  ## cannot start (no display). Close it with `destroyWindow` then
  ## `glfwTerminate`.
  createWindow("paraloop headless", width, height, visible = false)

proc run*[G](game: sink G, title = "paraloop", width = 1024, height = 768) =
  ## Create the window, run `game.init()`, then drive `game.step(tick)` at a
  ## fixed 1/60s tick from a wall-clock accumulator and `game.draw(alpha)`
  ## once per frame -- natively in a `while` loop, or under `-d:emscripten`
  ## via the browser's own main loop. Window key events land in `engineKeys`
  ## for `step` to read, and each tick and frame go through `stepTick` and
  ## `drawFrame`.
  ##
  ## `run` takes ownership of `game`, so it may be a local in the caller's
  ## `main`: emscripten unwinds the caller's stack, and the loop keeps its own copy.
  gWindow = createWindow(title, width, height, visible = true)
  if gWindow == nil:
    quit(-1)

  when not defined(emscripten):
    # requestAnimationFrame already vsyncs, and the GLFW shim's swapInterval
    # only warns when called before emscripten_set_main_loop.
    glfwSwapInterval(1)

  discard gWindow.setFramebufferSizeCallback(frameSizeCallback)
  discard gWindow.setKeyCallback(keyCallback)
  when not defined(emscripten):
    discard gWindow.setCursorPosCallback(cursorPosCallback)
    discard gWindow.setMouseButtonCallback(mouseButtonCallback)

  # `{.global.}` turns these into per-instantiation statics rather than
  # locals `mainLoop` would need to close over: `emscripten_set_main_loop`
  # takes a plain `{.cdecl.}` function pointer, which can't carry a closure
  # environment.
  var loopGame {.global.}: G
  loopGame = move game
  loopGame.init()

  var clock {.global.}: Accumulator
  var lastTime {.global.}: float

  proc mainLoop() {.cdecl.} =
    let ts = glfwGetTime()
    let elapsed = ts - lastTime
    lastTime = ts
    when defined(emscripten):
      var w, h: cint
      if emscripten_get_canvas_element_size("#canvas", w.addr, h.addr) >= 0 and
          (w != canvasWidth or h != canvasHeight):
        canvasWidth = w
        canvasHeight = h
        # The shell sizes the framebuffer at devicePixelRatio for sharpness,
        # so divide it back out: the world is laid out in CSS pixels.
        var cssWidth, cssHeight: float64
        if emscripten_get_element_css_size("#canvas", cssWidth.addr, cssHeight.addr) >= 0 and cssWidth > 0:
          gDensity = max(1.0, float(w) / cssWidth)
        frameSizeCallback(gWindow, w, h)
    when defined(emscripten):
      if gQuit:
        emscripten_cancel_main_loop()
        return
    let ticks = clock.advance(elapsed)
    when defined(dev):
      let workStart = glfwGetTime()
    for i in 1 .. ticks:
      loopGame.stepTick(clock.tick - ticks + i)
    when defined(dev):
      if ticks > 0:
        recordStats(elapsed, (glfwGetTime() - workStart) / float(ticks))
    loopGame.drawFrame(clock.alpha())
    gWindow.swapBuffers()
    glfwPollEvents()

  clock = initAccumulator()
  lastTime = glfwGetTime()
  when defined(emscripten):
    emscripten_set_main_loop(mainLoop, 0, true)
  else:
    while not gWindow.windowShouldClose and not gQuit:
      mainLoop()

  gWindow.destroyWindow()
  glfwTerminate()
