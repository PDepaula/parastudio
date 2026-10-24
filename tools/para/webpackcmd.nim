# `para web pack`: zips a finished `para build --target web` output into what
# a static host needs (tools/web/pack.mjs has the file list and the zip
# format). It packs what is on disk and builds nothing, so the zip is the
# build `para web smoke` and `para build` left in tmp/web/<game>/.

import std/[os, json, strutils, strformat]
import art/[clihelpers, toon]
import nimutil
import games
import webbuild

type Run = clihelpers.Run

const webPackHelp* = "para web pack [--game NAME | --dir DIR] [--out FILE]\n" &
  "  zips tmp/web/<game>/ (from `para build --target web`; or DIR) into exactly what a static host needs:\n" &
  "  index.html, <game>.js, <game>.wasm, manifest.webmanifest and the two icons -- no build.json,\n" &
  "  no stale files. The zip is reproducible (sorted entries, fixed time stamp): the same build\n" &
  "  packs to the same bytes. Default FILE: tmp/web/<game>-<build id>.zip; a -d:dev build is refused\n"

proc isDevDefine*(d: string): bool =
  ## Whether the define `d` (`NAME` or `NAME=VALUE`) turns on `defined(dev)`:
  ## nim compares define names ignoring case and underscores, so `Dev`, `DEV`
  ## and `d_ev` are `dev` too, whatever the value.
  d.split('=', 1)[0].toLowerAscii.replace("_", "") == "dev"

proc runWebPack*(args: seq[string]): Run =
  var gameName = "hello"
  var outFile = ""
  var dir = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (webPackHelp, 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      gameName = args[i]
    of "--dir":
      inc i
      if i >= args.len: return errorOut("--dir needs a path", @[])
      dir = args[i]
    of "--out":
      inc i
      if i >= args.len: return errorOut("--out needs a path", @[])
      outFile = args[i]
    else:
      return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --game NAME, --dir DIR, --out FILE"])
    inc i

  if dir.len == 0:
    var game: Game
    let notFound = resolveGame(gameName, game)
    if notFound.code != 0: return notFound
    gameName = game.name
    dir = webOutDir(gameName)
  let info = readBuildInfo(dir)
  if info.isNil or info{"id"}.getStr.len == 0:
    return errorOut(&"no web build in {dir}",
      @[&"Run `para build --target web --game {gameName}` first"])
  var isDev = false
  for d in info{"defines"}.getElems:
    if isDevDefine(d.getStr): isDev = true
  if isDev:
    return errorOut(&"{dir} is a -d:dev build (it carries the dev control channel): not for shipping",
      @[&"Run `para build --target web --game {gameName}` without --define dev"])
  let id = info["id"].getStr
  if outFile.len == 0:
    outFile = webRoot / (info{"game"}.getStr(gameName) & "-" & id & ".zip")

  let pack = runCaptured("node", @["tools/web/pack.mjs", "--dir", dir, "--out", outFile])
  if pack.exitCode != 0:
    result.output = "error: web pack failed\n" & lastLines(pack.output, 20)
    result.code = 1
    return

  var rows: seq[seq[string]]
  var zipLine: seq[string]
  var leftOut = ""
  for line in pack.output.splitLines:
    let parts = line.split("  ")
    if line.startsWith("file  ") and parts.len == 3:
      rows.add @[parts[1], parts[2]]
    elif line.startsWith("zip  ") and parts.len >= 3:
      zipLine = parts
    elif line.startsWith("left out  "):
      leftOut = line["left out  ".len .. ^1]
  result.output = &"pack: ok, wrote {outFile}, build {id}\n"
  result.output.add toonTable("files", ["name", "bytes"], rows)
  if zipLine.len >= 3:
    result.output.add &"zip: {zipLine[2]} bytes, {zipLine[^1]}\n"
  if leftOut.len > 0:
    result.output.add &"left out: {leftOut}\n"
