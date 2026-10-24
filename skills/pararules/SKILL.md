---
name: pararules
description: Where a paraloop game's logic goes and how to write it as pararules rules. Game logic is rules by default, with four named exceptions; covers getters, command / changed-fact / beat rules, pulses, state machines, request-and-reaper, derived state, join order, firing order, effects (never in a `then`), proving a change with hashes and testing a rule, plus schema, `gameRules`, snapshot/restore and the three common errors. Use when designing or implementing a new game feature or mechanic, adding or changing a game's rules.nim, data.nim or systems, or when a rule fails to fire, fires too often, or a `query`/recursion-limit error comes up.
---

# pararules in paraloop

pararules keeps a game's whole state as `(id, attr, value)` facts in one
`Session`, matched against `rule`s compiled at build time (`staticRuleset`).
`template/rules.nim` is the worked starting point this skill walks through;
`src/paraloop/sim.nim` is what turns a session into something a game loop can
snapshot, restore and hash.

Schema and `gameRules`, the two macro gotchas, snapshot/restore and the three
common errors are under "Mechanics and errors" at the end.

## 1. Game logic is rules

**Game logic is rules.** Every change to a game's state is a pararules rule in
that game's `rules.nim`. A rule reacts to one of three things: a command fact
(something the player did), the fact that changed (derived state, a threshold
crossed), or a tick beat (a timer, a per-entity step). Reading state through
getter rules and pure functions is always fine and is the idiomatic way to
read. A procedure may change game state only under a named exception, and
nothing below the shell performs an effect: a rule only writes the session,
and the shell acts on the resulting state.

The four exceptions:

1. **Geometry between sets of entities** (which mobs a sword, a star or a
   blast touches). The scan writes what it found as facts (an `Hp`, a touch, a
   hit); a rule decides what it means. A scan never decides anything.
2. **Retraction and teardown.** A rule flags; one reaper step outside the
   rules retracts (see "Request and reaper").
3. **Building a session**: the factory, fixtures, restore, and a new run or
   life's starting facts. There is no prior state to react to.
4. **Effects**: sound, files, quitting, the clock. They are not game logic;
   the shell owns them (see "Effects never").

Everything else is a rule, including single-entity state machines, per-entity
steps over a whole population, menus, timers and derived state.

**The test for adding an exception.** A new one must show one of:

- **A measurement.** On the cap gate command (see "The measured boundary"),
  the rule form puts the debug p99 above 75% of the tick (12.5 ms) or more
  than doubles the release p99, with both numbers and the command in the PR.
  For scale: enemy movement as a rule (`moveEnemy`, as shipped) measures 69%
  and 1.4 times, so it does not qualify; the sword-against-enemy join measured
  287% and 10 times, so it does.
- **An engine constraint**, cited to a line of the engine patch
  (`patches/pararules/engine.nim`) or to this skill.
- **It is an effect**, in which case it does not belong in the core at all.

"It was simpler" and "the order matters" are not reasons. Order is a beat
(see "Order and determinism").

