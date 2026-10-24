# The Codex adapter for `para studio`: runs the friend's own `codex` program as an app-server
# (JSON-RPC, one JSON message per line, over the child's standard input and output), one turn per
# process, and turns its notifications into the studio's `UiEvent`s (agent.nim). Everything
# Codex-specific lives in this file.
#
# Tested with Codex CLI 0.159.2 (checked 2026-10-23 on Linux; Windows and macOS were not run). The
# message shapes this reads come from that version's generated JSON schema and from real runs of its
# app-server (tests/fixtures/codex-appserver/: trimmed copies, the account and path details replaced).
#
# How a turn runs:
#
#   codex app-server --listen stdio://
#
# in the repository root, then over standard input: `initialize`, the `initialized` notification,
# `thread/start` (or `thread/resume` with the saved thread id), `turn/start` with the friend's
# message, and nothing more until `turn/completed` arrives; then the adapter closes standard input
# and the app-server ends. The message travels inside JSON on standard input, never on a command
# line: it is untrusted text, and on Windows a `.cmd` shim would hand a command line to cmd.exe.
# The only arguments are constants of ours, and the `.cmd` path additionally refuses any argument
# with a shell metacharacter. The environment passes through unchanged, with one addition,
# PARALOOP_UI=studio.
#
# Permissions: `approvalPolicy: "never"` with `sandbox: "workspace-write"`. Codex then never asks;
# a command outside its sandbox fails inside Codex (it does not hang) and an item it was not allowed
# to run is shown here in plain words. Should a server ask anyway (an approval request), the answer
# is always no. Never `danger-full-access`, never an automatic yes.
#
# What it never does: read, ask for, keep or show a login or a token. `account/chatgptAuthTokens/refresh`
# and every other request this adapter does not know is answered with an error. The sign-in stays
# with the codex program the friend signed in to themselves, and when it says it is not signed in
# the studio only tells the friend where to do that. A usage limit is shown as the plain message
# it is; nothing here retries around it.
#
# Stopping: `TurnControl.cancel` first asks politely (`turn/interrupt`, the app-server answers with
# `turn/completed` status interrupted within milliseconds and stops the command it was running) and
# only then ends the process tree, as for every adapter.
#
# The user's own Codex hooks (`~/.codex/hooks.json`) run in a turn too, as do the folder's own
# (`.codex/hooks.json`, which is where the producer's session-start hook lives); Codex has no way
# to keep only the second kind.
#
# A picture the model makes (the `imageGeneration` item; the tool is called image_gen__imagegen and
# exists on a paid plan only) lands under `<codexHome>/generated_images/<thread>/<item>.png`. The
# adapter copies it into the studio's own folder (`importPicture`) and sends a `ukShot` card.

import std/[json, os, osproc, streams, strutils, tables, sets, times, locks]
import agent
import agentjson
import nimutil
import studioshot

const
  testedCodexVersion* = "0.159.2"
  installUrl* = "https://developers.openai.com/codex/cli"
  maxHelperText = 400
  maxStray = 12 ## unparseable lines kept for the "details" of a crash
  nearLimitPercent = 90
  exitWaitMs = 5000 ## how long the app-server gets to end once its standard input is closed
  interruptRequestId = 1_000_000
  costSentence* = "Talking to Codex uses your own ChatGPT plan or OpenAI API credit. The studio only starts the codex program on this computer; it never sees or keeps your login."
  aboutSentence* = "Works on a ChatGPT Plus plan, and making pictures is verified there. The free plan has no picture tool. Claude stays the default."

  notInstalledText* = "I can't find the codex program on this computer, so Codex can't chat here yet. " &
    "Install Codex CLI from OpenAI's page (on Windows that is a step for you to do; the studio doesn't install anything), " &
    "sign in once in a terminal, then reload this page."
  notSignedInText* = "Codex isn't signed in. The studio never touches your login, so please do this once yourself: open a terminal, type codex, " &
    "and follow its sign-in (a ChatGPT login or an API key, your choice, made inside codex). " &
    "Then reload this page and send your message again."
  noCreditText* = "Codex says your plan has no usage left for now. Wait for it to reset (your ChatGPT usage page shows when) or add credit, then send your message again."
  busyText* = "Codex is busy or you have reached a rate limit. Wait a little and send your message again."
  contextFullText* = "This Codex conversation got too long to go on. Start a new conversation from the chat's menu; the producer picks the game up again from its notes."
  toolChangedText* = "Codex answered in a way this studio doesn't recognise, so nothing shows here. Codex may have changed. " &
    "Update the studio (git pull, then rebuild para), or keep chatting in your terminal for now."
  partialText* = "Some of what Codex said didn't look the way the studio expects, so parts of this turn may be missing. The studio may need an update."

