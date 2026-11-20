# `para helper`: scout helpers that para itself runs, so they keep working after the producer's turn
# ends and leave a report in `games/<game>/reports/`.
#
# `start` checks the rules (helperrules.nim: a topic, a question, at most `maxLiveHelpers` at once,
# one scout per report), gives the helper its record and status line (helpers.nim), and starts
# `para helper run <game> <id>` as a detached child of its own, which supervises the helper's agent
# program (the same adapters the studio chat uses) until it ends. The command returns as soon as that
# child is started. `list` reads the records and status lines, and `stop` asks a working helper to end
# (a `.stop` file its supervisor looks for; the supervisor ends the agent's whole process tree) or, for
# one that already ended, forgets its record.
#
# `run` is the supervisor's own entry, not for people: it prints nothing (its standard streams are
# pipes nobody reads) and exits when the helper has ended. The builder and the checker never come
# through here.
#
# Every proc takes the repository `root` (empty means the working directory) and a `HelperEnv`, so
# a test drives all of it on a scratch folder with a stand-in agent, a stand-in clock and no child
# process.

import std/[os, osproc, strutils, strformat, times]
when not defined(windows):
  import std/posix
import art/[clihelpers, toon]
import agent
import agents
import helperrules
import helpers
import nimutil
import savepoint

type Run = clihelpers.Run

const
  helperHelp* = "para helper start <game> --for scout --topic NAME --ticket TEXT [--agent claude|codex] [--speed quick|standard|deep]\n" &
    "                  [--timeout MIN] [--silence MIN] [--tools N]\n" &
    "para helper list [--game NAME]\n" &
    "para helper stop <game> <id>\n" &
    "  a helper is the claude or codex program you already use, started by para with one question, that keeps working after\n" &
    "  this command returns and writes one file, games/<game>/reports/<topic>.md (any other changed file in the game fails it); only the scout role is started this way\n" &
    "  (the builder and the checker work inside the producer's own turn, in lanes)\n" &
    "  start  checks the rules, prints the helper's id, its report and its status file, and returns at once; at most " & $maxLiveHelpers &
    " helpers\n" &
    "         work at a time, one per report; the agent is the first of claude, codex that is installed (--agent picks), on the\n" &
    "         quick setting (--speed)\n" &
    "         three counters stop it, then it is reported and never started again: --timeout minutes on the clock (default " &
    $(defaultTimeoutSec div 60) & "),\n" &
    "         --silence minutes with no output (default " & $(defaultSilenceSec div 60) & "), --tools tool calls (default " & $defaultToolBudget & ")\n" &
    "  list   one row per helper: game, id, role, topic, state (working, done, failed, stopped, lost), tool calls, and what it left\n" &
    "  stop   ends a working helper (its report may be missing or partial); on one that already ended, forgets its record and\n" &
    "         status line; never touches a report\n" &
    "  the status line is plain text in tmp/helpers/<game>.<id>.status; a helper may only write its report, and when one ends the\n" &
    "  other files of the game that changed meanwhile are named (they may be your own edits: it is noticed, not enforced)\n"

  timeoutRange = 1 .. 240
  silenceRange = 1 .. 120
  toolsRange = 1 .. 1000

type
  HelperEnv* = object
    ## What the commands need from the world; a test replaces any of it.
    now*: proc (): int64 {.closure, gcsafe.}
    spawn*: proc (root, game, id: string): string {.closure, gcsafe.} ## starts the supervisor; "" or why it could not
    installed*: proc (agent: string): bool {.closure, gcsafe.}
    adapter*: proc (agent: string): AgentAdapter {.closure, gcsafe.}
    clock*: helpers.Clock ## the supervisor's clock; nil = the real one
    tickMs*: int ## the supervisor's watchdog period; 0 = its default
    stopPolls*: int ## how many times `stop` looks for the helper to end before it says it is on its way
    stopPollMs*: int

proc spawnSupervisor(root, game, id: string): string =
  ## `para helper run <game> <id>`, detached: its own session, its streams pipes nobody reads, not waited for.
  try:
    let p = startLocked(getAppFilename(), workingDir = realRoot(root), args = @["helper", "run", game, id],
                        options = {poDaemon})
    p.close()
  except OSError as e:
    return e.msg

proc defaultEnv*(): HelperEnv =
  HelperEnv(
    now: proc (): int64 = int64(epochTime()),
    spawn: spawnSupervisor,
    installed: proc (name: string): bool = adapterNamed(name).describe(adapterNamed(name)).installed,
    adapter: proc (name: string): AgentAdapter = adapterNamed(name),
    stopPolls: 50, stopPollMs: 100)

proc refuse(lines: varargs[string]): Run =
  ## A refusal: exit 1, nothing started.
  result.output = lines.join("\n") & "\n"
  result.code = 1

proc cleanText(s: string, cap: int): string =
  oneLine(redactSecrets(s), cap)

# --- start ------------------------------------------------------------------------------------

