## paraloop/tilemap: a grid of square tiles a game's rooms are made of, and the
## geometry a room needs: which cell a world point is in, a box sliding along
## solid tiles, line of sight, which floor can be walked to, and the path there. No window, no GL,
## no pararules: headless code (a rule's `then`, a test, `para sim`) imports it.
##
## World units are integers, as the sim's positions are. Tile (0, 0) is the
## top-left cell and covers world `[0, tileSize)` on both axes; x grows right,
## y grows down, so tile `(tx, ty)` covers `[tx * tileSize, (tx + 1) * tileSize)`
## on x and likewise on y. A box is its top-left corner and its size. Anything
## outside the map is solid: a box can never leave the room.
##
## A `TileMap` stores a tile kind per cell as a byte (the game's own enum,
## through `parseGrid`'s legend) and whether it blocks. The engine never learns
## the game's kinds; the game says which are solid when it parses a grid.
##
## Runs at compile time as well (no closures stored, no pointers), so a game can
## check its rooms in a `static:` block.

import std/[math, options, heapqueue]

const
  tileSize* = 48
    ## World units in a tile's side. The player (96x144) is two tiles wide and three tall;
    ## a 20x12 room is one 960x576 screen.

type
  Tile* = tuple[x, y: int]
    ## A cell's column and row.

  AABB* = tuple[x, y, w, h: int]
    ## An axis-aligned box in world units: top-left corner, then width and height.

  TileMap* = object
    width*, height*: int ## tiles across and down
    tiles*: seq[uint8] ## the kind of each cell, row by row (`y * width + x`)
    solid*: seq[bool] ## whether each cell blocks movement and sight, same order

# ---- cells -------------------------------------------------------------------------------

func inBounds*(map: TileMap, x, y: int): bool =
  x >= 0 and y >= 0 and x < map.width and y < map.height

func isSolid*(map: TileMap, x, y: int): bool =
  ## Whether the cell blocks. Outside the map blocks, so a walk or a ray cannot leave the room.
  not map.inBounds(x, y) or map.solid[y * map.width + x]

func tileAt*(map: TileMap, x, y: int): uint8 =
  ## The kind byte of cell `(x, y)`; an index error outside the map, like a `seq`.
  if not map.inBounds(x, y):
    raise newException(IndexDefect, "tile (" & $x & ", " & $y & ") is outside the " & $map.width &
      "x" & $map.height & " map")
  map.tiles[y * map.width + x]

func worldToTile*(x, y: int): Tile =
  ## The cell a world point is in (floor division, so a point left of or above the map is a
  ## negative cell, not cell 0).
  (x: floorDiv(x, tileSize), y: floorDiv(y, tileSize))

func tileToWorld*(tx, ty: int): tuple[x, y: int] =
  ## The world point at the centre of cell `(tx, ty)`.
  (x: tx * tileSize + tileSize div 2, y: ty * tileSize + tileSize div 2)

func worldWidth*(map: TileMap): int = map.width * tileSize
func worldHeight*(map: TileMap): int = map.height * tileSize
  ## The map's size in world units.

# ---- parsing -----------------------------------------------------------------------------

proc parseGrid*[K: enum](rows: openArray[string], legend: proc (c: char): Option[K] {.nimcall.},
                         isSolid: proc (kind: K): bool {.nimcall.}): TileMap =
  ## A map from text rows, one character a cell, `legend` giving each character's kind (`none` for
  ## a character the grid may not hold) and `isSolid` whether that kind blocks. A grid with no
  ## rows, an empty one, a row of a different length than the first or a character `legend` does
  ## not know is a `ValueError` naming the row and column (both counted from 1).
  if rows.len == 0:
    raise newException(ValueError, "the grid has no rows")
  if rows[0].len == 0:
    raise newException(ValueError, "row 1 is empty")
  result.width = rows[0].len
  result.height = rows.len
  result.tiles = newSeq[uint8](result.width * result.height)
  result.solid = newSeq[bool](result.width * result.height)
  for y, row in rows:
    if row.len != result.width:
      raise newException(ValueError, "row " & $(y + 1) & " is " & $row.len & " wide, the first row is " &
        $result.width & " (column " & $(min(row.len, result.width) + 1) & ")")
    for x, c in row:
      let kind = legend(c)
      if kind.isNone:
        raise newException(ValueError, "row " & $(y + 1) & ", column " & $(x + 1) & ": '" & $c &
          "' is not in the legend")
      result.tiles[y * result.width + x] = uint8(ord(kind.get))
      result.solid[y * result.width + x] = isSolid(kind.get)

# ---- movement ----------------------------------------------------------------------------

