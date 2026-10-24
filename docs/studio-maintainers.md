# Studio: maintainer notes (`para studio`)

For whoever changes Studio. The guide for the friend using it is [studio.md](studio.md).

## Server and guards

`tmp/para studio` serves a small page from the `para` program itself and opens it in your browser.

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
  starts on one. With none, the page offers **Start a game**.
- Going back to an earlier save point and setting work aside are not in the page
  yet (use `para save --back` / `--set-aside` in the terminal).

## Source files and tests

The code is `tools/para/studiohttp.nim` (the server and its checks),
`studioapi.nim` (the routes and jobs), `preflight.nim` (the startup checks, below),
`studiocmd.nim` (the command),
`studiochat.nim` (the chat's turns, session files and the pick per game), `agent.nim`
(the interface every agent adapter fills in), `claudeagent.nim` (the Claude adapter),
`codexagent.nim` (the Codex adapter), `agentjson.nim` (reading an agent's JSON without
raising), `agents.nim` (which adapters exist), `studioplay.nim` (the game window),
`studioshot.nim` (the pictures) and `studio/index.html` (the page, compiled
into the binary with the fonts in `studio/fonts/`, which `studiofonts.nim` inlines; editing either
needs a rebuild of `para`). Visual boards are `boardcmd.nim` (`para board`, below) and
`browser.nim` (opening the browser, shared with `para studio`). Tests: `para test --filter
test_para_studio` and `para test --filter test_para_board`.

## How the page is built

The page is a desk in three columns (Pip's card on the left, the conversation in the middle, the
game panel on the right; under 1100px the panel slides in over the chat, and on a phone the left
column is a drawer). The page's own behaviour is described for the friend in
[studio.md](studio.md), "The page". The notes that used to sit under the message box moved to the
startup checks and the help (?).

**Sizes.** Big and round on purpose: 18px messages, a message box at least 64px tall, Pip the
parakeet three times the size it used to be.

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

## Start a game (route)

The studio runs `para new <name>` as a step, like Check and Save (`POST /api/new`, refused while
another step or a chat turn runs), then opens the new game. The name is normalised (spaces and
dashes become `_`, capitals become small letters) and checked first: small letters, digits and `_`,
starting with a letter, at most 40 characters, and not taken.

## Startup checks (internals)

The page asks the studio to look at the setup before any chat. It makes no model call and never
blocks Play, Check, Save or the chat (a chat sent anyway still gets the same plain messages as
before).

**A message sent while the setup is broken is kept.** If a turn ends in an error before the
producer said anything (not signed in, out of credit, not installed), the message goes back into
the message box (in front of anything typed since, with a blank line between), and the startup
checks are asked again at the same time.

**Claude's first run.** When Claude is installed but not signed in, or does not trust this folder,
the checks show a card with the folder, the command to paste (`cd "<this folder>"` and
`claude`, or just `claude` when the folder's path has a `"`, `$`, backtick, `%` or `\` in it or
starts with a Windows drive letter, since the page cannot know which shell is used) with a **Copy**
button, and what Claude asks the first time. On macOS the card also has **Open a terminal here**
(`POST /api/terminal`, which runs `open -a Terminal <this folder>`: a fixed program and folder,
nothing from the page). Linux has no one standard terminal and Windows has several, so there the
route answers 501. The card only shows text and copies it: the studio never reads, keeps or
touches a login, and never types into the terminal.
`GET /api/preflight` also returns `folder` (this folder) and `terminal` (whether that button is
offered) for it.

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

**Optional programs.** `GET /api/preflight` also returns `optional`: one row per program Studio
works without, today only Lavish (`boardCheck` in `boardcmd.nim`: `lavish-axi` looked up on the
PATH, nothing run). A row is `ok` or `absent`, never part of `ready` or the count; an absent one
carries `problem`, `about` (package, registry page, licence, Node.js needed) and `command`
(`tmp/para board install`), which the page shows under **Optional** with a **Copy** button. The
page installs nothing. `para studio --check` prints the same rows under "Optional", with no
`fix:` line and no effect on the exit code.

## Visual boards (`para board`)

A board is one HTML file in `games/<game>/review/<topic>.html` where the friend clicks choices and
leaves notes; the answer comes back to the producer (producer playbook, "Visual boards").

- **The template** is `.agents/skills/producer/board/board.html` plus `board.css`. `para board new`
  fills in the title, the stylesheet, the fonts (the Studio's own woff2 files as `data:` URIs,
  through `studiofonts.nim`), Pip (`tools/docs/theme/pip.svg`) and, when the game has one, its
  palette, so a board is one self-contained file: Lavish shows it in a sandboxed frame, and opened
  on its own it needs nothing else. `board.css` repeats the Studio page's tokens, light and dark;
  `tests/test_para_board_cmd.nim` fails if they drift from `studio/index.html` or the
  documentation site's `site.css`. A game palette is `art/style.toml`'s `palette` (a Lospec `.hex`
  file, as `para art lint` reads it), else the one `.hex` file in `art/`: `pickRoles` takes the
  lightest colour as paper, the darkest as ink (at least 4.5:1), the most colourful one that reads
  on the paper (3:1) as accent, and sets five `--game-*` variables; `board.css` derives the rest.
  The builder never adds styling.
- **Lavish** (`lavish-axi`, MIT, npm, needs Node.js 22+, checked with 0.1.92) runs a live board.
  It is optional: `boardCheck` only looks it up. `para board install` is the launchers' offer
  pattern: it checks Node.js (`engines: node >=22`) and that `npm prefix -g` is writable by this
  user, prints what/from/into/needs/command, asks y/n on standard input (closed input is no) and
  then runs exactly `npm install -g --no-fund --no-audit lavish-axi@0.1.92`. It never uses sudo.
  The launchers are unchanged: an optional Node.js program does not fit their
  required-tools-only flow.
- **Local only.** Lavish binds `127.0.0.1` plus, when Tailscale is running and `LAVISH_AXI_HOST`
  is unset, the machine's Tailscale IPv4 address, and its links then use the MagicDNS name (that is
  why boards opened by hand can show a tailnet URL). It also sends anonymous usage telemetry
  (command name, version, platform) to an Umami server at `a.kunchenguid.com` unless
  `LAVISH_AXI_TELEMETRY=0`, and its browser menu and `share` command publish to the third-party
  host ht-ml.app. Every command `para board` runs gets `localEnv`: `LAVISH_AXI_HOST=127.0.0.1`
  (which turns the Tailscale listener off), `LAVISH_AXI_PORT=4388` and
  `LAVISH_AXI_STATE_DIR=tmp/lavish` (its own server, never one started by hand with other
  settings), `LAVISH_AXI_TELEMETRY=0`, `LAVISH_AXI_HTML_APP_API_URL=http://127.0.0.1:9` (publishing
  fails, nothing is uploaded), `LAVISH_AXI_NO_OPEN=1`, and the link, allowed-host and token
  variables removed. `para board open` checks the link is loopback (`isLocalUrl`) before it opens
  the browser, and ends the session otherwise. `share`, `update`, `setup` and `export` are never
  run. The server stops by itself after the last session ends with nothing connected or after 30
  idle minutes; `para board stop` stops it at once.
