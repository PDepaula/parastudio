## __GAME__'s content as data (AGENTS.md "Content is table rows"; report
## finding #4): a new phase is a new `GamePhase` value in `rules.nim` plus a
## row here, never a `case` on `GamePhase` outside this file.
##
## Adding a phase:
## 1. add the value to `GamePhase` in `rules.nim`
## 2. add its row here
## 3. a test in this game's `tests/` directory if the phase changes behaviour

import rules

type
  PhaseDef* = tuple[label: string]

const phaseDefs*: array[GamePhase, PhaseDef] = [
  Playing: (label: "Playing")
]
