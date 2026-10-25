# Install with one line

The quickest way to get Para Studio: paste one line into a terminal. It makes a `parastudio`
folder in your home folder, sets it up and offers to start Studio. It asks before it installs
anything, and it tells you exactly what it will do first.

**Mac or Linux:** open Terminal and paste:

```sh
curl -fsSL https://pdepaula.github.io/parastudio/install.sh | sh
```

**Windows:** open PowerShell (press the Windows key, type `powershell`, press Enter) and paste:

```powershell
irm https://pdepaula.github.io/parastudio/install.ps1 | iex
```

You do not need to change any Windows setting first (no "execution policy" change).

**Status:** the installers have been run start to finish on GitHub's own test machines for Linux,
Mac and Windows (the `installer` check; see [What was checked](#what-was-checked)). Nobody has run
them on a real Mac or a real Windows PC yet. If you are the first, please send the captain what
you see.

## What it does

1. **It looks.** It checks for git (needed to make your copy), a C compiler and Nim 2.2.10, and
   prints what it found. Looking changes nothing.
2. **It tells you the plan and asks once.** It prints what it will get (Para Studio at one exact
   commit), from where (the project's page on GitHub) and into which folder, and what comes next.
   Only `y` (or `yes`) goes ahead. Just Enter, `n` or anything else stops, with nothing changed.
3. **It makes your copy.** It runs `git clone` into the new folder and checks that the copy is at
   exactly the commit it named.
4. **It sets it up with the launcher.** It runs the same launcher the double-click files use,
   from inside your new copy ([Mac](mac.md), [Windows](windows.md), [Linux](linux.md)). For each
   thing that is missing (a C compiler, Nim 2.2.10, and git on Windows) the launcher says what it
   would install, from where and into which folder, and asks you `y` or `n` again. Then it fetches
   the game libraries (`nimble install -d -y`, then `nimble setup`) and builds `para`, the program
   behind Studio. This part takes a few minutes the first time.
5. **It asks whether to start Studio.** Say `y` and Studio opens in your browser. Later, start it
   the usual way: double-click `Paraloop-Studio.command` (Mac) or `Paraloop-Studio.bat` (Windows)
   in the folder, or run `./paraloop-studio.sh` in it (Linux).

## What it never does

- It never installs anything you did not say `y` to. Installing Nim, a C compiler or git always
  has its own question, after it has shown what, from where and into which folder.
- It never uses `sudo` (your administrator password) by itself. On Linux, the only time it can is
  when the launcher offers your package manager's own command (for example
  `sudo apt-get install build-essential`), shows it to you, and you say `y`. On Windows it never
  asks for an administrator password.
- It never overwrites a folder. If the folder is already there and is a Para Studio copy, it only
  finishes setting that copy up and changes none of its files; anything else in the way and it
  stops without touching it.
- It never changes your shell settings or your Windows settings, never touches a login, and never
  sends anything anywhere. There is no tracking of any kind. The only downloads are the copy from
  GitHub, the game libraries, and whatever you said `y` to.

It is safe to run again: a second run never overwrites what is there and skips the steps that
are already done. If something stops it, it says why and what to do, and you run the same line
again once that is fixed.

## Choosing the folder

The folder is `parastudio` in your home folder unless you say otherwise. To pick another, put
the folder in front of the line:

```sh
curl -fsSL https://pdepaula.github.io/parastudio/install.sh | PARASTUDIO_DIR="$HOME/games/parastudio" sh
```

```powershell
$env:PARASTUDIO_DIR = "$HOME\games\parastudio"; irm https://pdepaula.github.io/parastudio/install.ps1 | iex
```

## Read it before you run it

Piping a download into a shell runs it straight away. If you would rather read it first, download
it, open it in any text editor, and run the file you read. Each installer is one short file with
comments that say what every part does.

Mac or Linux:

```sh
curl -fsSL -o install.sh https://pdepaula.github.io/parastudio/install.sh
less install.sh        # read it (press q to leave)
sh install.sh
```

Windows (PowerShell):

```powershell
irm https://pdepaula.github.io/parastudio/install.ps1 -OutFile install.ps1
notepad install.ps1    # read it, then close Notepad
Get-Content -Raw .\install.ps1 | iex
```

The last line runs the file you read the same way the one-liner does, so no Windows setting has
to change. The files are also in the project, next to the launchers:
[install.sh](../tools/launcher/install.sh) and [install.ps1](../tools/launcher/install.ps1).

## Which code it installs

The copy on this site has one exact commit written into it when the site is published, and it
installs exactly that commit, so the script you read and the code you get always match. It checks
the copy it made is at that commit and stops if it is not. A copy of the installer taken straight
from the project's files has no commit written in: it says so plainly, and then uses the newest
code on `main`.

## Removing it

Delete the `parastudio` folder (or the folder you chose). That removes Para Studio and your games
in it, so keep anything you want first; each game in `games/` is a folder of its own you can copy
out. To also remove what the launcher may have added:

- the game libraries, in `.nimble` in your home folder (shared with any other Nim project, so
  only if you have none)
- Nim 2.2.10, if the launcher installed it, in `.paraloop` in your home folder

A C compiler or git installed through your package manager or winget is removed the usual way
for that tool.

## Running it with nobody at the keyboard

For automated checks there is an unattended mode: set `PARASTUDIO_YES=1`. It answers yes only to
the installer's own question (make the copy, fetch the libraries, build `para`). It never installs
a C compiler, Nim or git: if one is missing, it stops with what to install by hand. It does not
start Studio.

```sh
curl -fsSL https://pdepaula.github.io/parastudio/install.sh | PARASTUDIO_YES=1 sh
```

```powershell
$env:PARASTUDIO_YES = '1'; irm https://pdepaula.github.io/parastudio/install.ps1 | iex
```

## What was checked

The `installer` workflow (`.github/workflows/installer.yml`) builds the docs site, serves it on
the runner and runs the published installers exactly as the lines above do, in unattended mode,
into a new folder under a clean home folder, on GitHub's Linux, Mac and Windows test machines. A
Mac and a Windows PC there come with git and a C compiler; Nim 2.2.10 and, on Linux, the window
libraries are set up by the workflow's own steps before the installer runs. Each run checks that
the copy is at the commit the script names, that `para` was built, that a second run changes
nothing, and that a folder that is in the way is refused. On every pull request the `docs` check
also makes sure the published installers are exactly the project's files with only the commit
written in. What those machines cannot show: a real person's Mac or Windows PC, the questions
typed by a person, and the installs of Nim, a C compiler or git, which the launcher's own tests
cover ([platforms.md](platforms.md)).

On Linux, building `para` also needs the X11 and OpenGL development files (on Debian or Ubuntu:
`sudo apt-get install libx11-dev libxcursor-dev libxrandr-dev libxinerama-dev libxi-dev
libgl-dev`). The launcher does not check for them yet; if the build stops with a missing `X11`
header, install those and run the line again.

To set everything up by hand instead, see [Set up from a terminal](start.md).
