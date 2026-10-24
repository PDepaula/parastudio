# The HTTP side of `para studio`: a small server on the standard library's sockets, and nothing
# else (no Node, no Python, no nimble dependency), so it runs the same on Windows, macOS and Linux.
#
# What it guarantees, whatever the page or the routes behind it do:
#
# - it listens on 127.0.0.1 only: the address is the constant `loopbackAddr`, there is no host
#   setting to change it, and `listensOnLoopbackOnly` is what the tests (and `newHttpServer`)
#   check on the real socket;
# - every request must carry this run's random token (`X-Studio-Token`; the page itself, `GET /`,
#   takes it as `?token=` because a link cannot send headers), and a wrong one is a 403 with the
#   same text as a missing one;
# - the Host header must be exactly 127.0.0.1:<port> or localhost:<port> (this is what stops a web
#   page on another site reaching the server through DNS rebinding);
# - a request that is not a GET must say it comes from this page: an Origin that is anything other
#   than http://127.0.0.1:<port> or http://localhost:<port> is refused, a browser's own
#   `Sec-Fetch-Site` of cross-site/same-site is refused, and the body has to be JSON (which makes a
#   browser ask first, and the server never answers that question: no CORS headers, no OPTIONS);
# - the path is checked before anything else looks at it: only [A-Za-z0-9_./-], no `.` or `..`
#   segment, no empty one, so nothing can climb out of what a route serves;
# - the head is at most 16 KiB and 64 headers, the body at most 32 KiB and only with a
#   Content-Length (chunked bodies are refused), and a whole request has to arrive within 15 s;
# - one request per connection (`Connection: close`), a fixed handful of worker threads and a short
#   queue, so a slow or greedy client cannot make the process grow;
# - it writes no log: not a request, not a header, not the token.
#
# The token comes from the operating system's random source (`std/sysrand`), never from a clock.
#
# The routes live in studioapi.nim; this file only calls the `Handler` it is given, with a
# `Request` that already passed every check above.

import std/[net, nativesockets, locks, deques, atomics, monotimes, times, strutils, uri, sysrand, base64]
when defined(windows):
  from std/winlean import shutdown
else:
  from std/posix import shutdown

const
  loopbackAddr* = "127.0.0.1"
  maxHeadBytes* = 16 * 1024
  maxHeaderCount* = 64
  maxBodyBytes* = 32 * 1024
  workerCount = 6
  maxQueued = 32 ## connections waiting for a worker; more are closed at once
  tokenHeader* = "x-studio-token"

type
  Request* = object
    meth*, path*: string
    query*: seq[(string, string)]
    headers*: seq[(string, string)] ## names lowercased
    body*: string

  Response* = object
    status*: int
    contentType*: string
    body*: string
    headers*: seq[(string, string)] ## extra headers, on top of the security ones

  Handler* = proc (ctx: pointer, req: Request): Response {.nimcall, gcsafe.}

  HttpServer* = object
    token: string
    port: int
    listener: SocketHandle
    handler: Handler
    ctx: pointer
    lock: Lock
    cond: Cond
    queue: Deque[SocketHandle]
    stopping: Atomic[bool]
    workers: array[workerCount, Thread[ptr HttpServer]]

var requestSeconds* = 15 ## the whole request (head and body) has to arrive within this (a var so a test can shorten it)
var ctrlCPressed: Atomic[bool]

proc onCtrlC() {.noconv.} =
  ctrlCPressed.store(true)

proc installCtrlC*() =
  ## Ctrl+C asks every running server to stop (the serve loop looks within a fifth of a second).
  ## Not installed by the tests.
  setControlCHook(onCtrlC)

proc newToken*(): string =
  ## 192 bits from the operating system, URL-safe. Raises when the system has no random source:
  ## the studio never falls back to something guessable.
  var raw = newSeq[byte](24)
  if not urandom(raw):
    raise newException(OSError, "the system has no secure random source, so I won't start a studio without a token")
  result = encode(raw, safe = true).strip(leading = false, chars = {'='})

proc port*(srv: ptr HttpServer): int = srv.port
proc token*(srv: ptr HttpServer): string = srv.token

