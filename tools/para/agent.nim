# The seam between `para studio` and whatever AI agent the friend has installed.
#
# The studio (studiochat.nim, studioapi.nim) and its page know only what is in this file: a message
# goes in, a stream of `UiEvent`s comes out, a turn can be cancelled, and a session id is reported
# so the next turn resumes the same conversation. Nothing Claude-specific is allowed above this
# line: claudeagent.nim and codexagent.nim are the adapters today, and an adapter for another agent
# is one more file that fills in an `AgentAdapter` and is listed in agents.nim; the server and the
# page do not change.
#
# What an adapter promises:
#
# - it runs the friend's own, unmodified agent program as a child process of this computer, started
#   with an argument list (never a shell string), and never a copy of that program that we bundle
#   or download;
# - it never reads, asks for, stores, logs, forwards or shows a login, a token or an API key: those
#   live with the agent program, and the studio has no sign-in screen. Anything of the agent's own
#   words that reaches the page as a diagnostic goes through `redactSecrets` first;
# - everything the agent says is untrusted text: the page puts it in with textContent, never as
#   HTML, and nothing in it is ever run;
# - `pastTurns`, when it has one, opens only the agent's own record of the one conversation it is
#   asked about, read-only: it never lists or scans the agent's folder, never writes there, and
#   never reads the agent's settings or login.
#
# This file also owns the two pieces every child-process adapter needs and none should redo: the
# `TurnControl` that lets another thread stop a turn (killing the child's whole process tree, the
# part that differs between Windows and the rest), and `redactSecrets`.

import std/[locks, os, osproc, strutils, strtabs, times]
when not defined(windows):
  import std/posix

