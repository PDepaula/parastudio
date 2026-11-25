# The purity step of `para check`: a game's core files (`rules.nim`, `data.nim`, `systems.nim`)
# stay pure, so a run replays from its seed and its inputs to the same state hash. Three things are
# refused, each with a plain `file:line:` message:
#
# - an import of a module that performs an effect (`bannedImports`): drawing, sound, the clock,
#   files, processes, the network, threads, the environment (AGENTS.md "Boundaries";
#   skills/pararules/SKILL.md "Effects never": the shell owns every effect);
# - anywhere in a core file, one of `system`'s effect routines, which need no import, so a game
#   proc a `then` calls cannot hide one: `systemEffects` (`echo`, `readFile`, `stdout`, ...) as
#   any use of the name, `systemEffectCalls` (`open`, `quit`) only when called, so a variable,
#   field or enum member with that name passes;
# - a call inside a rule's `then:` (or `thenFinally:`) body other than the session's insert, id
#   generation and RNG, and pure helpers (`sessionCalls`, `pureHelpers`, `pureEngineHelpers`, and
#   any routine or table of procs declared in the core files themselves, which the two rules above
#   keep away from effects; a routine in another of the game's modules, such as a `schema.nim`,
#   is not one of them). A `then` writes the session and nothing else (SKILL.md "What a `then`
#   can and cannot do"), so a retract or a `fireRules` there is refused too.
#
# Names compare the way Nim compares them: the first character exactly, the rest ignoring case
# and `_` (`next_id` is `nextId`).
#
# It reads the source as text, without compiling: comments and string literals are blanked first,
# then imports and `then` bodies are scanned. That keeps the step fast and needs no compiler, at the
# price of a text check's limits: a call is a name followed by `(` (or `[...](`), a method call
# `x.name(`, or a command `name arg` at the start of a line; a capitalised name is a type
# conversion or an object constructor and always passes; `x.name` with no parentheses reads as a
# field and passes; the `{...}` parts of a `fmt"..."` or `&"..."` string are blanked with the
# string, so a call written there is not seen.

import std/[algorithm, os, sets, strutils]

type
  Finding* = tuple[file: string, line: int, msg: string]