type
  Stage = enum
    stStart, stInit, stThread, stTurn, stRunning, stEnded

  Helper = object
    role, text, status: string
    tools: int
    finished: bool

  CodexMapper* = object
    root: string          ## the repository root with `/` separators, for words
    workDir: string       ## the repository root as given, for paths we hand out
    text: string          ## what the friend typed
    resumeId: string      ## "" for a new conversation
    stage: Stage
    nextId: int
    pending: Table[int, string] ## request id -> method
    outbox: seq[string]   ## lines still to send; the runner takes them with `takeOutbox`
    codexHome: string
    sessionId*: string    ## the thread id
    turnId*: string
    version*: string
    sawInit*: bool
    completed*: bool      ## `turn/completed` arrived
    status*: string       ## the turn's status then: completed, interrupted or failed
    shapeProblems*: int
    errorEmitted*: bool
    sessionMissing*: bool
    lastErrorInfo, lastErrorMessage: string
    helpers: Table[string, Helper]    ## by the id of the call that started the helper
    threadCard: Table[string, string] ## a helper's thread id -> its card
    told: HashSet[string]             ## items already given an activity line
    refused: HashSet[string]
    resetsAt: int
    nearLimitTold: bool
    stray*: seq[string]

proc newCodexMapper*(root = "", text = "", resumeId = ""): CodexMapper =
  CodexMapper(root: root.replace('\\', '/').strip(leading = false, chars = {'/'}), workDir: root,
              text: text, resumeId: validUuid(resumeId), nextId: 1)

proc validThread*(s: string): string =
  ## `s` when it is shaped like a Codex thread id (a UUID), else "". The id travels inside JSON, not
  ## on a command line, but it is checked to the letter all the same.
  validUuid(s)

# --- wording ----------------------------------------------------------------------

proc relPath(m: CodexMapper, p: string): string =
  let q = p.replace('\\', '/')
  if m.root.len > 0 and q.startsWith(m.root & "/"): q[m.root.len + 1 .. ^1] else: q

proc unquote(s: string): string =
  let t = s.strip
  if t.len >= 2 and t[0] in {'\'', '"'} and t[^1] == t[0]: t[1 ..< t.len - 1] else: t

proc plainCommand*(command: string): string =
  ## What the friend should read for a command: Codex runs everything as `bash -lc '...'`, and the
  ## wrapper is noise (`/usr/bin/bash -lc 'ls -la'` becomes `ls -la`).
  let t = command.strip
  for flag in [" -lc ", " -ic ", " -c "]:
    let at = t.find(flag)
    if at <= 0: continue
    let shell = t[0 ..< at].replace('\\', '/').rsplit('/', 1)[^1].toLowerAscii.replace(".exe", "")
    if shell in ["bash", "sh", "zsh", "dash"]:
      return unquote(t[at + flag.len .. ^1])
  t

proc windowWords(epoch: int): string =
  ## "on Oct 23 at 14:05" in this computer's time.
  if epoch <= 0: return ""
  try:
    fromUnix(epoch).local.format("'on' MMM d 'at' HH:mm")
  except CatchableError:
    ""

