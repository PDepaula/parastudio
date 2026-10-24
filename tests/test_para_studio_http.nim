# Tests for the HTTP side of `para studio` (tools/para/studiohttp.nim): a real server on an
# ephemeral loopback port with a trivial handler, hit with hand-written requests. What is pinned:
# 127.0.0.1 only, the per-run token, the Host and Origin checks, a path that cannot climb out,
# the size and time limits, and that nothing sends CORS headers. The routes behind it are
# test_para_studio_api.nim.

import std/[unittest, strutils, os, tables, sets, net]
import studio_support
import tools/para/studiohttp

proc echoHandler(ctx: pointer, req: Request): Response {.nimcall, gcsafe.} =
  Response(status: 200, contentType: "text/plain; charset=utf-8",
           body: req.meth & " " & req.path & " body=" & $req.body.len & "\n")

var running: Running

suite "para studio http: what the server is":
  setup: running = startServer(echoHandler, nil)
  teardown: running.stop()

  test "it listens on 127.0.0.1 and nowhere else":
    check listensOnLoopbackOnly(running.srv)
    check running.srv.port > 0
    check loopbackAddr == "127.0.0.1"

  test "the token is long, random and different every time":
    var seen = initHashSet[string]()
    for i in 0 ..< 50:
      let t = newToken()
      check t.len >= 32
      check t.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_'})
      seen.incl t
    check seen.len == 50
    check running.srv.token.len >= 32

  test "cleanPath accepts plain paths and refuses anything that could climb or hide":
    for good in ["/", "/api/state", "/a/b-c_d.e"]:
      check cleanPath(good) == good
    for bad in ["", "x", "/..", "/../etc/passwd", "/a/../b", "/a/./b", "/./", "//x", "/a//b", "/a/", "/%2e%2e/x",
                "/..%2fx", "/a\\b", "/a\0b", "/a b", "/a?b", "/é"]:
      check cleanPath(bad) == ""

suite "para studio http: the token":
  setup: running = startServer(echoHandler, nil)
  teardown: running.stop()

  test "the page needs ?token=; no token and a wrong token are both 403":
    let port = running.srv.port
    let hostLine = "Host: 127.0.0.1:" & $port & "\r\n\r\n"
    check rawRequest(port, "GET / HTTP/1.1\r\n" & hostLine).status == 403
    check rawRequest(port, "GET /?token=nope HTTP/1.1\r\n" & hostLine).status == 403
    check rawRequest(port, "GET /?token= HTTP/1.1\r\n" & hostLine).status == 403
    let ok = rawRequest(port, "GET /?token=" & running.srv.token & " HTTP/1.1\r\n" & hostLine)
    check ok.status == 200
    check ok.body.startsWith("GET /")

  test "the same refusal text for a missing and a wrong token (nothing to learn from it)":
    let port = running.srv.port
    let a = rawRequest(port, "GET /api/x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\n\r\n")
    let b = rawRequest(port, "GET /api/x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\nX-Studio-Token: wrong\r\n\r\n")
    check a.status == 403 and b.status == 403
    check a.body == b.body
    check running.srv.token notin a.body

  test "an API call takes the token in the header, not in the address":
    check running.request("GET", "/api/x").status == 200
    check running.request("GET", "/api/x", withToken = false).status == 403
    check running.request("GET", "/api/x?token=" & running.srv.token, withToken = false).status == 403
    check running.request("GET", "/api/x", @[("X-Studio-Token", "wrong")]).status == 403

  test "a token that is a prefix of the real one, or the real one plus more, is refused":
    let t = running.srv.token
    check running.request("GET", "/api/x", @[("X-Studio-Token", t[0 ..< t.len - 1])]).status == 403
    check running.request("GET", "/api/x", @[("X-Studio-Token", t & "x")]).status == 403

