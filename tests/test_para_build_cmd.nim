# Tests for `para build` (task 1.8): Nim's `file(line, col) Severity:
# message` diagnostic parsing (nimutil, shared with `para test`'s fallback
# tail and `para web smoke`'s build step), `runBuild`'s flag validation, and
# one real native build of examples/hello -- fast (~1-2s) and never mutates
# the example, so it's safe to run for real here (unlike `para test`, which
# would recurse into `nimble test`).

import std/[unittest, os, strutils]
import tools/para/nimutil
import tools/para/buildcmd

suite "parseNimDiagnostics":
  test "an Error line becomes one diagnostic with file:line":
    let diags = parseNimDiagnostics(
      "src/rules.nim(318, 10) Error: type mismatch: got 'int' but expected 'Hp'\n")
    check diags.len == 1
    check diags[0].at == "src/rules.nim:318"
    check diags[0].msg == "type mismatch: got 'int' but expected 'Hp'"
    check diags[0].severity == "Error"

  test "Hint lines are dropped, Warning lines are kept":
    let diags = parseNimDiagnostics("""
src/foo.nim(1, 1) Hint: 'x' is declared but not used [XDeclaredButNotUsed]
src/foo.nim(2, 3) Warning: BareExcept is deprecated [BareExcept]
""")
    check diags.len == 1
    check diags[0].severity == "Warning"

  test "a line with no (line, col) shape is skipped, not a crash":
    let diags = parseNimDiagnostics("Error: cannot open file: bogus\n")
    check diags.len == 0

  test "runCaptured reports a command it cannot start as exit 127, not an exception":
    let r = runCaptured("para-no-such-tool", @["--version"])
    check r.exitCode == 127
    check r.output.startsWith("cannot run para-no-such-tool:")

  test "runStreamed hands each line over in order as it is printed and still returns the whole output":
    var seen: seq[string]
    let r = runStreamed("sh", @["-c", "echo one; echo two >&2; printf three"],
                        proc (line: string) = seen.add line)
    check r.exitCode == 0
    check seen == @["one", "two", "three"]
    check r.output == "one\ntwo\nthree\n"

  test "runStreamed reports a command it cannot start as exit 127, calling back nothing":
    var calls = 0
    let r = runStreamed("para-no-such-tool", @["--version"], proc (line: string) = inc calls)
    check r.exitCode == 127
    check calls == 0

  test "no diagnostics in clean output":
    check parseNimDiagnostics("Hint: operation successful\n").len == 0

suite "runBuild: flag validation and a real native build":
  test "--help prints usage, exit 0":
    let r = runBuild(@["--help"])
    check r.code == 0
    check r.output.startsWith("para build")

  test "an unknown target is a usage error, exit 2":
    let r = runBuild(@["--target", "bogus"])
    check r.code == 2
    check r.output.startsWith("error:")
    check r.output.contains("native")
    check r.output.contains("web")

  test "an unknown --game is a usage error listing the valid games":
    let r = runBuild(@["--game", "nope"])
    check r.code == 2
    check r.output.startsWith("error: unknown game \"nope\"")
    # substring, not exact match: task 1.9's `para new` can leave other
    # games registered alongside hello (e.g. a CI run's games/ci_smoke)
    check r.output.contains("Valid games:")
    check r.output.contains("hello")

  test "--release and --debug together is a usage error, not a silent pick":
    let r = runBuild(@["--target", "web", "--release", "--debug"])
    check r.code == 2
    check r.output.startsWith("error:")
    check r.output.contains("--debug")

  test "an unknown flag is a usage error":
    let r = runBuild(@["--bogus"])
    check r.code == 2

  test "building examples/hello natively succeeds and reports the output path":
    let r = runBuild(@[])
    check r.code == 0
    check r.output.contains("build: ok, wrote " & ("tmp" / "hello"))
    check fileExists("tmp" / "hello")
