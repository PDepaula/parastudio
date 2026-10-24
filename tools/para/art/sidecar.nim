# Per-asset sidecars: <name>.art.toml next to <name>.png. This is the ground
# truth for a sheet's declared cell size (report §7.2: koalio.png's 128x32
# sheet is hand-offset into 18x26 cells by design, which no grid-detection
# heuristic would recover - the game already knows this the way
# parasurvivors' src/data.nim:152-167 SheetDef table knows it) and it carries
# per-asset lint waivers with a reason (report §5.3, §6.1 step 10), never a
# global rule loosening.

import std/[options, os, strutils, tables]
import profile, toml

type
  Waiver* = object
    rule*: string
    reason*: string

  Sidecar* = object
    cellW*, cellH*: int
    profile*: string
    pivot*: string ## "bottom" (feet on the cell's bottom row may touch it) or "none"
    kind*: string ## "" (the default) for a sprite or sheet, "tile" for one seamless full-bleed ground tile
    key*: string ## optional RRGGBB the sprite was keyed from, "" when unknown; lint's `key` rule needs it
    waivers*: seq[Waiver]

  SidecarError* = object of CatchableError

const sidecarKeys = ["cell_w", "cell_h", "profile", "pivot", "kind", "key"]

proc sidecarPath*(pngPath: string): string =
  let (dir, name, _) = splitFile(pngPath)
  (if dir.len > 0: dir / name else: name) & ".art.toml"

proc loadSidecar*(pngPath: string): Option[Sidecar] =
  let path = sidecarPath(pngPath)
  if not fileExists(path):
    return none(Sidecar)
  let doc = loadToml(path)
  for key in doc.top.keys:
    if key notin sidecarKeys:
      raise newException(SidecarError, path & ": unknown key \"" & key &
        "\" (valid: " & sidecarKeys.join(", ") & ", [[waiver]])")
  for name in doc.arrays.keys:
    if name != "waiver":
      raise newException(SidecarError, path & ": unknown table [[" & name & "]]")
  if not doc.top.hasKey("cell_w") or not doc.top.hasKey("cell_h"):
    raise newException(SidecarError, path & ": missing cell_w/cell_h")
  if not doc.top.hasKey("profile"):
    raise newException(SidecarError, path & ": missing profile")
  var sc: Sidecar
  try:
    sc = Sidecar(
      cellW: doc.top.getInt("cell_w", 0),
      cellH: doc.top.getInt("cell_h", 0),
      profile: doc.top.getStr("profile"),
      pivot: doc.top.getStr("pivot", "bottom"),
      kind: doc.top.getStr("kind"),
      key: doc.top.getStr("key").toLowerAscii)
  except ValueError as e:
    raise newException(SidecarError, path & ": " & e.msg)
  if sc.cellW < 1 or sc.cellH < 1:
    raise newException(SidecarError, path & ": cell_w and cell_h must be at least 1")
  if builtinProfile(sc.profile).isNone:
    raise newException(SidecarError, path & ": profile must be lowbit or hibit, got \"" & sc.profile & "\"")
  if sc.pivot notin ["bottom", "none"]:
    raise newException(SidecarError, path & ": pivot must be bottom or none, got \"" & sc.pivot & "\"")
  if sc.kind notin ["", "tile"]:
    raise newException(SidecarError, path & ": kind must be tile when present, got \"" & sc.kind & "\"")
  if sc.key.len > 0 and (sc.key.len != 6 or not sc.key.allCharsInSet(HexDigits)):
    raise newException(SidecarError, path & ": key must be an RRGGBB hex colour, got \"" & sc.key & "\"")
  if doc.arrays.hasKey("waiver"):
    for w in doc.arrays["waiver"]:
      if not w.hasKey("rule") or not w.hasKey("reason"):
        raise newException(SidecarError, path & ": [[waiver]] needs rule and reason")
      sc.waivers.add(Waiver(rule: w.getStr("rule"), reason: w.getStr("reason")))
  some(sc)

proc renderSidecar*(sc: Sidecar): string =
  ## The file `fix` writes: the four keys lint needs (plus `kind` for a tile and `key` when known),
  ## then any waivers carried over from the file it replaces.
  result = "cell_w = " & $sc.cellW & "\ncell_h = " & $sc.cellH &
    "\nprofile = \"" & sc.profile & "\"\npivot = \"" & sc.pivot & "\"\n"
  if sc.kind.len > 0: result.add "kind = \"" & sc.kind & "\"\n"
  if sc.key.len > 0: result.add "key = \"" & sc.key & "\"\n"
  for w in sc.waivers:
    result.add "\n[[waiver]]\nrule = \"" & w.rule & "\"\nreason = \"" & w.reason & "\"\n"

proc writeSidecar*(pngPath: string, sc: Sidecar): bool =
  ## Writes `<name>.art.toml` next to the png unless it already says exactly
  ## this; true when the file changed. Waivers in an existing sidecar are the
  ## caller's to carry over (see `fix.nim`): a sidecar is never rewritten
  ## without them.
  let path = sidecarPath(pngPath)
  let text = renderSidecar(sc)
  if fileExists(path) and readFile(path) == text: return false
  writeFile(path, text)
  true
