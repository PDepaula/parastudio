# `para art fix` (asset pipeline report §6.1, §8.2, §9 row A2): background
# key to hard alpha, pixel-grid recovery, palette lock, orphan-pixel
# cleanup, fixed cell and pivot, content slicing. All pixel math is Python
# (numpy/opencv/scipy/pixelfixer/unfake, tools/art/), run through `uv run
# --locked --project tools/art python -m para_art_fix` with one JSON request for
# every asset in the run and one JSON result back (report §8.2: "the agent
# sees only `para`").
#
# Unlike `para art lint`/`sheet`, `fix` takes no parameters from a
# `<name>.art.toml` sidecar (it only reads an existing one to carry over its
# waivers and key, see `writeSidecars`): a sidecar's cell_w/cell_h names the repeating *tile* size across
# an already-assembled, already-packed sheet (lint checks `width mod
# cellW == 0` against it), while `fix`'s job (report §6.1) runs earlier,
# on one raw or degraded sprite at a time, before it has a sidecar at all
# (that's A3's `para art pack`, report §9). Its cell size is `--cell WxH`,
# or left for Python's grid detection to find (art/style.toml's palette and
# default profile are still discovered the same way lint does, via
# clihelpers.findStyleToml - a palette is a whole-game file, not per-asset).
# What it does do is write one beside each output it produces (a fixed
# sprite is exactly one cell, so cell_w/cell_h are the cell it was placed in),
# so `fix` then `lint` needs no hand-written sidecar; see `writeSidecars`.
#
# No generation, no network calls at run time, no GPU: every dependency
# Python imports here was already installed by `uv sync --locked` (or `uv
# run --locked`'s own first-time sync, which fails instead of re-resolving
# when pyproject.toml has drifted from uv.lock) before this ever runs.

import std/[json, options, os, osproc, streams, strformat, strutils, tables]
import clihelpers, profile, sidecar, toon

const artProjectDir = currentSourcePath.parentDir.parentDir.parentDir / "art"
  ## tools/para/art/fix.nim -> tools/art, baked in at compile time like
  ## tests/fixtures/art/gen_painted.nim's own currentSourcePath use - valid
  ## because this project's nimcache policy (AGENTS.md) always builds and
  ## runs from the same worktree.

type
  FixToolError* = object of CatchableError

  AssetSpec = object
    path, outName, pivot, profileName, palettePath, keyHex: string
    keyBorderOnly, outline, tile: bool
    maxColors: int
    cellW, cellH: int ## 0,0 = unknown; grid.py auto-detects

proc toJson(a: AssetSpec): JsonNode =
  result = %*{
    "file": a.path,
    "out_name": a.outName,
    "pivot": a.pivot,
    "profile": a.profileName,
    "cell": if a.cellW > 0 and a.cellH > 0: %[a.cellW, a.cellH] else: newJNull(),
    "palette": if a.palettePath.len > 0: %a.palettePath else: newJNull(),
    "key": if a.keyHex.len > 0: %a.keyHex else: newJNull(),
    "key_border_only": a.keyBorderOnly,
    "outline": a.outline,
    "tile": a.tile,
    "max_colors": if a.maxColors > 0: %a.maxColors else: newJNull(),
  }

proc runPyFix(request: JsonNode): JsonNode =
  ## Raises FixToolError for anything that means the tool itself couldn't
  ## run (uv missing, a non-JSON reply); a per-asset processing failure
  ## comes back as a normal "error" field inside one of "results" instead.
  var p: Process
  try:
    p = startProcess("uv",
      args = @["run", "--locked", "--project", artProjectDir, "python", "-m", "para_art_fix"],
      options = {poUsePath})
  except OSError as e:
    raise newException(FixToolError, "couldn't run uv: " & e.msg & " (is uv installed and on PATH?)")
  let inp = p.inputStream
  inp.write($request)
  inp.close()
  let stdoutText = p.outputStream.readAll()
  discard p.waitForExit()
  let stderrText = p.errorStream.readAll()
  p.close()
  try:
    result = parseJson(stdoutText)
  except JsonParsingError:
    let detail = if stderrText.strip().len > 0: stderrText.strip() else: stdoutText.strip()
    raise newException(FixToolError, "para_art_fix gave no JSON back: " & detail)
  if result.kind == JObject and result.hasKey("error"):
    raise newException(FixToolError, result["error"].getStr())

const fixCols = ["file", "out", "changed", "size", "cell", "colors", "semi_alpha_px", "orphan", "grid", "key"]

