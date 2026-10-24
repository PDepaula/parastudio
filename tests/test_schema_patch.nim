import unittest
import pararules
from pararules/engine import nil

# The patched pararules macros (patches/pararules/pararules.nim).
# `schema`: one generic `insert` and one generic `retract` instead of an
# overload per value type. Pins that they do what the per-type overloads did,
# for every way a value reaches a session.
# `staticRuleset`: a match is `kind` plus one array of slots shared by every
# rule instead of a variant branch per rule. Pins that rules of different
# widths still read their own variables.

static: doAssert declared(pararules.paraloopSchemaPatched),
  "patches/pararules/pararules.nim is not applied; check patchFile in config.nims"
static: doAssert declared(engine.paraloopEnginePatched),
  "patches/pararules/engine.nim is not applied; check patchFile in config.nims"

type
  Id = enum
    Global, Player
  Attr = enum
    Count, Speed, Name, Alive, Mood, Owner, Tags
  MoodKind = enum
    Calm, Angry
  Strings = seq[string]

schema Fact(Id, Attr):
  Count: int
  Speed: float
  Name: string
  Alive: bool
  Mood: MoodKind
  Owner: Id
  Tags: Strings

let (initSession, rulesInternal) =
  staticRuleset(Fact, FactMatch):
    rule getCount(Fact):
      what:
        (id, Count, count)
    rule getSpeed(Fact):
      what:
        (Global, Speed, speed)
    rule getName(Fact):
      what:
        (Global, Name, name)
    rule getAlive(Fact):
      what:
        (Global, Alive, alive)
    rule getMood(Fact):
      what:
        (Global, Mood, mood)
    rule getOwner(Fact):
      what:
        (Global, Owner, owner)
    rule getTags(Fact):
      what:
        (Global, Tags, tags)
    # A `then` inserts through the same generic proc as a caller outside a rule.
    rule doubleCount(Fact):
      what:
        (Player, Count, count)
      then:
        session.insert(Player, Speed, float(count * 2))
    rule getPlayerSpeed(Fact):
      what:
        (Player, Speed, speed)
    # The widest rule: five variables, where `getCount` has two and the other
    # getters one. `count` is the third here and the second in `getCount`.
    rule getWhole(Fact):
      what:
        (id, Speed, speed)
        (id, Count, count)
        (id, Name, name)
        (id, Alive, alive)
      cond:
        alive

static: doAssert compiles(FactMatch().vals),
  "patches/pararules/pararules.nim has lost its staticRuleset change (a match is one array of slots)"

let patchRules = rulesInternal

proc newSession(): Session[Fact, FactMatch] =
  result = initSession(autoFire = false)
  for r in patchRules.fields:
    result.add(r)

