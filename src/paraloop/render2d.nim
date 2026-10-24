# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
## 2D rendering for paraloop games: an instanced sprite batch per image sheet,
## a compile-time atlas manifest, text, flat-colour rects and a camera.
## Carried over from parasurvivors' `render.nim` and `data.nim` (report §3.3),
## minus the direct pararules `session` reads (R7): every proc here takes
## what it draws as parameters, so a game keeps its own state (in facts, in
## plain objects, wherever) and hands positions/colours/text to `add`/`draw`
## each frame. Nothing here imports `pararules` or `paraloop/sim`.
##
## Atlas manifest format
## ----------------------
## A small text format both a person and a future art-pack step (report A3)
## can produce: one `size` line, then one line per sprite.
##
##     size <atlasWidth> <atlasHeight>
##     <name> <x> <y> <w> <h>
##
## Fields are whitespace-separated integers; blank lines are ignored. `name`
## is the lower-cased enum value name (an enum `Icon = enum IconGem` names
## its manifest line `icongem`); pick enum names that read well lower-cased,
## since there is no prefix-stripping. Parse it inside a `const`, against the
## enum it fills and the PNG it describes:
##
##     type Icon = enum IconGem, IconHeart
##     const icons = parseAtlas(Icon, staticRead("assets/icons.txt"),
##                              staticRead("assets/icons.png"))
##
## so a manifest line naming a sprite outside the enum, an enum value with no
## line in the manifest, a sprite named twice, a missing or repeated `size`
## line, a `size` that differs from the PNG's own (IHDR) dimensions, or a
## rect that is empty or does not fit inside `size` is a **compile error**
## raised where the manifest is parsed, not a runtime surprise found later
## (task 1.5's acceptance).
##
## Batches
## -------
## `Sheet` wraps one loaded image plus its instanced draw batch: `addCell`
## crops a fixed-size grid cell (a walk-cycle sheet), `addRegion` crops an
## atlas rect (an icon, auto-sized from the rect's own aspect). Both queue an
## instance; `flush` draws every queued instance in one instanced call and
## empties the batch for the next frame. `RectBatch` is the same shape for
## flat-colour rects (HUD bars, panels, overlays). Load a `Sheet`/`RectBatch`
## once (in the game's `init`); `add*`/`flush` every `draw`.
##
## Text is simpler: there is no separate add/flush, `drawText` queues one
## string's glyphs and draws them in the same call, since each string can
## carry its own position, colour and scale.
##
## Pixel fonts
## -----------
## `loadFont` bakes ASCII 32..127 (so names and labels are ASCII-only,
## romanized) from any TTF into a 512x512 coverage atlas that is sampled
## with `GL_NEAREST`, never smoothed. A pixel TTF is crisp when the bake
## height is a whole multiple of its design pixel: every covered atlas texel
## is then fully on or off and every glyph metric is a whole number, so
## `drawText` at a whole-number `scale` lands each glyph pixel on exactly one
## screen pixel (`drawText` floors `x` and `y` itself, see `snapToPixel`). At
## any other height the rasteriser smears the pixel grid into grey texels (the
## blur this path exists to avoid).
## `fontCrispness(ttf, heightPx)` bakes headlessly (no GL context) and counts
## both failure modes; zero and zero is crisp.
##
## The vendored pixel font is Press Start 2P (`assets/PressStart2P-Regular.ttf`,
## SIL OFL 1.1, licence next to it in `assets/PressStart2P-OFL.txt`). Its
## design pixel is 1/8 em, so it is crisp at 8, 16, 24, 32... Bake it at 8 and
## draw at a whole-number `scale` for bigger text: each atlas pixel stays one
## whole block, and `textWidth(s, scale)` is exact. To use another pixel
## font, vendor it with its OFL/CC0 licence file, find its design pixel with
## `fontCrispness`, and bake at a multiple of that.
##
## Camera & zoom
## -------------
## A camera is a plain `Mat3x3[GLfloat]`: `flush`'s `invert(camera)` renders
## the world point at the camera's position at the screen origin, so
## `cameraAt(playerX - worldW / 2, playerY - worldH / 2)` keeps the player
## centred. `mat3f(1)` (re-exported from `paranim/glm`) is the identity
## camera for screen-space content (HUD, menus) -- passing it to `flush` is a
## no-op, not a special case. `zoomFor(windowHeight, referenceHeight)` keeps
## the vertical field of view constant across window sizes: a short (phone)
## window zooms out instead of just cropping the world. Feed it back into
## `flush` as world units, not screen pixels: `flush(sheet, game, windowWidth
## / zoom, windowHeight / zoom, camera)`, carried over from parasurvivors'
## `data.nim` and `rules.nim`. Pixel art that must not shimmer uses the integer
## variant instead: `snappedZoomFor` (the largest whole-number zoom at which the
## canvas fits the window) and `letterboxFor`/`applyLetterbox`/`resetLetterbox` (a fixed logical
## canvas centred at that zoom, black bars elsewhere), flushed at the logical
## extent -- e.g. 1080 and 2160 tall windows give 2x and 4x on a 540 canvas.

