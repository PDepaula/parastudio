# Para Studio on a Mac

How to start Para Studio on a Mac by double-clicking one file. It needs
nothing installed first: the file checks what your Mac has, asks before it installs
anything, and tells you in plain words what it is doing.

**Status:** this was written and tested on Linux only. Nobody has run it on a Mac yet,
and opening the game window has never been checked on macOS. You are the first, so
please send the captain what you see if anything looks different from this page.

## What you need

- A Mac (Apple chip or Intel) with an internet connection.
- The `parastudio` folder from the captain, on your Mac. Anywhere in your home folder is
  fine (Documents or the Desktop, for example). A copy made with `git clone` is best,
  because it lets you bring in engine updates later. A zip file works too. Either way
  your game, made by `para new`, is a git repository of its own inside `games/`, so save
  points only need git to be installed.
- Some patience the first time (the downloads and the first build take several minutes). Later starts take seconds.

## First time

1. Open the `parastudio` folder in Finder.
2. **Right-click** (or hold Control and click) `Paraloop-Studio.command`, choose
   **Open**, then click **Open** in the box that appears.
   macOS warns about any file that came from the internet ("cannot be opened because
   it is from an unidentified developer", or "Apple could not verify..."). Choosing
   Open from the right-click menu is how you tell macOS you trust it. You only do this once.
   - If the box has no Open button (newer macOS): click **Done**, open **System
     Settings > Privacy & Security**, scroll down to the line about
     `Paraloop-Studio.command` and click **Open Anyway**, then try again.
   - If it still will not open, or says you do not have permission, open Terminal
     (press Command+Space, type `Terminal`, press Return) and paste these two lines,
     one at a time, with the real folder instead of `~/Documents/parastudio`:

     ```
     xattr -dr com.apple.quarantine ~/Documents/parastudio
     chmod +x ~/Documents/parastudio/Paraloop-Studio.command
     ```

     Then double-click the file again. The first line removes the "downloaded from the
     internet" mark from the folder; the second makes the file runnable.
3. A Terminal window opens and prints numbered steps. Each says what it is doing:

   | Step | What you see | What to do |
   |---|---|---|
   | 1 Apple's command line tools | Usually "ok". If they are missing, a window pops up from Apple. | Click **Install**, wait until it says it is done, then **double-click `Paraloop-Studio.command` again**. This is not an error. |
   | 2 git | "ok" | Nothing. |
   | 3 Nim 2.2.10 | "ok", or "Nim is missing. Install it now? (y/n)" | Type `y` and press Return. It downloads Nim from nim-lang.org (about 15 MB), checks the download against the checksum nim-lang.org publishes, and unpacks it into `.paraloop/nim-2.2.10` in your home folder. No password is asked and nothing outside your home folder changes. Type `n` to stop with nothing installed. |
   | 4 Game libraries | "working" with dots, a few minutes | Wait. It is working even when nothing moves. |
   | 5 Building para | "working" with dots, a few minutes | Wait. |
   | 6 Claude or Codex | Says which it found, or where to install one | See "The producer's chat" below. |
   | 7 Starting Studio | Studio opens in your browser | Keep the Terminal window open while you use Studio. The first time it says there is no game yet: in Terminal, in the same folder, run `tmp/para new mygame` (any name without spaces), then reload the page. |

4. To stop Studio, press **Control+C** in the Terminal window, then close it.

## Next times

Double-click `Paraloop-Studio.command`. Steps that are already done say "ok" and are
skipped, so it goes straight to Studio.

## The producer's chat (Claude or Codex)

Studio's chat runs the `claude` or `codex` program on your Mac. Studio does not install
it, and it never handles sign-in: it never sees or keeps your password or key. If the
launcher says neither is installed, install one from its official page, then open it once
and sign in there, in its own window:

- Claude Code: <https://code.claude.com/docs/en/setup>
- Codex CLI: <https://developers.openai.com/codex/cli>

You can start Studio before that; the chat starts working once one is installed and
signed in. Claude Code also asks, the first time you open a folder, whether you trust it:
in Terminal, in the `parastudio` folder, run `claude`, sign in, and choose **Yes, I trust this
folder** (the highlighted choice is "No, exit", so move down first). Until you do, Claude
ignores the list of things the producer may do. Studio checks all of this when its page opens and
says "Ready" or what is missing (see [studio.md](studio.md#startup-checks)).

## If the game window does not open

Press Play in Studio. If your Mac cannot open the game window, Studio says "Your computer
could not open the game window. This is usually a graphics or display problem..." Click
**Show the details** and send the captain that message and the lines under it.

## If something fails

The launcher stops and prints a block like this:

```
==============================================================================
Something went wrong. Please send the captain everything between these lines.
------------------------------------------------------------------------------
Step:     5 of 7, build para
Problem:  Building para failed. The log has the compiler's words.
Computer: macOS 15.1, arm64
Log file: /Users/you/Documents/parastudio/tmp/launcher.log   (attach this file too)
Last lines of the log:
  | ...
==============================================================================
```

Send the captain that whole block (select it in Terminal, copy, paste), and attach the
file named on the `Log file:` line. The log is plain text: what each step printed, and
nothing secret (Studio's own output, which carries its private link, is not in it).

## What the launcher does and does not do

- It never uses `sudo` and never asks for your password.
- It does not edit your shell settings. It finds Nim in `~/.paraloop/nim-2.2.10`,
  `~/.nimble/bin`, Homebrew and the usual places on its own each time.
- It talks to the internet only to download Nim (and its checksum) from nim-lang.org,
  to let nimble fetch the game libraries, and through git. No telemetry.
- It does not read, copy or change any login or setting of Claude or Codex.
- To see what it would do without changing anything, run
  `bash tools/launcher/launch.sh --dry-run` in Terminal from the `parastudio` folder.

## Linux and Windows

- **Linux:** run `./paraloop-studio.sh` from the `parastudio` folder. Same steps and
  messages; the C compiler is checked instead of Apple's tools (install one with your
  package manager if it asks).
- **Windows:** double-click `Paraloop-Studio.bat` instead; see [windows.md](windows.md).
  It checks the same things but installs nothing itself, and it is not verified on a real
  Windows PC. The command-by-command route is [windows-first-game.md](windows-first-game.md);
  opening the game window on Windows has never been checked either.
