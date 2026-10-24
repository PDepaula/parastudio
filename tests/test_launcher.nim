# Tests for the double-click launcher (Paraloop-Studio.command, paraloop-studio.sh and the shared
# tools/launcher/launch.sh behind them): that the files are runnable and, run from another folder,
# reach the launcher, that `--dry-run` lists every
# step without installing, building or opening anything (with Nim missing from PATH, so the
# "ask first" branch is reached), that the macOS branch says what it would do, and, against a
# throwaway checkout with fake `nim`/`nimble`/`para`, that a second run only starts Studio and that
# a failure prints the block the friend sends the captain. The real Nim install, xcode-select and
# a real browser are never run here. Needs bash; skipped on Windows.

import std/[unittest, os, osproc, strutils, strtabs, tempfiles, times]

const
  command = "Paraloop-Studio.command"
  linuxScript = "paraloop-studio.sh"
  launcher = "tools" / "launcher" / "launch.sh"
  # every program the launcher may call in the steps these tests reach
  hostTools = ["bash", "uname", "dirname", "git", "grep", "sed", "awk", "find", "date", "cat", "tr", "head",
               "tail", "wc", "rm", "mkdir", "chmod", "mktemp", "sleep", "gcc", "cc", "id"]

proc scrubbedBin(dir: string): string =
  ## A folder of links to the host programs the launcher needs and nothing else: no nim, no
  ## nimble, no claude, no codex.
  result = dir / "bin"
  createDir(result)
  for tool in hostTools:
    let found = findExe(tool)
    if found.len > 0 and not fileExists(result / tool): createSymlink(found, result / tool)

proc launch(args: string, home, path: string, extra: openArray[(string, string)] = [],
            where = "", script = launcher): tuple[output: string, exitCode: int] =
  var env = newStringTable()
  env["HOME"] = home
  env["PATH"] = path
  env["TMPDIR"] = home
  for (k, v) in extra: env[k] = v
  let cwd = if where.len > 0: where else: getCurrentDir()
  execCmdEx(quoteShell(findExe("bash")) & " " & quoteShell(cwd / script) & " " & args, env = env, workingDir = cwd)

proc hostHasAgent(): bool =
  for dir in ["/opt/homebrew/bin", "/usr/local/bin"]:
    for name in ["claude", "codex"]:
      if fileExists(dir / name): return true

when defined(windows):
  suite "launcher":
    test "skipped on Windows (the launcher is bash for macOS and Linux)":
      skip()