**Every key press is a command rule** (see "A command"): the fight's menus
and the screens between fights alike. What is left in `hub.nim` and `life.nim`
besides readers is what the exceptions name: the teardown and the rebuilds a
rule asks the core for (a visit's start and end, the next life).

## 2. Reading state: getters

A getter is a named query: a `what` block with no `then`, so it never fires
anything. It gives `session.query` / `session.queryAll` a name for "the facts
matching this pattern".

```nim
rule player(Fact):          # a game's rules.nim
  what:
    (Player, PosX, x)
    (Player, PosY, y)
    (Player, Hp, hp)
    (Global, Phase, phase)

rule enemies(Fact):         # rules.nim:885: one match per entity
  what:
    (id, Enemy, kind)
    (id, Hp, hp)
    (id, PosX, x)
    (id, PosY, y)
    (id, SealedUntil, sealedUntil)
    (id, StaggerUntil, staggerUntil)
```

```nim
let (x, y, hp, phase) = sim.session.query(gameRules.player)       # a singleton
for e in sim.session.queryAll(gameRules.enemies):                 # per entity, e.id
  ...
```

- `query` returns the one match (the lowest `(id, attr)` if there are several)
  and raises an index error when there is none yet, so it is for facts that
  always exist. `queryAll` returns a `seq` and is empty when nothing matches,
  which makes it the safe read for a fact that exists only sometimes
  (`systems.nim:679`, `cancelFieldConfirm`, checks `queryAll(...).len > 0`).
- A singleton getter names fixed ids (`Player`, `Global`); an entity getter
  binds `id` and every match carries it.
- Reading through getters from a procedure, the draw, a test or the shell is
  idiomatic. It is never a gap to close.
- A getter has no `then`, so it can't loop or re-trigger anything. It is not
  free of the state hash: see "Proving a rules change" before adding one that
  can match in an existing run.

## 3. Three triggers

A mutating rule has exactly one trigger: the `what` line without
`then = false`. Everything else it reads carries `then = false`, or the rule
also fires when that fact changes (which is how two rules re-trigger each
other into the recursion limit). The trigger goes **last**.

The three kinds differ only in what the trigger is.

### A beat: a tick stage, a timer, a per-entity step

The first beat a game has is the per-tick `DeltaTime` insert (`core.nim:327`,
`template/template.nim:136`), the trigger of its per-tick rules:

```nim
rule tickTime(Fact):        # rules.nim:1005
  what:
    (Global, TotalTime, total, then = false)
    (Global, DeltaTime, dt)
  then:
    session.insert(Global, TotalTime, total + dt)
```

`pickupFlight` (`rules.nim:1016`) is the per-entity form: it lists the pickup's
own attrs first, the player's position next, `DeltaTime` last, all but the
last with `then = false`, and moves each magnetized pickup toward the player.
One firing per matching pickup, in `(id, attr)` order.

`DeltaTime` is the oldest beat, and the one left standing. The rest of a
tick is a schedule of named beats (`core.schedule`: the treasures' gate, the
caster, pending spawns, deaths, the haul, the mirror's offer, the mobs' step,
the contact hit, waves, the qi bar, a visit's clock, the locked bar's timer, a
tribulation's three), each
a pulse (next section) a rule subscribes to by making it its trigger, so
"after" is the order of the schedule's rows:

```nim
rule lockTimer(Fact):       # rules.nim:2034
  what:
    (Player, PosX, x, then = false)
    (Player, PosY, y, then = false)
    (Global, Stage, stage, then = false)
    (Global, LockTicks, ticks, then = false)
    (Global, LockBeat, beat)
  then:
    session.insert(Global, LockTicks, ticks + 1)
    if ticks + 1 >= autoStartTicks:
      session.beginTribulationAt(x, y, stage, stallPenaltyBolts)
```

A beat's value (`Beat`, `schema.nim`) carries what its rules cannot join, as a
command's does: the tick, whether a life is running, and the facts that
exist only sometimes (a visit). **An entity born on a beat is not that beat's.**
A rule over a set of entities fires for the ones that stood when the beat was
pulsed, so what must also act on the newborn is a later beat: a tribulation's
clock telegraphs a bolt on `TribulationBeat`, and `BoltsBeat` then counts
every bolt down, that one too.

**A step over a whole population is one per-entity rule on its beat.**
`moveEnemy` (`rules.nim:2604`) is every enemy's step at the player, on
`MoveBeat`: the enemy's own attrs, the two it writes (`PosX`, `PosY`) last
among them, the tick and the player's position read from the beat's value and
never joined, a despawn a `Gone` mark for the reaper. One firing per enemy,
each writing only its own entity. So a new enemy kind's movement is not a
procedure. A kind that walks like the rest is its `enemyDefs` row (its speed).
One that moves another way is a column on that row the rule reads, or a second
rule on `MoveBeat` whose `cond:` reads the row, with the same `what` shape.

### A changed fact: derived state, a threshold

Same shape, the trigger is whatever fact changed:

```nim
rule onLevelUp(Fact):
  what:
    (Player, Hp, hp, then = false)
    (Player, Level, level)   # fires only when Level itself changes
  then:
    session.insert(Player, Hp, hp + 10)
```

`settleLevel` (`rules.nim:2657`) is the live one. It was a procedure its two
callers had to remember to call after they wrote `Cultivation`; the rule reads
`cultivationCurve` (a content row, `data.nim:1981`) and the pure function
`subLevelAt` (`rules.nim:92`, above the ruleset, where a `then` can name it):

```nim
rule settleLevel(Fact):
  what:
    (Global, Realm, realm, then = false)
    (Global, SubLevel, subLevel, then = false)
    (Global, HalfStepLocked, locked, then = false)
    (Global, Cultivation, cultivation)
  then:
    let at = subLevelAt(cultivationCurve[realm], cultivation)
    if at.level != subLevel:
      session.insert(Global, SubLevel, at.level)
    # ... the half-step lock
```

Nothing calls it. Every write to `Cultivation` settles the level, a
failed advance roll (the cost it takes) included. That is every
writer: a golden fixture states sub-level ten with no lock, the rule locked the
bar and the frame moved, so `applyFixture` (`fixture.nim:269`) puts the level
facts back after its write. A writer that states facts outright has to say so.

### A command: something the player did

The shell maps a tick's keys to command values (`keys.tickInput`, a pure
mapping) and `core.advance` pulses each one pressed as a `Command` fact, in
`CommandKind` order (`core.nim:260`, `run`). The rule's trigger is the command:

```nim
rule openPause(Fact):       # rules.nim:1246
  what:
    (Global, Command, cmd)
  cond:
    cmd.kind == PauseCmd
    phaseDefs[cmd.phase].canPause
  then:
    if FieldArmed in cmd.scene:
      session.insert(Global, FieldConfirmUntil, fieldLapsed)
    session.insert(Global, PausedFrom, cmd.phase)
    session.insert(Global, PauseSelected, ord(ResumeChoice))
    session.insert(Global, Phase, Paused)
```

The `if phase ...` branches the old `step` held are the `cond:` lines. Three
things a command rule has to get right:

- **Read the screen from the command, not from `Phase`.** `cmd.phase` is the
  phase the command was pulsed on. A rule whose match first completes while
  the pulse stands fires in the next pass of the same pulse: `openPause`
  writes `PausedFrom`, which completes `closePause`'s match, and a
  `closePause` that joined the live `Phase` closed the pause it had just
  watched open. What such a rule decides on must be fixed for the pulse
  (`cmd.phase`, `cmd.scene`) or already used up (a card rule finds its menu
  closed).
- **A fact that exists only sometimes rides on the command.** pararules has no
  "this fact is absent" condition, and a rule that joins a fact cannot fire
  without it. `GameCommand.scene` carries those as flags (`LabOpen`,
  `FieldArmed`, ...) and its optional fields the values, read by the core as
  it pulses (`core.scene`, `core.act`).
- **It cannot retract.** `openPause` cancels the armed confirm by writing
  `fieldLapsed`, a deadline already past, which the reaper retracts (see
  "Request and reaper").

## 4. The pulse

A pulse is a trigger fact the core inserts, lets the rules fire on, and
retracts. It exists because of a quirk, reproduced on main: **a trigger fact
left standing in the session re-fires its rule for the first new match that
arrives after the match set was empty.** With `DeltaTime` standing, the first
flying pickup dropped on an empty field moves 6 units the moment it spawns
(`pickupFlight`, `rules.nim:1016`; spawned at x=60, read back at x=54 with no
tick stepped), and the second one does not. The fix is a trigger that does
not stand. The pickup quirk itself is not fixed: it is baked into every hash
and balance number.

```nim
session.insert(Global, Beat, value)   # outside any rule: fires at once
session.retract(Global, Beat)         # outside any rule: leaves nothing behind
```

- Insert and retract happen outside a rule (an insert outside a rule fires
  immediately, `engine.nim:561`). The retract is legal there; see "Request and
  reaper".
- A pulse fires at the same point in the tick as the procedure it replaces and
  in the same entity order, which is what keeps hashes unchanged when you port
  one.
- **Carry values on the pulse.** The trigger's value can be a tuple or a small
  object: the tick, the player's position, whatever the rule needs that is
  written every tick. A `then` can't read another rule or the sim's tick, so
  what it needs rides on the pulse (see "Join order" for why that also makes
  the rule cheaper).
- `isNew` (`engine.nim:296`) is the engine's own test for "this fact was not
  in the match before"; it is what a standing trigger trips.
- `paraloop/sim.pulse` does insert, fire, retract in one call:
  `sim.pulse(Global, Beat, value)`, or on a `session`. It fires once more
  after the retract, so anything the retract queued runs too and nothing is
  left pending.

## 5. A state machine in one rule

A thing that walks states on a budget is one rule, not a procedure plus a
rule. `treasureTick` (`rules.nim:1044-1064`) is the model:

```nim
rule treasureTick(Fact):
  what:
    (id, TreasureStage, stage, then = false)
    (id, TreasureTimer, timer, then = false)
    (id, TreasureDurations, durations, then = false)
    (id, ReleaseNow, release, then = false)
    (Global, TreasuresTick, active, then = false)
    (Global, DeltaTime, dt)
  cond:
    active
  then:
    if (stage == Rising and release) or timer + 1 >= durations[stage]:
      let next = if stage == high(TreasureState): low(TreasureState) else: succ(stage)
      session.insert(id, TreasureStage, next)
      session.insert(id, TreasureTimer, 0)
      if release:
        session.insert(id, ReleaseNow, false)
      if next == Smash:
        session.insert(id, SmashPending, true)
    else:
      session.insert(id, TreasureTimer, timer + 1)
```

What to copy from it:

- **The machine's whole state is facts**: stage, timer, the budget
  (`TreasureDurations` is a fact, copied in from the row by
  `systems.acquireTreasure`; `rules.nim` can read the row now, but dropping the
  fact moves every state hash, so the ship that does says so), and an early-exit flag
  (`ReleaseNow`) that another actor sets and the rule honours and clears.
- **It writes only its own entity** (see "What a `then` can and cannot do").
- **It raises a request on entry** (`SmashPending`) for the part it can't do
  yet, and a step outside the rules consumes it.
- A phase gate is a fact the rule's `cond:` reads (`TreasuresTick`), not a
  call it makes.

The same shape is the right one for the caster's deadline machine, the lock
timer and tribulation, a pause menu and a visit clock: one entity, discrete
triggers, a deadline. These are single-entity state machines. They are rules,
not exceptions. The pause menu is one (its triggers are commands), and so are
the caster, a spent blade, the lock timer, the tribulation and the visit clock
(`beginCast`, `releaseVolley`, `retireBlade`, `holdCast`, `lockTimer`,
`tribulationClock`, `tribulationVerdict`, `visitClock`: their triggers are
beats).

## 6. Request and reaper

A rule never retracts. When a rule's outcome needs something it can't do
(retract), it writes a request fact. One step outside the rules, after they
settle for the tick, acts on the request and clears it.

`SmashPending` is the live example: `treasureTick` raises it on entering
`Smash`; `systems.processTreasures` (`systems.nim:622`) resolves each flagged
treasure through its pattern's slot and sets it back to `false`. Nothing else
reads or writes it, so it is never in a snapshot taken between ticks.

A command rule asks the same way: it inserts a `Request` (`schema.nim`'s
`RequestKind`) and `core.settle` (`core.nim:226`) carries it out and retracts
it before the next command. `settle` reads it through the `requests` rule,
which is not a getter: its `then` is an empty `discard`, so its trigger is
cleared when it fires. A getter over a request attr would leave its trigger
set from the first request on and move every replay's `stateHash` (see
"Proving a rules change").

