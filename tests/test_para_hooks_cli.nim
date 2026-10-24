# Tests for `para setup hooks` (task 1.8): it only prints a config snippet --
# never touches a config file itself.

import std/[unittest, strutils, json]
import tools/para/hookscmd

suite "runSetupHooks":
  test "prints a SessionStart hook snippet running the documented tmp/para build from the repo root":
    let r = runSetupHooks(@[])
    check r.code == 0
    check r.output.contains("SessionStart")
    let snippet = r.output[r.output.find("{\n") .. r.output.find("\n}\n") + 1]
    let hook = parseJson(snippet)["hooks"]["SessionStart"][0]["hooks"][0]
    check hook["type"].getStr == "command"
    check hook["command"].getStr == "cd \"$CLAUDE_PROJECT_DIR\" && tmp/para"
    check r.output.contains("never edits a config file")
    check r.output.contains(".claude/settings.json")

  test "extra arguments are a usage error, not silently ignored":
    let r = runSetupHooks(@["bogus"])
    check r.code == 2
    check r.output.startsWith("error:")
