# The Play button of `para studio`: build the game with its dev channel in, open the game's NATIVE
# window as a separate program the studio owns, say in plain words how that is going, and stop it
# again. One game window at a time; a second Play restarts it. The web build is never used here, so
# nothing beyond what building a game already needs (Nim and a C compiler) is required.
#
# What runs, for the game `mygame` (all in the repository root, as the friend's terminal would):
#
#   nim c -d:dev --out:tmp/studio/play/mygame games/mygame/mygame.nim                (the build)
#   tmp/studio/play/mygame                                                            (the window)
#
# `-d:dev` is what puts the control channel in the game (paraloop/dev: `tmp/dev.sock`, or on
# Windows a loopback port written to that same path), which is how this file asks "are you up?"
# (`pingGame`, the request `para live status` makes) and how studioshot.nim asks for a picture. The
# binary goes in its own folder, so it never overwrites the `tmp/<game>` that `para build` makes,
# and the compiler keeps the nimcache of a terminal `nim c -r -d:dev` run, so the two warm each other.
#
# Both programs are started with an argument list (no shell, nothing quoted by hand), as their own
# process group (POSIX) or without a console window (Windows), and their output is read into a few
# hundred lines of memory only: it is how a closed window is told apart from a missing display or a
# missing graphics driver, and the studio writes no log file. Stopping ends the program and
# everything it started: a signal to the group on POSIX, `taskkill /T` on Windows (agent.nim's
# `TurnControl`, the same code that stops a chat turn). No unix signal is used on Windows, and
# nothing here runs through `sh -c` or `cmd /c`.
#
# What the window IS (idle, building, starting, running, failed or exited, and for which run) is not
# kept here: it is the desk's `PlayWindow` view (studiodesk.nim), so every "may this start" (Play while
# a step runs, a step while Play builds, a picture of another game's window, Stop with nothing to stop)
# is one rule in one place. This file is the shell around it:
#
#   - `PlayRunner`, the desk's processor, calls `playOpen` when Play was accepted and `playStop` when
#     Stop was pressed. Both run inside the command, under the studio's ONE lock (`studiochat.nim`'s
#     `ChatState.lock`; this file has no lock of its own), so they only start a thread or hand a stop
#     on, and never wait: ending a program waits a few seconds for it to go, so that is a small thread
#     of its own (`stopMain`).
#   - one thread runs one Play run from the build to the window's exit (`playMain`) and reports back
#     with the commands `PlayPhase` and `EndPlay`, which the desk refuses (`staleRun`) once another
#     Play has replaced the run. A second Play therefore starts at once: its thread first waits (it,
#     not the lock) until the older runs' threads have ended, so the program being replaced is gone
#     before the build overwrites it (Windows will not overwrite a running program).
#   - what is kept here is what the desk must not hold: each run's output lines, its programs'
#     controls and its threads. They are guarded by the studio's one lock too.
#   - the page's poll (`playView`) reads the desk's answer, adds the build's latest `CC:` line and
#     pings the game, and tells the desk when the window has started answering (or has not, in time).

import std/[os, osproc, streams, strutils, times, sequtils]
import agent
import devclient
import nimutil
import studiochat
import studiodesk
import studioshot

const
  maxLines = 300
  maxLineChars = 400
  maxDetailLines = 8
  pingMs = 1000
  stopWaitSeconds = 15.0 ## how long a stop, a second Play or the studio closing waits for a run's thread to finish before giving up on it

var startWaitSeconds* = 45.0 ## a started window that has not answered by now is shown as open but not answering (a var so a test can shorten it)

type
  PlayLaunch* = object
    buildExe*: string ## "" = nothing to build first
    buildArgs*: seq[string]
    gameExe*: string
    gameArgs*: seq[string]

  Planner* = proc (root, game: string): PlayLaunch {.nimcall, gcsafe.}
    ## What to run for `game`. The studio uses `defaultPlan`; a test passes a stand-in.

  Play* = object
    chat: ptr ChatState ## the desk, and its ONE lock
    root: string
    planner: Planner
    runs: seq[ptr PlayRun] ## the runs whose threads or controls are not freed yet, oldest first (under the lock)

  PlayRun = object
    play: ptr Play
    id: int ## the run's number, the desk's `PlayStarted.run`
    game: string
    plan: PlayLaunch
    lines: seq[string]
    ctl: ptr TurnControl ## the program running now (the build, then the window); nil between them and after the end
    ctls: seq[ptr TurnControl]
    startedAt: float ## when the window was launched
    stopRequested: bool
    done: bool ## the thread's last act: nothing of this run is left running but the thread's exit
    started: bool ## the thread was started
    thread: Thread[ptr PlayRun]
    stopper: Thread[ptr PlayRun]
    stopperStarted: bool
    stopperDone: bool

  PlayView* = object
    state*: string ## idle, building, starting, running, failed or exited
    game*: string
    run*: int
    message*: string ## a plain sentence for the page; "" when there is nothing to say
    code*: string ## a short stable word when something went wrong
    detail*: string ## the few lines that say what went wrong, redacted
    progress*: string ## while building: the latest `CC: <module>` line, "" before the C compiler starts
    live*: bool ## the window answered a ping just now

