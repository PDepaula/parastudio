# The scout helpers inside `para studio`: the shell around the desk's `Helpers` view and its processor
# HelperRunner (studiodesk.nim), the way studioplay.nim is the shell around the game window.
#
# A helper started here is the same thing `para helper start` makes (helpers.nim: a record and one status
# line under `tmp/helpers/`, one report under `games/<game>/reports/`, the three counters, the read-only
# check), except that its supervisor is a thread of the studio instead of a detached `para` process,
# and the studio's journal, `tmp/studio/studio.jsonl`, tells it as facts: HelperStarted, HelperEnded.
# Nothing else writes that journal; a helper's own files stay plain text at the edge.
#
#   - the desk decides whether a helper may start (a good topic and question, at most `maxLiveHelpers`
#     working in all games, one scout per report): `startHelper` looks the working helpers up on disk
#     (their status lines, so a helper started from a terminal counts) and hands them to the command;
#   - `HelperRunner`, the desk's processor, calls `helperOpen` when the start was accepted and `helperStop`
#     when a stop was asked for. Both run inside the command, under the studio's ONE lock (this file has no
#     lock of its own), so they only start a thread and never wait: ending a helper's agent program waits
#     a few seconds for it to go, so that is a small thread of its own;
#   - one thread supervises one helper (`helperMain`) and hands back the one command its processor's
#     `issues` line lists, EndHelper, with how it ended;
#   - when the studio closes, `shutdownHelpers` stops every helper it still runs. A helper the log
#     shows as working after a restart is ended as `lost` (studiochat.nim's `initChat`).
#
# What this does not do: the producer's own helpers (the builder and the checker, which work inside its
# turn) and a `para helper start` made in a terminal or by the producer. Those leave their files and
# the digest line, but the studio's journal never sees them: the journal has one writer.

import std/[os, tables, times, json]
import agent
import helperrules
import helpers
import studiochat
import studiodesk

const
  stopWaitSeconds = 15.0 ## how long the studio closing waits for a helper's thread to finish

type
  HelperRun = object
    shell: ptr HelperShell
    rec: HelperRecord
    speed: Speed
    ctl: ptr TurnControl
    thread: Thread[ptr HelperRun]
    stopper: Thread[ptr HelperRun]
    started, stopperStarted, stopperDone, done: bool

  Pending = object
    rec: HelperRecord
    speed: Speed

  HelperShell* = object
    chat: ptr ChatState ## the desk, and its ONE lock
    root: string
    adapters: seq[AgentAdapter] ## the agents a helper may use, the default first
    clock: Clock
    tickMs: int
    runs: seq[ptr HelperRun] ## runs whose threads are not joined yet, oldest first (under the lock)
    pending: Table[string, Pending] ## made ready by `startHelper` for the processor, for the length of its command (under the lock)

proc keyOf(game, id: string): string = game & "/" & id

template locked(shell: ptr HelperShell, body: untyped) =
  lockDesk(shell.chat)
  try:
    body
  finally:
    unlockDesk(shell.chat)

proc adapterFor(shell: ptr HelperShell, name: string): AgentAdapter =
  for a in shell.adapters:
    if a.name == name: return a
  shell.adapters[0]

# --- the processor's hands -------------------------------------------------------------------

proc helperMain(r: ptr HelperRun) {.thread.} =
  let shell = r.shell
  var spec: SuperviseSpec
  locked(shell):
    spec = SuperviseSpec(root: shell.root, rec: r.rec, adapter: shell.adapterFor(r.rec.agent), speed: r.speed,
                         clock: shell.clock, tickMs: shell.tickMs)
  var ended: HelperEnd
  {.cast(gcsafe).}:
    ended = superviseHelper(spec, r.ctl)
  locked(shell):
    discard endHelperLocked(shell.chat, r.rec.game, r.rec.id, ended.outcome, ended.why, ended.tools, ended.report)
    r.done = true

proc stopMain(r: ptr HelperRun) {.thread.} =
  ## Ends the helper's agent program. `cancel` waits for it (up to a short grace), so this is a thread
  ## and not the processor, which runs under the lock and may not wait.
  {.cast(gcsafe).}:
    r.ctl.cancel("stop")
  locked(r.shell):
    r.stopperDone = true

proc reapLocked(shell: ptr HelperShell) =
  ## Joins the threads of runs that have ended and frees them. Called with the lock held; a run that has
  ## set `done` (and whose stopper, if it had one, is through) has nothing left to do but leave its
  ## thread, so the join is short.
  var live: seq[ptr HelperRun]
  for r in shell.runs:
    if r.done and (not r.stopperStarted or r.stopperDone):
      if r.started: joinThread(r.thread)
      if r.stopperStarted: joinThread(r.stopper)
      freeTurnControl(r.ctl)
      r.rec = HelperRecord()
      dealloc(r)
    else:
      live.add r
  shell.runs = live

proc runOf(shell: ptr HelperShell, game, id: string): ptr HelperRun =
  for r in shell.runs:
    if r.rec.game == game and r.rec.id == id and not r.done: return r

