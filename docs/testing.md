# Running the tests

```sh
nimble install -d -y   # fetch dependencies pinned in nimble.lock
nimble setup           # wire the dependency paths into config.nims
nimble test            # headless tests
```

`nimble test` also runs `para art fix`'s Python tests, so it needs
[uv](https://docs.astral.sh/uv/) on `PATH` (see [`tools/art/README.md`](../tools/art/README.md)).

## The local loop: `para test --filter`

The whole suite is about 10 minutes from a cold Nim cache (it compiles and
runs ~60 test files one after another), so while working run only the files
you touched. Build `para` once (`nim c --hints:off --outdir:tmp tools/para/para.nim`), then:

```sh
tmp/para test --filter test_audio     # only test files whose path contains "test_audio"; the rest are not compiled
tmp/para test --filter games/         # every game test
tmp/para test --area game             # the game's tests + the `para` tests that link it
tmp/para test --area art              # the art pipeline's tests + pytest (tools/art)
tmp/para test                         # everything (what main and engine changes run)
```

`--filter` is a case-insensitive substring of the test file's path and runs
*only* those files (a bare `--filter` run skips pytest and the final `para`
build too); `--area` picks the files whose import graph reaches that part of
the repo, and combines with `--filter`. The first run of a file compiles it
(game tests ~8 s each); later runs reuse `.nimcache/` and cost only the test's
own run time. Each test file prints one `progress I/N: <file>: pass|FAIL` line
on stderr as it finishes, so a long run shows how far it got; a failing golden
frame is for CI or a human to re-render, never fixed locally.

## Running the checks on demand

CI runs on every push to `main` and every pull request (`ci.yml`), and by hand.
`platform-check.yml` is manual only. To run the full Linux CI yourself:

```sh
tmp/para test --filter <file>         # locally: the narrow run for what you changed
gh workflow run ci.yml                # the full Linux CI
gh workflow run ci.yml --ref <branch> # the same, on a branch (the workflow file must exist on it)
gh run watch                          # follow the run
```

A manual run takes the `all` row of the table below (every test). The
repository variable `CI_RUNNER` (JSON `runs-on`, e.g.
`["self-hosted","linux","paraloop-ci"]`) picks a self-hosted runner; unset, CI
runs on GitHub-hosted `ubuntu-latest`.

## What CI runs for a pull request

CI runs the `test` job as four shards on four runners (`para test --shard i/4`,
one quarter of the selected files each, under one aggregate check named `test`) and scopes
a pull request's selection to the area it touches
(`.github/scripts/ci-scope.sh` buckets the changed paths, then runs
`para test --area ...`; run `git diff --name-only origin/main... | .github/scripts/ci-scope.sh`
to see what a diff triggers). A test file is in an area when the repo files it
imports (transitively) include that area's source roots
(`tools/para/testplan.nim`), so a change can only skip a test that cannot see it.

| Changed paths | `para test --area` | Runs |
| --- | --- | --- |
| `games/<name>/` code, tests, goldens | `game` | every test under `games/*/tests/` plus the `tests/test_para_*` files that link the game (`sim_cli`, `shot_script`, `dev_cli`, `usage`) and the sim gate |
| `games/*/assets`, `games/*/art`, `games/*/atlas`, `tools/art/`, `tools/para/artcmd.nim`, `tools/para/art/{fix,lint,profile,sheet,sidecar,toml}.nim`, `tests/fixtures/art/`, `tests/test_art_*` | `art` | `tests/test_art_*`, the `para` tests that import those modules, and pytest for `tools/art` |
| `src/`, `template/`, `tools/para/` (the rest, incl. `art/clihelpers.nim`, `art/toon.nim`), `tools/web/`, `examples/`, `patches/`, `.github/`, `config.nims`, `paraloop.nimble`, `nimble.lock`, `tests/` (the rest), `skills/para/` (a test reads `SKILL.md`), any path not listed here | `all` | everything, same as a push to main |
| `*.md`, `docs/`, `tools/docs/`, `skills/` (except `skills/para/`), `LICENSE*`, `.github/ISSUE_TEMPLATE/` only | none | the `test` job is skipped (reports skipped) |

Pushes to main, `workflow_dispatch` and any non-PR run always use `all`, and an
unreadable or empty diff fails open to `all`.

`PR_FULL_TESTS=off` skips the full-suite jobs on pull requests.

The `docs` job is not scoped: it runs on every pull request and push, docs-only ones included,
builds the documentation site with `uv run tools/docs/build.py` (about half a minute) and fails
on a broken link or image, missing alt text, headings out of order, or a local path, tailnet
address or email address ([site.md](site.md) has the full list). Run the same command locally
before pushing a docs change.

Heavy simulation tests (`test_sim_replay`, `test_para_shot_script`,
`test_para_sim_cli`, and a game's bot-run and driver tests) each carry a `test_<name>.nims` beside them that builds that
file with `--stacktrace:off -O1`: same assertions and every runtime check
still on, ~5-7x faster. Delete the `.nims` to get Nim stack traces back while
debugging an unexpected exception in one of them.

CI (`.github/workflows/ci.yml`) can run on a self-hosted runner instead of
GitHub-hosted runners (`CI_RUNNER`), and can skip the full suite on PRs
(`PR_FULL_TESTS`), each switched by a repository variable; see the header comment in `ci.yml`.