func slideX(map: TileMap, box: AABB, dx: int): int =
  ## The box's new left edge after trying to move `dx` along x: stopped flush against the first
  ## solid column in its way (any of the rows its height spans).
  if dx == 0:
    return box.x
  let top = floorDiv(box.y, tileSize)
  let bottom = floorDiv(box.y + box.h - 1, tileSize)
  if dx > 0:
    let first = floorDiv(box.x + box.w - 1, tileSize) + 1
    let last = floorDiv(box.x + box.w + dx - 1, tileSize)
    for col in first .. last:
      for row in top .. bottom:
        if map.isSolid(col, row):
          return col * tileSize - box.w
  else:
    let first = floorDiv(box.x, tileSize) - 1
    let last = floorDiv(box.x + dx, tileSize)
    for col in countdown(first, last):
      for row in top .. bottom:
        if map.isSolid(col, row):
          return (col + 1) * tileSize
  box.x + dx

func slideY(map: TileMap, box: AABB, dy: int): int =
  ## `slideX` along y: the new top edge, stopped flush against the first solid row in the way.
  if dy == 0:
    return box.y
  let left = floorDiv(box.x, tileSize)
  let right = floorDiv(box.x + box.w - 1, tileSize)
  if dy > 0:
    let first = floorDiv(box.y + box.h - 1, tileSize) + 1
    let last = floorDiv(box.y + box.h + dy - 1, tileSize)
    for row in first .. last:
      for col in left .. right:
        if map.isSolid(col, row):
          return row * tileSize - box.h
  else:
    let first = floorDiv(box.y, tileSize) - 1
    let last = floorDiv(box.y + dy, tileSize)
    for row in countdown(first, last):
      for col in left .. right:
        if map.isSolid(col, row):
          return (row + 1) * tileSize
  box.y + dy

func moveBox*(map: TileMap, box: AABB, dx, dy: int): tuple[x, y: int] =
  ## Where `box`'s top-left corner ends up after moving `(dx, dy)`: the x move first, resolved
  ## against solid tiles (the box stops flush against the wall), then the y move from there. A
  ## diagonal into a wall therefore slides along it instead of stopping dead. A box that already
  ## overlaps a solid tile is not pushed out, it just cannot move further into one.
  let x = map.slideX(box, dx)
  let y = map.slideY((x: x, y: box.y, w: box.w, h: box.h), dy)
  (x: x, y: y)

# ---- sight and reach ---------------------------------------------------------------------

func raycast*(map: TileMap, x0, y0, x1, y1: int): bool =
  ## Line of sight between two world points: true when no solid tile lies on the segment, either
  ## end's own cell included (a point inside a wall sees nothing). A grid walk (DDA) over the
  ## cells the segment crosses; a segment through a corner shared by two cells counts both, so a
  ## ray never slips between two diagonal walls.
  var (cx, cy) = worldToTile(x0, y0)
  let (ex, ey) = worldToTile(x1, y1)
  if map.isSolid(cx, cy):
    return false
  let dx = x1 - x0
  let dy = y1 - y0
  let stepX = if dx > 0: 1 elif dx < 0: -1 else: 0
  let stepY = if dy > 0: 1 elif dy < 0: -1 else: 0
  # Distance along the segment (0 .. 1) to the first cell border on each axis, and between
  # borders. Exact integer fractions would need 64-bit cross products; floats are exact for the
  # sizes a room has (every operand is a whole number far below 2^53).
  let ax = abs(dx).float
  let ay = abs(dy).float
  var tMaxX = Inf
  var tMaxY = Inf
  var tDeltaX = Inf
  var tDeltaY = Inf
  if stepX != 0:
    let border = if stepX > 0: (cx + 1) * tileSize else: cx * tileSize
    tMaxX = abs(border - x0).float / ax
    tDeltaX = tileSize.float / ax
  if stepY != 0:
    let border = if stepY > 0: (cy + 1) * tileSize else: cy * tileSize
    tMaxY = abs(border - y0).float / ay
    tDeltaY = tileSize.float / ay
  var remX = abs(ex - cx)
  var remY = abs(ey - cy)
  while remX > 0 or remY > 0:
    if remY == 0 or (remX > 0 and tMaxX < tMaxY):
      tMaxX += tDeltaX
      cx += stepX
      dec remX
      if map.isSolid(cx, cy): return false
    elif remX == 0 or tMaxY < tMaxX:
      tMaxY += tDeltaY
      cy += stepY
      dec remY
      if map.isSolid(cx, cy): return false
    else:
      # Exactly on a corner: both neighbours of the diagonal step are crossed.
      if map.isSolid(cx + stepX, cy) or map.isSolid(cx, cy + stepY) or
          map.isSolid(cx + stepX, cy + stepY):
        return false
      tMaxX += tDeltaX
      tMaxY += tDeltaY
      cx += stepX
      cy += stepY
      dec remX
      dec remY
  true

