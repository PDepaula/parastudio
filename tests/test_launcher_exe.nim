# Tests for the native Windows launcher (tools/launcher/launch.nim, Paraloop-Studio.exe in the
# portable zip). It is plain Nim with no Windows-only logic in the steps, so it is compiled and run
# here on Linux against a throwaway "zip folder" laid out like the real one (the launcher, then
# nim-2.2.10/bin, mingw64/bin and parastudio/ beside it) with stand-ins for nim, nimble, gcc, git,
# winget and para. They check: the layout is found and the bundled tools are used ahead of anything
# on PATH, the seven steps run in order, a second run skips the libraries, a failure prints the
# block the friend sends the captain, a half-extracted zip stops with the way out, the one offer
# (git, through winget) takes only y or yes as yes and runs nothing otherwise, `--dry-run` installs,
# builds and opens nothing, and the log never holds Studio's own output. What it does when it
# really runs on Windows (a real double-click, SmartScreen, a real build with the bundled MinGW)
# is checked by the `portable` workflow (.github/workflows/portable.yml) and by the friend.
# Skipped on Windows (the stand-ins are shell scripts).

import std/[unittest, os, osproc, strutils, strtabs, tempfiles, streams]

const
  source = "tools" / "launcher" / "launch.nim"
  sh = "/bin/sh"

var
  exe = ""        # the compiled launcher
  work = ""

proc put(path, text: string, exec = false) =
  createDir(parentDir(path))
  writeFile(path, text)
  if exec: setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc script(path, body: string) = put(path, "#!" & sh & "\n" & body & "\n", exec = true)

type Zip = object
  dir, root, home, path, callsFile: string

proc newZip(name: string, nimVersion = "2.2.10", withNim = true, withCc = true, withGit = true,
            withWinget = false): Zip =
  ## A folder shaped like the portable zip, with stand-ins for every program the launcher runs.
  let dir = work / name
  removeDir(dir)
  result = Zip(dir: dir, root: dir / "parastudio", home: dir / "home", path: dir / "pathbin", callsFile: dir / "calls.txt")
  createDir(result.home)
  createDir(result.path)
  writeFile(result.callsFile, "")
  copyFile(exe, dir / "Paraloop-Studio")
  setFilePermissions(dir / "Paraloop-Studio", {fpUserRead, fpUserWrite, fpUserExec})
  if withNim:
    script(dir / ("nim-2.2.10") / "bin" / "nim", """
case "$1" in
  --version) echo "Nim Compiler Version """ & nimVersion & """ [Linux: amd64]"; exit 0;;
  c) echo "nim $*" >> "$FAKE_CALLS"; [ -n "$FAKE_NIM_FAIL" ] && { echo "error: fake compiler failure"; exit 1; }
     /bin/mkdir -p tmp; /bin/cp "$FAKE_PARA" tmp/para; /bin/chmod +x tmp/para; exit 0;;
esac""")
    script(dir / "nim-2.2.10" / "bin" / "nimble", """
echo "nimble $*" >> "$FAKE_CALLS"
case "$1" in
  install) echo "fetching the libraries"; [ -n "$FAKE_NIMBLE_FAIL" ] && exit 1; exit 0;;
  setup) /bin/mkdir -p pkgs; echo "--path:\"$PWD/pkgs\"" > nimble.paths; echo '# nimble.paths' >> config.nims; exit 0;;
esac""")
  if withCc:
    script(dir / "mingw64" / "bin" / "gcc", "echo gcc 11.1.0")
  put(result.root / "paraloop.nimble", "version = \"0\"\n")
  put(result.root / "config.nims", "switch(\"mm\", \"orc\")\n")
  put(result.root / "nimble.lock", "{}\n")
  createDir(result.root / ".git")
  script(dir / "fake-para", """
if [ "$1" = studio ] && [ "$2" = "--check" ]; then echo "checks: claude ok, folder trusted"; exit 0; fi
echo "STUDIO_RAN $* KEY=secret-per-run-key"; exit ${FAKE_STUDIO_EXIT:-0}""")
  if withGit: script(result.path / "git", "exit 0")
  if withWinget:
    # a winget that "installs" git by dropping a git program into the folder on PATH
    script(result.path / "winget", "echo \"winget $*\" >> \"$FAKE_CALLS\"\nprintf '#!/bin/sh\\nexit 0\\n' > \"" &
           result.path / "git" & "\"; /bin/chmod +x \"" & result.path / "git" & "\"")
  sleep(30) # nimble.paths must come out strictly newer than nimble.lock

proc run(z: Zip, args: seq[string], input = "", extra: openArray[(string, string)] = []): tuple[output: string, code: int] =
  var env = newStringTable()
  env["HOME"] = z.home
  env["PATH"] = z.path
  env["FAKE_CALLS"] = z.callsFile
  env["FAKE_PARA"] = z.dir / "fake-para"
  env["PARALOOP_LAUNCHER_PAUSE"] = "0"
  for (k, v) in extra: env[k] = v
  let p = startProcess(z.dir / "Paraloop-Studio", workingDir = z.dir, args = args, env = env,
                       options = {poStdErrToStdOut})
  let inp = p.inputStream
  inp.write(input)
  inp.close
  result.output = p.outputStream.readAll
  result.code = p.waitForExit
  p.close