Rules for requests and reapers:

- The rule decides; the reaper only carries out. A reaper that also decides is
  a procedure holding game logic.
- One reaper in the core, not one per system. A rule marks an entity that is
  done with `Gone` (its value says what kind it is: a fallen enemy, a
  collected pickup, a spent sword, a placed spawn, a struck bolt), and
  `core.reap` retracts the mark and the entity's facts (`rules.entityAttrs`)
  as soon as the pulse that marked it has settled, so no later slot reads it.
  A request is cleared in the same tick it is raised, and so is a mark: neither
  is ever in a snapshot.
- A teardown (`retractEnemy`, `retractTreasure`, `life.clearField`) is exception
  2 and lives here: the rule flags the entity, the reaper retracts its facts.
- **The core places an entity whose arrival a standing trigger would catch.**
  A kill's loot is decided by `dropLoot` (what, where, which tier, a chain
  elite's heir among it) and placed by the core (`DropsDue`,
  `systems.placeDrops`), one drop at a time in the order the rule listed.
  Inserted inside the `then`, every pickup of that firing would arrive in one
  pass and each would fly at once (the quirk in "The pulse"; only the first
  does, in every replay hash), and the pickup cap's eviction is a retraction.
- What `processTreasures` does with a request besides retracting (spawning,
  drawing) moves into the rule: ids and the RNG are reachable from a `then`
  (`session.nextId()`, `session.rng`), and content rows are readable
  (`rules.nim` imports `data.nim`). The geometry inside a smash stays a scan
  (exception 1).

