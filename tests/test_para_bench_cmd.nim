# Tests for `para bench` (tools/para/benchcmd.nim): help and usage errors
# (exit 2), the pure pieces (result-line parsing, the least-squares fit, the
# budget check), and one real run of each subcommand at a tiny size to pin
# its output shape and exit code. Nothing here asserts on a measured time:
# the bench measures, the tests only check that it ran and what it printed.

import std/[unittest, strutils, tables, math]
import tools/para/benchcmd
import paraloop/prof

suite "para bench: help and usage errors":
  test "bare and --help print the usage, exit 0":
    for args in [newSeq[string](), @["--help"], @["rules", "--help"], @["sprites", "-h"], @["build", "--help"]]:
      let r = runBench(args)
      check r.code == 0
      check r.output.startsWith("para bench <rules|sprites|build>")

  test "an unknown subcommand or flag is exit 2 naming the valid ones":
    let sub = runBench(@["frames"])
    check sub.code == 2
    check sub.output.startsWith("error: unknown command \"bench frames\"")
    check sub.output.contains("Valid commands: bench rules, bench sprites, bench build")
    check runBench(@["--bogus"]).code == 2
    for s in ["rules", "sprites", "build"]:
      let r = runBench(@[s, "--bogus"])
      check r.code == 2
      check r.output.contains("Valid flags:")

  test "bad values are exit 2 before anything is built":
    for args in [@["rules", "--n", "abc"], @["rules", "--n", "0"], @["rules", "--n", "100,"],
                 @["rules", "--rules", "4"], @["rules", "--rules", "0"], @["rules", "--ticks", "0"],
                 @["rules", "--repeat", "0"], @["rules", "--warmup", "-1"], @["rules", "--budget-ms", "0"],
                 @["rules", "--budget-ms", "x"], @["rules", "--n"],
                 @["sprites", "--calls", "20", "--n", "10"], @["sprites", "--frames", "0"],
                 @["sprites", "--budget-ms", "-3"], @["build", "--game"], @["build", "--game", "no-such-game"]]:
      let r = runBench(args)
      check r.code == 2
      check r.output.startsWith("error: ")

suite "para bench: the pure pieces":
  test "parseResult reads a result line's key=value fields":
    let t = parseResult("noise\nresult entities=300 rules=3 p99_ms=2.5 rss_mb=n/a\nmore\n")
    check t["entities"] == "300"
    check t["p99_ms"] == "2.5"
    check t["rss_mb"] == "n/a"
    check parseResult("no result here\n").len == 0

  test "leastSquares fits a line, and needs two distinct counts":
    let f = leastSquares(@[100.0, 200.0, 300.0], @[1.5, 2.5, 3.5])
    check abs(f.slope - 0.01) < 1e-12
    check abs(f.intercept - 0.5) < 1e-9
    check leastSquares(@[100.0], @[1.0]).slope.isNaN
    check leastSquares(@[100.0, 100.0], @[1.0, 2.0]).slope.isNaN

  test "overBudget picks the rows whose p99 is over the budget, optionally one variant":
    let rows = @[@["100", "3", "rules", "0.5", "0.9"], @["300", "3", "rules", "2.0", "4.2"],
                 @["300", "3", "systems", "1.0", "5.0"], @["1000", "3", "rules", "n/a", "n/a"]]
    check overBudget(rows, 4, 4.0, "rules") == @[1]
    check overBudget(rows, 4, 4.0) == @[1, 2]
    check overBudget(rows, 4, 10.0).len == 0

  test "without -d:prof the seams are off and count nothing":
    check not profEnabled
    check rulesNanos() == 0

suite "para bench: real runs at a tiny size":
  test "rules prints the machine, one row per count and variant, the fit, exit 0":
    let r = runBench(@["rules", "--n", "5,10", "--rules", "2", "--ticks", "3", "--warmup", "1", "--repeat", "1"])
    check r.code == 0
    check r.output.startsWith("bench: rules, release build, 3 ticks after 1 warm-up, median of 1 run")
    check r.output.contains("\nmachine: cpu ")
    check r.output.contains("results[6]{entities,rules,variant,p50_ms,p99_ms,p99_tick_pct,setup_ms,rss_mb,heap_mb}:\n")
    for row in ["  5,2,rules,", "  5,2,systems,", "  5,2,plain,", "  10,2,rules,", "  10,2,systems,", "  10,2,plain,"]:
      check row in r.output
    check r.output.contains("\nfit: rules variant per entity under 2 rules (least squares over 2 counts): p50 ")
    check not r.output.contains("gate:")

  test "sprites prints the renderer and one row per count and call split, or says there is no display":
    let r = runBench(@["sprites", "--n", "10", "--calls", "1,2", "--frames", "2", "--warmup", "0", "--repeat", "1"])
    if r.code == 0:
      check r.output.startsWith("bench: sprites, release build, 1280x720 hidden window")
      check r.output.contains("\ngpu: renderer ")
      check r.output.contains("results[2]{sprites,calls,add_ms,submit_ms,gpu_ms,wait_ms,p50_ms,p99_ms,rss_mb}:\n")
      check "  10,1," in r.output
      check "  10,2," in r.output
    else:
      check r.code == 1
      check r.output.startsWith("error: no display")

  test "build times hello's forced and unchanged debug builds and reports their bytes":
    let r = runBench(@["build", "--game", "hello", "--skip-release"])
    check r.code == 0
    check r.output.startsWith("bench: build, hello (")
    check r.output.contains("builds[2]{build,seconds,bytes}:\n")
    check r.output.contains("\n  debug forced,")
    check r.output.contains("\n  debug unchanged rebuild,")
