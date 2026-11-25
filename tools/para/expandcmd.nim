# `para expand`: the Nim that a module's Eversince blocks (`record`, `event`, `command`, `view`,
# `query`, `processor`, `sealModel`) turn into, written next to the model file, so the code the
# compiler builds is something a person or an agent can open and read. The default is the studio's
# desk, tools/para/studiodesk.nim (its model file is studiodesk.em, beside it), written to
# tools/para/studiodesk.expanded.nim. The expansion is the compiler's own: `nim check
# --expandMacro:<name>` for each block macro prints every call's expansion as a hint, and this file
# keeps the ones of the module asked for, in source order. The written file is not kept in git (it
# changes with the compiler version, and a model change would make it a big diff again).
#
# It also prints the size: the module's own lines (written), the lines the blocks expand to
# (generated) and their ratio. `--max-ratio N` makes a ratio over N a finding (exit 1), which is
# the size budget .github/scripts/model-budget.sh holds in CI (it times the same run for the
# compile-time budget; no test here looks at a clock).
#
# Parsing, counting and the budget are plain functions of the compiler's text, so
# tests/test_para_expand.nim pins them without running the compiler; one test runs it for real.

import std/[os, strformat, strutils, sequtils]
import art/[clihelpers, toon]
import nimutil

type Run = clihelpers.Run

const
  defaultSource* = "tools/para/studiodesk.nim"
  blockMacros* = ["record", "event", "command", "view", "query", "processor", "sealModel"]
  hintMark = " Hint: expanded macro:"
  hintTail = " [ExpandMacro]"

const expandHelp* = "para expand [FILE.nim] [--out PATH] [--max-ratio N]\n" &
  "  writes the Nim that FILE's Eversince blocks (" & blockMacros.join(", ") & ") expand to\n" &
  "  next to it, as FILE.expanded.nim (default FILE: " & defaultSource & ", the studio's desk, whose model\n" &
  "  file is studiodesk.em), and prints its size: the lines FILE has (written), the lines its blocks expand\n" &
  "  to (generated) and generated/written (ratio). The expansion is the compiler's own (`nim check\n" &
  "  --expandMacro`), in source order, each block headed by its line in FILE; the same compiler and FILE\n" &
  "  always write the same bytes. The written file is for reading, never for editing or importing; git\n" &
  "  ignores it.\n" &
  "  --out PATH     write the expansion there instead\n" &
  "  --max-ratio N  a ratio over N is a finding (exit 1); CI's size budget\n" &
  "                 (.github/scripts/model-budget.sh)\n"

type
  Expansion* = object
    line*: int      ## the line of FILE the block starts on (1-based)
    code*: string   ## what the compiler printed for it, no final newline

  ExpandSize* = object
    written*: int   ## lines of the module as written
    generated*: int ## lines its blocks expand to

proc lineCount*(text: string): int =
  ## Lines of `text`: a final line without its newline still counts; "" has none.
  if text.len == 0: 0
  else: text.count('\n') + (if text.endsWith('\n'): 0 else: 1)

proc ratio*(s: ExpandSize): float =
  if s.written == 0: 0.0 else: s.generated / s.written

proc ratioText*(r: float): string = formatFloat(r, ffDecimal, 2)

proc overBudget*(s: ExpandSize, maxRatio: float): bool =
  ## True when the ratio, as printed (two decimals), is over `maxRatio`: what the line says is what is judged.
  parseFloat(ratioText(s.ratio)) > maxRatio

proc expandedPath*(source: string): string =
  ## Where the expansion goes by default: beside FILE, as FILE.expanded.nim.
  source.changeFileExt("expanded.nim")

proc sameFile(a, b: string): bool =
  cmpPaths(a.absolutePath.normalizedPath, b.absolutePath.normalizedPath) == 0

proc parseExpansions*(output, source: string): seq[Expansion] =
  ## The expansions `nim check --expandMacro:... --listFullPaths:on` printed for the calls in
  ## `source`, in the order printed. A hint is `<file>(<line>, <col>) Hint: expanded macro: <code>`,
  ## the code running over the following lines until one ends in ` [ExpandMacro]`. Hints for
  ## other modules (an imported module's own blocks) and every other line are skipped.
  let lines = output.splitLines
  var i = 0
  while i < lines.len:
    let l = lines[i]
    let at = l.find(hintMark)
    inc i
    if at < 0: continue
    let head = l[0 ..< at]               # <file>(<line>, <col>)
    let open = head.rfind('(')
    if open <= 0 or not head.endsWith(")"): continue
    let pos = head[open + 1 .. ^2].split(',')
    if pos.len != 2: continue
    var lineNo: int
    try: lineNo = parseInt(pos[0].strip)
    except ValueError: continue
    var first = l[at + hintMark.len .. ^1]
    if first.startsWith(" "): first = first[1 .. ^1]
    var body = @[first]
    while not body[^1].endsWith(hintTail) and i < lines.len:
      body.add lines[i]
      inc i
    if body[^1].endsWith(hintTail):
      body[^1].setLen(body[^1].len - hintTail.len)
    if body.len > 1 and body[0].strip.len == 0: body.delete(0)
    if not sameFile(head[0 ..< open], source): continue
    result.add Expansion(line: lineNo, code: body.join("\n"))

