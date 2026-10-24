# The Claude adapter for `para studio`: runs the friend's own `claude` program, one turn per
# process, and turns its `--output-format stream-json` lines into the studio's `UiEvent`s
# (agent.nim). Everything Claude-specific lives in this file.
#
# Tested with Claude Code 2.1.296 (checked 2026-10-21 on Linux; Windows and macOS were not run).
# The stream-json shapes this reads were copied from real runs into tests/fixtures/claude-stream/.
#
# How a turn runs:
#
#   claude -p --output-format stream-json --verbose --setting-sources project,local [--resume ID]
#
# in the repository root, with the friend's message on the child's standard input. The message is
# never part of the command line: it is untrusted text, and on Windows a `.cmd` shim would hand a
# command line to cmd.exe. Every argument is a constant of ours or a session id that passed
# `validSession`, and the `.cmd` path additionally refuses any argument with a shell metacharacter,
# so nothing a friend (or an agent) types can reach a shell. `--setting-sources project,local` keeps
# this computer's user-level hooks out of the studio; the repo's own hooks (the producer's
# session-start hook) and its permission allow-list still apply. The environment passes through
# unchanged, with one addition, PARALOOP_UI=studio, which is how the producer learns it is talking
# through a page with buttons instead of a terminal.
#
# What it never does: `--bare`, `--dangerously-skip-permissions`, any `--permission-mode`. Headless
# permissions come from the allow-list in .claude/settings.json; a call that list does not cover is
# refused by claude (it does not hang) and shown here in plain words. It never reads, asks for, keeps
# or shows a login or an API key: those stay with the claude program the friend signed in to
# themselves, and when it says it is not signed in the studio only tells the friend where to do that.
#
# One stream can hold several `result` events: a helper that finishes after the producer has
# answered wakes the producer up again. So the turn ends when the process exits, not at the first
# `result`.

import std/[json, os, osproc, streams, strutils, tables, sets]
import agent
import agentjson
import nimutil

const
  testedClaudeVersion* = "2.1.296"
  installUrl* = "https://code.claude.com/docs/en/setup"
  maxHelperText = 400
  maxToolMemory = 400 ## tool calls remembered to word a refusal
  maxStray = 12 ## unparseable lines kept for the "details" of a crash
  costSentence* = "Talking to Claude uses your own Claude plan or API credit. The studio only starts the claude program on this computer; it never sees or keeps your login."
  aboutSentence* = "The default producer. It builds, checks and plays your game with helpers."
  notInstalledText* = "I can't find the claude program on this computer, so the producer can't chat here yet. " &
    "Install Claude Code from Anthropic's setup page (on Windows that is a step for you to do; the studio doesn't install anything), " &
    "sign in once in a terminal, then reload this page."
  notSignedInText* = "Claude isn't signed in. The studio never touches your login, so please do this once yourself: open a terminal, type claude, " &
    "and follow its sign-in (Anthropic's setup page explains the options; an API key is the documented path, and a Pro or Max login is your own choice made inside claude). " &
    "Then reload this page and send your message again."
  noCreditText* = "Claude says there is no credit left on your plan or API account. Add credit or wait for your plan to reset (on your Claude account page), then send your message again."
  busyText* = "Claude is busy or you have reached a usage limit. Wait a little and send your message again."
  untrustedText* = "Claude doesn't trust this folder yet, so it ignores the list of commands the helpers may run and their commands will be refused. " &
    "Open a terminal in this folder once, type claude, answer Yes to the question about trusting the folder, then come back."
  toolChangedText* = "The producer's tool answered in a way this studio doesn't recognise, so nothing shows here. Claude Code may have changed. " &
    "Update the studio (git pull, then rebuild para), or keep chatting in your terminal for now."
  partialText* = "Some of what the producer's tool said didn't look the way the studio expects, so parts of this turn may be missing. The studio may need an update."

type
  Helper = object
    role: string
    finished: bool

  ToolCall = object
    name, line, parent: string

  ClaudeMapper* = object
    root: string
    sessionId*: string
    version*: string
    sawInit*, sawResult*: bool
    shapeProblems*: int
    errorEmitted*: bool
    sessionMissing*: bool
    untrusted*: bool
    lastAssistantError: string
    helpers: Table[string, Helper]
    background: HashSet[string]
    tools: Table[string, ToolCall]
    toolOrder: seq[string]
    refused: HashSet[string]
    stray*: seq[string]