const
  coreFiles* = ["rules.nim", "data.nim", "systems.nim"]
    ## The game's core: its facts, its rules and content rows, and the named exceptions'
    ## procedures. Everything else in the game's folder is the shell (drawing, sound, input, files).

  bannedImports* = [
    # (module, why) -- a module matches itself and everything under it (`paranim` bans
    # `paranim/gl`). `std/` and `pkg/` prefixes are dropped before matching, so `std/os` and a bare
    # `os` are the same module. std/random is not here: the sim's RNG is a std/random `Rand`
    # (`session.rng.rand(99)`); its global procs are refused as calls instead (AGENTS.md bans them).
    ("paranim", "it draws (the GL window)"),
    ("paratext", "it draws text"),
    ("parasound", "it plays sound"),
    ("stb_image", "it reads and writes image files"),
    # the engine's shell modules: everything in src/paraloop/ except `coreSafeEngineModules`
    ("paraloop/app", "it runs the window and the frame loop"),
    ("paraloop/audio", "it plays sound"),
    ("paraloop/audio_device", "it plays sound"),
    ("paraloop/audio_web", "it plays sound"),
    ("paraloop/baseline", "it reads files"),
    ("paraloop/clock", "it reads the clock"),
    ("paraloop/dev", "it opens the dev control channel"),
    ("paraloop/devsock", "it opens a socket"),
    ("paraloop/render2d", "it draws"),
    ("paraloop/save", "it writes files"),
    ("paraloop/testkit", "it is for tests"),
    ("paraloop/tune", "it plays sound"),
    ("paraloop/web", "it runs the web page"),
    # the standard library's effects
    ("times", "it reads the clock"),
    ("monotimes", "it reads the clock"),
    ("os", "it reaches files, folders, the environment and the clock"),
    ("osproc", "it starts programs"),
    ("dirs", "it reaches folders"),
    ("files", "it reaches files"),
    ("symlinks", "it reaches files"),
    ("appdirs", "it reaches folders"),
    ("tempfiles", "it writes files"),
    ("memfiles", "it reads files"),
    ("streams", "it reads and writes files"),
    ("syncio", "it reads and writes files"),
    ("envvars", "it reads the environment"),
    ("cmdline", "it reads the command line"),
    ("terminal", "it writes to the terminal"),
    ("logging", "it writes logs"),
    ("browsers", "it opens a browser"),
    ("distros", "it starts programs"),
    ("sysrand", "its randomness is not from the seed"),
    ("net", "it opens the network"),
    ("nativesockets", "it opens the network"),
    ("asyncdispatch", "it runs async work"),
    ("asyncnet", "it opens the network"),
    ("asyncfile", "it reads and writes files"),
    ("asynchttpserver", "it opens the network"),
    ("httpclient", "it opens the network"),
    ("smtp", "it opens the network"),
    ("selectors", "it waits on files and sockets"),
    ("threadpool", "it starts threads"),
    ("typedthreads", "it starts threads"),
    ("locks", "it is for threads"),
    ("rlocks", "it is for threads"),
    ("cpuinfo", "it asks the machine"),
    ("posix", "it calls the operating system"),
    ("winlean", "it calls the operating system"),
    ("exitprocs", "it runs code when the program quits"),
    ("rdstdin", "it reads the keyboard"),
    ("dynlib", "it loads libraries"),
    ("oids", "it reads the clock"),
    ("parseopt", "it reads the command line"),
    ("cgi", "it reads the environment"),
  ]

  systemEffects* = [
    # (routine, why) -- `system`'s effects, refused anywhere in a core file: they need no import,
    # so the import rule cannot keep them out of a game proc that a `then` calls. Any use of one
    # of these names is refused; `systemEffectCalls` are refused only when called.
    ("echo", "it writes output"),
    ("debugEcho", "it writes output"),
    ("readFile", "it reads files"),
    ("writeFile", "it writes files"),
    ("readLines", "it reads files"),
    ("stdout", "it writes output"),
    ("stderr", "it writes output"),
    ("stdin", "it reads the keyboard"),
  ]

  systemEffectCalls* = [
    # (routine, why) -- `system`'s effects whose names a game also uses for its own things (an
    # `open` list in a path search, a door's `open` field, a menu's `quit` item): refused only as
    # a call, `open(...)`, `x.open(...)` or a command `quit 1` at the start of a statement.
    ("open", "it opens files"),
    ("quit", "it quits the program"),
  ]

  coreSafeEngineModules* = ["sim", "input", "tilemap", "toml"]
    ## The src/paraloop/ modules a core file may import (no effect, no window). Every other engine
    ## module is in `bannedImports`; tests/test_para_purity.nim fails when one is in neither list.

  sessionCalls* = ["insert", "nextId", "rng", "matchCount", "contains", "queryAll"]
    ## What a `then` may call on `session`: write a fact, allocate an id, draw from the seeded RNG
    ## (`session.rng.rand(99)`), and the pure reads SKILL.md names (a rule's match count, whether
    ## a fact exists, `session.queryAll(this)` in a `thenFinally`). Never `retract` (SKILL.md "Never
    ## retract inside `then`"), `add`, `fireRules` or anything else.

  rngProcs* = ["rand", "sample", "shuffle", "gauss"]
    ## std/random's procs: allowed on the sim's RNG (`session.rng.rand(9)`, `rand(session.rng, 9)`),
    ## refused bare (`rand(9)` draws from std/random's global RNG, which no seed controls).

  pureHelpers* = [
    # system: sizes, arithmetic, conversions, ordinals, seqs and sets
    "len", "high", "low", "min", "max", "abs", "inc", "dec", "succ", "pred", "ord", "chr", "card",
    "add", "del", "delete", "insert", "setLen", "newSeq", "newSeqOfCap", "contains", "find",
    "incl", "excl", "swap", "move", "default", "typeof", "isNil", "cmp", "clamp",
    "toFloat", "toInt", "toBiggestFloat", "toBiggestInt",
    "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
    "float", "float32", "float64", "bool", "char", "string", "byte",
    "items", "mitems", "pairs", "mpairs", "countup", "countdown",
    "assert", "doAssert", "newException",
    # compile-time questions, not calls (`when defined(debug): doAssert x`)
    "defined", "declared", "compiles", "sizeof",
    # std/math
    "floor", "ceil", "round", "trunc", "sqrt", "cbrt", "pow", "hypot", "exp", "ln", "log",
    "log2", "log10", "sin", "cos", "tan", "arcsin", "arccos", "arctan", "arctan2", "degToRad",
    "radToDeg", "sgn", "floorDiv", "floorMod", "euclDiv", "euclMod", "isNaN", "copySign", "sum",
    "prod", "splitDecimal", "classify",
    # std/options
    "some", "none", "isSome", "isNone", "get", "unsafeGet", "map", "filter", "flatMap",
    # std/sequtils and std/algorithm
    "toSeq", "mapIt", "filterIt", "anyIt", "allIt", "countIt", "keepItIf", "applyIt", "foldl",
    "concat", "zip", "unzip", "deduplicate", "any", "all", "count", "minIndex", "newSeqWith", "pop",
    "maxIndex", "distribute", "reversed", "reverse", "sorted", "sort", "sortedByIt", "isSorted",
    "binarySearch", "lowerBound", "upperBound", "fill", "rotateLeft", "rotatedLeft",
    # std/tables and std/sets
    "hasKey", "getOrDefault", "mgetOrPut", "hasKeyOrPut", "initTable", "toTable", "initHashSet",
    "toHashSet", "keys", "values", "mvalues", "newTable", "initOrderedTable", "toOrderedTable",
    "initCountTable", "toCountTable",
    # std/deques
    "initDeque", "addFirst", "addLast", "popFirst", "popLast", "peekFirst", "peekLast",
    # std/strutils and std/strformat, for a label a fact carries
    "fmt", "join", "split", "strip", "startsWith", "endsWith", "replace", "repeat", "align",
    "formatFloat", "toLowerAscii", "toUpperAscii", "intToStr", "parseInt", "parseFloat", "format",
  ]

  pureEngineHelpers* = [
    # paraloop/tilemap: grid queries, movement and paths over a map value
    "inBounds", "isSolid", "tileAt", "worldToTile", "tileToWorld", "worldWidth", "worldHeight",
    "parseGrid", "moveBox", "raycast", "reachable", "findPath", "nearestReachable",
    # paraloop/toml: parsing text already in hand and reading values; not `loadToml`, which reads
    # a file
    "parseToml", "getStr", "getInt", "getBool", "getFloat",
  ]

  routineKeywords = ["proc", "func", "template", "macro", "iterator", "method", "converter"]
  nimKeywords = [
    "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept", "const",
    "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else", "end",
    "enum", "except", "export", "finally", "for", "from", "func", "if", "import", "in",
    "include", "interface", "is", "isnot", "iterator", "let", "macro", "method", "mixin", "mod",
    "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "return",
    "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var", "when", "while",
    "xor", "yield", "true", "false", "result", "this", "session"]

