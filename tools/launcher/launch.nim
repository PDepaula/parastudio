# Para Studio native launcher: the one file a Windows friend double-clicks (Paraloop-Studio.exe,
# inside the portable zip; docs/windows.md). It is a port of tools/launcher/launch.bat that needs
# no cmd.exe, no PowerShell and no execution policy, and that carries the toolchain with it: Nim
# 2.2.10 and MinGW-w64 sit in folders beside the program, so there is nothing to detect, download
# or install for them. The steps and the words are the batch launcher's:
#
#   1 a C compiler   <exe folder>\mingw64\bin\gcc.exe (else gcc, cc or clang on PATH)
#   2 git            on PATH or where Git for Windows installs itself; the only thing it can offer
#   3 Nim 2.2.10     <exe folder>\nim-2.2.10\bin (else a Nim 2.2.10 on PATH or in the usual folders)
#   4 the libraries  nimble install -d -y, then nimble setup (skipped when already set up)
#   5 build para     nim c --hints:off --outdir:tmp tools/para/para.nim
#   6 chat program   tmp\para.exe studio --check (read only; never stops Studio)
#   7 Studio         tmp\para.exe studio, which prints its link and opens the browser itself
#
#   Paraloop-Studio.exe [--dry-run | --check] [--no-studio] [--no-open] [--help]
#
# --dry-run (or --check) runs the same looks, says what each later step WOULD do and installs,
# builds, fetches, opens and asks nothing. --no-studio does every step but the last. --no-open
# starts Studio without opening a browser (CI uses it). PARALOOP_LAUNCHER_UNATTENDED=1 is for a run
# with nobody at the keyboard: the one offer (git) is answered no without asking. Test hooks, read
# only in a dry run: PARALOOP_LAUNCHER_FAKE_MISSING=cc,git,nim pretends those are missing and
# PARALOOP_LAUNCHER_DRY_ASK=1 asks the real question of the git offer and says what it WOULD do.
# PARASTUDIO_ROOT=<folder> names the Para Studio folder (default: parastudio next to this program,
# else this program's own folder, else two folders up from tools\launcher).
# PARALOOP_BUNDLE_DIR=<folder> names the folder that holds nim-2.2.10 and mingw64 (default: the
# folder this program is in). PARALOOP_LAUNCHER_PAUSE=1 / 0 forces / prevents the "press Enter to
# close" wait at the end (default: wait only when Windows opened this window for the program, that
# is, when it was double-clicked).
#
# Never silent, same rules as the batch launcher: when git is missing it prints what it would
# install (name and version), from where (the exact winget command), into which folder and how big,
# then asks a plain yes/no. Only y or yes is yes; Enter, anything else and a closed input are no, and
# no stops with what to install by hand. It never downloads Nim or a compiler (they are in the zip),
# runs a downloaded script, asks for an administrator password, changes PATH or any setting of the
# computer (PATH is extended inside this program's own process and its children only; winget, when
# you say yes to it, adds git to your user PATH as it always does), reads or writes a login or a
# config of claude or codex, or sends anything anywhere except through nimble's package fetch, git
# and the winget install you said yes to. The log (tmp\launcher.log) holds only what the steps
# printed; Studio's own output, which carries its per-run key, is never written to it.
#
# Plain ASCII, standard library only (it is compiled before any Nim package exists).

import std/[os, osproc, strutils, times]

const
  nimVersion = "2.2.10"
  stepCount = 7
  gitWinget = "winget install --id Git.Git -e --source winget --scope user"
  gitUrl = "https://git-scm.com/download/win"
  controlCExit = 3221225786'i64 # 0xC000013A, STATUS_CONTROL_C_EXIT

var
  dryRun, noStudio, noOpen, unattended, dryAsk = false
  fake = ""
  logPath = ""
  root = ""
  exeDir = ""
  bundleDir = ""
  portable = false
  stepNo = 0
  stepName = "starting"
  startedAt = epochTime()
  interrupted = false

proc onCtrlC() {.noconv.} =
  # The launcher outlives Ctrl+C so that it can wait for Studio to stop and then say so.
  interrupted = true

proc say(s = "") =
  echo s
  stdout.flushFile

proc duration(seconds: float): string =
  let s = int(seconds + 0.5)
  if s < 60: $s & " s" else: $(s div 60) & " min " & $(s mod 60) & " s"

