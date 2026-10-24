# Your first game on Windows

A short checklist to go from nothing to a game window on a Windows PC. Do the
steps in order and stop at the first one that fails (see "If a step fails" at the
end).

**Status:** the hosted Windows and macOS check (the platform check, GitHub's
cloud machines) is paused until 2026-11-01 because the hosted-runner minutes
are used up. For now, the project owner's own try of this checklist on a Windows
VM is the check. The last hosted Windows runs that executed showed that new
game, build, `test --filter games/mygame/`, the `nim c -d:dev` compile and the
`test_dev` tests (including the new devsock tests) passed. In that same run the
`test_para_dev_cli` file aborted in its "no display" screenshot test (a GLFW
assertion; the runner has no OpenGL). That test was then changed to run only on
Linux, and that fix and everything after it has **not** been re-run on Windows.
**Opening the window** was never checked, and cannot be on a machine without a
graphics card; it needs real hardware. You may be the first person to try it.

## Read this first: a virtual machine may not be able to open the window

If you are on a Windows virtual machine (VirtualBox, VMware, Hyper-V, a cloud
PC), it often has no real graphics card, only a slow software stand-in, and the
stand-in may not speak OpenGL, which the game needs. Then everything before the
last step works and the window will not open. That is **not a bug in your game**.

What a missing OpenGL looks like, in the window step:

- the program prints `WGL: The driver does not appear to support OpenGL` (or
  another line starting `WGL:` or `GLFW`) and stops with no window; or
- the program ends straight away, with or without such a line (it may even
  report a crash or an `Assertion failed` message), and no window ever appears.
  When the window step ends like this, it is a graphics problem, not a bug in
  your game.

What a real bug looks like instead: the window **opens** (even a black or
broken one) and then something goes wrong, or the program fails *before* the
window step, in the install, new game, build or test steps.

If you see the missing-OpenGL message in a virtual machine, try the same steps
on a real PC (any laptop or desktop with up-to-date graphics drivers). Nothing
else needs to change.

## What to install

Install these three, in this order. Say yes to the defaults.

1. **Git for Windows**, which also gives you the terminal used below, "Git
   Bash": download it from <https://git-scm.com/download/win>, or in a normal
   terminal run `winget install --id Git.Git -e`.
2. **A C compiler** (the game is turned into a program by one): in a normal
   terminal run `winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e`. Any
   MinGW-w64 `gcc` works; the cloud test used MinGW-w64 gcc 15.2.
3. **Nim 2.2.10** (the language; `nimble`, its package tool, comes with it):
   download <https://nim-lang.org/download/nim-2.2.10_x64.zip>, unzip it
   somewhere permanent such as `C:\nim`, and run `finish.exe` inside. Let it add
   the Nim folders to your PATH (it does not need to install a compiler, you did
   that in step 2).

Nothing else is needed: no Visual Studio, no Python, no extra graphics
libraries (the window library comes with the engine).

Now close every terminal and open **Git Bash** from the Start menu. Check:

```
git --version
gcc --version
nim --version
nimble --version
```

Each must print a version. If one says "command not found", that install did
not reach your PATH: report it (see the end).

## The steps

Run every command in **Git Bash**, one at a time, from the folder where you want
the project. The first two take a few minutes; the cloud test took about three
minutes in total from the clone to a tested game.

**1. Get the engine and its parts**

```
git clone https://github.com/PDepaula/parastudio.git parastudio
cd parastudio
nimble install -d -y
nimble setup
```

**2. Build the toolbox**

```
nim c --hints:off --outdir:tmp tools/para/para.nim
```

**3. Make your game** (pick any short lowercase name; this guide uses `mygame`)

```
tmp/para new mygame
```

**4. Build it and check it**

```
tmp/para build --game mygame
tmp/para test --filter games/mygame/
```

The second command should end with `0 failed`. Never run `tmp/para test` with
nothing after it: that runs the whole engine's checks and takes very long.

**5. Open the window** (the step that needs a real graphics card)

```
nim c -r -d:dev games/mygame/mygame.nim
```

A window opens; press the arrow keys. Close it with the window's X. In a
virtual machine this is where a missing OpenGL shows up (see the top of this
page).

**6. Try saving your work** (not yet exercised on Windows)

These are the new `check` and `save` commands for keeping a game's work as
numbered save points. They have not been run on Windows yet, so what you see
(good or bad) is what we want to hear. Run them in Git Bash from the same
folder, with `mygame` from step 3:

```
tmp/para check
tmp/para save -m "first save"
tmp/para save --list
tmp/para save --back 1 --yes
```