proc errorName(info: JsonNode): string =
  ## `codexErrorInfo` is either a plain word ("usageLimitExceeded") or an object with one key
  ## ({"httpConnectionFailed": {...}}).
  if info == nil: return ""
  case info.kind
  of JString: info.getStr
  of JObject:
    for k, _ in info: return k
    ""
  else: ""

proc classifyError*(name, text: string): tuple[code, message: string] =
  ## Codex's own word for what went wrong (`codexErrorInfo`, or the words of the message when it
  ## gave none) to a stable code and plain words for the friend.
  let t = text.toLowerAscii
  if name == "unauthorized" or "not logged in" in t or "log in again" in t or "sign in again" in t or
     "invalid api key" in t:
    return ("not-signed-in", notSignedInText)
  if name == "usageLimitExceeded" or "usage limit" in t or "out of credits" in t or "no credits" in t:
    return ("no-credit", noCreditText)
  if name in ["rateLimitExceeded", "serverOverloaded", "flexUnavailable"] or "rate limit" in t or "overloaded" in t:
    return ("busy", busyText)
  if name in ["contextWindowExceeded", "sessionBudgetExceeded"]:
    return ("conversation-full", contextFullText)
  ("agent-error", "Codex stopped with a problem.")

proc refusalText(what: string): string =
  "The producer wasn't allowed to " & what & ". Ask the producer to do it a different way."

# --- the mapping ------------------------------------------------------------------

proc say(text: string): UiEvent = UiEvent(kind: ukSay, text: text)

proc request(m: var CodexMapper, meth: string, params: JsonNode): string =
  let id = m.nextId
  inc m.nextId
  m.pending[id] = meth
  $(%*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params})

proc notification(meth: string): string =
  $(%*{"jsonrpc": "2.0", "method": meth, "params": {}})

proc reply(id: JsonNode, answer: JsonNode): string =
  $(%*{"jsonrpc": "2.0", "id": id, "result": answer})

proc replyError(id: JsonNode, code: int, message: string): string =
  $(%*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})

proc begin*(m: var CodexMapper): seq[string] =
  ## The first line to send. The rest follow the app-server's answers (`takeOutbox`).
  m.stage = stInit
  @[m.request("initialize", %*{"clientInfo": {"name": "para-studio", "title": "Para Studio", "version": "1"}})]

proc takeOutbox*(m: var CodexMapper): seq[string] =
  result = m.outbox
  m.outbox = @[]

proc interruptLine*(threadId, turnId: string): string =
  $(%*{"jsonrpc": "2.0", "id": interruptRequestId, "method": "turn/interrupt",
       "params": {"threadId": threadId, "turnId": turnId}})

proc itemActivity(m: CodexMapper, item: JsonNode): seq[string] =
  ## Light lines for what an item does; none for items not worth a line.
  case item.str("type")
  of "commandExecution":
    let c = oneLine(plainCommand(item.str("command")), 110)
    if c.len > 0: result.add "Running: " & c
  of "fileChange":
    let changes = item.at("changes")
    if changes != nil and changes.kind == JArray:
      for c in changes:
        let p = oneLine(m.relPath(c.str("path")), 100)
        if p.len > 0 and result.len < 6: result.add "Changing " & p
  of "mcpToolCall":
    let t = oneLine(item.str("tool"), 40)
    if t.len > 0: result.add "Using " & t
  of "webSearch": result.add "Looking something up online"
  of "imageGeneration": result.add "Making a picture"
  else: discard

proc tell(m: var CodexMapper, item: JsonNode): seq[UiEvent] =
  let id = item.str("id")
  if id in m.told: return
  for line in m.itemActivity(item): result.add UiEvent(kind: ukActivity, text: line)
  if id.len > 0 and result.len > 0: m.told.incl id # a file change may only name its files when it completes