proc helperOpen(data: pointer, e: HelperStarted): bool {.nimcall, gcsafe.} =
  ## HelperRunner on HelperStarted: writes the helper's record and first status line and starts its
  ## supervisor thread. False when it could not, and the processor then ends the helper as failed.
  ## Lock held; never waits.
  let shell = cast[ptr HelperShell](data)
  let key = keyOf(e.game, e.helper)
  if key notin shell.pending: return true # a fact that did not come from `startHelper` (nothing to run)
  let p = shell.pending[key]
  shell.reapLocked()
  if not beginHelper(shell.root, p.rec, int64(epochTime())): return false
  let r = create(HelperRun)
  r.shell = shell
  r.rec = p.rec
  r.speed = p.speed
  r.ctl = newTurnControl()
  shell.runs.add r
  try:
    createThread(r.thread, helperMain, r)
    r.started = true
  except CatchableError:
    r.done = true # reaped with the next start
    forgetHelper(shell.root, p.rec.game, p.rec.id)
    return false
  true

proc helperStop(data: pointer, e: HelperStopRequested): bool {.nimcall, gcsafe.} =
  ## HelperRunner on HelperStopRequested: has the helper's agent program ended, by a small thread of
  ## its own. False when no run is left to end it. Lock held; never waits.
  let shell = cast[ptr HelperShell](data)
  let r = shell.runOf(e.game, e.helper)
  if r == nil or r.stopperStarted: return r != nil
  try:
    createThread(r.stopper, stopMain, r)
    r.stopperStarted = true
  except CatchableError:
    return false
  true

proc initHelpers*(shell: ptr HelperShell, chat: ptr ChatState, root: string, adapters: seq[AgentAdapter],
                  clock: Clock = nil, tickMs = 0) =
  ## Tells the desk's processor HelperRunner how to start and stop a helper (its two hooks, kept in the
  ## chat state). `clock` and `tickMs` are for tests: the counters' clock and the watchdog's period.
  doAssert adapters.len > 0
  shell.chat = chat
  shell.root = root
  shell.adapters = adapters
  shell.clock = clock
  shell.tickMs = tickMs
  chat.setHelpers(HelperHooks(data: shell, open: helperOpen, stop: helperStop))

# --- asking -----------------------------------------------------------------------------------

type
  HelperStart* = object
    ## The answer to "may this scout start": `started.ok` and the helper's id, or the refusal.
    started*: Started
    id*: string
    report*: string

proc startHelperHeld(shell: ptr HelperShell, game, topic, brief, agentName: string, speed: Speed,
                     limits: Limits): HelperStart =
  ## One scout for `game`. The desk decides; what is accepted is then done by the processor, from the
  ## record made ready here. `agentName` is one of the adapters ("" = the first).
  let now = int64(epochTime())
  let live = liveHelpers(shell.root, now)
  let name = if agentName.len > 0: agentName else: shell.adapters[0].name
  var rec: HelperRecord
  locked(shell):
    rec = planHelper(shell.root, game, "scout", topic, brief, name, $speed, limits, now)
    shell.pending[keyOf(game, rec.id)] = Pending(rec: rec, speed: speed)
  let asked = askStartHelper(shell.chat, game, rec.id, "scout", topic, brief, live.count, live.topics)
  locked(shell):
    shell.pending.del(keyOf(game, rec.id))
  result.started = asked
  if asked.ok:
    result.id = rec.id
    result.report = rec.report

proc startHelper*(shell: ptr HelperShell, game, topic, brief, agentName: string, speed: Speed,
                  limits: Limits): HelperStart =
  ## One start at a time, with `para helper start` too (`withStartLock`): the cap and the id are read, then used.
  var res: HelperStart
  let held = withStartLock(shell.root):
    res = startHelperHeld(shell, game, topic, brief, agentName, speed, limits)
  if not held:
    res.started = Started(status: 503, code: "busy", message: "Another helper is starting just now. Try again in a moment.")
  res

proc stopHelper*(shell: ptr HelperShell, game, id: string): bool =
  ## True when the helper was working and has been told to end (the thread does the ending).
  askStopHelper(shell.chat, game, id)

proc workingCount*(shell: ptr HelperShell): int =
  shell.chat.workingHelpers.len

proc rowsJson*(shell: ptr HelperShell, game: string): JsonNode =
  ## The helpers the studio started for `game`, as the routes tell them: what the desk's view says and
  ## what each one's status line says now (tool calls, and what it is doing or left).
  result = newJArray()
  for r in shell.chat.helperFacts(game).rows:
    let line = readStatus(shell.root, r.game, r.helper)
    result.add %*{"id": r.helper, "role": r.role, "topic": r.topic, "state": r.state, "why": r.why,
                  "stopping": r.stopping, "tools": (if line.tools >= 0: line.tools else: r.tools),
                  "report": reportPath(r.game, r.topic), "text": line.text}

proc shutdownHelpers*(shell: ptr HelperShell) =
  ## The studio is closing: end every helper this studio runs so no agent program is left behind, and
  ## wait (a few seconds at most) for their threads.
  for r in shell.chat.workingHelpers: discard askStopHelper(shell.chat, r.game, r.helper)
  let until = epochTime() + stopWaitSeconds
  while epochTime() < until:
    var busy = false
    locked(shell):
      for r in shell.runs:
        if not r.done: busy = true
    if not busy: break
    sleep(20)
  locked(shell):
    shell.reapLocked()
  shell.chat.setHelpers(HelperHooks())
