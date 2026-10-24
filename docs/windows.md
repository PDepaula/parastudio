# Para Studio on Windows

How to start Para Studio on a Windows PC by double-clicking one file,
`Paraloop-Studio.bat`. The file checks what your PC has, builds the `para` tool,
starts Studio and opens it in your browser. Unlike the Mac launcher
([mac.md](mac.md)), **it installs nothing itself**: if a C compiler, git or Nim
is missing, it tells you what to install and from where, and stops.

**Status: unverified.** This launcher was written and its text was checked on
Linux only. Nobody has run it on a real Windows PC yet, so you are the first:
please send the captain what you see if anything differs from this page. In
particular these have never been checked: the Windows warning about a downloaded
file, the double-click itself, a real Nim install, and whether Studio and its
game window work from a plain Windows window at all (opening the game window on
Windows has never been checked either; see [platforms.md](platforms.md)). The
other route, typing commands in Git Bash, is
[windows-first-game.md](windows-first-game.md); it is also not fully checked.

## What you need

Install these three first, in this order, saying yes to the defaults. The
launcher checks for them and shows these same instructions if one is missing.

1. **A C compiler** (the game is turned into a program by one). In a normal
   terminal (press the Windows key, type `terminal`, press Enter) run:

   ```
   winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e
   ```

   Any MinGW-w64 `gcc` works.
2. **git** (keeps your save points): download Git for Windows from
   <https://git-scm.com/download/win>, or run `winget install --id Git.Git -e`.
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
   | 3 Nim 2.2.10 | "ok", or "MISSING" | Same. All three are checked before it stops, so you see everything missing at once. |
   | 4 Game libraries | "Nothing is printed here while it works" | Wait a few minutes. It is working even when nothing moves. |
   | 5 Building para | the same | Wait a few minutes. |
   | 6 Starting Studio | Studio opens in your browser | Keep the black window open while you use Studio. |

4. To stop Studio, press **Ctrl+C** in the black window (answer **Y** if it asks
   "Terminate batch job"), or just close the window.

## Next times

Double-click `Paraloop-Studio.bat`. Steps that are already done say "ok" and are
skipped (the libraries) or take seconds (only what changed is rebuilt), so it
goes straight to Studio.

## If something is missing

The launcher stops with a block like this, listing only what is missing:

```
------------------------------------------------------------------------------
Studio cannot start yet: something it needs is not on this computer.
Nothing was installed or changed; this launcher never installs anything itself.
Install what is listed below, then close this window and double-click
Paraloop-Studio.bat again.
------------------------------------------------------------------------------
```

Install what it lists (the commands and links are the ones in "What you need"),
close the window and double-click again.

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
signed in on your PC. The launcher does not check for it; Studio tells you in the
chat if it is missing. Whether the chat runs from the launcher's plain Windows
window, rather than Git Bash, has never been checked.

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
Step:     5 of 6, build para
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

- It never installs anything, never asks for an administrator password, and
  does not change your PATH or any Windows setting. It looks for Nim, a C
  compiler and git on your PATH and in the usual folders (for example `C:\nim`,
  `%USERPROFILE%\.nimble\bin`, `C:\Program Files\Git\cmd`, the WinLibs folder
  `winget` uses), and extends the PATH **inside its own window only**.
- It talks to the internet only to let nimble fetch the game libraries, and
  through git. No telemetry.
- To see what it would do without building or opening anything, open a Command
  Prompt in the `parastudio` folder and run
  `Paraloop-Studio.bat --dry-run`. The checks still really look; the later steps
  only say what they would do. It exits with an error if something is missing.

## What was and was not checked

Same steps and wording as the Mac launcher (`tools/launcher/launch.sh`), with three
differences: it never installs Nim for you, it checks all three tools before
stopping, and it does not look for the chat program.

- **Checked on Linux:** only the shape of both files, by `tests/test_launcher_bat.nim`
  (plain ASCII, Windows line endings, every `goto` and `call` has its label, no label
  twice, no parenthesised blocks). That says nothing about what the script does.
- **Run once under Wine on Linux, on an earlier version of the script** (before the
  library check also looked at the `--path` folders and before the chat-program step was
  removed; those parts were not rerun): the whole script (a first run and a second run,
  Nim of the wrong version, everything missing, a failing build, a failing Studio,
  `--dry-run`, `--help`, a bad option) was driven through Wine's `cmd.exe` with
  stand-in programs for `nim`, `nimble`, `git`, a C compiler and `para`, and
  printed the messages in this page. Wine is a re-implementation of Windows, not
  Windows: real `cmd.exe` and the real `where` and `findstr` can differ (Wine's
  `findstr` ignored the `/i /x /l` switches, and its `where` had to be replaced by a
  stand-in), and the stand-ins never ran a real compiler.
- **Set up to run on a hosted Windows machine:** the `windows-launcher` job in
  `.github/workflows/platform-check.yml` runs `Paraloop-Studio.bat --dry-run`
  there, once with Nim installed (it must finish ok) and once pretending
  everything is missing (it must stop with the messages above). It is started by
  hand only, and had **not been run** when this page was written (the hosted
  runners are paused; see [platforms.md](platforms.md)). If it has run, it proves
  only that the script parses and its checks and messages run on Windows Server.
- **Never checked:** the SmartScreen prompt, the real double-click, a real Nim
  install, a friend's PATH, `nimble` and the `para` build from this script,
  Studio's browser and chat from a plain Windows window, and the game window.
