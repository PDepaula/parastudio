# `para art`: the asset-pipeline track's CLI dispatch (asset pipeline report
# §9, rows A1-A2: `lint`, `sheet`, `fix`; A3-A7 are later tasks). `fix` is the
# only one with any Python behind it (tools/art/); this file itself stays
# plain Nim. Written as a plain `runArt(args): (output, code)` - no direct
# stdout/exit calls - so the unified `para` CLI (engine report task 1.8) can
# import this module and wire it in without touching anything under art/,
# and so tests can call it without a subprocess. tools/para/para.nim, the
# whole of what 1.8 needs to replace, just prints `output` and quits `code`.

import std/[options, os, sequtils, strformat, strutils, tables]
import art/[clihelpers, fix, lint, profile, sheet, sidecar, toon]

type
  Run = clihelpers.Run

proc gridCell(r: AssetReport): string =
  case r.grid
  of gsOk: "ok"
  of gsBad: "BAD"
  of gsUnknown: "?"

proc outlineCell(r: AssetReport): string =
  if not r.cellsMeasured: "unmeasured"
  elif r.outlineOffenders == 0: "ok"
  else: &"{r.outlineOffenders} px"

proc paletteCell(r: AssetReport): string =
  if not r.paletteChecked: "-"
  elif r.offPalette.len == 0: "ok"
  else: &"{r.offPalette.len} off"

const sheetCols = ["file", "size", "cell", "grid", "colors", "semi_alpha_px",
  "empty_cells", "edge_touch_cells", "outline", "palette"]

proc reportsToRows(reports: seq[AssetReport]): seq[seq[string]] =
  for r in reports:
    result.add @[
      r.file,
      &"{r.width}x{r.height}",
      (if r.grid == gsUnknown: "?" else: &"{r.cellW}x{r.cellH}"),
      gridCell(r),
      $r.colorCount,
      $r.semiAlphaPx,
      (if r.tile: "-" elif r.cellsMeasured: $r.emptyCells else: "unmeasured"),
      (if r.tile: "-" elif r.cellsMeasured: $r.edgeTouchCells else: "unmeasured"),
      (if r.tile: "-" else: outlineCell(r)),
      paletteCell(r),
    ]

proc runLint(args: seq[string]): Run =
  var paths: seq[string]
  var styleArg = ""
  var failingOnly = false
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--style":
      inc i
      if i >= args.len: return errorOut("--style needs a path", @[])
      styleArg = args[i]
    of "--failing":
      failingOnly = true
    else:
      if a.startsWith("--"):
        return errorOut(&"unknown flag \"{a}\"",
          @["Valid flags: --style PATH, --failing"])
      paths.add a
    inc i
  if paths.len == 0:
    if dirExists("art"):
      paths.add "art"
    else:
      return errorOut("no paths given and no ./art directory found",
        @["Run `para art lint <dir-or-file>...`"])

  var styles = initTable[string, Style]()
  if styleArg.len > 0:
    try:
      styles[styleArg] = loadStyle(styleArg)
    except ProfileError as e:
      return errorOut(e.msg, @[])

  var pngs: seq[string]
  try:
    pngs = gatherPngs(paths)
  except IOError as e:
    return errorOut(e.msg, @[])

  if pngs.len == 0:
    result.output.add toonTable("sheets", sheetCols, @[])
    result.output.add "lint: 0 assets found\n"
    result.output.add toonHelp(@["Point `para art lint` at a directory of PNGs with <name>.art.toml sidecars"])
    result.code = 1
    return

  var reports: seq[AssetReport]
  var infoLines: seq[string]
  for p in pngs:
    try:
      let stylePath = if styleArg.len > 0: styleArg else: findStyleToml(p)
      var style = none(Style)
      if stylePath.len > 0:
        if stylePath notin styles: styles[stylePath] = loadStyle(stylePath)
        style = some(styles[stylePath])
      let r = lintFile(p, style)
      reports.add r
      var lines = @[&"style: {r.profileName} ({r.profileSource})\n"]
      if style.isSome and style.get.palette.len > 0:
        lines.add &"palette: {style.get.palettePath} ({style.get.palette.len} colours, every asset)\n"
      for line in lines:
        if line notin infoLines: infoLines.add line
    except LintError, SidecarError, ProfileError, IOError, OSError:
      return errorOut(getCurrentExceptionMsg(), @[])
  for line in infoLines:
    result.output.add line

  let shown = if failingOnly: reports.filterIt(it.verdict == "fail") else: reports
  result.output.add toonTable("sheets", sheetCols, reportsToRows(shown))

  for r in shown:
    if r.offPalette.len > 0:
      let hexes = r.offPalette.mapIt(it.toHex(6).toLowerAscii).join(",")
      result.output.add &"off_palette: {r.file} {hexes}\n"
    if r.tile:
      result.output.add &"tile: {r.file} seam_x {r.seamX:.1f} seam_y {r.seamY:.1f} (limit {int(seamMax)})\n"
    if r.keyLeakPx > 0:
      result.output.add &"key_leak: {r.file} {r.keyLeakPx} px\n"
    for w in r.waived:
      result.output.add &"waived: {r.file} {w.rule} - {w.reason}\n"

  let failing = reports.filterIt(it.verdict == "fail")

  result.output.add &"lint: {failing.len} of {reports.len} failed\n"

  if failing.len > 0:
    var help: seq[string]
    for r in failing:
      help.add &"""{r.file}: {r.failReasons.join(", ")}"""
    result.output.add toonHelp(help)
    result.code = 1
  else:
    result.code = 0

