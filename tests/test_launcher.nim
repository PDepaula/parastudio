# Tests for the double-click launcher (Paraloop-Studio.command, paraloop-studio.sh and the shared
# tools/launcher/launch.sh behind them): that the files are runnable and, run from another folder,
# reach the launcher, that `--dry-run` (and `--check`, the same) lists every step and every install
# it would offer without installing, building, opening or asking anything (with Nim missing from PATH,
# and a C compiler and git pretended missing, so the "ask first" branches are reached), that the macOS
# branch says what it would do, and, against a throwaway checkout with fake `nim`/`nimble`/`para`, that
# a second run only starts Studio, that a failure prints the block the friend sends the captain, that
# the startup checks (`para studio --check`) are printed before Studio starts and never stop it, and
# that every offer to install takes only "y" or "yes" as yes: Enter, another answer and a closed input
# install nothing. Installs run against stand-ins: a fake `sudo` and `apt-get`, a fake `xcode-select`,
# and a fake `curl` that hands out a Nim archive made here. Nothing is downloaded, no real package
# manager, xcode-select or browser is run. Needs bash; skipped on Windows.

import std/[unittest, os, osproc, strutils, strtabs, tempfiles, times]

const
  command = "Paraloop-Studio.command"
  linuxScript = "paraloop-studio.sh"
  launcher = "tools" / "launcher" / "launch.sh"
  # every program the launcher may call in the steps these tests reach
  hostTools = ["bash", "uname", "dirname", "git", "grep", "sed", "awk", "find", "date", "cat", "tr", "head",
               "tail", "wc", "rm", "mkdir", "chmod", "mktemp", "sleep", "gcc", "cc", "id", "tar", "xz",
               "sha256sum", "mv", "cp", "printf"]
  compilers = ["gcc", "cc"]

proc scrubbedBin(dir: string, without: openArray[string] = []): string =
  ## A folder of links to the host programs the launcher needs and nothing else: no nim, no
  ## nimble, no claude, no codex, no curl, no sudo (and none of `without`).
  result = dir / "bin"
  createDir(result)
  for tool in hostTools:
    if tool in without: continue
    let found = findExe(tool)
    if found.len > 0 and not fileExists(result / tool): createSymlink(found, result / tool)

proc launch(args: string, home, path: string, extra: openArray[(string, string)] = [],
            where = "", script = launcher, answer = ""): tuple[output: string, exitCode: int] =
  ## Runs the launcher with `answer` as everything typed into it; its input is then closed.
  var env = newStringTable()
  env["HOME"] = home
  env["PATH"] = path
  env["TMPDIR"] = home
  for (k, v) in extra: env[k] = v
  let cwd = if where.len > 0: where else: getCurrentDir()
  execCmdEx(quoteShell(findExe("bash")) & " " & quoteShell(cwd / script) & " " & args, env = env,
            workingDir = cwd, input = answer)