proc isIdentStart(c: char): bool = c in {'a'..'z', 'A'..'Z', '_', '\x80'..'\xff'}
proc isIdentChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xff'}

proc nimIdent*(name: string): string =
  ## `name` the way Nim compares identifiers: the first character kept, the rest lowercased and
  ## without `_`.
  if name.len == 0: return ""
  result = $name[0]
  for c in name[1 .. ^1]:
    if c != '_': result.add c.toLowerAscii

proc identSet(names: openArray[string]): HashSet[string] =
  for n in names: result.incl nimIdent(n)

proc effectWhy(name: string): string =
  ## Why `name` is one of `systemEffects` or `systemEffectCalls`, or "".
  let key = nimIdent(name)
  for (effect, why) in systemEffects:
    if key == nimIdent(effect): return why
  for (effect, why) in systemEffectCalls:
    if key == nimIdent(effect): return why

proc calledOnly(name: string): bool =
  let key = nimIdent(name)
  for (effect, _) in systemEffectCalls:
    if key == nimIdent(effect): return true

const
  sessionCallSet = identSet(sessionCalls)
  rngProcSet = identSet(rngProcs)
  pureHelperSet = identSet(pureHelpers) + identSet(pureEngineHelpers)

proc blankCode*(src: string): string =
  ## `src` with every comment and the inside of every string and char literal turned into spaces,
  ## newlines kept, so a later scan sees only code and every line keeps its number.
  result = newString(src.len)
  var i = 0
  template keep() =
    result[i] = src[i]; inc i
  template blank() =
    result[i] = (if src[i] == '\n': '\n' else: ' '); inc i
  while i < src.len:
    let c = src[i]
    if c == '#' and i + 1 < src.len and src[i + 1] == '[' or
       c == '#' and i + 2 < src.len and src[i + 1] == '#' and src[i + 2] == '[':
      var depth = 0
      while i < src.len:
        if src[i] == '#' and i + 1 < src.len and src[i + 1] == '[':
          inc depth; blank(); blank()
        elif src[i] == ']' and i + 1 < src.len and src[i + 1] == '#':
          dec depth; blank(); blank()
          if depth == 0: break
        else: blank()
    elif c == '#':
      while i < src.len and src[i] != '\n': blank()
    elif c == '"' and i + 2 < src.len and src[i + 1] == '"' and src[i + 2] == '"':
      keep(); keep(); keep()
      while i < src.len and not (src[i] == '"' and i + 2 < src.len and src[i + 1] == '"' and src[i + 2] == '"'):
        blank()
      while i < src.len and src[i] == '"': keep()
    elif c == '"':
      let raw = i > 0 and isIdentChar(src[i - 1])
      keep()
      while i < src.len and src[i] != '\n':
        if src[i] == '"':
          if raw and i + 1 < src.len and src[i + 1] == '"': blank(); blank(); continue
          break
        if not raw and src[i] == '\\' and i + 1 < src.len: blank()
        blank()
      if i < src.len and src[i] == '"': keep()
    elif c == '\'' and not (i > 0 and isIdentChar(src[i - 1])):
      # a char literal ('a', '\n', '\x41'); a `'` after a digit or a name is a literal's type suffix
      var j = i + 1
      if j < src.len and src[j] == '\\':
        j += 2
        while j < src.len and src[j] notin {'\'', '\n'}: inc j
      elif j < src.len: inc j
      if j < src.len and src[j] == '\'':
        keep()
        while i < j: blank()
        keep()
      else: keep()
    else: keep()

