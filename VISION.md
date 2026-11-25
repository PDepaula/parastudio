# Vision

`parastudio` exists so that people can make small 2D games with AI agents, games that want replay, a state hash and fast startup.
It serves two audiences through two faces of one codebase.
Para Studio is for a friend who loves games and is not an engineer: they talk to a producer, and the game gets built, checked, saved and shared.
paraloop, the engine and `para` CLI underneath, is for friends already at home with agentic work, and it is headed for its own package; both are worked on at once, and the Studio grows out of what paraloop builds.
paraloop's CLI and API may break only before its open release; after it, a breaking change is avoided at nearly any cost, in the manner of Clojure.
Para Studio is the flexible consumer: its friends never see the machinery, so it changes freely.
It owns exactly one thing: making small, deterministic 2D games with agents, from a sentence or a command to a game someone else can play.

## The friend never sees the machinery

The friend hears plain words from one voice, the producer, and every helper reports through it.
The friend is never shown code, diffs or file lists, not even behind a fold.
A setup problem shows up as a startup check with one plain fix line, never as a failure halfway through a chat.
Nothing installs without the friend's plain yes, and an optional tool such as Lavish falls back to the Studio's own views when it is missing.
Starting is one pasted line or one double-click, on Mac, Linux and Windows.
Sharing is part of the path: a release build a friend can run as one program, the game's repository, or a web build published to a site such as itch.io.
The Studio's orchestration is a smaller cut of the model the owner runs day to day in firstmate, and it stays less powerful on purpose.
Its sweet spot is two games at once (`maxLiveGames = 2`), at most three helpers across them, and a timer on every turn, step and helper; improvements within that shape are welcome.
Someone who wants many games and many workers at once has outgrown the Studio and moves to paraloop with a stronger orchestrator of their own.
A change that asks the friend to read a stack trace, pick a branch or edit a config file is a bug.

## Determinism is the spine

Every game runs on a fixed-tick loop whose ids and randomness come from the sim's seed, so a run replays from its seed and input script to the same state hash.
Game logic (`rules.nim`, `data.nim`, any `systems.nim`) never imports graphics, text or sound, so `para test` runs it headless with no window and no device.
Time in game logic is counted in ticks; a real-world value such as today's date enters once, as an input fact recorded in the input script, so replay still reproduces the run.
The agent-friendliness claim is headless, text-first, tick-level testability, built and measured: `para sim`, `stateHash`, snapshot and restore, golden frames; code locality is a style rule, because nobody has measured it against agent turns.
The `para` CLI is shaped for agents, after Kun Chen's axi: compact TOON output and exit codes 0, 1 and 2.
Replay and a matching hash are goals; rollback netcode is not designed.
Replay exists for the person building the game: a run must reproduce on the machine and build that recorded it.
A replay that does not match on someone else's machine, or between native and web, is acceptable; neither has ever been checked, and neither is promised.

## A short written model, checked by the build

Each part of the system that agents change has a short written model on disk, with examples and a checker, and the build refuses code that disagrees with it.
The model is written first for the human who has to hold the whole system in their head, and the owner finds the Eversince model the easiest way to do that.
A measurement that agents need fewer turns on flat code does not replace the model, because that gain is unproven as the code base grows.
For the Studio the model is `studiodesk.em`: the compiler holds every record, event, command, view, query and processor to `studiodesk.nim`, and each of its 22 refusal words has a scenario.
That containment holds for the desk and stops at its edge: the HTTP layer, the routes, the shells and the page hold about 100 refusal and guard sites the model does not know, plus 79 fixed words typed as plain strings.
The page's routes are checked against the model's screens (`tests/test_para_studio_model.nim`); the direction is to move what the desk can know into views, and which of the existing edge rules belong in the model is open.
A new path the friend is expected to take, such as exporting or publishing a game, has its refusals in the model from its first slice; only facts the desk cannot know, such as network and account state, stay in the shell.
Generated code is published beside the model by an `expand` command, and CI fails when the generated-to-written ratio or compile time passes a budget (decided, not built, budget not set).
Rule purity is enforced by `para check`: core files may not import banned modules, and a `then` body may call only the session's insert, ids, rng and pure helpers (decided, not built).
The project does not claim that higher abstractions win for agents, and how far the model should sit above plain Nim is open.
Two experiments inform it without deciding it: the same studio changes against the macro form and its expansion, and the same tickets against this layer and a raw-GL, plain-struct version of the demo.

