# Tests for paraloop/prof and the engine's `-d:prof` counters (built with
# -d:prof by tests/test_prof.nims): which pararules calls count as one
# outermost call (a nested insert or fire does not count twice), and the
# summary's shape, percentiles and warm-up cut on recorded samples given by
# hand. Call counts, not times: nothing here asserts on a clock.

import std/[unittest, strutils]
import pararules
from pararules/engine import profRulesCalls
import paraloop/prof

type
  Id = enum Global
  Attr = enum DeltaTime, Total, Pos

schema Fact(Id, Attr):
  DeltaTime: float
  Total: float
  Pos: int

let (newSession, rules) =
  staticRuleset(Fact, FactMatch):
    rule total(Fact):
      what:
        (Global, Total, t, then = false)
        (Global, DeltaTime, dt)
      then:
        session.insert(Global, Total, t + dt)
    rule positions(Fact):
      what:
        (id, Pos, p)

suite "engine counters under -d:prof":
  test "the build has the seams on":
    check profEnabled

  test "one outermost call each; the rule an insert fires and the insert it makes are inside it":
    var s = newSession()
    s.add(rules.total)
    s.add(rules.positions)
    let c0 = profRulesCalls
    s.insert(Global, Total, 0.0)
    check profRulesCalls == c0 + 1
    s.insert(Global, DeltaTime, 1.0) # fires `total`, whose then inserts Total: still one call
    check profRulesCalls == c0 + 2
    s.insert(5, Pos, 3)
    let c1 = profRulesCalls
    check s.queryAll(rules.positions).len == 1
    check profRulesCalls == c1 + 1
    s.retract(5, Pos)
    check profRulesCalls == c1 + 2
    check rulesNanos() >= 0

suite "profSummary":
  setup:
    resetProf()

  test "nothing recorded: every zone has 0 samples":
    let text = profSummary()
    check text.startsWith("prof: 0 frames and 0 ticks after 0 warm-up frames, tick budget 16.667ms\n")
    check "zones[6]{zone,samples,p50_ms,p99_ms,max_ms}:\n" in text
    check "  tick,0,0.000,0.000,0.000\n" in text
    check text.endsWith("rules-share: 0.0% of tick time\n")

  test "warm-up frames and their ticks are left out; systems is tick minus rules":
    recordTick(50.0, 40.0)              # ran in the warm-up frame
    recordFrame(FrameSample(frameMs: 99.0, drawMs: 9.0, swapMs: 9.0, ticks: 1))
    for i in 1 .. 4:
      recordTick(float(i), float(i) / 2)
      recordFrame(FrameSample(frameMs: float(i) + 1, drawMs: 0.5, swapMs: 0.25, ticks: 1))
    check recordedTicks().len == 5
    check recordedFrames().len == 5
    check frameCount() == 5
    let text = profSummary(warmupFrames = 1)
    check text.startsWith("prof: 4 frames and 4 ticks after 1 warm-up frames")
    check "  tick,4,2.000,3.000,4.000\n" in text
    check "  rules,4,1.000,1.500,2.000\n" in text
    check "  systems,4,1.000,1.500,2.000\n" in text
    check "  draw,4,0.500,0.500,0.500\n" in text
    check "  swap,4,0.250,0.250,0.250\n" in text
    check "  frame,4,3.000,4.000,5.000\n" in text
    check text.endsWith("rules-share: 50.0% of tick time\n")

  test "percentile is nearest rank on the sorted samples":
    check percentile([5.0, 1.0, 3.0, 2.0, 4.0], 0.5) == 3.0
    check percentile([5.0, 1.0, 3.0, 2.0, 4.0], 0.99) == 4.0
    check percentile(newSeq[float](), 0.5) == 0.0