proc indentOf(line: string): int =
  while result < line.len and line[result] == ' ': inc result

proc moduleKey(m: string): string =
  ## How `bannedImports` spells a module: no quotes, no `std/`/`pkg/`/`./` prefix.
  result = m.strip.strip(chars = {'"'})
  for prefix in ["std/", "pkg/", "./"]:
    if result.startsWith(prefix): result = result[prefix.len .. ^1]

proc bannedWhy*(module: string): string =
  ## Why an import of `module` is refused, or "" when it is allowed.
  let key = moduleKey(module)
  for (banned, why) in bannedImports:
    if key == banned or key.startsWith(banned & "/"): return why

proc splitTop(s: string): seq[string] =
  ## `s` split on the commas outside brackets.
  var depth = 0
  var cur = ""
  for c in s:
    case c
    of '[': inc depth; cur.add c
    of ']': dec depth; cur.add c
    of ',':
      if depth == 0: result.add cur; cur = ""
      else: cur.add c
    else: cur.add c
  if cur.strip.len > 0: result.add cur

proc expandModules(clause: string): seq[string] =
  ## `a/b, c/[d, e] as f, g except h` -> a/b, c/d, c/e, g
  for part in splitTop(clause):
    var p = part.strip
    for cut in [" except ", " as "]:
      let at = p.find(cut)
      if at >= 0: p = p[0 ..< at].strip
    let open = p.find('[')
    if open >= 0 and p.endsWith("]"):
      let prefix = p[0 ..< open]
      for inner in p[open + 1 .. ^2].split(','):
        if inner.strip.len > 0: result.add prefix & inner.strip
    elif p.len > 0:
      result.add p

