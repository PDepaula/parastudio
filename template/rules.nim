## __GAME__'s pararules schema and rules: the standard attrs every paraloop
## game keeps (parasurvivors-engine-scout report §4.2), one getter, one
## command rule and one per-tick rule (task 1.9 acceptance).
##
## Never imports paranim/paratext/parasound (AGENTS.md "Boundaries"), so
## `para test` runs this game's logic headless, with no GL context. Add game
## entities as `Id` values and their attrs as `Attr` values; put rules here,
## content tables in `data.nim` (AGENTS.md "Content is table rows": never
## `case` on a content enum outside `data.nim`).
##
## pararules gotchas (repo AGENTS.md, skills/pararules/SKILL.md):
## - a per-entity rule lists the entity's own attrs FIRST, `(Global,
##   DeltaTime, dt)` LAST (the join-order cliff);
## - every mutating rule has exactly one trigger: every other `what` line
##   carries `then = false`;
## - never retract inside `then` (`fireRules` raises after 16 passes);
## - a trigger fact is pulsed (`paraloop/sim.pulse`: insert, fire, retract),
##   never left standing in the session.

import pararules

type
  Id* = enum
    Global ## time, world size and phase -- every paraloop game keeps one
    Player ## the one entity this template starts with; add more as needed

  Attr* = enum
    # Standard attrs (report §4.2): `DeltaTime` is written once a tick by the
    # game's main file and is the per-tick rule's trigger (below). The window's
    # pixel size is not here: it is shell state `draw` reads, not game state.
    DeltaTime, TotalTime, WorldWidth, WorldHeight, Phase,
    # A command: something the player did, as a fact the shell pulses.
    MoveCommand,
    # Game-specific attrs from here down:
    PosX, PosY

  GamePhase* = enum
    ## The attr is named `Phase` (report §4.2's standard attr list); the type
    ## is named `GamePhase` so the two don't collide as the same identifier.
    Playing

  Step* = tuple[dx, dy: int]
    ## A move in world units. The command's value carries the amount, so the
    ## rule needs no speed constant: the shell decides how far a key moves.

schema Fact(Id, Attr):
  DeltaTime: float
  TotalTime: float
  WorldWidth: float
  WorldHeight: float
  Phase: GamePhase
  MoveCommand: Step
  PosX: int
  PosY: int

# `newRawSession`, not `initSession`: `pararules` itself exports a public
# `initSession` macro, and reusing that name for this module-level binding
# resolves a caller's `initSession()` back to the macro instead once it
# crosses an `import rules` boundary (it did, the first time this template
# was written) -- keep this name if you rename it, never call it
# `initSession`.
let (newRawSession*, gameRules*) =
  staticRuleset(Fact, FactMatch):
    # The getter: a pure read, so it's fine that it fires on every change to
    # what it reads (nothing here subscribes to it). The game's main file
    # calls `session.query(gameRules.player)` for `(x, y, phase)`. Player's
    # own attrs first, `Global` last, the same order a mutating rule needs.
    rule player(Fact):
      what:
        (Player, PosX, x)
        (Player, PosY, y)
        (Global, Phase, phase)

    # A command rule: `MoveCommand` is the one trigger (last, so the entity's
    # own attrs join first) and `PosX`/`PosY` carry `then = false`. The shell
    # turns held keys into a `Step` and pulses it with `sim.pulse(Global,
    # MoveCommand, step)`: the pulse inserts the fact, this rule fires, and
    # the fact is retracted, so the next key press is a new match and fires it
    # again. Writes the entity's own attrs only; never retracts.
    rule move(Fact):
      what:
        (Player, PosX, x, then = false)
        (Player, PosY, y, then = false)
        (Global, MoveCommand, step)
      then:
        session.insert(Player, PosX, x + step.dx)
        session.insert(Player, PosY, y + step.dy)

    # The per-tick rule: `(Global, DeltaTime, dt)` is the one trigger and
    # stays last; `TotalTime` above it carries `then = false` so only the
    # DeltaTime insert fires this rule. Advances TotalTime; never retracts.
    rule tickTime(Fact):
      what:
        (Global, TotalTime, total, then = false)
        (Global, DeltaTime, dt)
      then:
        session.insert(Global, TotalTime, total + dt)
