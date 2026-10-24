# A tiny client for `paraloop/dev`'s control-channel request format
# (`paraloop/dev`'s module doc: one line in, `ok <text>` | `error <message>`
# back, then the connection closes) -- what `para live` and the bare view's
# live ping (engine report task 1.8) wrap. `paraloop/dev` itself holds only
# the server side (`newDevServer`/`poll`).

import std/[net, os, times, strutils]
import paraloop/devsock

type
  DevReply* = object
    ok*: bool
    text*: string ## the text after `ok `/`error `, or the raw line if neither
    raw*: string

proc socketExists*(path: string): bool =
  ## `os.fileExists` doesn't recognize a unix socket special file as
  ## "existing" (it only checks regular files and symlinks) -- paraloop/dev's
  ## own tests use the same `getFileInfo` workaround.
  try:
    discard getFileInfo(path)
    true
  except OSError:
    false

const maxSockPath = 100 ## a unix socket address holds 104 bytes on macOS, 108 on Linux

proc connectPath*(path: string): string =
  ## `path` as it can be connected to. A unix socket address cannot be longer than the OS allows
  ## (a game folder deep in a long path, or one synced into iCloud or OneDrive, can pass it), and
  ## `connectUnix` then raises ValueError. The same socket is reachable by its path from the
  ## current directory, which is short when the studio or `para` runs inside the repository.
  when tcpChannel:
    path
  else:
    if path.len <= maxSockPath: return path
    try:
      let rel = relativePath(path, getCurrentDir())
      if rel.len < path.len: rel else: path
    except OSError:
      path

proc sendDevRequest*(sockPath: string, request: string, timeoutMs = 2000): DevReply =
  ## Sends `request` (one line) to the unix socket at `sockPath` and returns
  ## the one-line reply. Raises `IOError` (never `OSError`/`TimeoutError`
  ## directly) with a message ready to show the agent when the socket is
  ## missing, refuses the connection, or never answers in time.
  if not socketExists(sockPath):
    raise newException(IOError, "no live session at " & sockPath)
  var client: Socket
  try:
    client = connectDev(connectPath(sockPath))
  except OSError, ValueError:
    raise newException(IOError, "cannot connect to " & sockPath & ": " & getCurrentExceptionMsg())
  try:
    client.send(request & "\n")
    var line: string
    try:
      line = client.recvLine(timeout = timeoutMs)
    except TimeoutError:
      raise newException(IOError, "no response from " & sockPath & " within " & $timeoutMs & "ms")
    if line.len == 0:
      raise newException(IOError, sockPath & " closed the connection with no reply")
    result.raw = line
    if line.startsWith("ok "):
      result.ok = true
      result.text = line["ok ".len .. ^1]
    elif line.startsWith("error "):
      result.ok = false
      result.text = line["error ".len .. ^1]
    else:
      result.ok = false
      result.text = line
  finally:
    client.close()

proc waitForFile*(path: string, timeoutMs = 5000): bool =
  ## Polls for `path` to appear -- a `shot` reply names a file a later frame
  ## writes (`paraloop/dev`'s module doc), and it only ever appears complete.
  let started = epochTime()
  while not fileExists(path):
    if (epochTime() - started) * 1000 > float(timeoutMs):
      return false
    sleep(20)
  true