suite "para studio http: Host":
  setup: running = startServer(echoHandler, nil)
  teardown: running.stop()

  test "only 127.0.0.1:<port> and localhost:<port> are accepted":
    let port = running.srv.port
    check running.request("GET", "/api/x", host = "127.0.0.1:" & $port).status == 200
    check running.request("GET", "/api/x", host = "localhost:" & $port).status == 200
    check running.request("GET", "/api/x", host = "LocalHost:" & $port).status == 200
    for bad in ["evil.example", "evil.example:" & $port, "127.0.0.1", "127.0.0.1:" & $(port + 1), "localhost",
                "0.0.0.0:" & $port, "[::1]:" & $port, "127.0.0.1.evil.example:" & $port, "localhost.evil.example:" & $port,
                "127.0.0.1:" & $port & ".evil.example"]:
      check running.request("GET", "/api/x", host = bad).status == 403
      check running.request("GET", "/?token=" & running.srv.token, withToken = false, host = bad).status == 403

  test "a missing Host header is refused":
    check rawRequest(running.srv.port, "GET /api/x HTTP/1.1\r\nX-Studio-Token: " & running.srv.token & "\r\n\r\n").status == 403

  test "a Host sent twice is refused":
    let port = running.srv.port
    check rawRequest(port, "GET /api/x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\nHost: evil.example\r\nX-Studio-Token: " &
                     running.srv.token & "\r\n\r\n").status == 400

suite "para studio http: POST must come from the page":
  setup: running = startServer(echoHandler, nil)
  teardown: running.stop()

  test "a foreign Origin is refused, the page's own (either spelling) and none are accepted":
    let port = running.srv.port
    check running.request("POST", "/api/x", body = "{}").status == 200
    check running.request("POST", "/api/x", @[("Origin", "http://127.0.0.1:" & $port)], "{}").status == 200
    check running.request("POST", "/api/x", @[("Origin", "http://localhost:" & $port)], "{}").status == 200
    for bad in ["http://evil.example", "https://evil.example", "null", "http://127.0.0.1", "http://127.0.0.1:" & $(port + 1),
                "https://127.0.0.1:" & $port, "http://127.0.0.1:" & $port & ".evil.example", "http://evil.example:" & $port]:
      check running.request("POST", "/api/x", @[("Origin", bad)], "{}").status == 403

  test "a browser's own cross-site marker is refused":
    check running.request("POST", "/api/x", @[("Sec-Fetch-Site", "cross-site")], "{}").status == 403
    check running.request("POST", "/api/x", @[("Sec-Fetch-Site", "same-site")], "{}").status == 403
    check running.request("POST", "/api/x", @[("Sec-Fetch-Site", "same-origin")], "{}").status == 200

  test "a POST without the token is refused even from the right origin":
    let port = running.srv.port
    check running.request("POST", "/api/x", @[("Origin", "http://127.0.0.1:" & $port)], "{}", withToken = false).status == 403

  test "a POST that is not JSON is refused (so a browser has to ask first, and nobody answers)":
    check running.request("POST", "/api/x", @[("Content-Type", "text/plain")], "{}").status == 415
    check running.request("POST", "/api/x", @[("Content-Type", "application/x-www-form-urlencoded")], "a=1").status == 415
    check running.request("POST", "/api/x", @[("Content-Type", "application/json; charset=utf-8")], "{}").status == 200

  test "no CORS headers, ever; OPTIONS and the other methods are refused":
    let ok = running.request("GET", "/api/x")
    for k in ok.headers.keys: check not k.startsWith("access-control")
    for m in ["OPTIONS", "PUT", "DELETE", "PATCH", "HEAD", "TRACE"]:
      let r = running.request(m, "/api/x")
      check r.status == 405
      for k in r.headers.keys: check not k.startsWith("access-control")
    let pre = running.request("OPTIONS", "/api/x", @[("Origin", "http://evil.example"), ("Access-Control-Request-Method", "POST")])
    check pre.status == 405
    check "access-control-allow-origin" notin pre.headers

  test "every answer carries the plain safety headers":
    let r = running.request("GET", "/api/x")
    check r.headers["cache-control"] == "no-store"
    check r.headers["x-content-type-options"] == "nosniff"
    check r.headers["referrer-policy"] == "no-referrer"
    check r.headers["connection"] == "close"