proc itemRefusal(m: var CodexMapper, item: JsonNode): seq[UiEvent] =
  let id = item.str("id")
  if id.len > 0:
    if id in m.refused: return
    m.refused.incl id
  var what = "run a command"
  case item.str("type")
  of "commandExecution":
    let c = oneLine(plainCommand(item.str("command")), 100)
    if c.len > 0: what = "run `" & c & "`"
  of "fileChange":
    let lines = m.itemActivity(item)
    what = if lines.len > 0: "change " & lines[0][len("Changing ") .. ^1] else: "change a file"
  else: discard
  @[UiEvent(kind: ukRefused, code: "refused", text: refusalText(what))]

proc cardStatus(codexStatus: string): string =
  case codexStatus
  of "completed": "done"
  of "errored", "notFound": "failed"
  of "interrupted", "shutdown": "stopped"
  else: "working"

proc cardEvent(id: string, h: Helper): UiEvent =
  UiEvent(kind: ukHelper, id: id, role: h.role, status: h.status, text: h.text, tools: h.tools)

proc applyStates(m: var CodexMapper, states: JsonNode): seq[UiEvent] =
  if states == nil or states.kind != JObject: return
  for thread, st in states:
    let card = m.threadCard.getOrDefault(thread)
    if card.len == 0 or card notin m.helpers: continue
    var h = m.helpers[card]
    if h.finished: continue
    let status = cardStatus(st.str("status"))
    if status == h.status: continue
    h.status = status
    h.finished = status != "working"
    if h.finished:
      let said = oneLine(st.str("message"), maxHelperText)
      if said.len > 0: h.text = said
    m.helpers[card] = h
    result.add cardEvent(card, h)

proc onCollab(m: var CodexMapper, item: JsonNode): seq[UiEvent] =
  let id = item.str("id")
  if id.len == 0: return
  if item.str("tool") == "spawnAgent" and id notin m.helpers:
    let prompt = item.str("prompt")
    let h = Helper(role: helperRole("", "", prompt), text: oneLine(prompt, maxHelperText),
                   status: "started", tools: 0)
    m.helpers[id] = h
    result.add cardEvent(id, h)
  if item.str("tool") == "spawnAgent" and id in m.helpers:
    let threads = item.at("receiverThreadIds")
    if threads != nil and threads.kind == JArray:
      for t in threads:
        if t.kind == JString and t.getStr.len > 0: m.threadCard[t.getStr] = id
    if item.str("status") in ["failed", "interrupted"] and not m.helpers[id].finished:
      var h = m.helpers[id]
      h.status = if item.str("status") == "failed": "failed" else: "stopped"
      h.finished = true
      m.helpers[id] = h
      result.add cardEvent(id, h)
  result.add m.applyStates(item.at("agentsStates"))

proc onSubAgentActivity(m: var CodexMapper, item: JsonNode): seq[UiEvent] =
  let card = m.threadCard.getOrDefault(item.str("agentThreadId"))
  if card.len == 0 or card notin m.helpers: return
  var h = m.helpers[card]
  if h.finished: return
  inc h.tools
  h.status = "working"
  m.helpers[card] = h
  result.add cardEvent(card, h)

proc onImage(m: var CodexMapper, item: JsonNode): seq[UiEvent] =
  let failure = item.at("failure")
  if failure != nil and failure.kind == JObject:
    let until = windowWords(failure.at("resetsAt").getInt(0))
    return @[UiEvent(kind: ukNotice, code: "no-credit",
      text: "Codex has no picture credit left on your plan" & (if until.len > 0: " until it resets " & until else: "") &
        ". I won't try again; the picture will have to wait.")]
  let saved = item.str("savedPath")
  if saved.len == 0: return
  let shot = importPicture(m.workDir, saved, m.codexHome / "generated_images")
  if shot.ok: return @[UiEvent(kind: ukShot, text: shot.name)]
  @[UiEvent(kind: ukNotice, code: "picture-not-shown", text: shot.message)]

