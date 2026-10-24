# Para Studio

Para Studio: make a small 2D game with a producer that talks to you. It is built on the
paraloop engine (Nim + paranim + pararules): a deterministic fixed-tick loop, headless tests,
one CLI (`para`) and a Studio page in your browser.

It is for a friend who loves games and works with an AI producer ([Claude Code](https://code.claude.com/docs/en/setup)
or [Codex](https://developers.openai.com/codex/cli)): you say what you want to play, the producer
and its helpers build it, check it, and keep a save point you can go back to.
You do not need to be an engineer.

**The documentation is at [pdepaula.github.io/parastudio](https://pdepaula.github.io/parastudio/)**
(built from [docs/](docs/)).

Two ways to use it:

- **Para Studio, the default.** One place to do everything: open it, talk to the producer, play, check
  and save. You do not wire up any agent yourself. See the [Quick start](#quick-start) and
  [the Studio guide](docs/studio.md).
- **Power users.** Skip the Studio and drive the engine and the `para` CLI directly with your own coding
  agent. See [docs/para.md](docs/para.md), [AGENTS.md](AGENTS.md) and the skills in
  [skills/](skills/) and [.agents/skills/](.agents/skills/).

![The Studio front door: the producer's chat, the game picker, Play and Check & save](docs/img/studio-1-front-door.png)

## Quick start

Clone this repository (`git clone https://github.com/PDepaula/parastudio.git`), then start the
launcher for your computer. It needs nothing installed first: when Nim, a C compiler or git is
missing it says what it would install and asks before it does.

- **Mac:** double-click `Paraloop-Studio.command` ([docs/mac.md](docs/mac.md)).
- **Windows:** double-click `Paraloop-Studio.bat` ([docs/windows.md](docs/windows.md), not yet tried
  on a real Windows PC).
- **Linux:** run `./paraloop-studio.sh` ([docs/linux.md](docs/linux.md)).

To type the commands yourself instead: [docs/start.md](docs/start.md).

![Check passed, then Saved as save point 1](docs/img/studio-4-check-save.png)

## Licence

MIT, see [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY.md](THIRD_PARTY.md).