## Two lanes for game code, drawn by measurement

Game code is rules as a functional core inside an imperative shell; Eversince models the Studio's information system, the desk today and the page's routes next.
A feature is a rule unless it joins two populations or rewrites a joined attribute for most entities every tick; then its scan is a system that writes facts, and a rule decides.
That line comes from this repository's numbers: a per-entity rule over 200 mobs costs about 1% of a release tick, while an entity-against-entity join costs 0.8 to 8 ms.
The rules session keeps commands, phases, timers and the entities rules reason about; hot per-entity data lives in plain arrays owned by systems.
The cap on rule-driven entities (a few hundred, about 1,000 on fast hardware) is provisional until `para bench` and a storage-attribution profile measure it.
Each game class gets a performance gate run by `para bench` and `para sim` on named hardware; the example numbers (300 entities, p99 tick under 4 ms headless) are placeholders until `para bench` exists and a cross-engine sprite benchmark calibrates them.
This level is not chosen for frame time: it pays in determinism, replay, a 2 MB binary, fast startup and an 18 ms headless test.

## Own the small stack

The project owns what it stands on: pararules is forked with its patches applied, and paranim's few hundred lines of GL plumbing are vendored once the add-path fix lands; both are Unlicense, so owning them needs no one's permission.
paranim was picked as a simple, composable base to build on, and a mature library is welcome on the same terms: it must slot into a lane and keep the functional core and imperative shell apart.
A physics library, for example, runs as a system on the hot path, writes its results as facts, and leaves decisions to rules.
Graphics stay on OpenGL 3.3 and WebGL2, because the measured costs sit in Nim-side math and a lower API would move none of them.
Vulkan, wgpu and SDL3 GPU are out for now; sokol is a fallback only on a named trigger, and ANGLE gets packaged for Windows Intel GPUs when a driver report arrives.
The loop stays single-threaded until a profile shows a ref-free system above about 5 ms.
For tooling, a plain tool beats a new dependency: helpers get plain `git worktree` lanes, not a pool manager.

## Agents work on a leash

Agents build, the friend directs, and the producer writes no game code beyond number tweaks in `data.nim`.
Each writing helper works in its own copy of the game and lands through Check and Save; scouts write only reports and stop on a timeout, on silence or on a tool budget, with no relaunch.
Studio turns may edit files under `games/` only, and golden frames are re-rendered by CI or a human, never by an agent.
The producer runs on a mid-tier model: an orchestrator needs to be smart enough to delegate, not the smartest model available.
It hands questions that need more depth up to a stronger model through a scout, and hands building to fast workers on mid- or lower-tier models.
A worker's default moves down a tier only on evidence that the cheaper model builds games in this narrow Nim stack, from the owner's tests or from what friends report.
A cheap model does not edit the desk until an experiment shows it reaching a passing build from the model file and compiler errors alone.
Godot driven headless is the alternative this project measures itself against for small 2D games, on agent efficiency through the CLI; it is never a second engine inside the Studio.
A claim nobody tested is written as untested, in docs and pull requests alike.

## Scope

Neither face is a general-purpose engine, and neither is a 3D engine: limited 3D ships only after both the web build and weak machines pass, and an opt-in flag does not lower that bar.
Multiplayer is out of scope on purpose; the trade is portability, since Nim compiles to C and cross-compiles, so a game travels as one program or a web build.
It is not a hosted service, and the friend's games live in their own repositories under `games/`, which this repository never tracks.

A change aligns when it shortens the path from a sentence or a command to a game someone else can play, moves a rule from the shell or from prose into something the build checks, keeps game logic headless and replayable, or replaces a guess with a measurement.
A change should be resisted when it shows the friend machinery, installs without asking, lets the wall clock or global randomness into game logic outside a recorded input, adds a rule the build cannot see where the model could hold it, states an unmeasured benefit as fact, adds a dependency that does not fit a lane or a lower graphics API without a named trigger, reaches for multiplayer or general-purpose scope, breaks paraloop's API after its open release, or lets an agent act outside its copy, its folder or its budget.