proc logLine(s: string) =
  if logPath.len == 0: return
  try:
    let f = open(logPath, fmAppend)
    f.writeLine(now().format("yyyy-MM-dd HH:mm:ss") & " " & s)
    f.close
  except IOError, OSError: discard

proc ok(s: string) =
  say "      ok: " & s
  logLine "ok: " & s

proc bad(s: string) =
  say "      MISSING: " & s
  logLine "missing: " & s

proc note(s: string) =
  say "      " & s
  logLine s

proc would(s: string) = say "      would: " & s

proc step(text, name: string) =
  inc stepNo
  stepName = name
  say ""
  say "[" & $stepNo & "/" & $stepCount & "] " & text
  logLine "step " & $stepNo & ": " & name

proc osName(): string =
  when defined(windows): "Windows, " & hostCPU else: hostOS & ", " & hostCPU

proc pauseWindow() =
  ## "Press Enter to close" so a double-clicked window does not vanish with the message in it.
  if dryRun: return
  var wait = false
  let force = getEnv("PARALOOP_LAUNCHER_PAUSE")
  if force == "1": wait = true
  elif force == "0": wait = false
  else:
    when defined(windows):
      # Windows opened a console just for this program (a double-click) when no other process
      # shares it; from a terminal, cmd.exe or PowerShell is on it too.
      proc getConsoleProcessList(list: ptr uint32, count: uint32): uint32
        {.importc: "GetConsoleProcessList", stdcall, dynlib: "kernel32".}
      var ids: array[4, uint32]
      wait = getConsoleProcessList(addr ids[0], 4) <= 1
  if not wait: return
  say ""
  say "Press Enter to close this window."
  try: discard stdin.readLine except IOError, EOFError: discard

proc logTail() =
  if logPath.len == 0 or not fileExists(logPath): return
  var lines: seq[string]
  try: lines = readFile(logPath).splitLines
  except IOError: return
  while lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
  if lines.len == 0: return
  say "Last lines of the log:"
  for l in lines[max(0, lines.len - 12) .. ^1]: say "  | " & l

proc fail(problem: string) =
  say ""
  say "=============================================================================="
  say "Something went wrong. Please send the captain everything between these lines."
  say "------------------------------------------------------------------------------"
  say "Step:     " & $stepNo & " of " & $stepCount & ", " & stepName
  say "Problem:  " & problem
  say "Computer: " & osName()
  if logPath.len > 0:
    say "Log file: " & logPath & "   (attach this file too)"
    logTail()
  say "=============================================================================="
  logLine "FAILED at step " & $stepNo & " (" & stepName & "): " & problem
  pauseWindow()
  quit(1)

proc ask(question: string): bool =
  ## Yes only for y or yes typed here; Enter, anything else and a closed input are no. An
  ## unattended run never asks.
  if unattended:
    say "      " & question & " No: this is an unattended run, and nothing is installed without a person typing y."
    logLine "asked: " & question & " - answer: no (unattended)"
    return false
  stdout.write "      " & question & " (y/n, Enter means no) "
  stdout.flushFile
  var reply = ""
  try: reply = stdin.readLine
  except IOError, EOFError: reply = ""
  let r = reply.strip.toLowerAscii
  result = r == "y" or r == "yes"
  logLine "asked: " & question & " - answer: " & (if result: "yes" else: "no")
  if not result: say "      Okay, nothing was installed."

# --- finding things (looking only; PATH is extended for this process and its children only) -------

proc withExe(dir, name: string): string = dir / addFileExt(name, ExeExt)

proc prependPath(dir: string) =
  putEnv("PATH", dir & $PathSep & getEnv("PATH"))

proc isFake(what: string): bool = dryRun and ("," & fake & ",").contains("," & what & ",")

proc programVersion(exe: string): string =
  ## The first line of `exe --version`, or "" when it will not run.
  try:
    result = execProcess(exe, args = ["--version"], options = {poStdErrToStdOut}).splitLines[0].strip
  except CatchableError:
    result = ""

proc nimVersionOf(nimExe: string): string =
  ## "2.2.10" from "Nim Compiler Version 2.2.10 [Windows: amd64]".
  let words = programVersion(nimExe).splitWhitespace
  if words.len >= 4 and words[2] == "Version": words[3] else: ""

