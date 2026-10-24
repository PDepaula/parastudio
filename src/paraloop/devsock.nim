# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
## paraloop/devsock: the socket `paraloop/dev`'s control channel listens on and
## `para live` (`tools/para/devclient.nim`, `homecmd.nim`) connects to.
##
## POSIX: a unix socket at the channel path, exactly as before.
##
## Windows: `std/net` has no `bindUnix`/`connectUnix` there, so the channel is
## a loopback TCP listener (127.0.0.1, an OS-picked port) and the channel path
## is a small regular file holding that port number. The path stays the one
## rendezvous point both sides already use: `socketExists`, the stale-file
## cleanup in `newDevServer`/`close` and `para live --sock PATH` need no
## change, and a dead listener leaves a file whose port refuses the
## connection, which reads as the same "stale socket" as on POSIX. Windows 10+
## does have `AF_UNIX`, but `std/net`'s accept path and `getFileInfo` on the
## socket's reparse point are untested there; the TCP route uses only the
## calls every platform already runs. Any local process can reach a loopback
## port (a unix socket has file permissions), which is acceptable for a
## `-d:dev` tool and nothing else: a release build carries none of it.
##
## `-d:devTcp` selects the TCP route on any OS, so the Windows code is
## exercised by the Linux test suite too.

import std/net

const tcpChannel* = defined(windows) or defined(devTcp)
  ## True when the channel is loopback TCP plus a port file instead of a unix
  ## socket.

when tcpChannel:
  import std/[os, strutils]

proc listenDev*(path: string): Socket =
  ## A listening socket for the channel at `path`; on the TCP route it also
  ## writes the chosen port to `path`. The caller makes the parent directory
  ## and removes any stale `path` first, and sets non-blocking mode.
  when tcpChannel:
    result = newSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
    result.bindAddr(Port(0), "127.0.0.1")
    result.listen()
    let (_, port) = result.getLocalAddr()
    writeFile(path & ".tmp", $int(port) & "\n")
    moveFile(path & ".tmp", path)
  else:
    result = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, IPPROTO_NONE)
    result.bindUnix(path)
    result.listen()

proc connectDev*(path: string): Socket =
  ## A client socket connected to the channel at `path`. Raises `OSError`
  ## when nothing listens there (the connection is refused, or on the TCP
  ## route the port file is unreadable or holds no port).
  when tcpChannel:
    var port = 0
    try:
      port = parseInt(readFile(path).strip)
    except IOError, ValueError:
      raise newException(OSError, "no port in " & path)
    if port notin 1 .. 65535:
      raise newException(OSError, "no port in " & path)
    result = newSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
    try:
      result.connect("127.0.0.1", Port(port))
    except OSError:
      result.close()
      raise
  else:
    result = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, IPPROTO_NONE)
    try:
      result.connectUnix(path)
    except OSError:
      result.close()
      raise