proc newClaudeMapper*(root = ""): ClaudeMapper =
  ClaudeMapper(root: root.replace('\\', '/').strip(leading = false, chars = {'/'}))

proc validSession*(s: string): string =
  ## `s` when it is shaped like the UUID claude uses for a session, else "". This is the one string
  ## from outside that reaches the command line, so it is checked to the letter.
  validUuid(s)

# --- wording ----------------------------------------------------------------------

proc relPath(m: ClaudeMapper, p: string): string =
  let q = p.replace('\\', '/')
  if m.root.len > 0 and q.startsWith(m.root & "/"): q[m.root.len + 1 .. ^1] else: q

proc toolLine(m: ClaudeMapper, name: string, input: JsonNode): string =
  ## A light line for what a tool call does; "" for calls not worth a line.
  case name
  of "Bash": "Running: " & oneLine(input.str("command"), 110)
  of "Read": "Reading " & oneLine(m.relPath(input.str("file_path")), 100)
  of "Edit", "MultiEdit", "Write", "NotebookEdit":
    "Changing " & oneLine(m.relPath(input.str("file_path")), 100)
  of "Glob", "Grep": "Searching the project"
  of "Skill": "Reading a playbook"
  of "WebSearch", "WebFetch": "Looking something up online"
  of "Agent", "Task", "TodoWrite", "ToolSearch", "ScheduleWakeup": ""
  else: "Using " & oneLine(name, 40)

proc looksRefused*(text: string): bool =
  ## Is this tool error claude's way of saying "that call was not allowed" (as opposed to a command
  ## that ran and failed)? Worded from real runs: "Permission to use Bash has been denied...",
  ## "This command requires approval", "This Bash command contains multiple operations. The
  ## following part requires approval: ...", "A variable in this command can't be checked before it
  ## runs". The result event's `permission_denials` is the authoritative list and catches what these
  ## words miss, only later (at the end of the turn).
  let t = text[0 ..< min(text.len, 300)].toLowerAscii.strip
  t.startsWith("permission to use") or t.startsWith("claude requested permissions") or
    t.startsWith("a variable in this command") or "requires approval" in t or
    "require approval" in t or "haven't granted" in t or "can't be checked before it runs" in t

proc classifyError*(assistantError, text: string): tuple[code, message: string] =
  ## Claude's own word for what went wrong (`error` on the assistant message, or the result text)
  ## to a stable code and plain words for the friend.
  let t = text.toLowerAscii
  if assistantError == "authentication_failed" or "not logged in" in t or "/login" in t or
     "invalid api key" in t or "invalid x-api-key" in t or "authentication" in t:
    return ("not-signed-in", notSignedInText)
  if assistantError == "billing_error" or "credit balance" in t or "out of credit" in t or
     "billing" in t or "insufficient" in t:
    return ("no-credit", noCreditText)
  if assistantError == "rate_limit" or "rate limit" in t or "usage limit" in t or
     "limit reached" in t or "overloaded" in t:
    return ("busy", busyText)
  if "no conversation found" in t:
    return ("session-missing", "Claude could not find the earlier conversation.")
  ("agent-error", "Claude stopped with a problem.")

# --- the mapping ------------------------------------------------------------------

proc say(text: string): UiEvent = UiEvent(kind: ukSay, text: text)

proc remember(m: var ClaudeMapper, id: string, call: ToolCall) =
  if id.len == 0: return
  if m.tools.len >= maxToolMemory and m.toolOrder.len > 0:
    m.tools.del(m.toolOrder[0])
    m.toolOrder.delete(0)
  m.tools[id] = call
  m.toolOrder.add id

