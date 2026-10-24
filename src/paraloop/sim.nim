## paraloop/sim: pararules session helpers shared by every game.
##
## A `Sim[T, MatchT]` bundles a pararules session with the sim's own
## bookkeeping: a seeded RNG, a tick counter and an id allocator, none of
## them facts (report `parasurvivors-engine-scout` §3.4 R2, R7). That makes
## the whole game state `queryAll(session)` plus those few extra fields, so
## `dumpFacts`, `snapshot` and `restore` (§3.4 R3) and `stateHash` are
## generic over any schema.
##
## The RNG and the id allocator live in the session's context
## (`patches/pararules/engine.nim`'s `SessionContext`), held by reference, so
## the session a `then` receives is the same context the `Sim` reads:
## `sim.rng`/`sim.nextId()` and `session.rng`/`session.nextId()` in a rule
## are one RNG and one allocator, and a rule that draws or allocates leaves
## the same state a procedure doing it by hand would. Copies of a `Sim` or
## its session share them (as they already shared every fact).
##
## `initSim` needs the schema's id enum, so the id allocator starts past its
## entities: pass it as `initSim(session, seed, Id)`. `restore` needs the
## schema's attribute enum explicitly, since it can't be inferred from the
## `(id, attr, value)` tuples `queryAll` returns; pass it as
## `restore(snap, newSession, Attr)`. `newSession` is the game's own
## "fresh session with every rule added" factory (see tests/test_sim.nim).
##
## Take snapshots and hashes outside rule execution. A snapshot carries the
## session's pending rule work (set triggers, queued `then`/`thenFinally`
## blocks), so a restored sim behaves exactly like the original: paraloop's
## pararules patch (patches/pararules/engine.nim) makes rule firing and match
## order depend only on the facts, not on pointer addresses or table
## history. Match ids (`find`/`get`) are the exception: they are allocation
## counters, so don't store them in facts.

import std/[random, hashes, algorithm, intsets]
import pararules
from pararules/engine import PendingRules, Production, pendingRules, resetPending, matchCount

export matchCount

type
  Sim*[T, MatchT] = object
    session*: Session[T, MatchT]
    seed*: int64
    tick*: int

  Snapshot*[T] = object
    tick*: int
    seed*: int64
    rng*: Rand
    lastId*: int
    facts*: seq[tuple[id: int, attr: int, value: T]]
    pending*: PendingRules

proc initSim*[T, MatchT, I](session: Session[T, MatchT], seed: int64, idType: typedesc[I]): Sim[T, MatchT] =
  ## `idType` is the schema's `Id` enum. pararules stores enum ids and int ids
  ## as the same ints, so the allocator starts after `high(idType).ord` and
  ## `nextId` never hands out an enum entity's id. Seeds the session's
  ## context: do not hand one session to two sims.
  session.context.rng = initRand(seed)
  session.context.lastId = high(I).ord
  Sim[T, MatchT](session: session, seed: seed, tick: 0)

# The session's context, as a rule's `then` sees it (`session`) and as the
# shell sees it (`sim`): the same RNG and allocator either way.

proc rng*[T, MatchT](session: Session[T, MatchT]): var Rand =
  ## The seeded RNG. In a `then`: `session.rng.rand(99)`. Draws advance the
  ## sim's own RNG, so they replay from the seed and travel through
  ## `snapshot`/`restore` like any other.
  session.context.rng

proc rng*[T, MatchT](sim: Sim[T, MatchT]): var Rand =
  sim.session.rng

proc lastId*[T, MatchT](session: Session[T, MatchT]): int =
  ## The last entity id handed out.
  session.context.lastId

proc lastId*[T, MatchT](sim: Sim[T, MatchT]): int =
  sim.session.lastId

proc nextId*[T, MatchT](session: Session[T, MatchT]): int =
  ## Allocates the next entity id, past every id enum entity. Ids are held
  ## beside the facts (not as one), so `lastId` travels through
  ## `snapshot`/`restore` alongside the tick counter and RNG state. In a
  ## `then`: `let id = session.nextId()`.
  inc session.context.lastId
  session.context.lastId

proc nextId*[T, MatchT](sim: Sim[T, MatchT]): int =
  sim.session.nextId()

proc matchCount*[T, MatchT](sim: Sim[T, MatchT], ruleName: string): int =
  ## How many matches the rule named `ruleName` has (the length of
  ## `queryAll(session, rule)`), without building them: O(1). A `then`
  ## cannot name another rule, so it counts by name:
  ## `session.matchCount("enemies")` (the engine's, re-exported here).
  ## Raises `KeyError` for an unknown rule.
  sim.session.matchCount(ruleName)

proc matchCount*[T, U, MatchT](sim: Sim[T, MatchT], prod: Production[T, U, MatchT]): int =
  ## `matchCount` by rule, from outside a `then`: `sim.matchCount(gameRules.enemies)`.
  sim.session.matchCount(prod)

proc dumpFacts*[T, MatchT](sim: Sim[T, MatchT]): seq[tuple[id: int, attr: int, value: T]] =
  ## Every fact, sorted by `(id, attr)`: `queryAll`'s own order reflects
  ## table layout, not state, and can differ between two identical sims.
  result = queryAll(sim.session)
  result.sort(proc (a, b: tuple[id: int, attr: int, value: T]): int =
    if a.id != b.id: cmp(a.id, b.id) else: cmp(a.attr, b.attr))