proc onItem(m: var CodexMapper, e: JsonNode, completed: bool): seq[UiEvent] =
  if e.str("threadId") != m.sessionId: return # a helper's own thread: its card tells the story
  let item = e.at("item")
  if item == nil or item.kind != JObject:
    inc m.shapeProblems
    return
  case item.str("type")
  of "agentMessage":
    if completed:
      let t = item.str("text").strip
      if t.len > 0: result.add say(t)
  of "commandExecution", "fileChange":
    result.add m.tell(item)
    if completed and item.str("status") == "declined": result.add m.itemRefusal(item)
  of "mcpToolCall", "webSearch":
    result.add m.tell(item)
  of "imageGeneration":
    result.add m.tell(item)
    if completed: result.add m.onImage(item)
  of "collabAgentToolCall":
    result.add m.onCollab(item)
  of "subAgentActivity":
    result.add m.onSubAgentActivity(item)
  else: discard # reasoning, the friend's own message, plans, compaction: nothing for the friend

proc failureEvent(m: var CodexMapper, name, message: string): UiEvent =
  let (code, text) = classifyError(name, message)
  m.errorEmitted = true
  var shown = text
  if code == "no-credit" and m.resetsAt > 0:
    let until = windowWords(m.resetsAt)
    if until.len > 0: shown.add " Your plan resets " & until & "."
  UiEvent(kind: ukError, code: code, text: shown, url: installUrl,
          detail: if code == "agent-error": oneLine(redactSecrets(message), 300) else: "")

proc onTurnCompleted(m: var CodexMapper, e: JsonNode): seq[UiEvent] =
  let turn = e.at("turn")
  m.completed = true
  m.stage = stEnded
  m.status = turn.str("status")
  if m.status != "failed": return
  let err = turn.at("error")
  var name = err.at("codexErrorInfo").errorName
  var message = err.str("message")
  if message.len == 0:
    name = m.lastErrorInfo
    message = m.lastErrorMessage
  result.add m.failureEvent(name, message)

proc onRateLimits(m: var CodexMapper, limits: JsonNode): seq[UiEvent] =
  var worst = -1
  var resets = 0
  for w in ["primary", "secondary"]:
    let win = limits.at(w)
    let used = win.num(["usedPercent"])
    if used > worst:
      worst = used
      resets = win.num(["resetsAt"])
  if resets > 0 and worst >= nearLimitPercent: m.resetsAt = resets
  if worst >= nearLimitPercent and not m.nearLimitTold:
    m.nearLimitTold = true
    let until = windowWords(resets)
    result.add UiEvent(kind: ukNotice, code: "limit-near",
      text: "Your Codex plan is " & $min(worst, 100) & "% used for this period" &
        (if until.len > 0: ", and it resets " & until else: "") & ". When it runs out, Codex stops and I'll say so.")

proc onNotification(m: var CodexMapper, meth: string, e: JsonNode): seq[UiEvent] =
  let params = e.at("params")
  case meth
  of "turn/started":
    let id = params.str("turn", "id")
    if id.len > 0 and params.str("threadId") == m.sessionId: m.turnId = id
  of "item/started": result = m.onItem(params, false)
  of "item/completed": result = m.onItem(params, true)
  of "turn/completed":
    if params.str("threadId") == m.sessionId: result = m.onTurnCompleted(params)
  of "error":
    if params.str("threadId") == m.sessionId and not params.flag("willRetry"):
      m.lastErrorInfo = params.at("error", "codexErrorInfo").errorName
      m.lastErrorMessage = params.str("error", "message")
  of "account/rateLimits/updated": result = m.onRateLimits(params.at("rateLimits"))
  else: discard # deltas, hooks, token counts, status changes, startup notices: nothing for the friend