## 7. Derived state

A rule that keeps one fact in line with another replaces a procedure every
writer must remember to call. `settleLevel` above is the pattern: write
`Cultivation`, the rule sets `SubLevel`.

`gateTreasures` is the same on a beat: it keeps the `TreasuresTick` fact in
line with `phaseDefs[phase].treasuresTick`, which a procedure
(`syncTreasureGate`) copied "before this tick's `DeltaTime` insert". The fact
itself stays (dropping it moves every state hash, so the ship that does says
so).

For a total or a collection over many entities, a per-entity `then` is wrong
(each firing sees the values from the start of the pass, see "What a `then`
can and cannot do"). Use `thenFinally`: it runs once per pass, after that
pass's `then` blocks (`engine.nim:509`), with `session` and `this`, so
`session.queryAll(this)` reads every current match and one insert writes the
total. Nothing in the repo uses `thenFinally` yet; test it before relying on
it.

## 8. What a `then` can and cannot do

- **It sees its own match, `session` and `this`.** It cannot name another
  rule. `session.queryAll(gameRules.enemies)` inside a `then` fails to
  compile: `undeclared identifier: 'gameRules'`. What a rule needs must be
  joined in its `what`, carried on its trigger's value (the pulse), or kept
  as a derived fact another rule maintains.
- **It reads values as they were when its pass began.** The engine copies the
  matches first (`engine.nim:491-502`), then runs every queued `then`. Two
  hundred firings that each add to one total all read the same old total. A
  per-entity rule writes only its own entity.
- **Its inserts queue until it returns, so a `then` is atomic.** A `then` runs
  with `insideRule` set (`engine.nim:240-244`) and `fireRules` returns at once
  while it is (`engine.nim:456`); the queued rules fire in the next pass. A
  transition written in one `then` is seen whole. A procedure that inserts
  fact by fact is seen half-written by anything reactive, which is why a
  reactive rule must tolerate it, or the writer batches with `autoFire` off as
  `sim.restore` does (`src/paraloop/sim.nim:104-111`).
- **It cannot retract.** See "Request and reaper" and the next section.
- **Content rows are in reach.** `rules.nim` imports `data.nim` (`data.nim`
  imports `schema.nim`, the types, so there is no cycle): a rule reads a
  content row directly (`pickupFlySpeed`, `data.nim:499`). `TreasureDurations`
  stays a fact because dropping it would move every state hash.
- **Ids, the RNG and counts are on the session.** A `then` can allocate ids
  and draw from the seeded RNG, so a spawner or a roll is a rule:
  `session.nextId()`, `session.rng.rand(99)` (`paraloop/sim`; they are the
  sim's own, so a rule that draws leaves the state a procedure doing it by
  hand would). It cannot name another rule, but `session.matchCount("enemies")`
  counts that rule's matches by name in O(1).
- **No effects.** See "Effects never".
- **Nothing outside the sim's seeded RNG.** `std/random`'s global procs are
  banned in game code (root `AGENTS.md`).

### Never retract inside `then`

Retracting a fact inside a `then` block can re-trigger rules mid-fire in an
order that depends on which rule happened to run first, not on the facts --
exactly the nondeterminism `paraloop/sim`'s patched pararules engine
(`patches/pararules/engine.nim`) exists to avoid elsewhere. Retract facts
from the reaper step (or the game's own tick code) after rules have settled
for that tick, never from inside a `then`. This is exception 2.

## 9. Join order

pararules builds one join per `what` line, in `what`-line order, and a join
at the front of the chain is the expensive one under load.

- A per-entity rule lists that entity's own attrs **first**, then the attrs
  written most often **last among them**, then the trigger last.
- **Never join a second entity that is written every tick** (the player's
  position, say) to a rule over a whole population. Put its values on the
  pulse instead. Measured at the 200-mob cap, debug build: joining the
  player's position in cost 6.70 ms p50 for the movement rule; carrying the
  tick and position on the pulse with the hot attrs last cost 3.72 ms.
- `moveEnemy` (`rules.nim:2604`) is the rule over 200 mobs: own attrs first,
  the positions it writes last among them, the player's position on the
  pulse. With the positions ahead of the two seal deadlines instead, the same
  rule measured 13.2 ms debug p99 at the cap against 11.6 (one run).
  `pickupFlight` (`rules.nim:1016`) is older and joins the player's position;
  few pickups fly at once, and every hash has it so.
- A join between two sets of entities (every sword against every enemy) is
  the cliff, and exception 1.
- **Keep a rule to ten variables.** A match (`FactMatch`) holds a slot per
  variable of the rule that binds the most, and every join of every rule
  copies matches of that width: a sixteen-variable rule measured +0.2 ms p50
  a tick on a run that never fired it. Ten is the widest getter (`swords`);
  what a rule needs past that rides on its trigger's value, as the stamp's
  steering takes the player's position and facing from its beat
  (`steerStamp`; `tests/test_combat_beats.nim` holds the width).

## 10. Order and determinism

- **Firing order is rule order, then `(id, attr)`.** The patched engine sorts
  the queued `then` blocks by rule add order and then by match
  (`engine.nim:473-476`), so **the order of rules in the file is semantic**
  for rules that share a trigger. The same match set fires in the same order
  on every host, which is what makes a snapshot, a replay and a hash agree.
- **A cascade stops at 16 passes** (`engine.nim:455-468`,
  `recursionLimit`). Chains must stay shallow. A rule that triggers a rule
  that triggers a rule is a design smell before it is a limit.
- **A beat is how you say "after".** The tick's order is `core.schedule`, a
  table of slots run top to bottom, each in the phases its row names. A
  constraint such as "before deaths: a fresh pending spawn waits the full
  respawnTicks" is the position of a row; "nothing later this tick may move
  the phase on again" is a column (`ends`). A slot pulses its beat or runs
  the exception that holds it. New per-tick logic is a
  rule on an existing beat, or a new beat: an attr, a `schema` line and a row.
- **A slot reads before it pulses.** What a beat's rules cannot join (which
  enemy fell, which pickup is in reach, whether a mob touches the player) the
  slot's reading scans for and puts on the beat's value (`core.readDeaths`,
  `readHaul`, `readTouch`). The scan decides nothing; a reading that found
  nothing returns false and the beat is not pulsed, so an idle slot visits no
  join.
- **"The order matters" is not an exception.** It is a beat.

## 11. The measured boundary

All figures measured on 2026-10-12 on one host (32 cores,
load under 1), Nim 2.2.10, native build. "Debug" is the build the sim gate
used to run (CI no longer runs the cap gate); "release" adds `-d:release`. Nothing here is from the web build.

The cap gate, no longer a CI step but still runnable:

```
para sim --game <game> --seed 7 --ticks 21600 --treasure SealingStamp \
  --min-smashes 60 --min-mobs 200 --keep-alive --hold-mobs 200
```

It prints `perf: sim p50 ... p99 ... (budget ...)`; the budget is the
16.667 ms tick (`tools/para/simcmd.nim`, `--budget-ms` overrides it).
Main's baseline is p50 1.70 ms and p99 6.4 ms in debug (three runs: 6.35, 6.59,
6.41), and p50 0.231 / p99 0.804 ms in release.

