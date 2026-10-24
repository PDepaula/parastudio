---
name: para
description: Build, test, see and drive paraloop games in this repo through the `para` AXI CLI (tmp/para) instead of raw nimble/nim/node commands. Use for running tests, compiling a game, headless sim runs and bug replays, golden-frame screenshots, a live -d:dev game, and the web smoke check.
---

# para

Build it with `nim c --hints:off --outdir:tmp tools/para/para.nim` (`nimble test`
also builds it), then run `tmp/para` from the repo root. Bare `tmp/para` prints
the home view: each game's last recorded test, golden and web-smoke status, and
whether a live `-d:dev` window is running. Output is TOON; exit codes are 0
(ok), 1 (findings) and 2 (usage error); `--full` un-truncates.

`tmp/para --help`:

```text
para: build, test, see and drive paraloop games in this workspace; bare `para` is the home view
commands[17]{command,summary}:
  art <lint|fix|sheet> [args],pixel-art lint/fix/sheet (`para art --help`)
  new <game>,"create games/<game>/ from template/ as a git repository of its own, where `para save` keeps its save points (`para new --help`)"
  test [--filter SUBSTR] [--area AREA] [--skip-balance | --only-balance] [--shard I/N] [--full],"wraps `nimble test`: counts and a failures table; --filter/--area run only the matching test files; --skip-balance/--only-balance skip or run just the balance pins; --shard I/N runs one of N slices (CI runs one per runner)"
  check [--game NAME] [--lane ID],"run the game's own tests (balance pins skipped) and build it, one pass/fail line per step and a verdict (exit 1 on a fail); a pass is what lets `para save` save the game as it is now; --lane ID checks a helper's lane instead (a rehearsal: it lets nothing be saved)"
  save [--game NAME] -m TEXT | --list | --back N --yes | --set-aside,"keep games/<game> as the next numbered save point (a git commit in the game's own repository, games/<game>/.git, tagged save-<game>-<n>) after a passing `para check`; refuses on a detached git, on changes outside the game (a game that has no repository of its own), or on a stale check; --back N adds a new save point that undoes the later ones; --set-aside keeps unfinished work as an unchecked save point and goes back to the one before; never pushes or resets"
  lane <start|list|land|drop|clean> [args],"a helper's own copy of a game (games/<game>.<id>/, a git worktree of the game's repository) so helpers work at once without touching the game; land puts its work into the game as unsaved changes for `para check` and `para save`; never commits on the game's line, and never removes work that is not landed (`para lane --help`)"
  backup [--game NAME] [--push --yes [--is-private]],"say whether the friend's own private online backup (the git remote \"backup\" of the game's own repository) is set up, or with --push --yes upload the current branch and its save points there; refuses a public or unconfirmed-private repository, any remote that is not \"backup\", and anything that points at origin or the paraloop project; never forces; nothing runs it by itself"
  build [--game NAME] [--lane ID] [--target native|web] [--release | --debug] [--define NAME[=VALUE]] [--title TEXT] [--feedback-url URL] [--full],"compile a game; structured compiler errors; --target web is a release build (--debug for the other) rendered to tmp/web/<game>/index.html with a build id, --define NAME[=VALUE] (web only) passes a define to the compile; --lane ID builds a helper's lane natively into tmp/lanes/<game>.<id>/"
  sim [--game NAME] --seed N --ticks N [--script FILE | --keys S] [--budget-ms X] [--trace N] [game flags] | --from DIR,"headless run, optionally replaying an input script or gating on p99 (state/entities/perf/hash/facts-hash; --trace N adds the facts hash every N ticks), or F9 bug replay; a game's own flags (a starting treasure, a gate on smashes or peak mobs, a room) come from its driver, `para sim --game NAME --help`"
  shot [--game NAME] [--at FRAMES] [--check] [--script FILE | --keys S] [--seed N] [game flags] [--fixtures DIR] [--size WxH] [--tolerance N] [--max-diff-px N] | --update-golden FRAMES,"render frames at ticks or phases from a scripted, seeded run, or from state fixtures (--fixtures), and diff them against goldens"
  driver GAME [COMMAND ARGS...],run a command only that game has through its driver program (games/GAME/tools/GAME_driver.nim; `sim` and `shot` use the same program for a game that is not linked into para)
  live <status|shot|...> [--sock PATH],"talk to a running -d:dev game's control channel"
  "web smoke [--game NAME] [--debug] [--define NAME[=VALUE]] [--enter] [--click X,Y] [--ticks N] [--chrome PATH] [--sound] [--full]","build (release unless --debug) and CDP-smoke the wasm target; --enter taps Enter first for a title that ignores the arrows; --click X,Y posts a real click and checks the canvas gets it and the engine pointer exports are up"
  web pack [--game NAME | --dir DIR] [--out FILE],zip tmp/web/<game>/ into exactly what a static host needs (reproducible; a dev build is refused)
  setup hooks,print a SessionStart hook config (prints only)
  producer-context,"print the producer voice, the game's names and a short resume digest (next step, last save point, unsaved changes, open choices) for a session-start hook (what .claude/settings.json and .codex/hooks.json run); nothing at all outside a friend's game folder or on any error, exit 0"
  studio [--game NAME] [--port N] [--no-open] [--turn-timeout MINUTES] [--check],"open a page in your browser with the producer's chat (it runs the claude or codex program you installed and signed in to yourself, the page lets you pick per game; the studio never sees a login or key), a Play button that opens your game's own window and a screenshot button that puts a picture of it in the chat, Check, Save, your save points and the backup; served by `para` itself on 127.0.0.1 only, the link carries a key that changes every run; Check, Save and Backup run the same `para` commands with the same guards; a chat turn is stopped after --turn-timeout minutes (default 60); Ctrl+C stops it (and closes the game window); --check only prints the page's startup checks (installed, signed in, folder trusted) and exits"
  board [install|new TOPIC|open BOARD|answers BOARD|end BOARD|stop],"visual boards: a page in the friend's browser where they click choices and leave notes and the answers come back to the producer (`para board --help`); a live board needs Lavish (lavish-axi, optional, from npm; `board install` says what and from where and asks y/n first), run on 127.0.0.1 only with its usage counts and publishing off; without it a board is a page whose button copies the picks"
flags[2]{flag,description}:
  --help,show help for any command
  --version,print the version
examples[9]:
  para new mygame
  para test
  para check --game mygame
  para save --game mygame -m "ship moves"
  para sim --game hello --seed 7 --ticks 3600
  para shot --game hello --at title,t600 --check
  para driver mygame replay --seed 8
  para build --target web --game hello --title Hello
  para web pack --game hello
```