`check` runs the game's tests and builds it; it has to pass before `save`
will save. `save --list` should show save point 1 with your note. `save --back
1 --yes` adds a new save point that puts the game back as it was at point 1
(nothing is deleted); to see it do something, change a file in `games/mygame/`,
run `tmp/para check` and `tmp/para save -m "second save"` first, then go back
to 1. If one of these fails, report it as described below.

**7. Try the studio page** (new; not yet exercised on Windows)

`para studio` opens a page in your own browser with the producer's chat, a Play
button that opens your game's window, a screenshot button, and the same buttons as the
terminal: Check, Save, your save points and the backup. It runs
inside the `para` program (nothing else to install) and only listens on your own
computer. From the same folder, in Git Bash:

```
tmp/para studio
```

What should happen: it prints a link that starts with `http://127.0.0.1:` and
your default browser opens on it. If the browser does not open, copy the link
into one yourself. Then try, in the page: press the **+** next to the message box
and choose **Check the game** or **Save…**, which opens the "Check & save" panel: its
"Where we left off" part shows your game's next step and last save point;
**Check the game** runs the checks (a few minutes the first time) and says whether
they passed; type a note and press **Save** (it refuses, in plain words, until a check
passed on the game as it is now); the save points list in the sidebar shows what you
saved; **Back up online…** in the sidebar says whether an online backup is set up. Windows may ask whether to allow the program
through its firewall: it only listens on your own computer, so "Cancel" or
"Allow" should both work, and please tell us which prompt appeared. Stop it
with Ctrl+C in the terminal.

**The Play step.** Once the page is open:

1. Press **Play**. The page says "Building the game…" (the first build takes a few
   minutes on Windows, later ones are quick) and then "Opening the game window…" and
   "The game window is open." Your game's own window opens on the desktop; the arrow
   keys move the sprite. There is no console window and nothing to type.
2. Press the **+** next to the message box, then **Show me a screenshot**. A card with a picture of the game window appears in
   the chat, and the page says "Done. The picture is in the chat above." Press it a
   few times; the studio keeps the newest 20 pictures (in `tmp/studio/shots/`).
3. Press **Play** again: the first window closes and a new one opens (one game window at
   a time). Press **Stop game**: the window closes. Close the window with its X
   instead: the page says "The game window was closed."
4. Press Ctrl+C in Git Bash while a game window is open: the window closes too.

If the window does not open, the page says why in plain words. Please report which
sentence it showed and open "Show the details" for the last lines it printed:
"The game did not build" (say what the details show), "no screen for it to use" (not
expected on Windows), "could not start OpenGL" or "stopped before its window opened and
said nothing" (the graphics problem described at the top of this page, expected in a
virtual machine), or "stopped by itself ... code N". Also say whether a firewall or
antivirus prompt appeared (none should: the studio and the game's control channel only
use your own computer's loopback address). Nothing in the Play step has been run on
Windows yet, and the screenshot path reads `tmp/dev.sock` as a port number written to a
file (the Windows form of the control channel), so a failure there is news to us.

**The chat step.** The chat runs the `claude` program (Claude Code) that you
installed and signed in to yourself; the page never asks for, sees or keeps a
login or a key, and has no sign-in screen. So before this step, once: install
Claude Code from Anthropic's setup page (https://code.claude.com/docs/en/setup;
that is your step on Windows, the studio installs nothing), open Git Bash in the
folder, type `claude` and sign in (an API key set the way that page describes is the
documented way; a Pro or Max login is your own choice). If you are asked "Is this a
project you created or one you trust?" answer **Yes, I trust this folder**: without
that, Claude ignores the folder's list of commands the helpers may run. Using
Claude costs your own plan or API credit. Then, in the page:

1. Press **Where did we leave off?** (or **What should we work on next?**). Nothing
   is sent to Claude until you press one of these or Send; the page says so under the
   message box. You should see your line, then the producer answering you as "director".
2. Type `Please ask a helper to list the games folder, then tell me what it found`
   and press Enter. You should see a **helper card** appear ("Helper · started",
   then "working", then "done"), and then the producer's answer. **Stop** ends a
   turn early. While the producer works, Check and Save are greyed out.
3. If a line says a helper "wasn't allowed to run ..." tell us which command it
   was; that is the list of allowed commands working as designed, and we want to
   know which ones are missing.
4. If `claude` is not found, or not signed in, the page says so in plain words;
   please tell us exactly what it said, and whether `claude --version` works in
   the same Git Bash window.

If any of this fails, report it as described below.

## Your AI assistant: say yes to its prompts once

If you make the game by talking to Claude Code or Codex in this folder, the
assistant speaks as your producer (it calls you "director") from its very first
message. Two things make that happen: it reads `AGENTS.md` (Claude Code reads
`CLAUDE.md`, which points at it), and a small session-start hook prints the
producer notes plus your game's names. The hook needs your OK **once per
folder**; this is what each tool asks, checked on Linux with Claude Code
2.1.296 and Codex 0.159.2 (Windows not checked, see below).

