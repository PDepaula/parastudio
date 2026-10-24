## Adversarial replay checks for paraloop/sim: many short-lived entities, rules
## whose firing order draws from one shared RNG, a rule that triggers on a fact
## that rarely changes, a factory fact the game retracts, a ref seq fact
## mutated in place, and rule work still queued when the snapshot is taken (a
## `thenFinally` queued by retracts, a `then` queued by an insert, both made
## after `fireRules`). Run with `--straight-hash` to print the straight run's
## hash and exit (used to compare separate processes).

import std/[unittest, random, hashes, os, osproc, strutils, sequtils]
import pararules
from pararules/engine import idAttrsComparisons, joinMatchesVisited
import paraloop/sim

type
  History = ref seq[int]

  Id = enum
    Global
  Attr = enum
    Tick, Wave, Log, Hp, Pos, Vel

schema Fact(Id, Attr):
  Tick: int
  Wave: int
  Log: History
  Hp: int
  Pos: int
  Vel: int

const bossId = 1_000_000

var ruleRng: ptr Rand

let (initSession, rules) =
  staticRuleset(Fact, FactMatch):
    # Triggers only when Wave changes, not every tick.
    rule waveStart(Fact):
      what:
        (Global, Wave, wave)
        (Global, Log, log, then = false)
      then:
        log[].add(-1000 * wave - ruleRng[].rand(999))
        session.insert(Global, Log, log)

    # Runs once per enemy per tick; each run draws from the shared RNG and
    # logs its enemy, so the firing order is part of the state.
    rule enemyTick(Fact):
      what:
        (Global, Tick, tick)
        (id, Hp, hp, then = false)
        (Global, Log, log, then = false)
      then:
        let hit = ruleRng[].rand(9)
        log[].add(id * 10 + hit)
        session.insert(Global, Log, log)
        session.insert(id, Hp, hp - hit)

    rule enemy(Fact):
      what:
        (id, Hp, hp)

    # Logs the alive count once per run; retracting an enemy queues it.
    rule countAlive(Fact):
      what:
        (id, Hp, hp)
        (Global, Log, log, then = false)
      thenFinally:
        let alive = session.queryAll(this)
        if alive.len > 0:
          let log = alive[0].log
          log[].add(-alive.len)
          session.insert(Global, Log, log)

    rule history(Fact):
      what:
        (Global, Log, log)

    # A per-entity join: each Pos update must reach only its own entity's
    # Vel match.
    rule motion(Fact):
      what:
        (id, Vel, v)
        (id, Pos, p, then = false)
      then:
        session.insert(id, Pos, p + v)

proc newGameSession(autoFire: bool): Session[Fact, FactMatch] =
  result = initSession(autoFire = autoFire)
  for r in rules.fields:
    result.add(r)
  var log: History
  new(log)
  result.insert(Global, Log, log)
  result.insert(bossId, Hp, 1_000)

proc step(s: var Sim[Fact, FactMatch]) =
  ruleRng = s.rng.addr
  inc s.tick
  if s.tick == 5:
    s.session.retract(bossId, Hp)
  for i in 0 ..< s.rng.rand(3):
    s.session.insert(s.nextId(), Hp, 5 + s.rng.rand(20))
  for e in s.session.queryAll(rules.enemy):
    s.session.insert(e.id, Hp, e.hp + s.rng.rand(2))
  s.session.insert(Global, Tick, s.tick)
  s.session.fireRules()
  for e in s.session.queryAll(rules.enemy):
    if e.hp <= 0:
      s.session.retract(e.id, Hp)
  if s.tick mod 100 == 0:
    s.session.insert(Global, Wave, s.tick div 100)

proc run(s: var Sim[Fact, FactMatch], ticks: int) =
  for i in 1 .. ticks:
    s.step()

proc straightHash(autoFire: bool): Hash =
  var s = initSim(newGameSession(autoFire), seed = 42'i64, idType = Id)
  s.run(1200)
  s.stateHash()

if paramCount() == 1 and paramStr(1) == "--straight-hash":
  echo straightHash(autoFire = false)
  quit(0)

suite "paraloop/sim replay":
  for autoFire in [false, true]:
    test "entities created and retracted, snapshot at 600, restore, 600 more == 1200 straight (autoFire = " & $autoFire & ")":
      let expected = straightHash(autoFire)
      var first = initSim(newGameSession(autoFire), seed = 42'i64, idType = Id)
      first.run(600)
      let snap = first.snapshot()
      first.run(600)
      check first.stateHash() == expected

      let factory = proc (): Session[Fact, FactMatch] = newGameSession(autoFire)
      for i in 1 .. 2:
        var restored = restore(snap, factory, Attr)
        check restored.dumpFacts.len == snap.facts.len
        restored.run(600)
        check restored.stateHash() == expected

  test "a thenFinally queued by a retract right before the snapshot runs exactly once, the same way, after restore":
    var s = initSim(newGameSession(autoFire = false), seed = 7'i64, idType = Id)
    s.run(10)
    let before = s.session.query(rules.history).log[]
    let alive = s.session.queryAll(rules.enemy)
    check alive.len > 1
    s.session.retract(alive[0].id, Hp)
    let snap = s.snapshot()
    var restored = restore(snap, proc (): Session[Fact, FactMatch] = newGameSession(autoFire = false), Attr)
    check restored.stateHash() == s.stateHash()

    s.session.fireRules()
    restored.session.fireRules()
    check s.session.query(rules.history).log[] == before & @[-(alive.len - 1)]
    check restored.session.query(rules.history).log[] == before & @[-(alive.len - 1)]
    check restored.stateHash() == s.stateHash()

  test "a per-entity join sorts only the parent match that passes its id shortcut":
    const
      n = 500
      ticks = 5
    var session = newGameSession(autoFire = false)
    for id in 1 .. n:
      session.insert(id, Vel, 1)
      session.insert(id, Pos, 0)
    let before = idAttrsComparisons
    for tick in 1 .. ticks:
      for id in 1 .. n:
        session.insert(id, Vel, 1)
      session.fireRules()
    # Each tick sorts its n queued `then`s once (about n * log2(n) comparisons,
    # well under n * 32); sorting all n parent matches on each of the n Pos
    # updates would take about n * n * log2(n).
    check idAttrsComparisons - before < ticks * n * 32
    let moved = session.queryAll(rules.motion)
    check moved.len == n
    check moved.allIt(it.p == ticks)

  test "a per-entity join reads only its own id's parent matches, not all of them":
    # The walk system at the 200-mob cap is one fact write per mob axis per
    # step; each write must cost O(1) join work, not a scan of every parent
    # match (n * n visits a tick, ~16 ms p99 on the debug sim).
    const
      n = 500
      ticks = 5
    var session = newGameSession(autoFire = false)
    for id in 1 .. n:
      session.insert(id, Vel, 1)
      session.insert(id, Pos, 0)
    let before = joinMatchesVisited
    for tick in 1 .. ticks:
      for id in 1 .. n:
        session.insert(id, Pos, tick)
    # One parent match (the entity's own Vel) per update.
    check joinMatchesVisited - before == ticks * n
    check session.queryAll(rules.motion).allIt(it.p == ticks)

  test "the straight run hashes the same in separate processes":
    let cmd = quoteShell(getAppFilename()) & " --straight-hash"
    let a = execCmdEx(cmd)
    let b = execCmdEx(cmd)
    check a.exitCode == 0
    check b.exitCode == 0
    check a.output.strip == b.output.strip
    check a.output.strip == $straightHash(autoFire = false)
