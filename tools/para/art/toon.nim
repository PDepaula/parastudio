# Minimal TOON-shaped table/help writer (AXI principle 1: TOON output;
# principle 9: next-step help[] hints). Not a general TOON encoder - just the
# flat `name[N]{cols}:` row shape every sample in the reports uses.

import std/[strutils, sequtils]
from std/json import escapeJson

proc toonCell*(s: string): string =
  ## `s` as one TOON field: bare when it is unambiguous, otherwise a
  ## double-quoted JSON-style string -- the same rule as paraloop/dev's
  ## `toonFacts` (the delimiter, a quote, a backslash, a colon, a control
  ## character or edge whitespace, or empty).
  let bare = s.len > 0 and s == s.strip and
    not s.anyIt(it in {',', '"', '\\', ':'} or it < ' ' or it == '\x7f')
  if bare: s else: s.escapeJson

proc toonRow*(row: seq[string]): string =
  row.map(toonCell).join(",")

proc toonTable*(name: string, cols: openArray[string], rows: seq[seq[string]]): string =
  result = name & "[" & $rows.len & "]{" & cols.join(",") & "}:\n"
  for row in rows:
    result.add("  " & toonRow(row) & "\n")

proc toonHelp*(lines: seq[string]): string =
  if lines.len == 0:
    return ""
  result = "help[" & $lines.len & "]:\n"
  for line in lines:
    result.add("  " & line & "\n")
