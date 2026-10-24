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
# (`ping`, the request `para live status` makes) and how studioshot.nim asks for a picture. The
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
# One thread runs one Play from the build to the window's exit; the HTTP side only reads the state
# (`playView`), which also pings the game to see whether it is answering. The start, stop and
# shutdown calls take `gate`, so two clicks never interleave.

import std/[locks, os, osproc, streams, strutils, times, sequtils]
import agent
import devclient
import nimutil
import studioshot

const
  maxLines = 300
  maxLineChars = 400
  maxDetailLines = 8
  pingMs = 1000
  stopWaitSeconds = 15.0 ## how long a stop waits for the run's thread to finish before giving up on it

var startWaitSeconds* = 45.0 ## a started window that has not answered by now is shown as open but not answering (a var so a test can shorten it)

type
  PlayLaunch* = object
    buildExe*: string ## "" = nothing to build first
    buildArgs*: seq[string]
    gameExe*: string
    gameArgs*: seq[string]

  Planner* = proc (root, game: string): PlayLaunch {.nimcall, gcsafe.}
    ## What to run for `game`. The studio uses `defaultPlan`; a test passes a stand-in.

  PlayPhase = enum
    ppIdle, ppBuilding, ppStarting, ppRunning, ppFailed, ppExited

  Play* = object
    lock: Lock
    gate: Lock ## held by start, stop and shutdown
    root: string
    planner: Planner
    plan: PlayLaunch
    phase: PlayPhase
    game: string
    runId: int
    lines: seq[string]
    code, message, detail: string
    startedAt: float ## when the window was launched
    stopRequested: bool
    active: bool ## the thread has not finished
    ctl: ptr TurnControl
    ctls: seq[ptr TurnControl]
    thread: Thread[ptr Play]
    threadStarted: bool

  PlayView* = object
    state*: string ## idle, building, starting, running, failed or exited
    game*: string
    run*: int
    message*: string ## a plain sentence for the page; "" when there is nothing to say
    code*: string ## a short stable word when something went wrong
    detail*: string ## the few lines that say what went wrong, redacted
    progress*: string ## while building: the latest `CC: <module>` line, "" before the C compiler starts
    live*: bool ## the window answered a ping just now

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

proc addLine(play: ptr Play, line: string) =
  let clean = cleanLine(line)
  acquire(play.lock)
  play.lines.add clean
  if play.lines.len > maxLines: play.lines = play.lines[play.lines.len - maxLines .. ^1]
  release(play.lock)

proc initPlay*(play: ptr Play, root: string, planner: Planner) =
  initLock(play.lock)
  initLock(play.gate)
  play.root = root
  play.planner = planner

proc settle(play: ptr Play, phase: PlayPhase, code, message, detail: string) =
  acquire(play.lock)
  play.phase = phase
  play.code = code
  play.message = message
  play.detail = detail
  play.ctl = nil
  release(play.lock)

# --- the thread ------------------------------------------------------------------

type Child = object
  started: bool
  code: int

proc runChild(play: ptr Play, exe: string, args: seq[string], ctl: ptr TurnControl, onStarted: bool): Child =
  ## Starts `exe` in the repository root, reads its output into the line buffer until it ends, and
  ## waits for it. `onStarted`: the window phase, so the clock for "not answering" starts.
  var p: Process
  try:
    p = startProcess(exe, workingDir = play.root, args = args, options = {poUsePath, poStdErrToStdOut, poDaemon})
  except OSError as e:
    play.addLine "cannot run " & exe & ": " & e.msg
    return Child(started: false, code: 127)
  result.started = true
  ctl.attach(p.processID)
  if onStarted:
    acquire(play.lock)
    play.startedAt = epochTime()
    release(play.lock)
  var line: string
  try:
    while p.outputStream.readLine(line): play.addLine line
  except IOError, OSError:
    discard # the program is gone; its exit code tells the story
  result.code = p.waitForExit()
  ctl.markExited()
  p.close()

