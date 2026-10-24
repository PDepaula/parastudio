# The lint checks themselves (asset pipeline report §5.3, demonstrated on
# real sheets in §7.2). Pixel analysis (`analyzeAsset`) works on a decoded
# RGBA buffer so it can run on synthetic buffers in tests as well as real
# files; `lintFile` is the disk-facing wrapper `para art lint` uses.

import std/[algorithm, math, options, sets, strutils]
import stb_image/read as stbi
import profile, sidecar

type
  EdgeCounts* = object
    top*, bottom*, left*, right*: int

  GridStatus* = enum
    gsOk, gsBad, gsUnknown ## gsUnknown: no sidecar, so no declared cell size

  AssetReport* = object
    file*: string
    width*, height*: int
    cellW*, cellH*: int
    grid*: GridStatus
    colorCount*: int
    semiAlphaPx*: int
    emptyCells*: int
    edges*: EdgeCounts
    edgeTouchCells*: int ## cells with opaque pixels on any of their four edges
    orphanPixels*: int
    keyLeakPx*: int ## visible pixels within keyLeakDist of the sidecar's key colour
    cellsMeasured*: bool ## the per-cell rules (empty, edge, outline) need a tiling grid
    outlineOffenders*: int ## boundary pixels not darker than their cell's darkest interior pixel
    paletteChecked*: bool
    offPalette*: seq[int] ## distinct packed 0xRRGGBB of visible pixels not in the palette
    tile*: bool ## the sidecar says `kind = "tile"`: tile rules instead of sprite rules
    visiblePx*: int ## pixels with alpha > 0; none at all is a `blank` output
    seamX*, seamY*: float ## tile only: wrap-around seam excess, see `seamExcess`
    profileName*: string
    profileSource*: string
    failReasons*: seq[string]
    waived*: seq[Waiver]
    verdict*: string ## "ok" or "fail"

const keyLeakDist* = 40.0
  ## RGB (Euclidean) distance from the declared key colour inside which a
  ## visible pixel counts as leaked background. Matches
  ## tools/art/src/para_art_fix/keyleak.py's KEY_LEAK_DIST, which strips every
  ## such pixel, so `fix` output always passes the `key` rule.

const seamMax* = 16.0
  ## Tile rule `seamless`: a tile fails when either wrap-around seam (see
  ## `seamExcess`) is worse than this, in RGB (Euclidean, 0..441.7) units of
  ## mean distance across the seam beyond the 75th-percentile inside cut. A
  ## seamless texture scores 0 or close to it; a hard seam through ground
  ## texture scores in the tens to hundreds (the seam_break fixture: about
  ## 200), and one through a smooth gradient scores near its whole range. 16 is
  ## a few palette steps: a seam that small is lost in the texture itself.

const cellsUnmeasured* = "cells unmeasured"
  ## Not a rule, so no waiver clears it: a waived grid still leaves the
  ## per-cell rules unchecked.

proc luma(r, g, b: byte): float =
  0.299 * r.float + 0.587 * g.float + 0.114 * b.float

proc seamExcess*(pixels: openArray[byte], width, height: int, horizontal: bool): float =
  ## How much worse the seam of a 3x3 tiling of the image is than a typical cut
  ## through it. In a 3x3 tiling every seam joins the last column to the first
  ## (`horizontal`) or the last row to the first, so one wrap pair is enough.
  ## Its measure is the mean RGB distance across that pair, minus the 75th
  ## percentile of the same mean over every pair of neighbouring columns (rows)
  ## inside the image. A percentile, not the worst pair, so one strong
  ## full-height line (a grout line, a crack) cannot raise the bar above a hard
  ## seam; and not the median, so a texture whose edges are half the pairs (a
  ## checker) still wraps. The cost: a texture that is smooth except for a few
  ## strong lines scores its wrap pair in full when the wrap lands on one of
  ## them, and fails (regenerate it, or waive `seamless`). Clamped at 0.
  template px(x, y, ch: int): float = pixels[(y * width + x) * 4 + ch].float
  template dist(x0, y0, x1, y1: int): float =
    sqrt((px(x0, y0, 0) - px(x1, y1, 0)) ^ 2 + (px(x0, y0, 1) - px(x1, y1, 1)) ^ 2 +
         (px(x0, y0, 2) - px(x1, y1, 2)) ^ 2)
  let across = if horizontal: width else: height ## length of the axis the seam crosses
  let along = if horizontal: height else: width
  if across < 2 or along < 1: return 0.0
  var seam = 0.0
  var inside = newSeq[float](across - 1) ## summed distance across each inside pair
  for a in 0 ..< along:
    if horizontal:
      seam += dist(width - 1, a, 0, a)
      for x in 0 ..< width - 1: inside[x] += dist(x, a, x + 1, a)
    else:
      seam += dist(a, height - 1, a, 0)
      for y in 0 ..< height - 1: inside[y] += dist(a, y, a, y + 1)
  inside.sort()
  max(0.0, (seam - inside[(across - 2) * 3 div 4]) / along.float)