proc refusal(m: var ClaudeMapper, id, toolName, detail, parent: string): seq[UiEvent] =
  if id.len > 0:
    if id in m.refused: return
    m.refused.incl id
  let who = if parent.len > 0: "A helper" else: "The producer"
  var what = oneLine(detail, 100)
  if what.len > 0 and toolName == "Bash": what = "run `" & what & "`"
  elif what.len == 0 and toolName == "Bash": what = "run a command"
  elif toolName in ["Edit", "MultiEdit", "Write", "NotebookEdit"]: what = "change " & (if what.len > 0: what else: "a file")
  elif what.len == 0: what = "use " & (if toolName.len > 0: oneLine(toolName, 40) else: "a tool")
  else: what = "use " & oneLine(toolName, 40) & " on " & what
  @[UiEvent(kind: ukRefused, code: "refused",
    text: who & " wasn't allowed to " & what & ". Ask the producer to do it a different way.")]

proc toolDetail(input: JsonNode): string =
  for k in ["command", "file_path", "pattern", "url"]:
    let v = input.str(k)
    if v.len > 0: return v

proc noteStray(m: var ClaudeMapper, line: string): seq[UiEvent] =
  ## A line that is not stream-json: claude's own stderr (the studio reads both together). Kept for
  ## the details of a crash; one known warning gets a note of its own.
  let t = oneLine(line, 300)
  if t.len == 0: return
  if m.stray.len >= maxStray: m.stray.delete(0)
  m.stray.add t
  if "permissions.allow" in t and "not been trusted" in t and not m.untrusted:
    m.untrusted = true
    return @[UiEvent(kind: ukNotice, code: "untrusted-folder", text: untrustedText)]

proc onSystem(m: var ClaudeMapper, e: JsonNode): seq[UiEvent] =
  case e.str("subtype")
  of "init":
    m.sawInit = true
    let sid = validSession(e.str("session_id"))
    if sid.len > 0: m.sessionId = sid
    let v = e.str("claude_code_version")
    if v.len > 0: m.version = v
  of "task_started":
    let id = e.str("tool_use_id")
    let key = if id.len > 0: id else: e.str("task_id")
    if key.len == 0:
      inc m.shapeProblems
      return
    let kind = e.str("task_type")
    let subagent = e.str("subagent_type")
    if kind == "local_agent" or subagent.len > 0:
      let role = helperRole(subagent, e.str("description"), e.str("prompt"))
      m.helpers[key] = Helper(role: role)
      result.add UiEvent(kind: ukHelper, id: key, role: role, status: "started",
                         text: oneLine(e.str("description"), maxHelperText), tools: 0)
    else:
      # a shell command the producer left running in the background: a line, not a helper card
      m.background.incl key
      let d = oneLine(e.str("description"), 110)
      if d.len > 0: result.add UiEvent(kind: ukActivity, text: "Running in the background: " & d)
  of "task_progress":
    let key = if e.str("tool_use_id").len > 0: e.str("tool_use_id") else: e.str("task_id")
    if key in m.helpers and not m.helpers[key].finished:
      result.add UiEvent(kind: ukHelper, id: key, role: m.helpers[key].role, status: "working",
                         text: oneLine(e.str("description"), maxHelperText),
                         tools: e.num(["usage", "tool_uses"]))
  of "task_notification":
    let key = if e.str("tool_use_id").len > 0: e.str("tool_use_id") else: e.str("task_id")
    if key in m.helpers:
      m.helpers[key].finished = true
      let status = case e.str("status")
        of "failed", "error": "failed"
        of "stopped", "killed", "cancelled": "stopped"
        else: "done"
      result.add UiEvent(kind: ukHelper, id: key, role: m.helpers[key].role, status: status,
                         text: oneLine(e.str("summary"), maxHelperText),
                         tools: e.num(["usage", "tool_uses"]))
  else: discard # hooks, thinking counters, task patches: nothing for the friend

proc onAssistant(m: var ClaudeMapper, e: JsonNode): seq[UiEvent] =
  let parent = e.str("parent_tool_use_id")
  let err = e.str("error")
  if err.len > 0: m.lastAssistantError = err
  let content = e.at("message", "content")
  if content == nil or content.kind != JArray:
    inc m.shapeProblems
    return
  for b in content:
    case b.str("type")
    of "text":
      let t = b.str("text")
      # a message with an `error` is claude's own notice ("Not logged in"), told once by the result
      if parent.len == 0 and err.len == 0 and t.strip.len > 0: result.add say(t.strip)
    of "tool_use":
      let name = b.str("name")
      let input = b.at("input")
      let line = m.toolLine(name, input)
      m.remember(b.str("id"), ToolCall(name: name, line: toolDetail(input), parent: parent))
      if parent.len == 0 and line.len > 0: result.add UiEvent(kind: ukActivity, text: line)
    else: discard

