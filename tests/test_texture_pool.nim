# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Texture-unit pool (patches/paranim/gl.nim): paranim used to give every
# texture its own never-reused GL texture unit, so a game with more textures
# than the device has units (WebGL2 guarantees 32; one game has 182) drew
# solid blocks and black squares. The pool arithmetic is pure and runs
# anywhere; the draw checks need a real, hidden GL context (same display guard
# as test_render2d.nim).

import unittest
import std/os
import paranim/glfw
import paranim/gl
import paranim/opengl
import paranim/math as pmath
import paraloop/render2d

static: doAssert declared(texturePoolSizeFor),
  "patches/paranim/gl.nim is not applied; check patchFile in config.nims"

suite "texture pool: size":
  test "the default pool fits the 32 units WebGL2 guarantees":
    check defaultTexturePoolSize <= 32
    check defaultTexturePoolSize >= 1

  test "a roomy device gets the default pool":
    check texturePoolSizeFor(192) == defaultTexturePoolSize
    check texturePoolSizeFor(64) == defaultTexturePoolSize
    check texturePoolSizeFor(32) == defaultTexturePoolSize

  test "a device with fewer units than the default caps the pool":
    check texturePoolSizeFor(8) == 8
    check texturePoolSizeFor(2) == 2
    check texturePoolSizeFor(8, wanted = 4) == 4

  test "a device that reports nothing still leaves one unit":
    check texturePoolSizeFor(0) == 1
    check texturePoolSizeFor(-1) == 1

# ---------------------------------------------------------------- draws

type TestGame = object of RootGame

const
  winSize = 64
  textures = 40
    ## More than the default pool (16) and than WebGL2's 32 guaranteed units.

proc newHiddenWindow(): GLFWWindow =
  doAssert glfwInit()
  glfwWindowHint(GLFWContextVersionMajor, 3)
  glfwWindowHint(GLFWContextVersionMinor, 3)
  glfwWindowHint(GLFWOpenglForwardCompat, GLFWTrue)
  glfwWindowHint(GLFWOpenglProfile, GLFWOpenglCoreProfile)
  glfwWindowHint(GLFWVisible, GLFWFalse)
  result = glfwCreateWindow(winSize, winSize, "paraloop texture pool test")
  doAssert result != nil
  result.makeContextCurrent()
  doAssert glInit()

type Rgb = tuple[r, g, b: byte]

proc colorOf(i: int): Rgb =
  ## Distinct per texture, so a draw that samples the wrong texture is seen.
  (r: byte(10 + i * 5), g: byte(250 - i * 6), b: byte(20 + i * 3))

proc solid(c: Rgb): seq[byte] =
  for _ in 0 ..< 4 * 4:
    result.add [c.r, c.g, c.b, 255'u8]

proc drawn(game: TestGame, sheet: var Sheet): Rgb =
  ## Draw `sheet` over the whole window and read the centre pixel back.
  glClearColor(0f, 0f, 0f, 1f)
  glClear(GL_COLOR_BUFFER_BIT)
  sheet.addCell(0, 0, winSize / 2, winSize / 2, winSize.float, winSize.float)
  sheet.flush(game, winSize.float, winSize.float, mat3f(1))
  var px: array[4, byte]
  glReadPixels(winSize div 2, winSize div 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px.addr)
  (r: px[0], g: px[1], b: px[2])

proc boundOnUnit0(): GLuint =
  ## The texture the last draw left on pool unit 0 (a sheet's batch is
  ## private, and the unit is what a draw binds to).
  glActiveTexture(GL_TEXTURE0)
  var name: GLint
  glGetIntegerv(GL_TEXTURE_BINDING_2D, name.addr)
  GLuint(name)

suite "texture pool: draws on a real context":
  # one window for the suite: a second glfwInit/glfwTerminate round is not
  # what is under test
  let haveDisplay = existsEnv("DISPLAY")
  let win = if haveDisplay: newHiddenWindow() else: nil

  test "more textures than the pool each draw their own image, in any order":
    if not haveDisplay:
      skip()
    else:
      var game = TestGame()
      var sheets: seq[Sheet]
      for i in 0 ..< textures:
        sheets.add initSheet(game, solid(colorOf(i)), 4, 4)
      check game.texCount == textures
      check textures > texturePoolSize()

      # forward, backward and strided: after the pool wraps every texture
      # still samples its own image, not whatever shared its unit last
      var order: seq[int]
      for i in 0 ..< textures: order.add i
      for i in countdown(textures - 1, 0): order.add i
      for stride in [7, 13]:
        for k in 0 ..< textures: order.add (k * stride) mod textures
      for i in order:
        check game.drawn(sheets[i]) == colorOf(i)

      # nothing sits on a unit past the pool, and no GL error was raised
      var deviceUnits: GLint
      glGetIntegerv(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, deviceUnits.addr)
      for unit in texturePoolSize() ..< min(int(deviceUnits), textures):
        glActiveTexture(GLenum(GL_TEXTURE0.ord + unit))
        var bound: GLint
        glGetIntegerv(GL_TEXTURE_BINDING_2D, bound.addr)
        check bound == 0
      check glGetError() == GL_NO_ERROR

  test "a texture re-uploaded or deleted behind the engine's back still draws right":
    if not haveDisplay:
      skip()
    else:
      var game = TestGame()
      var sheets: seq[Sheet]
      for i in 0 ..< 4:
        sheets.add initSheet(game, solid(colorOf(i)), 4, 4)
      for i in 0 ..< 4:
        check game.drawn(sheets[i]) == colorOf(i)

      # re-upload sheet 1 through raw GL, on a unit that is not the pool's
      let fresh = colorOf(30)
      var pixels = solid(fresh)
      check game.drawn(sheets[1]) == colorOf(1)
      let name = boundOnUnit0()
      glActiveTexture(GLenum(GL_TEXTURE0.ord + 5))
      glBindTexture(GL_TEXTURE_2D, name)
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 4, 4, GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)
      check game.drawn(sheets[1]) == fresh

      # delete sheet 2's texture: the sheets that follow must not see it
      check game.drawn(sheets[2]) == colorOf(2)
      var gone = boundOnUnit0()
      glDeleteTextures(1, gone.addr)
      for i in [0, 3, 1, 0]:
        check game.drawn(sheets[i]) == (if i == 1: fresh else: colorOf(i))
      check glGetError() == GL_NO_ERROR

  test "the window closes":
    if haveDisplay:
      win.destroyWindow()
      glfwTerminate()
    else:
      skip()