import paranim/opengl
import paranim/gl, paranim/gl/entities
import paranim/glm
import paranim/math as pmath
from paranim/primitives import nil
import paratext, paratext/gl/text
import stb_image/read as stbi
import std/[strutils, math]

export glm

# ---------------------------------------------------------------- atlas manifest

type
  Rect* = tuple[x, y, w, h: int]
  Atlas*[T: enum] = object
    size*: tuple[w, h: int]
    rects*: array[T, Rect]

proc manifestName[T: enum](s: T): string =
  toLowerAscii($s)

proc pngSize(png: string): tuple[w, h: int] =
  ## Width and height from a PNG's IHDR chunk (big-endian, bytes 16-23).
  doAssert png.len >= 24 and png[0 .. 7] == "\x89PNG\r\n\x1a\n" and png[12 .. 15] == "IHDR",
    "atlas image is not a PNG"
  proc be32(i: int): int =
    (ord(png[i]) shl 24) or (ord(png[i + 1]) shl 16) or (ord(png[i + 2]) shl 8) or ord(png[i + 3])
  (be32(16), be32(20))

proc parseAtlas*[T: enum](_: typedesc[T], manifest, png: string): Atlas[T] =
  ## Parse an atlas manifest (see the module doc for the format) against the
  ## sprite enum `T` and the PNG it describes (typically `staticRead`).
  ## Intended to run inside a `const`, so every failure here is a compile
  ## error.
  var seen: set[T]
  var sawSize = false
  for line in manifest.splitLines:
    let f = line.splitWhitespace
    if f.len == 0:
      continue
    if f[0] == "size":
      doAssert f.len == 3, "bad atlas manifest 'size' line: " & line
      doAssert not sawSize, "atlas manifest has more than one 'size' line: " & line
      sawSize = true
      result.size = (parseInt(f[1]), parseInt(f[2]))
      continue
    doAssert f.len == 5, "bad atlas manifest line: " & line
    var found = false
    for s in T:
      if manifestName(s) == f[0]:
        doAssert s notin seen, "atlas manifest names a sprite twice: \"" & f[0] & "\""
        result.rects[s] = (parseInt(f[1]), parseInt(f[2]), parseInt(f[3]), parseInt(f[4]))
        seen.incl s
        found = true
    doAssert found, "atlas manifest names an unknown sprite: \"" & f[0] & "\""
  doAssert sawSize, "atlas manifest has no 'size' line"
  let image = pngSize(png)
  doAssert result.size == image,
    "atlas manifest size " & $result.size.w & "x" & $result.size.h &
    " does not match the PNG's " & $image.w & "x" & $image.h
  for s in T:
    doAssert s in seen, "sprite missing from atlas manifest: " & manifestName(s)
  for s in T:
    let r = result.rects[s]
    doAssert r.w > 0 and r.h > 0,
      "atlas manifest rect for \"" & manifestName(s) & "\" has a non-positive size: " & $r
    doAssert r.x >= 0 and r.y >= 0 and r.x + r.w <= result.size.w and r.y + r.h <= result.size.h,
      "atlas manifest rect for \"" & manifestName(s) & "\" falls outside the " &
      $result.size.w & "x" & $result.size.h & " image: " & $r

