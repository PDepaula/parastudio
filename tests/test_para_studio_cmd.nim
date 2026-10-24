# Tests for the `para studio` command itself (tools/para/studiocmd.nim): its flags, the link it
# prints, that --no-open opens nothing, that there is no way to listen anywhere but 127.0.0.1,
# and how it finds the repository. The server is stopped from the `ready` hook, so no browser
# starts and nothing keeps running. The HTTP rules are test_para_studio_http.nim and the routes
# test_para_studio_api.nim.

import std/[unittest, os, strutils, tempfiles, net]
import studio_support
import tools/para/para
import tools/para/studiocmd
import tools/para/studiohttp
import tools/para/usage

type Seen = object
  lines: seq[string]
  opened: seq[string]
  token: string
  port: int
  loopback: bool

var seen: Seen
var browserResult = true

proc onAnnounce(line: string) =
  seen.lines.add line

proc onOpen(url: string): bool =
  seen.opened.add url
  browserResult

proc onReady(srv: ptr HttpServer) =
  seen.token = srv.token
  seen.port = srv.port
  seen.loopback = listensOnLoopbackOnly(srv)
  requestStop(srv)

proc hooks(): StudioHooks =
  seen = Seen()
  StudioHooks(announce: onAnnounce, openBrowser: onOpen, ready: onReady)

var root: string

suite "para studio: flags":
  setup: root = newGameRepo("pong")
  teardown: removeDir(root)

  test "--help, and flags that go nowhere are exit 2 with the valid ones":
    let h = runStudioWith(@["--help"], hooks(), root)
    check h.code == 0
    check h.output.startsWith("para studio")
    check "127.0.0.1" in h.output
    for bad in [@["--bogus"], @["--port"], @["--port", "abc"], @["--port", "70000"], @["--port", "-1"], @["--game"], @["extra"],
                @["--turn-timeout"], @["--turn-timeout", "0"], @["--turn-timeout", "abc"], @["--turn-timeout", "1441"], @["--turn-timeout", "-5"]]:
      let r = runStudioWith(bad, hooks(), root)
      check r.code == 2
      check r.output.startsWith("error:")
    check "Valid flags" in runStudioWith(@["--bogus"], hooks(), root).output

  test "--turn-timeout is documented and takes minutes":
    let h = runStudioWith(@["--help"], hooks(), root)
    check "--turn-timeout MINUTES" in h.output and "default 60" in h.output
    check "never sees or keeps a login or key" in h.output
    check runStudioWith(@["--no-open", "--turn-timeout", "90"], hooks(), root).code == 0
    check seen.port > 0

  test "there is no way to choose another address: --host and friends are refused":
    for flag in ["--host", "--bind", "--address", "--listen"]:
      for value in ["0.0.0.0", "192.168.1.5", "::"]:
        let r = runStudioWith(@[flag, value], hooks(), root)
        check r.code == 2
        check "127.0.0.1" in r.output
        check seen.port == 0 # nothing started listening

  test "a game that is not there is refused before anything starts":
    let r = runStudioWith(@["--game", "nope"], hooks(), root)
    check r.code == 2
    check "Games with a plan: pong" in r.output
    check seen.port == 0
    check runStudioWith(@["--game", "../x"], hooks(), root).code == 2

  test "para dispatch knows `studio`, lists it and answers --help":
    check "studio" in paraCommands
    check dispatch(@["studio", "--help"]).output.startsWith("para studio")
    check dispatch(@["studio", "--host", "0.0.0.0"]).code == 2

suite "para studio: the link and the browser":
  setup: root = newGameRepo("pong")
  teardown: removeDir(root)

  test "it listens on 127.0.0.1, prints a link with this run's key, and stops when asked":
    let r = runStudioWith(@["--no-open"], hooks(), root)
    check r.code == 0
    check "stopped" in r.output
    check seen.loopback
    check seen.port > 0
    let link = "http://127.0.0.1:" & $seen.port & "/?token=" & seen.token
    check ("  " & link) in seen.lines
    check seen.token.len >= 32
    check "Games: pong" in seen.lines
    check "http://0.0.0.0" notin seen.lines.join("\n")

  test "two runs get different keys":
    discard runStudioWith(@["--no-open"], hooks(), root)
    let first = seen.token
    discard runStudioWith(@["--no-open"], hooks(), root)
    check seen.token != first

  test "--no-open opens nothing":
    discard runStudioWith(@["--no-open"], hooks(), root)
    check seen.opened.len == 0
    check not seen.lines.join("\n").contains("could not open")

  test "without --no-open the browser is asked once, with the same link":
    discard runStudioWith(@[], hooks(), root)
    check seen.opened == @["http://127.0.0.1:" & $seen.port & "/?token=" & seen.token]

  test "when no browser can be started the link is still printed, with a plain note":
    browserResult = false
    defer: browserResult = true
    let r = runStudioWith(@[], hooks(), root)
    check r.code == 0
    check "I could not open your browser, so open the link above yourself." in seen.lines
    check ("  http://127.0.0.1:" & $seen.port & "/?token=" & seen.token) in seen.lines

  test "--port picks that port; one that is taken is a plain error, not a crash":
    let probe = newSocket()
    probe.bindAddr(Port(0), "127.0.0.1")
    let free = int(probe.getLocalAddr()[1])
    probe.close()
    discard runStudioWith(@["--no-open", "--port", $free], hooks(), root)
    check seen.port == free
    let taken = newSocket()
    defer: taken.close()
    taken.bindAddr(Port(0), "127.0.0.1")
    taken.listen()
    let busy = int(taken.getLocalAddr()[1])
    let r = runStudioWith(@["--no-open", "--port", $busy], hooks(), root)
    check r.code == 1
    check ("could not start listening on port " & $busy) in r.output
    check seen.port == 0

  test "no game yet: it still starts and says so":
    let empty = createTempDir("para_studio_empty_", "")
    defer: removeDir(empty)
    empty.put("paraloop.nimble", "")
    discard runStudioWith(@["--no-open"], hooks(), empty)
    check seen.port > 0
    check "No game here has a PLAN.md yet; the page will say so." in seen.lines

suite "para studio: finding the repository":
  test "the nearest folder with paraloop.nimble at or above, else nothing":
    let top = createTempDir("para_studio_find_", "")
    defer: removeDir(top)
    top.put("paraloop.nimble", "")
    createDir(top / "games" / "pong")
    check findRepoRoot(top) == top
    check findRepoRoot(top / "games" / "pong") == top
    let outside = createTempDir("para_studio_out_", "")
    defer: removeDir(outside)
    check findRepoRoot(outside) == ""

  test "outside a paraloop folder it says so":
    let outside = createTempDir("para_studio_out2_", "")
    defer: removeDir(outside)
    let saved = getCurrentDir()
    setCurrentDir(outside)
    defer: setCurrentDir(saved)
    let r = runStudioWith(@["--no-open"], hooks())
    check r.code == 2
    check "not a paraloop folder" in r.output
