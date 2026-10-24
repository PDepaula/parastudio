# Structural checks for the Windows double-click launcher (Paraloop-Studio.bat and the
# tools/launcher/launch.bat behind it). Batch cannot be run here (CI is Linux), so these only check
# the bytes and shape cmd.exe needs to run the files at all: plain ASCII, CRLF line endings, every
# goto and call has a label, no label twice, no parenthesised blocks. What the script does when it
# really runs on Windows is checked by the `windows-launcher` job in
# .github/workflows/platform-check.yml, by hand, and by the friend.

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