func reachable*(map: TileMap, start: Tile): seq[bool] =
  ## Every cell that can be walked to from `start` over non-solid cells, four neighbours at a time
  ## (`y * width + x`, like `solid`). All false when `start` is solid or outside the map. The
  ## helper every room test uses: "every floor tile is reachable from the entry".
  result = newSeq[bool](map.width * map.height)
  if map.isSolid(start.x, start.y):
    return
  var queue = @[start]
  result[start.y * map.width + start.x] = true
  var head = 0
  while head < queue.len:
    let at = queue[head]
    inc head
    for (nx, ny) in [(at.x + 1, at.y), (at.x - 1, at.y), (at.x, at.y + 1), (at.x, at.y - 1)]:
      if not map.isSolid(nx, ny) and not result[ny * map.width + nx]:
        result[ny * map.width + nx] = true
        queue.add (x: nx, y: ny)

# ---- paths -------------------------------------------------------------------------------

const neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)]
  ## The eight steps of `findPath`, the four straight ones first: among equal paths the
  ## search prefers the one that walks straight, and the order is part of its answer.

func octile(a, b: Tile): int =
  ## The cost of the shortest unobstructed walk from `a` to `b`, in tenths of a step: 10 straight,
  ## 14 diagonal (a whole-number stand-in for sqrt 2).
  let dx = abs(a.x - b.x)
  let dy = abs(a.y - b.y)
  10 * max(dx, dy) + 4 * min(dx, dy)

func findPath*(map: TileMap, fromTile, toTile: Tile): seq[Tile] =
  ## The shortest walk from `fromTile` to `toTile`, A* over eight neighbours: the tiles to step
  ## through in order, `fromTile` not among them and `toTile` last. A diagonal step needs both
  ## tiles it passes between free (no cutting a corner). Empty when `toTile` is `fromTile`, when
  ## either end is solid or off the map, and when no walk joins them. Straight steps cost 10 and
  ## diagonals 14, ties broken by the order the tiles were reached, so a path never depends on
  ## anything but the map and the two ends.
  if fromTile == toTile or map.isSolid(fromTile.x, fromTile.y) or map.isSolid(toTile.x, toTile.y):
    return
  type Node = tuple[f, seq, g: int, at: Tile]
  proc before(a, b: Node): bool = (a.f, a.seq) < (b.f, b.seq)
  let cells = map.width * map.height
  var best = newSeq[int](cells)
  var cameFrom = newSeq[int](cells)
  for i in 0 ..< cells:
    best[i] = high(int)
    cameFrom[i] = -1
  var open = initHeapQueue[Node]()
  var counter = 0
  best[fromTile.y * map.width + fromTile.x] = 0
  open.push (f: octile(fromTile, toTile), seq: 0, g: 0, at: fromTile)
  while open.len > 0:
    let node = open.pop()
    let here = node.at.y * map.width + node.at.x
    if node.g > best[here]:
      continue # a cheaper way here was found after this entry was queued
    if node.at == toTile:
      var i = here
      while i != fromTile.y * map.width + fromTile.x:
        result.add (x: i mod map.width, y: i div map.width)
        i = cameFrom[i]
      for a in 0 ..< result.len div 2:
        swap(result[a], result[result.len - 1 - a])
      return
    for (dx, dy) in neighbours:
      let nx = node.at.x + dx
      let ny = node.at.y + dy
      if map.isSolid(nx, ny):
        continue
      if dx != 0 and dy != 0 and (map.isSolid(node.at.x + dx, node.at.y) or map.isSolid(node.at.x, node.at.y + dy)):
        continue
      let g = node.g + (if dx != 0 and dy != 0: 14 else: 10)
      let there = ny * map.width + nx
      if g < best[there]:
        best[there] = g
        cameFrom[there] = here
        inc counter
        open.push (f: g + octile((x: nx, y: ny), toTile), seq: counter, g: g, at: (x: nx, y: ny))

func nearestReachable*(map: TileMap, tile: Tile, maxRadius = 3): Option[Tile] =
  ## The free tile nearest `tile` within `maxRadius` steps (`tile` itself when it is free): a
  ## search outward in rings, a ring being the tiles `r` steps away by the larger of the two
  ## offsets. The first ring with a free tile answers, the tile of it nearest `tile` in a straight
  ## line, and of equal ones the first in reading order, so the answer is the same on every
  ## machine. `none` when every tile in range is solid or off the map.
  for r in 0 .. maxRadius:
    var bestDist = high(int)
    for dy in -r .. r:
      for dx in -r .. r:
        if max(abs(dx), abs(dy)) == r and not map.isSolid(tile.x + dx, tile.y + dy) and
            dx * dx + dy * dy < bestDist:
          bestDist = dx * dx + dy * dy
          result = some((x: tile.x + dx, y: tile.y + dy))
    if result.isSome:
      return
