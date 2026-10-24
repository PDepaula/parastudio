# The studio page (`para studio`)

`tmp/para studio` serves a small page from the `para` program itself and opens it in
your browser: the producer's chat, a Play button that opens your game's own window
(and a button that puts a screenshot of it in the chat), a "where we left off" panel
(the same digest `para producer-context` prints), a Check button, a Save box, the
save points, a button that starts a new game, and the backup (with a confirmation that
says what goes online and where).
Nothing to install (no Node, no Python), no account of ours and no telemetry; the
only thing that leaves the computer is what the `claude` or `codex` program you installed
sends to Anthropic or OpenAI when you chat (see "The chat" below).

- It listens on `127.0.0.1` only (there is no flag to change that), on any free
  port (`--port N` to pick one), and prints a link that carries a random key that
  changes every run. Every request needs that key, the `Host` has to be
  `127.0.0.1:<port>` or `localhost:<port>`, and a POST has to come from the page's
  own origin, so another website open in your browser cannot reach it. `--no-open`
  only prints the link. Ctrl+C stops it. It is meant for your own computer: the key
  is in the link, which the browser is started with, so on a shared computer another
  user who can list your running programs could read it.
- Check, Save and Backup run the same commands a terminal would, as child processes
  of the same binary (`para check`, `para save -m`, `para backup --push --yes`), so
  their guards still hold: a save needs a fresh passing check, a backup only goes
  to the remote named `backup`, never to `origin`, and only after the friend clicks
  yes. The page adds none of its own. Save and Backup work in the game's own git
  repository (`games/<game>/.git`, which `para new` makes); a game without one is
  saved in the repository that contains `games/`, as before.
- With more than one game in `games/` the page asks which one; `--game NAME`
  starts on one. With none, the page offers **Start a game** (below).
- Going back to an earlier save point and setting work aside are not in the page
  yet (use `para save --back` / `--set-aside` in the terminal).