proc lookCc(): string =
  ## Sets up the compiler and says where it is; "" when there is none.
  let bundled = bundleDir / "mingw64" / "bin"
  if dirExists(bundled):
    if fileExists(withExe(bundled, "gcc")):
      prependPath bundled
      return "gcc in " & bundled & " (the one in this zip)"
    return ""
  for name in ["gcc", "cc", "clang"]:
    if findExe(name).len > 0: return name
  when defined(windows):
    var dirs = @["C:\\mingw64\\bin", "C:\\msys64\\ucrt64\\bin", "C:\\msys64\\mingw64\\bin",
                 getEnv("ProgramFiles") / "mingw-w64" / "bin"]
    for p in walkPattern(getEnv("LOCALAPPDATA") / "Microsoft" / "WinGet" / "Packages" / "BrechtSanders.WinLibs*" / "mingw64" / "bin"):
      dirs.add p
    for d in dirs:
      if fileExists(withExe(d, "gcc")):
        prependPath d
        return "gcc in " & d & " (not on PATH; used for this program only)"

proc lookGit(): bool =
  if findExe("git").len > 0: return true
  let bundled = bundleDir / "mingit" / "cmd"
  var dirs = @[bundled]
  when defined(windows):
    dirs.add getEnv("ProgramFiles") / "Git" / "cmd"
    dirs.add getEnv("LOCALAPPDATA") / "Programs" / "Git" / "cmd"
  for d in dirs:
    if fileExists(withExe(d, "git")):
      prependPath d
      return true

proc lookNim(other: var string): string =
  ## The folder of a Nim 2.2.10 (and puts it on PATH); "" when there is none. Another version is
  ## named in `other` and left alone.
  var candidates: seq[string]
  let bundled = bundleDir / ("nim-" & nimVersion) / "bin"
  if dirExists(bundled):
    candidates = @[bundled]
  else:
    let onPath = findExe("nim")
    if onPath.len > 0: candidates.add onPath.parentDir
    let home = getHomeDir()
    for d in [home / ".paraloop" / ("nim-" & nimVersion) / "bin", "C:\\nim\\bin", "C:\\nim\\nim-" & nimVersion & "\\bin",
              "C:\\nim-" & nimVersion & "\\bin", home / ("nim-" & nimVersion) / "bin", home / ".nimble" / "bin",
              home / ".choosenim" / "toolchains" / ("nim-" & nimVersion) / "bin",
              getEnv("ProgramFiles") / "nim" / "bin", getEnv("LOCALAPPDATA") / "Programs" / "nim" / "bin"]:
      if d.len > 0 and d notin candidates: candidates.add d
  for d in candidates:
    let exe = withExe(d, "nim")
    if not fileExists(exe): continue
    let v = nimVersionOf(exe)
    if v == nimVersion: return d
    if v.len > 0 and other.len == 0: other = v & " at " & exe

proc findRoot(): string =
  let env = getEnv("PARASTUDIO_ROOT")
  if env.len > 0:
    return if fileExists(env / "paraloop.nimble"): normalizedPath(absolutePath(env)) else: ""
  for c in [exeDir / "parastudio", exeDir, exeDir / ".." / ".."]:
    if fileExists(c / "paraloop.nimble"): return normalizedPath(absolutePath(c))

proc depsReady(): bool =
  ## nimble.paths exists, config.nims uses it, no file it comes from (nimble.lock, paraloop.nimble)
  ## is strictly newer, and every --path folder in it still exists.
  if not fileExists("nimble.paths") or not fileExists("config.nims"): return false
  try:
    if not readFile("config.nims").contains("nimble.paths"): return false
    let made = getLastModificationTime("nimble.paths")
    for f in ["nimble.lock", "paraloop.nimble"]:
      if fileExists(f) and getLastModificationTime(f) > made: return false
    for l in readFile("nimble.paths").splitLines:
      if l.startsWith("--path:"):
        let p = l["--path:".len .. ^1].strip.strip(chars = {'"'})
        if p.len > 0 and not dirExists(p): return false
  except IOError, OSError: return false
  true

# --- running things ------------------------------------------------------------------------------

proc runLogged(exe: string, args: seq[string]): int =
  ## Runs a step with its output going to the log only. -1 when it could not be started.
  logLine "$ " & extractFilename(exe) & " " & args.join(" ")
  try:
    let p = startProcess(exe, workingDir = root, args = args, options = {poStdErrToStdOut})
    var f: File
    let haveLog = logPath.len > 0 and open(f, logPath, fmAppend)
    for line in p.lines:
      if haveLog: f.writeLine line
    if haveLog: f.close
    result = p.waitForExit
    p.close
  except CatchableError as e:
    logLine "could not start " & exe & ": " & e.msg
    result = -1