proc pickAgent(env: HelperEnv, asked: string): tuple[name, problem: string] =
  if asked.len > 0:
    if asked notin knownAgents: return ("", "there is no agent called \"" & cleanText(asked, 20) & "\" (" & knownAgents.join(", ") & ")")
    return (asked, "")
  for name in knownAgents:
    if env.installed(name): return (name, "")
  (knownAgents[0], "") # none installed: the refusal below names the first

proc startHelperHeld(root: string, env: HelperEnv, game, role, topic, brief, agentFlag, speedFlag: string, limits: Limits): Run =
  if not validGameName(game) or not dirExists(gameDirOf(root, game)):
    return errorOut(&"there is no game called \"{cleanText(game, 40)}\" in {gamesDir}/", @[])
  let now = env.now()
  let live = liveHelpers(root, now)
  let no = startRefusal(role, topic, brief, live.count, live.topics, game)
  if no.code.len > 0: return refuse("not started: " & no.message)
  let (name, problem) = pickAgent(env, agentFlag)
  if problem.len > 0: return errorOut(problem, @[])
  var speed = spQuick
  if speedFlag.len > 0:
    let (ok, sp) = parseSpeed(speedFlag)
    if not ok: return errorOut("--speed is quick, standard or deep", @[])
    speed = sp
  if not env.installed(name):
    return refuse("not started: the " & name & " program is not installed on this computer, so a helper cannot use it",
                  "help: install it, or pick the other agent with --agent")
  let made = prepareHelper(root, game, role, topic, brief, name, $speed, limits, now)
  if not made.ok: return refuse("not started: could not write the helper's record under tmp/helpers/ (is the disk full?)")
  let r = made.rec
  let why = env.spawn(root, game, r.id)
  if why.len > 0:
    discard writeStatus(root, game, r.id, StatusLine(state: "failed", at: now, tools: 0, why: "agent-error",
      text: "could not start: " & cleanText(why, 100)))
    var dead = r
    dead.ended = now
    dead.outcome = "failed"
    dead.why = "agent-error"
    discard writeRecord(root, dead)
    return refuse("not started: " & cleanText(why, 160))
  result.output = &"helper: {r.id}\ngame: {game}\nrole: {role}\ntopic: {topic}\nreport: {r.report}\n" &
    &"status: tmp/helpers/{game}.{r.id}.status\nagent: {name} ({speed})\n" &
    &"limits: {limits.timeoutSec div 60} min, {limits.silenceSec div 60} min without output, {limits.toolBudget} tool calls\n" &
    toonHelp(@["It keeps working after this command returns; `para helper list` says how it is going, and the report appears at " & r.report])

proc startHelper(root: string, env: HelperEnv, game, role, topic, brief, agentFlag, speedFlag: string, limits: Limits): Run =
  ## One start at a time (`withStartLock`): the cap, the topic rule and the id are read and then used.
  var res: Run
  let held = withStartLock(root):
    res = startHelperHeld(root, env, game, role, topic, brief, agentFlag, speedFlag, limits)
  if not held:
    return refuse("not started: another helper is starting just now. Try again in a moment.")
  res

# --- list -------------------------------------------------------------------------------------

proc leftBehind(h: HelperInfo): string =
  case h.state
  of "done": h.rec.report
  of "working": h.line.text
  of "stopped": "stopped on request"
  of "lost": whyWords("lost")
  of "failed":
    let why = if h.rec.why.len > 0: h.rec.why else: h.line.why
    whyWords(why) & (if why == "touched-files" and h.rec.touched.len > 0: ": " & h.rec.touched[0 ..< min(h.rec.touched.len, 3)].join(", ") else: "")
  else: h.line.text

proc listHelpersCmd(root: string, env: HelperEnv, onlyGame: string): Run =
  if onlyGame.len > 0 and (not validGameName(onlyGame) or not dirExists(gameDirOf(root, onlyGame))):
    return errorOut(&"there is no game called \"{cleanText(onlyGame, 40)}\" in {gamesDir}/", @[])
  var rows: seq[seq[string]]
  let all = listHelpers(root, env.now(), onlyGame)
  for h in all:
    let tools = if h.line.tools >= 0: h.line.tools else: h.rec.tools
    rows.add @[h.rec.game, h.rec.id, h.rec.role, h.rec.topic, h.state, $tools, h.leftBehind]
  result.output = toonTable("helpers", ["game", "id", "role", "topic", "state", "tools", "left"], rows)
  if all.len > 0:
    result.output.add toonHelp(@["Stop a working helper, or forget an ended one, with `para helper stop <game> <id>`; reports are in games/<game>/reports/"])

# --- stop -------------------------------------------------------------------------------------

