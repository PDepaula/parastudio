# Tests for `para check`'s purity step (tools/para/purity.nim): a pure fixture game and the
# template pass, an impure fixture fails on exactly its marked lines with plain `file:line:`
# messages, and every engine module is either banned in a core file or named safe. Nothing compiles
# the fixtures; tests/test_para_check_cmd.nim covers the step inside `para check`.

import std/[unittest, os, strutils, sets, algorithm]
import tools/para/purity

const
  repo = currentSourcePath().parentDir.parentDir
  fixtures = currentSourcePath().parentDir / "fixtures" / "purity"

proc at(found: seq[Finding]): seq[string] =
  ## `file:line` of every finding, the file as its bare name, sorted.
  for f in found: result.add f.file.extractFilename & ":" & $f.line
  result.sort()

proc msgAt(found: seq[Finding], file: string, line: int): string =
  for f in found:
    if f.file.extractFilename == file and f.line == line: return f.msg

suite "purity: what passes":
  test "the pure fixture uses every allowed import and then call, and passes":
    let found = purityFindings(fixtures / "pure")
    checkpoint $found
    check found.len == 0
    let r = runPurity(fixtures / "pure")
    check r.code == 0
    check r.output.startsWith("purity: ")

  test "the template every new game starts from passes":
    check purityFindings(repo / "template").len == 0

  test "the hello example passes (it has no core files of its own)":
    check purityFindings(repo / "examples" / "hello").len == 0

  test "open and quit pass as a variable, a field or an enum member, and fail only when called":
    let dir = getTempDir() / "purity-open-quit"
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "systems.nim",
      "type\n  Menu = enum\n    play, quit\n  Door = object\n    open: bool\n" &
      "proc open(d: var Door) = d.open = true\n" &
      "proc f(d: var Door, m: Menu) =\n  var open = @[1]\n  if d.open and m == quit: open.add 2\n" &
      "  if open.len > 9: quit(1)\n")
    check purityFindings(dir).at == @["systems.nim:10"]

  test "a game with no core files passes":
    check purityFindings(fixtures / "missing").len == 0

suite "purity: what fails":
  let found = purityFindings(fixtures / "impure")

  test "exactly the marked lines, in every core file":
    check found.at == @[
      "data.nim:1",
      "rules.nim:16", "rules.nim:17", "rules.nim:18", "rules.nim:19", "rules.nim:2",
      "rules.nim:20", "rules.nim:22", "rules.nim:23", "rules.nim:29",
      "rules.nim:3", "rules.nim:35", "rules.nim:5", "rules.nim:7",
      "systems.nim:14", "systems.nim:15", "systems.nim:16",
      "systems.nim:2", "systems.nim:3", "systems.nim:4", "systems.nim:5", "systems.nim:6",
      "systems.nim:9"]

  test "a banned import names the module and the effect":
    check found.msgAt("rules.nim", 2).startsWith("imports std/times, which a core file may not: it reads the clock")
    check found.msgAt("rules.nim", 3).startsWith("imports std/os, ")
    check found.msgAt("rules.nim", 5).startsWith("imports paraloop/render2d, which a core file may not: it draws")
    check found.msgAt("rules.nim", 7).startsWith("imports paranim/gl, ")
    check found.msgAt("data.nim", 1).startsWith("imports std/osproc, which a core file may not: it starts programs")
    check found.msgAt("systems.nim", 2).startsWith("imports std/monotimes, ")
    check found.msgAt("systems.nim", 3).startsWith("imports std/os, ")

  test "an import behind a one-line elif or else, or with its modules on the lines below, is read":
    check found.msgAt("systems.nim", 4).startsWith("imports std/times, ")
    check found.msgAt("systems.nim", 5).startsWith("imports std/rdstdin, which a core file may not: it reads the keyboard")
    check found.msgAt("systems.nim", 6).startsWith("imports std/oids, which a core file may not: it reads the clock")
    check found.msgAt("systems.nim", 9).startsWith("imports std/parseopt, which a core file may not: it reads the command line")

  test "system's effects are refused anywhere in a core file, so a game proc cannot hide one":
    check found.msgAt("rules.nim", 16).startsWith("uses echo, which a core file may not: it writes output")
    check found.msgAt("rules.nim", 18).startsWith("uses readFile, which a core file may not: it reads files")
    check found.msgAt("rules.nim", 29).startsWith("uses quit, which a core file may not: it quits the program")
    check found.msgAt("systems.nim", 14).startsWith("uses echo, which a core file may not: it writes output")
    check found.msgAt("systems.nim", 15).startsWith("uses read_file, which a core file may not: it reads files")
    check found.msgAt("systems.nim", 16).startsWith("uses quit, which a core file may not: it quits the program")
    check found.msgAt("rules.nim", 36) == "" # the then's call to that proc (stamp) is not itself refused

  test "a refused then call names the rule and the call":
    check found.msgAt("rules.nim", 17).startsWith("rule tickTime's then calls epochTime: a then may call only " &
                                                  "session.insert, session.nextId, session.rng and pure helpers")
    check found.msgAt("rules.nim", 19).startsWith("rule tickTime's then calls session.retract (never retract inside a then")
    check found.msgAt("rules.nim", 20).startsWith("rule tickTime's then calls rand (std/random's global RNG")
    check found.msgAt("rules.nim", 22).startsWith("rule tickTime's then calls shuffle (std/random's global RNG")
    check found.msgAt("rules.nim", 23).startsWith("rule tickTime's then calls session.fireRules: ")
    check found.msgAt("rules.nim", 35).startsWith("rule loader's then calls loadToml: ")

  test "the step prints one file:line line per finding and exits 1":
    let r = runPurity(fixtures / "impure")
    check r.code == 1
    let lines = r.output.strip.splitLines
    check lines.len == found.len
    check lines[0] == fixtures / "impure" / "rules.nim" & ":2: " & found[0].msg