proc analyzeAsset*(pixels: openArray[byte], width, height: int,
                    cellW, cellH: int, profile: Profile,
                    pivot: string, palette: openArray[int] = [],
                    key = "", kind = ""): AssetReport =
  ## `key` is the RRGGBB the sprite was keyed from (the sidecar's `key`), ""
  ## when unknown, which skips the `key` rule: lint cannot guess a background.
  ## `kind` is the sidecar's: "tile" swaps the sprite rules (alpha cut, edge,
  ## outline, orphan, key) for the tile rules (exact one-cell size, fully
  ## opaque, `seamless`); every kind fails `blank` when nothing is visible.
  result.tile = kind == "tile"
  result.width = width
  result.height = height
  result.cellW = cellW
  result.cellH = cellH

  template px(x, y: int, ch: int): byte = pixels[(y * width + x) * 4 + ch]

  # Colour count and semi-alpha are whole-image; they don't need a grid.
  # The count is of opaque colours; palette membership covers every visible
  # pixel, so an alpha waiver never hides an off-palette colour.
  var opaqueColors = initHashSet[int]()
  var visibleColors = initHashSet[int]()
  for y in 0 ..< height:
    for x in 0 ..< width:
      let a = px(x, y, 3)
      if a == 0: continue
      inc result.visiblePx
      let packed = px(x, y, 0).int shl 16 or px(x, y, 1).int shl 8 or px(x, y, 2).int
      visibleColors.incl(packed)
      if a == 255: opaqueColors.incl(packed)
      else: inc result.semiAlphaPx
  result.colorCount = opaqueColors.len

  if key.len == 6:
    let kr = parseHexInt(key[0 .. 1]).float
    let kg = parseHexInt(key[2 .. 3]).float
    let kb = parseHexInt(key[4 .. 5]).float
    for y in 0 ..< height:
      for x in 0 ..< width:
        if px(x, y, 3) == 0: continue
        let dr = px(x, y, 0).float - kr
        let dg = px(x, y, 1).float - kg
        let db = px(x, y, 2).float - kb
        if sqrt(dr * dr + dg * dg + db * db) <= keyLeakDist: inc result.keyLeakPx

  # Orphan pixels: any visible (alpha > 0) pixel with no visible 8-neighbour.
  for y in 0 ..< height:
    for x in 0 ..< width:
      if px(x, y, 3) == 0: continue
      var hasNeighbour = false
      for dy in -1 .. 1:
        for dx in -1 .. 1:
          if dx == 0 and dy == 0: continue
          let nx = x + dx
          let ny = y + dy
          if nx >= 0 and nx < width and ny >= 0 and ny < height and px(nx, ny, 3) > 0:
            hasNeighbour = true
      if not hasNeighbour:
        inc result.orphanPixels

  result.grid = if cellW <= 0 or cellH <= 0: gsUnknown
                elif width mod cellW == 0 and height mod cellH == 0: gsOk
                else: gsBad

  # Outline present and darkest (report §5.3), judged per cell: every
  # boundary pixel (on the cell edge or with a transparent orthogonal
  # neighbour) must be darker than the cell's darkest interior pixel.
  result.cellsMeasured = result.grid == gsOk

  if result.tile:
    result.seamX = seamExcess(pixels, width, height, true)
    result.seamY = seamExcess(pixels, width, height, false)

  if result.cellsMeasured and not result.tile:
    let cols = width div cellW
    let rows = height div cellH
    for cy in 0 ..< rows:
      for cx in 0 ..< cols:
        let x0 = cx * cellW
        let y0 = cy * cellH
        var cellHasOpaque = false
        var boundaryLumas: seq[float]
        var darkestInterior = 255.0
        var sawInterior = false
        var touchTop, touchBottom, touchLeft, touchRight = false
        for y in y0 ..< y0 + cellH:
          for x in x0 ..< x0 + cellW:
            let a = px(x, y, 3)
            if a == 0: continue
            cellHasOpaque = true
            if y == y0: touchTop = true
            if y == y0 + cellH - 1: touchBottom = true
            if x == x0: touchLeft = true
            if x == x0 + cellW - 1: touchRight = true
            # Boundary vs interior, judged against this cell's own bounds so
            # a neighbouring frame in the sheet never counts as "inside".
            let isBoundary = x == x0 or x == x0 + cellW - 1 or
                             y == y0 or y == y0 + cellH - 1 or
                             px(x - 1, y, 3) == 0 or px(x + 1, y, 3) == 0 or
                             px(x, y - 1, 3) == 0 or px(x, y + 1, 3) == 0
            let l = luma(px(x, y, 0), px(x, y, 1), px(x, y, 2))
            if isBoundary:
              boundaryLumas.add l
            else:
              sawInterior = true
              if l < darkestInterior: darkestInterior = l
        if sawInterior:
          for l in boundaryLumas:
            if l >= darkestInterior: inc result.outlineOffenders
        if not cellHasOpaque: inc result.emptyCells
        if touchTop: inc result.edges.top
        if touchBottom: inc result.edges.bottom
        if touchLeft: inc result.edges.left
        if touchRight: inc result.edges.right
        if touchTop or touchBottom or touchLeft or touchRight:
          inc result.edgeTouchCells

  # A tile is outside the game palette lock on purpose (tools/art/README.md,
  # "Ground tiles"): only its own colour cap applies.
  result.paletteChecked = palette.len > 0 and not result.tile
  if result.paletteChecked:
    let paletteSet = palette.toHashSet
    for c in visibleColors:
      if c notin paletteSet: result.offPalette.add c
    result.offPalette.sort()

  result.profileName = profile.name
  result.profileSource = profile.source

  var reasons: seq[string]
  case result.grid
  of gsBad: reasons.add "grid"
  of gsUnknown: reasons.add "sidecar"
  of gsOk: discard
  if not result.cellsMeasured: reasons.add cellsUnmeasured
  if result.visiblePx == 0: reasons.add "blank"
  if result.offPalette.len > 0: reasons.add "palette"
  if result.colorCount > profile.maxColors: reasons.add "colors"
  if result.semiAlphaPx > 0: reasons.add "alpha"
  if result.tile:
    # A full-bleed tile touches every cell edge, has no cut-out outline or
    # stray pixels to judge, and was never keyed: only size, opacity and the
    # seam matter.
    if result.visiblePx < width * height and "alpha" notin reasons: reasons.add "alpha"
    if result.grid != gsUnknown and (width != cellW or height != cellH): reasons.add "size"
    if max(result.seamX, result.seamY) > seamMax: reasons.add "seamless"
  else:
    if profile.outlineRequired and result.outlineOffenders > 0: reasons.add "outline"
    if result.orphanPixels > profile.orphanMax: reasons.add "orphan"
    if result.keyLeakPx > 0: reasons.add "key"
    let clipTouches = result.edges.top + result.edges.left + result.edges.right +
      (if pivot == "bottom": 0 else: result.edges.bottom)
    if clipTouches > 0: reasons.add "edge"

  result.failReasons = reasons
  result.verdict = if reasons.len == 0: "ok" else: "fail"

