# Tests for `para web smoke`'s output parsing (task 1.8): turning
# tools/web/smoke.mjs's own `ok`/`fail`/`pass` lines into a TOON checks table.
# `runWebSmoke` itself needs emcc/node/chrome, so only its up-front flag and
# `--game` validation (both rejected before anything is built) are exercised
# here; parseSmokeOutput covers the parsing against synthetic driver output.

import std/[unittest, strutils]
import tools/para/websmokecmd

suite "parseSmokeOutput":
  test "an all-pass run":
    let (rows, summary, allOk) = parseSmokeOutput("""
page  http://127.0.0.1:12345/hello.html
ok  wasm module loads
    Module._psKeyDown export present
ok  ticks run
    frame changed after 300 ms with ArrowRight held; ran 1500 ms
ok  frame saved
    tmp/web-smoke/hello.png (48213 bytes)
ok  0 console errors
    none
ok  0 page exceptions
    none
ok  0 WebGL warnings
    none (device emulated with 32 texture units)
pass  6/6 checks
""")
    check rows.len == 6
    check rows[5] == @["0 WebGL warnings", "ok", "none (device emulated with 32 texture units)"]
    check rows[0] == @["wasm module loads", "ok", "Module._psKeyDown export present"]
    check rows[1][0] == "ticks run"
    check summary == "pass  6/6 checks"
    check allOk

  test "a failing run distinguishes the last check from the summary line, both prefixed \"fail\"":
    let (rows, summary, allOk) = parseSmokeOutput("""
page  http://127.0.0.1:12345/hello.html
ok  wasm module loads
    Module._psKeyDown export present
fail  ticks run
    frame never changed within 15000 ms while ArrowRight was held
ok  frame saved
    tmp/web-smoke/hello.png (12 bytes)
ok  0 console errors
    none
fail  0 page exceptions
    TypeError: x is not a function | ReferenceError: y is not defined
fail  3 ok, 2 failed
""")
    check rows.len == 5
    check rows[1] == @["ticks run", "fail", "frame never changed within 15000 ms while ArrowRight was held"]
    check rows[4][1] == "fail"
    check summary == "fail  3 ok, 2 failed"
    check not allOk

  test "no parseable checks returns an empty row set":
    let (rows, summary, allOk) = parseSmokeOutput("some unrelated crash output\n")
    check rows.len == 0
    check summary == ""
    check not allOk

suite "runWebSmoke: flag validation (nothing built)":
  test "--help prints usage, exit 0":
    let r = runWebSmoke(@["--help"])
    check r.code == 0
    check r.output.startsWith("para web smoke")

  test "an unknown --game is a usage error listing the valid games":
    let r = runWebSmoke(@["--game", "nope"])
    check r.code == 2
    check r.output.startsWith("error: unknown game \"nope\"")
    # substring, not exact match: task 1.9's `para new` can leave other
    # games registered alongside hello (e.g. a CI run's games/ci_smoke)
    check r.output.contains("Valid games:")
    check r.output.contains("hello")

  test "an unknown flag is a usage error":
    let r = runWebSmoke(@["--bogus"])
    check r.code == 2

  test "a value-taking flag with no value is a usage error":
    check runWebSmoke(@["--game"]).code == 2
    check runWebSmoke(@["--ticks"]).code == 2
    check runWebSmoke(@["--max-texture-units"]).code == 2
    check runWebSmoke(@["--chrome"]).code == 2

  test "--sound is a flag, not a usage error: parsing goes on to the game lookup":
    let r = runWebSmoke(@["--sound", "--game", "nope"])
    check r.code == 2
    check r.output.startsWith("error: unknown game \"nope\"")

  test "--help documents --sound":
    check runWebSmoke(@["--help"]).output.contains("--sound")

  test "--click takes X,Y in whole pixels, and --help documents it":
    check runWebSmoke(@["--click"]).code == 2
    for bad in ["480", "480,", ",300", "480,300,1", "a,b", "-1,5", "480;300"]:
      let r = runWebSmoke(@["--click", bad])
      check r.code == 2
      check r.output.startsWith("error: bad --click")
    let ok = runWebSmoke(@["--click", "480,300", "--game", "nope"])
    check ok.output.startsWith("error: unknown game \"nope\"") # parsed, on to the game lookup
    check runWebSmoke(@["--help"]).output.contains("--click X,Y")