proc jstr(n: JsonNode, key: string): string =
  if n.hasKey(key) and n[key].kind == JString: n[key].getStr() else: ""

proc jint(n: JsonNode, key: string): int =
  if n.hasKey(key) and n[key].kind == JInt: n[key].getInt() else: 0

proc parseCellFlag(s: string): tuple[w, h: int, ok: bool] =
  let parts = s.split('x')
  if parts.len != 2: return (0, 0, false)
  try:
    let w = parseInt(parts[0])
    let h = parseInt(parts[1])
    if w < 1 or h < 1: return (0, 0, false)
    return (w, h, true)
  except ValueError:
    return (0, 0, false)

proc writeSidecars(results: JsonNode, assets: seq[AssetSpec]): tuple[written, unchanged: int, hints: seq[string]] =
  ## One `<out>.art.toml` per fixed output: the cell it was placed in, the
  ## profile and pivot it was fixed for, and the key it was keyed from (so
  ## lint's `key` rule can check for leaks; omitted with --key-border-only,
  ## where the key colour is deliberate). Waivers, and the key when this run
  ## skipped keying (fix rerun on its own output), in a sidecar already there
  ## are kept, and a file that already says the same is left alone.
  var specs = initTable[string, AssetSpec]()
  for a in assets: specs[a.path] = a
  for r in results:
    if r.hasKey("error") or not r.hasKey("out") or jstr(r, "file") notin specs: continue
    let spec = specs[jstr(r, "file")]
    let png = jstr(r, "out")
    var sc = Sidecar(cellW: jint(r, "cell_w"), cellH: jint(r, "cell_h"),
      profile: spec.profileName, pivot: spec.pivot, kind: if spec.tile: "tile" else: "")
    let keyStatus = jstr(r, "key")
    if not spec.keyBorderOnly and keyStatus.len == 6 and keyStatus.allCharsInSet(HexDigits):
      sc.key = keyStatus.toLowerAscii
    try:
      let old = loadSidecar(png)
      if old.isSome:
        sc.waivers = old.get.waivers
        if sc.key.len == 0 and not spec.keyBorderOnly and keyStatus.startsWith("skip:"):
          sc.key = old.get.key
        if old.get == sc:
          inc result.unchanged
          continue
    except SidecarError as e:
      result.hints.add &"{e.msg}; left as is, fix it or delete it and rerun fix"
      continue
    if writeSidecar(png, sc): inc result.written else: inc result.unchanged

