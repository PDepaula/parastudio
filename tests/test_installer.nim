# Tests for the one-line installer for macOS and Linux (tools/launcher/install.sh), against a
# throwaway repository whose launcher is a stand-in that only notes how it was run and makes
# tmp/para: that an unstamped copy says it is not pinned and uses main, that a copy stamped the way
# tools/docs/build.py stamps it checks out exactly that commit on `main` and refuses a commit the
# repository does not have, that an existing folder is never overwritten (a Para Studio copy is only
# set up again; anything else is refused untouched), that the launcher runs with --no-studio and, in
# an unattended run, with PARALOOP_LAUNCHER_UNATTENDED=1 and no input, that a launcher that stops
# stops the installer, and that a missing git or a missing terminal stops it before anything is
# done. The real launcher and the published copy are run end to end by
# .github/workflows/installer.yml. Needs sh, bash and git; skipped on Windows.

import std/[unittest, os, osproc, strutils, strtabs, tempfiles]

const
  installer = "tools" / "launcher" / "install.sh"
  emptyCommitLine = "PARASTUDIO_COMMIT=\"\""

when defined(windows):
  suite "installer":
    test "skipped on Windows (install.sh is for macOS and Linux)":
      skip()
else:
  proc git(dir: string, args: string): string =
    let (o, code) = execCmdEx("git -C " & quoteShell(dir) & " " & args)
    doAssert code == 0, args & ": " & o
    o.strip

  suite "installer: install.sh":
    var scratch, origin, home, marks, script: string
    var first, second: string # the throwaway repository's two commits on main

    setup:
      scratch = createTempDir("installer", "")
      origin = scratch / "origin"
      home = scratch / "home"
      marks = scratch / "marks.txt"
      createDir(home)
      createDir(origin / "tools" / "launcher")
      writeFile(origin / "tools" / "launcher" / "launch.sh",
        "echo \"launch $* unattended=${PARALOOP_LAUNCHER_UNATTENDED:-0}\" >> " & quoteShell(marks) & "\n" &
        "if [ -n \"${FAKE_LAUNCH_FAIL:-}\" ]; then echo 'launcher: a fake failure'; exit 1; fi\n" &
        "read -r line && echo \"launch read: $line\" >> " & quoteShell(marks) & "\n" &
        "cd \"$(dirname \"$0\")/../..\" && mkdir -p tmp && printf '#!/bin/sh\\n' > tmp/para && chmod +x tmp/para\n")
      writeFile(origin / "README.md", "one\n")
      writeFile(origin / ".gitignore", "tmp/\n")
      discard execCmdEx("git init -q -b main " & quoteShell(origin))
      discard git(origin, "config user.email test@example.com")
      discard git(origin, "config user.name test")
      discard git(origin, "add -A")
      discard git(origin, "commit -q -m one")
      first = git(origin, "rev-parse HEAD")
      writeFile(origin / "README.md", "two\n")
      discard git(origin, "commit -q -am two")
      second = git(origin, "rev-parse HEAD")
      script = scratch / "install.sh"
      copyFile(installer, script)
    teardown: removeDir(scratch)

    proc stamp(sha: string) =
      ## The copy the docs build publishes: the one empty commit line filled in, nothing else.
      let text = readFile(installer)
      doAssert text.count("\n" & emptyCommitLine & "\n") == 1
      writeFile(script, text.replace("\n" & emptyCommitLine & "\n", "\nPARASTUDIO_COMMIT=\"" & sha & "\"\n"))

    proc run(extra: openArray[(string, string)] = [], path = getEnv("PATH"), viaPipe = true): tuple[output: string, exitCode: int] =
      ## Runs the installer the way the one-liner does (piped into sh), unattended unless `extra` says otherwise.
      var env = newStringTable()
      env["HOME"] = home
      env["PATH"] = path
      env["PARASTUDIO_REPO"] = origin
      env["PARASTUDIO_YES"] = "1"
      for (k, v) in extra: env[k] = v
      let cmd = if viaPipe: "cat " & quoteShell(script) & " | sh" else: "sh " & quoteShell(script)
      execCmdEx(cmd, env = env, workingDir = scratch)

    proc launched(): string =
      if fileExists(marks): readFile(marks) else: ""

    test "unstamped: says it is not pinned, clones main into ~/parastudio and runs the launcher unattended":
      let r = run()
      check r.exitCode == 0
      check "has no commit written into it" in r.output
      check "the newest commit on main (not pinned)" in r.output
      check "Where:   " & home / "parastudio" & " (a new folder)" in r.output
      check git(home / "parastudio", "rev-parse HEAD") == second
      check git(home / "parastudio", "symbolic-ref --short HEAD") == "main"
      check "launch --no-studio unattended=1\n" in launched()
      check "launch read:" notin launched() # an unattended launcher gets no input
      check "Para Studio is installed in " & home / "parastudio" in r.output
      check "Start Para Studio now?" notin r.output

    test "stamped: checks out exactly that commit on main and says so":
      stamp(first)
      let r = run()
      check r.exitCode == 0
      check "commit " & first & " (the code this installer was published with)" in r.output
      check "is at commit " & first & ", the one this installer names." in r.output
      check "not pinned" notin r.output
      check git(home / "parastudio", "rev-parse HEAD") == first
      check git(home / "parastudio", "symbolic-ref --short HEAD") == "main"
      check git(home / "parastudio", "status --porcelain") == ""

    test "stamped with a commit the repository does not have: stops":
      stamp(repeat('a', 40))
      let r = run()
      check r.exitCode == 1
      check "commit " & repeat('a', 40) & " was not found" in r.output
      check "launch" notin launched()

    test "PARASTUDIO_DIR picks the folder":
      let r = run({"PARASTUDIO_DIR": scratch / "elsewhere" / "studio"})
      check r.exitCode == 0
      check fileExists(scratch / "elsewhere" / "studio" / "tmp" / "para")
      check not dirExists(home / "parastudio")

    test "a folder in the way that is not a Para Studio copy is refused and left untouched":
      createDir(home / "parastudio")
      writeFile(home / "parastudio" / "mine.txt", "keep\n")
      let r = run()
      check r.exitCode == 1
      check "already exists and is not a Para Studio copy. I will not touch it." in r.output
      check "Go ahead?" notin r.output
      var left: seq[string]
      for kind, f in walkDir(home / "parastudio"): left.add f.extractFilename
      check left == @["mine.txt"]
      check "launch" notin launched()

    test "a second run changes no file and only runs the launcher again":
      stamp(first)
      check run().exitCode == 0
      writeFile(home / "parastudio" / "games-note.txt", "the friend's own file\n")
      let r = run()
      check r.exitCode == 0
      check "already holds a Para Studio copy (at commit " & first & ")" in r.output
      check "I will not replace or update any file in it" in r.output
      check "Cloning" notin r.output
      check git(home / "parastudio", "rev-parse HEAD") == first
      check readFile(home / "parastudio" / "games-note.txt") == "the friend's own file\n"
      check launched().count("launch --no-studio") == 2

    test "a launcher that stops stops the installer":
      let r = run({"FAKE_LAUNCH_FAIL": "1"})
      check r.exitCode == 1
      check "launcher: a fake failure" in r.output
      check "Stopped: the launcher stopped" in r.output
      check "Para Studio is installed" notin r.output

    test "no git: stops before anything is done, with how to get it":
      let bin = scratch / "bin"
      createDir(bin)
      for tool in ["sh", "cat", "uname", "bash"]:
        let found = findExe(tool)
        if found.len > 0: createSymlink(found, bin / tool)
      let r = run(path = bin)
      check r.exitCode == 1
      check "git: not found." in r.output
      check "Stopped: git is missing." in r.output
      check not dirExists(home / "parastudio")

    test "not unattended and no terminal to answer in: stops before anything is done":
      if findExe("setsid").len == 0: skip() # setsid gives the run no terminal; not on macOS
      else:
        var env = newStringTable()
        env["HOME"] = home
        env["PATH"] = getEnv("PATH")
        env["PARASTUDIO_REPO"] = origin
        let r = execCmdEx("setsid -w sh " & quoteShell(script) & " </dev/null", env = env, workingDir = scratch)
        check r.exitCode == 1
        check "there is no terminal to type an answer in" in r.output
        check not dirExists(home / "parastudio")
