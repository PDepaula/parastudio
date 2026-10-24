# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Tests for `paraloop/devsock`: the control channel's listener and client
# sockets. The round trip runs on whichever route the platform uses (unix
# socket on POSIX, loopback TCP plus a port file on Windows); the port-file
# cases only exist where that route does, and `-d:devTcp` turns it on anywhere.
# No GL, no display.

import std/[unittest, os, net]
import paraloop/devsock

when tcpChannel:
  import std/strutils

const tmpDir = currentSourcePath().parentDir.parentDir / "tmp"

proc cleanPath(name: string): string =
  result = tmpDir / name
  createDir(tmpDir)
  removeFile(result)

suite "devsock: listener and client":
  test "a line round-trips from client to listener and back":
    let path = cleanPath("test-devsock-roundtrip.sock")
    let server = listenDev(path)
    defer:
      server.close()
      removeFile(path)
    let client = connectDev(path)
    defer: client.close()
    client.send("ping\n")
    var peer: Socket
    server.accept(peer)
    defer: peer.close()
    check peer.recvLine() == "ping"
    peer.send("ok pong\n")
    check client.recvLine() == "ok pong"

  test "connecting where nothing was bound raises OSError":
    let path = cleanPath("test-devsock-missing.sock")
    expect OSError:
      discard connectDev(path)

  test "connecting after the listener closed raises OSError":
    let path = cleanPath("test-devsock-closed.sock")
    let server = listenDev(path)
    server.close()
    defer: removeFile(path)
    expect OSError:
      discard connectDev(path)

when tcpChannel:
  suite "devsock: the TCP route's port file":
    test "the channel path holds the loopback port the listener got":
      let path = cleanPath("test-devsock-portfile.sock")
      let server = listenDev(path)
      defer:
        server.close()
        removeFile(path)
      check fileExists(path)
      let (_, port) = server.getLocalAddr()
      check readFile(path).strip == $int(port)

    test "a port file with no port in it raises OSError, not a parse error":
      let path = cleanPath("test-devsock-badport.sock")
      defer: removeFile(path)
      for contents in ["", "not a port\n", "0\n", "70000\n"]:
        writeFile(path, contents)
        expect OSError:
          discard connectDev(path)