proc importFindings(file: string, lines: seq[string]): seq[Finding] =
  var i = 0
  while i < lines.len:
    let start = i
    let ind = indentOf(lines[i])
    var stmt = lines[i].strip
    if stmt.startsWith("when ") or stmt.startsWith("elif ") or stmt.startsWith("else:"):
      # `when defined(dev): import std/os` (or `elif ...:`, `else:`) on one line
      for kw in [": import", ": from ", ": include"]:
        let at = stmt.find(kw)
        if at > 0: stmt = stmt[at + 2 .. ^1]; break
    let isImport = stmt in ["import", "include"] or stmt.startsWith("import ") or
                   stmt.startsWith("include ") or stmt.startsWith("from ")
    var depth = stmt.count('[') - stmt.count(']')
    # the statement goes on while a bracket is open, after a trailing comma, and over every deeper
    # line (`import` alone on its line, `from std/os import` then the names below)
    while isImport and i + 1 < lines.len and
          (depth > 0 or stmt.endsWith(",") or
           lines[i + 1].strip.len > 0 and indentOf(lines[i + 1]) > ind):
      inc i
      stmt.add " " & lines[i].strip
      depth = stmt.count('[') - stmt.count(']')
    inc i
    var modules: seq[string]
    for kw in ["import ", "include "]:
      if stmt.startsWith(kw): modules = expandModules(stmt[kw.len .. ^1])
    if stmt.startsWith("from "):
      let at = stmt.find(" import ")
      if at > 0: modules = @[stmt["from ".len ..< at].strip]
    for m in modules:
      let why = bannedWhy(m)
      if why.len > 0:
        result.add (file, start + 1, "imports " & m & ", which a core file may not: " & why &
                    " (an effect belongs to the shell, the game's main file)")

proc declaredRoutines*(code: string): HashSet[string] =
  ## The names of every routine `code` declares (`proc name`, `func name*[T]`, ...).
  for line in code.splitLines:
    var s = line.strip
    for kw in routineKeywords:
      if s.startsWith(kw & " "):
        var j = kw.len
        while j < s.len and s[j] == ' ': inc j
        if j < s.len and s[j] == '`':
          let e = s.find('`', j + 1)
          if e > j: result.incl s[j + 1 ..< e]
        else:
          var name = ""
          while j < s.len and isIdentChar(s[j]): name.add s[j]; inc j
          if name.len > 0: result.incl name

proc isCallAt(b: string, j, e: int): bool =
  ## Whether the name at `b[j ..< e]` is called: `name(` that does not declare it, or a command
  ## `name arg` at the start of a statement (the line's start, or after a `:` or `;`).
  let before = b[0 ..< j].strip
  var w = before.len
  while w > 0 and isIdentChar(before[w - 1]): dec w
  if before[w .. ^1] in routineKeywords: return false
  if e < b.len and b[e] == '(': return true
  if before.len > 0 and before[^1] notin {':', ';'}: return false
  if e >= b.len or b[e] != ' ': return false
  var k = e
  while k < b.len and b[k] == ' ': inc k
  var nextWord = ""
  var m = k
  while m < b.len and isIdentChar(b[m]): nextWord.add b[m]; inc m
  k < b.len and (isIdentChar(b[k]) or b[k] in {'"', '\'', '(', '@'}) and nextWord notin nimKeywords