# ---------------------------------------------------------------- sprite batches

type
  Sheet* = object
    frameW*, frameH*: int ## grid cell size in pixels; the whole image for a sheet only used via `addRegion`
    base: UncompiledImageEntity
    batch: InstancedImageEntity

proc clearBatch(b: var InstancedImageEntity) =
  b.attributes.a_matrix.data[].setLen(0)
  b.attributes.a_texture_matrix.data[].setLen(0)
  b.instanceCount = 0

proc initSheet*[G](game: var G, pixels: openArray[byte], width, height: int, frameW = 0, frameH = 0): Sheet =
  ## Compile an instanced batch from already-decoded RGBA pixels
  ## (`width * height * 4` bytes). `frameW`/`frameH` default to the whole
  ## image, for a sheet only ever cropped by `addRegion`.
  let base = initImageEntity(pixels, width, height)
  Sheet(frameW: (if frameW == 0: width else: frameW),
        frameH: (if frameH == 0: height else: frameH),
        base: base, batch: compile(game, initInstancedEntity(base)))

proc loadSheet*[G](game: var G, png: string, frameW = 0, frameH = 0): Sheet =
  ## Decode a PNG (typically `staticRead`) and compile its batch.
  var width, height, channels: int
  let data = stbi.loadFromMemory(cast[seq[uint8]](png), width, height, channels, stbi.RGBA)
  initSheet(game, data, width, height, frameW, frameH)

proc isEmpty*(sheet: Sheet): bool =
  sheet.batch.attributes.a_matrix.data[].len == 0

proc clear*(sheet: var Sheet) =
  clearBatch(sheet.batch)

proc addCell*(sheet: var Sheet, col, row: int, cx, cy, w, h: float, flip = false) =
  ## Queue one `frameW x frameH` grid cell, centred at `(cx, cy)` and scaled
  ## to `w x h`. `flip` mirrors it left-right (a character facing left).
  var e = sheet.base
  let fw = GLfloat(sheet.frameW)
  let fh = GLfloat(sheet.frameH)
  e.crop(GLfloat(col) * fw, GLfloat(row) * fh, fw, fh)
  if flip:
    e.translate(GLfloat(cx) + GLfloat(w) / 2, GLfloat(cy) - GLfloat(h) / 2)
    e.scale(-GLfloat(w), GLfloat(h))
  else:
    e.translate(GLfloat(cx) - GLfloat(w) / 2, GLfloat(cy) - GLfloat(h) / 2)
    e.scale(GLfloat(w), GLfloat(h))
  sheet.batch.add(e)

proc placeRotated*[U, A](e: var Entity[U, A], cx, cy, w, h, angle: float) =
  ## Put the unit quad of `e` at `w x h`, centred at `(cx, cy)`, turned by
  ## `angle` radians about its centre. `angle` is the screen angle of the
  ## quad's +x edge on the y-down canvas (clockwise-positive), so
  ## `arctan2(dy, dx)` of a screen vector draws along that vector.
  ## paranim's `rotate` turns +x toward screen-up on this canvas, hence the
  ## negation: this is the one place that convention is fixed.
  e.translate(GLfloat(cx), GLfloat(cy))
  if angle != 0.0:
    e.rotate(GLfloat(-angle))
  e.translate(-GLfloat(w) / 2, -GLfloat(h) / 2)
  e.scale(GLfloat(w), GLfloat(h))

proc addRegion*(sheet: var Sheet, r: Rect, cx, cy, w: float, angle = 0.0) =
  ## Queue an atlas icon: the rect `r` cropped from the sheet, centred at
  ## `(cx, cy)`, `w` wide with height taken from the rect's own aspect.
  ## `angle` is radians, the screen angle of the +x edge with y down
  ## (clockwise-positive), so `arctan2(dy, dx)` of a screen vector draws
  ## along that vector.
  let h = w * float(r.h) / float(r.w)
  var e = sheet.base
  e.crop(GLfloat(r.x), GLfloat(r.y), GLfloat(r.w), GLfloat(r.h))
  e.placeRotated(cx, cy, w, h, angle)
  sheet.batch.add(e)