proc onServerRequest(m: var CodexMapper, meth: string, id, params: JsonNode): seq[UiEvent] =
  ## The server asked the client something. Approvals are always refused; anything else this adapter
  ## does not know is answered with an error (that includes asking for a login token).
  case meth
  of "item/commandExecution/requestApproval":
    m.outbox.add reply(id, %*{"decision": "decline"})
    let c = oneLine(plainCommand(params.str("command")), 100)
    result.add UiEvent(kind: ukRefused, code: "refused", text: refusalText(if c.len > 0: "run `" & c & "`" else: "run a command"))
  of "item/fileChange/requestApproval":
    m.outbox.add reply(id, %*{"decision": "decline"})
    result.add UiEvent(kind: ukRefused, code: "refused", text: refusalText("change a file"))
  of "item/permissions/requestApproval":
    m.outbox.add reply(id, %*{"permissions": {}, "scope": "turn"})
    result.add UiEvent(kind: ukRefused, code: "refused", text: refusalText("use more access than it was given"))
  of "applyPatchApproval", "execCommandApproval":
    m.outbox.add reply(id, %*{"decision": "denied"})
    result.add UiEvent(kind: ukRefused, code: "refused", text: refusalText("change files or run a command"))
  of "item/tool/requestUserInput":
    m.outbox.add reply(id, %*{"answers": {}})
  else:
    m.outbox.add replyError(id, -32601, "the studio does not handle this request")

proc fail(m: var CodexMapper, name, message: string): seq[UiEvent] =
  m.stage = stEnded
  @[m.failureEvent(name, message)]

proc onResponse(m: var CodexMapper, id: int, e: JsonNode): seq[UiEvent] =
  if id notin m.pending: return # the answer to our interrupt, say
  let meth = m.pending[id]
  m.pending.del id
  let err = e.at("error")
  let isError = err != nil
  let message = err.str("message")
  case meth
  of "initialize":
    if isError: return m.fail("", message)
    m.sawInit = true
    m.codexHome = e.str("result", "codexHome")
    let userAgent = e.str("result", "userAgent") # "para-studio/0.159.2 (Linux ...)"
    let slash = userAgent.find('/')
    if slash >= 0:
      let v = userAgent[slash + 1 .. ^1].splitWhitespace()
      if v.len > 0 and v[0].allCharsInSet({'0'..'9', '.'}): m.version = v[0]
    m.outbox.add notification("initialized")
    let policy = %*{"cwd": m.workDir, "approvalPolicy": "never", "sandbox": "workspace-write"}
    m.stage = stThread
    if m.resumeId.len > 0:
      policy["threadId"] = %m.resumeId
      policy["excludeTurns"] = %true
      m.outbox.add m.request("thread/resume", policy)
    else:
      m.outbox.add m.request("thread/start", policy)
  of "thread/start", "thread/resume":
    if isError:
      let name = err.at("data").errorName
      if meth == "thread/resume" and classifyError(name, message).code == "agent-error":
        m.sessionMissing = true # the adapter starts a fresh conversation; no error for the friend
        m.stage = stEnded
        return
      return m.fail(name, message)
    let thread = validThread(e.str("result", "thread", "id"))
    if thread.len == 0:
      inc m.shapeProblems
      return m.fail("", "no thread id")
    m.sessionId = thread
    m.stage = stTurn
    m.outbox.add m.request("turn/start", %*{"threadId": thread, "input": [{"type": "text", "text": m.text}]})
  of "turn/start":
    if isError: return m.fail(err.at("data").errorName, message)
    let tid = e.str("result", "turn", "id")
    if tid.len > 0 and m.turnId.len == 0: m.turnId = tid
    if m.stage == stTurn: m.stage = stRunning
  else: discard

proc noteStray(m: var CodexMapper, line: string) =
  ## A line that is not JSON: codex's own log on stderr (the studio reads both together). Kept for
  ## the details of a crash.
  let t = oneLine(line, 300)
  if t.len == 0: return
  if m.stray.len >= maxStray: m.stray.delete(0)
  m.stray.add t