proc effectFindings(file: string, lines: seq[string]): seq[Finding] =
  ## Every use of one of `systemEffects` and every call of one of `systemEffectCalls`, anywhere
  ## in the file.
  for n, b in lines:
    var j = 0
    while j < b.len:
      if not isIdentStart(b[j]) or (j > 0 and isIdentChar(b[j - 1])):
        inc j; continue
      var e = j
      while e < b.len and isIdentChar(b[e]): inc e
      let name = b[j ..< e]
      let why = effectWhy(name)
      if why.len > 0 and (not calledOnly(name) or isCallAt(b, j, e)):
        result.add (file, n + 1, "uses " & name & ", which a core file may not: " & why &
                    " (an effect belongs to the shell, the game's main file)")
      j = e

proc skipSpaces(s: string, j: int): int =
  result = j
  while result < s.len and s[result] == ' ': inc result

proc matching(s: string, j: int, open, close: char): int =
  ## The index of the bracket closing the one at `j`, or -1.
  var depth = 0
  for k in j ..< s.len:
    if s[k] == open: inc depth
    elif s[k] == close:
      dec depth
      if depth == 0: return k
  -1

proc receiverOf(s: string, dot: int): string =
  ## The dotted name before `s[dot]` (`session.rng` for `session.rng.rand`), "" when it is not one.
  var k = dot
  while k > 0 and (isIdentChar(s[k - 1]) or s[k - 1] == '.'): dec k
  s[k ..< dot]

proc thenFindings(file: string, lines: seq[string], helpers: HashSet[string]): seq[Finding] =
  var rule = ""
  var i = 0
  while i < lines.len:
    let line = lines[i]
    let s = line.strip
    if s.startsWith("rule "):
      rule = ""
      var j = "rule ".len
      while j < s.len and isIdentChar(s[j]): rule.add s[j]; inc j
    var section = ""
    for kw in ["thenFinally", "then"]:
      if s.startsWith(kw) and s[kw.len .. ^1].strip.startsWith(":"):
        section = kw; break
    if section.len == 0:
      inc i; continue
    let base = indentOf(line)
    # the body: the rest of the `then:` line, then every deeper line
    var body: seq[(int, string)] = @[(i, line[line.find(':') + 1 .. ^1])]
    inc i
    while i < lines.len and (lines[i].strip.len == 0 or indentOf(lines[i]) > base):
      body.add (i, lines[i]); inc i
    var locals = helpers
    for (_, b) in body:
      for name in declaredRoutines(b): locals.incl nimIdent(name)
    let who = if rule.len > 0: "rule " & rule & "'s " & section else: "a " & section
    for (n, b) in body:
      var calls: seq[string]
      # a command call at the start of the line: `echo x`, `quit 1`
      let st = b.strip
      var w = 0
      while w < st.len and isIdentChar(st[w]): inc w
      if w > 0 and isIdentStart(st[0]) and w < st.len and st[w] == ' ':
        let next = skipSpaces(st, w)
        var nextWord = ""
        var k = next
        while k < st.len and isIdentChar(st[k]): nextWord.add st[k]; inc k
        let word = st[0 ..< w]
        if next < st.len and (isIdentChar(st[next]) or st[next] in {'"', '\'', '(', '@'}) and
           nextWord notin nimKeywords and word notin nimKeywords and
           word notin routineKeywords and nimIdent(word) notin pureHelperSet and
           nimIdent(word) notin locals and effectWhy(word).len == 0:
          calls.add word
      # `name(`, `name[T](`, `x.name(`, and every `session.name`
      var j = 0
      while j < b.len:
        if not isIdentStart(b[j]) or (j > 0 and isIdentChar(b[j - 1])):
          inc j; continue
        var e = j
        while e < b.len and isIdentChar(b[e]): inc e
        let name = b[j ..< e]
        let key = nimIdent(name)
        let recv = if j > 0 and b[j - 1] == '.': receiverOf(b, j - 1) else: ""
        var after = e
        if after < b.len and b[after] == '[':
          let close = matching(b, after, '[', ']')
          if close > 0 and close + 1 < b.len and b[close + 1] == '(': after = close + 1
        let isCall = after < b.len and b[after] == '('
        if recv == "session" or recv.startsWith("session."):
          # session.rng.rand(9) and a game helper called on the session (session.openHub()) pass
          if recv == "session" and key notin sessionCallSet and key notin locals:
            calls.add "session." & name
        elif isCall and name notin nimKeywords and name notin routineKeywords:
          if key in rngProcSet:
            if not b[skipSpaces(b, after + 1) .. ^1].startsWith("session.rng"):
              calls.add name # rand(9), xs.shuffle(): std/random's global RNG
          elif name[0] notin {'A'..'Z'} and key notin pureHelperSet and key notin locals and
               effectWhy(name).len == 0:
            # (an effect from `systemEffects` or `systemEffectCalls` is reported by
            # `effectFindings` instead)
            # (a capitalised name is a type conversion or an object constructor, so it passes)
            calls.add name
        j = e
      for c in calls:
        let what =
          if c == "session.retract": "session.retract (never retract inside a then; the systems step retracts)"
          elif nimIdent(c) in rngProcSet: c & " (std/random's global RNG; draw from session.rng instead)"
          else: c
        result.add (file, n + 1, who & " calls " & what & ": a then may call only session.insert, " &
                    "session.nextId, session.rng and pure helpers (the game's own procs and funcs, or " &
                    "the list in tools/para/purity.nim)")