template locked(play: ptr Play, body: untyped) =
  lockDesk(play.chat)
  try:
    body
  finally:
    unlockDesk(play.chat)

# --- what to run -----------------------------------------------------------------

proc playBinary*(root, game: string): string =
  root / "tmp" / "studio" / "play" / addFileExt(game, ExeExt)

proc defaultPlan*(root, game: string): PlayLaunch =
  let exe = playBinary(root, game)
  PlayLaunch(buildExe: "nim",
             # no hints except `CC: <module>`, one line per file as the C compiler works: the page's progress
             buildArgs: @["c", "--hints:on", "--hint:all:off", "--hint:CC:on", "-d:dev", "--out:" & exe,
                          "games" / game / (game & ".nim")],
             gameExe: exe)

# --- saying what went wrong, in plain words ----------------------------------------

proc tailText(lines: seq[string], n: int): string =
  let from0 = max(0, lines.len - n)
  lines[from0 .. ^1].mapIt(redactSecrets(it)).join("\n")

proc classifyBuildFailure*(lines: seq[string], couldNotStart: bool): tuple[code, message, detail: string] =
  ## Why a build that did not succeed did not, and what the friend can do.
  let output = lines.join("\n")
  let low = output.toLowerAscii
  if couldNotStart:
    return ("no-nim", "I could not find Nim, the program that builds the game. Make sure `nim --version` works in the terminal you started the studio from, then press Play again.",
            tailText(lines, 2))
  let errors = parseNimDiagnostics(output).filterIt(it.severity == "Error")
  if errors.len == 0 and ("external compiler" in low or "execution of an external program failed" in low) and
     ("not found" in low or "no such file" in low or "not recognized" in low or "cannot find" in low or "could not find" in low):
    return ("no-compiler", "Nim could not find a C compiler to build the game with. Install one (the setup steps in the README say which for your computer), then press Play again.",
            tailText(lines, maxDetailLines))
  var detail = errors[0 ..< min(errors.len, 3)].mapIt(redactSecrets(it.at & ": " & it.msg)).join("\n")
  if detail.len == 0: detail = tailText(lines, maxDetailLines)
  ("build", "The game did not build, so there is no window to open. Ask the producer to fix it, then press Play again.", detail)

proc displayEnvMissing*(): bool =
  ## On Linux and the BSDs a window needs DISPLAY (X11) or WAYLAND_DISPLAY; with neither set there
  ## is no screen to open one on. Windows and macOS always have one.
  when defined(linux) or defined(bsd):
    getEnv("DISPLAY").len == 0 and getEnv("WAYLAND_DISPLAY").len == 0
  else:
    false

const noDisplayMessage = "The game could not open its window because this computer has no screen for it to use (no display). If you are connected from another computer, run the studio on the computer in front of you."