- **Claude Code** asks, the first time you open the folder:
  `Accessing workspace: <the folder>` / `Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team).` with
  `No, exit` (highlighted) and `Yes, I trust this folder`. Choose **Yes, I trust this folder**. There is no second question
  about the hook; it runs from then on. Claude Code stores the answer in
  `.claude.json` in your home folder.
- **Codex** asks two things. First `Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder settings can run code automatically, even without a model request. Continue only if you trust these files. Your trust decision will be saved.` Choose **Trust and continue**.
  Then `Hooks need review` / `1 hook is new or changed.` / `Hooks can run outside the sandbox after you trust them.` with
  `Review hooks`, `Trust all and continue` and `Continue without trusting (hooks won't run)`. Choose **Trust all and continue**.
  Codex stores both answers in `config.toml` in its home folder (`.codex`), and asks about the hook again if the repo ever changes it. Until you trust the folder
  and the hook, Codex quietly skips the hook.

While you make the game, please note whether the assistant started helpers
(a separate builder and checker, usually shown as extra agents or sub-tasks) or
said it was doing the work itself, and tell us which, with the tool you used.

What the hook does: it runs `tmp/para producer-context`, which only reads files
in this folder (and asks git two quick questions about your game) and prints
text: the producer notes, your game's names and a short "where things stand"
summary (the next step, the last save point, whether anything is unsaved, open
questions), so a new session picks up where the last one stopped. If git cannot
answer, that part is left out. It prints nothing (and the assistant carries on
normally) if `tmp/para` is not built yet, if you are working on the engine
rather than on your own game, or if anything goes wrong. So in a brand-new clone
the hook stays silent until step 3 has made your game; the first message still
gets the voice from `AGENTS.md`. If you say no to the prompts, nothing is lost
except the hook: the voice still comes from `AGENTS.md`.

Claude Code also reads the folder's `.claude/settings.json` permission list once you
have said yes to the trust prompt: it lets the assistant and its helpers run the
project's own `tmp/para test`, `check`, `build`, `sim` and `save -m` commands, and edit
files inside `games/`, without asking each time. It lists nothing that uploads, deletes,
resets or reaches the network, and `save --back`, `save --set-aside` and `backup --push` still ask first.

Not checked: the hook lines are written for a Bash-style shell (Git Bash from
step 1). Whether Claude Code and Codex run them that way on Windows has not been
tried; if the assistant does not greet you as director on Windows, report it
(the voice from `AGENTS.md` should still arrive).

## If a step fails

Stop and send back these four things:

1. **The step** (its number and the command you typed).
2. **The full error text**: select everything the terminal printed for that
   command, copy it and paste it. Do not shorten it.
3. **Your Windows version**: press the Windows key, type `winver`, press Enter,
   and read the version and build numbers.
4. **Your graphics card, or the virtual machine**: for a real PC, the card's name
   (Settings, System, Display, Advanced display); for a virtual machine, the
   program (VirtualBox, VMware, Hyper-V, ...) and whether 3D acceleration is on.

For a failed window step, also say whether any window appeared at all, even for
a second.

## What was and was not checked

The "where things stand" summary, `tmp/para save --set-aside` (puts unfinished
work aside without deleting it) and `tmp/para backup` (an optional private online
copy of your saved work, only after the assistant asks you and you say yes) have
**not been exercised on Windows**. A game also gets a `NOTES.md` from `tmp/para
new` now, where the assistant keeps short lessons about your game.

Steps 6 and 7 (`check` and `save`, and the `tmp/para studio` page with its chat, Play button and screenshots) have **not been exercised on Windows**; the studio's own tests ran on Linux only, and nothing about starting `claude` from the studio, finding `claude.exe` or a `claude.cmd` shim, ending its process tree with `taskkill /T`, or building and opening the game window from the studio (including reading the control channel's port file for a screenshot) has been run on Windows or macOS. The platform check is set up to run steps 1 to 4 on a hosted Windows machine,
and to compile the game the same way step 5 does (`nim c -d:dev
games/mygame/mygame.nim`, without `-r`); see `docs/platforms.md` and
`.github/workflows/platform-check.yml`. It is also set up to run the game's
developer control channel (what `tmp/para live` talks to) without a window. That
check is **paused** until 2026-11-01. The last hosted Windows runs that executed
passed new game, build, `test --filter games/mygame/`, the `nim c -d:dev`
compile and the `test_dev` tests; the `test_para_dev_cli` file aborted in its
"no display" test (no OpenGL on the runner), and the fix for that, plus anything
after it, was not re-run on Windows. The machine has no graphics card, so
**whether the window opens on a real Windows PC has not been checked by anyone
yet.**
