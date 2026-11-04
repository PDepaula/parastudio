# Set up from a terminal

The one-line installer ([Install with one line](install.md)) does all of this for you. These are
the steps it takes, for when you would rather take them yourself.

## Clone and start the launcher

Clone the repository, then start the launcher for your computer. It needs nothing installed
first: when Nim, a C compiler or git is missing it says what it would install, from where and into
which folder, and asks before it does.

```sh
git clone https://github.com/PDepaula/parastudio.git
```

- **Mac:** double-click `Paraloop-Studio.command` in the folder ([Mac](mac.md)).
- **Windows:** the easiest way is the portable zip, which carries Nim and the C compiler: extract it
  and double-click `Paraloop-Studio.exe` ([Windows](windows.md#the-portable-zip)). Or, in a folder
  you cloned, double-click `Paraloop-Studio.bat` ([Windows](windows.md)). Neither has been tried on a
  real Windows PC yet, and Windows shows a warning screen the first time (the program is not signed
  yet): [Windows](windows.md#the-blue-windows-protected-your-pc-screen) shows what to click.
- **Linux:** run `./paraloop-studio.sh` in the folder ([Linux](linux.md)).

## If something goes wrong

The steps above are the smooth path; a first run on a new PC often is not. For Windows, see
[Windows troubleshooting](windows.md#windows-troubleshooting): the "Windows protected your PC" screen,
Defender, PowerShell's "running scripts is disabled", a compiler that is "not found", administrator
prompts and the Codex setup step. For Mac and Linux, see [Mac](mac.md) and [Linux](linux.md). When a
launcher stops, it prints a block of text and writes `tmp/launcher.log`: send both to whoever helps
you.

## Every command by hand

To type every step yourself instead, on any system:

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

## Before the first message to the producer

Do this once: install [Claude Code](https://code.claude.com/docs/en/setup)
(or Codex), open a terminal **in this folder**, run `claude`, sign in, and answer **Yes, I trust this
folder** (the highlighted choice is "No, exit", so move down first). The Studio page checks all of this
when it opens, says "Ready" or what is missing in one line each, and never blocks Play. If Claude
does not work for you, the checklist can switch to Codex (and back) with one button. On Windows,
Codex also needs a one-time sandbox step that you do in Codex yourself: see
[the setup checklist](windows.md#the-setup-checklist-claude-or-codex) and
[the Codex sandbox step](windows.md#the-codex-sandbox-step).

## Talking to the producer from a terminal

To talk to the producer from a terminal instead of the Studio, open the folder in Claude Code or Codex
(say yes to the trust question, as above): `AGENTS.md` starts the producer voice and `.agents/skills/` holds its helpers.
