import unittest
import pararules
from pararules/engine import nil
import paraloop/sim

static: doAssert declared(engine.paraloopEnginePatched),
  "patches/pararules/engine.nim is not applied; check patchFile in config.nims"

type
  Id = enum
    Global
  Attr = enum
    Tick, Count

schema Fact(Id, Attr):
  Tick: int
  Count: int

let (initSession, rulesInternal) =
  staticRuleset(Fact, FactMatch):
    rule getCount(Fact):
      what:
        (Global, Count, count)
    # Mirrors parasurvivors' tickGameTime shape (id-first, then the trigger
    # last) and repeatedly walks the thenQueue path patches/pararules fixes.
    rule tickCounter(Fact):
      what:
        (Global, Count, count, then = false)
        (Global, Tick, tick)
      then:
        session.insert(Global, Count, count + 1)

let smokeRules = rulesInternal

proc newSmokeSession(): Session[Fact, FactMatch] =
  result = initSession(autoFire = false)
  for r in smokeRules.fields:
    result.add(r)
  result.insert(Global, Count, 0)

suite "smoke: pararules compiles and runs against orc + the patched engine":
  test "200 ticks fire through the patched then-queue and the count matches":
    var s = newSmokeSession()
    for i in 1 .. 200:
      s.insert(Global, Tick, i)
      s.fireRules()
    let (count) = s.query(smokeRules.getCount)
    check count == 200