- The code is `tools/para/studiohttp.nim` (the server and its checks),
  `studioapi.nim` (the routes and jobs), `preflight.nim` (the startup checks, below),
  `studiocmd.nim` (the command),
  `studiochat.nim` (the chat's turns, session files and the pick per game), `agent.nim`
  (the interface every agent adapter fills in), `claudeagent.nim` (the Claude adapter),
  `codexagent.nim` (the Codex adapter), `agentjson.nim` (reading an agent's JSON without
  raising), `agents.nim` (which adapters exist), `studioplay.nim` (the game window),
  `studioshot.nim` (the pictures) and `studio/index.html` (the page, compiled
  into the binary with the fonts in `studio/fonts/`; editing either needs a rebuild of
  `para`). Tests: `para test --filter test_para_studio`.

### The page

The page is a desk in three columns, big and round on purpose (18px messages, a message
box at least 64px tall, Pip the parakeet three times the size it used to be):

- **On the left**, Pip's card: the producer's face (it bobs while idle, thinks while a turn
  runs and talks when an answer arrives) and, when this computer knows more than one, the
  **Claude** / **Codex** pick for the game. Under it **New conversation**, the games in this
  folder (click one to switch), **Start a new game**, the save points, and at the bottom
  your name, **Back up online** (the cloud) and the light / dark / follow-the-computer switch.
  The name on the card is Pip unless the game's `PLAN.md` says `Call the producer:` something
  other than "producer". On a phone this column is a drawer behind the menu button.
- **In the middle**, the conversation and the message box. Under the box's text are the
  **+** menu (Show me a screenshot, Check the game, Save…) and two quick replies, "Where did
  we leave off?" and "What should we work on next?". Nothing is written under the box: the
  notes that used to sit there moved to the startup checks and the help (below). The top bar
  has the game's name (a menu when there are several), a **Running** pill while the game
  window is open, the **startup checks** pill, **?** for help, and the button that shows or
  hides the game panel.
- **On the right**, the game panel: **Play** (or **Play again**), **Show me a screenshot**
  and **Stop game**, the newest picture of the game window, **Check & save** (Check the game,
  then a note and Save; the badge says what is next: unsaved changes, ready to save, or
  everything saved), and **Where we left off**. On a window narrower than 1100px the panel
  slides in over the chat from that button instead.

![The Studio desk in the light look: Pip's card, the conversation, and the game panel](img/studio-1-front-door.png)

![The dark look with the startup checks open](img/studio-dark-checks.png)

![On a phone: the conversation, and the help (?) in the dark look](img/studio-phone.png)

**Help (?)** holds what used to be the fine print: Enter sends and Shift+Enter starts a new
line; nothing is sent until you press a suggestion or Send, and the studio never sees your
login; who pays (your own Claude plan or API credit, or your ChatGPT plan for Codex); what
Play does; that a save needs a passing check; and, with more than one producer, one line on
each (Claude is the default; only Codex, on a ChatGPT Plus plan or better, can make pictures).

![The help (?) popover](img/studio-help.png)

**Fonts.** The page uses Nunito for text and Fredoka for headings, Latin letters only, SIL Open
Font License 1.1 (`tools/para/studio/fonts/`, with their licences; listed in
`THIRD_PARTY.md`). They are put inside the page as `data:` addresses when `para` is built
(`studioapi.nim`, about 65 KB of fonts, 87 KB inlined; the `para` binary grows by about
110 KB), so the page still loads nothing from the network: its Content-Security-Policy adds
`font-src data:` and nothing else. Without them the page falls back to the system's own
rounded or plain sans-serif font.

**Not built: a list of past conversations.** The design this page follows had a "Producer
sessions" list in the sidebar. The studio keeps one conversation per game and producer (see
"Conversations" below), so there is nothing to list yet and the page leaves it out; keeping
several would need `studiochat.nim` to store more than one session id per game.

### Start a game

With no game in `games/` the greeting says so and offers **Start a game**; **Start a new
game** in the sidebar does the same at any time. You type a name (spaces and dashes become
`_`, capitals become small letters, so "Space Frogs" is `space_frogs`), and the studio runs
`para new <name>` as a step, like Check and Save (`POST /api/new`, refused while another step
or a chat turn runs), then opens the new game. The name is checked first and a problem is said
in plain words: it has to be small letters, digits and `_`, start with a letter, be at most 40
characters, and not be taken. What `para new` makes is the same as in a terminal: a copy of
`template/` in `games/<name>/` that is a git repository of its own.

![Start a game: a name, then the studio makes it](img/studio-start-game.png)

### Startup checks

The first thing the page does, before any chat, is ask the studio to look at the setup. The
answer is the pill in the top bar: green **Ready 4/4** when everything is fine, red **Setup needed**
(or amber when something could not be checked) when it is not. The pill opens the startup checks:
every check with a tick, or what is wrong with one plain line on how to fix it, the setup note when
the producer's program is missing, the two notes that used to sit under the message box (nothing is
sent until you press Send; who pays), and a **Check again** button. When something is not ready the
checks open by themselves the first time. It is only information: it never blocks Play, Check, Save
or the chat (a chat you send anyway still gets the same plain messages as before), and it makes no
model call, so it costs nothing.

**A message sent while the setup is broken is kept.** If a turn ends in an error before the
producer said anything (not signed in, out of credit, not installed), the message goes back into
the empty message box and the page says to fix the problem and press Send again; the startup checks
are asked again at the same time.

**Claude's first run.** When Claude is installed but not signed in, or does not trust this folder,
the startup checks also show a card for the first run, which happens in a terminal the page cannot
answer for you: the folder to open a terminal in, the command to paste (`cd "<this folder>"` and
`claude`) with a **Copy** button, and what Claude asks the first time in plain words: how text
should look (any choice is fine); how to sign in (an Anthropic Console API key, pay as you go and
the way Claude Code documents, or a Claude Pro or Max subscription, your own choice, whose usage
limits the chats count toward, or a company account); and what "Do you trust the files in this
folder?" means and which answer to pick. On macOS the card also has **Open a terminal here**
(`POST /api/terminal`, which runs `open -a Terminal <this folder>`: a fixed program and folder,
nothing from the page). Linux has no one standard terminal and Windows has several, so there the
card only offers the command to copy (the route answers 501). The card only shows text and copies
it: the studio never reads, keeps or touches a login, and never types into the terminal.
`GET /api/preflight` also returns `folder` (this folder) and `terminal` (whether that button is
offered) for it.

