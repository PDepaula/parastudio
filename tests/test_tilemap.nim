## paraloop/tilemap: parsing a text grid (and what it refuses), world <-> tile, a box sliding along
## solid tiles, line of sight and flood-fill reach. Ticks and positions only, headless, no timing.

import std/[options, sequtils, strutils, unittest]
import paraloop/tilemap

type Kind = enum
  Wall, Floor, Bush

proc legend(c: char): Option[Kind] =
  case c
  of '#': some Wall
  of '.': some Floor
  of 't': some Bush
  else: none(Kind)

proc blocks(kind: Kind): bool = kind != Floor

proc grid(rows: varargs[string]): TileMap =
  parseGrid[Kind](rows, legend, blocks)

proc errorOf(rows: varargs[string]): string =
  try:
    discard grid(rows)
  except ValueError:
    return getCurrentExceptionMsg()

const
  ts = tileSize
  feet = (w: 40, h: 24)

proc box(x, y: int): AABB = (x: x, y: y, w: feet.w, h: feet.h)

suite "tilemap: parsing":
  test "a grid is one kind and one blocking flag per cell":
    let map = grid("####",
                   "#.t#",
                   "####")
    check map.width == 4 and map.height == 3
    check map.worldWidth == 4 * ts and map.worldHeight == 3 * ts
    check Kind(map.tileAt(1, 1)) == Floor and Kind(map.tileAt(2, 1)) == Bush and Kind(map.tileAt(0, 0)) == Wall
    check not map.isSolid(1, 1)
    check map.isSolid(2, 1) # the legend's flag, not the character
    check map.isSolid(0, 0)

  test "outside the map is solid, and a tile read there is an index error":
    let map = grid("..", "..")
    check map.isSolid(-1, 0) and map.isSolid(0, -1) and map.isSolid(2, 0) and map.isSolid(0, 2)
    expect IndexDefect:
      discard map.tileAt(2, 0)

  test "a ragged grid names its row and column":
    let msg = errorOf("###", "#.", "###")
    check "row 2" in msg and "column 3" in msg
    check "row 3" in errorOf("##", "##", "###")

  test "an unknown character names its row and column":
    let msg = errorOf("###", "#?#")
    check "row 2" in msg and "column 2" in msg and "'?'" in msg

  test "no rows and an empty first row are refused":
    check errorOf().len > 0
    check "row 1" in errorOf("", "")

suite "tilemap: world and tile":
  test "a tile covers [tile * 48, (tile + 1) * 48) and its centre is 24 in":
    check worldToTile(0, 0) == (x: 0, y: 0)
    check worldToTile(47, 47) == (x: 0, y: 0)
    check worldToTile(48, 95) == (x: 1, y: 1)
    check tileToWorld(0, 0) == (x: 24, y: 24)
    check tileToWorld(3, 2) == (x: 3 * ts + 24, y: 2 * ts + 24)

  test "a point left of or above the map is a negative tile (floor, not truncation)":
    check worldToTile(-1, -1) == (x: -1, y: -1)
    check worldToTile(-48, -49) == (x: -1, y: -2)

  test "a tile's centre is in that tile":
    for ty in -2 .. 5:
      for tx in -2 .. 5:
        let c = tileToWorld(tx, ty)
        check worldToTile(c.x, c.y) == (x: tx, y: ty)

suite "tilemap: moveBox":
  # Row 0 and the last row are wall; the room is 4 tiles wide and 4 tall inside.
  let room = grid("######",
                  "#....#",
                  "#....#",
                  "#....#",
                  "#....#",
                  "######")

  test "open floor: the box moves exactly where it is told":
    check room.moveBox(box(100, 100), 3, -2) == (x: 103, y: 98)
    check room.moveBox(box(100, 100), 0, 0) == (x: 100, y: 100)

  test "the right wall stops the box flush, not short and not through":
    # the inner right face is at 5 * 48 = 240; a 40 wide box's left edge stops at 200
    check room.moveBox(box(190, 100), 30, 0) == (x: 200, y: 100)
    check room.moveBox(box(200, 100), 5, 0) == (x: 200, y: 100)

  test "the left, top and bottom walls stop it flush too":
    check room.moveBox(box(60, 100), -30, 0) == (x: ts, y: 100)
    check room.moveBox(box(100, 60), 0, -30) == (x: 100, y: ts)
    # inner bottom face is 5 * 48 = 240; a 24 tall box's top edge stops at 216
    check room.moveBox(box(100, 200), 0, 30) == (x: 100, y: 216)

  test "a diagonal into a wall slides along it":
    # pressed against the right wall, moving down-right keeps the y move
    check room.moveBox(box(200, 100), 4, 4) == (x: 200, y: 104)
    # pressed against the floor wall, moving right-down keeps the x move
    check room.moveBox(box(100, 216), 4, 4) == (x: 104, y: 216)

  test "a move longer than a tile still cannot pass a wall":
    check room.moveBox(box(60, 100), 500, 0) == (x: 200, y: 100)
    check room.moveBox(box(200, 100), -500, 0) == (x: ts, y: 100)
    check room.moveBox(box(100, 60), 0, 900) == (x: 100, y: 216)

  test "an inner solid tile blocks along each axis":
    let bush = grid("#######",
                    "#.....#",
                    "#..t..#",
                    "#.....#",
                    "#######")
    # the bush is tile (3, 2): x 144 .. 192, y 96 .. 144. Walk right at its height.
    check bush.moveBox(box(80, 100), 40, 0) == (x: 104, y: 100) # right edge 144 meets its left face
    # from the right, left edge stops at 192
    check bush.moveBox(box(200, 100), -40, 0) == (x: 192, y: 100)
    # from above, bottom edge (y + 24) meets its top face at 96
    check bush.moveBox(box(150, 60), 0, 40) == (x: 150, y: 72)
    # from below, top edge meets its bottom face at 144
    check bush.moveBox(box(150, 160), 0, -40) == (x: 150, y: 144)

  test "a one-tile gap is passable by the 40 wide feet box, and a hair wider is not":
    let wall = grid("##.##",
                    "#...#",
                    "#...#",
                    "##.##")
    check wall.isSolid(1, 0) and not wall.isSolid(2, 0) # the doorway is column 2: x 96 .. 144
    var at = (x: 100, y: ts + 10)
    for _ in 0 ..< 40:
      at = wall.moveBox(box(at.x, at.y), 0, -2)
    check at == (x: 100, y: 0) # through the doorway to the edge of the map
    # the box's right edge at 145 clips the wall beside the doorway: held under the wall row
    check wall.moveBox(box(105, ts + 10), 0, -30) == (x: 105, y: ts)

  test "a box two tiles wide does not fit a one-tile gap":
    let wall = grid("##.##",
                    "#...#",
                    "#...#",
                    "##.##")
    let wide: AABB = (x: 2 * ts - 24, y: ts + 10, w: 96, h: 24)
    let moved = wall.moveBox(wide, 0, -30)
    check moved.y == ts # stopped under the wall row, the gap is too small for it

  test "outside the map blocks like a wall":
    let map = grid("...", "...")
    check map.moveBox(box(0, 0), -10, 0) == (x: 0, y: 0)
    check map.moveBox(box(0, 0), 0, -10) == (x: 0, y: 0)
    check map.moveBox(box(100, 60), 100, 100) == (x: 3 * ts - 40, y: 2 * ts - 24)

  test "the same inputs always give the same answer":
    for dx in -9 .. 9:
      for dy in -9 .. 9:
        check room.moveBox(box(120, 120), dx, dy) == room.moveBox(box(120, 120), dx, dy)