proc wasStopped(play: ptr Play): bool =
  acquire(play.lock)
  result = play.stopRequested
  release(play.lock)

proc finishStopped(play: ptr Play) =
  settle(play, ppIdle, "", "The game was stopped.", "")

proc playRun(play: ptr Play) =
  var plan: PlayLaunch
  var ctl: ptr TurnControl
  acquire(play.lock)
  plan = play.plan
  ctl = play.ctl
  release(play.lock)

  if plan.buildExe.len > 0:
    try: createDir(plan.gameExe.parentDir)
    except OSError: discard
    let built = runChild(play, plan.buildExe, plan.buildArgs, ctl, false)
    if wasStopped(play):
      finishStopped(play)
      return
    if not built.started or built.code != 0:
      var lines: seq[string]
      acquire(play.lock)
      lines = play.lines
      release(play.lock)
      let why = classifyBuildFailure(lines, not built.started)
      # the compiler spells paths out in full; the friend knows the game by its folder
      let shortDetail = why.detail.replace(play.root & "/", "").replace(play.root & "\\", "")
      settle(play, ppFailed, why.code, why.message, shortDetail)
      return

  if not fileExists(plan.gameExe):
    settle(play, ppFailed, "no-program",
      "The build said it worked, but the game program is not where the studio expects it. Press Play again; if it still happens, tell the producer.", "")
    return

  acquire(play.lock)
  if play.stopRequested:
    release(play.lock)
    finishStopped(play)
    return
  ctl = newTurnControl() # the window's own control: the build's has already seen its program exit
  play.ctls.add ctl
  play.ctl = ctl
  play.lines = @[]
  play.phase = ppStarting
  play.startedAt = epochTime()
  release(play.lock)

  let ran = runChild(play, plan.gameExe, plan.gameArgs, ctl, true)
  if wasStopped(play):
      finishStopped(play)
      return
  var lines: seq[string]
  var wasStarting: bool
  acquire(play.lock)
  lines = play.lines
  # still "starting" only if nothing has answered and it ended soon enough to be a failed start
  wasStarting = play.phase == ppStarting and epochTime() - play.startedAt < startWaitSeconds
  release(play.lock)
  if not ran.started:
    settle(play, ppFailed, "cannot-start",
      "The studio could not start the game program. " & (if lines.len > 0: oneLine(redactSecrets(lines[^1]), 160) else: ""), "")
    return
  let why = classifyGameExit(lines, ran.code, wasStarting, displayEnvMissing())
  let phase = if why.code == "closed": ppExited elif wasStarting: ppFailed else: ppExited
  settle(play, phase, why.code, why.message, why.detail)

proc playMain(play: ptr Play) {.thread.} =
  {.cast(gcsafe).}:
    try:
      playRun(play)
    except CatchableError as e:
      settle(play, ppFailed, "studio-error", "The studio hit a problem while running the game: " & oneLine(redactSecrets(e.msg), 160), "")
  acquire(play.lock)
  play.active = false
  release(play.lock)

# --- start, stop, shutdown -----------------------------------------------------------

proc isActive*(play: ptr Play): bool =
  acquire(play.lock)
  result = play.active
  release(play.lock)

proc reap(play: ptr Play) =
  ## Joins the last run's thread and frees its controls. Only called when no run is active.
  if play.threadStarted:
    joinThread(play.thread)
    play.threadStarted = false
  for c in play.ctls: freeTurnControl(c)
  play.ctls.setLen(0)
  play.ctl = nil

proc stopLocked(play: ptr Play): bool =
  ## Ends the running build or window and waits until its thread is done. Needs `gate`.
  var ctl: ptr TurnControl
  acquire(play.lock)
  if play.active:
    result = true
    play.stopRequested = true
    ctl = play.ctl
  release(play.lock)
  if not result: return
  if ctl != nil: ctl.cancel("stop")
  # the thread sees the request between steps too (a stop that came while one program was
  # ending and the next not yet started): give it a moment either way
  let until = epochTime() + stopWaitSeconds
  while isActive(play) and epochTime() < until: sleep(20)
  if not isActive(play): reap(play)