suite "schema patch: one generic insert and retract":
  test "insert wraps each value type the way its own overload did":
    var s = newSession()
    s.insert(Global, Count, 7)
    s.insert(Global, Speed, 1.5)
    s.insert(Global, Name, "wolf")
    s.insert(Global, Alive, true)
    s.insert(Global, Mood, Angry)
    s.insert(Global, Tags, @["a", "b"])
    s.fireRules()
    check s.query(patchRules.getCount).count == 7
    check s.query(patchRules.getSpeed).speed == 1.5
    check s.query(patchRules.getName).name == "wolf"
    check s.query(patchRules.getAlive).alive == true
    check s.query(patchRules.getMood).mood == Angry
    check s.query(patchRules.getTags).tags == @["a", "b"]

  test "an id-typed attribute takes an id or an int, and stores the int":
    var s = newSession()
    s.insert(Global, Owner, Player)
    check s.query(patchRules.getOwner).owner == Player.ord
    s.insert(Global, Owner, 41)
    check s.query(patchRules.getOwner).owner == 41

  test "the id is an enum or an int":
    var s = newSession()
    s.insert(Global, Count, 1)
    s.insert(900, Count, 2)
    let all = s.queryAll(patchRules.getCount)
    check all.len == 2
    check all[0] == (id: Global.ord, count: 1)
    check all[1] == (id: 900, count: 2)

  test "insert takes a value already wrapped in the fact type":
    var s = newSession()
    s.insert(Global, Name, initFact("crane"))
    check s.query(patchRules.getName).name == "crane"

  test "a second insert of the same id and attribute replaces the value":
    var s = newSession()
    s.insert(Global, Count, 1)
    s.insert(Global, Count, 2)
    check s.queryAll(patchRules.getCount).len == 1
    check s.query(patchRules.getCount).count == 2

  test "a rule's then inserts through the same proc":
    var s = newSession()
    s.insert(Player, Count, 21)
    s.fireRules()
    check s.query(patchRules.getPlayerSpeed).speed == 42.0

  test "retract with a value removes the fact":
    var s = newSession()
    s.insert(Global, Name, "wolf")
    s.insert(Global, Mood, Calm)
    check s.contains(Global, Name)
    s.retract(Global, Name, "wolf")
    check not s.contains(Global, Name)
    check s.find(patchRules.getName) == -1
    s.retract(Global, Mood, Calm)
    check not s.contains(Global, Mood)

  test "retract with only the id and attribute removes the fact":
    var s = newSession()
    s.insert(Global, Count, 3)
    s.insert(900, Count, 4)
    s.retract(Global, Count)
    s.retract(900, Count)
    check not s.contains(Global, Count)
    check not s.contains(900, Count)
    check s.queryAll(patchRules.getCount).len == 0

  test "contains reads an id and attribute without a value":
    var s = newSession()
    check not s.contains(Global, Alive)
    s.insert(Global, Alive, false)
    check s.contains(Global, Alive)
    check not s.contains(Player, Alive)

  when not defined(release):
    test "a debug build rejects a value of the wrong type, with upstream's message":
      var s = newSession()
      try:
        s.insert(Global, Name, 5)
        fail()
      except Exception as e:
        check e.msg == "Name should be a string"
      try:
        s.insert(Global, Count, "five")
        fail()
      except Exception as e:
        check e.msg == "Count should be a int or a Id"
      try:
        s.insert(Global, Speed, initFact(true))
        fail()
      except Exception as e:
        check e.msg == "Speed should be a float"
      s.insert(Global, Name, "wolf")
      try:
        s.retract(Global, Name, 5)
        fail()
      except Exception as e:
        check e.msg == "Name should be a string"
      check s.contains(Global, Name)

  test "a value whose type is not in the schema does not compile":
    var s = newSession()
    check not compiles(s.insert(Global, Count, 1'u8))
    check not compiles(s.insert(Global, Name, 'c'))
    check not compiles(s.retract(Global, Name, initFact("wolf")))
    check compiles(s.insert(Global, Count, 1))

suite "staticRuleset patch: one array of slots for every rule's match":
  test "a match is its rule's kind and a slot per variable of the widest rule":
    check FactMatch().vals.len == 5
    check FactMatch().vals is array[5, tuple[fact: Fact, isSet: bool]]
    check not compiles(FactMatch().getWhole)
    check not compiles(FactMatch().getCount)

  test "a wide rule and a narrow rule each read their own variables":
    var s = newSession()
    s.insert(900, Speed, 1.5)
    s.insert(900, Count, 3)
    s.insert(900, Name, "wolf")
    s.insert(900, Alive, true)
    s.insert(901, Speed, 2.5)
    s.insert(901, Count, 4)
    s.insert(901, Name, "crane")
    s.insert(901, Alive, true)
    let whole = s.queryAll(patchRules.getWhole)
    check whole.len == 2
    check whole[0] == (id: 900, speed: 1.5, count: 3, name: "wolf", alive: true)
    check whole[1] == (id: 901, speed: 2.5, count: 4, name: "crane", alive: true)
    # `count` sits in a different slot of `getCount`'s matches.
    let counts = s.queryAll(patchRules.getCount)
    check counts.len == 2
    check counts[0] == (id: 900, count: 3)
    check counts[1] == (id: 901, count: 4)

  test "a one-variable rule reads its slot beside a wide rule's matches":
    var s = newSession()
    s.insert(Global, Speed, 1.5)
    s.insert(Global, Count, 3)
    s.insert(Global, Name, "wolf")
    s.insert(Global, Alive, true)
    check s.query(patchRules.getWhole) ==
      (id: Global.ord, speed: 1.5, count: 3, name: "wolf", alive: true)
    check s.query(patchRules.getName).name == "wolf"
    check s.query(patchRules.getSpeed).speed == 1.5
    check s.query(patchRules.getAlive).alive == true

  test "a match waits for every variable of its rule":
    var s = newSession()
    s.insert(900, Speed, 1.5)
    s.insert(900, Count, 3)
    s.insert(900, Name, "wolf")
    check s.find(patchRules.getWhole) == -1
    s.insert(900, Alive, true)
    check s.find(patchRules.getWhole) != -1

  test "cond reads the match's variables":
    var s = newSession()
    s.insert(900, Speed, 1.5)
    s.insert(900, Count, 3)
    s.insert(900, Name, "wolf")
    s.insert(900, Alive, false)
    check s.find(patchRules.getWhole) == -1
    s.insert(900, Alive, true)
    check s.query(patchRules.getWhole).alive == true

  test "an updated fact replaces its slot and leaves the others":
    var s = newSession()
    s.insert(900, Speed, 1.5)
    s.insert(900, Count, 3)
    s.insert(900, Name, "wolf")
    s.insert(900, Alive, true)
    s.insert(900, Count, 8)
    s.insert(900, Name, "crane")
    check s.queryAll(patchRules.getWhole) ==
      @[(id: 900, speed: 1.5, count: 8, name: "crane", alive: true)]

  test "retracting one fact of a join drops the match":
    var s = newSession()
    s.insert(900, Speed, 1.5)
    s.insert(900, Count, 3)
    s.insert(900, Name, "wolf")
    s.insert(900, Alive, true)
    s.retract(900, Name)
    check s.find(patchRules.getWhole) == -1
    check s.queryAll(patchRules.getCount) == @[(id: 900, count: 3)]
