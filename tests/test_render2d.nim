# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Headless tests for paraloop/render2d: the compile-time atlas manifest, and
# (when a display is available, same guard as test_app.nim) the sprite/rect/
# text batches against a real, hidden GL context.

import unittest
import std/[os, osproc, strutils]
import paranim/glfw
import paranim/gl
import paranim/opengl
import paranim/math as pmath
import paraloop/render2d
import stb_image/read as stbi
import examples/hello/hello as hello

const fixturesDir = currentSourcePath().parentDir / "fixtures" / "render2d"
const repoRoot = currentSourcePath().parentDir.parentDir

proc checkFixture(name: string): tuple[ok: bool, output: string] =
  ## Runs `nim check` against a fixture .nim file and reports whether it
  ## compiled. Fixtures under fixtures/render2d/ that call `parseAtlas` with
  ## a bad manifest are expected to fail here -- that failure *is* the
  ## compile error task 1.5 requires.
  let cmd = "nim check --hints:off --path:" & quoteShell(repoRoot / "src") & " " &
            quoteShell(fixturesDir / (name & ".nim"))
  let (output, exitCode) = execCmdEx(cmd)
  (exitCode == 0, output)

suite "render2d: atlas manifest":
  test "a manifest matching its enum exactly compiles clean":
    let (ok, output) = checkFixture("ok_atlas")
    check ok
    if not ok: echo output

  test "hello's real atlas parses at compile time and every rect fits inside its image":
    var w, h, channels: int
    discard stbi.load(repoRoot / "examples" / "hello" / "assets" / "icons.png", w, h, channels, stbi.RGBA)
    check hello.icons.size == (w: w, h: h)
    check hello.icons.size == (w: 64, h: 32)
    check hello.icons.rects[hello.IconRed] == (x: 4, y: 4, w: 24, h: 24)
    check hello.icons.rects[hello.IconBlue] == (x: 36, y: 4, w: 24, h: 24)
    for r in [hello.icons.rects[hello.IconRed], hello.icons.rects[hello.IconBlue]]:
      check r.x >= 0 and r.y >= 0
      check r.x + r.w <= hello.icons.size.w
      check r.y + r.h <= hello.icons.size.h

  test "an enum value missing from the manifest is a compile error":
    let (ok, output) = checkFixture("missing_sprite")
    check not ok
    check "sprite missing from atlas manifest: b" in output

  test "a manifest name outside the enum is a compile error":
    let (ok, output) = checkFixture("unknown_name")
    check not ok
    check "atlas manifest names an unknown sprite: \"c\"" in output

  test "a rect that falls outside the image is a compile error":
    let (ok, output) = checkFixture("out_of_bounds")
    check not ok
    check "falls outside the 10x10 image" in output

  test "a manifest size that differs from the PNG's is a compile error":
    let (ok, output) = checkFixture("size_mismatch")
    check not ok
    check "atlas manifest size 12x10 does not match the PNG's 10x10" in output

  test "a missing or repeated size line is a compile error":
    let (missingOk, missingOutput) = checkFixture("missing_size")
    check not missingOk
    check "atlas manifest has no 'size' line" in missingOutput
    let (dupOk, dupOutput) = checkFixture("duplicate_size")
    check not dupOk
    check "atlas manifest has more than one 'size' line" in dupOutput

  test "a zero or negative rect size is a compile error":
    for name in ["empty_rect", "negative_rect"]:
      let (ok, output) = checkFixture(name)
      check not ok
      check "atlas manifest rect for \"b\" has a non-positive size" in output

  test "a sprite named twice is a compile error":
    let (ok, output) = checkFixture("duplicate_sprite")
    check not ok
    check "atlas manifest names a sprite twice: \"a\"" in output

