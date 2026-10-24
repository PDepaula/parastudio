# Package

version       = "0.1.0"
author        = "Patrick"
description   = "Para Studio: make a small 2D game with an AI producer, on the paraloop engine (Nim, paranim, pararules)"
license       = "MIT"

import std/[os, strutils, algorithm]

# Dependencies

requires "nim == 2.2.10"
requires "paranim == 0.12.0"
requires "pararules == 1.4.0"
requires "stb_image == 2.5"
requires "paratext == 0.13.0"
requires "parasound == 1.0.0"

bin = @["tools/para/para"]

task test, "Run headless tests":
  # nimble 0.22.2 (bundled with Nim 2.2.10) exits 0 even when a task fails, so
  # the task writes tmp/tests-passed only after every test passes; `para test`
  # (which CI runs) checks it.
  #
  # PARALOOP_TEST_PLAN names a file `para test --filter/--area` wrote
  # (tools/para/testplan.nim): one entry per line -- `pytest tools/art/tests`,
  # a test file, a test group (a tests directory's pin_tests.nim, standing in
  # for the test files it imports), `build tools/para/para.nim` -- and only
  # those entries run. Unset (a bare `nimble test`, or a bare `para test`),
  # everything runs, each test file as its own program.
  rmFile "tmp/tests-passed"
  if not dirExists("tmp"): mkDir "tmp"
  let planPath = getEnv("PARALOOP_TEST_PLAN")
  var plan: seq[string]
  if planPath.len > 0:
    for line in readFile(planPath).splitLines:
      if line.len > 0: plan.add line
  var ran: seq[string]
  proc wanted(path: string): bool =
    # The plan names files with '/'; on Windows `/` joins them with '\\'.
    let id = path.replace('\\', '/')
    result = planPath.len == 0 or id in plan
    if result: ran.add id
  # A helper's lane (`games/<game>.<id>/`, tools/para/lanecmd.nim) holds the same test files as
  # its game, so its programs go to tmp/lanes/<game>.<id>/ (config.nims gives it its own cache
  # too): two copies of a game testing at once never overwrite each other's binary.
  proc outDirOf(f: string): string =
    let parts = f.replace('\\', '/').split('/')
    if parts.len > 2 and parts[0] == "games" and '.' in parts[1]: "tmp/lanes/" & parts[1] else: "tmp"
  # Compile, then run the binary: `nim c -r` keeps the compiler (2-3 GB for a test that links a
  # game) resident for as long as the test runs, and a test that builds another program (a game's
  # balance probe) would then hold two compilers at once -- over a CI container's 6 GB.
  proc runTest(f: string) =
    echo "running ", f
    let outDir = outDirOf(f)
    exec "nim c --hints:off --outdir:" & outDir & " " & f
    exec outDir / f.extractFilename.changeFileExt(ExeExt)
  # A test group is one compile for several test files. The program prints `running <file>`
  # itself as each file's tests start, and `finished` after the last, so this only says that
  # the build began (`para test` reads the three lines, tools/para/testcmd.nim).
  proc runGroup(group: string) =
    echo "building ", group
    let outDir = outDirOf(group)
    exec "nim c --hints:off --outdir:" & outDir & " " & group
    exec outDir / group.extractFilename.changeFileExt(ExeExt)
  # One tests directory: its group first, when the plan names it, then each test file the plan
  # names (a plan names a group instead of its files, never both).
  proc sweep(testsDir: string) =
    let group = testsDir / "pin_tests.nim"
    if planPath.len > 0 and wanted(group): runGroup group
    for f in listFiles(testsDir).sorted:
      let name = f.extractFilename
      if name.startsWith("test_") and name.endsWith(".nim") and wanted(f):
        runTest f
  # `para art fix`'s Python steps (tools/art/, asset pipeline report §8.2):
  # `uv run --locked` syncs tools/art/uv.lock (failing, not re-resolving,
  # when pyproject.toml has drifted from it) before running its own unit
  # tests, scoped to tools/art/tests so pytest never collects stray test_*.py
  # from the repo root (CI's emsdk-cache/ checkout). The Nim-level regression test (§6.3) below runs the same
  # `uv run --locked` command as the real `para art fix` CLI.
  if wanted("pytest tools/art/tests"):
    echo "running pytest tools/art/tests"
    exec "uv run --locked --project tools/art pytest -q tools/art/tests"
  sweep "tests"
  # A game's own tests travel with it (`template/tests/`, task 1.9), so a
  # game `para new` creates gets covered by `para test` with no wiring of
  # its own: every games/<name>/tests/ and examples/<name>/tests/ directory
  # is swept the same way as the top-level tests/ above. A helper's lane (a `games/<game>.<id>/`
  # copy of a game) runs only when a plan names its files (`para test --filter games/<game>.<id>/`):
  # a bare run would test the game twice.
  for base in ["examples", "games"]:
    if not dirExists(base): continue
    for kind, gameDir in walkDir(base):
      if kind != pcDir: continue
      if planPath.len == 0 and '.' in gameDir.extractFilename: continue
      let testsDir = gameDir / "tests"
      if dirExists(testsDir): sweep testsDir
  # Building `para` itself is part of the test gate: it's the tool the game
  # style profile examples in this task are meant to be run through.
  if wanted("build tools/para/para.nim"):
    echo "running build tools/para/para.nim"
    exec "nim c --hints:off --outdir:tmp tools/para/para.nim"
  # A plan entry nothing above ran would be tests silently not run: fail instead.
  for id in plan:
    if id notin ran:
      raise newException(ValueError, "test plan entry not run: " & id)
  writeFile "tmp/tests-passed", ""

task webSmoke, "Build examples/hello for the web (wasm), postbuild, then smoke it headless (task 1.7 acceptance: wasm loads, ticks run, 0 console errors, frame saved to tmp/web-smoke/)":
  # Needs emcc + node 22+ on PATH -- local: `source $EMSDK/emsdk_env.sh`; CI: setup-emsdk + setup-node.
  # The emscripten '-s' settings go through EMCC_CFLAGS, output via -o, and the shell/theme
  # are rendered post-build; the nims only pins the wasm target.
  #
  # Like `test`, the task writes tmp/web-smoke-passed only after every step passed
  # (nimble 0.22.2 exits 0 even when a task fails), so check for it after running.
  rmFile "tmp/web-smoke-passed"
  rmDir "tmp/web/hello"
  exec "mkdir -p tmp/web/hello"
  # The nim selection (a nim whose config/nim.cfg carries the `@if emscripten`
  # wiring), the release mode and emcc flags live in tools/web/build.sh, shared
  # with `para build --target web` / `para web smoke` (task 1.8).
  exec "bash tools/web/build.sh examples/hello/hello.nim tmp/web/hello/hello"
  exec "node tools/web/postbuild.mjs --dir tmp/web/hello --title 'paraloop hello'"
  exec "node tools/web/smoke.mjs --dir tmp/web/hello --game hello --sound"
  writeFile "tmp/web-smoke-passed", ""