## The studio page

`tmp/para studio` opens a page in the friend's browser with the producer's chat,
Play, a screenshot button, Check, Save, the save points, the backup and a resume panel. It listens on
127.0.0.1 only and the printed link carries a key that changes every run;
`--no-open` only prints the link, Ctrl+C stops it. The buttons run the same `para
check`, `para save -m` and `para backup --push --yes` a terminal would (child
processes of the same binary), so a save still needs a fresh passing check and a
backup still only goes to the remote named `backup`, after a click on a yes.

The chat starts the friend's own `claude` program (`claude -p --output-format
stream-json --verbose --setting-sources project,local`, the message on its standard
input, `PARALOOP_UI=studio` in its environment) in the repo root, one turn at a
time, and resumes the same conversation per game and agent from a session id kept in
`tmp/studio/session-<game>-<agent>.id`. It sends nothing until the friend sends a message.
**The studio never reads, asks for, stores, logs, forwards or shows a login, a token
or an API key**, and has no sign-in screen: the friend signs in to `claude` once in
a terminal, an API key is the documented path, and a Pro or Max login is the
friend's own choice made inside the unmodified `claude`. If `claude` is missing, not
signed in or out of credit, the chat says so in plain words and points at Anthropic's
setup page. **Play** builds the game with its dev channel in
(`nim c -d:dev --out:tmp/studio/play/<game> games/<game>/<game>.nim`) and opens its own
native window as a program the studio owns (one at a time; a second Play restarts it;
Stop game or Ctrl+C closes it); the web build, emsdk and Node are never used. **Show me a
screenshot** asks that window for a picture over the dev control channel (what `para live
shot` does) and shows it as a card in the chat; the studio keeps the newest 20 in
`tmp/studio/shots/` and serves only those, by exact name. When the window cannot open the
page says why in plain words (the game did not build, no screen, no OpenGL). Helpers show up as cards (builder, checker, scout); a call the project
allow-list in `.claude/settings.json` does not cover is refused by `claude` and shown
in plain words (edits are allowed under `games/` only; see `docs/studio.md`). Agents are adapters (`tools/para/agent.nim`, `claudeagent.nim`,
`agents.nim`); the other is Codex (`codexagent.nim`, `codex app-server`), picked per game on the page with Claude the default; see `docs/studio-maintainers.md`, "Claude or Codex". Tests: `para test --filter
test_para_studio`.

## Visual boards

`tmp/para board` makes and runs visual boards: a page in the friend's browser where they click
choices and leave notes, and the answers come back to the producer (`.agents/skills/producer/SKILL.md`,
"Visual boards"). `board new TOPIC --game NAME` writes `games/<game>/review/<topic>.html` from the
shared template in `.agents/skills/producer/board/` (`board.html` and `board.css`: the Studio Desk
tokens, the fonts and Pip, all inside the one file; the game's own palette when `art/style.toml`
names one); `board open BOARD [--picture FILE]...` opens it; `board answers BOARD`
reads what the friend sent; `board end` and `board stop` finish. A live board runs
on Lavish (`lavish-axi`, MIT, from npm, needs Node.js 22+), which is optional and only installed by
the friend through `board install` (it says what and from where, then asks y/n). `para board` runs
it with `LAVISH_AXI_HOST=127.0.0.1` (no Tailscale or LAN listener), its own port (4388) and state
folder (`tmp/lavish/`), telemetry off and publishing pointed at a closed local port, and closes any
board whose link is not a loopback address. Without Lavish the board is a page whose button copies
the picks. Tests: `para test --filter test_para_board`.
