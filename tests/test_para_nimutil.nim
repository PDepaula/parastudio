# Tests for nimutil.runCaptured's timeout and its start-failure behaviour:
# a command that runs too long is stopped and reported as timed out, one that
# cannot be started is exit 127, and neither leaves this process in the
# command's working directory (Nim leaves it there when a start fails).

import std/[unittest, os, strutils, tempfiles, times]
import tools/para/nimutil

suite "runCaptured":
  test "output and exit code, as before":
    let r = runCaptured("git", @["--version"])
    check r.exitCode == 0
    check r.output.startsWith("git version")

  test "a command that cannot be started is 127 and the working directory is kept":
    let dir = createTempDir("para_nimutil_", "")
    let here = getCurrentDir()
    let r = runCaptured("para-test-no-such-command", @[], dir)
    check r.exitCode == 127
    check getCurrentDir() == here
    removeDir(dir)

  test "a fast command under a timeout is unaffected":
    let r = runCaptured("git", @["--version"], timeoutMs = 5000)
    check r.exitCode == 0
    check r.output.startsWith("git version")

  when not defined(windows):
    test "a command still running after the timeout is stopped and reported as timed out":
      let t0 = epochTime()
      let r = runCaptured("sleep", @["20"], timeoutMs = 200)
      check r.exitCode == timedOutCode
      check "took longer" in r.output
      check epochTime() - t0 < 10.0
