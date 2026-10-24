# `para art sheet`: a contact sheet of existing PNGs, tiled into one PNG so
# an agent can `Read` a single image instead of N (report §7.1 rung 2,
# §7.3's row-of-candidates idea, kept to plain compositing - no generation,
# no ML, nearest-neighbour only per the pixel-art scaling rule in report §4.2).

import std/[math, os]
import stb_image/read as stbi
import stb_image/write as stbw

type
  Tile* = object
    file*: string
    srcW*, srcH*: int
    x*, y*, w*, h*: int

  SheetResult* = object
    tiles*: seq[Tile]
    canvasW*, canvasH*: int
    outPath*: string

  SheetError* = object of CatchableError

proc nearestScale(pixels: openArray[byte], w, h, nw, nh: int): seq[byte] =
  result = newSeq[byte](nw * nh * 4)
  for oy in 0 ..< nh:
    let sy = min(h - 1, (oy * h) div nh)
    for ox in 0 ..< nw:
      let sx = min(w - 1, (ox * w) div nw)
      let srcIdx = (sy * w + sx) * 4
      let dstIdx = (oy * nw + ox) * 4
      for c in 0 .. 3:
        result[dstIdx + c] = pixels[srcIdx + c]

proc buildContactSheet*(paths: seq[string], outPath: string,
                         maxTile = 128, cols = 4, padding = 8): SheetResult =
  if paths.len == 0:
    raise newException(SheetError, "no assets to lay out")
  if cols < 1 or maxTile < 1:
    raise newException(SheetError, "cols and max tile must be at least 1")
  let actualCols = min(cols, paths.len)
  let rows = (paths.len + actualCols - 1) div actualCols
  let cellSize = maxTile + padding
  result.canvasW = actualCols * cellSize + padding
  result.canvasH = rows * cellSize + padding
  var canvas = newSeq[byte](result.canvasW * result.canvasH * 4) # transparent

  for i, path in paths:
    var w, h, channels: int
    let pixels =
      try:
        stbi.load(path, w, h, channels, stbi.RGBA)
      except stbi.STBIException as e:
        raise newException(SheetError, path & ": " & e.msg)

    let scale = min(1.0, maxTile.float / max(w, h).float)
    let drawW = max(1, (w.float * scale).round.int)
    let drawH = max(1, (h.float * scale).round.int)
    let scaled = if drawW == w and drawH == h: @pixels
                 else: nearestScale(pixels, w, h, drawW, drawH)

    let col = i mod actualCols
    let row = i div actualCols
    let cellX = padding + col * cellSize
    let cellY = padding + row * cellSize
    let ox = cellX + (maxTile - drawW) div 2
    let oy = cellY + (maxTile - drawH) div 2

    for y in 0 ..< drawH:
      for x in 0 ..< drawW:
        let srcIdx = (y * drawW + x) * 4
        let dstIdx = ((oy + y) * result.canvasW + (ox + x)) * 4
        for c in 0 .. 3:
          canvas[dstIdx + c] = scaled[srcIdx + c]

    result.tiles.add Tile(file: path, srcW: w, srcH: h,
                           x: ox, y: oy, w: drawW, h: drawH)

  let outDir = outPath.parentDir
  if outDir.len > 0:
    createDir(outDir)
  if not stbw.writePNG(outPath, result.canvasW, result.canvasH, stbw.RGBA, canvas):
    raise newException(SheetError, "failed to write " & outPath)
  result.outPath = outPath