proc mapLine*(m: var CodexMapper, line: string): seq[UiEvent] =
  ## One output line of `codex app-server` to zero or more events; lines to send back collect in the
  ## outbox. Never raises: a line that is not JSON is kept as a stray line, a message nobody knows
  ## is ignored, a message of a known kind with the wrong shape is skipped (and counted in
  ## `shapeProblems`).
  let t = line.strip
  if t.len == 0: return
  var e: JsonNode
  try:
    e = parseJson(t)
  except CatchableError:
    m.noteStray(t)
    return
  if e.kind != JObject:
    m.noteStray(t)
    return
  try:
    let meth = e.str("method")
    let id = e.at("id")
    if meth.len > 0 and id != nil: result = m.onServerRequest(meth, id, e.at("params"))
    elif meth.len > 0: result = m.onNotification(meth, e)
    elif id != nil and id.kind == JInt: result = m.onResponse(id.getInt, e)
  except CatchableError:
    inc m.shapeProblems
    result = @[]

proc finish*(m: var CodexMapper, exitCode: int, cancelled: bool): seq[UiEvent] =
  ## What is still to say once the process has ended.
  if cancelled or m.errorEmitted or m.sessionMissing: return
  if not m.completed:
    m.errorEmitted = true
    if exitCode != 0:
      var detail = ""
      if m.stray.len > 0: detail = redactSecrets(m.stray[^1])
      return @[UiEvent(kind: ukError, code: "crashed", detail: detail,
        text: "The producer's tool stopped before it finished (exit code " & $exitCode & "). Your message may not have been handled; you can send it again.")]
    return @[UiEvent(kind: ukError, code: "tool-changed", text: toolChangedText, url: installUrl)]
  if m.shapeProblems > 0:
    return @[UiEvent(kind: ukNotice, code: "partial", text: partialText)]

# --- running codex ----------------------------------------------------------------

proc locate(a: AgentAdapter): string =
  if a.exe.len > 0: a.exe else: findExe("codex")

proc codexDescribe(a: AgentAdapter): AgentInfo =
  result = AgentInfo(name: "codex", label: "Codex", url: installUrl)
  let exe = locate(a)
  if exe.len == 0:
    result.note = notInstalledText
    return
  result.installed = true
  let r = runCaptured(exe, @["--version"], timeoutMs = 8000)
  if r.exitCode == 0:
    let words = r.output.strip.splitWhitespace()
    if words.len > 0 and words[^1].len <= 24 and words[^1].allCharsInSet({'0'..'9', '.'}) and '.' in words[^1]:
      result.version = words[^1]
  if result.version.len == 0:
    result.note = "I couldn't read Codex's version, so I can't tell whether it is one this studio was tested with (" &
      testedCodexVersion & "). Chat may still work."

type
  Link = object
    ## What the thread that stops a turn may touch: the way to write to the app-server and the ids a
    ## polite stop needs. Allocated by hand, shared through `TurnControl`'s soft stop.
    lock: Lock
    input: Stream
    threadId, turnId: string
    interrupted: bool

  Attempt = object
    exitCode: int
    started: bool

proc sendLines(link: ptr Link, lines: seq[string]) =
  acquire(link.lock)
  defer: release(link.lock)
  if link.input.isNil: return
  try:
    for l in lines:
      link.input.writeLine(l)
    link.input.flush()
  except IOError, OSError:
    discard # the child already left; its exit code tells the story

proc closeInput(link: ptr Link) =
  acquire(link.lock)
  defer: release(link.lock)
  if link.input.isNil: return
  try: link.input.close()
  except IOError, OSError: discard
  link.input = nil

proc softStop(data: pointer): bool {.nimcall, gcsafe.} =
  ## Called by `TurnControl.cancel` with its lock held: asks the app-server to interrupt the turn.
  {.cast(gcsafe).}:
    let link = cast[ptr Link](data)
    acquire(link.lock)
    defer: release(link.lock)
    if link.input.isNil or link.threadId.len == 0 or link.turnId.len == 0 or link.interrupted: return false
    link.interrupted = true
    try:
      link.input.writeLine(interruptLine(link.threadId, link.turnId))
      link.input.flush()
      result = true
    except IOError, OSError:
      result = false

