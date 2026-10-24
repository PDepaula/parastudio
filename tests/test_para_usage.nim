# Tests for `para`'s top-level dispatch and help (task 1.8, AXI §6/§10): the
# root, every command and every command group answer `--help` with exit 0,
# unknown flags and commands are exit-2 errors that list the valid ones, and
# skills/para/SKILL.md (the installable skill, AXI §7) carries the current
# `para --help` text verbatim, so it cannot drift from the CLI.

import std/[unittest, os, strutils]
import tools/para/para
import tools/para/usage

const repoRoot = currentSourcePath().parentDir.parentDir

suite "para dispatch: help and errors":
  test "--help lists every command, the flags and examples, exit 0":
    let r = dispatch(@["--help"])
    check r.code == 0
    check r.output == paraHelp
    check r.output.contains("commands[17]{command,summary}:")
    check r.output.contains("examples[")
    for c in paraCommands:
      check r.output.contains("\n  " & c & " ") or r.output.contains("\n  " & c & ",")

  test "every command and command group answers --help with exit 0":
    for c in paraCommands:
      let r = dispatch(@[c, "--help"])
      check r.code == 0
      check r.output.startsWith("para " & c)
    check dispatch(@["web", "smoke", "--help"]).code == 0
    check dispatch(@["web", "pack", "--help"]).code == 0
    check dispatch(@["setup", "hooks", "--help"]).code == 0

  test "a bare command group prints its usage, exit 0":
    check dispatch(@["web"]) == dispatch(@["web", "--help"])
    check dispatch(@["setup"]).code == 0

  test "unknown flags and commands exit 2 and list the valid ones":
    let flag = dispatch(@["--bogus"])
    check flag.code == 2
    check flag.output.startsWith("error: unknown flag \"--bogus\"")
    check flag.output.contains("Valid flags: --help, --version")
    let cmd = dispatch(@["bogus"])
    check cmd.code == 2
    check cmd.output.contains("Valid commands: art, new, test, check, save, backup, build, sim, shot, driver, live, web, setup, producer-context, studio")
    let group = dispatch(@["web", "touch"])
    check group.code == 2
    check group.output.contains("Valid commands: web smoke, web pack")

  test "every command rejects an unknown flag with exit 2":
    for c in ["new", "test", "check", "save", "backup", "build", "sim", "shot", "driver", "live", "producer-context", "studio"]:
      check dispatch(@[c, "--axi-probe-unknown-flag"]).code == 2
    check dispatch(@["setup", "hooks", "--bogus"]).code == 2

suite "skills/para/SKILL.md":
  test "carries the current `para --help` text verbatim":
    let skill = readFile(repoRoot / "skills" / "para" / "SKILL.md")
    check skill.startsWith("---\nname: para\n")
    check ("```text\n" & paraHelp & "```\n") in skill