else:
  suite "launcher: the files":
    test "the double-click files are executable bash scripts":
      for f in [command, linuxScript, launcher]:
        check fileExists(f)
        check fpUserExec in getFilePermissions(f)
        let first = readFile(f).splitLines[0]
        check first.startsWith("#!") and "bash" in first

    test "git stores the double-click files with the executable bit":
      if findExe("git").len > 0:
        for f in [command, linuxScript, launcher]:
          let (listing, code) = execCmdEx("git ls-files -s " & quoteShell(f))
          if code == 0 and listing.len > 0: check listing.startsWith("100755 ")

  suite "launcher: --dry-run":
    var scratch: string
    setup: scratch = createTempDir("launcher", "")
    teardown: removeDir(scratch)

    test "the double-click files run the launcher from any folder":
      let elsewhere = scratch / "elsewhere"
      createDir(elsewhere)
      for wrapper in [command, linuxScript]:
        var env = newStringTable()
        env["HOME"] = scratch
        env["PATH"] = scrubbedBin(scratch)
        env["TMPDIR"] = scratch
        let r = execCmdEx(quoteShell(findExe("bash")) & " " & quoteShell(getCurrentDir() / wrapper) & " --dry-run",
                          env = env, workingDir = elsewhere)
        check r.exitCode == 0
        for n in 1 .. 7: check ("[" & $n & "/7]") in r.output
        check "Dry run finished: nothing was installed, built or opened." in r.output

    test "--help and an unknown option":
      let h = launch("--help", scratch, scrubbedBin(scratch))
      check h.exitCode == 0
      check "--dry-run" in h.output
      let bad = launch("--bogus", scratch, scrubbedBin(scratch))
      check bad.exitCode == 2

    test "Linux with Nim missing from PATH: every step is listed, Nim is asked about, nothing is installed":
      let r = launch("--dry-run", scratch, scrubbedBin(scratch))
      check r.exitCode == 0
      for n in 1 .. 7: check ("[" & $n & "/7]") in r.output
      check "C compiler" in r.output
      check "Checking for git" in r.output
      check "Checking for Nim 2.2.10" in r.output
      check "Nim is missing. Install it now? (y/n)" in r.output
      check "would: wait for your answer; on n, stop here and change nothing" in r.output
      check "nim-2.2.10-linux_" in r.output
      check "SHA-256" in r.output
      check "no sudo" in r.output
      check "nimble install -d -y" in r.output
      check "nimble setup" in r.output
      check "nim c --hints:off --outdir:tmp tools/para/para.nim" in r.output or "tmp/para is already built" in r.output
      check "tmp/para studio" in r.output
      check "Dry run finished: nothing was installed, built or opened." in r.output
      check not hostHasAgent() == ("never handles sign-in" in r.output)
      if not hostHasAgent():
        check "https://code.claude.com/docs/en/setup" in r.output
        check "https://developers.openai.com/codex/cli" in r.output
      # nothing was written under the friend's home
      check not dirExists(scratch / ".paraloop")
      check not dirExists(scratch / ".nimble")

    test "macOS arm64 names the official arm64 download":
      let r = launch("--dry-run", scratch, scrubbedBin(scratch),
                     {"PARALOOP_LAUNCHER_OS": "Darwin", "PARALOOP_LAUNCHER_ARCH": "arm64"})
      check r.exitCode == 0
      check "Apple's command line tools" in r.output
      check "nim-2.2.10-macosx_arm64.tar.xz" in r.output
      check "nim-2.2.10-macosx_arm64.tar.xz.sha256" in r.output

    test "missing Apple tools: xcode-select would run, she is told to double-click again, nothing after it runs":
      let r = launch("--dry-run", scratch, scrubbedBin(scratch),
                     {"PARALOOP_LAUNCHER_OS": "Darwin", "PARALOOP_LAUNCHER_ARCH": "arm64",
                      "PARALOOP_LAUNCHER_FAKE_CLT": "missing"})
      check r.exitCode == 0
      check "xcode-select --install" in r.output
      check "click Install" in r.output
      check "double-click this file again" in r.output
      check "[2/7]" notin r.output

    test "an unsupported computer is told plainly":
      let r = launch("--dry-run", scratch, scrubbedBin(scratch),
                     {"PARALOOP_LAUNCHER_OS": "Darwin", "PARALOOP_LAUNCHER_ARCH": "ppc"})
      check r.exitCode == 1
      check "no official Nim 2.2.10 download" in r.output
      check "Please send the captain" in r.output

  suite "launcher: a real run against a throwaway checkout":
    var scratch, repo, fakeBin, home: string

    proc fakeProgram(path, body: string) =
      writeFile(path, "#!/bin/bash\n" & body)
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

    proc touch(path: string, secondsAgo: int) =
      setLastModificationTime(path, getTime() - initDuration(seconds = secondsAgo))

    setup:
      scratch = createTempDir("launcher", "")
      repo = scratch / "paraloop"
      home = scratch / "home"
      createDir(home)
      for d in ["tools" / "launcher", "tools" / "para", "src", "tmp", "libs" / "pkg"]: createDir(repo / d)
      copyFile(launcher, repo / launcher)
      setFilePermissions(repo / launcher, {fpUserRead, fpUserWrite, fpUserExec})
      writeFile(repo / "config.nims", "include \"nimble.paths\"\n")
      writeFile(repo / "paraloop.nimble", "requires \"nim == 2.2.10\"\n")
      writeFile(repo / "nimble.lock", "{}\n")
      writeFile(repo / "nimble.paths", "--path:\"" & repo / "libs" / "pkg" & "\"\n")
      writeFile(repo / "tools" / "para" / "para.nim", "echo 1\n")
      fakeBin = scrubbedBin(scratch)
      let marks = scratch / "marks.txt"
      fakeProgram(fakeBin / "nim", "if [ \"$1\" = --version ]; then echo 'Nim Compiler Version 2.2.10 [Linux: amd64]'; exit 0; fi\n" &
                                   "echo \"nim $*\" >> " & quoteShell(marks) & "\n" &
                                   "if [ -n \"${FAKE_NIM_FAIL:-}\" ]; then echo 'Error: fake compiler failure'; exit 1; fi\n" &
                                   "mkdir -p tmp && printf '#!/bin/bash\\necho studio \"$*\" >> " & marks & "\\n' > tmp/para && chmod +x tmp/para\n")
      fakeProgram(fakeBin / "nimble", "echo \"nimble $*\" >> " & quoteShell(marks) & "\n" &
                                      "mkdir -p " & quoteShell(repo / "libs" / "pkg") & "\n")
      for f in ["config.nims", "paraloop.nimble", "nimble.lock", "nimble.paths", "tools" / "para" / "para.nim"]:
        touch(repo / f, 1000)
    teardown: removeDir(scratch)

    proc marks(): string =
      if fileExists(scratch / "marks.txt"): readFile(scratch / "marks.txt") else: ""

    test "first run builds and starts Studio; the second run only starts Studio":
      let first = launch("", home, fakeBin, where = repo)
      check first.exitCode == 0
      check "nim c --hints:off --outdir:tmp tools/para/para.nim" in marks()
      check "studio studio" in marks()
      check "Studio opens in your browser" in first.output
      check fileExists(repo / "tmp" / "launcher.log")
      let before = marks().count("nim c")
      let second = launch("", home, fakeBin, where = repo)
      check second.exitCode == 0
      check marks().count("nim c") == before
      check "nimble" notin marks()
      check "tmp/para is already built and up to date." in second.output
      check "the libraries are already set up." in second.output
      check marks().count("studio studio") == 2

    test "a changed source file triggers a rebuild":
      discard launch("", home, fakeBin, where = repo)
      let built = marks().count("nim c")
      touch(repo / "tmp" / "para", 500)
      writeFile(repo / "tools" / "para" / "para.nim", "echo 2\n")
      discard launch("", home, fakeBin, where = repo)
      check marks().count("nim c") == built + 1

    test "a failed build prints the block to send the captain, names the log, and does not start Studio":
      let r = launch("", home, fakeBin, {"FAKE_NIM_FAIL": "1"}, where = repo)
      check r.exitCode == 1
      check "Something went wrong. Please send the captain everything between these lines." in r.output
      check "Step:     5 of 7, build para" in r.output
      check "Building para failed" in r.output
      check "Log file: " & repo / "tmp" / "launcher.log" in r.output
      check "studio" notin marks()
      check "Error: fake compiler failure" in readFile(repo / "tmp" / "launcher.log")

    test "libraries missing on disk are fetched again":
      removeDir(repo / "libs" / "pkg")
      let r = launch("", home, fakeBin, where = repo)
      check "nimble install -d -y" in marks()
      check "nimble setup" in marks()
      check r.exitCode == 0
      check "libraries ready." in r.output
      check dirExists(repo / "libs" / "pkg")