proc declaredValues*(code: string): HashSet[string] =
  ## The names a top-level `const`, `let` or `var` section declares: content tables, some of
  ## them tables of procs a `then` calls (`pickupEffects[kind](now, session.rng)`).
  var inSection = false
  var childIndent = -1
  for line in code.splitLines:
    let s = line.strip
    if s.len == 0: continue
    let ind = indentOf(line)
    if ind == 0:
      inSection = false
      for kw in ["const", "let", "var"]:
        if s == kw or s.startsWith(kw & " "):
          inSection = true
          childIndent = -1
          let rest = s[kw.len .. ^1].strip
          var name = ""
          var j = 0
          while j < rest.len and isIdentChar(rest[j]): name.add rest[j]; inc j
          if name.len > 0: result.incl name
    elif inSection:
      if childIndent < 0: childIndent = ind
      if ind == childIndent and isIdentStart(s[0]):
        var name = ""
        var j = 0
        while j < s.len and isIdentChar(s[j]): name.add s[j]; inc j
        result.incl name

proc purityFindings*(gameDir: string): seq[Finding] =
  ## Every purity finding in the core files of the game in `gameDir`, in file and line order.
  var codes: seq[(string, seq[string])]
  var helpers: HashSet[string]
  for name in coreFiles:
    let path = gameDir / name
    if not fileExists(path): continue
    let code = blankCode(readFile(path))
    for name in declaredRoutines(code) + declaredValues(code): helpers.incl nimIdent(name)
    codes.add (path, code.splitLines)
  for (path, lines) in codes:
    var found = importFindings(path, lines) & effectFindings(path, lines) &
                thenFindings(path, lines, helpers)
    found.sort(proc (a, b: Finding): int = cmp(a.line, b.line))
    result.add found

proc runPurity*(gameDir: string): tuple[output: string, code: int] =
  ## The step: one `file:line: message` line per finding and exit 1, or a one-line pass and exit 0.
  let found = purityFindings(gameDir)
  if found.len == 0:
    return ("purity: the core files import nothing banned and every then only writes the session\n", 0)
  for f in found:
    result.output.add f.file & ":" & $f.line & ": " & f.msg & "\n"
  result.code = 1