proc flush*[G](sheet: var Sheet, game: G, ww, wh: float, camera: Mat3x3[GLfloat]) =
  ## Draw every queued instance in one call and empty the batch. Pass
  ## `mat3f(1)` as `camera` for screen-space content.
  if sheet.isEmpty:
    return
  var b = sheet.batch
  b.project(GLfloat ww, GLfloat wh)
  b.invert(camera)
  render(game, b)
  clearBatch(sheet.batch)

# ---------------------------------------------------------------- rects

type
  RectBatch* = object
    base: UncompiledTwoDEntity
    batch: InstancedTwoDEntity

proc clearBatch(b: var InstancedTwoDEntity) =
  b.attributes.a_matrix.data[].setLen(0)
  b.attributes.a_color.data[].setLen(0)
  b.instanceCount = 0

proc initRectBatch*[G](game: var G): RectBatch =
  let base = initTwoDEntity(primitives.rectangle[GLfloat]())
  RectBatch(base: base, batch: compile(game, initInstancedEntity(base)))

proc isEmpty*(batch: RectBatch): bool =
  batch.batch.attributes.a_matrix.data[].len == 0

proc clear*(batch: var RectBatch) =
  clearBatch(batch.batch)

proc addRect*(batch: var RectBatch, cx, cy, w, h, angle: float, color: Vec4[GLfloat]) =
  ## Queue a flat-colour `w x h` rect centred at `(cx, cy)`. `angle` is
  ## radians, the screen angle of the +x edge with y down (clockwise-positive),
  ## so `arctan2(dy, dx)` of a screen vector draws along that vector.
  var e = batch.base
  e.placeRotated(cx, cy, w, h, angle)
  e.color(color)
  batch.batch.add(e)

proc flush*[G](batch: var RectBatch, game: G, ww, wh: float, camera: Mat3x3[GLfloat]) =
  if batch.isEmpty:
    return
  var b = batch.batch
  b.project(GLfloat ww, GLfloat wh)
  b.invert(camera)
  render(game, b)
  clearBatch(batch.batch)

# ---------------------------------------------------------------- text

const
  fontFirstChar = 32
  fontCharCount = 96 ## ASCII 32..127
  fontBitmapSize = 512

type
  TextBatch* = object
    font: BakedFont[fontCharCount]
    base: UncompiledTextEntity
    batch: InstancedTextEntity

proc clearBatch(b: var InstancedTextEntity) =
  b.attributes.a_translate_matrix.data[].setLen(0)
  b.attributes.a_scale_matrix.data[].setLen(0)
  b.attributes.a_texture_matrix.data[].setLen(0)
  b.attributes.a_color.data[].setLen(0)
  b.instanceCount = 0

proc loadFont*[G](game: var G, ttf: string, heightPx: float): TextBatch =
  ## Bake a TTF (typically `staticRead`) at `heightPx` and compile its batch.
  let font = initFont(ttf = ttf, fontHeight = GLfloat heightPx, firstChar = cint fontFirstChar,
                       bitmapWidth = fontBitmapSize, bitmapHeight = fontBitmapSize, charCount = fontCharCount)
  let base = initTextEntity(font)
  TextBatch(font: font, base: base, batch: compile(game, initInstancedEntity(base)))