proc listensOnLoopbackOnly*(srv: ptr HttpServer): bool =
  ## True when the real listening socket is bound to 127.0.0.1 (asked of the operating system).
  let (address, _) = getLocalAddr(srv.listener, AF_INET)
  address == loopbackAddr

# --- checks that need no socket -------------------------------------------------

proc cleanPath*(target: string): string =
  ## The path part of a request target when it is safe to route on, else "". Only `/`, letters,
  ## digits, `_`, `-` and `.` are accepted, and no segment may be empty, `.` or `..`: a percent
  ## sign, a backslash, a NUL or a doubled slash is refused outright, never decoded.
  if target.len == 0 or target[0] != '/': return ""
  if target == "/": return "/"
  for c in target:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '/'}: return ""
  for seg in target[1 .. ^1].split('/'):
    if seg.len == 0 or seg == "." or seg == "..": return ""
  target

proc header*(req: Request, name: string): string =
  for (k, v) in req.headers:
    if k == name: return v

proc queryValue*(req: Request, name: string): string =
  for (k, v) in req.query:
    if k == name: return v

proc sameText(a, b: string): bool =
  ## Constant-time comparison, so a token cannot be guessed a letter at a time.
  var diff = a.len xor b.len
  for i in 0 ..< min(a.len, b.len):
    diff = diff or (ord(a[i]) xor ord(b[i]))
  diff == 0

proc allowedHost*(host: string, port: int): bool =
  host == loopbackAddr & ":" & $port or host.toLowerAscii == "localhost:" & $port

proc allowedOrigin*(origin: string, port: int): bool =
  origin == "http://" & loopbackAddr & ":" & $port or origin.toLowerAscii == "http://localhost:" & $port

proc textResponse(status: int, text: string): Response =
  Response(status: status, contentType: "text/plain; charset=utf-8", body: text & "\n")

proc statusLine(status: int): string =
  case status
  of 200: "200 OK"
  of 204: "204 No Content"
  of 400: "400 Bad Request"
  of 403: "403 Forbidden"
  of 404: "404 Not Found"
  of 405: "405 Method Not Allowed"
  of 408: "408 Request Timeout"
  of 409: "409 Conflict"
  of 411: "411 Length Required"
  of 413: "413 Content Too Large"
  of 415: "415 Unsupported Media Type"
  of 431: "431 Request Header Fields Too Large"
  of 501: "501 Not Implemented"
  of 503: "503 Service Unavailable"
  else: $status & " Status"

proc checkRequest*(req: Request, port: int, token: string): Response =
  ## Status 0 when the request may go on to a route, else the refusal. The order matters: where
  ## the request came from and what it asks for are judged before anything is looked up.
  if req.meth notin ["GET", "POST"]:
    return textResponse(405, "Only GET and POST are used here.")
  if not allowedHost(req.header("host"), port):
    return textResponse(403, "Forbidden: this is not the address para studio printed.")
  if cleanPath(req.path).len == 0:
    return textResponse(404, "Not found.")
  let isPage = req.meth == "GET" and req.path == "/"
  let given = if isPage: req.queryValue("token") else: req.header(tokenHeader)
  if given.len == 0 or not sameText(given, token):
    return textResponse(403, "Forbidden: open the link para studio printed (it carries a key that changes every run).")
  if req.meth == "POST":
    let origin = req.header("origin")
    if origin.len > 0 and not allowedOrigin(origin, port):
      return textResponse(403, "Forbidden: this request did not come from the studio page.")
    let site = req.header("sec-fetch-site").toLowerAscii
    if site.len > 0 and site notin ["same-origin", "none"]:
      return textResponse(403, "Forbidden: this request did not come from the studio page.")
    if not req.header("content-type").toLowerAscii.startsWith("application/json"):
      return textResponse(415, "The studio sends JSON.")
  Response()

# --- reading a request ----------------------------------------------------------

type
  Refusal = object of CatchableError
    status: int

proc refuse(status: int, text: string) {.noreturn.} =
  var e = newException(Refusal, text)
  e.status = status
  raise e

