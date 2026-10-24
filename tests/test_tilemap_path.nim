## paraloop/tilemap paths: `findPath` (A*, eight neighbours, no corner cutting) and
## `nearestReachable`. Tiles only, headless, no timing.

import std/[options, unittest]
import paraloop/tilemap

type Kind = enum
  Wall, Floor

proc legend(c: char): Option[Kind] =
  case c
  of '#': some Wall
  of '.': some Floor
  else: none(Kind)

proc blocks(kind: Kind): bool = kind == Wall

proc grid(rows: varargs[string]): TileMap =
  parseGrid[Kind](rows, legend, blocks)

proc isWalk(map: TileMap, start: Tile, path: seq[Tile]): bool =
  ## Every step is to a neighbouring free tile, and a diagonal passes between two free ones.
  var at = start
  for step in path:
    if map.isSolid(step.x, step.y): return false
    let dx = step.x - at.x
    let dy = step.y - at.y
    if max(abs(dx), abs(dy)) != 1: return false
    if dx != 0 and dy != 0 and (map.isSolid(at.x + dx, at.y) or map.isSolid(at.x, at.y + dy)):
      return false
    at = step
  true

suite "findPath":
  test "an open room: a straight line is as long as the distance, a diagonal as long as its larger side":
    let map = grid("#######",
                   "#.....#",
                   "#.....#",
                   "#.....#",
                   "#######")
    check map.findPath((1, 1), (5, 1)) == @[(2, 1), (3, 1), (4, 1), (5, 1)]
    check map.findPath((1, 1), (3, 3)) == @[(2, 2), (3, 3)]
    check map.findPath((1, 1), (5, 3)).len == 4
    check map.isWalk((1, 1), map.findPath((1, 1), (5, 3)))

  test "the path leaves the start out and ends on the target":
    let map = grid("#####",
                   "#...#",
                   "#####")
    let path = map.findPath((1, 1), (3, 1))
    check path == @[(2, 1), (3, 1)]
    check (1, 1) notin path

  test "zero length: the start is the target, and there is nothing to walk":
    let map = grid("###",
                   "#.#",
                   "###")
    check map.findPath((1, 1), (1, 1)).len == 0

  test "a diagonal never cuts a corner: both tiles it passes between must be free":
    #  . #     the only diagonal from (1,1) to (2,2) squeezes between a wall and a floor
    #  . .
    let oneWall = grid("####",
                       "#.##",
                       "#..#",
                       "####")
    check oneWall.findPath((1, 1), (2, 2)) == @[(1, 2), (2, 2)]
    let bothWalls = grid("####",
                         "#.#.",
                         "##.#",
                         "####")
    # (1,1) and (2,2) touch only at a corner between two walls: no path at all.
    check bothWalls.findPath((1, 1), (2, 2)).len == 0
    check bothWalls.findPath((3, 1), (2, 2)).len == 0

  test "a wall is walked around, by the shorter side":
    let map = grid("#########",
                   "#.......#",
                   "#...#...#",
                   "#...#...#",
                   "#.......#",
                   "#########")
    let path = map.findPath((2, 2), (6, 2))
    check map.isWalk((2, 2), path)
    check path[^1] == (6, 2)
    check path.len == 4 # up and over on the diagonals: as long as the larger side

  test "unreachable: a sealed pocket, a solid or off-map end, all give an empty path":
    let map = grid("#######",
                   "#..#..#",
                   "#..#..#",
                   "#######")
    check map.findPath((1, 1), (4, 1)).len == 0
    check map.findPath((1, 1), (3, 1)).len == 0   # the target is a wall
    check map.findPath((3, 1), (1, 1)).len == 0   # the start is a wall
    check map.findPath((1, 1), (9, 9)).len == 0   # off the map
    check map.findPath((-1, 0), (1, 1)).len == 0

  test "the same map and ends give the same path, and it is as short as flood fill says":
    let map = grid("##########",
                   "#........#",
                   "#.##.###.#",
                   "#..#...#.#",
                   "#.##.#.#.#",
                   "#....#...#",
                   "##########")
    let first = map.findPath((1, 1), (8, 5))
    check first == map.findPath((1, 1), (8, 5))
    check first.len > 0 and map.isWalk((1, 1), first)
    check first[^1] == (8, 5)
    # Every free tile the flood fill reaches has a path; the others none.
    let reach = map.reachable((1, 1))
    for y in 0 ..< map.height:
      for x in 0 ..< map.width:
        if (x, y) != (1, 1):
          let path = map.findPath((1, 1), (x, y))
          check (path.len > 0) == reach[y * map.width + x]
          if path.len > 0:
            check map.isWalk((1, 1), path) and path[^1] == (x, y)

  test "a walk of straight steps and diagonals is not longer than the octile distance":
    let map = grid("###########",
                   "#.........#",
                   "#.........#",
                   "#.........#",
                   "###########")
    for (tx, ty) in [(9, 3), (9, 1), (2, 3), (5, 2)]:
      let path = map.findPath((1, 1), (tx, ty))
      check path.len == max(abs(tx - 1), abs(ty - 1))

suite "nearestReachable":
  let map = grid("#######",
                 "#.....#",
                 "#.###.#",
                 "#.#.#.#",
                 "#.###.#",
                 "#.....#",
                 "#######")

  test "a free tile is its own answer":
    check map.nearestReachable((1, 1)) == some((1, 1))

  test "a wall goes to the nearest free tile, the straighter one of a ring":
    check map.nearestReachable((2, 2)) == some((2, 1))     # straight above beats the diagonals
    check map.nearestReachable((3, 2)) == some((3, 1))     # above and below tie: reading order
    check map.nearestReachable((0, 3)) == some((1, 3))

  test "nothing free within the radius is none":
    let walled = grid("#########",
                      "#########",
                      "#########",
                      "#########",
                      "####.####")
    check walled.nearestReachable((4, 0), 3).isNone
    check walled.nearestReachable((4, 1), 3) == some((4, 4))

  test "off the map counts as solid, and a tile outside the map can still find the inside":
    check map.nearestReachable((-1, 1)) == some((1, 1))
    check map.nearestReachable((-2, -2), 1).isNone
