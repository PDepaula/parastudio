# Structural checks for the Windows double-click launcher (Paraloop-Studio.bat and the
# tools/launcher/launch.bat behind it). Batch cannot be run here (CI is Linux), so these only check
# the bytes and shape cmd.exe needs to run the files at all: plain ASCII, CRLF line endings, every
# goto and call has a label, no label twice, no parenthesised blocks; and the rules of its offers to
# install, read from the script's text: `--dry-run` and `--check` both make a dry run, the one way
# it asks takes only y or yes as yes (Enter and a closed input leave the answer no), every install
# command comes after a dry-run exit and a yes in its own section, each offer names what, from
# where, where to and how big, the Nim zip is checked against a pinned SHA-256, and nothing runs
# sudo, edits the registry or PATH for good, or pipes a download into a shell. What the script does
# when it really runs on Windows is checked by the `windows-launcher` job in
# .github/workflows/platform-check.yml, by hand, and by the friend.

import std/[unittest, os, strutils, sets, tables, sequtils]

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

suite "launcher (Windows): the script is well-formed batch":
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

proc sections(lines: seq[string]): OrderedTable[string, seq[string]] =
  ## The script cut at its labels: each label's name and the lines up to the next label. The lines
  ## before the first label are under "".
  var name = ""
  result[name] = @[]
  for l in lines:
    if l.startsWith(":") and not l.startsWith("::"):
      name = l[1 .. ^1].strip.toLowerAscii
      result[name] = @[]
    else:
      result[name].add l

proc code(l: string): string = l.strip

