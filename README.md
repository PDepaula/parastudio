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

Paste one line into a terminal. It makes a `parastudio` folder in your home folder, says exactly
what it will do and asks before it installs anything, then offers to start Studio.

Mac or Linux (Terminal):

```sh
curl -fsSL https://pdepaula.github.io/parastudio/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://pdepaula.github.io/parastudio/install.ps1 | iex
```

What it does, how to read it before running it, how to pick another folder and how to remove it:
[docs/install.md](docs/install.md). It has run on GitHub's Linux, Mac and Windows test machines,
not yet on a real Mac or Windows PC. To clone and start the launchers yourself, or to type every
command: [docs/start.md](docs/start.md).

![Check passed, then Saved as save point 1](docs/img/studio-4-check-save.png)

## Licence

MIT, see [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY.md](THIRD_PARTY.md).