Per-entity enemy movement over 200 mobs and the join, at the cap:

| variant | debug p50 | debug p99 | release p50 | release p99 |
|---|---|---|---|---|
| main (procedures) | 1.70 | 6.4 | 0.231 | 0.804 |
| a rule that joins the player's position | 6.70 | 15.27 | not run | not run |
| a rule with tick and position on the pulse, hot attrs last | 3.72 | 9.74 | 0.413 | 1.064 |
| the same plus a sword-against-enemy join | 3.82 | **47.80**, over budget | 0.462 | **8.049** |

How to read it:

- **One per-entity rule over 200 mobs is affordable**: +2.0 ms p50 and +3.3
  ms p99 in debug, +0.18 ms and +0.26 ms in release (1.1% of the tick). It is
  3.4 times the procedure in release (241 against 70 microseconds). It is not
  free.
- **As shipped** (`moveEnemy`, `rules.nim:2604`; 2026-10-13 against main
  `a06959b`, five runs a side, alternated): debug p50 2.06 to 4.44 ms and p99
  7.66 to 11.58 ms (69% of the tick); release p50 0.248 to 0.454 ms and p99
  0.869 to 1.199 ms (1.4 times). Main's debug p99 had already risen from 6.4
  to 7.7 ms since the scout, so the debug gate has room for about one more
  rule of this size before p99 passes the tick, not three: measure the next
  one before it lands.