suite "launcher (Windows): offers to install":
  let lines = codeLines(launcher)
  let parts = sections(lines)
  let installs = ["%CC_WINGET%", "%GIT_WINGET%", "call :install_nim"]

  test "--dry-run and --check both make a dry run":
    check "if /i \"%~1\"==\"--dry-run\" set \"DRY_RUN=1\" & shift & goto parse_args" in lines
    check "if /i \"%~1\"==\"--check\" set \"DRY_RUN=1\" & shift & goto parse_args" in lines

  test "the one question: no unless y or yes was typed; Enter or a closed input stay no":
    check "ask" in parts
    let ask = parts["ask"].filterIt(not isComment(it)).mapIt(code(it))
    let prompt = ask.find("set /p \"REPLY=      %~1 (y/n, Enter means no) \"")
    check prompt > 0
    check ask.find("set \"ANSWER=no\"") in 0 ..< prompt
    check ask.find("set \"REPLY=\"") in 0 ..< prompt
    var yes: seq[string]
    for l in ask:
      if "\"RES=yes\"" in l: yes.add l
    check yes == @["if /i \"!REPLY!\"==\"y\" set \"RES=yes\"", "if /i \"!REPLY!\"==\"yes\" set \"RES=yes\""]
    check "set \"RES=no\"" in ask
    # nothing else asks
    for l in lines:
      if not isComment(l) and "set /p" in l.toLowerAscii: check "REPLY=" in l

  test "every install runs only after the dry-run exit and a yes, in its own section":
    var seen = 0
    for name, body in parts:
      let b = body.filterIt(not isComment(it)).mapIt(code(it))
      for i, l in b:
        if l notin installs: continue
        inc seen
        checkpoint(":" & name & " runs " & l)
        let dry = b.find("if \"%DRY_RUN%\"==\"1\" if not defined DRY_ASK goto offer_dry")
        let dryNim = b.find("if \"%DRY_RUN%\"==\"1\" if not defined DRY_ASK goto offer_nim_dry")
        check max(dry, dryNim) in 0 ..< i
        var asked = -1
        for j in 0 ..< i:
          if b[j].startsWith("call :ask "): asked = j
        check asked >= 0
        check b[asked + 1] == "if not \"%ANSWER%\"==\"yes\" exit /b 0"
        check b[asked + 2].startsWith("if defined DRY_ASK call :would ") and b[asked + 2].endsWith(" & exit /b 0")
        check asked + 2 < i
    check seen == installs.len
    # the downloads happen only inside :install_nim
    for name, body in parts:
      for l in body:
        if not isComment(l) and "curl.exe -" in l: check name == "install_nim"

  test "the dry-run question hook is read only in a dry run and asks before it says what it would do":
    check "set \"DRY_ASK=\"" in lines
    check "if \"%DRY_RUN%\"==\"1\" if \"%PARALOOP_LAUNCHER_DRY_ASK%\"==\"1\" set \"DRY_ASK=1\"" in lines
    for l in lines:
      if not isComment(l) and "PARALOOP_LAUNCHER_DRY_ASK" in l:
        check l.startsWith("if \"%DRY_RUN%\"==\"1\" ")
    for name in ["offer_cc", "offer_git", "offer_nim"]:
      let b = parts[name].filterIt(not isComment(it)).mapIt(code(it))
      checkpoint(name)
      check b.anyIt(it.startsWith("if \"%DRY_RUN%\"==\"1\" if not defined DRY_ASK goto "))
      check b.anyIt(it.startsWith("if defined DRY_ASK call :would \"install "))

  test "echoed and logged text has no redirect characters (a bare > writes a file named after the rest)":
    for l in lines:
      if isComment(l): continue
      let t = code(l)
      var text = ""
      if t.toLowerAscii.startsWith("echo "): text = t[5 .. ^1]
      else:
        for fn in ["call :log ", "call :note ", "call :ok ", "call :bad ", "call :would "]:
          let at = t.find(fn)
          if at >= 0: text = t[at + fn.len .. ^1].split(" & ")[0]
      if text.len == 0: continue
      checkpoint(l)
      check '<' notin text
      check '>' notin text

  test "each offer says what, from where, the command or link, where to and how big":
    for name in ["offer_cc", "offer_git", "offer_nim"]:
      let text = parts[name].join("\n")
      checkpoint(name)
      for field in ["What:", "From:", "Where:", "Size:", "PATH:"]: check field in text
    check "Command: %CC_WINGET%" in parts["offer_cc"].join("\n")
    check "Command: %GIT_WINGET%" in parts["offer_git"].join("\n")
    check "From:    %NIM_ZIP_URL%" in parts["offer_nim"].join("\n")

  test "the Nim zip comes from nim-lang.org and must match the published and the pinned SHA-256":
    check "set \"NIM_ZIP_URL=https://nim-lang.org/download/nim-2.2.10_x64.zip\"" in lines
    check "set \"NIM_ZIP_SHA256=fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f\"" in lines
    let body = parts["install_nim"].mapIt(code(it))
    let unpack = body.find("tar.exe -xf \"%WORK%\\%NIM_ZIP%\" -C \"%WORK%\" >>\"%LOG%\" 2>&1")
    check unpack > 0
    check body.find("if /i not \"%ACTUAL%\"==\"%NIM_ZIP_SHA256%\" goto nim_bad_sum") in 0 ..< unpack
    check body.find("if /i not \"%ACTUAL%\"==\"%PUBLISHED%\" goto nim_bad_sum") in 0 ..< unpack
    check "set \"NIM_HOME=%USERPROFILE%\\.paraloop\\nim-2.2.10\"" in lines

  test "nothing runs as administrator, changes PATH for good, edits the registry or runs a download":
    for l in lines:
      if isComment(l) or isEcho(l): continue
      let t = l.toLowerAscii
      for banned in ["sudo", "runas", "setx", "reg add", "reg.exe", "powershell", "iex", "invoke-expression",
                     "finish.exe", "| cmd", "|cmd", "start-process"]:
        if banned in t:
          checkpoint("banned \"" & banned & "\" in: " & l)
          fail()

  test "the startup checks run after the build and before Studio, and never stop it":
    let checks = lines.find("tmp\\para.exe studio --check")
    let build = lines.find("call nim c --hints:off --outdir:tmp tools/para/para.nim >>\"%LOG%\" 2>&1")
    let studio = lines.find("tmp\\para.exe studio")
    check build > 0 and checks > build and studio > checks
    check not lines[checks + 1].toLowerAscii.contains("errorlevel")