proc classifyGameExit*(lines: seq[string], exitCode: int, wasStarting: bool,
                       noDisplayEnv = false): tuple[code, message, detail: string] =
  ## Why the game window's program ended, and what the friend can do. `wasStarting`: it ended before
  ## it ever answered the studio. `noDisplayEnv`: this computer has no DISPLAY (see `displayEnvMissing`).
  ## The engine quits with -1 and no words when GLFW cannot make a window (`paraloop/app.run`), so a
  ## silent exit like that is told apart by what is known about the screen, not by its output.
  let low = lines.join("\n").toLowerAscii
  let detail = tailText(lines, maxDetailLines)
  if wasStarting:
    for cue in ["cannot open display", "failed to open display", "display environment variable", "x11: the display",
                "no display", "failed to connect to the display", "wayland: failed to connect", "xopendisplay"]:
      if cue in low:
        return ("no-display", noDisplayMessage, detail)
    for cue in ["wgl:", "glx:", "egl:", "opengl", "glfw", "pixel format", "glxfbconfig"]:
      if cue in low:
        return ("no-graphics", "Your computer could not open the game window. This is usually a graphics or display problem: the game could not start OpenGL, the part of your graphics that games use. Update your graphics driver and press Play again. On a virtual machine this is common and is not a bug in your game; docs/windows-first-game.md explains. If it keeps happening, send the captain this message and the lines under Show the details.", detail)
    if exitCode in [255, -1, 4294967295]:
      if noDisplayEnv: return ("no-display", noDisplayMessage, detail)
      return ("no-window", "Your computer could not open the game window. This is usually a graphics or display problem: the game stopped before its window opened and said nothing, which almost always means no screen is available to it, or the graphics driver does not support OpenGL 3.3, which the game needs. Update your graphics driver, or if you are on a virtual machine or a remote connection, run the studio on a computer with a real screen; docs/windows-first-game.md explains. If it keeps happening, send the captain this message and the lines under Show the details.", detail)
    if exitCode == 0:
      return ("closed-early", "The game window closed before the studio could talk to it. Press Play to open it again.", detail)
    return ("crashed", "The game stopped by itself before its window was ready (it ended with code " & $exitCode &
            "). Tell the producer; the lines below are the last thing it printed.", detail)
  if exitCode == 0:
    return ("closed", "The game window was closed.", "")
  ("crashed-later", "The game window closed unexpectedly (the program ended with code " & $exitCode &
   "). Tell the producer what you were doing; the lines below are the last thing it printed.", detail)

# --- the state -------------------------------------------------------------------

proc cleanLine(line: string): string =
  for c in line:
    if result.len >= maxLineChars: break
    if c >= ' ' and c != '\x7f': result.add c
    elif c == '\t': result.add ' '

proc addLine(run: ptr PlayRun, line: string) =
  let clean = cleanLine(line)
  locked(run.play):
    run.lines.add clean
    if run.lines.len > maxLines: run.lines = run.lines[run.lines.len - maxLines .. ^1]

proc runOf(play: ptr Play, id: int): ptr PlayRun =
  ## Called with the lock held.
  for r in play.runs:
    if r.id == id: return r

# --- the thread ------------------------------------------------------------------

type Child = object
  started: bool
  code: int

proc runChild(run: ptr PlayRun, exe: string, args: seq[string], ctl: ptr TurnControl, onStarted: bool): Child =
  ## Starts `exe` in the repository root, reads its output into the line buffer until it ends, and
  ## waits for it. `onStarted`: the window phase, so the clock for "not answering" starts.
  var p: Process
  try:
    p = startLocked(exe, workingDir = run.play.root, args = args, options = {poUsePath, poStdErrToStdOut, poDaemon})
  except OSError as e:
    run.addLine "cannot run " & exe & ": " & e.msg
    return Child(started: false, code: 127)
  result.started = true
  ctl.attach(p.processID)
  if onStarted:
    locked(run.play):
      run.startedAt = epochTime()
  var line: string
  try:
    while p.outputStream.readLine(line): run.addLine line
  except IOError, OSError:
    discard # the program is gone; its exit code tells the story
  result.code = p.waitForExit()
  ctl.markExited()
  p.close()

proc wasStopped(run: ptr PlayRun): bool =
  locked(run.play):
    result = run.stopRequested

proc endRun(run: ptr PlayRun, code, message, detail: string) =
  ## The run's end, told to the desk: the code decides whether the window shows idle, exited or
  ## failed. The desk refuses it when another Play has replaced this run, and that is fine.
  locked(run.play):
    run.ctl = nil
    discard endPlayLocked(run.play.chat, run.id, code, message, detail)

proc finishStopped(run: ptr PlayRun) =
  endRun(run, "", "The game was stopped.", "")

proc waitForEarlier(run: ptr PlayRun): string =
  ## A second Play replaced older runs; this run's thread (never the lock) waits until their threads
  ## are done, so a program being replaced is gone before the build writes over it. "go", "stopped"
  ## (this run was stopped meanwhile) or "stuck" (an older run did not end in time).
  let until = epochTime() + stopWaitSeconds
  while true:
    var clear = true
    var stopped = false
    locked(run.play):
      stopped = run.stopRequested
      for r in run.play.runs:
        if r.id < run.id and not r.done: clear = false
    if stopped: return "stopped"
    if clear: return "go"
    if epochTime() > until: return "stuck"
    sleep(20)