proc onUser(m: var ClaudeMapper, e: JsonNode): seq[UiEvent] =
  let parent = e.str("parent_tool_use_id")
  let content = e.at("message", "content")
  if content == nil or content.kind != JArray: return
  for b in content:
    if b.str("type") != "tool_result" or not b.flag("is_error"): continue
    var text = ""
    let c = b.at("content")
    if c != nil and c.kind == JString: text = c.getStr
    elif c != nil and c.kind == JArray:
      for part in c: text.add part.str("text") & " "
    if not looksRefused(text): continue
    let id = b.str("tool_use_id")
    let call = m.tools.getOrDefault(id)
    result.add m.refusal(id, call.name, call.line, parent)

proc onResult(m: var ClaudeMapper, e: JsonNode): seq[UiEvent] =
  m.sawResult = true
  let denials = e.at("permission_denials")
  if denials != nil and denials.kind == JArray:
    for d in denials:
      let input = d.at("tool_input")
      result.add m.refusal(d.str("tool_use_id"), d.str("tool_name"), toolDetail(input), "")
  let subtype = e.str("subtype")
  let failed = e.flag("is_error") or (subtype.startsWith("error") and subtype.len > 0)
  if not failed: return
  var text = e.str("result")
  let errs = e.at("errors")
  if errs != nil and errs.kind == JArray:
    for x in errs:
      if x.kind == JString: text.add " " & x.getStr
  let (code, message) = classifyError(m.lastAssistantError, text)
  if code == "session-missing":
    m.sessionMissing = true # the adapter starts a fresh conversation; no error for the friend
    return
  m.errorEmitted = true
  result.add UiEvent(kind: ukError, code: code, text: message, url: installUrl,
    detail: if code == "agent-error": oneLine(redactSecrets(text), 300) else: "")

proc mapLine*(m: var ClaudeMapper, line: string): seq[UiEvent] =
  ## One output line of `claude --output-format stream-json` to zero or more events. Never raises:
  ## a line that is not JSON is kept as a stray line, an event type nobody knows is ignored, an
  ## event of a known type with the wrong shape is skipped (and counted in `shapeProblems`).
  let t = line.strip
  if t.len == 0: return
  var e: JsonNode
  try:
    e = parseJson(t)
  except CatchableError:
    return m.noteStray(t)
  if e.kind != JObject:
    return m.noteStray(t)
  try:
    case e.str("type")
    of "system": result = m.onSystem(e)
    of "assistant": result = m.onAssistant(e)
    of "user": result = m.onUser(e)
    of "result": result = m.onResult(e)
    else: discard
  except CatchableError:
    inc m.shapeProblems
    result = @[]

proc finish*(m: var ClaudeMapper, exitCode: int, cancelled: bool): seq[UiEvent] =
  ## What is still to say once the process has ended.
  if cancelled: return
  if m.lastAssistantError.len > 0 and not m.errorEmitted and not m.sessionMissing:
    # claude told us something went wrong but never sent its result line
    let (code, message) = classifyError(m.lastAssistantError, "")
    m.errorEmitted = true
    return @[UiEvent(kind: ukError, code: code, text: message, url: installUrl)]
  if m.errorEmitted or m.sessionMissing: return
  if exitCode != 0:
    m.errorEmitted = true
    var detail = ""
    if m.stray.len > 0: detail = redactSecrets(m.stray[^1])
    return @[UiEvent(kind: ukError, code: "crashed", detail: detail,
      text: "The producer's tool stopped before it finished (exit code " & $exitCode & "). Your message may not have been handled; you can send it again.")]
  if not m.sawInit and not m.sawResult:
    m.errorEmitted = true
    return @[UiEvent(kind: ukError, code: "tool-changed", text: toolChangedText, url: installUrl)]
  if m.shapeProblems > 0:
    return @[UiEvent(kind: ukNotice, code: "partial", text: partialText)]