suite "render2d: camera & zoom":
  test "cameraAt positions the camera so an entity there renders at the origin":
    # `flush` does `entity.invert(camera)`, i.e. `entity.matrix = inverse(camera) * entity.matrix`.
    # An entity translated to the camera's own position must cancel out to identity.
    let camera = cameraAt(10.0, 20.0)
    var m = mat3f(1)
    pmath.translate(m, 10f, 20f)
    pmath.invert(m, camera)
    check m == mat3f(1)

  test "zoomFor holds the reference height and clamps at both ends":
    check zoomFor(768, 768.0) == 1.0
    check zoomFor(384, 768.0) == 0.5
    check zoomFor(100, 768.0) == 0.4 # minZoom floor
    check zoomFor(2000, 768.0) == 1.0 # maxZoom ceiling

  test "snappedZoomFor gives 2x at 1080 and 4x at 2160 on a 540 reference":
    check snappedZoomFor(1920, 1080, 960.0, 540.0) == 2
    check snappedZoomFor(3840, 2160, 960.0, 540.0) == 4
    check snappedZoomFor(960, 540, 960.0, 540.0) == 1

  test "snappedZoomFor floors between whole zooms and clamps at both ends":
    check snappedZoomFor(1920, 1079, 960.0, 540.0) == 1
    check snappedZoomFor(2880, 1619, 960.0, 540.0) == 2 # 2.998x
    check snappedZoomFor(2880, 1620, 960.0, 540.0) == 3
    check snappedZoomFor(300, 200, 960.0, 540.0) == 1 # no integer zoom below 1
    check snappedZoomFor(20_000, 10_000, 960.0, 540.0) == 8 # maxZoom ceiling
    check snappedZoomFor(20_000, 10_000, 960.0, 540.0, maxZoom = 4) == 4

  test "snappedZoomFor is limited by the narrower dimension":
    check snappedZoomFor(1000, 1080, 960.0, 540.0) == 1 # width allows 1.04x
    check snappedZoomFor(2560, 1080, 960.0, 540.0) == 2 # height limits
    check snappedZoomFor(3839, 2160, 960.0, 540.0) == 3 # width allows 3.99x

  test "letterboxFor fills a 16:9 window exactly at whole zooms":
    let at1080 = letterboxFor(1920, 1080, 960.0, 540.0)
    check at1080 == Letterbox(zoom: 2.0, x: 0, y: 0, w: 1920, h: 1080)
    let at2160 = letterboxFor(3840, 2160, 960.0, 540.0)
    check at2160 == Letterbox(zoom: 4.0, x: 0, y: 0, w: 3840, h: 2160)

  test "letterboxFor centres the canvas with bars at other sizes":
    # 1080 tall but wide: 2x canvas, pillarbox left and right.
    check letterboxFor(2560, 1080, 960.0, 540.0) == Letterbox(zoom: 2.0, x: 320, y: 0, w: 1920, h: 1080)
    # 1440 tall (2.67x): stays at 2x, bars all round.
    check letterboxFor(2560, 1440, 960.0, 540.0) == Letterbox(zoom: 2.0, x: 320, y: 180, w: 1920, h: 1080)
    # 1080 tall but narrow: the width limits the zoom, so letterbox top and bottom.
    check letterboxFor(1000, 1080, 960.0, 540.0) == Letterbox(zoom: 1.0, x: 20, y: 270, w: 960, h: 540)
    # The shipped default 1024x768 window.
    check letterboxFor(1024, 768, 960.0, 540.0) == Letterbox(zoom: 1.0, x: 32, y: 114, w: 960, h: 540)

  test "letterboxFor falls back to a fractional fit under the canvas size":
    let lb = letterboxFor(480, 270, 960.0, 540.0)
    check lb == Letterbox(zoom: 0.5, x: 0, y: 0, w: 480, h: 270)
    let tall = letterboxFor(480, 400, 960.0, 540.0)
    check tall.zoom == 0.5
    check tall.w == 480 and tall.h == 270 and tall.y == 65

  test "the letterbox never leaves the window and is centred, over a sweep of sizes":
    for h in countup(100, 2400, 37):
      for w in countup(100, 4000, 113):
        let lb = letterboxFor(w, h, 960.0, 540.0)
        check lb.x >= 0 and lb.y >= 0
        check lb.x + lb.w <= w and lb.y + lb.h <= h
        check abs((w - lb.w) - 2 * lb.x) <= 1 and abs((h - lb.h) - 2 * lb.y) <= 1
        if lb.zoom >= 1.0:
          check lb.zoom == float(snappedZoomFor(w, h, 960.0, 540.0))

  test "screenToWorld is the inverse of the letterbox and the camera, pinned against letterboxFor":
    # The canvas's corners and centre map to the world points drawn there, whole zoom or not.
    # The cursor runs from the window's top-left; the letterbox's y from the bottom.
    for (w, h) in [(960, 540), (1920, 1080), (2560, 1440), (1024, 768), (480, 270), (480, 400)]:
      let lb = letterboxFor(w, h, 960.0, 540.0)
      let top = h - lb.y - lb.h
      let origin = (x: 1000.0, y: -200.0) # the world point at the canvas's top-left
      let topLeft = screenToWorld(lb, h, origin.x, origin.y, lb.x, top)
      check topLeft == origin
      let bottomRight = screenToWorld(lb, h, origin.x, origin.y, lb.x + lb.w, top + lb.h)
      check abs(bottomRight.x - (origin.x + 960.0)) < 1e-6
      check abs(bottomRight.y - (origin.y + 540.0)) < 1e-6
      let mid = screenToWorld(lb, h, origin.x, origin.y, lb.x + lb.w div 2, top + lb.h div 2)
      check abs(mid.x - (origin.x + 480.0)) < 1e-6
      check abs(mid.y - (origin.y + 270.0)) < 1e-6

  test "screenToWorld at zoom 1 is the pixel less the bars, at zoom 2 half of it":
    let one = letterboxFor(1024, 768, 960.0, 540.0) # bars: x 32, y 114
    check screenToWorld(one, 768, 0.0, 0.0, 32 + 480, 114 + 300) == (480.0, 300.0)
    check screenToWorld(one, 768, 100.0, 50.0, 32, 114) == (100.0, 50.0)
    let two = letterboxFor(1920, 1080, 960.0, 540.0)
    check screenToWorld(two, 1080, 0.0, 0.0, 960, 600) == (480.0, 300.0)
    check screenToWorld(two, 1080, 0.0, 0.0, 961, 601) == (480.5, 300.5)

  test "screenToWorld on a fractional fit scales back up, and a bar pixel lands off the canvas":
    let half = letterboxFor(480, 270, 960.0, 540.0)
    check screenToWorld(half, 270, 0.0, 0.0, 240, 135) == (480.0, 270.0)
    let tall = letterboxFor(480, 400, 960.0, 540.0) # bars above and below (65 px)
    check screenToWorld(tall, 400, 0.0, 0.0, 0, 65) == (0.0, 0.0)
    check screenToWorld(tall, 400, 0.0, 0.0, 0, 0).y == -130.0