proc stopHelperCmd(root: string, env: HelperEnv, game, id: string): Run =
  if not validGameName(game) or not goodHelperId(id):
    return errorOut("para helper stop needs the game and the helper's id", @["para helper stop <game> <id>"])
  let found = readRecord(root, game, id)
  if not found.found: return refuse(&"there is no helper {id} for {game}")
  let r = found.rec
  let state = block:
    let line = readStatus(root, game, id)
    var s = effectiveState(line, env.now())
    if r.outcome.len > 0 and s in ["working", "lost", "unknown"]: s = r.outcome
    s
  if state != "working":
    forgetHelper(root, game, id)
    let how = if state == "done": "had finished" elif state == "stopped": "was stopped" else: "did not finish"
    return ("forgot helper " & id & " (" & r.topic & "), which " & how & "; its report, if any, is untouched\n", 0)
  try:
    writeFile(stopFile(root, game, id), "stop\n")
  except IOError, OSError:
    return refuse("could not ask the helper to stop (is the disk full?)")
  for _ in 0 ..< max(env.stopPolls, 0):
    if effectiveState(readStatus(root, game, id), env.now()) != "working": break
    sleep(env.stopPollMs)
  let after = readStatus(root, game, id)
  if after.state in statesEnded:
    ("helper " & id & " (" & r.topic & ") " & after.state & "\n", 0)
  else:
    (&"asked helper {id} ({r.topic}) to stop; it ends in a moment (`para helper list` says when)\n", 0)

# --- run (the supervisor's own entry) -----------------------------------------------------------

proc runSupervisor(root: string, env: HelperEnv, game, id: string): Run =
  ## Supervises one helper to its end. Prints nothing: the process that runs this has no terminal.
  if not validGameName(game) or not goodHelperId(id): return ("", 2)
  let found = readRecord(root, game, id)
  if not found.found or found.rec.outcome.len > 0: return ("", 1)
  when not defined(windows):
    # no terminal and no reader: a hangup of the one that started this must not end it, and a write
    # to a pipe nobody reads is an error to ignore, not a death
    discard signal(SIGHUP, SIG_IGN)
    discard signal(SIGPIPE, SIG_IGN)
  let rec = found.rec
  let (ok, speed) = parseSpeed(rec.speed)
  let ctl = newTurnControl()
  defer: freeTurnControl(ctl)
  let spec = SuperviseSpec(root: root, rec: rec, adapter: env.adapter(rec.agent), speed: if ok: speed else: spQuick,
                           clock: env.clock, tickMs: env.tickMs)
  let ended = superviseHelper(spec, ctl)
  ("", if ended.outcome == "done": 0 else: 1)

# --- the command --------------------------------------------------------------------------------

proc parseCount(s: string, range: Slice[int]): int =
  if s.len in 1 .. 4 and s.allCharsInSet(Digits) and parseInt(s) in range: parseInt(s) else: -1

proc runHelperWith*(root: string, env: HelperEnv, args: seq[string]): Run =
  if args.len == 0 or args[0] in ["--help", "-h"]:
    return (helperHelp, 0)
  let sub = args[0]
  var positional: seq[string]
  var role, topic, ticket, gameFlag, agentFlag, speedFlag = ""
  var limits = defaultLimits
  var i = 1
  while i < args.len:
    let a = args[i]
    template value(what: string): string =
      inc i
      if i >= args.len: return errorOut(a & " needs " & what, @[])
      args[i]
    case a
    of "--help", "-h": return (helperHelp, 0)
    of "--for": role = value("a role")
    of "--topic": topic = value("a report name")
    of "--ticket": ticket = value("the question")
    of "--game": gameFlag = value("a name")
    of "--agent": agentFlag = value("claude or codex")
    of "--speed": speedFlag = value("quick, standard or deep")
    of "--timeout":
      let n = parseCount(value("minutes"), timeoutRange)
      if n < 0: return errorOut("--timeout needs a number of minutes from " & $timeoutRange.a & " to " & $timeoutRange.b, @[])
      limits.timeoutSec = n * 60
    of "--silence":
      let n = parseCount(value("minutes"), silenceRange)
      if n < 0: return errorOut("--silence needs a number of minutes from " & $silenceRange.a & " to " & $silenceRange.b, @[])
      limits.silenceSec = n * 60
    of "--tools":
      let n = parseCount(value("a number"), toolsRange)
      if n < 0: return errorOut("--tools needs a number from " & $toolsRange.a & " to " & $toolsRange.b, @[])
      limits.toolBudget = n
    else:
      if a.startsWith("-"):
        return errorOut(&"unknown flag \"{a}\"", @["Run `para helper --help` for the flags of each helper command"])
      positional.add a
    inc i
  case sub
  of "start":
    if positional.len != 1: return errorOut("para helper start needs the game", @["para helper start <game> --for scout --topic NAME --ticket TEXT"])
    if role.len == 0: return errorOut("para helper start needs --for scout", @["Valid roles: " & helperRoles.join(", ")])
    startHelper(root, env, positional[0], role, topic, ticket, agentFlag, speedFlag, limits)
  of "list":
    if positional.len > 0: return errorOut("para helper list takes no names; use --game NAME", @[])
    listHelpersCmd(root, env, gameFlag)
  of "stop":
    if positional.len != 2: return errorOut("para helper stop needs the game and the helper's id", @["para helper stop <game> <id>"])
    stopHelperCmd(root, env, positional[0], positional[1])
  of "run":
    if positional.len != 2: return ("", 2)
    runSupervisor(root, env, positional[0], positional[1])
  else:
    errorOut(&"unknown command \"helper {sub}\"", @["Valid commands: helper start, helper list, helper stop"])

proc runHelper*(args: seq[string]): Run =
  runHelperWith("", defaultEnv(), args)