proc fakeProgram(path, body: string) =
  writeFile(path, "#!/bin/bash\n" & body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc copyBin(src, dest: string, without: openArray[string]) =
  ## A copy of the folder of programs `src` (links stay links) without the programs in `without`.
  createDir(dest)
  for kind, f in walkDir(src):
    let name = f.extractFilename
    if name in without: continue
    if kind == pcLinkToFile: createSymlink(expandSymlink(f), dest / name)
    else: copyFileWithPermissions(f, dest / name)

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
      check "--check" in h.output
      let bad = launch("--bogus", scratch, scrubbedBin(scratch))
      check bad.exitCode == 2

    test "Linux with Nim missing from PATH: every step is listed, Nim is asked about, nothing is installed":
      let r = launch("--dry-run", scratch, scrubbedBin(scratch))
      check r.exitCode == 0
      for n in 1 .. 7: check ("[" & $n & "/7]") in r.output
      check "C compiler" in r.output
      check "Checking for git" in r.output
      check "Checking for Nim 2.2.10" in r.output
      check "Nim 2.2.10 is not installed." in r.output
      check "would: ask you: Download and install Nim 2.2.10 now? (y/n, Enter means no)" in r.output
      check "would: on n or Enter, stop here and change nothing" in r.output
      check "From:    https://nim-lang.org/download/nim-2.2.10-linux_" in r.output
      check "Where:   " & scratch / ".paraloop" / "nim-2.2.10" in r.output
      check "Size:    about 1" in r.output
      check "PATH:    added for this run only; your shell settings are not changed" in r.output
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

    test "--check is the same dry run, and asks nothing even when an answer is waiting":
      let r = launch("--check", scratch, scrubbedBin(scratch), answer = "y\ny\ny\n")
      check r.exitCode == 0
      check "Dry run finished: nothing was installed, built or opened." in r.output
      check "Enter means no) " notin r.output # the real question ends in a space and waits; the dry run only quotes it
      check not dirExists(scratch / ".paraloop")

    test "Linux with no C compiler and no git: the package-manager command is shown, never run":
      let bin = scrubbedBin(scratch)
      let marks = scratch / "marks.txt"
      fakeProgram(bin / "apt-get", "echo \"apt-get $*\" >> " & quoteShell(marks) & "\n")
      fakeProgram(bin / "sudo", "echo \"sudo $*\" >> " & quoteShell(marks) & "\n")
      let r = launch("--dry-run", scratch, bin, {"PARALOOP_LAUNCHER_FAKE_MISSING": "cc,git"}, answer = "y\ny\n")
      check r.exitCode == 0
      check "No C compiler was found." in r.output
      check "Command: sudo apt-get install build-essential" in r.output
      check "git was not found." in r.output
      check "Command: sudo apt-get install git" in r.output
      check "From:    the package servers apt-get is already set up to use" in r.output
      check "would: ask you: Run that command now? (y/n, Enter means no)" in r.output
      check "would: on n or Enter, stop here with nothing installed" in r.output
      check not fileExists(marks)

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
      check "Command: xcode-select --install" in r.output
      check "Where:   /Library/Developer/CommandLineTools" in r.output
      check "would: ask you: Open Apple's installer now? (y/n, Enter means no)" in r.output
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
                                   "mkdir -p tmp && printf '#!/bin/bash\\necho studio \"$*\" >> " & marks & "\\n" &
                                   "if [ \"$2\" = --check ]; then echo \"Claude: not ready yet\"; echo \"       fix: a fake fix line\"; exit 1; fi\\n' > tmp/para && chmod +x tmp/para\n")
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

    test "the startup checks are printed after the build and before Studio, and never stop it":
      fakeProgram(fakeBin / "claude", "exit 0\n")
      let r = launch("", home, fakeBin, where = repo)
      check r.exitCode == 0
      check "studio studio --check" in marks()
      check "studio studio\n" in marks()
      check "found Claude Code: " & fakeBin / "claude" in r.output
      check "      Claude: not ready yet" in r.output
      check "             fix: a fake fix line" in r.output
      let checks = r.output.find("Claude: not ready yet")
      check checks > r.output.find("[5/7]")
      check checks < r.output.find("Studio opens in your browser")
      check "Claude: not ready yet" in readFile(repo / "tmp" / "launcher.log")

    test "--no-studio sets up, builds and prints the startup checks, then stops without starting Studio":
      fakeProgram(fakeBin / "claude", "exit 0\n")
      let r = launch("--no-studio", home, fakeBin, where = repo)
      check r.exitCode == 0
      check "nim c --hints:off --outdir:tmp tools/para/para.nim" in marks()
      check "studio studio --check" in marks()
      check "studio studio\n" notin marks()
      check "[7/7] Starting Studio..." in r.output
      check "not started now (--no-studio)." in r.output
      check "Studio opens in your browser" notin r.output

    test "a dry run names the startup checks and runs nothing":
      fakeProgram(fakeBin / "claude", "exit 0\n")
      let r = launch("--dry-run", home, fakeBin, where = repo)
      check r.exitCode == 0
      check "would: run: tmp/para studio --check" in r.output
      check "studio" notin marks()

    # --- offers to install, against stand-ins ---------------------------------------------------

    proc noCompilerBin(): string =
      ## The fake bin of this suite without any C compiler, plus a fake `sudo` (it runs what it is
      ## given) and a fake `apt-get` that "installs" a stand-in `cc` there.
      result = scratch / "bin-nocc"
      copyBin(fakeBin, result, compilers)
      let marksFile = scratch / "marks.txt"
      fakeProgram(result / "sudo", "echo \"sudo $*\" >> " & quoteShell(marksFile) & "\n\"$@\"\n")
      fakeProgram(result / "apt-get", "echo \"apt-get $*\" >> " & quoteShell(marksFile) & "\n" &
                                     "printf '#!/bin/bash\\n' > " & quoteShell(result / "cc") & "\n" &
                                     "chmod +x " & quoteShell(result / "cc") & "\n")

    test "no C compiler: only y or yes runs the shown command; Enter, another answer and a closed input do not":
      for answer in ["", "\n", "n\n", "maybe\n", "yy\n", " y\n"]:
        let bin = noCompilerBin()
        let r = launch("", home, bin, where = repo, answer = answer)
        checkpoint("answer: " & answer.escape)
        check r.exitCode == 1
        check "Command: sudo apt-get install build-essential" in r.output
        check "Run that command now? (y/n, Enter means no)" in r.output
        check "Okay, nothing was installed and nothing changed." in r.output
        check "sudo apt-get install build-essential" in r.output
        check "sudo" notin marks()
        check "studio" notin marks()
        check "Something went wrong" notin r.output
        removeDir(bin)
      let closed = launch("", home, noCompilerBin(), where = repo)
      check "no answer could be read, so the answer is no" in closed.output

    test "no C compiler, answered y: the shown command runs once and the launcher carries on":
      for answer in ["y\n", "yes\n"]:
        let bin = noCompilerBin()
        removeFile(scratch / "marks.txt")
        let r = launch("", home, bin, where = repo, answer = answer)
        check r.exitCode == 0
        check marks().count("sudo apt-get install build-essential") == 1
        check "apt-get install build-essential" in marks()
        check "ok: found a C compiler." in r.output
        check "studio studio" in marks()
        removeDir(bin)

    test "unattended (PARALOOP_LAUNCHER_UNATTENDED=1): an offer is answered no without asking, even with y waiting":
      let bin = noCompilerBin()
      let r = launch("--no-studio", home, bin, {"PARALOOP_LAUNCHER_UNATTENDED": "1"}, where = repo, answer = "y\n")
      check r.exitCode == 1
      check "Command: sudo apt-get install build-essential" in r.output
      check "Run that command now? No: this is an unattended run, and nothing is installed without a person typing y." in r.output
      check "(y/n, Enter means no)" notin r.output
      check "Okay, nothing was installed and nothing changed." in r.output
      check "sudo" notin marks()
      check "studio" notin marks()

    proc nimArchive(dir: string): string =
      ## A stand-in for nim-2.2.10-linux_x64.tar.xz: a `nim` that answers --version and a `nimble`.
      let top = dir / "nim-2.2.10" / "bin"
      createDir(top)
      fakeProgram(top / "nim", readFile(fakeBin / "nim"))
      fakeProgram(top / "nimble", readFile(fakeBin / "nimble"))
      result = dir / "nim-2.2.10-linux_x64.tar.xz"
      let (o, code) = execCmdEx("tar -cJf " & quoteShell(result) & " -C " & quoteShell(dir) & " nim-2.2.10")
      doAssert code == 0, o

    proc noNimBin(served: string, published: string): string =
      ## The fake bin without nim or nimble, and a fake `curl` that logs the link it was given and
      ## hands out `served` for the archive and `published` for its .sha256 file. Nothing is downloaded.
      result = scratch / "bin-nonim"
      copyBin(fakeBin, result, ["nim", "nimble"])
      writeFile(scratch / "published.sha256", published & "  nim-2.2.10-linux_x64.tar.xz\n")
      fakeProgram(result / "curl",
        "out=''; url=''\n" &
        "while [ $# -gt 0 ]; do case \"$1\" in -o) out=$2; shift ;; https://*) url=$1 ;; esac; shift; done\n" &
        "echo \"curl $url\" >> " & quoteShell(scratch / "marks.txt") & "\n" &
        "case \"$url\" in\n" &
        "  *.sha256) cat " & quoteShell(scratch / "published.sha256") & " ;;\n" &
        "  *) cp " & quoteShell(served) & " \"$out\" ;;\n" &
        "esac\n")

    proc pinTo(sha: string) =
      ## The copy of the launcher in the throwaway checkout, with the stand-in archive's checksum
      ## written where the real one is.
      let path = repo / launcher
      var text = readFile(path)
      let real = "linux_x64)    echo 0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211"
      doAssert real in text
      writeFile(path, text.replace(real, "linux_x64)    echo " & sha))

    proc sha256(path: string): string =
      execCmdEx("sha256sum " & quoteShell(path)).output.splitWhitespace[0]

    const linux64 = {"PARALOOP_LAUNCHER_OS": "Linux", "PARALOOP_LAUNCHER_ARCH": "x86_64"}

    test "no Nim, answered n or nothing: nothing is downloaded and nothing lands in the home folder":
      let archive = nimArchive(scratch / "fixture")
      pinTo(sha256(archive))
      for answer in ["", "\n", "n\n"]:
        let r = launch("", home, noNimBin(archive, sha256(archive)), linux64, where = repo, answer = answer)
        check r.exitCode == 1
        check "From:    https://nim-lang.org/download/nim-2.2.10-linux_x64.tar.xz" in r.output
        check "Size:    about 18 MB" in r.output
        check "Download and install Nim 2.2.10 now? (y/n, Enter means no)" in r.output
        check "Okay, nothing was installed and nothing changed." in r.output
        check "curl" notin marks()
        check not dirExists(home / ".paraloop")
        removeDir(scratch / "bin-nonim")

    test "no Nim, answered y: the official link is fetched, the checksum checked, Nim unpacked in the home folder":
      let archive = nimArchive(scratch / "fixture")
      pinTo(sha256(archive))
      let r = launch("", home, noNimBin(archive, sha256(archive)), linux64, where = repo, answer = "y\n")
      check r.exitCode == 0
      check "curl https://nim-lang.org/download/nim-2.2.10-linux_x64.tar.xz\n" in marks()
      check "curl https://nim-lang.org/download/nim-2.2.10-linux_x64.tar.xz.sha256" in marks()
      check "checksum matches (" & sha256(archive) & ")" in r.output
      check fileExists(home / ".paraloop" / "nim-2.2.10" / "bin" / "nim")
      check "Nim 2.2.10 installed in " & home / ".paraloop" / "nim-2.2.10" in r.output
      check "studio studio" in marks()
      # nothing besides that folder was written in the home folder: no shell profile was touched
      var written: seq[string]
      for kind, f in walkDir(home): written.add f.extractFilename
      check written == @[".paraloop"]

    test "no Nim, answered y, but the download does not match the published checksum: stop, nothing installed":
      let archive = nimArchive(scratch / "fixture")
      pinTo(sha256(archive))
      let r = launch("", home, noNimBin(archive, repeat('0', 64)), linux64, where = repo, answer = "y\n")
      check r.exitCode == 1
      check "does not match its published checksum, so it was NOT used and nothing was installed" in r.output
      check not dirExists(home / ".paraloop" / "nim-2.2.10")
      check "studio" notin marks()

    test "no Nim, answered y, but the download does not match the checksum in the launcher: stop, nothing installed":
      let archive = nimArchive(scratch / "fixture")
      let r = launch("", home, noNimBin(archive, sha256(archive)), linux64, where = repo, answer = "y\n")
      check r.exitCode == 1
      check "does not match its published checksum" in r.output
      check not dirExists(home / ".paraloop" / "nim-2.2.10")

    test "macOS without Apple's tools: asked first; only y opens Apple's installer":
      let marksFile = scratch / "marks.txt"
      fakeProgram(fakeBin / "xcode-select", "echo \"xcode-select $*\" >> " & quoteShell(marksFile) & "\n" &
                                            "if [ \"$1\" = -p ]; then exit 2; fi\n")
      let mac = {"PARALOOP_LAUNCHER_OS": "Darwin", "PARALOOP_LAUNCHER_ARCH": "arm64"}
      let no = launch("", home, fakeBin, mac, where = repo, answer = "\n")
      check no.exitCode == 1
      check "Open Apple's installer now? (y/n, Enter means no)" in no.output
      check "--install" notin marks()
      check "xcode-select --install" in no.output # the by-hand instruction
      let yes = launch("", home, fakeBin, mac, where = repo, answer = "y\n")
      check yes.exitCode == 0
      check "xcode-select --install" in marks()
      check "click Install" in yes.output
      check "[2/7]" notin yes.output