proc playRun(run: ptr PlayRun) =
  let play = run.play
  var ctl: ptr TurnControl
  case waitForEarlier(run)
  of "stopped":
    finishStopped(run)
    return
  of "stuck":
    endRun(run, "restart", "The studio could not close the game window it opened before. Close that window yourself, then press Play again.", "")
    return
  else: discard
  let plan = run.plan
  locked(play):
    ctl = run.ctl

  if plan.buildExe.len > 0:
    try: createDir(plan.gameExe.parentDir)
    except OSError: discard
    let built = runChild(run, plan.buildExe, plan.buildArgs, ctl, false)
    if wasStopped(run):
      finishStopped(run)
      return
    if not built.started or built.code != 0:
      var lines: seq[string]
      locked(play):
        lines = run.lines
      let why = classifyBuildFailure(lines, not built.started)
      # the compiler spells paths out in full; the friend knows the game by its folder
      let shortDetail = why.detail.replace(play.root & "/", "").replace(play.root & "\\", "")
      endRun(run, why.code, why.message, shortDetail)
      return

  if not fileExists(plan.gameExe):
    endRun(run, "no-program",
      "The build said it worked, but the game program is not where the studio expects it. Press Play again; if it still happens, tell the producer.", "")
    return

  var stopped = false
  locked(play):
    if run.stopRequested:
      stopped = true
    else:
      ctl = newTurnControl() # the window's own control: the build's has already seen its program exit
      run.ctls.add ctl
      run.ctl = ctl
      run.lines = @[]
      run.startedAt = epochTime()
      discard phasePlayLocked(play.chat, run.id, "starting", playOpeningMessage, "")
  if stopped:
    finishStopped(run)
    return

  let ran = runChild(run, plan.gameExe, plan.gameArgs, ctl, true)
  if wasStopped(run):
    finishStopped(run)
    return
  var lines: seq[string]
  var wasStarting: bool
  locked(play):
    lines = run.lines
    # still "starting" only if nothing has answered and it ended soon enough to be a failed start
    let w = windowLocked(play.chat)
    wasStarting = w.run == run.id and w.state == "starting" and epochTime() - run.startedAt < startWaitSeconds
  if not ran.started:
    endRun(run, "cannot-start",
      "The studio could not start the game program. " & (if lines.len > 0: oneLine(redactSecrets(lines[^1]), 160) else: ""), "")
    return
  let why = classifyGameExit(lines, ran.code, wasStarting, displayEnvMissing())
  endRun(run, why.code, why.message, why.detail)

proc playMain(run: ptr PlayRun) {.thread.} =
  {.cast(gcsafe).}:
    try:
      playRun(run)
    except CatchableError as e:
      endRun(run, "studio-error", "The studio hit a problem while running the game: " & oneLine(redactSecrets(e.msg), 160), "")
  locked(run.play):
    run.done = true # the last act: after this the run's pieces may be freed

proc stopMain(run: ptr PlayRun) {.thread.} =
  ## Ends the program the run has going now. `cancel` waits a few seconds for it to go, which nothing
  ## under the lock may do, so a stop is handed to this thread.
  var ctl: ptr TurnControl
  locked(run.play):
    ctl = run.ctl
  {.cast(gcsafe).}:
    if ctl != nil: ctl.cancel("stop")
  locked(run.play):
    run.stopperDone = true

# --- what the desk's processor calls (the lock is held: start, hand on, never wait) ---------

proc reapLocked(play: ptr Play) =
  ## Joins and frees every run that is over (its thread has made its last act, so a join returns at
  ## once). Called with the lock held.
  var kept: seq[ptr PlayRun]
  for r in play.runs:
    if r.done and (not r.stopperStarted or r.stopperDone):
      if r.started: joinThread(r.thread)
      if r.stopperStarted: joinThread(r.stopper)
      for c in r.ctls: freeTurnControl(c)
      reset(r.lines)
      reset(r.ctls)
      reset(r.plan)
      reset(r.game)
      dealloc(r)
    else:
      kept.add r
  play.runs = kept

proc haltLocked(run: ptr PlayRun) =
  ## Asks a run to end: its thread sees the flag between its two programs, and the stopper thread
  ## ends the program that is going now. Called with the lock held.
  if run.done or run.stopRequested: return
  run.stopRequested = true
  try:
    createThread(run.stopper, stopMain, run)
    run.stopperStarted = true
  except CatchableError:
    discard # the flag alone still ends the run between its programs