type
  UiKind* = enum
    ukSay        ## the producer's words (`text`)
    ukActivity   ## a light "what it is doing" line (`text`)
    ukHelper     ## a helper card: `id`, `role`, `status`, `text`, `tools`
    ukRefused    ## a tool call was not allowed, in plain words (`text`)
    ukNotice     ## a plain note that is not an error (`code`, `text`)
    ukError      ## the turn failed (`code`, `text`, maybe `detail`, `url`)
    ukTurnDone   ## the turn ended (`text`); sent by the studio, not by an adapter
    ukShot       ## a picture card (`text` is the studio's own picture name); the studio sends it for a screenshot, an adapter only for a picture it copied into the studio's folder

  UiEvent* = object
    kind*: UiKind
    text*: string
    id*: string      ## ukHelper: which card
    role*: string    ## ukHelper: "builder", "checker", "scout", "art" or "helper"
    status*: string  ## ukHelper: "started", "working", "done", "failed" or "stopped"
    tools*: int      ## ukHelper: tool calls so far, -1 when not known
    code*: string    ## ukNotice / ukError: a short stable word the page can act on
    detail*: string  ## ukError: a few redacted words from the agent, for the curious
    url*: string     ## ukError: where to read more; always one of our own constants

  ChatLine* = tuple[you: bool, ev: UiEvent] ## one line of a chat; `you` for the friend's own message (an `ukSay`)

  EmitProc* = proc (ev: UiEvent) {.closure, gcsafe.}
  SessionProc* = proc (sessionId: string) {.closure, gcsafe.}

  TurnRequest* = object
    text*: string        ## what the friend typed (untrusted; never put on a command line)
    sessionId*: string   ## "" on the first turn
    workDir*: string     ## the repository root
    onSession*: SessionProc ## called as soon as the agent reports its session id

  TurnResult* = object
    ok*: bool            ## the agent ended without an error (an error has been emitted otherwise)
    cancelled*: bool
    exitCode*: int
    sessionId*: string

  AgentInfo* = object
    name*: string        ## "claude"
    label*: string       ## what the page calls it: "Claude"
    installed*: bool
    version*: string     ## "" when it could not be read
    note*: string        ## one plain line to show when something is off (not installed, no version)
    url*: string         ## where to read more

  CheckState* = enum
    csOk       ## looked, and it is fine
    csFail     ## looked, and it is not
    csUnknown  ## could not tell (no safe way to ask, or the answer was not in a shape we know)

  PreflightCheck* = object
    ## One line of the startup check on the page (`GET /api/preflight`).
    id*: string          ## "installed", "signed-in", "trusted" or "edits": a stable word the page and tests use
    state*: CheckState
    label*: string       ## what should be true: "Claude is signed in"
    problem*: string     ## when not ok: what is wrong, or "Could not check ..."
    fix*: string         ## when not ok: one plain line saying what to do

  AgentAdapter* = object
    name*: string        ## "claude": the word in file names and requests
    label*: string       ## "Claude": what the page calls it
    exe*: string         ## "" = look the program up on PATH; set by tests
    describe*: proc (a: AgentAdapter): AgentInfo {.nimcall, gcsafe.}
    preflight*: proc (a: AgentAdapter, root: string): seq[PreflightCheck] {.nimcall, gcsafe.}
      ## Read-only setup checks before the first chat (installed, signed in, folder trusted, edits
      ## allowed); nil for an adapter that has none. Never starts a model turn, never reads or
      ## returns a login, a token or a key.
    runTurn*: proc (a: AgentAdapter, req: TurnRequest, ctl: ptr TurnControl,
                    emit: EmitProc): TurnResult {.nimcall, gcsafe.}
    pastTurns*: proc (a: AgentAdapter, root, sessionId: string): seq[ChatLine] {.nimcall, gcsafe.}
      ## The friend's messages and the agent's words in conversation `sessionId`, read back from the
      ## agent's own record of it on this computer, for a chat the studio kept no lines of (one from
      ## before it kept them). Empty when there is no such record or it cannot be read; never raises.
      ## Nil for an agent whose records are not that simple to find.
    historyDir*: string  ## where `pastTurns` looks; "" = the agent's own folder. Set by tests
    cost*: string        ## one plain sentence about who pays, shown beside the chat
    about*: string       ## one plain sentence for the agent picker: what to expect from this one

  SoftStop* = proc (data: pointer): bool {.nimcall, gcsafe.}

  TurnControl* = object
    lock: Lock
    pid: int
    cancelled: bool
    reason: string
    exited: bool
    softStop: SoftStop
    softData: pointer

const
  termGraceMs = 2000

# --- stopping a turn -------------------------------------------------------------

proc descendantsOf*(pid: int): seq[int] =
  ## The processes `pid` started, and the ones they started (POSIX: read from `ps`; Windows asks
  ## `taskkill /T` to walk the tree instead, so this is empty there). Taken before anything is
  ## signalled: once a parent is gone its children are adopted and can no longer be found from it.
  when defined(windows):
    discard
  else:
    var kids: seq[(int, int)]
    try:
      for line in execProcess("ps", args = ["-A", "-o", "pid=,ppid="], options = {poUsePath}).splitLines:
        let f = line.splitWhitespace
        if f.len == 2 and f[0].allCharsInSet(Digits) and f[1].allCharsInSet(Digits):
          kids.add (parseInt(f[0]), parseInt(f[1]))
    except OSError, ValueError:
      return
    var frontier = @[pid]
    while frontier.len > 0 and result.len < 4096:
      let cur = frontier.pop
      for (k, parent) in kids:
        if parent == cur and k notin result:
          result.add k
          frontier.add k

