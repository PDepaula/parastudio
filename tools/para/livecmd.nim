# `para live`: talk to a running game's dev control channel (engine report
# §4.4: "the live window beside the agent"). `status` and `shot` get special
# handling (liveness ping, and the "wait for the named file" convention
# `paraloop/dev`'s module doc documents); anything else is forwarded verbatim
# as one request line, since the channel defines no command vocabulary of its
# own beyond `ok`/`error` framing -- a game wires its own (`paraloop/dev`'s
# module doc; `examples/hello` only understands `ping` and `shot` so far).

import std/[os, strutils]
import art/[clihelpers, toon]
import devclient

type Run = clihelpers.Run

const liveHelp = """para live <status|shot|...> [--sock PATH]
  status         -- ping the live session
  shot           -- request a screenshot, wait for it, print its path
  <anything else> is sent verbatim as one request line -- a game's own
    dev-command vocabulary (paraloop/dev's module doc)
"""

proc runLive*(args: seq[string]): Run =
  var sockPath = "tmp" / "dev.sock"
  var rest: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--sock":
      inc i
      if i >= args.len: return errorOut("--sock needs a path", @[])
      sockPath = args[i]
    elif a in ["--help", "-h"]:
      return (liveHelp, 0)
    elif a.startsWith("-"):
      return errorOut("unknown flag \"" & a & "\"", @["Valid flags: --sock PATH, --help"])
    else:
      rest.add a
    inc i

  if rest.len == 0:
    result.output = liveHelp
    result.code = 0
    return

  if not socketExists(sockPath):
    return errorOut("no live session at " & sockPath,
      @["Run `nim c -r -d:dev examples/hello/hello.nim` to start one, then retry `para live " &
        rest.join(" ") & "`"])

  let cmd = rest[0]
  let request = if cmd == "status": "ping" else: rest.join(" ")

  var reply: DevReply
  try:
    reply = sendDevRequest(sockPath, request)
  except IOError as e:
    return errorOut(e.msg, @[])

  case cmd
  of "shot":
    if not reply.ok:
      return errorOut("live session refused the shot request: " & reply.text, @[])
    let path = reply.text.strip
    if not waitForFile(path, 5000):
      return errorOut(path & " never appeared within 5000ms of the shot request", @[])
    result.output = toonTable("frames", ["name", "path"], @[@["shot", path]])
    result.code = 0
  of "status":
    result.output = "live: " & (if reply.ok: "up (" & reply.text & ")\n" else: "not responding (" & reply.text & ")\n")
    result.code = (if reply.ok: 0 else: 1)
  else:
    result.output = (if reply.ok: "ok " else: "error ") & reply.text & "\n"
    result.code = (if reply.ok: 0 else: 1)
