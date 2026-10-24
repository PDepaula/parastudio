# `para studio`: a page in the friend's own browser with the producer's chat, a Play button that
# opens the game's own window (with screenshots in the chat), and the buttons a terminal has
# (Check, Save, the save points, the backup). Served by this same `para` binary on 127.0.0.1
# only: no Node, no Python, nothing to install, nothing leaves the computer.
#
# The server is studiohttp.nim, the routes and the jobs are studioapi.nim, the game window is
# studioplay.nim, the pictures are studioshot.nim, the page is studio/index.html (compiled into
# the binary). This file is the command: the flags, finding the
# repository, printing the link, opening the browser and waiting for Ctrl+C.
#
# Unlike every other command, `para studio` has to print before it returns (the link, while the
# server runs), so it writes through `StudioHooks.announce` as it goes and only returns once the
# server has stopped. Tests give it hooks of their own: no browser, no printing, and a `ready` hook
# to stop the server again.
#
# The studio never reads, keeps or forwards a login or a token of the friend's; the one secret it
# has is its own per-run key in the link, which is never written to a file.
#
# `para studio --check` starts no server: it prints the page's startup checks (preflight.nim) as
# plain lines and exits, so the double-click launchers can show them before they open the page.

import std/[os, strutils, sequtils]
import art/clihelpers
import savepoint
import producercmd
import studiohttp
import studioapi
import studiochat
import agent
import agents
import preflight
import browser
import boardcmd

type
  Run = clihelpers.Run

  StudioHooks* = object
    announce*: proc (line: string)
    openBrowser*: proc (url: string): bool ## true when a browser was started
    ready*: proc (srv: ptr HttpServer) ## called once the server is listening (tests stop it here)

const studioHelp* = "para studio [--game NAME] [--port N] [--no-open] [--turn-timeout MINUTES] [--check]\n" &
  "  opens a page in your browser with the producer's chat, Play (the game's own window) with screenshots in the chat, Check, Save, your save points and the backup, for the games in this folder\n" &
  "  the chat runs the claude or codex program you installed and signed in to yourself (the page lets you pick, per game); the studio never sees or keeps a login or key, and sends nothing until you send a message\n" &
  "  --game NAME  the game the page starts on; left out, the only game with a PLAN.md (the page asks when there are several)\n" &
  "  --port N     listen on this port (default: any free one, printed)\n" &
  "  --no-open    print the link and do not open the browser\n" &
  "  --turn-timeout MINUTES  stop a chat turn that runs longer than this (default 60; long builds are normal)\n" &
  "  --check      print the page's startup checks (claude or codex installed, signed in, folder trusted, edits allowed) with one fix line each, and the optional ones (Lavish, for visual boards), and exit without starting anything; exit 1 when no producer program is ready (an optional one never counts)\n" &
  "  it only listens on this computer (127.0.0.1); the link carries a key that changes every run\n" &
  "  Ctrl+C stops it, and closes the game window it opened. Check, Save and Backup run the same `para` commands a terminal would, with the same guards\n"

proc findRepoRoot*(start: string): string =
  ## The nearest directory at or above `start` that is a paraloop checkout (it has paraloop.nimble).
  var dir = start
  while dir.len > 0:
    if fileExists(dir / "paraloop.nimble"): return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent

proc checkLines(label: string, checks: seq[PreflightCheck]): seq[string] =
  result.add label & ": " & (if allOk(checks): "ready" else: "not ready yet")
  for c in checks:
    case c.state
    of csOk: result.add "  ok:  " & c.label
    of csFail: result.add "  no:  " & c.label & ". " & c.problem
    of csUnknown: result.add "  ?:   " & c.label & ". " & c.problem
    if c.state != csOk: result.add "       fix: " & c.fix

proc optionalLines(checks: seq[PreflightCheck]): seq[string] =
  ## Optional programs: listed, never counted, never a failure.
  if checks.len == 0: return
  result.add "Optional (Studio works without these):"
  for c in checks:
    if c.state == csOk: result.add "  ok:  " & c.label
    else:
      result.add "  --:  " & c.label & ". " & c.problem
      result.add "       " & c.fix