- **The join shape matters more than the rule.** A second entity written every
  tick cost 1.8 times the pulse form.
- **An entity-against-entity join is the cliff.** With one or two swords in
  flight (378 pairs a tick on average, sword level 1) release p99 went from
  0.8 to 8.0 ms, and the sword stage from 36 to 943 microseconds a tick. Level
  5 launches eight swords a volley on a 14-tick cooldown (`data.nim:1083-1089`,
  `swordDefs`), so at least eight times the pairs. That is exception 1.
- **Procedures pay mostly for reading, not for logic.** The pending-spawn
  procedure (`tickSpawns`, now the `placeSpawn` rule) did almost nothing at
  the cap except one `queryAll(gameRules.enemies)`, about 380 microseconds in
  debug and 46 in release for 200 rows, and four or five systems repeat that
  read every tick. A rule is handed its matches; a
  procedure that re-reads them pays again.

Not measured: the web (wasm) build, sword levels above 1, a full port of sword
hits, compile time with 150 rules, memory. Treat a rule family's cost as its
own measurement before it joins this table.

To rerun for a PR: build `para` (debug, `nim c --hints:off --outdir:tmp
tools/para/para.nim`), run the command above on the branch and on main, and
paste both p50/p99 lines.

## 12. Effects never

A `then` writes the session and nothing else. The shell performs every effect
(sound, a file write, quitting, the clock) afterwards, from the resulting
state. The furthest edge of rule firing is the core's edge: rules are the
functional core, and rendering and engine code just read the state the rules
power.

- **Prefer the diff.** `sfx.nim` does this for every one of its events:
  `snapshot` the facts, then `sfxEvents(prev, cur)` (`sfx.nim:48`, `:76`),
  and `observe` plays what the change calls for (`sfx.nim:159-172`). The shell
  holds "the last state I acted on" as its own state; after a restore it
  starts from the restored value so it does not replay.
- **One-shot events become a counter or a stamp fact the shell diffs.** The
  repo already does this: `FieldTick`, `HitTick`, `RealmUpTick`,
  `EffectTick` and `RunEndTick` each record the tick something last happened
  (`schema.nim:47-49`, `:94-98`, `:120-124`), so a diff can see an event a
  state change alone would hide. Use a **counter** where the event can repeat
  while the tick stands still (a paused tick isn't counted,
  `core.nim:533-539`, so two saves in the Lab share a tick); use a
  **stamp** where the tick is enough.
- **Don't use a request the shell reads and clears.** It makes the shell a
  writer. A request the *core* consumes (`SmashPending`) is fine: it's cleared
  in the same tick and never in a between-ticks snapshot.
- **A counter or stamp is an ordinary fact written only by a rule**, so a
  headless run and a windowed run hash the same and a snapshot carries it.
