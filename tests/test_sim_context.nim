## paraloop/sim's session context and the helpers over it: a `then` that
## allocates entity ids and draws from the seeded RNG (the same ids and values
## a procedure doing it by hand gets), a match count by rule name, `factsHash`
## against `stateHash`, and `pulse`. Headless, deterministic counts only.

import std/[unittest, random, hashes, sequtils, strutils]
import pararules
from pararules/engine import idAttrsComparisons, joinMatchesVisited, pendingRules
import paraloop/sim

type
  Id = enum
    Global
  Attr = enum
    Spawn, Hp, Beat, Order, Seen, Count, Armour

  OrderLog = ref seq[string]

schema Fact(Id, Attr):
  Spawn: int
  Hp: int
  Beat: int
  Order: OrderLog
  Seen: int
  Count: int
  Armour: int

let (initSession, rules) =
  staticRuleset(Fact, FactMatch):
    rule enemies(Fact):
      what:
        (id, Hp, hp)

    # A rule that allocates and draws: `Spawn n` makes n entities, each with an
    # id from the sim's allocator and an Hp from the sim's RNG.
    rule spawner(Fact):
      what:
        (Global, Spawn, n)
      then:
        for _ in 0 ..< n:
          let id = session.nextId()
          session.insert(id, Hp, 5 + session.rng.rand(20))

    rule counted(Fact):
      what:
        (Global, Count, count)

    # Counts another rule's matches by name: a `then` cannot name `enemies`.
    rule census(Fact):
      what:
        (Global, Beat, beat)
      then:
        session.insert(Global, Count, session.matchCount("enemies"))

    rule history(Fact):
      what:
        (Global, Order, order)

    # Two rules on one pulse: rule order is firing order.
    rule firstOnPulse(Fact):
      what:
        (Global, Order, order, then = false)
        (Global, Seen, seen)
      then:
        order[].add("first:" & $seen)
        session.insert(Global, Order, order)

    rule secondOnPulse(Fact):
      what:
        (Global, Order, order, then = false)
        (Global, Seen, seen)
      then:
        order[].add("second:" & $seen)
        session.insert(Global, Order, order)

    # A rule over a fact that matches only above a threshold.
    rule armoured(Fact):
      what:
        (id, Armour, armour)
      cond:
        armour > 0

    # A getter nobody triggers but a fact can match: it adds its name to the
    # pending rule work (and so to `stateHash`) without touching a fact.
    rule armourSeen(Fact):
      what:
        (id, Armour, armour)

proc newSession(autoFire = true, withGetter = true): Session[Fact, FactMatch] =
  result = initSession(autoFire = autoFire)
  for name, r in rules.fieldPairs:
    if withGetter or name != "armourSeen":
      result.add(r)
  var order: OrderLog
  new(order)
  result.insert(Global, Order, order)

proc hpValues(sim: Sim[Fact, FactMatch]): seq[tuple[id, hp: int]] =
  for e in sim.session.queryAll(rules.enemies):
    result.add((e.id, e.hp))

