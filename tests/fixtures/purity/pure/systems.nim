## A named exception (geometry): a procedure, not a rule, so it may retract.
import std/[algorithm, heapqueue, math]
import pararules
import paraloop/sim

proc reap*[M](session: var Session[int, M]) =
  discard

type
  MenuItem* = enum
    play, quit
  Door* = object
    open*: bool

proc frontier*(doors: seq[Door], pick: MenuItem): int =
  ## A variable named `open` (a path search's open list), a field named `open` and an enum
  ## member named `quit`: none of them opens a file or quits.
  var open = initHeapQueue[int]()
  for d in doors:
    if d.open: open.push(1)
  result = open.len
  if pick == quit: result = 0
