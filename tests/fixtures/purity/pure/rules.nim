## A pure game: every import and every `then` call here is allowed. Comments may say echo,
## readFile("x") or import std/times without tripping the check:
## import std/os
#[ a block comment: quit(1) session.retract(Player, Hp) ]#

import std/[deques, math, options, sequtils, strutils, tables]
from std/random import Rand, rand, shuffle
import pararules
import paraloop/[sim, tilemap, toml]
import data

type
  Id* = enum
    Global, Player
  Attr* = enum
    DeltaTime, TotalTime, Hp, Wallet, Spawned, Roll, Label
  Step* = tuple[dx, dy: int]

schema Fact(Id, Attr):
  DeltaTime: float
  TotalTime: float
  Hp: int
  Wallet: int
  Spawned: int
  Roll: int
  Label: string

func halved*(x: int): int = x div 2

proc openShop*[M](session: var Session[Fact, M], wallet: int) =
  session.insert(Global, Wallet, wallet)

let (newRawSession*, gameRules*) =
  staticRuleset(Fact, FactMatch):
    rule player(Fact):
      what:
        (Player, Hp, hp)

    rule tickTime(Fact):
      what:
        (Global, TotalTime, total, then = false)
        (Global, DeltaTime, dt)
      then:
        session.insert(Global, TotalTime, total + dt)

    rule spawn(Fact):
      what:
        (Global, Spawned, n, then = false)
        (Global, DeltaTime, dt)
      then:
        let id = session.nextId()
        let roll = session.rng.rand(99) + rand(session.rng, 3)
        var order = @[1, 2, 3]
        session.rng.shuffle(order)
        let speed = max(abs(roll), 1).float * sqrt(dt)
        let label = "echo readFile(\"x\") " & $n
        let pick = some(Step(dx: 1, dy: 0))
        if pick.isSome and
            speed > 0.0 and n < session.matchCount("player"):
          inc order[0]
          session.insert(Global, Spawned, n + halved(order.len))
        session.insert(Global, Label, label)
        session.openShop(stepCost[pick.get.dx](n))
        session.insert(Global, Roll, floor(speed).int + int(roll) + 1'i64.int)

    rule total(Fact):
      what:
        (Player, Hp, hp)
      thenFinally:
        let all = session.queryAll(this)
        session.insert(Global, Wallet, all.len)

    rule tally(Fact):
      what:
        (Global, Roll, roll)
      then:
        var q = initDeque[int]()
        q.addLast(roll)
        q.addFirst(1)
        let a = q.popFirst() + q.popLast()
        var xs = newSeqWith(3, 0)
        let b = xs.pop()
        let t = newTable[int, int]()
        let o = initOrderedTable[string, int]()
        let c = initCountTable[int]()
        let n = parseInt("4") + parseFloat("1.5").int + t.get_or_default(1) + o.len + c.len
        when defined(debug): doAssert n > 0
        let doc = parseToml("a = 1")
        session.insert(Global, Label, format("$1 $2", a, b) & doc.top.getStr("a"))
        session.insert(Global, Spawned, session.next_id() + hal_ved(n))