- **Results that come back are inputs.** A profile load, saved dials: the
  shell hands them in the way it hands in keys, so a replay can record them.
  Game logic never reads a shell field. The saved dials ride on the tick's
  input (`TickInput.saved`) and on the command pulsed from it (`cmd.saved`,
  the Lab's reset); a standing fact for them would be in every run and move
  every hash.
- **Restart is not an effect.** A fresh session from `seed + 1` and the dials
  is a pure rebuild of state, so it is exception 3, done by the core
  (`core.restartRun`, `core.nim:123`).

The live shape: `core.advance(sim, input)` performs nothing. The shell reads
the state before and after the tick (`core.seen`) and `core.effectsDue(prev,
cur)` says what the change asks of it, the way `sfx.sfxEvents` says what it
sounds like: the profile write when a visit ended or the life went into the
ledger, quit and the Lab's save when their counter (`QuitsAsked`,
`SavesAsked`) rose, a dial change when the dials differ. The game's `step`
performs them (`perform`). The rule that confirms Quit only bumps the counter,
from the count the command carries, since a rule cannot join a fact that may
not exist yet:

```nim
if choice.quits:
  session.insert(Global, QuitsAsked, cmd.quits + 1)
```

Mute never touches the sim, so it is the shell's key alone.

## 13. Proving a rules change

"Does the hash move" is the first question on every rules change.

- **`stateHash`** (`src/paraloop/sim.nim`) covers every fact, the tick, seed, RNG
  state, id allocator **and `pendingRules`**: the names of getters whose
  trigger is set. So **adding one getter that matches in a reference run moves
  the state hash**, though no fact changed. Measured: `--seed 7 --ticks 3600`
  moved from -428982057051841543 to -1886539081449337328 for one added getter.
  `rules.nim:1066-1072` already warns about it: a getter must not partly match
  from the first tick, nor read an attr a run changes every tick.
- **`factsHash`** (`src/paraloop/sim.nim`) is the same hash without the pending
  rule names; it does not move for a getter. `para sim` prints `hash` and
  `facts-hash`, and `--trace N` prints the facts hash every N ticks, so a
  change is compared against main tick by tick.
- A new fact appearing only when used (as `PausedFrom` does) leaves a run
  that never uses it byte-identical.

The proof block, run on the branch and on main, pasted into the PR body:

```
para sim --game <game> --seed 7 --ticks 3600
para test --filter test_hollow_script                     # the seven-room walk, its final hash pinned
```

The unscripted seed-7 run presses no key, so it proves nothing about menus;
the hollow script does. A port that is meant to be behaviour-neutral
should leave the hashes byte-identical;
if a derived fact had to be added, say which, and show every pre-existing fact
equal at each Nth tick. A change that moves a hash on purpose (a reaction
that fires at the write, not at the next beat, changes RNG draw order) needs
a reviewed re-pin (`test_hollow_script.nim`), re-captured
goldens and a playtest.

## 14. Testing a rule

Drive the rule the way the game does and assert on a getter.

- **Headless**: `initSim(newGameSession(), seed = 7, idType = Id)`, write facts,
  then `insert(Global, DeltaTime, fixedDt)` to fire per-tick rules. Assert
  with `queryAll(gameRules.<getter>)`, not by peeking at facts.
  A game's rule test is the model: "`step`
  minus the systems call: only the rule runs", one tick at a time, checking
  `pending` on the exact tick the rule raises it, then calling the reaper and
  checking it cleared. The scaffold is `seededGame` (`:18`).
- Drive a command rule by its command, not by faking a key: `sim.act(ConfirmCmd)`
  (`core.act`) pulses it the way `advance` does and settles it
  (`tests/test_commands.nim`). Drive a beat rule by its beat:
  `sim.beat(SpawnsBeat)` (`core.beat`) runs the slot's reading, the pulse,
  what the rules asked of the core and the reaper (`tests/test_beats.nim`).
- **Test the "no match yet" case.** A getter queried before its facts exist
  raises an index error (see "The `query` index error"). A rule gated on a
  fact that doesn't exist must be quiet on the empty session, and a test
  that never inserts it asserts exactly that.
- **Test replay**: `template/tests/test_template.nim` drives `stepTick` from a
  script and checks two runs hash the same.

---

## Mechanics and errors

### Schema and `gameRules`

```nim
import pararules

type
  Id* = enum
    Global, Player
  Attr* = enum
    DeltaTime, TotalTime, WorldWidth, WorldHeight, Phase,
    PosX, PosY

schema Fact(Id, Attr):
  DeltaTime: float
  TotalTime: float
  PosX: int
  PosY: int
  # ...

let (newRawSession*, gameRules*) =
  staticRuleset(Fact, FactMatch):
    rule player(Fact):
      what:
        (Player, PosX, x)
        (Player, PosY, y)
```

