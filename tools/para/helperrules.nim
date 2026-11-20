# The rules about a scout helper that need no disk, no process and no clock: what a topic may be
# called, how many helpers may run at once, what a status line says, and what the three counters
# that watch a helper (wall-clock timeout, output silence, tool-call budget) allow.
#
# Two programs use them and must agree, so they live here and nowhere else: `para helper`
# (helpers.nim and helpercmd.nim, which also own the files and the child processes) and the studio's
# desk (studiodesk.nim, a pure core that may not import either of those). tests/test_para_helpers.nim
# holds both to this file.

import std/strutils

const
  helperRoles* = ["scout"] ## the roles `para helper` starts; the builder and the checker stay in the producer's own turn
  maxLiveHelpers* = 3 ## helpers running at once, all games together: each is a whole agent program on a small computer
  maxTopicChars* = 40
  maxBriefChars* = 2000
  maxTouchedKept* = 20 ## files named in a record when files besides the report changed
  defaultTimeoutSec* = 15 * 60 ## the first counter: wall clock from the start
  defaultSilenceSec* = 5 * 60 ## the second: no output the studio understands for this long
  defaultToolBudget* = 80 ## the third: tool calls
  beatSeconds* = 30 ## a working helper's status line is rewritten at least this often
  lostAfterSeconds* = 4 * beatSeconds ## a working line older than this belongs to a helper that is gone

type
  Limits* = object
    ## The three counters. After any one trips, the helper is stopped and reported, never started again.
    timeoutSec*, silenceSec*, toolBudget*: int

  StatusLine* = object
    ## What a helper's one status line says (`working [at=1795155935] [tools=7]: reading rules.nim`).
    state*: string ## working, done, failed or stopped; "" for a line that is not one
    at*: int64
    tools*: int ## -1 when the line does not say
    why*: string ## "" or a short word: timeout, silent, budget, agent-error, no-report, touched-files, lost
    text*: string

const
  defaultLimits* = Limits(timeoutSec: defaultTimeoutSec, silenceSec: defaultSilenceSec, toolBudget: defaultToolBudget)
  statesEnded* = ["done", "failed", "stopped"]

func goodTopic*(topic: string): bool =
  ## A report's name: small letters, digits, `-` and `_`, starting with a letter. It goes into a path,
  ## so nothing else gets in.
  topic.len in 1 .. maxTopicChars and topic[0] in {'a'..'z'} and
    topic.allCharsInSet({'a'..'z', '0'..'9', '_', '-'})

func goodHelperId*(id: string): bool =
  ## `scout`, `scout2`, ...: a role and a number, like a lane's id.
  var n = id.len
  while n > 0 and id[n - 1] in Digits: dec n
  id[0 ..< n] in helperRoles and (n == id.len or (id.len - n <= 4 and id[n] != '0'))

func roleOfHelper*(id: string): string =
  var n = id.len
  while n > 0 and id[n - 1] in Digits: dec n
  id[0 ..< n]

func validBrief*(brief: string): string =
  ## "" when `brief` can be given to a helper, else the plain reason it cannot.
  if brief.strip.len == 0: return "Say what the helper should find out (--ticket \"...\")."
  if brief.len > maxBriefChars:
    return "That question is too long (up to " & $maxBriefChars & " characters). Shorten it."
  for ch in brief:
    if ch == '\0' or (ch < ' ' and ch notin {'\n', '\r', '\t'}):
      return "That question has a character a helper cannot be given."

func reportPath*(game, topic: string): string =
  ## Where the helper writes, from the repository root, spelled the way git and the prompt do.
  "games/" & game & "/reports/" & topic & ".md"

func topicKey*(game, topic: string): string = game & "/" & topic

func startRefusal*(role, topic, brief: string, liveCount: int, liveTopics: openArray[string],
                   game: string): tuple[code, message: string] =
  ## Why a helper may not start now: `code` is "" when it may. `liveCount` is how many helpers run now
  ## (all games), `liveTopics` their `topicKey`s; the caller looked them up.
  if role notin helperRoles:
    return ("badRole", "Only a scout can be started this way (" & helperRoles.join(", ") &
      "); the builder and the checker work inside the producer's own turn.")
  if not goodTopic(topic):
    return ("badTopic", "A report's name uses only small letters, digits, - and _, starts with a letter, and is at most " &
      $maxTopicChars & " characters. For example: story")
  let problem = validBrief(brief)
  if problem.len > 0: return ("badBrief", problem)
  if topicKey(game, topic) in liveTopics:
    return ("topicTaken", "A scout is already writing games/" & game & "/reports/" & topic &
      ".md. Wait for it, stop it, or pick another topic name.")
  if liveCount >= maxLiveHelpers:
    return ("tooMany", $liveCount & " helpers are working already, and more at once would be too much for this computer. Wait for one to finish, or stop one.")