suite "a then reaches the sim's ids and RNG":
  test "ids and draws from a then equal the same sequence done by hand":
    var viaRule = initSim(newSession(), seed = 99'i64, idType = Id)
    var byHand = initSim(newSession(), seed = 99'i64, idType = Id)
    for n in [3, 0, 5, 1]:
      viaRule.session.insert(Global, Spawn, n)
      for _ in 0 ..< n:
        let id = byHand.nextId()
        byHand.session.insert(id, Hp, 5 + byHand.rng.rand(20))
    check viaRule.hpValues.len == 9
    check viaRule.hpValues == byHand.hpValues
    check viaRule.lastId == byHand.lastId
    check viaRule.lastId == Id.high.ord + 9
    check viaRule.rng.next() == byHand.rng.next()

  test "the entity ids start past the schema's id enum and run in order":
    var sim = initSim(newSession(), seed = 1'i64, idType = Id)
    sim.session.insert(Global, Spawn, 4)
    check sim.hpValues.mapIt(it.id) == @[1, 2, 3, 4]
    check sim.nextId() == 5

  test "a restored snapshot carries the context: it draws and allocates like the original":
    let factory = proc (): Session[Fact, FactMatch] = newSession()
    var a = initSim(newSession(), seed = 5'i64, idType = Id)
    a.session.insert(Global, Spawn, 2)
    var b = restore(a.snapshot(), factory, Attr)
    check b.lastId == a.lastId
    check b.stateHash == a.stateHash
    a.session.insert(Global, Spawn, 3)
    b.session.insert(Global, Spawn, 3)
    check a.hpValues.len == 5
    check b.hpValues == a.hpValues
    check b.stateHash == a.stateHash

  test "two sims never share a context":
    var a = initSim(newSession(), seed = 7'i64, idType = Id)
    var b = initSim(newSession(), seed = 8'i64, idType = Id)
    let before = b.rng.next()
    discard a.nextId()
    discard a.rng.rand(100)
    var c = initSim(newSession(), seed = 8'i64, idType = Id)
    check c.rng.next() == before
    check b.lastId == Id.high.ord

suite "matchCount":
  test "equals the length of queryAll for a getter, through inserts, updates and retracts":
    var sim = initSim(newSession(), seed = 1'i64, idType = Id)
    check sim.matchCount("enemies") == 0
    for id in 1 .. 6:
      sim.session.insert(id, Hp, id)
    check sim.matchCount("enemies") == 6
    check sim.matchCount(rules.enemies) == sim.session.queryAll(rules.enemies).len
    sim.session.insert(3, Hp, 30)
    check sim.matchCount("enemies") == 6
    sim.session.retract(2, Hp)
    sim.session.retract(5, Hp)
    check sim.matchCount("enemies") == 4
    check sim.matchCount("enemies") == sim.session.queryAll(rules.enemies).len

  test "counts only the matches a cond lets through":
    var sim = initSim(newSession(), seed = 1'i64, idType = Id)
    for id in 1 .. 5:
      sim.session.insert(id, Armour, id - 2)   # -1, 0, 1, 2, 3
    check sim.matchCount("armoured") == 3
    check sim.matchCount("armoured") == sim.session.queryAll(rules.armoured).len
    sim.session.insert(1, Armour, 4)           # a disabled match becomes enabled
    sim.session.insert(5, Armour, 0)           # an enabled one is disabled
    check sim.matchCount("armoured") == 3
    sim.session.retract(2, Armour)             # a disabled match goes away
    sim.session.retract(3, Armour)             # an enabled one goes away
    check sim.matchCount("armoured") == 2
    check sim.matchCount("armoured") == sim.session.queryAll(rules.armoured).len

  test "a then reads another rule's count by name":
    var sim = initSim(newSession(), seed = 1'i64, idType = Id)
    for id in 1 .. 3:
      sim.session.insert(id, Hp, 1)
    sim.session.insert(Global, Beat, 1)
    check sim.session.query(rules.counted).count == 3
    sim.session.insert(4, Hp, 1)
    sim.session.insert(Global, Beat, 2)
    check sim.session.query(rules.counted).count == 4

  test "an unknown rule raises KeyError naming it":
    let sim = initSim(newSession(), seed = 1'i64, idType = Id)
    expect KeyError:
      discard sim.matchCount("nosuchrule")
    try:
      discard sim.matchCount("nosuchrule")
    except KeyError as e:
      check "nosuchrule" in e.msg

  test "is O(1): no sorting, no join walks":
    var sim = initSim(newSession(), seed = 1'i64, idType = Id)
    for id in 1 .. 500:
      sim.session.insert(id, Hp, id)
    let cmpBefore = idAttrsComparisons
    let visitedBefore = joinMatchesVisited
    for _ in 1 .. 100:
      check sim.matchCount("enemies") == 500
    check idAttrsComparisons == cmpBefore
    check joinMatchesVisited == visitedBefore
    discard sim.session.queryAll(rules.enemies)   # the read it replaces sorts
    check idAttrsComparisons > cmpBefore

suite "factsHash":
  test "ignores the pending rule names that stateHash includes":
    var withGetter = initSim(newSession(withGetter = true), seed = 3'i64, idType = Id)
    var without = initSim(newSession(withGetter = false), seed = 3'i64, idType = Id)
    proc feed(sim: var Sim[Fact, FactMatch]) =
      sim.session.insert(1, Armour, 2)
      sim.session.insert(Global, Spawn, 2)
    feed(withGetter)
    feed(without)
    # The Order fact is a ref each session builds for itself; every other fact
    # is the same.
    proc plain(sim: Sim[Fact, FactMatch]): auto =
      sim.dumpFacts.filterIt(it.attr != Order.ord)
    check withGetter.plain == without.plain
    check pendingRules(withGetter.session) != pendingRules(without.session)
    check withGetter.stateHash != without.stateHash
    check withGetter.factsHash == without.factsHash

  test "moves with a fact, the tick, the RNG and the id allocator":
    var sim = initSim(newSession(), seed = 3'i64, idType = Id)
    let base = sim.factsHash
    check sim.factsHash == base
    sim.session.insert(1, Hp, 1)
    let withFact = sim.factsHash
    check withFact != base
    inc sim.tick
    let withTick = sim.factsHash
    check withTick != withFact
    discard sim.rng.rand(10)
    let withDraw = sim.factsHash
    check withDraw != withTick
    discard sim.nextId()
    check sim.factsHash != withDraw

suite "pulse":
  test "leaves no fact and no pending rule work behind":
    var sim = initSim(newSession(), seed = 1'i64, idType = Id)
    let before = sim.dumpFacts
    sim.pulse(Global, Beat, 1)
    check not sim.session.contains(Global, Beat)
    check sim.dumpFacts.filterIt(it.attr != Count.ord) == before
    let pending = pendingRules(sim.session)
    check pending.thens.len == 0
    check pending.thenFinallys.len == 0

  test "fires the rules it triggers in rule order, with the pulse's value":
    var sim = initSim(newSession(), seed = 1'i64, idType = Id)
    sim.pulse(Global, Seen, 7)
    sim.pulse(Global, Seen, 8)
    check sim.session.query(rules.history).order[] ==
      @["first:7", "second:7", "first:8", "second:8"]

  test "fires the same with autoFire off":
    var sim = initSim(newSession(autoFire = false), seed = 1'i64, idType = Id)
    sim.pulse(Global, Seen, 4)
    sim.pulse(Global, Seen, 5)
    check sim.session.query(rules.history).order[] ==
      @["first:4", "second:4", "first:5", "second:5"]

  test "a standing trigger re-fires for the first new match after the rule had none; a pulse does not":
    # `firstOnPulse` joins Order (then = false) and triggers on Seen. Writing
    # Seen once and leaving it standing, then retracting and re-inserting the
    # Order fact, gives the rule a new match with a stale trigger: it fires
    # again with no new Seen. Pulsing Seen leaves the rule nothing to re-fire.
    proc freshOrder(): OrderLog =
      new(result)

    var standing = initSim(newSession(), seed = 1'i64, idType = Id)
    standing.session.insert(Global, Seen, 1)
    standing.session.retract(Global, Order)
    standing.session.insert(Global, Order, freshOrder())
    check standing.session.query(rules.history).order[] == @["first:1", "second:1"]

    var pulsed = initSim(newSession(), seed = 1'i64, idType = Id)
    pulsed.pulse(Global, Seen, 1)
    pulsed.session.retract(Global, Order)
    pulsed.session.insert(Global, Order, freshOrder())
    check pulsed.session.query(rules.history).order[].len == 0