suite "tilemap: raycast":
  let map = grid("#########",
                 "#.......#",
                 "#...#...#",
                 "#...#...#",
                 "#.......#",
                 "#########")

  test "open floor sees across the room":
    check map.raycast(ts + 24, ts + 24, 7 * ts + 24, ts + 24)
    check map.raycast(ts + 24, 4 * ts + 24, 7 * ts + 24, 4 * ts + 24)

  test "a wall in the way blocks, from either end":
    check not map.raycast(2 * ts + 24, 2 * ts + 24, 6 * ts + 24, 2 * ts + 24)
    check not map.raycast(6 * ts + 24, 3 * ts + 24, 2 * ts + 24, 3 * ts + 24)

  test "a ray over the top of the pillar sees, one through it does not":
    check map.raycast(3 * ts + 24, ts + 24, 5 * ts + 24, ts + 24)
    check not map.raycast(3 * ts + 24, 2 * ts + 24, 5 * ts + 24, 3 * ts + 24)

  test "a point in a wall sees nothing, and a point sees itself":
    check not map.raycast(24, 24, 3 * ts, 3 * ts)
    check map.raycast(100, 100, 100, 100)
    check not map.raycast(24, 24, 24, 24)

  test "outside the map is solid":
    check not map.raycast(ts + 24, ts + 24, -100, ts + 24)

  test "a ray through the exact corner of two diagonal walls is blocked":
    let corner = grid("....",
                      ".#..",
                      "..#.",
                      "....")
    # tile (1, 2)'s centre to tile (2, 1)'s: the segment passes exactly through the point (96, 96)
    # where the two walls touch
    check not corner.raycast(ts + 24, 2 * ts + 24, 2 * ts + 24, ts + 24)
    check corner.raycast(24, 24, 3 * ts + 24, 24) # along the open top row

  test "symmetric: the same segment sees the same both ways":
    for (x0, y0, x1, y1) in [(60, 60, 380, 200), (60, 200, 380, 60), (100, 100, 100, 220), (70, 90, 300, 90)]:
      check map.raycast(x0, y0, x1, y1) == map.raycast(x1, y1, x0, y0)

suite "tilemap: reachable":
  test "every floor tile of a plain room is reachable from inside it":
    let map = grid("#####",
                   "#...#",
                   "#...#",
                   "#####")
    let seen = map.reachable((x: 1, y: 1))
    for y in 0 ..< map.height:
      for x in 0 ..< map.width:
        check seen[y * map.width + x] == not map.isSolid(x, y)

  test "a wall that splits the room leaves the far side unreached":
    let map = grid("#######",
                   "#..#..#",
                   "#..#..#",
                   "#######")
    let seen = map.reachable((x: 1, y: 1))
    check seen[1 * map.width + 2] and seen[2 * map.width + 1]
    check not seen[1 * map.width + 4] and not seen[2 * map.width + 5]

  test "movement is four-way: two floors that only touch at a corner are not joined":
    let map = grid("####",
                   "#.##",
                   "##.#",
                   "####")
    let seen = map.reachable((x: 1, y: 1))
    check seen[1 * map.width + 1]
    check not seen[2 * map.width + 2]

  test "starting on a wall or off the map reaches nothing":
    let map = grid("###", "#.#", "###")
    check map.reachable((x: 0, y: 0)).count(true) == 0
    check map.reachable((x: -1, y: 1)).count(true) == 0
    check map.reachable((x: 1, y: 1)).count(true) == 1

  test "a thicket (solid by the legend) is never in the reach":
    let map = grid("#####",
                   "#.t.#",
                   "#####")
    let seen = map.reachable((x: 1, y: 1))
    check seen[1 * map.width + 1]
    check not seen[1 * map.width + 2] and not seen[1 * map.width + 3]
