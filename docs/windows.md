# Para Studio on Windows

Two ways to start Para Studio on a Windows PC, both with a plain yes or no before anything is
installed:

- **The portable zip (new, the one to try first).** Download one zip, extract it, double-click
  `Paraloop-Studio.exe`. Nim and the C compiler are inside the zip, so there is nothing to
  detect or install for them. See [The portable zip](#the-portable-zip). A signed version comes
  later; for now the program is **not signed** and Windows warns once.
- **The batch file.** In a folder you already have, double-click `Paraloop-Studio.bat`. It checks
  what your PC has, offers to install a missing C compiler, git or Nim (saying exactly what,
  from where and into which folder, and **installing it only after you answer `y`**), builds the
  `para` tool, prints the same startup checks as the Studio page, starts Studio and opens it in
  your browser. The rest of this page is about the batch file, after the zip section. Like the Mac
  launcher ([mac.md](mac.md)), any answer but `y` stops with what to install by hand.

**Status: unverified.** Both launchers were written and their text was checked on Linux only.
Nobody has run them on a real Windows PC yet, so you are the first: please send the captain what
you see if anything differs from this page. In particular these have never been checked: the
Windows warning about a downloaded file, the double-click itself, the winget installs and the
Nim install the batch file offers, and whether Studio and its game window work from a plain
Windows window at all (opening the game window on Windows has never been checked either; see
[platforms.md](platforms.md)). The other route, typing commands in Git Bash, is
[windows-first-game.md](windows-first-game.md); it is also not fully checked.

Starting from nothing and want the batch file? The one-line installer ([Install with one
line](install.md)) makes the `parastudio` folder and runs the same launcher for you. Testing the
zip for the captain? [The zip test](windows-friend-test.md) is a short checklist for what to
time and write down.

## The portable zip

**What it is.** One zip, `Paraloop-Studio-<version>-windows-x64.zip` (about 135 MB), holding one
folder, `Paraloop-Studio`:

| In the folder | What it is |
|---|---|
| `Paraloop-Studio.exe` | The launcher: a native program (no cmd, no PowerShell, no execution policy) that does what `Paraloop-Studio.bat` does. |
| `nim-2.2.10\` | Nim 2.2.10 and `nimble`, unmodified, from nim-lang.org. |
| `mingw64\` | The MinGW-w64 C compiler that Nim's own Windows installer sets up (GCC 11.1), from nim-lang.org, minus the parts a C build never runs (Fortran, D and Objective-C compilers, a debugger). |
| `parastudio\` | Para Studio at one exact commit, with its `.git` folder, so save points work. |
| `licenses\` | What Nim and MinGW are licensed under, and where their source is. |
| `README.txt` | The three steps below. |

**What you do.**

1. Download the zip the captain sent. **Do not** "Unblock" it first if the captain asked you to time
   the warnings (see [the zip test](windows-friend-test.md)); otherwise unblock it (right-click the zip,
   Properties, tick **Unblock** at the bottom, OK) to skip Windows' warning.
2. Right-click the zip, **Extract All**, and extract into a **short folder** such as
   `C:\ParaStudio` (a long path can make a build fail; the launcher warns when yours is long).
   Do not double-click from inside the zip: it will not find the rest.
3. Open `C:\ParaStudio\Paraloop-Studio` and double-click **`Paraloop-Studio.exe`**. If Windows shows
   **"Windows protected your PC"**, click **More info**, then **Run anyway**. The program is not
   signed yet (the captain is arranging that); that is the only reason for the warning.
4. A black window prints seven numbered steps. The first start fetches the game libraries and builds
   Studio, which takes several minutes; it says so and is working even when nothing moves. Later
   starts take seconds. Studio opens in your browser. Keep the black window open while you use Studio;
   press **Ctrl+C** in it or close it to stop Studio.

**What it asks, and what it never does.**

- The only thing it can offer to install is **git** (nimble fetches the game libraries with it), and
  only when your PC has none: it prints what (Git for Windows), from where (winget's catalog),
  the exact command (`winget install --id Git.Git -e --source winget --scope user`), where it goes
  (your user folder) and that it needs no administrator password, then asks `(y/n, Enter means no)`.
  Only `y` or `yes` is yes. If you say no it stops with what to install by hand.
- It never downloads Nim or a compiler (they are in the zip), never runs a downloaded script, never asks for
  an administrator password, never changes your Windows settings or PATH (it extends the PATH of its
  own window and the programs it starts, nothing else), and never reads, copies or changes any
  login or setting of Claude or Codex. The only things it fetches are the game libraries (nimble,
  through git) and whatever you said `y` to.
- `tmp\launcher.log` in the `parastudio` folder records what each step printed, with the time, and
  how long the start took. It never holds Studio's own output (that carries a private key).
- `Paraloop-Studio.exe --dry-run` (or `--check`) shows what it would do and changes nothing.
  `--no-studio` sets up and builds but does not start Studio; `--no-open` starts Studio without
  opening a browser tab.

**If something is missing or fails.** The launcher stops with a block to send the captain (the same
as the batch file's, below). If it says the compiler or Nim folder is missing, the zip was not fully
extracted: use Extract All again.

**Where git comes from.** The zip does not carry git (it is much larger than the rest, and
bundling it would be the next step if the git question turns out to be the one prompt left).

**Updates.** There is no auto-update. A new zip is a new download; the captain can also update the
`parastudio` folder inside with `git pull`.

**Building it yourself, and what is checked.** `python tools/launcher/build_portable.py` assembles
the zip on a Windows PC that has Nim 2.2.10 and a C compiler on PATH (to compile the launcher); it
checks both downloads against the SHA-256 pinned in the script and the one nim-lang.org publishes
beside each file. The `portable` workflow (`.github/workflows/portable.yml`) builds it on a GitHub
Windows machine on every change to the launcher, then unpacks it into `C:\ps`, and runs it with a
PATH that has Windows and git on it and nothing else (no compiler, no Nim), in a clean home folder:
the launcher must find the zip's own tools, fetch the libraries, build `para`, start Studio, and
Studio's page must load with its key. That proves the zip works on a clean machine; it does not
prove a window opens (a hosted machine has no graphics card), the SmartScreen prompt, or a person's
double-click. The zip is kept as a workflow artifact on every run. A release is made only when a
person pushes a tag called `portable-v...`, and then only as a draft that a person publishes.
**Signing** is a marked hook in that workflow (`SIGNING HOOK`): once the captain has an Azure
Artifact Signing account it signs the launcher before the zip is made, and the workflow can be set
to fail on an unsigned build.

## The batch file

Everything from here to the end of this page is about `Paraloop-Studio.bat`, the route for a
folder you already have (the zip above does the same without it).

## What you need

Studio needs three things. The launcher checks for each and offers to install
what is missing (see "If something is missing" below), so you can let it do
that. To install them yourself instead, in this order, saying yes to the
defaults (these are also the instructions it shows when you answer no):

1. **A C compiler** (the game is turned into a program by one). In a normal
   terminal (press the Windows key, type `terminal`, press Enter) run:

   ```
   winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e --source winget
   ```

   Any MinGW-w64 `gcc` works.
2. **git** (keeps your save points): download Git for Windows from
   <https://git-scm.com/download/win>, or run
   `winget install --id Git.Git -e --source winget --scope user`.
3. **Nim 2.2.10** (the language the games are written in; `nimble`, its package
   tool, comes with it): download
   <https://nim-lang.org/download/nim-2.2.10_x64.zip>, unzip it somewhere
   permanent such as `C:\nim`, run `finish.exe` inside the unzipped folder and let
   it add the Nim folders to your PATH. It must be exactly 2.2.10; another Nim on
   the PC is left alone.

Also needed: the `parastudio` folder from the captain, **fully unpacked** (if it
came as a zip file, right-click it and choose **Extract All**; double-clicking
from inside the zip does not work), in a folder with a short plain path such as
`C:\Users\you\parastudio`, and an internet connection. The first run downloads
the game libraries and builds `para`, which takes several minutes; later starts
take seconds.

## First time

1. Open the `parastudio` folder in File Explorer and double-click
   **`Paraloop-Studio.bat`** (it may show as just `Paraloop-Studio`).
2. If Windows shows **"Windows protected your PC"** (SmartScreen), click **More
   info**, then **Run anyway**. Windows warns about any program file that came
   from the internet; this is how you tell it you trust the captain's copy. If
   the file's Properties (right-click it) show an **Unblock** box at the bottom,
   tick it and click OK once; that stops the warning for good.
3. A black window opens and prints numbered steps. Each says what it is doing:

   | Step | What you see | What to do |
   |---|---|---|
   | 1 C compiler | "ok", or "MISSING" | If missing, see "If something is missing" below. |
   | 2 git | "ok", or "MISSING" | Same. |
   | 3 Nim 2.2.10 | "ok", or "MISSING" | Same. All three are checked before anything is offered, so every offer comes in one go. |
   | 4 Game libraries | "Nothing is printed here while it works" | Wait a few minutes. It is working even when nothing moves. |
   | 5 Building para | the same | Wait a few minutes. |
   | 6 Claude or Codex | The same startup checks the Studio page shows (installed, signed in, folder trusted), each "ok" or with one fix line | See "The producer's chat" below. They never stop Studio from opening. |
   | 7 Starting Studio | Studio opens in your browser | Keep the black window open while you use Studio. |

4. To stop Studio, press **Ctrl+C** in the black window (answer **Y** if it asks
   "Terminate batch job"), or just close the window.

## Next times

Double-click `Paraloop-Studio.bat`. Steps that are already done say "ok" and are
skipped (the libraries) or take seconds (only what changed is rebuilt), so it
goes straight to Studio.

## If something is missing

After the three checks, for each missing one the launcher prints what it would
install, from where, into which folder and how big, then asks a question ending
in `(y/n, Enter means no)`. Type `y` and press Enter to install it; just Enter,
`n` or anything else installs nothing.

| Missing | What it offers | From | Where it goes |
|---|---|---|---|
| C compiler | WinLibs GCC (MinGW-w64), with `winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e --source winget` | winget's own catalog (winget is the app installer that comes with Windows); the files come from github.com/brechtsanders/winlibs_mingw | your user folder, `%LOCALAPPDATA%\Microsoft\WinGet\Packages`; no administrator password. winget shows the size as it downloads (a few hundred MB) and adds the compiler to your user PATH itself |
| git | Git for Windows, with `winget install --id Git.Git -e --source winget --scope user` | winget's own catalog; the installer comes from github.com/git-for-windows | your user folder, `%LOCALAPPDATA%\Programs\Git`; no administrator password. Its installer adds git to your user PATH itself |
| Nim 2.2.10 | the official release zip | <https://nim-lang.org/download/nim-2.2.10_x64.zip> (about 28 MB), downloaded with `curl.exe`; its SHA-256 must match the `.sha256` file nim-lang.org publishes next to it and the value written in the launcher, or it stops and installs nothing | unpacked with `tar.exe` into `%USERPROFILE%\.paraloop\nim-2.2.10`; no administrator password; added to the PATH of this window only, Windows settings are not changed |

winget may first ask you to agree to its catalog's terms; answer `Y` there if
you agree. If winget is not on the PC (it comes with Windows 10 and 11), the
launcher cannot offer the C compiler and git and lists the steps to do by hand.
The Nim offer is only made on a 64-bit Intel or AMD PC (`AMD64`), the PC the
official zip is built for.

When you answer no, or an install did not finish, the launcher stops with a
block like this, listing only what is still missing, followed by the steps in
"What you need":

```
------------------------------------------------------------------------------
Studio cannot start yet: something it needs is still not on this computer.
Nothing you said no to was installed. To install it yourself, follow what is
listed below, then close this window and double-click Paraloop-Studio.bat again
(or double-click it again now and answer y).
------------------------------------------------------------------------------
```

- **Installed it and it still says MISSING?** Windows only hands a new program's
  location to windows opened after the install, and sometimes only after you sign
  out and back in. Restart the PC once and try again. If it still does not find
  it, send the captain a photo of the window.
- **"Found a different Nim (...)"** means another Nim version is installed. The
  launcher leaves it alone and needs 2.2.10 next to it.
- **"I cannot find tools\launcher\launch.bat"** means the folder is not fully
  unpacked (see "What you need").

## The producer's chat

Studio's chat needs the `claude` (Claude Code) or `codex` program installed and
signed in on your PC. The launcher never installs it and never handles sign-in.
Before it opens the page it runs `tmp\para.exe studio --check`, the same
read-only startup checks the Studio page shows: whether Claude or Codex is
installed, signed in and trusts this folder, each "ok" or with one plain fix
line. Whatever they say, Studio still opens. Whether the chat runs from the
launcher's plain Windows window, rather than Git Bash, has never been checked.

## If the game window does not open

Press Play in Studio. If the PC cannot open the game window, Studio says "Your
computer could not open the game window. This is usually a graphics or display
problem..." Click **Show the details** and send the captain that message and the
lines under it. On a virtual machine this is expected: it often has no OpenGL
(see the top of [windows-first-game.md](windows-first-game.md)).

## If something fails

The launcher stops and prints a block like this (a missing tool is not this
block; it has its own message above):

```
==============================================================================
Something went wrong. Please send the captain everything between these lines.
------------------------------------------------------------------------------
Step:     5 of 7, build para
Problem:  Building para failed. The log has the compiler's words.
Computer: Microsoft Windows [Version 10.0.22631.4460], AMD64
Log file: C:\Users\you\parastudio\tmp\launcher.log   (attach this file too)
Last lines of the log:
  | ...
==============================================================================
```

Send the captain that whole block (click the window's icon, Edit, Select All,
then press Enter to copy, and paste), and attach the file named on the `Log file:`
line. The log is plain text: what each step printed, and nothing secret
(Studio's own output, which carries its private link, is not in it).

## What the launcher does and does not do

- It installs nothing without asking first, and only `y` or `yes` counts as
  yes. If the window cannot take an answer at all, that counts as no.
- It never asks for an administrator password, never runs a script downloaded
  from the internet, and does not change your PATH or any Windows setting
  itself. It looks for Nim, a C compiler and git on your PATH and in the usual
  folders (for example `%USERPROFILE%\.paraloop\nim-2.2.10`, `C:\nim`,
  `%USERPROFILE%\.nimble\bin`, `C:\Program Files\Git\cmd`, the WinLibs folder
  `winget` uses), and extends the PATH **inside its own window only**. (When you
  say yes to a winget install, winget and Git's installer add their program to
  your user PATH, as they always do.)
- It talks to the internet only to download Nim (and its checksum) from
  nim-lang.org, through the winget installs you said yes to, to let nimble fetch
  the game libraries, and through git. No telemetry.
- It does not read, copy or change any login or setting of Claude or Codex.
- To see what it would do and what it would offer without installing, building,
  opening or asking anything, open a Command Prompt in the `parastudio` folder
  and run `Paraloop-Studio.bat --dry-run` (or `--check`, the same). The checks
  still really look; the offers and the later steps only say what they would do.

## What was and was not checked

Same steps and wording as the Mac launcher (`tools/launcher/launch.sh`), with two
differences: it checks all three tools before it offers anything, and it leaves
finding the chat program to `para studio --check`.

- **Checked on Linux:** the shape of both files and the rules of the offers, by
  `tests/test_launcher_bat.nim`, reading the script's text: plain ASCII, Windows line
  endings, every `goto` and `call` has its label, no label twice, no parenthesised
  blocks; `--dry-run` and `--check` both make a dry run; the one question takes only `y`
  or `yes` as yes; every install command comes after the dry-run exit and a yes; each
  offer names what, from where, where to and how big; the Nim zip is checked against the
  published and a pinned SHA-256 before it is unpacked; nothing runs `sudo`, `runas`,
  `setx`, `reg add`, PowerShell or `finish.exe`. That says nothing about what the script
  does when `cmd.exe` runs it.
- **The offers to install have never run anywhere:** not on Windows, and not under Wine
  (Wine was not available when they were written). In particular whether winget accepts
  `--scope user` for Git.Git on a given PC, `certutil`'s output on a real PC, and the
  `curl.exe` and `tar.exe` that come with Windows were not checked.
- **Run once under Wine on Linux, on an earlier version of the script** (before the
  library check also looked at the `--path` folders, before the chat-program step was
  removed and put back as `para studio --check`, and before the offers to install; those
  parts were not rerun): the whole script (a first run and a second run,
  Nim of the wrong version, everything missing, a failing build, a failing Studio,
  `--dry-run`, `--help`, a bad option) was driven through Wine's `cmd.exe` with
  stand-in programs for `nim`, `nimble`, `git`, a C compiler and `para`, and
  printed the messages in this page. Wine is a re-implementation of Windows, not
  Windows: real `cmd.exe` and the real `where` and `findstr` can differ (Wine's
  `findstr` ignored the `/i /x /l` switches, and its `where` had to be replaced by a
  stand-in), and the stand-ins never ran a real compiler.
- **Set up to run on a hosted Windows machine:** the `windows-launcher` job in
  `.github/workflows/platform-check.yml` runs `Paraloop-Studio.bat --dry-run`
  there, once with Nim installed (it must finish ok), once pretending
  everything is missing (it must print the offers above, ask nothing and install
  nothing), and three times more with the dry-run-only hook
  `PARALOOP_LAUNCHER_DRY_ASK=1`, which asks each offer's real question and says what it
  would do for the answer it got, still running no winget, `curl.exe` or `tar.exe`:
  with only Enter typed, with the input closed and with `y` typed for each question.
  Enter and a closed input must print "Okay, nothing was installed." and never a
  "would: install" line, `y` must print "would: install" for all three, each offer
  (what, from where, the winget ids, where to, how big) must come before its question,
  and nothing may be created in `%USERPROFILE%\.paraloop`. It is started by
  hand only (`workflow_dispatch`), and had **not been run** when this page was written
  (the hosted runners are paused; see [platforms.md](platforms.md)). If it has run, it
  proves that `cmd.exe` really runs the script, its checks, its messages, the question
  and the yes/no default on a hosted Windows runner. It still cannot prove a real download
  or install, winget, SmartScreen, a real user PATH, or a person typing.
- **Also set up to run on a hosted Windows machine:** the `installer` workflow
  (`.github/workflows/installer.yml`, [install.md](install.md)) runs `launch.bat --check --no-studio`
  there with the offers faked and `PARALOOP_LAUNCHER_UNATTENDED=1` (every offer must be answered no
  without asking, nothing installed, Studio not started), and runs it for real through `install.ps1`
  with Nim already installed. Same limits as the job above.
- **The portable zip, checked on Linux:** `tests/test_launcher_exe.nim` compiles
  `tools/launcher/launch.nim` and runs it against a throwaway folder shaped like the zip with
  stand-ins for nim, nimble, gcc, git, winget and para: the seven steps in order with the zip's own
  tools ahead of anything on PATH, a second run skipping the libraries, a failure printing the block
  to send, a half-extracted zip stopping with the way out, the git offer asking first (only `y` or
  `yes`, nothing run otherwise, nothing asked unattended), `--dry-run` doing nothing, and the log
  never holding Studio's output. `tests/test_portable.nim` keeps the zip script, the launcher and
  the workflow in agreement. The zip itself was assembled on Linux with a stand-in launcher to check
  its layout (a clean `git status` inside it, one top folder, no `finish.exe`).
- **The portable zip, set up to run on a hosted Windows machine:** the `portable` workflow (above).
  It had **not been run** when this page was written.
- **Never checked:** the SmartScreen prompt, the real double-click, a real winget
  or Nim install from this script, a yes or no typed by a person, a friend's PATH, `nimble` and the `para` build from this script,
  Studio's browser and chat from a plain Windows window, and the game window.