proc applyWaivers*(report: AssetReport, waivers: seq[Waiver]): AssetReport =
  result = report
  var remaining: seq[string]
  for reason in result.failReasons:
    var isWaived = false
    for w in waivers:
      if w.rule == reason and reason != cellsUnmeasured:
        isWaived = true
        result.waived.add w
        break
    if not isWaived:
      remaining.add reason
  result.failReasons = remaining
  result.verdict = if remaining.len == 0: "ok" else: "fail"

type
  LintError* = object of CatchableError

proc lintFile*(pngPath: string, style = none(Style)): AssetReport =
  ## The sidecar names the asset's profile; `style` is the game's
  ## art/style.toml, if any. An asset with no sidecar is still measured,
  ## against the style's profile or the hibit default, and fails
  ## "sidecar".
  var w, h, channels: int
  let pixels =
    try:
      stbi.load(pngPath, w, h, channels, stbi.RGBA)
    except stbi.STBIException as e:
      raise newException(LintError, pngPath & ": " & e.msg)

  let sc = loadSidecar(pngPath)
  var cellW, cellH: int
  var pivot = "bottom"
  var key = ""
  var kind = ""
  var prof = if style.isSome: style.get.profile else: builtinHiBit
  var waivers: seq[Waiver]
  if sc.isSome:
    cellW = sc.get.cellW
    cellH = sc.get.cellH
    pivot = sc.get.pivot
    key = sc.get.key
    kind = sc.get.kind
    prof = resolveProfile(sc.get.profile, style)
    waivers = sc.get.waivers

  let palette = if style.isSome: style.get.palette else: @[]
  result = analyzeAsset(pixels, w, h, cellW, cellH, prof, pivot, palette, key, kind)
  result.file = pngPath
  result = applyWaivers(result, waivers)