proc terminateTree*(pid: int, force: bool, also: seq[int] = @[]) =
  ## Ends a child process and everything it started. POSIX: the child leads its own process group
  ## (osproc's `poDaemon` on the spawn path), so the signal goes to the group, and to the child and
  ## every process in `also` (its descendants, from `descendantsOf`) one by one, which also covers
  ## children that made groups of their own; Windows: `taskkill /T` walks the tree.
  if pid <= 0: return
  when defined(windows):
    var exe = findExe("taskkill")
    if exe.len == 0: exe = getEnv("SystemRoot", "C:\\Windows") / "System32" / "taskkill.exe"
    try:
      let p = startProcess(exe, args = @["/PID", $pid, "/T", "/F"],
                           options = {poUsePath, poDaemon, poStdErrToStdOut})
      defer: p.close()
      discard p.waitForExit(5000)
    except OSError:
      discard
  else:
    let sig = if force: SIGKILL else: SIGTERM
    discard kill(Pid(-pid), sig) # the group
    discard kill(Pid(pid), sig)  # the child itself, in case it was not made a group leader
    for k in also: discard kill(Pid(k), sig)

proc newTurnControl*(): ptr TurnControl =
  result = create(TurnControl)
  initLock(result.lock)

proc freeTurnControl*(c: ptr TurnControl) =
  deinitLock(c.lock)
  dealloc(c)

proc attach*(c: ptr TurnControl, pid: int) =
  ## The adapter calls this once its child is running. A cancel that came first ends the child now.
  var now = false
  acquire(c.lock)
  c.pid = pid
  c.exited = false
  now = c.cancelled
  release(c.lock)
  if now: terminateTree(pid, true, descendantsOf(pid))

proc setSoftStop*(c: ptr TurnControl, stop: SoftStop, data: pointer) =
  ## An adapter whose agent can be asked to stop politely (a protocol message rather than a signal)
  ## registers that here; `cancel` tries it first and only then ends the process tree. `stop` returns
  ## true when it sent the request. `data` must stay valid until `clearSoftStop` returns.
  acquire(c.lock)
  c.softStop = stop
  c.softData = data
  release(c.lock)

proc clearSoftStop*(c: ptr TurnControl) =
  ## After this returns `cancel` no longer calls the soft stop, so its data may be freed.
  acquire(c.lock)
  c.softStop = nil
  c.softData = nil
  release(c.lock)

proc markExited*(c: ptr TurnControl) =
  acquire(c.lock)
  c.exited = true
  c.pid = 0
  release(c.lock)

proc isCancelled*(c: ptr TurnControl): bool =
  acquire(c.lock)
  result = c.cancelled
  release(c.lock)

proc cancelReason*(c: ptr TurnControl): string =
  acquire(c.lock)
  result = c.reason
  release(c.lock)

proc cancel*(c: ptr TurnControl, reason = "stop") =
  ## Asks the turn to end: terminates the child's tree, and if it is still there after a short grace
  ## period ends it for good. Blocks for at most the grace period (a couple of seconds).
  var pid = 0
  var asked = false
  acquire(c.lock)
  if not c.cancelled:
    c.cancelled = true
    c.reason = reason
  pid = c.pid
  if pid > 0 and c.softStop != nil: asked = c.softStop(c.softData) # under the lock: see clearSoftStop
  release(c.lock)
  if pid <= 0: return
  if asked:
    let polite = epochTime() + termGraceMs / 1000
    while epochTime() < polite:
      acquire(c.lock)
      let gone = c.exited
      release(c.lock)
      if gone: return
      sleep(20)
  let tree = descendantsOf(pid)
  terminateTree(pid, false, tree)
  let until = epochTime() + termGraceMs / 1000
  while epochTime() < until:
    acquire(c.lock)
    let gone = c.exited
    release(c.lock)
    if gone: break
    sleep(50)
  # whatever is still there (the child ignoring the polite signal, or a grandchild) is ended for good
  terminateTree(pid, true, tree)

# --- keeping secrets out of anything shown ------------------------------------------

proc secretName(name: string): bool =
  let n = name.toUpperAscii
  for part in ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "AUTH"]:
    if part in n: return true

