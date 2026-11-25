# `para expand`: the Nim that the studio's desk's Eversince blocks (`record`, `event`, `command`,
# `view`, `query`, `processor`, `sealModel`) turn into, written next to the model file, so the code
# the compiler builds is something a person or an agent can open and read. It always expands
# tools/para/studiodesk.nim (its model file is studiodesk.em, beside it) and writes
# tools/para/studiodesk.expanded.nim. The expansion is the compiler's own: `nim check
# --expandMacro:<name>` for each block macro prints every call's expansion as a hint, and this file
# keeps the desk's own ones, in source order. The written file is not kept in git (it
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

const expandHelp* = "para expand [--max-ratio N]\n" &
  "  writes the Nim that the studio's desk's Eversince blocks (" & blockMacros.join(", ") & ")\n" &
  "  expand to next to the model file: " & defaultSource & " (model file studiodesk.em) to\n" &
  "  " & defaultSource.changeFileExt("expanded.nim") & ", and prints its size: the lines the desk has\n" &
  "  (written), the lines its blocks expand to (generated) and generated/written (ratio). The expansion is\n" &
  "  the compiler's own (`nim check --expandMacro`), in source order, each block headed by its line in the\n" &
  "  desk; the same compiler and desk always write the same bytes. The written file is for reading, never\n" &
  "  for editing or importing; git ignores it. Run it from the repository root.\n" &
  "  --max-ratio N  a ratio over N is a finding (exit 1); CI's size budget\n" &
  "                 (.github/scripts/model-budget.sh)\n"

type
  Expansion* = object
    line*: int      ## the line of the source the block starts on (1-based)
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
  ## Where the expansion goes: beside the module, as <module>.expanded.nim.
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

proc expandReport*(source, sourceText, output: string, maxRatio: float): tuple[run: Run, text: string] =
  ## What a successful compile of `source` comes to: the file to write beside it (`text`, empty when
  ## there is nothing to write) and what `para expand` prints and exits with. `maxRatio` <= 0 judges
  ## no budget. A pure function of the compiler's output.
  let exps = parseExpansions(output, source)
  if exps.len == 0:
    result.run = (&"error: no expansions were read from the compiler's output for {source}\n" &
      toonHelp(@["The output format of `nim check --expandMacro` may have changed; " &
                 "parseExpansions in tools/para/expandcmd.nim reads it"]), 1)
    return
  let outPath = expandedPath(source)
  result.text = expandedText(source, sourceText, exps)
  let s = measure(sourceText, exps)
  result.run.output = &"expand: wrote {outPath}\n" &
    toonTable("size", ["file", "blocks", "written", "generated", "ratio"],
      @[@[source, $exps.len, $s.written, $s.generated, ratioText(s.ratio)]])
  if maxRatio > 0.0:
    if s.overBudget(maxRatio):
      result.run.output.add &"error: ratio {ratioText(s.ratio)} is over the budget of {ratioText(maxRatio)}\n" &
        toonHelp(@["Read " & outPath & " to see which blocks grew",
                   "Raise the budget in .github/scripts/model-budget.sh only on purpose, in the same change"])
      result.run.code = 1
    else:
      result.run.output.add &"budget: ok, ratio {ratioText(s.ratio)} is within {ratioText(maxRatio)}\n"

proc runExpand*(args: seq[string]): Run =
  let source = defaultSource
  var maxRatio = -1.0
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (expandHelp, 0)
    of "--max-ratio":
      inc i
      if i >= args.len: return errorOut("--max-ratio needs a number", @["For example --max-ratio 1.5"])
      try: maxRatio = parseFloat(args[i])
      except ValueError: maxRatio = -1.0
      if not (maxRatio > 0.0 and maxRatio < Inf):
        return errorOut(&"bad --max-ratio \"{args[i]}\"", @["It is a finite number over 0, for example 1.5"])
    else:
      return errorOut(&"unknown argument \"{a}\"", @["Valid flags: --max-ratio N, --help"])
    inc i

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
  let (run, text) = expandReport(source, readFile(source), res.output, maxRatio)
  if text.len > 0: writeFile(expandedPath(source), text)
  run
