# Shared bits between `para art`'s subcommands (lint, sheet, fix): the
# `(output, code)` run shape artcmd.nim's runArt expects back from each one,
# a usage-error formatter, PNG path gathering (files or directories) and the
# art/style.toml discovery walk lint.nim's callers use (report §5.1 layer 2).
# Split out of artcmd.nim so fix.nim can reuse them without an import cycle.

import std/[algorithm, os]
import toon

type
  Run* = tuple[output: string, code: int]

proc errorOut*(msg: string, help: seq[string]): Run =
  result.output = "error: " & msg & "\n"
  let h = toonHelp(help)
  if h.len > 0: result.output.add h
  result.code = 2

proc gatherPngs*(paths: seq[string]): seq[string] =
  for p in paths:
    if not fileExists(p) and not dirExists(p):
      raise newException(IOError, p & ": no such file or directory")
    if dirExists(p):
      for f in walkFiles(p / "*.png"):
        result.add f
    else:
      result.add p
  result.sort()

proc findStyleToml*(pngPath: string): string =
  ## The nearest art/style.toml walking up from the sheet to the repo root,
  ## so a game's sheets get that game's style from any working directory.
  var dir = pngPath.absolutePath.parentDir
  while dir.len > 0:
    if fileExists(dir / "art" / "style.toml"): return dir / "art" / "style.toml"
    if dirExists(dir / ".git") or fileExists(dir / ".git"): break
    dir = dir.parentDir
