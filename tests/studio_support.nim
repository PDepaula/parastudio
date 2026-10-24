# Shared by the `para studio` tests (tests/test_para_studio_*.nim): a raw HTTP request over a
# loopback socket (so a test controls every byte, the Host header included), a studio server
# started on an ephemeral port in a thread, and a scratch git repo with one game.
# Not a test file itself (no `test_` prefix).

import std/[net, nativesockets, os, strutils, tempfiles, tables]
import tools/para/nimutil
import tools/para/studiohttp
import tools/para/studioapi
import tools/para/agent
import tools/para/agents
import tools/para/studiochat
import tools/para/studioplay

type
  Reply* = object
    status*: int
    headers*: Table[string, string] ## names lowercased
    body*: string
    raw*: string

  Running* = object
    srv*: ptr HttpServer
    st*: ptr Studio
    thread*: ref Thread[ptr HttpServer]

proc serveMain(srv: ptr HttpServer) {.thread.} =
  serve(srv)

proc startServer*(handler: Handler, ctx: pointer): Running =
  result.srv = newHttpServer(handler, ctx)
  result.thread = new Thread[ptr HttpServer]
  createThread(result.thread[], serveMain, result.srv)

proc startStudio*(root, paraExe: string, defaultGame = "", adapter = defaultAdapter(),
                  turnSeconds = defaultTurnSeconds, planner: Planner = defaultPlan,
                  others: seq[AgentAdapter] = @[]): Running =
  result.st = newStudio(root, paraExe, defaultGame, adapter, turnSeconds, planner, others)
  result.srv = newHttpServer(studioHandler, result.st)
  result.thread = new Thread[ptr HttpServer]
  createThread(result.thread[], serveMain, result.srv)

proc stop*(r: Running) =
  if r.st != nil: shutdownStudio(r.st) # a chat turn still running is ended first
  requestStop(r.srv)
  joinThread(r.thread[])

proc parseReply*(raw: string): Reply =
  result.raw = raw
  let split = raw.find("\r\n\r\n")
  let head = if split >= 0: raw[0 ..< split] else: raw
  result.body = if split >= 0: raw[split + 4 .. ^1] else: ""
  let lines = head.split("\r\n")
  if lines.len > 0 and lines[0].startsWith("HTTP/1."):
    let parts = lines[0].split(' ')
    if parts.len >= 2 and parts[1].allCharsInSet(Digits): result.status = parseInt(parts[1])
  for i in 1 ..< lines.len:
    let c = lines[i].find(':')
    if c > 0: result.headers[lines[i][0 ..< c].toLowerAscii] = lines[i][c + 1 .. ^1].strip()

proc rawRequest*(port: int, bytes: string, readTimeoutMs = 5000): Reply =
  ## Sends exactly `bytes`, reads until the server closes the connection.
  let sock = newSocket()
  defer: sock.close()
  sock.connect("127.0.0.1", Port(port))
  if bytes.len > 0: sock.send(bytes)
  var raw = ""
  try:
    while true:
      let chunk = sock.recv(4096, timeout = readTimeoutMs)
      if chunk.len == 0: break
      raw.add chunk
  except TimeoutError, OSError:
    discard
  parseReply(raw)

proc request*(r: Running, meth, path: string, headers: seq[(string, string)] = @[], body = "",
              host = "", withToken = true, jsonBody = true): Reply =
  ## A well-formed request; the Host, token and JSON content type are filled in unless a test
  ## replaces them (`host`, `withToken = false`, an explicit header).
  let port = r.srv.port
  var lines = @[meth & " " & path & " HTTP/1.1"]
  var names: seq[string]
  for (k, _) in headers: names.add k.toLowerAscii
  lines.add "Host: " & (if host.len > 0: host else: "127.0.0.1:" & $port)
  if withToken and "x-studio-token" notin names: lines.add "X-Studio-Token: " & r.srv.token
  if meth == "POST":
    if jsonBody and "content-type" notin names: lines.add "Content-Type: application/json"
    lines.add "Content-Length: " & $body.len
  for (k, v) in headers: lines.add k & ": " & v
  rawRequest(port, lines.join("\r\n") & "\r\n\r\n" & body)

# --- a scratch repository with one game --------------------------------------------

proc gitOk*(root: string, args: varargs[string]): string =
  let r = runCaptured("git", @args, root)
  doAssert r.exitCode == 0, "git " & args.join(" ") & ": " & r.output
  r.output.strip

proc put*(root, rel, body: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, body)

proc newGameRepo*(games: varargs[string]): string =
  ## A friend's copy: branch `main`, `tmp/` ignored like the real repo, one save point per game, and
  ## `paraloop.nimble` so it looks like a paraloop folder.
  result = createTempDir("para_studio_", "")
  discard gitOk(result, "init", "-q")
  discard gitOk(result, "symbolic-ref", "HEAD", "refs/heads/main")
  discard gitOk(result, "config", "user.name", "Scratch")
  discard gitOk(result, "config", "user.email", "scratch@example.com")
  discard gitOk(result, "config", "commit.gpgsign", "false")
  result.put(".gitignore", "tmp/\n")
  result.put("paraloop.nimble", "version = \"0.1.0\"\n")
  for g in games:
    result.put("games/" & g & "/PLAN.md",
      "# " & g & "\nCall the friend: Sam\n\n## Now\n- [ ] make the ship move\n\n## Done\n- [x] a window\n")
    result.put("games/" & g & "/" & g & ".nim", "echo 1\n")
  discard gitOk(result, "add", ".")
  discard gitOk(result, "commit", "-q", "-m", "start")
  for g in games:
    discard gitOk(result, "tag", "-a", "save-" & g & "-1", "-m", "first save")
