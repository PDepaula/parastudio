# Style profiles for `para art lint`/`sheet` (asset pipeline report §4.2, §5.1
# layer 2, §5.3). A game's own art/style.toml is the real source of these
# values once it exists (report §10 decision, A0); until a game writes one,
# lint falls back to one of the two built-in example profiles below, which
# read the report's low-bit and hi-bit numbers straight off its §4.2 table.
# They are defaults for an unwritten style, not a recommendation to skip A0 -
# a game's style.toml always wins where it sets a value. The hi-bit profile
# was first named `punchclub`; that name is still accepted wherever a profile
# is read (sidecars, style.toml, `--profile`) and maps to `hibit`.

import std/[options, os, strutils, tables]
import toml

type
  Profile* = object
    ## Both profiles share hard alpha (0/255) and a bottom-centre pivot
    ## (report §4.2), so neither is a profile setting.
    name*: string
    maxColors*: int
    outlineRequired*: bool
    orphanMax*: int
    source*: string ## where these values came from, for `para art`'s `style:` lines

  Style* = object
    ## A game's art/style.toml. The profile it overlays sets budgets and the
    ## outline rule for sidecars naming that profile; the palette is one per
    ## game (report §4.2, §5.1 layer 3), so it applies to every asset.
    profile*: Profile
    palette*: seq[int] ## packed 0xRRGGBB; empty disables the membership rule
    palettePath*: string

const
  builtinLowBit* = Profile(
    name: "lowbit",
    maxColors: 16,
    outlineRequired: false,
    orphanMax: 4,
    source: "builtin default")

  builtinHiBit* = Profile(
    name: "hibit",
    maxColors: 48,
    outlineRequired: true,
    orphanMax: 8,
    source: "builtin default")

  profileAliases = {"punchclub": "hibit"}

  styleKeys = ["profile", "palette", "max_colors", "outline_required", "orphan_max"]

proc canonicalProfileName*(name: string): string =
  ## The builtin's own name for `name`: an alias (`punchclub`) maps to the
  ## profile it stands for, anything else comes back unchanged.
  for (alias, canonical) in profileAliases:
    if name == alias: return canonical
  name

proc builtinProfile*(name: string): Option[Profile] =
  case canonicalProfileName(name)
  of "lowbit": some(builtinLowBit)
  of "hibit": some(builtinHiBit)
  else: none(Profile)

proc overlayToml*(base: Profile, doc: TomlDoc, source: string): Profile =
  ## Overlays whatever keys a style.toml sets on top of a builtin default.
  ## Keys the file omits keep the builtin's value.
  result = base
  result.source = source
  if doc.top.hasKey("max_colors"): result.maxColors = doc.top.getInt("max_colors", result.maxColors)
  if doc.top.hasKey("outline_required"): result.outlineRequired = doc.top.getBool("outline_required", result.outlineRequired)
  if doc.top.hasKey("orphan_max"): result.orphanMax = doc.top.getInt("orphan_max", result.orphanMax)

type
  ProfileError* = object of CatchableError

proc loadPalette(path: string): seq[int] =
  ## Lospec .hex format: one RRGGBB per line (report §5.1 layer 3).
  for rawLine in readFile(path).splitLines:
    let line = rawLine.strip()
    if line.len == 0: continue
    let hex = if line.startsWith("#"): line[1 .. ^1] else: line
    if hex.len != 6 or not hex.allCharsInSet(HexDigits):
      raise newException(ValueError, path & ": \"" & line & "\" is not an RRGGBB colour")
    result.add parseHexInt(hex)
  if result.len == 0:
    raise newException(ValueError, path & ": palette has no colours")

proc loadStyle*(path: string): Style =
  ## A game's art/style.toml: its `profile` key names the builtin it
  ## overlays, and `palette` (a .hex file, relative to the style.toml)
  ## turns on the palette-membership rule for every asset.
  try:
    let doc = loadToml(path)
    for key in doc.top.keys:
      if key notin styleKeys:
        raise newException(ValueError,
          "unknown key \"" & key & "\" (valid: " & styleKeys.join(", ") & ")")
    for name in doc.arrays.keys:
      raise newException(ValueError, "unknown table [[" & name & "]]")
    let name = doc.top.getStr("profile")
    let base = builtinProfile(name)
    if base.isNone:
      raise newException(ValueError,
        "profile must be lowbit or hibit, got \"" & name & "\"")
    result.profile = overlayToml(base.get, doc, path)
    let palettePath = doc.top.getStr("palette")
    if palettePath.len > 0:
      result.palettePath =
        if palettePath.isAbsolute: palettePath else: path.parentDir / palettePath
      result.palette = loadPalette(result.palettePath)
  except IOError, ValueError:
    raise newException(ProfileError, path & ": " & getCurrentExceptionMsg())

proc resolveProfile*(name: string, style: Option[Style]): Profile =
  ## A game's style.toml is one profile for that game, not a table of all of
  ## them, so a sidecar asking for a profile the style doesn't set gets that
  ## profile's builtin default (its `style:` line says so). `name` is a
  ## sidecar's, which loadSidecar has already checked is a builtin (or an
  ## alias of one).
  let canonical = canonicalProfileName(name)
  if style.isSome and style.get.profile.name == canonical:
    return style.get.profile
  builtinProfile(canonical).get