proc playOpen(data: pointer, e: PlayStarted): string {.nimcall, gcsafe.} =
  ## Play was accepted: end the run that is open (a second Play restarts), and start this run's
  ## thread. Answers the phase the run is in: "building", "starting" (nothing to build) or "" (it
  ## did not start).
  let play = cast[ptr Play](data)
  play.reapLocked()
  for r in play.runs: haltLocked(r)
  let r = create(PlayRun)
  r.play = play
  r.id = e.run
  r.game = e.game
  try:
    r.plan = play.planner(play.root, e.game)
  except CatchableError:
    dealloc(r)
    return ""
  r.ctl = newTurnControl()
  r.ctls.add r.ctl
  r.startedAt = epochTime()
  play.runs.add r
  try:
    createThread(r.thread, playMain, r)
    r.started = true
  except CatchableError:
    r.done = true # reaped with the next Play
    return ""
  if r.plan.buildExe.len > 0: "building" else: "starting"

proc playStop(data: pointer, e: PlayStopRequested): bool {.nimcall, gcsafe.} =
  ## Stop was pressed: hand it on to the run. False when no run is left to end it.
  let play = cast[ptr Play](data)
  let r = play.runOf(e.run)
  if r == nil or r.done: return false
  haltLocked(r)
  true

proc initPlay*(play: ptr Play, chat: ptr ChatState, root: string, planner: Planner) =
  ## Tells the desk's processor PlayRunner how to start and stop a run (its two hooks, kept in the
  ## chat state; the processor reaches them through the desk's `hands`).
  play.chat = chat
  play.root = root
  play.planner = planner
  chat.setPlay(PlayHooks(data: play, open: playOpen, stop: playStop))

# --- stop, shutdown ------------------------------------------------------------------

proc stopPlay*(play: ptr Play): bool =
  ## True when a build or a window was running and has been ended: the desk takes the request, its
  ## processor hands it on, and this call (not the lock) waits until the window is no longer
  ## building, starting or running, so the page sees "idle" as soon as the stop returns.
  if not askStopPlay(play.chat): return false
  let until = epochTime() + stopWaitSeconds
  while epochTime() < until:
    if window(play.chat).state notin ["building", "starting", "running"]: break
    sleep(20)
  true

proc shutdownPlay*(play: ptr Play) =
  ## The studio is closing: end the build or the window so nothing is left running.
  discard askStopPlay(play.chat)
  let until = epochTime() + stopWaitSeconds
  while epochTime() < until:
    var busy = false
    locked(play):
      for r in play.runs:
        if not r.done or (r.stopperStarted and not r.stopperDone): busy = true
    if not busy: break
    sleep(20)
  locked(play):
    play.reapLocked()
  play.chat.setPlay(PlayHooks())

# --- what the page reads -----------------------------------------------------------

proc pingGame*(root: string): bool =
  ## `para live status`'s question, asked in this process: does a game answer on the channel?
  let sock = channelPath(root)
  if not socketExists(sock): return false
  try:
    sendDevRequest(sock, "ping", pingMs).ok
  except IOError:
    false

proc playView*(play: ptr Play): PlayView =
  ## The desk's answer, the build's latest `CC:` line, and whether the window answers a ping. A
  ## window that starts answering (or does not in time) is told to the desk, which is where "running"
  ## and "not-answering" come from.
  var facts: PlayFacts
  var startedAt: float
  locked(play):
    facts = windowLocked(play.chat)
    let r = play.runOf(facts.run)
    if r != nil:
      startedAt = r.startedAt
      if facts.state == "building":
        for i in countdown(r.lines.high, 0): # the C compiler's latest `CC: <module>` line
          if r.lines[i].startsWith("CC: "):
            result.progress = oneLine(r.lines[i], 120)
            break
  if facts.state in ["starting", "running"] and facts.code != "stopping":
    result.live = pingGame(play.root)
    locked(play):
      let now = windowLocked(play.chat)
      if now.run == facts.run and now.state in ["starting", "running"] and now.code != "stopping":
        if result.live:
          if now.state == "starting" or now.message != playOpenMessage or now.code.len > 0:
            discard phasePlayLocked(play.chat, now.run, "running", playOpenMessage, "")
        elif now.state == "starting" and epochTime() - startedAt > startWaitSeconds:
          discard phasePlayLocked(play.chat, now.run, "running", playNotAnsweringMessage, "not-answering")
        elif now.state == "running" and now.message != playNotAnsweringMessage:
          discard phasePlayLocked(play.chat, now.run, "running", playNotAnsweringMessage, now.code)
      facts = windowLocked(play.chat) # the run may have ended while we pinged: say how it ended
  result.state = facts.state
  result.game = facts.game
  result.run = facts.run
  result.message = facts.message
  result.code = facts.code
  result.detail = facts.detail
