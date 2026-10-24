# Static checks for the Windows double-click launcher (Paraloop-Studio.bat and the
# tools/launcher/launch.bat behind it). Batch cannot be run here (CI is Linux), so these read the
# files: that they would run on Windows at all (ASCII, CRLF, every goto and call has a label, no
# parenthesised blocks) and that they keep the promise in docs/windows.md (they only look: no
# install command is ever run). What the script does when it really runs on Windows is checked by
# the `windows-launcher` job in .github/workflows/platform-check.yml, by hand, and by the friend.

import std/[unittest, os, strutils, sets]

const
  wrapper = "Paraloop-Studio.bat"
  launcher = "tools" / "launcher" / "launch.bat"

proc codeLines(path: string): seq[string] =
  ## The lines of a batch file, without their CR.
  for l in readFile(path).split('\n'):
    result.add l.strip(leading = false, chars = {'\r'})

proc isComment(l: string): bool =
  l.strip.toLowerAscii.startsWith("rem ") or l.strip.toLowerAscii == "rem"

proc isEcho(l: string): bool =
  l.strip.toLowerAscii.startsWith("echo")

suite "launcher (Windows): the files":
  test "both files exist, are plain ASCII, and have CRLF line endings":
    for f in [wrapper, launcher]:
      check fileExists(f)
      let text = readFile(f)
      for i, c in text:
        if c > '\x7f': checkpoint(f & " has a non-ASCII byte at " & $i); fail()
        if c == '\n': check i > 0 and text[i - 1] == '\r'
      check text.startsWith("@echo off")

  test ".gitattributes keeps batch files CRLF":
    let attrs = readFile(".gitattributes")
    check "*.bat text eol=crlf" in attrs

  test "the double-click file hands over to the launcher with the pause switched on":
    let text = readFile(wrapper)
    check "tools\\launcher\\launch.bat" in text
    check "PARALOOP_LAUNCHER_PAUSE=1" in text
    check "%*" in text

suite "launcher (Windows): the script reads as batch that works":
  let lines = codeLines(launcher)

  test "every goto and call names a label that exists":
    var labels = initHashSet[string]()
    for l in lines:
      if l.startsWith(":") and not l.startsWith("::"): labels.incl l[1 .. ^1].strip.toLowerAscii
    for l in lines:
      if isComment(l) or isEcho(l): continue
      let words = l.splitWhitespace
      for i, w in words:
        let word = w.toLowerAscii
        if i + 1 < words.len and word in ["goto", "call"]:
          var target = words[i + 1].strip(chars = {'"'})
          if word == "goto" and not target.startsWith(":"): target = ":" & target
          if target.startsWith(":") and target.toLowerAscii != ":eof":
            let name = target[1 .. ^1].toLowerAscii
            check name in labels
            if name notin labels: checkpoint("no label :" & name & " (line: " & l & ")")

  test "no label is defined twice":
    var seen = initHashSet[string]()
    for l in lines:
      if l.startsWith(":") and not l.startsWith("::"):
        let name = l[1 .. ^1].strip.toLowerAscii
        check name notin seen
        seen.incl name

  test "no parenthesised blocks (a PATH with (x86) in it breaks them)":
    for l in lines:
      if isComment(l) or isEcho(l): continue
      let t = l.strip
      check not t.endsWith("(")
      check not t.startsWith(")")

  test "no delayed expansion (a folder name with ! in it breaks it)":
    for l in lines:
      if isComment(l): continue
      check "EnableDelayedExpansion" notin l
    check "DisableDelayedExpansion" in readFile(launcher)

  test "it only looks: it never runs an installer, a download, or a change to the computer":
    for l in lines:
      if isComment(l) or isEcho(l): continue
      let low = l.toLowerAscii
      for banned in ["winget install", "winget upgrade", "choco", "scoop", "msiexec", "curl", "wget", "powershell", "pwsh",
                     "invoke-webrequest", "bitsadmin", "certutil", "setx ", "reg add", "reg import",
                     "runas", "start-process", "expand-archive", "finish.exe"]:
        check banned notin low
        if banned in low: checkpoint("line runs " & banned & ": " & l)

  test "echoed text has no characters batch would run as commands":
    for l in lines:
      if not isEcho(l): continue
      let text = l.strip[4 .. ^1]
      if "^|" in text: continue # the log tail's quoted pipe sign
      for bad in ['&', '|', '<', '>']:
        check bad notin text
        if bad in text: checkpoint("echo has " & bad & ": " & l)

suite "launcher (Windows): the plain words":
  let text = readFile(launcher)

  test "same seven steps as the Mac launcher, in its order":
    check "STEPS=7" in text
    var last = -1
    for name in ["C compiler", "\"git\"", "Nim %NIM_VERSION%\"", "game libraries", "build para",
                 "claude or codex", "start Studio"]:
      let at = text.find("call :step ", last + 1)
      check at > last
      check text.find(name, at) > at
      last = at

  test "it says exactly what to install and from where":
    check "winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e" in text
    check "https://git-scm.com/download/win" in text
    check "winget install --id Git.Git -e" in text
    check "https://nim-lang.org/download/nim-2.2.10_x64.zip" in text
    check "https://code.claude.com/docs/en/setup" in text
    check "https://developers.openai.com/codex/cli" in text

  test "it says it installs nothing, and the dry run line the CI job looks for is there":
    check "never installs anything itself" in text
    check "Dry run finished: nothing was installed, built or opened." in text
    check "nim c --hints:off --outdir:tmp tools/para/para.nim" in text
    check "tmp\\para.exe studio" in text