proc fill(sock: Socket, buf: var string, deadline: MonoTime) =
  ## Appends what arrives next (up to 4 KiB). Raises a 408 refusal once the deadline passes and a
  ## plain Refusal(400) when the client closed the connection part way.
  let left = (deadline - getMonoTime()).inMilliseconds
  if left <= 0: refuse(408, "The request took too long to arrive.")
  var fds = @[sock.getFd]
  if selectRead(fds, int(left)) <= 0: refuse(408, "The request took too long to arrive.")
  var chunk: array[4096, char]
  let n = sock.recv(addr chunk[0], chunk.len)
  if n <= 0: refuse(400, "The connection closed before the request was complete.")
  let at = buf.len
  buf.setLen(at + n)
  copyMem(addr buf[at], addr chunk[0], n)

proc parseHead(head: string): Request =
  let lines = head.split("\r\n")
  let first = lines[0].split(' ')
  if first.len != 3 or not first[2].startsWith("HTTP/1."):
    refuse(400, "That is not an HTTP request.")
  result.meth = first[0]
  let target = first[1]
  let qm = target.find('?')
  result.path = if qm < 0: target else: target[0 ..< qm]
  if qm >= 0:
    for (k, v) in decodeQuery(target[qm + 1 .. ^1]):
      result.query.add (k, v)
  var seen = 0
  for i in 1 ..< lines.len:
    let line = lines[i]
    if line.len == 0: continue
    inc seen
    if seen > maxHeaderCount: refuse(431, "Too many headers.")
    let colon = line.find(':')
    if colon <= 0: refuse(400, "A header line is malformed.")
    let name = line[0 ..< colon].toLowerAscii
    if name.len == 0 or ' ' in name or '\t' in name: refuse(400, "A header line is malformed.")
    let value = line[colon + 1 .. ^1].strip()
    if name in ["host", "content-length", "origin", tokenHeader] and result.header(name).len > 0:
      refuse(400, "A header was sent twice.")
    result.headers.add (name, value)

proc readHead(sock: Socket, deadline: MonoTime): tuple[req: Request, rest: string] =
  var buf = ""
  var end0 = -1
  while true:
    end0 = buf.find("\r\n\r\n")
    if end0 >= 0: break
    if buf.len > maxHeadBytes: refuse(431, "The request head is too large.")
    fill(sock, buf, deadline)
  if end0 > maxHeadBytes: refuse(431, "The request head is too large.")
  result.req = parseHead(buf[0 ..< end0])
  result.rest = buf[end0 + 4 .. ^1]

proc readBody(sock: Socket, req: Request, rest: string, deadline: MonoTime): string =
  if req.header("transfer-encoding").len > 0:
    refuse(501, "Chunked bodies are not accepted.")
  let lenText = req.header("content-length")
  if lenText.len == 0:
    if req.meth == "POST": refuse(411, "A POST needs a Content-Length.")
    return ""
  if lenText.len > 9 or not lenText.allCharsInSet({'0'..'9'}):
    refuse(400, "Content-Length is not a number.")
  let want = parseInt(lenText)
  if want > maxBodyBytes: refuse(413, "That body is too large.")
  result = rest
  while result.len < want:
    fill(sock, result, deadline)
  if result.len > want: result.setLen(want)

# --- writing a response ---------------------------------------------------------

proc send(sock: Socket, res: Response) =
  var head = "HTTP/1.1 " & statusLine(res.status) & "\r\n"
  head.add "Content-Type: " & (if res.contentType.len > 0: res.contentType else: "text/plain; charset=utf-8") & "\r\n"
  head.add "Content-Length: " & $res.body.len & "\r\n"
  head.add "Cache-Control: no-store\r\n"
  head.add "X-Content-Type-Options: nosniff\r\n"
  head.add "Referrer-Policy: no-referrer\r\n"
  head.add "Cross-Origin-Resource-Policy: same-origin\r\n"
  head.add "Connection: close\r\n"
  for (k, v) in res.headers:
    head.add k & ": " & v & "\r\n"
  head.add "\r\n"
  try:
    sock.send(head & res.body)
  except OSError, TimeoutError:
    discard # the client went away; nothing more to tell it