proc startupChecks*(root: string, adapters: seq[AgentAdapter], optional: seq[PreflightCheck] = @[]): Run =
  ## `para studio --check`: the checks `GET /api/preflight` runs, for every producer program that is
  ## installed (the page asks the one the game talks to; here no game is picked), or for the first
  ## of `adapters` when none is, so its "not installed" line and fix are shown. Read-only, like the
  ## page's: no model is asked anything. Exit 1 when no producer program is ready.
  var shown: seq[(AgentAdapter, seq[PreflightCheck])]
  for a in adapters:
    if a.preflight.isNil: continue
    let checks = a.preflight(a, root)
    if checks.anyIt(it.id == "installed" and it.state == csOk): shown.add (a, checks)
  if shown.len == 0 and adapters.len > 0 and not adapters[0].preflight.isNil:
    shown.add (adapters[0], adapters[0].preflight(adapters[0], root))
  var lines = @["Startup checks (the same ones the Studio page shows):"]
  var ready = false
  for (a, checks) in shown:
    lines.add checkLines(a.label, checks)
    if allOk(checks): ready = true
  lines.add optionalLines(optional)
  lines.add "These never stop Studio from opening; the page shows them too, with a Check button."
  (lines.join("\n") & "\n", if ready: 0 else: 1)

proc stdoutAnnounce(line: string) =
  stdout.write(line & "\n")
  stdout.flushFile()

proc runStudioWith*(args: seq[string], hooks: StudioHooks, root = "", paraExe = ""): Run =
  ## `root` and `paraExe` are for tests; left out they are the checkout around the working
  ## directory and this running binary.
  var requested = ""
  var port = 0
  var open = true
  var turnSeconds = defaultTurnSeconds
  var checkOnly = false
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (studioHelp, 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      requested = args[i]
    of "--port":
      inc i
      if i >= args.len or args[i].len notin 1..5 or not args[i].allCharsInSet(Digits) or parseInt(args[i]) > 65535:
        return errorOut("--port needs a number from 0 to 65535", @["0 (or leaving it out) picks any free port"])
      port = parseInt(args[i])
    of "--no-open":
      open = false
    of "--check":
      checkOnly = true
    of "--turn-timeout":
      inc i
      if i >= args.len or args[i].len notin 1..4 or not args[i].allCharsInSet(Digits) or parseInt(args[i]) notin 1..1440:
        return errorOut("--turn-timeout needs a number of minutes from 1 to 1440", @["The default is 60"])
      turnSeconds = parseInt(args[i]) * 60
    of "--host", "--bind", "--address", "--listen":
      return errorOut("para studio only listens on this computer (127.0.0.1); that cannot be changed", @["Valid flags: --game NAME, --port N, --no-open, --turn-timeout MINUTES, --check"])
    else:
      return errorOut("unknown flag \"" & a & "\"", @["Valid flags: --game NAME, --port N, --no-open, --turn-timeout MINUTES, --check"])
    inc i

  let repo = if root.len > 0: root else: findRepoRoot(getCurrentDir())
  if repo.len == 0:
    return errorOut("this is not a paraloop folder", @["Run `para studio` from inside the paraloop folder (the one with paraloop.nimble)"])
  if checkOnly:
    return startupChecks(repo, allAdapters(), @[boardCheck()])
  let plans = gamesWithPlan(repo)
  if requested.len > 0 and (not validGameName(requested) or requested notin plans):
    return errorOut("there is no game called \"" & cleanValue(requested) & "\" with a " & planFile & " in " & gamesDir & "/",
      if plans.len > 0: @["Games with a plan: " & plans.join(", ")] else: @[])

  let exe = if paraExe.len > 0: paraExe else: getAppFilename()
  let first = defaultAdapter()
  let others = allAdapters().filterIt(it.name != first.name)
  let st = newStudio(repo, exe, requested, first, turnSeconds, others = others)
  var srv: ptr HttpServer
  try:
    srv = newHttpServer(studioHandler, st, port)
  except OSError as e:
    return ("error: para studio could not start listening" & (if port > 0: " on port " & $port else: "") & ": " & e.msg & "\n" &
            (if port > 0: "help[1]:\n  Try another port, or leave --port out to use any free one\n" else: ""), 1)
  let url = "http://" & loopbackAddr & ":" & $srv.port & "/?token=" & srv.token
  hooks.announce("para studio is running (only on this computer).")
  hooks.announce(if plans.len == 0: "No game here has a PLAN.md yet; the page will say so." else: "Games: " & plans.join(", "))
  hooks.announce("Open this link in your browser:")
  hooks.announce("  " & url)
  hooks.announce("The link carries a key that changes every run. Press Ctrl+C here to stop.")
  if open:
    if hooks.openBrowser.isNil or not hooks.openBrowser(url):
      hooks.announce("I could not open your browser, so open the link above yourself.")
  if not hooks.ready.isNil: hooks.ready(srv)
  serve(srv)
  shutdownStudio(st)
  ("para studio stopped.\n", 0)

proc runStudio*(args: seq[string]): Run =
  installCtrlC()
  runStudioWith(args, StudioHooks(announce: stdoutAnnounce, openBrowser: openInBrowser))