proc attemptTurn(exe: string, req: TurnRequest, ctl: ptr TurnControl, emit: EmitProc,
                 m: var CodexMapper): Attempt =
  let args = @["app-server", "--listen", "stdio://"]
  if isShim(exe) and not shimSafe(args):
    emit UiEvent(kind: ukError, code: "cannot-start", text: "I couldn't start Codex safely on this computer.")
    return Attempt(exitCode: 1)
  var p: Process
  try:
    p = startProcess(exe, workingDir = req.workDir, args = args, env = childEnv(),
                     options = {poUsePath, poStdErrToStdOut, poDaemon})
  except OSError as e:
    emit UiEvent(kind: ukError, code: "cannot-start",
      text: "I couldn't start Codex: " & oneLine(redactSecrets(e.msg), 200), url: installUrl)
    return Attempt(exitCode: 127)
  result.started = true
  ctl.attach(p.processID)
  let link = create(Link)
  initLock(link.lock)
  link.input = p.inputStream
  ctl.setSoftStop(softStop, link)
  link.sendLines(m.begin())
  var line: string
  var lastSession = ""
  try:
    while p.outputStream.readLine(line):
      for ev in m.mapLine(line):
        emit ev
      link.sendLines(m.takeOutbox())
      if m.sessionId.len > 0 and m.sessionId != lastSession:
        lastSession = m.sessionId
        if not req.onSession.isNil: req.onSession(lastSession)
      if m.sessionId.len > 0 and (link.threadId.len == 0 or m.turnId != link.turnId):
        acquire(link.lock)
        link.threadId = m.sessionId
        link.turnId = m.turnId
        release(link.lock)
      if m.stage == stEnded: break
  except IOError, OSError:
    discard
  # the turn is over (or the child is gone): closing standard input is how the app-server is told to leave
  link.closeInput()
  for _ in 0 ..< exitWaitMs div 100:
    if not p.running: break
    sleep(100)
  if p.running: terminateTree(p.processID, true, descendantsOf(p.processID))
  result.exitCode = p.waitForExit()
  ctl.markExited()
  ctl.clearSoftStop() # after this `cancel` can no longer reach `link`
  link.threadId = ""
  link.turnId = ""
  deinitLock(link.lock)
  dealloc(link)
  p.close()

proc codexRunTurn(a: AgentAdapter, req: TurnRequest, ctl: ptr TurnControl, emit: EmitProc): TurnResult =
  let exe = locate(a)
  if exe.len == 0:
    emit UiEvent(kind: ukError, code: "not-installed", text: notInstalledText, url: installUrl)
    return TurnResult(exitCode: 127)
  var session = validThread(req.sessionId)
  for attempt in 0 .. 1:
    var m = newCodexMapper(req.workDir, req.text, session)
    let r = attemptTurn(exe, req, ctl, emit, m)
    result.exitCode = r.exitCode
    result.sessionId = if m.sessionId.len > 0: m.sessionId else: session
    result.cancelled = ctl.isCancelled
    if m.sessionMissing and session.len > 0 and not result.cancelled and attempt == 0:
      emit UiEvent(kind: ukNotice, code: "fresh-start",
        text: "Codex couldn't find the earlier conversation, so this starts a new one. The producer will pick the game up from its notes.")
      session = ""
      continue
    if r.started:
      for ev in m.finish(r.exitCode, result.cancelled): emit ev
    result.ok = r.started and not result.cancelled and m.completed and m.status == "completed" and
                not m.errorEmitted
    return

proc newCodexAdapter*(exe = ""): AgentAdapter =
  ## `exe` is for tests (a stand-in program); left out, `codex` is looked up on PATH each time.
  AgentAdapter(name: "codex", label: "Codex", exe: exe, describe: codexDescribe, runTurn: codexRunTurn,
               cost: costSentence, about: aboutSentence)
