# Shared subprocess + diagnostic-parsing helpers for `para`'s test/build/web
# smoke commands: running a command and capturing its combined stdout+stderr
# with a real exit code (unlike a `nimble` task's own exit code, which is
# always 0 on nimble 0.22.2 even when the task failed -- AGENTS.md), and
# turning Nim's `file(line, col) Severity: message` diagnostic lines into rows
# a TOON table can print.

import std/[osproc, streams, strutils, strtabs, os, times, locks]

type
  ProcResult* = object
    output*: string
    exitCode*: int

  NimDiag* = object
    at*: string
    msg*: string
    severity*: string

const timedOutCode* = 124 ## the exit code `runCaptured` reports for a run it had to stop

var spawnLock: Lock
initLock(spawnLock)

proc startLocked*(cmd: string, workingDir = "", args: openArray[string] = [], env: StringTableRef = nil,
                  options: set[ProcessOption] = {poStdErrToStdOut}): Process =
  ## `startProcess`, one at a time across threads. osproc makes the child's pipes without
  ## close-on-exec and, for a `workingDir`, changes this whole process's current folder while it
  ## starts the child (posix_spawn has no chdir). Two starts at once from two threads (the studio
  ## asking git a question while a Check or a chat turn starts) would hand one child the other's
  ## pipe, so the question's answer waits for that other program to end, or start it in the wrong
  ## folder. Every program `para` starts from a thread goes through here.
  acquire(spawnLock)
  defer: release(spawnLock)
  startProcess(cmd, workingDir = workingDir, args = args, env = env, options = options)

proc runCaptured*(cmd: string, args: seq[string], workDir = "", timeoutMs = 0): ProcResult =
  ## Runs `cmd args...`, merging stderr into stdout, and returns the whole
  ## output plus the process's real exit code -- or exit code 127 and the
  ## reason as output when `cmd` cannot be started (say, not on PATH).
  ## With `timeoutMs` > 0 a run still going after that long is killed and
  ## reported as `timedOutCode` (its output is not read: a short, quiet
  ## command is the use, a session-start hook asking git a question).
  var p: Process
  let cwd = try: getCurrentDir() except OSError: ""
  try:
    p = startLocked(cmd, workingDir = workDir, args = args,
                    options = {poStdErrToStdOut, poUsePath})
  except OSError as e:
    # a start that fails (cmd not on the PATH) can leave this process in `workDir`
    if cwd.len > 0:
      try: setCurrentDir(cwd)
      except OSError: discard
    return ProcResult(output: "cannot run " & cmd & ": " & e.msg & "\n", exitCode: 127)
  defer: p.close()
  if timeoutMs > 0:
    let deadline = epochTime() + timeoutMs.float / 1000.0
    while p.running and epochTime() < deadline:
      sleep(5)
    if p.running:
      p.kill()
      discard p.waitForExit()
      return ProcResult(output: cmd & " took longer than " & $timeoutMs & " ms\n", exitCode: timedOutCode)
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()

proc runStreamed*(cmd: string, args: seq[string], onLine: proc (line: string),
                  workDir = ""): ProcResult =
  ## `runCaptured`, but calls `onLine` with each output line (no newline) as
  ## the process prints it, so a caller can show progress while a long run is
  ## still going. `output` is the same whole output `runCaptured` returns.
  var p: Process
  try:
    p = startLocked(cmd, workingDir = workDir, args = args,
                    options = {poStdErrToStdOut, poUsePath})
  except OSError as e:
    return ProcResult(output: "cannot run " & cmd & ": " & e.msg & "\n", exitCode: 127)
  defer: p.close()
  var line: string
  while p.outputStream.readLine(line):
    result.output.add line & "\n"
    onLine(line)
  result.exitCode = p.waitForExit()

proc parseNimDiagnostics*(output: string): seq[NimDiag] =
  ## Pulls `path/to/file.nim(line, col) Severity: message` lines out of a nim
  ## compiler run's output (only `Error`/`Warning` -- callers compile with
  ## `--hints:off`).
  for rawLine in output.splitLines:
    let line = rawLine.strip
    let parenIdx = line.find('(')
    if parenIdx <= 0: continue
    let closeIdx = line.find(')', parenIdx)
    if closeIdx < 0: continue
    let file = line[0 ..< parenIdx]
    if not file.endsWith(".nim"): continue
    let rest = line[closeIdx + 1 .. ^1]
    let colonIdx = rest.find(':')
    if colonIdx < 0: continue
    let sev = rest[0 ..< colonIdx].strip
    if sev notin ["Error", "Warning"]: continue
    let lc = line[parenIdx + 1 ..< closeIdx].split(',')
    if lc.len < 1: continue
    result.add NimDiag(at: file & ":" & lc[0].strip, msg: rest[colonIdx + 1 .. ^1].strip, severity: sev)

proc lastLines*(s: string, n: int): string =
  ## The last `n` lines of `s`, for a short inline preview ahead of --full.
  let lines = s.splitLines
  let start = max(0, lines.len - n)
  lines[start .. ^1].join("\n") & "\n"