proc copyValue[T](v: T): T =
  ## Deep-copies `v` so the copy shares no `ref` with it: the same traversal
  ## as `hashValue` (`IntSet`'s own `=copy` is already deep).
  when T is IntSet:
    result = v
  elif T is ref:
    if not v.isNil:
      new(result)
      result[] = copyValue(v[])
  elif T is seq:
    result = newSeq[typeof(v[0])](v.len)
    for i in 0 ..< v.len:
      result[i] = copyValue(v[i])
  elif T is (object or tuple):
    result = v
    for f in fields(result):
      when f is (ref or seq or object or tuple):
        f = copyValue(f)
  else:
    result = v

proc snapshot*[T, MatchT](sim: Sim[T, MatchT]): Snapshot[T] =
  ## Copies the sim's state; the snapshot shares no `ref` fact value with it.
  result = Snapshot[T](tick: sim.tick, seed: sim.seed, rng: sim.rng, lastId: sim.lastId,
                       facts: sim.dumpFacts, pending: pendingRules(sim.session))
  for f in result.facts.mitems:
    f.value = copyValue(f.value)

proc restore*[T, MatchT, A](snap: Snapshot[T], newSession: proc (): Session[T, MatchT], attrType: typedesc[A]): Sim[T, MatchT] =
  ## Builds a fresh session via `newSession`, retracts whatever facts it
  ## starts with and inserts (copies of) exactly `snap`'s facts, with
  ## `autoFire` off so no rule runs on a half-restored state. It then
  ## replaces the rule work those inserts queued with exactly the pending
  ## rule work `snap` carries, and restores the tick counter, seed, RNG
  ## state and id allocator. `attrType` is the
  ## schema's `Attr` enum, used to turn `queryAll`'s raw attr ordinals back
  ## into typed values the generated `insert`/`retract` expect.
  mixin insert, retract
  var session = newSession()
  let autoFire = session.autoFire
  session.autoFire = false
  for f in queryAll(session):
    retract(session, f.id, A(f.attr))
  for f in snap.facts:
    insert(session, f.id, A(f.attr), copyValue(f.value))
  session.resetPending(snap.pending)
  session.autoFire = autoFire
  session.context.rng = snap.rng
  session.context.lastId = snap.lastId
  Sim[T, MatchT](session: session, seed: snap.seed, tick: snap.tick)

proc hashValue*[T](v: T): Hash =
  ## Hashes `v` by content rather than identity: `ref` fields are
  ## dereferenced (nil-safe) and `IntSet`s are hashed in sorted order, so two
  ## independently-built values with the same data hash the same even though
  ## a plain `hash` would see different ref addresses or bucket layouts.
  mixin hashValue
  when T is IntSet:
    var xs: seq[int] = @[]
    for x in v: xs.add x
    xs.sort()
    result = 0
    for x in xs:
      result = result !& hash(x)
    result = !$result
  elif T is ref:
    if v.isNil:
      result = hash(0)
    else:
      result = hashValue(v[])
  elif T is seq:
    result = hash(v.len)
    for x in v:
      result = result !& hashValue(x)
    result = !$result
  elif T is (object or tuple):
    result = 0
    for f in fields(v):
      result = result !& hashValue(f)
    result = !$result
  else:
    result = hash(v)

proc stateHash*[T, MatchT](sim: Sim[T, MatchT]): Hash =
  ## A deterministic hash of the whole sim state: every fact (in `dumpFacts`'
  ## sorted order) plus the tick counter, seed, RNG state, id allocator and
  ## pending rule work. The pending work is keyed by rule *name*, so adding a
  ## rule (even a getter) can move this hash while no fact differs; compare
  ## `factsHash` across rulesets.
  result = 0
  result = result !& hash(sim.tick)
  result = result !& hash(sim.seed)
  result = result !& hash(sim.lastId)
  result = result !& hashValue(sim.rng)
  result = result !& hashValue(pendingRules(sim.session))
  for f in sim.dumpFacts:
    result = result !& hash(f.id)
    result = result !& hash(f.attr)
    result = result !& hashValue(f.value)
  result = !$result

proc factsHash*[T, MatchT](sim: Sim[T, MatchT]): Hash =
  ## `stateHash` without the pending rule names: the facts, the tick counter,
  ## seed, RNG state and id allocator. It does not move when a rule is added
  ## that matches nothing new, so it is what compares a run before and after
  ## a rules change; `stateHash` stays the replay and snapshot check.
  result = 0
  result = result !& hash(sim.tick)
  result = result !& hash(sim.seed)
  result = result !& hash(sim.lastId)
  result = result !& hashValue(sim.rng)
  for f in sim.dumpFacts:
    result = result !& hash(f.id)
    result = result !& hash(f.attr)
    result = result !& hashValue(f.value)
  result = !$result

proc pulse*[T, MatchT, I, A, V](session: var Session[T, MatchT], id: I, attr: A, value: V) =
  ## A one-shot trigger: insert the fact, let the rules it triggers fire,
  ## retract it, then let anything the retract queued fire. Nothing is left
  ## behind. A trigger fact left standing re-fires its rule for the first new
  ## match after the rule's match set was empty (the engine's `isNew`), so a
  ## per-tick or command trigger is pulsed, never left in the session.
  ##
  ## Call it outside rules: a `then` may not retract. With `autoFire` off the
  ## first `fireRules` also runs whatever was already queued.
  mixin insert, retract
  insert(session, id, attr, value)
  session.fireRules()
  retract(session, id, attr)
  session.fireRules()

proc pulse*[T, MatchT, I, A, V](sim: var Sim[T, MatchT], id: I, attr: A, value: V) =
  ## `pulse` on the sim's session.
  mixin insert, retract
  pulse(sim.session, id, attr, value)