proc fontCrispness*(ttf: string, heightPx: float): tuple[partialTexels, fractionalMetrics: int] =
  ## Bake `ttf` at `heightPx` exactly as `loadFont` does (no GL context
  ## needed) and count what keeps text from being crisp: atlas texels that are
  ## neither fully off nor fully on (`partialTexels`: anti-aliased edges), and
  ## per-glyph metrics (`xoff`, `yoff`, `xadvance`) or the baseline that are
  ## not whole numbers (`fractionalMetrics`: glyphs drawn between screen
  ## pixels). A crisp pixel font at this size reports `(0, 0)`.
  let font = initFont(ttf = ttf, fontHeight = GLfloat heightPx, firstChar = cint fontFirstChar,
                       bitmapWidth = fontBitmapSize, bitmapHeight = fontBitmapSize, charCount = fontCharCount)
  for v in font.bitmap.data:
    if v != 0 and v != 255:
      inc result.partialTexels
  template whole(x: float): bool = x == float(int(x + (if x < 0: -0.5 else: 0.5)))
  if not whole(font.baseline):
    inc result.fractionalMetrics
  for c in font.chars:
    for m in [c.xoff, c.yoff, c.xadvance]:
      if not whole(m):
        inc result.fractionalMetrics

proc textWidth*(t: TextBatch, s: string, scale = 1.0): float =
  for ch in s:
    let idx = int(ch) - t.font.firstChar
    if idx >= 0 and idx < fontCharCount:
      result += t.font.chars[idx].xadvance * scale

proc snapToPixel*(v: float): float =
  ## Floor `v` to a whole screen pixel: `drawText` applies it to `x` and `y`
  ## so a fractional position (half a window width, say) never straddles
  ## texels.
  floor(v)

proc drawText*[G](t: var TextBatch, game: G, s: string, x, y, ww, wh: float,
                   color = vec4(1f, 1f, 1f, 1f), scale = 1.0) =
  ## Queue `s`'s glyphs at `(x, y)` in screen space and draw them immediately
  ## -- there is no separate `flush`, since each string carries its own
  ## position, colour and scale.
  clearBatch(t.batch)
  var cx = 0f
  for ch in s:
    let idx = int(ch) - t.font.firstChar
    if idx < 0 or idx >= fontCharCount:
      continue
    let bc = t.font.chars[idx]
    var e = t.base
    e.crop(bc, cx, t.font.baseline)
    e.color(color)
    t.batch.add(e)
    cx += bc.xadvance
  if cx == 0:
    return
  var b = t.batch # a copy: project/translate/scale must not stick to the stored batch
  b.project(GLfloat ww, GLfloat wh)
  b.translate(GLfloat snapToPixel(x), GLfloat snapToPixel(y))
  b.scale(GLfloat scale, GLfloat scale)
  render(game, b)

# ---------------------------------------------------------------- camera & zoom

proc cameraAt*(x, y: float): Mat3x3[GLfloat] =
  ## A camera positioned at the world point `(x, y)`: `flush`'s `invert`
  ## renders an entity there at the screen origin (top-left), so a follow
  ## camera passes `cameraAt(playerX - worldW / 2, playerY - worldH / 2)` to
  ## keep the player centred (`worldW`/`worldH` the world units visible, i.e.
  ## the same `ww`/`wh` passed to `flush`).
  result = mat3f(1)
  pmath.translate(result, GLfloat x, GLfloat y)

proc zoomFor*(windowHeight: int, referenceHeight: float, maxZoom = 1.0, minZoom = 0.4): float =
  ## Screen pixels per world unit for a window `windowHeight` pixels tall,
  ## holding the vertical field of view constant at `referenceHeight`: a
  ## short (phone) window zooms out and sees more world instead of seeing a
  ## cropped version of a desktop's view, which would make the game harder
  ## rather than just smaller. Never above `maxZoom`, so windows at or above
  ## the reference height are unaffected.
  max(minZoom, min(maxZoom, float(windowHeight) / referenceHeight))

type Letterbox* = object
  ## Where a fixed-size logical canvas lands in a window: `zoom` screen pixels
  ## per logical pixel, and the pixel rectangle (`x`/`y` from the framebuffer's
  ## bottom-left, as `glViewport` takes it) the canvas fills. The rest of the
  ## window is the letterbox (or pillarbox) bars.
  zoom*: float
  x*, y*, w*, h*: int