proc runFix*(args: seq[string]): Run =
  var paths: seq[string]
  var styleArg = ""
  var outDir = "tmp/art/fix"
  var cellW, cellH = 0
  var pivot = "bottom"
  var profileArg = ""
  var keyArg = ""
  var keyBorderOnly = false
  var outlineFlag = false
  var tileFlag = false
  var pivotGiven = false
  var fitMode = "whole"
  var marginPct = 5.0
  var figureHeight = 0
  var marginGiven = false
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--style":
      inc i
      if i >= args.len: return errorOut("--style needs a path", @[])
      styleArg = args[i]
    of "--out":
      inc i
      if i >= args.len: return errorOut("--out needs a path", @[])
      outDir = args[i]
    of "--cell":
      inc i
      if i >= args.len: return errorOut("--cell needs WxH", @[])
      let (w, h, ok) = parseCellFlag(args[i])
      if not ok: return errorOut(&"--cell needs a positive WxH, got \"{args[i]}\"", @[])
      cellW = w
      cellH = h
    of "--pivot":
      inc i
      if i >= args.len: return errorOut("--pivot needs bottom or none", @[])
      if args[i] notin ["bottom", "none"]:
        return errorOut(&"--pivot must be bottom or none, got \"{args[i]}\"", @[])
      pivot = args[i]
      pivotGiven = true
    of "--profile":
      inc i
      if i >= args.len: return errorOut("--profile needs lowbit or hibit", @[])
      if builtinProfile(args[i]).isNone:
        return errorOut(&"--profile must be lowbit or hibit, got \"{args[i]}\"", @[])
      profileArg = canonicalProfileName(args[i])
    of "--key":
      inc i
      if i >= args.len: return errorOut("--key needs an RRGGBB hex colour", @[])
      let hx = args[i]
      if hx.len != 6 or not hx.allCharsInSet(HexDigits):
        return errorOut(&"--key needs an RRGGBB hex colour, got \"{args[i]}\"", @[])
      keyArg = hx
    of "--key-border-only":
      keyBorderOnly = true
    of "--outline":
      outlineFlag = true
    of "--tile":
      tileFlag = true
    of "--fit":
      inc i
      if i >= args.len: return errorOut("--fit needs whole or content", @[])
      if args[i] notin ["whole", "content"]:
        return errorOut(&"--fit must be whole or content, got \"{args[i]}\"", @[])
      fitMode = args[i]
    of "--margin":
      inc i
      if i >= args.len: return errorOut("--margin needs a percentage from 0 to 40", @[])
      try:
        marginPct = parseFloat(args[i])
      except ValueError:
        marginPct = -1
      if not (marginPct >= 0 and marginPct <= 40):
        return errorOut(&"--margin needs a percentage from 0 to 40, got \"{args[i]}\"", @[])
      marginGiven = true
    of "--figure-height":
      inc i
      if i >= args.len: return errorOut("--figure-height needs a pixel count", @[])
      try:
        figureHeight = parseInt(args[i])
      except ValueError:
        figureHeight = 0
      if figureHeight < 1:
        return errorOut(&"--figure-height needs a positive pixel count, got \"{args[i]}\"", @[])
    else:
      if a.startsWith("--"):
        return errorOut(&"unknown flag \"{a}\"",
          @["Valid flags: --style PATH, --out DIR, --cell WxH, --pivot bottom|none, --profile lowbit|hibit, --key RRGGBB, --key-border-only, --outline, --tile, --fit whole|content, --margin PCT, --figure-height PX"])
      paths.add a
    inc i
  if tileFlag:
    if cellW == 0 or cellH == 0:
      return errorOut("--tile needs --cell WxH", @["Run `para art fix <files> --tile --cell 96x96`"])
    for (given, flag) in [(keyArg.len > 0, "--key"), (keyBorderOnly, "--key-border-only"),
                          (outlineFlag, "--outline"), (pivotGiven, "--pivot"),
                          (fitMode == "content", "--fit content"), (marginGiven, "--margin"),
                          (figureHeight > 0, "--figure-height")]:
      if given:
        return errorOut(&"--tile can't be combined with {flag}: a tile is opaque, so there is no key, outline, pivot or content fit",
          @["Drop the flag, or fix the file without --tile"])
    pivot = "none"
  if fitMode == "content" and (cellW == 0 or cellH == 0):
    return errorOut("--fit content needs --cell WxH", @["Run `para art fix <files> --fit content --cell 96x144`"])
  if fitMode != "content" and (marginGiven or figureHeight > 0):
    return errorOut("--margin and --figure-height only apply with --fit content", @[])
  if figureHeight > cellH:
    return errorOut(&"--figure-height {figureHeight} is taller than the {cellW}x{cellH} cell", @[])

  if paths.len == 0:
    if dirExists("art"):
      paths.add "art"
    else:
      return errorOut("no paths given and no ./art directory found",
        @["Run `para art fix <dir-or-file>...`"])

  var explicitStyle = none(Style)
  if styleArg.len > 0:
    try:
      explicitStyle = some(loadStyle(styleArg))
    except ProfileError as e:
      return errorOut(e.msg, @[])

  var pngs: seq[string]
  try:
    pngs = gatherPngs(paths)
  except IOError as e:
    return errorOut(e.msg, @[])

  if pngs.len == 0:
    result.output.add toonTable("fixed", fixCols, @[])
    result.output.add "fix: 0 assets found\n"
    result.output.add toonHelp(@["Point `para art fix` at a directory of PNGs"])
    result.code = 1
    return

  var styles = initTable[string, Style]()
  if styleArg.len > 0: styles[styleArg] = explicitStyle.get

  var assets: seq[AssetSpec]
  var infoLines: seq[string]
  try:
    for p in pngs:
      var style = explicitStyle
      if styleArg.len == 0:
        let stylePath = findStyleToml(p)
        if stylePath.len > 0:
          if stylePath notin styles: styles[stylePath] = loadStyle(stylePath)
          style = some(styles[stylePath])
      var a: AssetSpec
      a.path = p
      a.outName = p.splitFile.name
      a.pivot = pivot
      a.profileName =
        if profileArg.len > 0: profileArg
        elif style.isSome: style.get.profile.name
        else: builtinHiBit.name
      a.maxColors =
        if profileArg.len > 0: builtinProfile(profileArg).get(builtinHiBit).maxColors
        elif style.isSome: style.get.profile.maxColors
        else: builtinHiBit.maxColors
      a.cellW = cellW
      a.cellH = cellH
      a.keyHex = keyArg
      a.keyBorderOnly = keyBorderOnly
      a.outline = outlineFlag
      a.tile = tileFlag
      if style.isSome and style.get.palette.len > 0:
        a.palettePath = style.get.palettePath
        let line = &"palette: {a.palettePath} ({style.get.palette.len} colours, every asset)\n"
        if line notin infoLines: infoLines.add line
      assets.add a
  except ProfileError as e:
    return errorOut(e.msg, @[])

  for line in infoLines: result.output.add line

  var request = %*{"out_dir": outDir, "assets": newJArray()}
  if fitMode == "content":
    request["fit"] = %"content"
    request["margin"] = %marginPct
    if figureHeight > 0: request["figure_height"] = %figureHeight
  for a in assets:
    request["assets"].add toJson(a)

  var response: JsonNode
  try:
    response = runPyFix(request)
  except FixToolError as e:
    return errorOut(e.msg, @[])

  if response.hasKey("fit"):
    let f = response["fit"]
    result.output.add &"""fit: content, scale {f["scale"].getFloat()}, tallest figure {jint(f, "figure_w")}x{jint(f, "figure_h")} in a {cellW}x{cellH} cell""" & "\n"
  let results = response["results"]
  var rows: seq[seq[string]]
  var failing, keyHints, outlineHints: seq[string]
  var written, unchanged = 0
  for r in results:
    let file = jstr(r, "file")
    let key = jstr(r, "key")
    let skipReason =
      if key == "skip:corners": "its corners differ"
      elif key == "skip:alpha": "it already has transparency"
      else: ""
    if skipReason.len > 0:
      let hint = &"{file}: {skipReason}, so no background was keyed; pass --key RRGGBB to force keying"
      if hint notin keyHints: keyHints.add hint
    let outline = jstr(r, "outline")
    let outlineHint =
      if outline == "refuse:interior-ink":
        &"{file}: the body along its edge is as dark as the outline would be, so a rim would not read; no outline step applied"
      elif outline == "flag:all-boundary":
        &"{file}: nearly its whole boundary would be recoloured at this small a cell; check the result before shipping, no outline step applied"
      elif outline == "refuse:edge-touch":
        &"{file}: its silhouette touches the cell edge, so growing or recolouring its edge is unsafe; no outline step applied"
      elif outline == "refuse:floor-at-black":
        &"{file}: its darkest interior colour is too dark to nudge below, so the outline rule can't be cleared; no outline step applied"
      elif outline == "refuse:color-cap":
        &"{file}: the outline colour would push it over the profile's colour cap; no outline step applied"
      elif outline == "refuse:palette":
        &"{file}: the outline colour would fall outside the locked palette; no outline step applied"
      else: ""
    if outlineHint.len > 0:
      if outlineHint notin outlineHints: outlineHints.add outlineHint
    if r.hasKey("error"):
      failing.add &"""{file}: {r["error"].getStr()}"""
      rows.add @[file, "-", "-", "-", "-", "-", "-", "-", "-", key]
      continue
    let changed = r.hasKey("changed") and r["changed"].kind == JBool and r["changed"].getBool()
    if changed: inc written else: inc unchanged
    rows.add @[
      file,
      jstr(r, "out"),
      $changed,
      &"""{jint(r, "width")}x{jint(r, "height")}""",
      &"""{jint(r, "cell_w")}x{jint(r, "cell_h")}""",
      $jint(r, "colors"),
      $jint(r, "semi_alpha_px"),
      $jint(r, "orphan_removed"),
      jstr(r, "grid_source"),
      key,
    ]
  result.output.add toonTable("fixed", fixCols, rows)
  result.output.add &"fix: {written} written, {unchanged} unchanged, {failing.len} failed\n"
  let sidecars = writeSidecars(results, assets)
  if sidecars.written + sidecars.unchanged > 0:
    result.output.add &"sidecars: {sidecars.written} written, {sidecars.unchanged} unchanged\n"
  var leakHints: seq[string]
  for r in results:
    if jint(r, "key_leak_px") > 0:
      leakHints.add &"""{jstr(r, "file")}: stripped {jint(r, "key_leak_px")} stray key-coloured pixel(s) left after keying"""

  if failing.len > 0:
    result.output.add toonHelp(failing & keyHints & outlineHints & leakHints & sidecars.hints)
    result.code = 1
  else:
    result.output.add toonHelp(@[&"Run `para art lint {outDir}` to check the results"] & keyHints & outlineHints & leakHints & sidecars.hints)
    result.code = 0
