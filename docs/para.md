# Building, testing and driving games (`para`)

`para` (task 1.8) is an [AXI](https://github.com/kunchenguid/axi)-shaped CLI: TOON
tables, definitive empty states, structured `error:`/`help[]:` output, exit codes
0 (pass) / 1 (findings) / 2 (usage error), and `--full` to un-truncate. Build it
with `nim c --hints:off --outdir:tmp tools/para/para.nim` (`nimble test` also
builds it as part of the test gate).

```sh
tmp/para                      # bare view: games with test/golden/web status, live status (cheap -- see `setup hooks`)
tmp/para test [--filter S] [--area A] [--skip-balance|--only-balance] [--shard I/N] [--full]   # wraps `nimble test`; --filter/--area run only matching test files; the balance flags skip or isolate the pins; --shard I/N one of N slices (CI)
tmp/para build [--game hello] [--target native|web] [--release|--debug] [--define NAME]... [--title T] [--feedback-url URL]   # web: a release build rendered to tmp/web/<game>/ (--define, --title and --feedback-url are web-only)
tmp/para sim --game hello --seed 7 --ticks 3600   # headless run: state, entities, perf vs budget, state and facts hash
tmp/para sim --from tmp/bugs/<stamp>              # replay an F9 bug capture, report the state hash
tmp/para shot --game hello --at title,t600 --check  # render frames at ticks, diff against goldens
tmp/para shot --script run.txt --seed 7 --size 960x540 --check  # same, from a scripted, seeded run in a pinned window (`para shot --help`)
tmp/para shot --update-golden t600                # save those frames as the goldens
tmp/para driver <game> <command> ...              # a game's own driver program, for any game that ships games/<game>/tools/<game>_driver.nim (`para driver <game> --help`)
tmp/para live <status|shot|...>                   # talk to a running -d:dev game's control channel
tmp/para web smoke [--game G] [--define NAME] [--enter] [--click X,Y]   # build (release), postbuild, and CDP-smoke the wasm target
tmp/para web pack [--game G]                      # zip tmp/web/<game>/ into what a static host needs
tmp/para setup hooks                              # print a SessionStart hook config (prints only)
tmp/para producer-context                         # the producer voice plus a resume digest (next step, last save, unsaved changes) for a friend's session-start hook (silent for engine work); `PARALOOP_UI=studio` adds one line telling the producer to say "press Play" (and that a screenshot button exists)
tmp/para backup [--game G] [--push --yes [--is-private]]  # a friend's own private online backup of the game's own repository: status, or upload to the "backup" remote only (never origin; `--help`)
tmp/para studio [--game G] [--port N] [--no-open] [--turn-timeout MIN]  # a page in your browser: the producer's chat (Claude or Codex, your pick per game), Play (the game's own window) and screenshots, Check, Save, save points, backup (127.0.0.1 only; see [studio.md](studio.md))
```

`para` is checked against the AXI spec with
`npx -y axi-axi@0.1.0 validate "$PWD/tmp/para" --dir . --strict` (every
automated check passes; CI runs it), and `skills/para/SKILL.md` is its
installable agent skill, carrying the `para --help` text (a test fails when
the two drift).

`--game` takes any `<name>` with an `examples/<name>/<name>.nim` or
`games/<name>/<name>.nim`; `sim` and `shot` run hello (the game linked into `para`) in
process and any other game through its `games/<name>/tools/<name>_driver.nim` program. `shot` renders in a
hidden GL window from a fresh run with no input, so it needs a display
(`DISPLAY`, or `xvfb-run`). Golden frames are re-rendered by a human with the game's own
tooling (a game's `goldens/README.md`). Frames go to `tmp/frames/<game>_<name>.png`,
goldens live in `<game dir>/goldens/<name>.png`, and a changed frame also gets
a `.diff.png`. `live` talks to `paraloop/dev`'s control channel over its unix
socket (`tmp/dev.sock` by default; on Windows a loopback TCP port named in
that file): start a `-d:dev` game first (e.g.
`nim c -r -d:dev examples/hello/hello.nim`), then run `para live status` or
`para live shot` from another terminal. `para test`, `para shot --check` and
`para web smoke` record their last outcome, pass or fail, under
`tmp/status/<game>/`, which the bare view reads. `para setup hooks` prints the
SessionStart hook snippet that shows the bare view at the start of every
agent session; it never edits a config file itself.
