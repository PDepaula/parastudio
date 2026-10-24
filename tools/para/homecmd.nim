# The bare `para` view (engine report §5.3 rank 10, §4.2's "ambient context"):
# cheap, recorded status only -- no test run, no build -- so `para setup
# hooks`'s SessionStart hook (task 1.8) costs nothing per session. Every row
# is computed from this workspace: the games under examples/ and games/,
# each one's last recorded `para test`/`para shot --check`/`para web smoke`
# outcome (`games.readStatus`), and a short-timeout ping of the live socket.

import std/[os, net, strutils]
import art/[clihelpers, toon]
import devclient
import games
import paraloop/devsock

type Run = clihelpers.Run

const defaultSock = "tmp" / "dev.sock"

proc liveStatus(sockPath = defaultSock): string =
  if not socketExists(sockPath):
    return "none running"
  try:
    var client = connectDev(sockPath)
    defer: client.close()
    client.send("ping\n")
    let reply = client.recvLine(timeout = 200)
    if reply.startsWith("ok"): "running (" & sockPath & ")" else: "stale socket (" & sockPath & ")"
  except OSError, TimeoutError:
    "stale socket (" & sockPath & ")"

proc gameRows(): seq[seq[string]] =
  for g in listGames():
    result.add @[g.name, readStatus(g.name, "tests"), readStatus(g.name, "goldens"),
                 readStatus(g.name, "web")]

proc runHome*(): Run =
  result.output.add "bin: tmp/para\n"
  result.output.add "description: Build, test, see and drive paraloop games in this workspace\n"
  result.output.add toonTable("games", ["name", "tests", "goldens", "web"], gameRows())
  result.output.add "live: " & liveStatus() & "\n"
  result.output.add toonHelp(@[
    "Run `para test` after each change",
    "Run `para shot --check` to compare frames against the goldens",
    "Run `para web smoke` to check the wasm build"])
  result.code = 0
