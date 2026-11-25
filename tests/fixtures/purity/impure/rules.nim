## An impure game: the lines tests/test_para_purity.nim expects a finding on carry `# BAD`.
import std/[math, times]                 # BAD 2: the clock
from std/os import getEnv                # BAD 3: the environment
import pararules
import paraloop/[sim, render2d]          # BAD 5: drawing
when defined(dev):
  import paranim/gl                      # BAD 7: drawing

let (newRawSession*, gameRules*) =
  staticRuleset(Fact, FactMatch):
    rule tickTime(Fact):
      what:
        (Global, TotalTime, total, then = false)
        (Global, DeltaTime, dt)
      then:
        echo "tick ", total              # BAD 16: echo
        let started = epochTime()        # BAD 17: the clock
        discard readFile("save.txt")     # BAD 18: a file
        session.retract(Player, Hp)      # BAD 19: a retract
        let r = rand(9)                  # BAD 20: the global RNG
        var xs = @[1, 2]
        xs.shuffle()                     # BAD 22: the global RNG
        session.fireRules()              # BAD 23: firing rules from a then
        session.insert(Global, TotalTime, total + dt)

    rule quitter(Fact):
      what:
        (Global, Quit, q)
      thenFinally: quit(1)               # BAD 29: quitting