# --- the status line -------------------------------------------------------------------------

func statusText*(s: StatusLine): string =
  ## One line, firstmate-shaped: `<state> [at=<epoch>] [tools=<n>] [why=<word>]: <text>`.
  result = s.state & " [at=" & $s.at & "]"
  if s.tools >= 0: result.add " [tools=" & $s.tools & "]"
  if s.why.len > 0: result.add " [why=" & s.why & "]"
  var t = ""
  for c in s.text:
    t.add(if c < ' ' or c == '\x7f': ' ' else: c)
  t = t.strip
  if t.len > 160: t = t[0 ..< 160].strip(leading = false) & "…"
  result.add ": " & t

func parseStatus*(text: string): StatusLine =
  ## Never raises; a line that is not a status line is `state: ""`.
  result = StatusLine(tools: -1)
  let line = text.strip.splitLines()[0].strip
  let sp = line.find(' ')
  if sp <= 0: return
  let state = line[0 ..< sp]
  if state notin ["working", "done", "failed", "stopped"]: return
  result.state = state
  var rest = line[sp + 1 .. ^1]
  while rest.startsWith("["):
    let close = rest.find(']')
    if close < 0: break
    let tag = rest[1 ..< close]
    let eq = tag.find('=')
    if eq > 0:
      let key = tag[0 ..< eq]
      let val = tag[eq + 1 .. ^1]
      try:
        case key
        of "at": result.at = parseBiggestInt(val)
        of "tools": result.tools = parseInt(val)
        of "why": result.why = val
        else: discard
      except ValueError: discard
    rest = rest[close + 1 .. ^1].strip(leading = true)
  if rest.startsWith(":"): result.text = rest[1 .. ^1].strip

func effectiveState*(s: StatusLine, now: int64): string =
  ## What a reader should say: the line's own state, except that a `working` line nobody has
  ## refreshed for `lostAfterSeconds` belongs to a helper that is gone (`lost`), and no line at all
  ## is `unknown`.
  if s.state.len == 0: "unknown"
  elif s.state == "working" and now - s.at > lostAfterSeconds: "lost"
  else: s.state

# --- the three counters ----------------------------------------------------------------------

type
  Watch* = object
    ## The counters, with no clock of its own: every call says what time it is, so a test drives it
    ## with numbers and nothing waits. The first counter to trip stays tripped.
    limits*: Limits
    startedAt*, lastOutputAt*: float
    tools*: int
    verdict*: string ## "", "timeout", "silent" or "budget"

func initWatch*(limits: Limits, now: float): Watch =
  Watch(limits: limits, startedAt: now, lastOutputAt: now)

func check(w: var Watch, now: float) =
  if w.verdict.len > 0: return
  if w.limits.toolBudget > 0 and w.tools > w.limits.toolBudget: w.verdict = "budget"
  elif w.limits.timeoutSec > 0 and now - w.startedAt > w.limits.timeoutSec.float: w.verdict = "timeout"
  elif w.limits.silenceSec > 0 and now - w.lastOutputAt > w.limits.silenceSec.float: w.verdict = "silent"

func sawOutput*(w: var Watch, now: float, toolCalls = 0): string =
  ## The helper produced output (and, in it, `toolCalls` tool calls). Output counts as output even when it
  ## arrives past a limit: the limits are looked at first, so a late event does not forgive a silence.
  w.check(now)
  if w.verdict.len == 0:
    w.lastOutputAt = now
    w.tools += toolCalls
    w.check(now)
  w.verdict

func tick*(w: var Watch, now: float): string =
  ## Time passed with no output: the timeout and the silence are looked at. The verdict, "" while fine.
  w.check(now)
  w.verdict

# --- saying it in words ---------------------------------------------------------------------

func whyWords*(why: string): string =
  ## A status line's `why` for the producer, in plain words.
  case why
  of "timeout": "took too long"
  of "silent": "went quiet"
  of "budget": "used up its tool calls"
  of "agent-error": "the agent stopped with a problem"
  of "no-report": "ended without writing its report"
  of "touched-files": "files besides its report changed while it ran (its, or yours)"
  of "lost": "disappeared before it finished (the computer or the studio closed?)"
  of "": ""
  else: "ended without finishing" # a word nobody here wrote is never repeated