proc closeGracefully(sock: Socket) =
  ## Says "that is all" and reads away what the client is still sending (a body that was refused
  ## unread) for a moment, so closing does not reset the connection before the client has read the
  ## answer. 1 is SHUT_WR on POSIX and SD_SEND on Windows.
  discard shutdown(sock.getFd, 1)
  var sink: array[1024, char]
  let until = getMonoTime() + initDuration(milliseconds = 300)
  var total = 0
  while total < 256 * 1024:
    let left = (until - getMonoTime()).inMilliseconds
    if left <= 0: break
    var fds = @[sock.getFd]
    if selectRead(fds, int(left)) <= 0: break
    let n = sock.recv(addr sink[0], sink.len)
    if n <= 0: break
    total += n

proc serveConnection(srv: ptr HttpServer, fd: SocketHandle) =
  let sock = newSocket(fd, buffered = false)
  defer:
    try:
      closeGracefully(sock)
      sock.close()
    except OSError: discard
  let deadline = getMonoTime() + initDuration(seconds = requestSeconds)
  try:
    var (req, rest) = readHead(sock, deadline)
    let verdict = checkRequest(req, srv.port, srv.token)
    if verdict.status != 0:
      sock.send(verdict)
      return
    if req.meth == "POST": req.body = readBody(sock, req, rest, deadline)
    var res: Response
    try:
      res = srv.handler(srv.ctx, req)
    except CatchableError:
      res = textResponse(500, "Something went wrong inside the studio.")
    sock.send(res)
  except Refusal as e:
    sock.send(textResponse(e.status, e.msg))
  except OSError, TimeoutError:
    discard

# --- the server -----------------------------------------------------------------

proc worker(srv: ptr HttpServer) {.thread.} =
  while true:
    var fd: SocketHandle
    acquire(srv.lock)
    while srv.queue.len == 0 and not srv.stopping.load:
      wait(srv.cond, srv.lock)
    if srv.queue.len == 0:
      release(srv.lock)
      return
    fd = srv.queue.popFirst
    release(srv.lock)
    serveConnection(srv, fd)

proc newHttpServer*(handler: Handler, ctx: pointer, port = 0, token = newToken()): ptr HttpServer =
  ## Binds 127.0.0.1:`port` (0 = any free port) and starts listening; raises OSError (with the
  ## system's words) when that is not possible. `serve` runs it.
  let sock = newSocket(inheritable = false)
  try:
    # on Windows SO_REUSEADDR lets another program share the port, so it is not set there
    when not defined(windows): sock.setSockOpt(OptReuseAddr, true)
    sock.bindAddr(Port(port), loopbackAddr)
    sock.listen()
  except OSError:
    sock.close()
    raise
  result = create(HttpServer)
  result.token = token
  result.handler = handler
  result.ctx = ctx
  result.listener = sock.getFd
  result.port = int(sock.getLocalAddr()[1])
  initLock(result.lock)
  initCond(result.cond)
  result.queue = initDeque[SocketHandle]()
  result.stopping.store(false)
  doAssert listensOnLoopbackOnly(result), "the studio listener is not on 127.0.0.1"

proc requestStop*(srv: ptr HttpServer) =
  srv.stopping.store(true)
  acquire(srv.lock)
  broadcast(srv.cond)
  release(srv.lock)

proc serve*(srv: ptr HttpServer) =
  ## Runs until `requestStop` (or Ctrl+C when `installCtrlC` was called), then closes the listener
  ## and waits for the workers.
  for i in 0 ..< workerCount:
    createThread(srv.workers[i], worker, srv)
  while not srv.stopping.load and not ctrlCPressed.load:
    var fds = @[srv.listener]
    if selectRead(fds, 200) <= 0: continue
    let (client, _) = accept(srv.listener)
    if client == osInvalidSocket: continue
    acquire(srv.lock)
    let full = srv.queue.len >= maxQueued
    if not full: srv.queue.addLast client
    release(srv.lock)
    if full: close(client) else: signal(srv.cond)
  requestStop(srv)
  close(srv.listener)
  for i in 0 ..< workerCount: joinThread(srv.workers[i])
  # connections that were still waiting for a worker
  while srv.queue.len > 0: close(srv.queue.popFirst)
