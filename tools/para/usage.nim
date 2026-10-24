# `para --help`'s text (AXI §10: concise help with flags and examples, the
# commands table `axi-axi validate` discovers subcommands from). The same
# text is the body of skills/para/SKILL.md, which tests/test_para_usage.nim
# keeps in step with it (AXI §7).

import art/toon

const paraCommands* = ["art", "new", "test", "check", "save", "backup", "build", "sim", "shot", "driver", "live", "web", "setup", "producer-context", "studio", "board"]

const paraHelp* = "para: build, test, see and drive paraloop games in this workspace; " &
  "bare `para` is the home view\n" &
  toonTable("commands", ["command", "summary"], @[
    @["art <lint|fix|sheet> [args]", "pixel-art lint/fix/sheet (`para art --help`)"],
    @["new <game>", "create games/<game>/ from template/ as a git repository of its own, where `para save` keeps its save points (`para new --help`)"],
    @["test [--filter SUBSTR] [--area AREA] [--skip-balance | --only-balance] [--shard I/N] [--full]", "wraps `nimble test`: counts and a failures table; --filter/--area run only the matching test files; --skip-balance/--only-balance skip or run just the balance pins; --shard I/N runs one of N slices (CI runs one per runner)"],
    @["check [--game NAME]", "run the game's own tests (balance pins skipped) and build it, one pass/fail line per step and a verdict (exit 1 on a fail); a pass is what lets `para save` save the game as it is now"],
    @["save [--game NAME] -m TEXT | --list | --back N --yes | --set-aside", "keep games/<game> as the next numbered save point (a git commit in the game's own repository, games/<game>/.git, tagged save-<game>-<n>) after a passing `para check`; refuses on a detached git, on changes outside the game (a game that has no repository of its own), or on a stale check; --back N adds a new save point that undoes the later ones; --set-aside keeps unfinished work as an unchecked save point and goes back to the one before; never pushes or resets"],
    @["backup [--game NAME] [--push --yes [--is-private]]", "say whether the friend's own private online backup (the git remote \"backup\" of the game's own repository) is set up, or with --push --yes upload the current branch and its save points there; refuses a public or unconfirmed-private repository, any remote that is not \"backup\", and anything that points at origin or the paraloop project; never forces; nothing runs it by itself"],
    @["build [--game NAME] [--target native|web] [--release | --debug] [--define NAME[=VALUE]] [--title TEXT] [--feedback-url URL] [--full]", "compile a game; structured compiler errors; --target web is a release build (--debug for the other) rendered to tmp/web/<game>/index.html with a build id, --define NAME[=VALUE] (web only) passes a define to the compile"],
    @["sim [--game NAME] --seed N --ticks N [--script FILE | --keys S] [--budget-ms X] [--trace N] [game flags] | --from DIR", "headless run, optionally replaying an input script or gating on p99 (state/entities/perf/hash/facts-hash; --trace N adds the facts hash every N ticks), or F9 bug replay; a game's own flags (a starting treasure, a gate on smashes or peak mobs, a room) come from its driver, `para sim --game NAME --help`"],
    @["shot [--game NAME] [--at FRAMES] [--check] [--script FILE | --keys S] [--seed N] [game flags] [--fixtures DIR] [--size WxH] [--tolerance N] [--max-diff-px N] | --update-golden FRAMES", "render frames at ticks or phases from a scripted, seeded run, or from state fixtures (--fixtures), and diff them against goldens"],
    @["driver GAME [COMMAND ARGS...]", "run a command only that game has through its driver program (games/GAME/tools/GAME_driver.nim; `sim` and `shot` use the same program for a game that is not linked into para)"],
    @["live <status|shot|...> [--sock PATH]", "talk to a running -d:dev game's control channel"],
    @["web smoke [--game NAME] [--debug] [--define NAME[=VALUE]] [--enter] [--click X,Y] [--ticks N] [--chrome PATH] [--sound] [--full]", "build (release unless --debug) and CDP-smoke the wasm target; --enter taps Enter first for a title that ignores the arrows; --click X,Y posts a real click and checks the canvas gets it and the engine pointer exports are up"],
    @["web pack [--game NAME | --dir DIR] [--out FILE]", "zip tmp/web/<game>/ into exactly what a static host needs (reproducible; a dev build is refused)"],
    @["setup hooks", "print a SessionStart hook config (prints only)"],
    @["producer-context", "print the producer voice, the game's names and a short resume digest (next step, last save point, unsaved changes, open choices) for a session-start hook (what .claude/settings.json and .codex/hooks.json run); nothing at all outside a friend's game folder or on any error, exit 0"],
    @["studio [--game NAME] [--port N] [--no-open] [--turn-timeout MINUTES] [--check]", "open a page in your browser with the producer's chat (it runs the claude or codex program you installed and signed in to yourself, the page lets you pick per game; the studio never sees a login or key), a Play button that opens your game's own window and a screenshot button that puts a picture of it in the chat, Check, Save, your save points and the backup; served by `para` itself on 127.0.0.1 only, the link carries a key that changes every run; Check, Save and Backup run the same `para` commands with the same guards; a chat turn is stopped after --turn-timeout minutes (default 60); Ctrl+C stops it (and closes the game window); --check only prints the page's startup checks (installed, signed in, folder trusted) and exits"],
    @["board [status|install|new TOPIC|open BOARD|answers BOARD|reply BOARD|end BOARD|stop]", "visual boards: a page in the friend's browser where they click choices and leave notes and the answers come back to the producer (`para board --help`); a live board needs Lavish (lavish-axi, optional, from npm; `board install` says what and from where and asks y/n first), run on 127.0.0.1 only with its usage counts and publishing off; without it a board is a page whose button copies the picks"]]) &
  toonTable("flags", ["flag", "description"], @[
    @["--help", "show help for any command"],
    @["--version", "print the version"]]) &
  "examples[9]:\n" &
  "  para new mygame\n" &
  "  para test\n" &
  "  para check --game mygame\n" &
  "  para save --game mygame -m \"ship moves\"\n" &
  "  para sim --game hello --seed 7 --ticks 3600\n" &
  "  para shot --game hello --at title,t600 --check\n" &
  "  para driver mygame replay --seed 8\n" &
  "  para build --target web --game hello --title Hello\n" &
  "  para web pack --game hello\n"
