import std/[unittest, intsets, random]
import pararules
from pararules/engine import nil
import paraloop/sim

static: doAssert declared(engine.paraloopEnginePatched),
  "patches/pararules/engine.nim is not applied; check patchFile in config.nims"

type
  Tags = ref seq[int]

  Id = enum
    Global, Player
  Attr = enum
    Tick, Count, Roll, Name, Ratio, Active, TagList, Members

schema Fact(Id, Attr):
  Tick: int
  Count: int
  Roll: int
  Name: string
  Ratio: float
  Active: bool
  TagList: Tags
  Members: IntSet

let (initSession, rulesInternal) =
  staticRuleset(Fact, FactMatch):
    rule countOf(Fact):
      what:
        (id, Count, count)

    rule getState(Fact):
      what:
        (Global, Count, count)
        (Global, Tick, tick, then = false)
        (Global, Roll, roll, then = false)
        (Global, Name, name, then = false)
        (Global, Ratio, ratio, then = false)
        (Global, Active, active, then = false)
        (Global, TagList, tags, then = false)
        (Global, Members, members, then = false)

    # Mirrors every attribute type the template schema will use (report
    # §8 risk): plain int/string/float/bool, a `ref seq` and an `IntSet`.
    rule tickState(Fact):
      what:
        (Global, Count, count, then = false)
        (Global, Roll, roll, then = false)
        (Global, TagList, tags, then = false)
        (Global, Members, members, then = false)
        (Global, Tick, tick)
      then:
        var newTags: Tags
        new(newTags)
        newTags[] = tags[]
        newTags[].add(roll)
        var newMembers = members
        newMembers.incl(tick mod 37)
        session.insert(Global, Count, count + 1)
        session.insert(Global, Name, "tick-" & $tick)
        session.insert(Global, Ratio, tick.float / 3.0)
        session.insert(Global, Active, (tick mod 2) == 0)
        session.insert(Global, TagList, newTags)
        session.insert(Global, Members, newMembers)

let stateRules = rulesInternal

proc newTestSession(): Session[Fact, FactMatch] =
  result = initSession(autoFire = false)
  for r in stateRules.fields:
    result.add(r)
  var initialTags: Tags
  new(initialTags)
  result.insert(Global, Count, 0)
  result.insert(Global, Roll, 0)
  result.insert(Global, Name, "start")
  result.insert(Global, Ratio, 0.0)
  result.insert(Global, Active, false)
  result.insert(Global, TagList, initialTags)
  result.insert(Global, Members, initIntSet())

proc step(s: var Sim[Fact, FactMatch]) =
  inc s.tick
  let roll = s.rng.rand(1000)
  s.session.insert(Global, Tick, s.tick)
  s.session.insert(Global, Roll, roll)
  s.session.fireRules()

proc queryState(s: Sim[Fact, FactMatch]): auto =
  s.session.query(stateRules.getState)

suite "paraloop/sim":
  test "600 ticks, snapshot, restore into a fresh session, 600 more ticks == 1200 straight (same hash)":
    var straight = initSim(newTestSession(), seed = 1234'i64, idType = Id)
    for i in 1 .. 1200:
      straight.step()
    let straightHash = straight.stateHash()

    var first = initSim(newTestSession(), seed = 1234'i64, idType = Id)
    for i in 1 .. 600:
      first.step()
    let snap = first.snapshot()

    var second = restore(snap, newTestSession, Attr)
    for i in 1 .. 600:
      second.step()
    let restoredHash = second.stateHash()

    check restoredHash == straightHash
    check second.tick == 1200
    check straight.tick == 1200

  test "id allocator increases monotonically and survives snapshot/restore":
    var sim = initSim(newTestSession(), seed = 1'i64, idType = Id)
    let a = sim.nextId()
    let b = sim.nextId()
    check b == a + 1

    let snap = sim.snapshot()
    var restored = restore(snap, newTestSession, Attr)
    let c = restored.nextId()
    check c == b + 1

  test "allocated ids never collide with the Id enum's entities":
    var sim = initSim(newTestSession(), seed = 5'i64, idType = Id)
    sim.session.insert(Player, Count, 99)
    var ids: seq[int]
    for i in 1 .. 5:
      let id = sim.nextId()
      ids.add(id)
      sim.session.insert(id, Count, i)
    check ids == @[Player.ord + 1, Player.ord + 2, Player.ord + 3, Player.ord + 4, Player.ord + 5]

    var restored = restore(sim.snapshot(), newTestSession, Attr)
    check restored.nextId() == Player.ord + 6
    for s in [sim, restored]:
      var counts: seq[tuple[id, count: int]]
      for c in s.session.queryAll(stateRules.countOf):
        counts.add((c.id, c.count))
      check counts == @[(Global.ord, 0), (Player.ord, 99), (Player.ord + 1, 1), (Player.ord + 2, 2),
                        (Player.ord + 3, 3), (Player.ord + 4, 4), (Player.ord + 5, 5)]

  test "snapshot/restore round-trips every attribute type, including ref seq and IntSet":
    var sim = initSim(newTestSession(), seed = 7'i64, idType = Id)
    for i in 1 .. 5:
      sim.step()
    let before = sim.queryState()

    let snap = sim.snapshot()
    var restored = restore(snap, newTestSession, Attr)
    let after = restored.queryState()

    check before.count == after.count
    check before.tick == after.tick
    check before.roll == after.roll
    check before.name == after.name
    check before.ratio == after.ratio
    check before.active == after.active
    check before.tags[] == after.tags[]
    var beforeMembers, afterMembers: seq[int]
    for x in before.members: beforeMembers.add x
    for x in after.members: afterMembers.add x
    check beforeMembers == afterMembers
    check restored.stateHash() == sim.stateHash()

  test "snapshot, the original sim and every restored sim do not alias the ref seq facts":
    var sim = initSim(newTestSession(), seed = 3'i64, idType = Id)
    for i in 1 .. 3:
      sim.step()
    let snap = sim.snapshot()
    let tags = sim.queryState().tags[]

    var r1 = restore(snap, newTestSession, Attr)
    var r2 = restore(snap, newTestSession, Attr)
    sim.queryState().tags[].add(-1)
    r1.queryState().tags[].add(-2)

    check sim.queryState().tags[] == tags & @[-1]
    check r1.queryState().tags[] == tags & @[-2]
    check r2.queryState().tags[] == tags
    check restore(snap, newTestSession, Attr).queryState().tags[] == tags