proc calls(z: Zip): string = readFile(z.callsFile)

proc logOf(z: Zip): string =
  if fileExists(z.root / "tmp" / "launcher.log"): readFile(z.root / "tmp" / "launcher.log") else: ""

when defined(windows):
  echo "test_launcher_exe: skipped on Windows (stand-ins are shell scripts)"
else:
  work = createTempDir("paraloop-launcher-exe-", "")
  let build = execCmdEx("nim c --hints:off -o:" & quoteShell(work / "launch") & " " & quoteShell(source))
  if build.exitCode != 0: echo build.output
  doAssert build.exitCode == 0, "tools/launcher/launch.nim did not compile"
  exe = work / "launch"

  suite "native launcher: the first run and the next":
    test "all seven steps run in order with the zip's own tools, and Studio is started":
      let z = newZip("first")
      let r = z.run(@[])
      check r.code == 0
      for n in 1 .. 7: check r.output.contains("[" & $n & "/7]")
      check r.output.find("[1/7]") < r.output.find("[4/7]")
      check r.output.contains("found a C compiler: gcc in " & z.dir / "mingw64" / "bin" & " (the one in this zip)")
      check r.output.contains("found Nim 2.2.10 in " & z.dir / "nim-2.2.10" / "bin")
      check r.output.contains("ok: libraries ready")
      check r.output.contains("checks: claude ok, folder trusted")
      check r.output.contains("STUDIO_RAN studio")
      check not r.output.contains("STUDIO_RAN studio --no-open")
      check r.output.contains("Studio stopped. Double-click this program again to start it.")
      check z.calls.contains("nimble install -d -y")
      check z.calls.contains("nimble setup")
      check z.calls.contains("nim c --hints:off --outdir:tmp tools/para/para.nim")
      check fileExists(z.root / "tmp" / "para")

    test "the log has what the steps printed and never Studio's output (it holds a per-run key)":
      let z = newZip("log")
      discard z.run(@[])
      let log = z.logOf
      check log.contains("fetching the libraries")
      check log.contains("step 5: build para")
      check log.contains("starting tmp" / "para studio")
      check log.contains("after the launcher began")
      check not log.contains("STUDIO_RAN")
      check not log.contains("secret-per-run-key")

    test "a second run skips the libraries and only rebuilds":
      let z = newZip("second")
      discard z.run(@[])
      writeFile(z.callsFile, "")
      let r = z.run(@[])
      check r.code == 0
      check r.output.contains("ok: the libraries are already set up.")
      check not z.calls.contains("nimble")
      check z.calls.contains("nim c")

    test "--no-studio and --no-open":
      let z = newZip("flags")
      let a = z.run(@["--no-studio"])
      check a.code == 0
      check a.output.contains("not started now (--no-studio).")
      check not a.output.contains("STUDIO_RAN")
      let b = z.run(@["--no-open"])
      check b.output.contains("STUDIO_RAN studio --no-open")

    test "Studio stopping with an error prints the block to send":
      let z = newZip("studio-error")
      let r = z.run(@[], extra = {"FAKE_STUDIO_EXIT": "3"})
      check r.code == 1
      check r.output.contains("Step:     7 of 7, start Studio")
      check r.output.contains("exit code 3")

    test "an unknown option is a usage error (exit 2), --help exits 0":
      let z = newZip("usage")
      check z.run(@["--frobnicate"]).code == 2
      let h = z.run(@["--help"])
      check h.code == 0
      check h.output.contains("--dry-run")

  suite "native launcher: failures say what happened":
    test "a failing build stops at step 5 with the block and the log's last lines":
      let z = newZip("build-fails")
      let r = z.run(@[], extra = {"FAKE_NIM_FAIL": "1"})
      check r.code == 1
      check r.output.contains("Something went wrong. Please send the captain everything between these lines.")
      check r.output.contains("Step:     5 of 7, build para")
      check r.output.contains("Building para failed. The log has the compiler's words.")
      check r.output.contains("Log file: " & z.root / "tmp" / "launcher.log")
      check r.output.contains("error: fake compiler failure")
      check not r.output.contains("STUDIO_RAN")

    test "nimble failing to fetch stops at step 4":
      let z = newZip("nimble-fails")
      let r = z.run(@[], extra = {"FAKE_NIMBLE_FAIL": "1"})
      check r.code == 1
      check r.output.contains("Step:     4 of 7, game libraries")
      check r.output.contains("Check that this computer is online")

    test "a zip that was not fully extracted stops with the way out, naming the missing folder":
      let z = newZip("half", withNim = false, withCc = false)
      let r = z.run(@[])
      check r.code == 1
      check r.output.contains("MISSING: No C compiler was found.")
      check r.output.contains("MISSING: Nim 2.2.10 was not found.")
      check r.output.contains("Extract All")
      check r.output.contains(z.dir / "nim-2.2.10")
      check not r.output.contains("[4/7]")

    test "no parastudio folder next to the program: the way out, exit 1":
      let z = newZip("no-root")
      removeDir(z.root)
      let r = z.run(@[])
      check r.code == 1
      check r.output.contains("I cannot find the parastudio folder")
      check r.output.contains("Extract All")

    test "a different Nim on PATH is left alone and does not count":
      let z = newZip("other-nim", nimVersion = "2.2.12")
      let r = z.run(@[])
      check r.code == 1
      check r.output.contains("Found a different Nim (2.2.12 at " & z.dir / "nim-2.2.10" / "bin" / "nim" & ")")
      check r.output.contains("the other one is left alone")

  suite "native launcher: the offer to install git asks first":
    test "git missing and no winget: nothing is offered, it stops with the steps by hand":
      let z = newZip("git-no-winget", withGit = false)
      let r = z.run(@[])
      check r.code == 1
      check r.output.contains("winget (the app installer that comes with Windows 10 and 11) was not found")
      check r.output.contains("https://git-scm.com/download/win")
      check not r.output.contains("[4/7]")

    test "the offer says what, from where, the command, where to and how big, before it asks":
      let z = newZip("git-offer", withGit = false, withWinget = true)
      let r = z.run(@[], input = "n\n")
      let o = r.output
      for part in ["What:    Git for Windows", "From:    winget's own catalog", "Command: winget install --id Git.Git -e --source winget --scope user",
                   "Where:   your user folder", "Size:", "PATH:"]:
        check o.contains(part)
        check o.find(part) < o.find("Install git now?")
      check r.code == 1
      check not z.calls.contains("winget")

    test "only y or yes is yes: Enter, n, anything else and a closed input install nothing":
      for answer in ["\n", "n\n", "yeah\n", "sure\n", ""]:
        let z = newZip("git-no", withGit = false, withWinget = true)
        let r = z.run(@[], input = answer)
        check r.code == 1
        check r.output.contains("Okay, nothing was installed.")
        check not z.calls.contains("winget")

    test "y and yes run exactly the winget command shown, then carry on":
      for answer in ["y\n", "YES\n"]:
        let z = newZip("git-yes", withGit = false, withWinget = true)
        let r = z.run(@[], input = answer)
        check r.output.contains("ok: git is installed.")
        check z.calls.contains("winget install --id Git.Git -e --source winget --scope user")
        check r.output.contains("[7/7]")

    test "an unattended run answers no without asking":
      let z = newZip("git-unattended", withGit = false, withWinget = true)
      let r = z.run(@[], input = "y\n", extra = {"PARALOOP_LAUNCHER_UNATTENDED": "1"})
      check r.code == 1
      check r.output.contains("No: this is an unattended run, and nothing is installed without a person typing y.")
      check not z.calls.contains("winget")

  suite "native launcher: dry run":
    test "--dry-run and --check list every step, install, build, open and ask nothing":
      for flag in ["--dry-run", "--check"]:
        let z = newZip("dry", withGit = false, withWinget = true)
        let r = z.run(@[flag], input = "y\ny\ny\n")
        check r.code == 0
        check r.output.contains("dry run: nothing will be installed, built or opened")
        check r.output.contains("[7/7]")
        check r.output.contains("would: ask you: Install it now? (y/n, Enter means no)")
        check r.output.contains("Dry run finished: nothing was installed, built or opened.")
        check not r.output.contains("STUDIO_RAN")
        check z.calls.len == 0
        check not dirExists(z.root / "tmp")
        check not dirExists(z.home / ".paraloop")

    test "the dry-run test hooks ask the real question and say what they would do":
      let z = newZip("dry-ask")
      let yes = z.run(@["--check"], input = "y\n", extra = {"PARALOOP_LAUNCHER_FAKE_MISSING": "git", "PARALOOP_LAUNCHER_DRY_ASK": "1"})
      check yes.code == 0
      check yes.output.contains("would: install git with: winget install --id Git.Git -e --source winget --scope user")
      let no = z.run(@["--check"], input = "\n", extra = {"PARALOOP_LAUNCHER_FAKE_MISSING": "git", "PARALOOP_LAUNCHER_DRY_ASK": "1"})
      check no.output.contains("Okay, nothing was installed.")
      check not no.output.contains("would: install")
      check z.calls.len == 0

    test "the fake-missing hook is read only in a dry run":
      let z = newZip("hook-real")
      let r = z.run(@["--no-studio"], extra = {"PARALOOP_LAUNCHER_FAKE_MISSING": "cc,git,nim"})
      check r.code == 0
      check r.output.contains("ok: git is installed.")

  suite "native launcher: what it never does":
    test "its source runs no administrator, registry, PATH-for-good or piped-download command":
      let text = readFile(source)
      for banned in ["sudo", "runas", "setx", "reg add", "powershell", "Invoke-Expression", "| sh", "| iex",
                     ".claude", ".codex", "credentials", "ShellExecute"]:
        checkpoint "found " & banned
        check not text.contains(banned)
      for i, c in text:
        if c > '\x7f': checkpoint("non-ASCII byte at " & $i); fail()
        if c == '\r': checkpoint("CR at " & $i); fail()

  removeDir(work)