proc keyLike(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.'}

proc redactSecrets*(text: string): string =
  ## `text` with anything that looks like a key or a login taken out: the value of any environment
  ## variable whose name suggests one (KEY, TOKEN, SECRET, PASSWORD, AUTH, CREDENTIAL), anything
  ## shaped like an `sk-...` API key, and whatever follows `Bearer `. The studio never meant to
  ## see such a thing; this is the belt to go with those braces.
  result = text
  for (k, v) in envPairs():
    if v.len >= 6 and secretName(k):
      result = result.replace(v, "[hidden]")
  var i = 0
  var outp = ""
  while i < result.len:
    let rest = result.len - i
    if rest > 3 and result[i .. i + 2] == "sk-" and (i == 0 or not keyLike(result[i - 1])):
      var j = i + 3
      while j < result.len and keyLike(result[j]): inc j
      if j - i >= 10:
        outp.add "[hidden]"
        i = j
        continue
    if rest > 7 and result[i .. i + 6].toLowerAscii == "bearer ":
      var j = i + 7
      while j < result.len and keyLike(result[j]): inc j
      outp.add "Bearer [hidden]"
      i = j
      continue
    outp.add result[i]
    inc i
  result = outp

# --- small helpers every adapter and the studio share ---------------------------------

proc oneLine*(s: string, limit: int): string =
  ## One short line: whitespace runs become a single space, cut with an ellipsis past `limit`.
  var last = ' '
  for c in s.strip:
    let c2 = if c in {'\n', '\r', '\t'}: ' ' else: c
    if c2 == ' ' and last == ' ': continue
    result.add c2
    last = c2
  if result.len > limit: result = result[0 ..< limit].strip(leading = false) & "…"

proc validSessionToken*(s: string): string =
  ## `s` when it could be an agent's session id (1 to 64 letters, digits, `-` or `_`, not starting
  ## with `-` so it can never read as an option), else "".
  ## This is all the studio asks of the id it keeps in a file; an adapter checks its own stricter
  ## shape before the id goes anywhere near a command line.
  if s.len == 0 or s.len > 64 or s[0] == '-': return ""
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: return ""
  s

proc validUuid*(s: string): string =
  ## `s` when it is shaped like a UUID (36 characters, hex digits and dashes in the usual places),
  ## else "". Claude's session ids and Codex's thread ids both are; an adapter checks this before an
  ## id goes anywhere near a command line or a request.
  if s.len != 36: return ""
  for i, c in s:
    if i in [8, 13, 18, 23]:
      if c != '-': return ""
    elif c notin {'0'..'9', 'a'..'f', 'A'..'F'}: return ""
  s

proc helperRole*(subagent, description, prompt: string): string =
  ## builder / checker / scout / art when the helper's prompt names that playbook (the producer's
  ## playbook says to), else the subagent type, else "helper".
  let hay = (prompt & " " & description).replace('\\', '/').toLowerAscii
  for r in ["builder", "checker", "scout", "art"]:
    if ("skills/" & r) in hay: return r
  for r in ["builder", "checker", "scout"]:
    if r in description.toLowerAscii: return r
  let s = subagent.strip
  if s.len > 0 and s.len <= 24 and s != "general-purpose" and
     s.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}):
    return s
  "helper"

# --- starting the agent program ---------------------------------------------------------

proc isShim*(exe: string): bool =
  let e = exe.toLowerAscii
  e.endsWith(".cmd") or e.endsWith(".bat")

proc shimSafe*(args: seq[string]): bool =
  ## A `.cmd` shim is run by cmd.exe, which reads its command line as a string. Our arguments are
  ## constants and a checked session id; this refuses to start if any of them could be read as more.
  for a in args:
    for c in a:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ',', ':', '='}: return false
  true

proc childEnv*(): StringTableRef =
  ## This process's environment plus PARALOOP_UI=studio, which is how the producer learns it is
  ## talking through a page with buttons instead of a terminal.
  result = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs():
    if k.len > 0 and k[0] != '=': # Windows keeps hidden per-drive entries named "=C:"; they are not ours to pass on
      result[k] = v
  result["PARALOOP_UI"] = "studio"
