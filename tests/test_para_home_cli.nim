# Tests for the bare `para` home view (task 1.8, engine report §4.2's
# "ambient context"): it must stay cheap -- recorded status only, no test
# run, no build -- since `para setup hooks` runs it at every SessionStart,
# and every row must be computed: per-game status as the last run recorded
# it (pass or fail), `never run` otherwise.

import std/[unittest, strutils, times, os]
import tools/para/homecmd
import tools/para/games

proc withStatusBackup(game: string, body: proc ()) =
  ## Runs `body`, then restores `tmp/status/<game>` to what it was, so this
  ## file never clobbers a real recorded status.
  let dir = "tmp" / "status" / game
  let backup = "tmp" / "status-backup-home-test" / game
  removeDir(backup)
  if dirExists(dir): copyDir(dir, backup)
  try:
    removeDir(dir)
    body()
  finally:
    removeDir(dir)
    if dirExists(backup): moveDir(backup, dir)

suite "runHome: always content-first, never a blank prompt":
  test "prints bin, description, a games table, live status and help":
    let r = runHome()
    check r.code == 0
    check r.output.startsWith("bin: tmp/para\n")
    check r.output.contains("description:")
    check r.output.contains("{name,tests,goldens,web}:")
    check r.output.contains("live:")
    check r.output.contains("help[")
    check not r.output.contains("patches")

  test "examples/hello is always listed (a definitive row, not an empty table)":
    let r = runHome()
    check r.output.contains("  hello,")

  test "a game with nothing recorded reads `never run`; a recorded failure reads as failed":
    withStatusBackup("hello", proc () =
      check runHome().output.contains("  hello,never run,never run,never run\n")
      recordStatus("hello", "tests", "58 passed, 1 failed")
      recordStatus("hello", "goldens", "1 changed")
      recordStatus("hello", "web", "smoke failed 2026-09-28")
      check runHome().output.contains(
        "  hello,\"58 passed, 1 failed\",1 changed,smoke failed 2026-09-28\n"))

  test "runs fast: no test run, no build, no live socket hang":
    let started = epochTime()
    discard runHome()
    check epochTime() - started < 2.0