![The startup checks with Claude not signed in and the folder not trusted: the first-run card](img/studio-first-run.png)

| Check | What the studio looks at | Shown when it fails |
| --- | --- | --- |
| Installed | the `claude` (or `codex`) program is on the PATH | the setup page to install it from |
| Signed in | `claude auth status --json` (Codex: `codex login status`); only its yes/no is read | "open a terminal, run: claude, and follow its sign-in" |
| Folder trusted | Claude's own record, `projects["<this folder>"].hasTrustDialogAccepted` in `~/.claude.json` (`$CLAUDE_CONFIG_DIR/.claude.json` if set) | "open a terminal in this folder, run: claude, and choose Yes, I trust this folder" |
| Edits in `games/` allowed | the folder's `.claude/settings.json` (and `.claude/settings.local.json`) still allow `Edit(/games/**)` and `Write(/games/**)` and nothing denies them | "put the file back: git checkout -- .claude/settings.json" |

A check the studio has no safe way to answer says **Could not check** with a hint instead of a
guess (for example a `claude` too old to have `auth status`, a config file in a shape it does not
know, or Codex's trust record, which it can only confirm, not rule out). Codex gets the first three
checks and no edit-rule check, since its sandbox needs no list of rules. Claude's trust record is
per folder: trusting a parent folder does not cover it (checked with Claude Code 2.1.306), and
the first question `claude` asks has **No, exit** highlighted, so pressing Enter without moving
down leaves the folder untrusted. The studio only reads that one entry and the yes/no of the
sign-in answer: it never reads, keeps, logs or shows a login, a token, an email address or any other
folder in those files. `GET /api/preflight?game=` returns the checks for the producer picked
for the game (or the default one, with no game yet), asking again every time. Tests:
`tmp/para test --filter test_para_studio_preflight`; Linux is where it was checked, the trust
record's format on Windows has not been seen (a folder with no entry there is "could not check").

### The chat

The chat is the same producer you get in a terminal, in a page. It runs the
`claude` program **you** installed and signed in to (or `codex`; see "Claude or Codex"
below), one turn at a time, in your paraloop folder:

```
claude -p --output-format stream-json --verbose --setting-sources project,local [--resume ID]
```

Your message goes to it on standard input (never on a command line), and
`PARALOOP_UI=studio` is added to its environment so the producer says "press Play"
instead of giving terminal commands. `--setting-sources project,local` keeps your
user-level hooks out; the folder's own `.claude/settings.json` (the producer's
session-start hook and the allow-list of commands the helpers may run and files they may
change) still applies.
The studio never passes `--bare`, `--dangerously-skip-permissions` or a permission
mode; a command the allow-list does not cover is refused by `claude`, and the chat
shows that in plain words ("A helper wasn't allowed to run ... Ask the producer to do
it a different way.") instead of hanging.

**What the producer and its helpers can change.** A headless `claude -p` turn cannot ask
anyone, so it refuses every edit that no rule allows. The allow-list therefore holds two
edit rules, `Edit(/games/**)` and `Write(/games/**)` (`/` is the repository root, so this
is the `games/` folder and nothing else): the producer writes `PITCH.md`, `PLAN.md`,
`CHOICES.md`, `DESIGN.md`, `PLAYTEST.md` and `NOTES.md` there, and the builder, checker
and scouts (they share the turn's rules) change the game's code and reports there. The
rest of the allow-list is the `tmp/para ...` commands. Everything outside `games/` stays
read-only in the studio: the playbooks (`.agents`), `.claude/settings.json`, `AGENTS.md`,
`tools`, `src`, `docs`, `tests`, `template`, `skills` and the files at the top of the
repository. A game's own `.git` folder is refused too (Claude Code treats it as a
sensitive file); saving goes through `para save`. If something wants to change a file
outside `games/`, the chat shows, for example:

> The producer wasn't allowed to change `AGENTS.md`: in the studio it can only change
> files inside your game folder (`games/`). To change the studio itself, use the terminal.

and the producer is told (`.agents/skills/producer/SKILL.md`) not to work around it. Both
edit rules take effect only in a folder Claude Code trusts (see "If something goes wrong" below);
in an untrusted folder `claude` ignores the whole allow-list, edits included.
`tests/test_para_producer_cmd.nim` guards the shape: only those two edit rules, only on
`games/**`, and no bare `Edit`, `Write` or `Bash(*)`.

- **Accounts.** The studio never reads, asks for, stores, logs, forwards or shows a
  login, a token or an API key, and has no sign-in screen. It only starts the
  unmodified `claude` you installed and signed in to yourself. Install Claude Code
  from Anthropic's setup page (https://code.claude.com/docs/en/setup; on Windows
  that is your step, the studio installs nothing), then open a terminal once, run
  `claude` and sign in. An API key, set the way Claude Code's own setup describes, is
  the documented path; a Pro or Max login is your own choice, made inside the
  unmodified `claude`. If `claude` is missing, not signed in, or out of credit the
  chat says so and what to do. Using Claude costs your own plan or API credit; the
  studio sends nothing until you press one of the suggestions ("Where did we leave off?" or
  "What should we work on next?") or send a message; the startup checks and the help (?) say so.