proc stopPlay*(play: ptr Play): bool =
  ## True when a build or a window was running and has been ended.
  acquire(play.gate)
  defer: release(play.gate)
  stopLocked(play)

proc startPlay*(play: ptr Play, game: string): bool =
  ## Builds and opens `game`, ending whatever was running first. False when the studio could not
  ## end the earlier run or start its thread.
  acquire(play.gate)
  defer: release(play.gate)
  discard stopLocked(play)
  if isActive(play): return false
  reap(play)
  let plan = play.planner(play.root, game)
  acquire(play.lock)
  inc play.runId
  play.game = game
  play.plan = plan
  play.lines = @[]
  play.code = ""
  play.message = ""
  play.detail = ""
  play.stopRequested = false
  play.phase = if plan.buildExe.len > 0: ppBuilding else: ppStarting
  play.startedAt = epochTime()
  let ctl = newTurnControl()
  play.ctls.add ctl
  play.ctl = ctl
  play.active = true
  release(play.lock)
  try:
    createThread(play.thread, playMain, play)
    play.threadStarted = true
    result = true
  except CatchableError:
    settle(play, ppFailed, "studio-error", "The studio could not start the game.", "")
    acquire(play.lock)
    play.active = false
    release(play.lock)

proc shutdownPlay*(play: ptr Play) =
  ## The studio is closing: end the build or the window so nothing is left running.
  discard stopPlay(play)

# --- what the page reads -----------------------------------------------------------

proc phaseName(ph: PlayPhase): string =
  case ph
  of ppIdle: "idle"
  of ppBuilding: "building"
  of ppStarting: "starting"
  of ppRunning: "running"
  of ppFailed: "failed"
  of ppExited: "exited"

proc pingGame*(root: string): bool =
  ## `para live status`'s question, asked in this process: does a game answer on the channel?
  let sock = channelPath(root)
  if not socketExists(sock): return false
  try:
    sendDevRequest(sock, "ping", pingMs).ok
  except IOError:
    false

proc playView*(play: ptr Play): PlayView =
  var phase: PlayPhase
  var runId: int
  var startedAt: float
  acquire(play.lock)
  phase = play.phase
  runId = play.runId
  startedAt = play.startedAt
  result.game = play.game
  result.run = play.runId
  result.code = play.code
  result.message = play.message
  result.detail = play.detail
  if phase == ppBuilding:
    for i in countdown(play.lines.high, 0): # the C compiler's latest `CC: <module>` line
      if play.lines[i].startsWith("CC: "):
        result.progress = oneLine(play.lines[i], 120)
        break
  release(play.lock)
  if phase in {ppStarting, ppRunning}:
    result.live = pingGame(play.root)
    acquire(play.lock)
    if play.runId == runId and play.phase in {ppStarting, ppRunning}:
      if result.live:
        play.phase = ppRunning
        play.code = ""
      elif play.phase == ppStarting and epochTime() - startedAt > startWaitSeconds:
        play.phase = ppRunning
        play.code = "not-answering"
      phase = play.phase
      if phase == ppRunning:
        result.code = play.code
        result.message = if result.live: "The game window is open."
          else: "The game window is open, but it is not answering the studio, so screenshots will not work. If it just opened, give it a moment."
    else:
      # the run ended while we pinged: say how it ended
      phase = play.phase
      result.code = play.code
      result.message = play.message
      result.detail = play.detail
    release(play.lock)
  result.state = phaseName(phase)
  if phase == ppStarting: result.message = "Opening the game window…"
  elif phase == ppBuilding: result.message = "Building the game… the first time takes a few minutes."