proc runSheet(args: seq[string]): Run =
  var paths: seq[string]
  var outPath = "tmp/art/sheet.png"
  var cols = 4
  var maxTile = 128
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--out":
      inc i
      if i >= args.len: return errorOut("--out needs a path", @[])
      outPath = args[i]
    of "--cols", "--max-tile":
      inc i
      if i >= args.len: return errorOut(&"{a} needs a number", @[])
      var n: int
      try:
        n = parseInt(args[i])
      except ValueError:
        return errorOut(&"{a} needs a whole number, got \"{args[i]}\"", @[])
      if a == "--cols": cols = n else: maxTile = n
    else:
      if a.startsWith("--"):
        return errorOut(&"unknown flag \"{a}\"",
          @["Valid flags: --out PATH, --cols N, --max-tile N"])
      paths.add a
    inc i
  if paths.len == 0:
    if dirExists("art"):
      paths.add "art"
    else:
      return errorOut("no paths given and no ./art directory found",
        @["Run `para art sheet <dir-or-file>...`"])

  var pngs: seq[string]
  try:
    pngs = gatherPngs(paths)
  except IOError as e:
    return errorOut(e.msg, @[])

  if pngs.len == 0:
    result.output.add toonTable("tiles", ["file", "x", "y", "w", "h"], @[])
    result.output.add "sheet: 0 assets found\n"
    result.output.add toonHelp(@["Point `para art sheet` at a directory of PNGs"])
    result.code = 1
    return

  var res: SheetResult
  try:
    res = buildContactSheet(pngs, outPath, maxTile, cols)
  except SheetError, IOError, OSError:
    return errorOut(getCurrentExceptionMsg(), @[])

  var rows: seq[seq[string]]
  for t in res.tiles:
    rows.add @[t.file, $t.x, $t.y, $t.w, $t.h]
  result.output.add toonTable("tiles", ["file", "x", "y", "w", "h"], rows)
  result.output.add &"sheet: {res.tiles.len} assets, {res.canvasW}x{res.canvasH}, wrote {res.outPath}\n"
  result.output.add toonHelp(@[&"Read {res.outPath}"])
  result.code = 0

proc runArt*(args: seq[string]): Run =
  if args.len == 0:
    result.output.add "para art: lint, fix and lay out pixel-art sheets (no generation, no network)\n"
    result.output.add toonHelp(@[
      "Run `para art lint <dir>` to check sheets against a style profile",
      "Run `para art fix <dir>` to key, grid-recover, palette-lock and re-cell sheets",
      "Run `para art sheet <dir>` to build a contact sheet PNG",
    ])
    result.code = 0
    return
  case args[0]
  of "lint": result = runLint(args[1 .. ^1])
  of "fix": result = runFix(args[1 .. ^1])
  of "sheet": result = runSheet(args[1 .. ^1])
  of "--help", "-h":
    result.output = "para art <lint|fix|sheet> [args]\n" &
      "  lint [paths...] [--style PATH] [--failing]\n" &
      "  fix [paths...] [--style PATH] [--out DIR] [--cell WxH] [--pivot bottom|none] [--profile lowbit|hibit] [--key RRGGBB] [--key-border-only] [--outline] [--tile] [--fit whole|content] [--margin PCT] [--figure-height PX]\n" &
      "    --fit content trims to the opaque bbox and scales to the --cell less --margin PCT (default 5), one scale shared by every file in the call; --figure-height PX pins the tallest figure\n" &
      "    a rerun on fix's own output changes 0 pixels without --key; an explicit --key keys that colour again, even on a rerun\n" &
      "  sheet [paths...] [--out PATH] [--cols N] [--max-tile N]\n"
    result.code = 0
  else:
    result = errorOut(&"unknown command \"art {args[0]}\"", @["Valid commands: lint, fix, sheet"])