- **Answers.** `para board answers` runs `lavish-axi poll --timeout-ms` (2 s), since a chat turn
  cannot hold an endless poll; Lavish keeps a sent answer queued until it is read. The template's
  one button queues a single prompt, `board picks (<topic>): key=answer; ...`, with the same
  answers as JSON. Lavish's own `next_step` (which names raw
  `lavish-axi` commands) and page outline are replaced by para board's next step.
- **Pictures** are copied next to the board (`pictures/`), because Lavish serves only the board's
  own folder: only image files from inside this folder, at most 10 MB each, each under a name of
  its own (compared without capitals): a clash between two `--picture`s, or with a different file
  already on the board, is refused before anything is copied.
- The producer may run `tmp/para board`'s `new`, `open`, `answers`, `end` and `stop`
  without a prompt (`.claude/settings.json`); never `install`. Not tried yet: Windows (npm's
  `lavish-axi.cmd`) and Codex as the producer (its sandbox may not allow the local server).

## The chat

The chat runs the `claude` program the friend installed and signed in to (or `codex`; see "Claude
or Codex" below), one turn at a time, in the paraloop folder:

```
claude -p --output-format stream-json --verbose --setting-sources project,local [--resume ID]
```

The message goes to it on standard input (never on a command line), and
`PARALOOP_UI=studio` is added to its environment so the producer says "press Play"
instead of giving terminal commands. `--setting-sources project,local` keeps user-level
hooks out; the folder's own `.claude/settings.json` (the producer's
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
sensitive file); saving goes through `para save`. The refusal text is in [studio.md](studio.md),
"What the producer can and cannot change", and the producer is told
(`.agents/skills/producer/SKILL.md`) not to work around it. Both
edit rules take effect only in a folder Claude Code trusts (see "If something goes wrong" in
[studio.md](studio.md)); in an untrusted folder `claude` ignores the whole allow-list, edits included.
`tests/test_para_producer_cmd.nim` guards the shape: only those two edit rules, only on
`games/**`, and no bare `Edit`, `Write` or `Bash(*)`.

- **Accounts.** The studio never reads, asks for, stores, logs, forwards or shows a
  login, a token or an API key, and has no sign-in screen. It only starts the
  unmodified `claude` you installed and signed in to yourself. An API key, set the way
  Claude Code's own setup describes, is the documented path; a Pro or Max login is the
  friend's own choice, made inside the unmodified `claude`. If `claude` is missing, not
  signed in, or out of credit the chat says so and what to do. The studio sends nothing
  until the friend presses one of the suggestions or sends a message; the startup checks
  and the help (?) say so.
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

## Claude or Codex

The pick per game is remembered in `tmp/studio/agent-<game>.txt` (a name and nothing else).
**Claude is the default** until Codex is picked for a game. A pick takes effect from the next
message and is refused while a turn is running. Each agent has its own conversation.

The Codex adapter (`codexagent.nim`) runs the `codex` program the friend installed and
signed in to (OpenAI's Codex CLI; it was written against 0.159.2), one turn per process:

```
codex app-server --listen stdio://
```

It then talks JSON-RPC over the child's standard input and output: `initialize`,
`thread/start` (or `thread/resume` with the saved thread id), `turn/start` with the
message inside the JSON (never on a command line), and `turn/interrupt` to stop. The
thread is started with `approvalPolicy: "never"` and `sandbox: "workspace-write"`, so
Codex never asks and a command outside its sandbox fails inside Codex; should a server
ask anyway, the answer is always no, and a request for a login token is answered with an
error. Never `danger-full-access`, never an automatic yes.

- **Stopping** asks Codex politely first (`turn/interrupt`, which also stops the command
  it was running) and only then ends the process tree, the way Claude's is ended.
- **Hooks.** Codex runs the folder's own `.codex/hooks.json` (the producer's
  session-start hook) and also the user's own `~/.codex/hooks.json`; it has no switch to keep
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
  or shows a login or a token.

## Play and screenshots (how it works)

The friend-facing description is in [studio.md](studio.md), "Play and screenshots".

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