suite "para studio http: a path cannot climb out":
  setup: running = startServer(echoHandler, nil)
  teardown: running.stop()

  test "`..`, encoded dots, doubled slashes and backslashes are 404, with the right token too":
    let port = running.srv.port
    for target in ["/../../etc/passwd", "/..", "/a/../../b", "/%2e%2e/%2e%2e/etc/passwd", "/..%2f..%2fetc/passwd",
                   "/%2E%2E/x", "//etc/passwd", "/a//b", "/a\\..\\b", "/./x", "/x/."]:
      let r = rawRequest(port, "GET " & target & " HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\nX-Studio-Token: " &
                         running.srv.token & "\r\n\r\n")
      check r.status == 404
      check "etc" notin r.body and "root:" notin r.body

  test "a bad path is a 404 before the token is even looked at":
    let port = running.srv.port
    check rawRequest(port, "GET /../x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\n\r\n").status == 404

suite "para studio http: size and time limits":
  setup: running = startServer(echoHandler, nil)
  teardown: running.stop()

  test "a body over the limit is refused from its Content-Length, before it is read":
    let port = running.srv.port
    let head = "POST /api/x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\nX-Studio-Token: " & running.srv.token &
               "\r\nContent-Type: application/json\r\nContent-Length: " & $(maxBodyBytes + 1) & "\r\n\r\n"
    check rawRequest(port, head).status == 413 # answered without sending the body at all
    let big = running.request("POST", "/api/x", body = "{\"x\":\"" & 'a'.repeat(maxBodyBytes) & "\"}")
    check big.status == 413

  test "a body at the limit is accepted":
    let r = running.request("POST", "/api/x", body = ' '.repeat(maxBodyBytes))
    check r.status == 200
    check ("body=" & $maxBodyBytes) in r.body

  test "a POST needs a Content-Length, and a chunked body is not accepted":
    let port = running.srv.port
    let pre = "POST /api/x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\nX-Studio-Token: " & running.srv.token &
              "\r\nContent-Type: application/json\r\n"
    check rawRequest(port, pre & "\r\n").status == 411
    check rawRequest(port, pre & "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n").status == 501
    check rawRequest(port, pre & "Content-Length: abc\r\n\r\n").status == 400
    check rawRequest(port, pre & "Content-Length: -1\r\n\r\n").status == 400
    check rawRequest(port, pre & "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}").status == 400

  test "a head over 16 KiB, or with too many headers, is refused":
    let port = running.srv.port
    let long = "GET /api/x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\nX-Pad: " & 'a'.repeat(maxHeadBytes) & "\r\n\r\n"
    check rawRequest(port, long).status == 431
    var many = "GET /api/x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\nX-Studio-Token: " & running.srv.token & "\r\n"
    for i in 0 ..< maxHeaderCount + 1: many.add "X-H" & $i & ": 1\r\n"
    check rawRequest(port, many & "\r\n").status == 431

  test "a request that is not HTTP is a 400":
    check rawRequest(running.srv.port, "hello\r\n\r\n").status == 400
    check rawRequest(running.srv.port, "GET / SPDY/9\r\n\r\n").status == 400

  test "a client that stops part way is answered 408 once the time is up, and the server still serves":
    let saved = requestSeconds
    requestSeconds = 1
    defer: requestSeconds = saved
    let port = running.srv.port
    let slow = rawRequest(port, "GET /api/x HTTP/1.1\r\nHost: 127.0.0.1:" & $port & "\r\n", readTimeoutMs = 4000)
    check slow.status == 408
    check running.request("GET", "/api/x").status == 200

  test "a client that connects and says nothing does not stop the others":
    let saved = requestSeconds
    requestSeconds = 1
    defer: requestSeconds = saved
    let port = running.srv.port
    var idle: seq[Socket]
    for i in 0 ..< 3:
      let s = newSocket()
      s.connect("127.0.0.1", Port(port))
      idle.add s
    check running.request("GET", "/api/x").status == 200
    for s in idle: s.close()