# ---------------------------------------------------------------- pixel font

suite "render2d: pixel font":
  let pixelTtf = readFile(repoRoot / "src" / "paraloop" / "assets" / "PressStart2P-Regular.ttf")
  let smoothTtf = readFile(repoRoot / "src" / "paraloop" / "assets" / "Roboto-Regular.ttf")

  test "the vendored pixel font is crisp at whole multiples of its 8px design pixel":
    for h in [8.0, 16.0, 24.0, 32.0]:
      check fontCrispness(pixelTtf, h) == (partialTexels: 0, fractionalMetrics: 0)

  test "the same font blurs off its pixel grid":
    # 12 px is 1.5 design pixels per em-eighth: edges land between texels.
    check fontCrispness(pixelTtf, 12.0).partialTexels > 0

  test "an outline font is never crisp (the check can fail)":
    let c = fontCrispness(smoothTtf, 24.0)
    check c.partialTexels > 0
    check c.fractionalMetrics > 0

  test "snapToPixel floors fractional positions to whole pixels":
    check snapToPixel(512.5) == 512.0
    check snapToPixel(384.0) == 384.0
    check snapToPixel(-0.5) == -1.0

# ---------------------------------------------------------------- batches

type TestGame = object of RootGame

proc newHiddenWindow(): GLFWWindow =
  doAssert glfwInit()
  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFWTrue)
  glfwWindowHint(GLFWOpenglProfile, GLFWOpenglCoreProfile)
  glfwWindowHint(GLFWVisible, GLFWFalse)
  result = glfwCreateWindow(64, 64, "paraloop render2d test")
  doAssert result != nil
  result.makeContextCurrent()
  doAssert glInit()

suite "render2d: batches":
  test "sheets, rects and text compile, queue, draw and clear":
    if not existsEnv("DISPLAY"):
      skip()
    else:
      let win = newHiddenWindow()
      var game = TestGame()

      var pixels: seq[byte]
      for _ in 0 ..< 4 * 4:
        pixels.add(255); pixels.add(0); pixels.add(0); pixels.add(255)
      var sheet = initSheet(game, pixels, 4, 4)
      check sheet.isEmpty
      sheet.addCell(0, 0, 32, 32, 8, 8)
      check not sheet.isEmpty
      sheet.flush(game, 64.0, 64.0, mat3f(1))
      check sheet.isEmpty # flush empties the batch

      var rects = initRectBatch(game)
      check rects.isEmpty
      rects.addRect(32, 32, 10, 10, 0, vec4(1f, 0f, 0f, 1f))
      check not rects.isEmpty
      rects.flush(game, 64.0, 64.0, mat3f(1))
      check rects.isEmpty

      let ttf = readFile(repoRoot / "src" / "paraloop" / "assets" / "Roboto-Regular.ttf")
      var text = loadFont(game, ttf, 12.0)
      check textWidth(text, "") == 0.0
      check textWidth(text, "hi") > 0.0
      check textWidth(text, "hiii") > textWidth(text, "hi")
      text.drawText(game, "hi", 4.0, 4.0, 64.0, 64.0) # must not crash

      win.destroyWindow()
      glfwTerminate()