proc snappedZoomFor*(windowWidth, windowHeight: int, referenceWidth, referenceHeight: float,
                     maxZoom = 8): int =
  ## The integer sibling of `zoomFor` for hi-bit pixel art: the largest whole
  ## number of screen pixels per world unit that keeps the whole
  ## `referenceWidth` x `referenceHeight` canvas inside the window, so a sprite
  ## never lands between pixels (no shimmer). Both dimensions limit it: on a
  ## 540 tall reference a 1080 tall window gives 2 and a 2160 tall one gives 4
  ## when wide enough, while a narrower window drops to the zoom its width
  ## allows. At least 1 (an integer zoom cannot go below it; `letterboxFor`
  ## falls back to a fractional fit under 1x), at most `maxZoom`.
  let fit = min(float(windowWidth) / referenceWidth, float(windowHeight) / referenceHeight)
  max(1, min(maxZoom, int(fit)))

proc letterboxFor*(windowWidth, windowHeight: int, referenceWidth, referenceHeight: float,
                   maxZoom = 8): Letterbox =
  ## Fits a `referenceWidth` x `referenceHeight` canvas into the window at an
  ## integer zoom, centred, with bars around it: `applyLetterbox` points the
  ## viewport at the result, then everything flushes with `referenceWidth` /
  ## `referenceHeight` as the world extent (the canvas is that many logical
  ## pixels however big the window is).
  ## The zoom is `snappedZoomFor` (a wide window pillarboxes, a short one
  ## letterboxes). A window smaller than the canvas has no whole zoom that
  ## fits, so it takes the fractional fit (the same field of view, smaller
  ## pixels) instead of cropping.
  let fit = min(float(windowWidth) / referenceWidth, float(windowHeight) / referenceHeight)
  let zoom = if fit < 1.0: fit
             else: float(snappedZoomFor(windowWidth, windowHeight, referenceWidth, referenceHeight, maxZoom))
  let w = int(referenceWidth * zoom)
  let h = int(referenceHeight * zoom)
  Letterbox(zoom: zoom, x: (windowWidth - w) div 2, y: (windowHeight - h) div 2, w: w, h: h)

func screenToWorld*(lb: Letterbox, fbHeight: int, originX, originY: float,
                    px, py: int): tuple[x, y: float] =
  ## The inverse of the letterbox and the camera: the world point under the
  ## framebuffer pixel (`px`, `py`), measured from the window's top-left as the
  ## cursor is. `lb` is the `letterboxFor` the frame was drawn with, `fbHeight`
  ## the framebuffer's height (the letterbox's `y` runs from the bottom, as
  ## `glViewport` takes it), and (`originX`, `originY`) the world point at the
  ## canvas's top-left corner: the camera position less half the canvas when the
  ## world is drawn at `canvas / 2 + position`. A pixel in the bars maps to a
  ## point outside the canvas, not an error.
  let canvasTop = fbHeight - lb.y - lb.h
  (x: originX + float(px - lb.x) / lb.zoom, y: originY + float(py - canvasTop) / lb.zoom)

proc applyLetterbox*(lb: Letterbox, windowWidth, windowHeight: int) =
  ## Needs a current GL context. Clears the whole window black for the bars,
  ## then points the viewport and scissor at the canvas so everything drawn
  ## after lands inside it (a world-space sprite past the canvas edge is cut
  ## off, not painted over a bar). Clear the canvas itself after this call.
  glDisable(GL_SCISSOR_TEST)
  glViewport(0, 0, GLsizei windowWidth, GLsizei windowHeight)
  glClearColor(0.0, 0.0, 0.0, 1.0)
  glClear(GL_COLOR_BUFFER_BIT)
  glViewport(GLint lb.x, GLint lb.y, GLsizei lb.w, GLsizei lb.h)
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint lb.x, GLint lb.y, GLsizei lb.w, GLsizei lb.h)

proc resetLetterbox*(windowWidth, windowHeight: int) =
  ## Pairs with `applyLetterbox`: back to the full window with no scissor, so
  ## anything drawn after the game's `draw` (the F3 overlay) is not squeezed
  ## into or clipped by the canvas rectangle.
  glDisable(GL_SCISSOR_TEST)
  glViewport(0, 0, GLsizei windowWidth, GLsizei windowHeight)
