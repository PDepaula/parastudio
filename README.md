# Para Studio

Para Studio: make a small 2D game with a producer that talks to you. It is built on the
paraloop engine (Nim + paranim + pararules): a deterministic fixed-tick loop, headless tests,
one CLI (`para`) and a Studio page in your browser.

It is for a friend who loves games and works with an AI producer ([Claude Code](https://code.claude.com/docs/en/setup)
or [Codex](https://developers.openai.com/codex/cli)): you say what you want to play, the producer
and its helpers build it, check it, and keep a save point you can go back to.
You do not need to be an engineer.

Two ways to use it:

- **Para Studio, the default.** One place to do everything: open it, talk to the producer, play, check
  and save. You do not wire up any agent yourself. Start at [The Studio](#the-studio) and the
  [Quick start](#quick-start).
- **Power users.** Skip the Studio and drive the engine and the `para` CLI directly with your own coding
  agent. See [docs/para.md](docs/para.md), [AGENTS.md](AGENTS.md) and the skills in
  [skills/](skills/) and [.agents/skills/](.agents/skills/).

## The Studio

`tmp/para studio` opens a page on your own computer (nothing is sent anywhere but
what the producer you chose sends to its own service).

![The Studio front door: the producer's chat, the game picker, Play and Check & save](docs/img/studio-1-front-door.png)

Press **Play** and your game opens in its own window; **Show me a screenshot** puts a picture
of it in the chat so the producer can see what you see.

![The game's screenshot shown inline in the Studio chat](docs/img/studio-3-play.png)

**Check** runs the game's tests and builds it; **Save** keeps a numbered save point, and only
after a passing check.

![Check passed, then Saved as save point 1](docs/img/studio-4-check-save.png)

## Quick start

You need [git](https://git-scm.com/), a C compiler (gcc or clang) and
[Nim 2.2.10](https://nim-lang.org/install.html) (`nimble` comes with it; `choosenim 2.2.10` also works).

```sh
git clone https://github.com/PDepaula/parastudio.git && cd parastudio
nimble install -d -y        # fetch the dependencies pinned in nimble.lock
nimble setup                # wire their paths into config.nims
nim c --hints:off --outdir:tmp tools/para/para.nim   # build the `para` CLI once
tmp/para new mygame         # games/mygame/, a git repository of its own
tmp/para studio --game mygame   # the Studio page (or, in a terminal: `tmp/para check`, `tmp/para save -m "what changed"`)
```

While `nimble install -d -y` runs it may print `No nim version matching 2.2.10. Download it now? -> [forced yes]`.
That line is normal: nothing is wrong, and it usually downloads nothing.

Before the first message to the producer, do this once: install [Claude Code](https://code.claude.com/docs/en/setup)
(or Codex), open a terminal **in this folder**, run `claude`, sign in, and answer **Yes, I trust this
folder** (the highlighted choice is "No, exit", so move down first). The Studio page checks all of this
when it opens, says "Ready" or what is missing in one line each, and never blocks Play.

On a Mac, double-click `Paraloop-Studio.command` instead ([docs/mac.md](docs/mac.md)); on Linux run
`./paraloop-studio.sh`. On Windows double-click `Paraloop-Studio.bat` ([docs/windows.md](docs/windows.md),
not yet tried on a real Windows PC) or follow [docs/windows-first-game.md](docs/windows-first-game.md).
The launchers need nothing installed first: when Nim, a C compiler or git is missing they say exactly
what they would install, from where and into which folder, and install it only after you type `y`
(Enter means no). Before opening the page they print the same startup checks it shows
(`tmp/para studio --check`). What was checked on each system is in
[docs/platforms.md](docs/platforms.md).

To talk to the producer from a terminal instead of the Studio, open the folder in Claude Code or Codex
(say yes to the trust question, as above): `AGENTS.md` starts the producer voice and `.agents/skills/` holds its helpers.

## What you get

- A fixed-tick simulation with a seed and a state hash, so a run is the same every time and a bug can be replayed.
- Game rules as facts in [pararules](https://github.com/paranim/pararules); content as table rows in `data.nim`.
- A sprite and text renderer on [paranim](https://github.com/paranim/paranim) (OpenGL) with a pixel font, input, and synthesised sound with no sound files.
- Native and web (wasm) builds from the same code.
- `para` for the whole loop: `new`, `test`, `check`, `build`, `sim`, `shot`, `studio`, `save` and `backup`.
- Headless tests: game logic never touches a window, so `para test` and `para check` run anywhere.
- Pixel-art checks and cleanup (`para art lint`, `para art fix`).
- The producer voice and its helpers (builder, checker, scout, art) for Claude Code and Codex.

## What is in the folder

| Path | What it is |
| --- | --- |
| `src/paraloop/` | the engine: sim loop, rules glue, renderer, input, audio, save, the web shell |
| `template/` | the skeleton `para new` copies into `games/<name>/` |
| `games/` | your games, one folder and one git repository each |
| `examples/hello/` | the small game the engine's own tests and the web smoke test use |
| `tools/para/` | the `para` CLI; `tools/art/` the pixel-art cleanup; `tools/web/` the wasm build and smoke test |
| `.agents/skills/` | the producer's playbook and its helpers (builder, checker, scout, art) |
| `skills/` | `para` and `pararules` skills an agent can install |

## Working on the engine

```sh
tmp/para test --filter test_audio   # only the test files whose path contains that text
tmp/para test --area game           # the game tests, plus the `para` tests that link a game
tmp/para build --game hello         # compile a game natively, with structured errors
tmp/para sim --game hello --seed 7 --ticks 3600   # headless run: state, perf, state hash
```

A bare `tmp/para test` runs everything (about ten minutes from a cold cache); [docs/testing.md](docs/testing.md)
says when to use which. Engine rules (pararules habits, what a game's `rules.nim` may import) are in [AGENTS.md](AGENTS.md).

## Your game is yours

Each game lives in `games/<name>/` and is a git repository of its own (`para new` makes it), so its
history and save points never mix with the engine's. `para save` keeps save points there.
`para backup` is the only thing that uploads: it pushes your game to a private remote
named `backup` that you set up yourself, after you say yes, and never to this project.

## Publish to the web

The web build needs an official Nim >= 2.2.12 (the nimble-managed 2.2.10 is not enough); see [docs/web.md](docs/web.md).

```sh
source $EMSDK/emsdk_env.sh                           # emsdk 6.x, once per terminal; see docs/web.md
tmp/para build --target web --game mygame --title "My Game"
tmp/para web pack --game mygame                      # tmp/web/mygame-<build id>.zip
```

Upload the zip's contents to [itch.io](https://itch.io) (an HTML5 project) or any static host.

## Docs

Most people only need the Studio page. If you drive the engine with your own agent, start from
[docs/para.md](docs/para.md), [AGENTS.md](AGENTS.md) and the skills below.

- [docs/studio.md](docs/studio.md): the default interface, the Studio page, its chat, Claude or Codex, Play and screenshots, what to do when something goes wrong
- [docs/para.md](docs/para.md): every `para` command
- [docs/testing.md](docs/testing.md): running the tests, the local loop, what CI runs
- [docs/web.md](docs/web.md): the wasm target, `para web smoke`, packing a build
- [docs/art.md](docs/art.md): `para art lint`, `fix` and `sheet`
- [docs/engine.md](docs/engine.md): sound and the profile store
- [docs/platforms.md](docs/platforms.md), [docs/mac.md](docs/mac.md), [docs/windows-first-game.md](docs/windows-first-game.md): macOS and Windows
- [skills/pararules/SKILL.md](skills/pararules/SKILL.md): writing rules, with worked examples
- [AGENTS.md](AGENTS.md): the producer's instructions and the engine's rules of the road

## Licence

MIT, see [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY.md](THIRD_PARTY.md).
