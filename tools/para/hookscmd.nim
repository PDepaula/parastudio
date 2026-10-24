# `para setup hooks`: prints a SessionStart hook config for Claude Code (and
# similar agent harnesses) that runs the bare `para` view at the start of
# every session (the "ambient context" hook). Prints only -- it never edits a
# user's config file itself.

import art/[clihelpers, toon]

type Run = clihelpers.Run

const setupHooksHelp* = "para setup hooks\n" &
  "  prints a SessionStart hook config that shows the bare `para` view; never edits a config file\n"

const hookSnippet = """{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "cd \"$CLAUDE_PROJECT_DIR\" && tmp/para" }
        ]
      }
    ]
  }
}
"""

proc runSetupHooks*(args: seq[string]): Run =
  if args.len == 1 and args[0] in ["--help", "-h"]:
    return (setupHooksHelp, 0)
  if args.len > 0:
    return errorOut("para setup hooks takes no arguments", @["Valid flags: --help"])
  result.output.add "para setup hooks: prints a SessionStart hook config; it never edits a config file itself.\n\n"
  result.output.add "Claude Code (and any agent harness with a SessionStart hook): add this to this\n"
  result.output.add "repo's .claude/settings.json (it runs this checkout's tmp/para from the repo root):\n\n"
  result.output.add hookSnippet
  result.output.add "\nOther agents: run `tmp/para` (the bare view) from the repo root the same way at session start.\n"
  result.output.add toonHelp(@[
    "Run `para` to preview the home view this hook prints",
    "Run `nim c --hints:off --outdir:tmp tools/para/para.nim` (or `nimble test`) first if tmp/para does not exist yet"])
  result.code = 0