proc measure*(sourceText: string, exps: seq[Expansion]): ExpandSize =
  ExpandSize(written: lineCount(sourceText), generated: exps.mapIt(lineCount(it.code)).foldl(a + b, 0))

proc expandedText*(sourceName, sourceText: string, exps: seq[Expansion]): string =
  ## The file `para expand` writes: a header with the size, then each expansion headed by the
  ## line of the source it came from. A pure function of its inputs.
  let s = measure(sourceText, exps)
  let src = sourceText.splitLines
  result = &"# Generated by `para expand` from {sourceName}: the Nim its Eversince blocks\n" &
    &"# ({blockMacros.join(\", \")}) expand to, as `nim check --expandMacro` prints it.\n" &
    "# For reading only: never edit or import it. `para expand` rewrites it and git ignores it.\n" &
    &"# written {s.written} lines, generated {s.generated} lines, ratio {ratioText(s.ratio)}\n"
  for e in exps:
    let label = if e.line in 1 .. src.len: src[e.line - 1].strip else: ""
    result.add &"\n# {sourceName}:{e.line}  {label}\n{e.code}\n"

proc runExpand*(args: seq[string]): Run =
  var source = ""
  var outPath = ""
  var maxRatio = -1.0
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (expandHelp, 0)
    of "--out":
      inc i
      if i >= args.len: return errorOut("--out needs a path", @[])
      outPath = args[i]
    of "--max-ratio":
      inc i
      if i >= args.len: return errorOut("--max-ratio needs a number", @["For example --max-ratio 1.5"])
      try: maxRatio = parseFloat(args[i])
      except ValueError: maxRatio = -1.0
      if maxRatio <= 0.0:
        return errorOut(&"bad --max-ratio \"{args[i]}\"", @["It is a number over 0, for example 1.5"])
    else:
      if a.startsWith("-"):
        return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --out PATH, --max-ratio N, --help"])
      if source.len > 0:
        return errorOut(&"one file at a time (got \"{source}\" and \"{a}\")", @[])
      source = a
    inc i
  if source.len == 0: source = defaultSource
  if not fileExists(source):
    return errorOut(&"no such file \"{source}\"", @["Give a .nim file that uses Eversince blocks, or none for " & defaultSource])
  if outPath.len == 0: outPath = expandedPath(source)
  if sameFile(outPath, source):
    return errorOut("--out would overwrite the file being expanded", @[])

  var nimArgs = @["check", "--colors:off", "--listFullPaths:on", "--hint:ExpandMacro:on"]
  for m in blockMacros: nimArgs.add "--expandMacro:" & m
  nimArgs.add source
  let res = runCaptured("nim", nimArgs)
  if res.exitCode != 0:
    let diags = parseNimDiagnostics(res.output).filterIt(it.severity == "Error")
    result.output = &"error: {source} does not compile\n"
    if diags.len > 0:
      result.output.add toonTable("errors", ["at", "msg"], diags.mapIt(@[it.at, it.msg]))
    else:
      result.output.add lastLines(res.output, 20)
    result.code = 1
    return
  let sourceText = readFile(source)
  let exps = parseExpansions(res.output, source)
  if exps.len == 0:
    return (&"error: {source} has no Eversince block to expand\n" &
      toonHelp(@["The blocks are " & blockMacros.join(", ") & " (import eversince)"]), 1)
  let outDir = outPath.parentDir
  if outDir.len > 0: createDir(outDir)
  writeFile(outPath, expandedText(source.replace('\\', '/'), sourceText, exps))
  let s = measure(sourceText, exps)
  result.output = &"expand: wrote {outPath}\n" &
    toonTable("size", ["file", "blocks", "written", "generated", "ratio"],
      @[@[source, $exps.len, $s.written, $s.generated, ratioText(s.ratio)]])
  if maxRatio > 0.0:
    if s.overBudget(maxRatio):
      result.output.add &"error: ratio {ratioText(s.ratio)} is over the budget of {ratioText(maxRatio)}\n" &
        toonHelp(@["Read " & outPath & " to see which blocks grew",
                   "Raise the budget in .github/scripts/model-budget.sh only on purpose, in the same change"])
      result.code = 1
    else:
      result.output.add &"budget: ok, ratio {ratioText(s.ratio)} is within {ratioText(maxRatio)}\n"