Two gotchas that only show up once a game's rules live in their own module
(as `template/`'s do), not inline in one file like a quick prototype:

- **Don't call the destructured session factory `initSession`.** `pararules`
  itself exports a public `macro initSession*(dataType: type, ...)`. Give
  your own binding any other name (`newRawSession` above) -- reusing
  `initSession` compiles, but a caller in a *different* module that does
  `import pararules` and `import rules` both sees your binding shadowed by
  pararules' own macro, and gets a confusing type-mismatch pointing at the
  macro's signature instead of an undeclared-identifier error.
- **A file that calls `stateHash`/`dumpFacts`/`queryAll` needs its own
  `import pararules`,** even if it never names a pararules symbol directly
  (say, a test that only imports the game module and `paraloop/sim`).
  `queryAll`'s generic body (`patches/pararules/engine.nim`) calls
  `sequtils.toSeq` on a `HashSet`, and Nim's overload resolution for that
  open generic call pulls in scope from every frame of the call chain,
  including the outermost caller's. Without `import pararules` there, it
  fails with a `HashSet`-flavoured "type mismatch: items(nodes)" that has
  nothing obviously to do with the missing import.

`schema` generates a variant type (`Fact`) with one case per `Attr`, plus
`insert`/`retract`/`contains` for it. `staticRuleset` compiles the `rule`
blocks and hands back a session factory (a fresh, ruleless `Session[Fact,
FactMatch]`, named `newRawSession` above -- never `initSession`) and a tuple
of compiled rules -- always destructure the second one as `gameRules` (see
AGENTS.md "Name the ruleset `gameRules`"): the module is `rules`, and
`ruleset` is a pararules keyword, so `gameRules` is the one name every game
uses, never a per-game one (`helloRules`, `survivorsRules`, ...). Add a rule
to a session with `session.add(gameRules.someRule)`, or all of them via
`for r in gameRules.fields: session.add(r)`.

`template/rules.nim` teaches the per-tick trigger (one getter, one `DeltaTime`
rule) and the command trigger (`move`, pulsed by the shell); the worked
changed-fact rules above are here, not in the template.

### Snapshot, restore and the state hash

`paraloop/sim.Sim[T, MatchT]` bundles a session with a seeded RNG, a tick
counter and an id allocator (report §3.4 R2/R3/R7) so the whole game state is
`queryAll(session)` plus those few fields. The RNG and the allocator are held
in the session's context, which is how a `then` reaches them:

```nim
import paraloop/sim

var sim = initSim(newGameSession(), seed = 1'i64, idType = Id)
let snap = sim.snapshot()                       # deep-copies every fact
let restored = restore(snap, newGameSession, Attr)  # a fresh session, same state
doAssert sim.stateHash == restored.stateHash
```

`restore` needs `Attr` explicitly (it can't be inferred from `queryAll`'s
raw `(id, attr, value)` tuples) and `newGameSession` as a zero-arg factory
that returns a session with every rule already added -- write that proc once
per game (`template.nim`'s `newGameSession`) and pass it by name. Take
snapshots and hashes *outside* rule execution -- mid-fire, a session carries
pending `then`/`thenFinally` work a snapshot needs to capture too (`Sim`'s
module doc). A snapshot taken between ticks carries no request a rule raised
and the core consumed in the same tick; one a rule leaves standing is
carried.

### The three errors you'll actually hit

**Recursion limit** (`fireRules` raises after `recursionLimit`, default 16):

> Recursion limit hit. The current limit is 16 (set by the recursionLimit
> param of fireRules).
> Try using `then = false` to prevent triggering rules in an infinite loop.

Almost always a missing `then = false` on some `what` line whose insert
retriggers the same rule (or a cycle of rules) every pass. Find the rule
whose `then` re-inserts a fact matched by one of its own *other* `what`
lines (or another rule's), and add `then = false` there.

**A value at the wrong type, at runtime, in a debug build.** `schema`
generates `Fact` as a case object (one variant per `Attr`); each attr's
declared type is enforced at the call site in release builds (a compile
error for a literal type mismatch) but a debug build can still hit a field
access mismatch if a fact was inserted with the wrong branch active
(usually from a generic helper that took the wrong `Attr`). The fix is
always at the `insert`/`retract` call that put the value in with the wrong
attr, not at the rule reading it.

**The `query` index error** (`find` returns `-1` when nothing matches yet,
and `get` indexes into an internal seq with it): `session.query(prod)` on a
rule with no match yet raises an index error, not a clean "no data" value.
This happens most often at start-up, when a getter is queried before its
starting facts are inserted (e.g. `getPlayer` before the game state's
`insert(Player, ...)` calls have run) -- always insert a getter's facts in
the session factory (`template.nim`'s `newGameSession`) before anything
queries it, and check `session.contains(id, attr)` first for a genuinely
optional fact, or read with `queryAll(...)` and test `.len`.