proc runLive(exe: string, args: seq[string]): int =
  ## Runs a program that talks to the person directly (its output is not logged).
  try:
    let p = startProcess(exe, workingDir = root, args = args, options = {poParentStreams})
    result = p.waitForExit
    p.close
  except CatchableError as e:
    logLine "could not start " & exe & ": " & e.msg
    result = -1

# --- the words -----------------------------------------------------------------------------------

proc help() =
  say "Para Studio launcher (Paraloop-Studio.exe)"
  say "  Paraloop-Studio.exe [--dry-run or --check] [--no-studio] [--no-open]"
  say "  --dry-run    check what is installed, say what it would offer to install and what each step"
  say "               would do; install, build and open nothing, and ask nothing (--check is the same)"
  say "  --no-studio  set up and build, then stop without starting Studio"
  say "  --no-open    start Studio without opening your browser"
  say "See docs/windows.md."

proc offerGit(haveGit: var bool) =
  say ""
  say "git is missing (it keeps your save points, and the game libraries are fetched with it)."
  let winget = findExe("winget")
  if winget.len == 0 and not dryAsk:
    say "  winget (the app installer that comes with Windows 10 and 11) was not found, so I"
    say "  cannot offer to install it; the steps to do it by hand are listed below."
    return
  say "  I can install it with winget, the app installer that comes with Windows:"
  say "    What:    Git for Windows, the newest version winget lists"
  say "    From:    winget's own catalog; the installer comes from github.com/git-for-windows"
  say "    Command: " & gitWinget
  say "    Where:   your user folder (%LOCALAPPDATA%\\Programs\\Git), no administrator password"
  say "    Size:    winget shows it as it downloads"
  say "    PATH:    Git's installer adds git to your user PATH itself"
  say "  winget may first ask you to agree to its catalog's terms; answer Y there if you agree."
  if dryRun and not dryAsk:
    would "ask you: Install it now? (y/n, Enter means no)"
    would "on y, run exactly the command above"
    would "on n or Enter, stop with nothing installed"
    return
  if not ask("Install git now?"): return
  if dryAsk:
    would "install git with: " & gitWinget
    return
  logLine "$ " & gitWinget
  let code = runLive(winget, gitWinget.splitWhitespace[1 .. ^1])
  if code != 0:
    note "winget did not finish (exit code " & $code & ")."
    return
  if not lookGit():
    note "winget finished, but this window cannot see git yet."
    return
  ok "git is installed."
  haveGit = true

proc helpCc() =
  say ""
  if portable:
    say "A C compiler (the game is turned into a program by one). Not found."
    say "  It is the mingw64 folder that comes in the zip, next to this program: " & (bundleDir / "mingw64")
    say "  It is not there, so the zip was probably not fully extracted. Right-click the zip file,"
    say "  choose Extract All, and double-click this program in the new folder."
  else:
    say "A C compiler (the game is turned into a program by one). Not found."
    say "  In a normal terminal run:   winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e --source winget"
    say "  Any MinGW-w64 gcc works; if you already have one, make sure its bin folder is on PATH."

proc helpGit() =
  say ""
  say "git (keeps your save points; the game libraries are fetched with it). Not found."
  say "  Download Git for Windows from " & gitUrl
  say "  or in a normal terminal run:   " & gitWinget
  say "  Say yes to the defaults."

proc helpNim() =
  say ""
  say "Nim " & nimVersion & " (the language the games are written in). Not found."
  if portable:
    say "  It is the nim-" & nimVersion & " folder that comes in the zip, next to this program: " & (bundleDir / ("nim-" & nimVersion))
    say "  It is not there, so the zip was probably not fully extracted. Right-click the zip file,"
    say "  choose Extract All, and double-click this program in the new folder."
  else:
    say "  Download https://nim-lang.org/download/nim-" & nimVersion & "_x64.zip"
    say "  Unzip it somewhere permanent such as C:\\nim, then run finish.exe inside the unzipped folder"
    say "  and let it add the Nim folders to your PATH. It does not need to install a compiler."
    say "  It must be exactly " & nimVersion & "; another Nim is left alone."

# --- the run -------------------------------------------------------------------------------------

