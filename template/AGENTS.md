# AGENTS.md (__GAME__)

This game was started from `template/` (paraloop task 1.9). The repo root
`AGENTS.md` and the `pararules` skill (`skills/pararules/SKILL.md`) cover the
engine and pararules gotchas; this file covers only what's specific to
`__GAME__`.

## Loop

- `tmp/para test --filter games/__GAME__/` -- runs this game's tests
  (`tests/test___GAME__.nim`) and nothing else; never a bare `para test`,
  which runs every game's suite.
- `tmp/para build --game __GAME__` -- compile natively.
  `para web smoke --game __GAME__` smoke-tests the wasm build; it needs
  emscripten, so it is for CI and engineers, not the producer.
- `nim c -r -d:dev games/__GAME__/__GAME__.nim` -- the live window, F3
  overlay, F9 bug capture and `para live` (needs a display).

## Files

- `rules.nim` -- schema (standard attrs + this game's own), `gameRules`.
- `data.nim` -- content as table rows (`GamePhase` -> `phaseDefs`).
- `__GAME__.nim` -- the `paraloop/app.Game` (window/init/step/draw).
- `tests/` -- headless tests, replay-driven (`paraloop/input`).

## Saves

This folder is a git repository of its own (`para new` ran `git init` here, and
`.gitignore` keeps `tmp/`, `.nimcache/` and compiled files out). `tmp/para check`
then `tmp/para save -m "..."` commit and tag `save-__GAME__-<n>` in this
repository, never in the paraloop folder around `games/`. `tmp/para backup --game
__GAME__` uploads this repository to the friend's own private remote, and nothing else.
Helpers never run git writes (the producer saves). A `games/__GAME__.<id>/` folder next
to this one is a helper's own copy of this game (`tmp/para lane`, a git worktree of this
repository): it is not a second game, and the producer lands it into this folder.

## Game notes

Plain-words files for making this game, kept by the producer
(`.agents/skills/producer/SKILL.md` at the repo root):

- `PITCH.md` -- the idea and its three pillars.
- `PLAN.md` -- the one backlog (Now/Next/Later/Done), the `Speed:` setting
  and the names the friend and producer call each other.
- `CHOICES.md` -- open questions with the recommendation pre-filled, and a
  Decided log.
- `DESIGN.md` -- one section per feature, and the art cell table.
- `PLAYTEST.md` -- how it felt to play.
- `NOTES.md` -- short lessons (what works, what to avoid, what the friend
  likes), one dated line each; read it before you work.
- `reports/` -- one `<topic>.md` per read-only scout (see its `README.md`);
  the producer reads them from here.

## Adding a phase

1. add the value to `GamePhase` in `rules.nim`
2. add its row to `phaseDefs` in `data.nim`
3. a test in `tests/` if the phase changes behaviour

Never `case` on `GamePhase` outside `data.nim` (repo AGENTS.md "Content is
table rows").