- **One turn at a time.** Check, Save and Backup wait while the producer is working,
  and the other way round. **Stop** ends the turn and everything it started (the
  whole process tree: its process group and descendants on macOS and Linux, `taskkill /T` on Windows).
  A turn is stopped after `--turn-timeout` minutes (default 60; long builds are
  normal). Closing the studio (Ctrl+C) ends a running turn too.
- **Conversations.** One per game and agent. The session id is kept in
  `tmp/studio/session-<game>-<agent>.id` (the id and nothing else) so a restart or a
  reopened page resumes it; "New conversation" forgets every agent's id for
  the game. The lines on the page live in memory while the studio runs. The one file
  Claude used before there was a second agent, `session-<game>.id`, is still read for
  Claude and replaced by the new name the next time Claude answers.
- **Helpers** show as cards (builder, checker, scout, found from the playbook the
  producer names in the helper's prompt). A shell command left running in the
  background is a one-line note, not a card.
- **Untrusted text.** Everything the agent says is put on the page with
  `textContent`, never as HTML, and nothing in it is ever run. Any words of the
  agent's that reach the page as a diagnostic first have anything that looks like a
  key taken out.
- **Adding another agent** is one more file that fills in `AgentAdapter`
  (`agent.nim`) and one line in `agents.nim`; the server and the page do not change.
  The Claude adapter was written against Claude Code 2.1.296. It reads
  `--output-format stream-json` defensively: a malformed line is skipped, an unknown
  event is ignored, and a stream that no longer looks right gets a plain "the
  producer's tool changed" note. If `claude --version` cannot be read, the page says
  so.

### Claude or Codex

Pip's card lists the producers this computer can use and lets you pick one per game
(`tmp/studio/agent-<game>.txt` remembers the pick, a name and nothing else).
**Claude is the default** until you pick Codex for a game. A pick takes effect from the next message and is
refused while a turn is running. Each agent has its own conversation, so switching back
resumes where that agent stopped; the one you switch to has not seen the other's chat
and picks the game up from its notes (`PLAN.md`, `NOTES.md`) like any fresh producer.

The Codex adapter (`codexagent.nim`) runs the `codex` program **you** installed and
signed in to (OpenAI's Codex CLI; it was written against 0.159.2), one turn per process:

```
codex app-server --listen stdio://
```

It then talks JSON-RPC over the child's standard input and output: `initialize`,
`thread/start` (or `thread/resume` with the saved thread id), `turn/start` with your
message inside the JSON (never on a command line), and `turn/interrupt` to stop. The
thread is started with `approvalPolicy: "never"` and `sandbox: "workspace-write"`, so
Codex never asks and a command outside its sandbox fails inside Codex; should a server
ask anyway, the answer is always no, and a request for a login token is answered with an
error. Never `danger-full-access`, never an automatic yes.

- **Stopping** asks Codex politely first (`turn/interrupt`, which also stops the command
  it was running) and only then ends the process tree, the way Claude's is ended.
- **Hooks.** Codex runs the folder's own `.codex/hooks.json` (the producer's
  session-start hook) and also your own `~/.codex/hooks.json`; it has no switch to keep
  only the first kind.
- **Trust.** Like Claude, Codex treats a folder it has not been opened in as untrusted.
  If its project settings seem ignored, open a terminal in the folder once, run `codex`
  and answer the trust question.
- **Plans and limits.** Codex's own account check (`account/read`) can name the wrong
  plan (it said Free on a Plus account), so the studio does not use it. It shows what
  Codex reports when a turn ends: a plan with nothing left is shown as the plain
  message it is, with when it resets if Codex said, and the studio never retries around
  it. A note appears once per turn when a usage window passes 90 percent.
- **Pictures.** On a ChatGPT Plus plan or better Codex has an image tool
  (`image_gen__imagegen`; picture-making has been checked on a Plus plan, and the Free
  plan has no such tool). It saves a PNG under `~/.codex/generated_images/<thread>/<item>.png`.
  The adapter copies it (only a `.png` inside Codex's own `generated_images` folder, a plain
  file with the PNG signature, under 12 MB) into `tmp/studio/shots/` and shows it as a
  card in the chat, like a screenshot. The art helper can also call `codex exec` inside a
  Claude conversation, in the `workspace-write` sandbox, with your approval each time
  (see [`.agents/skills/art/SKILL.md`](../.agents/skills/art/SKILL.md)).
- **Accounts.** As for Claude: the studio never reads, asks for, stores, logs, forwards
  or shows a login or a token. Install Codex CLI from OpenAI's page
  (https://developers.openai.com/codex/cli; on Windows that is your step), open a
  terminal once, run `codex` and sign in. Using Codex costs your own ChatGPT plan or
  OpenAI API credit.

### Two copies, two studios

One studio runs one chat turn at a time (Check, Save and Backup wait for it), because the
producer changes files in the folder. To work on two things at once, keep two copies of
the folder and run a studio in each. They share nothing: each has its own files,
`tmp/` and save points, so they cannot step on each other.

```
git clone <the folder you have now> ../parastudio-b      # a second copy (or clone the repository again)
cd ../parastudio-b
nimble install -d -y && nimble setup
nim c --hints:off --outdir:tmp tools/para/para.nim
tmp/para studio --port 8788 --game <the other game>    # the first studio keeps its own port and link
```

Put the two browser tabs side by side. Each studio prints its own link (the key in it
differs), and each copy can use a different producer: pick Codex on the page in
one, leave the default in the other. Run `claude` and `codex` once in the new folder to answer
their trust question. A save lands in the copy it was made in; the simplest way to keep
things straight is one game per copy. Bringing the two lines of work together later is
the git merge a terminal user would do (`git fetch ../parastudio-b` then `git merge`), not a
step the page has.

### Play and screenshots

**Play** builds the game (the first time takes a few minutes, later ones are quick) and
opens its own window on this computer: the same window `nim c -r -d:dev
games/<game>/<game>.nim` opens in a terminal, without typing that. The page says how
the build is going, and if the window cannot open it says why in plain words and what
to do (the game did not build, this computer has no screen for it, the graphics driver
cannot do OpenGL). **Stop game** closes the window. Pressing **Play** again closes the
old window and starts over, so there is one game window at a time, and closing the
studio (Ctrl+C) closes it too. **Show me a screenshot** asks the open window for a
picture and puts it in the chat as a card; the studio keeps the newest 20 in
`tmp/studio/shots/` and deletes older ones. If the window the studio opened belongs to
a different game than the one picked on the page, the screenshot is refused and the page
says which game is open. The producer can ask you to press either.

How it works, for whoever changes it:

- Play runs `nim c -d:dev --out:tmp/studio/play/<game> games/<game>/<game>.nim` (with its hints
  off except `CC:`, which gives the page a progress line)
  and then that program, both in the repository root, started with an argument list
  (no shell). The program lives in its own folder, so it never overwrites the
  `tmp/<game>` that `para build` makes, and the compiler's cache is the one a terminal
  `nim c -r -d:dev` run uses. The web build is never used here, so nothing beyond
  Nim and a C compiler is needed: no emsdk, no Node.
- `-d:dev` is what puts the control channel in the game (`paraloop/dev`:
  `tmp/dev.sock`, a unix socket, or on Windows a loopback port written to that file).
  The studio asks it `ping` (what `para live status` asks) to tell "opening" from
  "open", and `shot` (what `para live shot` asks, through the same `devclient.nim`) for
  a picture. A game without the `-d:dev` block shows as "open, but not answering".
- Stopping ends the program and everything it started, with the same code that stops a
  chat turn (`agent.nim`'s `TurnControl`): its process group on macOS and Linux,
  `taskkill /T` on Windows. Nothing runs through `sh -c` or `cmd /c`, and no unix signal
  is used on Windows.
- The game's printed lines are kept in memory only (a few hundred lines) so a window
  that closes straight away can be told apart (no screen, no OpenGL, a crash). The studio
  writes no log file. Play is refused while a Check, Save or Backup step runs (a check
  builds the game too); it does not wait for a chat turn, since the producer's helpers
  change files while you watch.
- A picture is never read from a path the game names without checking it: the name has to
  be a `.png` inside the repository's `tmp/`, a plain file (not a link) that starts with the
  PNG signature and is under 12 MB, and the studio then moves it into `tmp/studio/shots/`
  under a name it makes up (`shot-<date>-<time>-<number>.png`). The route that gives
  a picture back to the page (`GET /api/shot?name=`, with the page's key like every other
  call) only looks in that folder and only for a name of exactly that shape, and answers
  `image/png`; it cannot name any other file.

### If something goes wrong

- **The page says it lost touch with the studio.** The terminal window running
  `tmp/para studio` was closed or stopped. Run it again and use the new link (the key in
  the link changes every run). Closing the browser tab does not stop the studio.
- **"codex" is not installed, or not signed in.** Same as the next item for Codex: install
  it from https://developers.openai.com/codex/cli, run `codex` once in a terminal and sign
  in, then press "Check again". A turn that ends with "no usage left" is Codex's plan
  talking; wait for it to reset (the message says when, if Codex told us) or pick Claude.
- **"claude" is not installed, or not signed in.** The startup checks pill turns red and the
  checks open with the fix (and, for signing in, the first-run card), and so does the chat if you
  send a message anyway; your message stays in the box to send again. Install Claude Code
  from Anthropic's setup page (https://code.claude.com/docs/en/setup), open a terminal,
  run `claude` once and sign in, then press "Check again" on the page. The studio never
  asks for a login or key itself.
- **The producer says it is not allowed to run commands or change files in your game folder.**
  Claude Code ignores the folder's allow-list until you have said Yes to its trust question
  there (the startup check says "Claude does not trust this folder yet", and so does the chat):
  open a terminal in the folder, run `claude`, choose **Yes, I trust this folder** (the
  highlighted choice is "No, exit", so move down first), then press "Check again" on the page. If the refusal names a file
  outside `games/`, that is on purpose (see "What the producer and its helpers can change").
- **Play says the game did not build.** Ask the producer to fix it; "Show the details"
  has the lines the compiler printed. If it says Nim or a C compiler was not found,
  `nim --version` and `gcc --version` need to work in the terminal you started the studio
  from (see [windows-first-game.md](windows-first-game.md) for what to install).
- **Play says there is no screen.** On Linux a window needs `DISPLAY` or
  `WAYLAND_DISPLAY`; over a remote connection (SSH) there is none. Run the studio on the
  computer in front of you.
- **Play says the graphics driver cannot start OpenGL**, or the game stops straight
  away and says nothing. Update the graphics driver. A virtual machine often has no
  real graphics at all; that is not a bug in your game (see the top of
  [windows-first-game.md](windows-first-game.md)).
- **The port is busy** ("could not start listening"). Run `tmp/para studio --port N` with
  another number, or leave `--port` out and the studio picks a free one.
- **A firewall or antivirus asks about the studio.** It only listens on your own computer
  (`127.0.0.1`), so no prompt should appear; if one does, "Cancel" and "Allow" both work,
  and please tell us it happened.
- **Where are the logs?** The studio writes none. The page's "Show the details" boxes hold
  the last lines of a failed build or a window that stopped; the terminal where you started
  it only shows the link. The pictures are in `tmp/studio/shots/`.
- **How do I stop it?** Press Ctrl+C in the terminal where you started it. That closes the
  game window the studio opened and ends a chat turn that is still running.