proc main() =
  var args = commandLineParams()
  for a in args:
    case a.toLowerAscii
    of "--dry-run", "--check": dryRun = true
    of "--no-studio": noStudio = true
    of "--no-open": noOpen = true
    of "--help", "-h", "/?":
      help()
      quit(0)
    else:
      stderr.writeLine "Unknown option: " & a & " (try --help)"
      quit(2)

  setControlCHook(onCtrlC)
  exeDir = parentDir(getAppFilename())
  bundleDir = if getEnv("PARALOOP_BUNDLE_DIR").len > 0: getEnv("PARALOOP_BUNDLE_DIR") else: exeDir
  unattended = getEnv("PARALOOP_LAUNCHER_UNATTENDED") == "1"
  if dryRun:
    fake = getEnv("PARALOOP_LAUNCHER_FAKE_MISSING")
    dryAsk = getEnv("PARALOOP_LAUNCHER_DRY_ASK") == "1"

  root = findRoot()
  if root.len == 0:
    say ""
    say "I cannot find the parastudio folder (the one with paraloop.nimble) next to this program."
    say "If you opened this program from inside a zip file, close this window, right-click the"
    say "zip file, choose Extract All, and double-click Paraloop-Studio.exe in the new folder."
    say "Otherwise the zip is incomplete; ask the captain for a fresh copy."
    pauseWindow()
    quit(1)
  portable = root == normalizedPath(exeDir / "parastudio")
  setCurrentDir(root)

  if dryRun:
    say "Para Studio launcher (dry run: nothing will be installed, built or opened)"
  else:
    createDir(root / "tmp")
    logPath = root / "tmp" / "launcher.log"
    say "Para Studio launcher"
    say "A record of what happens is kept in " & logPath
    logLine "---- launcher run, " & osName() & ", folder " & root
  if root.len > 90:
    note "Note: this folder's path is long (" & $root.len & " characters). Windows can stop a build when a path gets too long;" &
         " if a step fails, extract the zip to a short folder such as C:\\ParaStudio and try again."

  # step 1: a C compiler
  step "Checking for a C compiler (the part of your computer that builds programs)...", "C compiler"
  var cc = if isFake("cc"): "" else: lookCc()
  if cc.len > 0: ok "found a C compiler: " & cc
  else: bad "No C compiler was found."

  # step 2: git
  step "Checking for git (keeps your save points)...", "git"
  var haveGit = not isFake("git") and lookGit()
  if haveGit:
    ok "git is installed."
    if not dirExists(root / ".git") and not fileExists(root / ".git"):
      note "Note: this folder was not copied with git (for example, it came from a zip file), so save points will not work until the captain gives you a git copy. Studio still starts."
  else:
    bad "git was not found."

  # step 3: Nim
  step "Checking for Nim " & nimVersion & " (the language the games are written in)...", "Nim " & nimVersion
  var otherNim = ""
  var nimDir = if isFake("nim"): "" else: lookNim(otherNim)
  if nimDir.len > 0:
    prependPath getHomeDir() / ".nimble" / "bin"
    prependPath nimDir
    ok "found Nim " & nimVersion & " in " & nimDir
  else:
    if otherNim.len > 0:
      note "Found a different Nim (" & otherNim & "). Paraloop needs exactly " & nimVersion & "; the other one is left alone."
    bad "Nim " & nimVersion & " was not found."

  # the offer (git only: Nim and the compiler come in the zip)
  if not haveGit:
    say ""
    say "------------------------------------------------------------------------------"
    say "Something Studio needs is not on this computer yet. For each one below I say"
    say "exactly what I would install, from where and into which folder, and then ask."
    say "Only y or yes is yes. Enter, or anything else, means no and installs nothing."
    say "------------------------------------------------------------------------------"
    offerGit haveGit
  let blocked = cc.len == 0 or not haveGit or nimDir.len == 0
  if blocked and dryRun:
    if cc.len == 0: helpCc()
    if nimDir.len == 0: helpNim()
    say ""
    would "carry on with the steps below only if everything above is found or answered y"
  elif blocked:
    say ""
    say "------------------------------------------------------------------------------"
    say "Studio cannot start yet: something it needs is still not on this computer."
    say "Nothing you said no to was installed. To fix it, follow what is listed below,"
    say "then close this window and double-click this program again."
    say "------------------------------------------------------------------------------"
    if cc.len == 0: helpCc()
    if not haveGit: helpGit()
    if nimDir.len == 0: helpNim()
    say ""
    say "Already installed it and still see this message? Restart the computer once, so Windows"
    say "hands the new program to this window, and double-click again. Still stuck? Send the"
    say "captain a photo or a copy of this window."
    logLine "stopped: missing cc=" & $(cc.len == 0) & " git=" & $(not haveGit) & " nim=" & $(nimDir.len == 0)
    pauseWindow()
    quit(1)

  let nimble = withExe(nimDir, "nimble")
  if not dryRun and nimDir.len > 0 and not fileExists(nimble):
    fail "Nim was found in " & nimDir & " but nimble (its package tool, normally in the same folder) was not."
  let nim = withExe(nimDir, "nim")

  # step 4: the game libraries
  step "Fetching the game libraries (nimble install -d -y, then nimble setup)...", "game libraries"
  if depsReady():
    ok "the libraries are already set up."
  elif dryRun:
    would "run: nimble install -d -y   (downloads the libraries pinned in nimble.lock)"
    would "run: nimble setup"
  else:
    let t0 = epochTime()
    note "The first time this takes a few minutes. Nothing is printed here while it works; it is working even when nothing moves."
    if runLogged(nimble, @["install", "-d", "-y"]) != 0:
      fail "nimble could not fetch the game libraries. Check that this computer is online, then run this again."
    if runLogged(nimble, @["setup"]) != 0:
      fail "nimble setup failed."
    if not depsReady():
      fail "The libraries were fetched but are not set up where the build expects them."
    ok "libraries ready (" & duration(epochTime() - t0) & ")."

  # step 5: build para
  step "Building para, the program behind Studio...", "build para"
  let para = root / "tmp" / addFileExt("para", ExeExt)
  let paraShown = "tmp" & DirSep & addFileExt("para", ExeExt)
  if dryRun:
    would "run: nim c --hints:off --outdir:tmp tools/para/para.nim"
  else:
    let t0 = epochTime()
    note "This takes a few minutes the first time and is quicker after (only what changed is rebuilt). Nothing is printed here while it works; it is working even when nothing moves."
    if runLogged(nim, @["c", "--hints:off", "--outdir:tmp", "tools/para/para.nim"]) != 0:
      fail "Building para failed. The log has the compiler's words."
    if not fileExists(para):
      fail "The build finished but " & paraShown & " was not made."
    ok "built " & paraShown & " (" & duration(epochTime() - t0) & ")"

  # step 6: the producer's chat program
  step "Checking the producer's chat program (claude or codex: installed, signed in, folder trusted)...", "claude or codex"
  if dryRun:
    would "run: " & paraShown & " studio --check   (the startup checks the Studio page shows: installed, signed in, folder trusted; they never stop Studio from opening)"
  else:
    # Read only, like the page's checks: no model is asked anything and no login is read. Whatever
    # it answers, Studio still opens, so its exit code is not looked at.
    logLine "$ " & paraShown & " studio --check"
    discard runLive(para, @["studio", "--check"])

  # step 7: Studio
  step "Starting Studio...", "start Studio"
  if noStudio:
    note "not started now (--no-studio)."
    if dryRun:
      say ""
      say "Dry run finished: nothing was installed, built or opened."
    quit(0)
  if dryRun:
    would "run: " & paraShown & " studio" & (if noOpen: " --no-open" else: "") &
          "   (it prints a link and opens it in your default browser)"
    say ""
    say "Dry run finished: nothing was installed, built or opened."
    quit(0)
  say "      Studio opens in your browser. Keep this window open while you use it;"
  say "      press Ctrl+C here or close this window to stop Studio."
  say ""
  logLine "starting " & paraShown & " studio, " & duration(epochTime() - startedAt) &
          " after the launcher began (its output is not logged: it holds a per-run key)"
  var studioArgs = @["studio"]
  if noOpen: studioArgs.add "--no-open"
  let code = runLive(para, studioArgs)
  logLine "Studio stopped with exit code " & $code
  if code == 0 or interrupted or int64(code) == controlCExit or int64(code) == controlCExit - 4294967296'i64:
    say ""
    say "Studio stopped. Double-click this program again to start it."
    pauseWindow()
    quit(0)
  fail "Studio stopped with an error (exit code " & $code & "). Copy what Studio printed above into your message too."

main()