suite "purity: the lists":
  test "every engine module is banned in a core file or named safe there":
    for kind, path in walkDir(repo / "src" / "paraloop"):
      let name = path.extractFilename
      if kind == pcFile and not name.endsWith(".nim"): continue
      if kind notin {pcFile, pcDir} or name == "assets": continue
      let module = "paraloop/" & name.changeFileExt("")
      checkpoint module
      check (bannedWhy(module).len > 0) != (name.changeFileExt("") in coreSafeEngineModules)

  test "std and pkg prefixes and bare names are the same module":
    check bannedWhy("std/os") == bannedWhy("os")
    check bannedWhy("std/os").len > 0
    check bannedWhy("pkg/paranim/gl").len > 0
    check bannedWhy("paraloop/sim") == ""
    check bannedWhy("std/random") == ""
    check bannedWhy("ostrich") == "" # a prefix only matches a whole path segment

  test "stdin, libraries, object ids, the command line and cgi are banned":
    check bannedWhy("std/rdstdin") == "it reads the keyboard"
    check bannedWhy("std/dynlib") == "it loads libraries"
    check bannedWhy("std/oids") == "it reads the clock"
    check bannedWhy("std/parseopt") == "it reads the command line"
    check bannedWhy("std/cgi") == "it reads the environment"

  test "names compare the way Nim compares them":
    check nimIdent("next_id") == nimIdent("nextId")
    check nimIdent("getOrDefault") == nimIdent("get_or_default")
    check nimIdent("Echo") != nimIdent("echo")

suite "purity: reading the source":
  test "comments and string literals are blanked, lines and code kept":
    let src = "let a = \"echo(1)\" # quit(2)\n#[ readFile(\"x\")\n]# b('c', 1'i64)\nr\"x\"\"y\" \"\"\"\nz()\n\"\"\""
    let blanked = blankCode(src)
    check blanked.len == src.len
    check blanked.count('\n') == src.count('\n')
    for word in ["echo", "quit", "readFile", "z()"]:
      check word notin blanked
    check "let a = \"" in blanked
    check "b(' ', 1'i64)" in blanked

  test "declared routines and top-level values are found":
    let code = "proc a*(x: int) = discard\nfunc `+`(x, y: T): T = x\ntemplate t[T](x: T) = x\n" &
               "const\n  table*: array[2, int] = [1, 2]\n  other = 3\nlet single* = 4\n" &
               "proc f() =\n  let local = 1\n"
    check declaredRoutines(code) == ["a", "+", "t", "f"].toHashSet
    check declaredValues(code) == ["table", "other", "single"].toHashSet
