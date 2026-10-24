# The studio page (`para studio`)

`tmp/para studio` serves a small page from the `para` program itself and opens it in
your browser: the producer's chat, a Play button that opens your game's own window
(and a button that puts a screenshot of it in the chat), a "where we left off" panel
(the same digest `para producer-context` prints), a Check button, a Save box, the
save points, and the backup (with a confirmation that says what goes online and where).
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
  starts on one.
- Going back to an earlier save point and setting work aside are not in the page
  yet (use `para save --back` / `--set-aside` in the terminal).
- The code is `tools/para/studiohttp.nim` (the server and its checks),
  `studioapi.nim` (the routes and jobs), `studiocmd.nim` (the command),
  `studiochat.nim` (the chat's turns, session files and the pick per game), `agent.nim`
  (the interface every agent adapter fills in), `claudeagent.nim` (the Claude adapter),
  `codexagent.nim` (the Codex adapter), `agentjson.nim` (reading an agent's JSON without
  raising), `agents.nim` (which adapters exist), `studioplay.nim` (the game window),
  `studioshot.nim` (the pictures) and `studio/index.html` (the page, compiled
  into the binary; editing it needs a rebuild of `para`). Tests: `para test
  --filter test_para_studio`.

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
session-start hook and the allow-list of commands the helpers may run) still applies.
The studio never passes `--bare`, `--dangerously-skip-permissions` or a permission
mode; a command the allow-list does not cover is refused by `claude`, and the chat
shows that in plain words ("A helper wasn't allowed to run ... Ask the producer to do
it a different way.") instead of hanging.

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
  "What should we work on next?") or send a message; the page says so under the message box.
- **One turn at a time.** Check, Save and Backup wait while the producer is working,
  and the other way round. **Stop** ends the turn and everything it started (the
  whole process tree: its process group and descendants on macOS and Linux, `taskkill /T` on Windows).
  A turn is stopped after `--turn-timeout` minutes (default 60; long builds are
  normal). Closing the studio (Ctrl+C) ends a running turn too.
- **Conversations.** One per game and agent. The session id is kept in
  `tmp/studio/session-<game>-<agent>.id` (the id and nothing else) so a restart or a
  reopened page resumes it; "Start a fresh conversation" forgets every agent's id for
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

The page lists the producers this computer can use and lets you pick one per game
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
- **"claude" is not installed, or not signed in.** The chat says so. Install Claude Code
  from Anthropic's setup page (https://code.claude.com/docs/en/setup), open a terminal,
  run `claude` once and sign in, then press "Check again" on the page. The studio never
  asks for a login or key itself.
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
