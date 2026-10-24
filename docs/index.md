# Para Studio

Make a small 2D game with a producer that talks to you. You say what you want to play; the
producer ([Claude Code](https://code.claude.com/docs/en/setup) or
[Codex](https://developers.openai.com/codex/cli)) and its helpers build it, check it, and keep a
save point you can go back to. You do not need to be an engineer.

![The Studio front door: the producer's chat, the game picker, Play and Check & save](img/studio-1-front-door.png)

## Studio, the default

One place to do everything: open it, talk to the producer, play, check and save. You do not wire
up any agent yourself. Start with the [quick start](#quick-start) below, then read
[the guide to the Studio page](studio.md).

## Power users

Skip the Studio and drive the engine and the `para` CLI directly with your own coding agent.
Start from [the `para` CLI](para.md), [AGENTS.md](../AGENTS.md) and the skills in
[skills/](../skills/) and [.agents/skills/](../.agents/skills/).

The engine is paraloop (Nim + paranim + pararules): a deterministic fixed-tick loop, headless
tests, one CLI (`para`) and a Studio page in your browser.

## Quick start

Get the `parastudio` folder (`git clone https://github.com/PDepaula/parastudio.git`, or a zip
from GitHub), then open Para Studio with the launcher for your computer:

- **Mac:** double-click `Paraloop-Studio.command`. The [Mac guide](mac.md) walks through the
  first time.
- **Windows:** double-click `Paraloop-Studio.bat` ([Windows guide](windows.md); not yet tried on
  a real Windows PC), or follow the command-by-command
  [first game on Windows](windows-first-game.md).
- **Linux:** run `./paraloop-studio.sh` in the folder ([Linux guide](linux.md)).

The launchers need nothing installed first: when Nim, a C compiler or git is missing they say
exactly what they would install, from where and into which folder, and install it only after you
type `y` (Enter means no). Before opening the page they print the same startup checks it shows
(`tmp/para studio --check`). What was checked on each system is in
[platforms.md](platforms.md). To type the commands yourself instead, see
[Set up from a terminal](start.md).

## What you get

- A fixed-tick simulation with a seed and a state hash, so a run is the same every time and a bug can be replayed.
- Game rules as facts in [pararules](https://github.com/paranim/pararules); content as table rows in `data.nim`.
- A sprite and text renderer on [paranim](https://github.com/paranim/paranim) (OpenGL) with a pixel font, input, and synthesised sound with no sound files.
- Native and web (wasm) builds from the same code.
- `para` for the whole loop: `new`, `test`, `check`, `build`, `sim`, `shot`, `studio`, `save` and `backup`.
- Headless tests: game logic never touches a window, so `para test` and `para check` run anywhere.
- Pixel-art checks and cleanup (`para art lint`, `para art fix`).
- The producer voice and its helpers (builder, checker, scout, art) for Claude Code and Codex.
- What may come next is in the [roadmap](roadmap.md).

## Your game is yours

Each game lives in `games/<name>/` and is a git repository of its own (`para new` makes it), so its
history and save points never mix with the engine's. `para save` keeps save points there.
`para backup` is the only thing that uploads: it pushes your game to a private remote
named `backup` that you set up yourself, after you say yes, and never to this project.

## Where to read next

- [The Studio page](studio.md): opening it, the startup checks, starting a game, what the
  producer can change, and what to do when something goes wrong
- [Mac](mac.md), [Windows](windows.md), [Linux](linux.md) and
  [what was checked where](platforms.md)
- [The `para` CLI](para.md): every `para` command
- [The engine](engine.md): the folder layout, sound and the profile store
- [Art](art.md): `para art lint`, `fix` and `sheet`
- [Testing](testing.md): running the tests, the local loop, what CI runs
- [Publish to the web](web.md): the wasm target, `para web smoke`, packing a build
- [Roadmap](roadmap.md): directions, not commitments
- [Writing rules](../skills/pararules/SKILL.md), with worked examples, and [AGENTS.md](../AGENTS.md):
  the producer's instructions and the engine's rules of the road
- For maintainers: [Studio internals](studio-maintainers.md) and [how this site is built](site.md)