# --- running claude ---------------------------------------------------------------

proc locate(a: AgentAdapter): string =
  if a.exe.len > 0: a.exe else: findExe("claude")

proc claudeDescribe(a: AgentAdapter): AgentInfo =
  result = AgentInfo(name: "claude", label: "Claude", url: installUrl)
  let exe = locate(a)
  if exe.len == 0:
    result.note = notInstalledText
    return
  result.installed = true
  let r = runCaptured(exe, @["--version"], timeoutMs = 8000)
  if r.exitCode == 0:
    let first = r.output.strip.splitWhitespace()
    if first.len > 0 and first[0].len <= 24 and first[0].allCharsInSet({'0'..'9', '.'}) and '.' in first[0]:
      result.version = first[0]
  if result.version.len == 0:
    result.note = "I couldn't read Claude's version, so I can't tell whether it is one this studio was tested with (" &
      testedClaudeVersion & "). Chat may still work."

type Attempt = object
  exitCode: int
  started: bool

proc attemptTurn(exe: string, req: TurnRequest, session: string, ctl: ptr TurnControl,
                 emit: EmitProc, m: var ClaudeMapper): Attempt =
  var args = @["-p", "--output-format", "stream-json", "--verbose", "--setting-sources", "project,local"]
  if session.len > 0: args.add ["--resume", session]
  if isShim(exe) and not shimSafe(args):
    emit UiEvent(kind: ukError, code: "cannot-start", text: "I couldn't start Claude safely on this computer.")
    return Attempt(exitCode: 1)
  var p: Process
  try:
    p = startProcess(exe, workingDir = req.workDir, args = args, env = childEnv(),
                     options = {poUsePath, poStdErrToStdOut, poDaemon})
  except OSError as e:
    emit UiEvent(kind: ukError, code: "cannot-start",
      text: "I couldn't start Claude: " & oneLine(redactSecrets(e.msg), 200), url: installUrl)
    return Attempt(exitCode: 127)
  result.started = true
  ctl.attach(p.processID)
  try:
    p.inputStream.write(req.text)
    p.inputStream.close()
  except IOError, OSError:
    discard # the child already left; its exit code tells the story
  var line: string
  var lastSession = ""
  try:
    while p.outputStream.readLine(line):
      for ev in m.mapLine(line):
        emit ev
      if m.sessionId.len > 0 and m.sessionId != lastSession:
        lastSession = m.sessionId
        if not req.onSession.isNil: req.onSession(lastSession)
  except IOError, OSError:
    discard
  result.exitCode = p.waitForExit()
  ctl.markExited()
  p.close()

proc claudeRunTurn(a: AgentAdapter, req: TurnRequest, ctl: ptr TurnControl, emit: EmitProc): TurnResult =
  let exe = locate(a)
  if exe.len == 0:
    emit UiEvent(kind: ukError, code: "not-installed", text: notInstalledText, url: installUrl)
    return TurnResult(exitCode: 127)
  var session = validSession(req.sessionId)
  for attempt in 0 .. 1:
    var m = newClaudeMapper(req.workDir)
    let r = attemptTurn(exe, req, session, ctl, emit, m)
    result.exitCode = r.exitCode
    result.sessionId = if m.sessionId.len > 0: m.sessionId else: session
    result.cancelled = ctl.isCancelled
    if m.sessionMissing and session.len > 0 and not result.cancelled and attempt == 0:
      emit UiEvent(kind: ukNotice, code: "fresh-start",
        text: "Claude couldn't find the earlier conversation, so this starts a new one. The producer will pick the game up from its notes.")
      session = ""
      continue
    if r.started:
      for ev in m.finish(r.exitCode, result.cancelled): emit ev
    result.ok = r.started and not result.cancelled and r.exitCode == 0 and not m.errorEmitted
    return

proc newClaudeAdapter*(exe = ""): AgentAdapter =
  ## `exe` is for tests (a stand-in program); left out, `claude` is looked up on PATH each time.
  AgentAdapter(name: "claude", label: "Claude", exe: exe, describe: claudeDescribe, runTurn: claudeRunTurn,
               cost: costSentence, about: aboutSentence)
