# A synthetic "AI-looking" degradation of a real sprite, built in code so
# the regression test (asset pipeline report §6.3, §9 row A2) never commits
# new art: flatten onto a flat key colour, nearest-neighbour upscale by an
# integer factor, bilinear-downscale to a *non-integer* final size (the
# report's own method: "8.08x non-integer upscale"), then a few box-blur
# passes stand in for the report's Gaussian blur and JPEG softening. Pure
# Nim (no ImageMagick/PIL dependency) so `para art fix`'s own Python side is
# the only thing under test.

import std/math

proc flattenOnBg*(rgba: seq[byte], w, h: int, bg: (byte, byte, byte)): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for i in 0 ..< w * h:
    let a = rgba[i * 4 + 3].float / 255.0
    let src = [rgba[i * 4].float, rgba[i * 4 + 1].float, rgba[i * 4 + 2].float]
    let bgArr = [bg[0].float, bg[1].float, bg[2].float]
    for c in 0 .. 2:
      let v = src[c] * a + bgArr[c] * (1.0 - a)
      result[i * 4 + c] = clamp(v.round.int, 0, 255).byte
    result[i * 4 + 3] = 255

proc nearestUpscale*(src: seq[byte], sw, sh, factor: int): tuple[pixels: seq[byte], w, h: int] =
  let dw = sw * factor
  let dh = sh * factor
  var dst = newSeq[byte](dw * dh * 4)
  for dy in 0 ..< dh:
    let sy = dy div factor
    for dx in 0 ..< dw:
      let sx = dx div factor
      for c in 0 .. 3:
        dst[(dy * dw + dx) * 4 + c] = src[(sy * sw + sx) * 4 + c]
  (dst, dw, dh)

proc bilinearResize*(src: seq[byte], sw, sh, dw, dh: int): seq[byte] =
  result = newSeq[byte](dw * dh * 4)
  for dy in 0 ..< dh:
    let sy = (dy.float + 0.5) * sh.float / dh.float - 0.5
    let y0 = clamp(sy.floor.int, 0, sh - 1)
    let y1 = clamp(y0 + 1, 0, sh - 1)
    let fy = clamp(sy - y0.float, 0.0, 1.0)
    for dx in 0 ..< dw:
      let sx = (dx.float + 0.5) * sw.float / dw.float - 0.5
      let x0 = clamp(sx.floor.int, 0, sw - 1)
      let x1 = clamp(x0 + 1, 0, sw - 1)
      let fx = clamp(sx - x0.float, 0.0, 1.0)
      for c in 0 .. 3:
        let p00 = src[(y0 * sw + x0) * 4 + c].float
        let p10 = src[(y0 * sw + x1) * 4 + c].float
        let p01 = src[(y1 * sw + x0) * 4 + c].float
        let p11 = src[(y1 * sw + x1) * 4 + c].float
        let top = p00 * (1.0 - fx) + p10 * fx
        let bot = p01 * (1.0 - fx) + p11 * fx
        let v = top * (1.0 - fy) + bot * fy
        result[(dy * dw + dx) * 4 + c] = clamp(v.round.int, 0, 255).byte

proc boxBlurPass*(src: seq[byte], w, h: int): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var sums: array[4, int]
      for dy in -1 .. 1:
        for dx in -1 .. 1:
          let ny = clamp(y + dy, 0, h - 1)
          let nx = clamp(x + dx, 0, w - 1)
          for c in 0 .. 3:
            sums[c] += src[(ny * w + nx) * 4 + c].int
      for c in 0 .. 3:
        result[(y * w + x) * 4 + c] = (sums[c] div 9).byte

proc degradeToFakeAI*(rgba: seq[byte], w, h: int, upscaleFactor, finalPx, blurPasses: int,
                       bg: (byte, byte, byte) = (0'u8, 255'u8, 0'u8)): tuple[pixels: seq[byte], size: int] =
  ## Report §6.3's recipe: flatten on a key colour, non-integer up/downscale,
  ## blur - reproduced here with bilinear+box-blur instead of ImageMagick's
  ## triangle filter and JPEG, since this only needs to look "AI-ish" to the
  ## grid detector, not bit-match the report's own numbers.
  let flat = flattenOnBg(rgba, w, h, bg)
  let (up, uw, uh) = nearestUpscale(flat, w, h, upscaleFactor)
  var down = bilinearResize(up, uw, uh, finalPx, finalPx)
  for _ in 0 ..< blurPasses:
    down = boxBlurPass(down, finalPx, finalPx)
  (down, finalPx)
