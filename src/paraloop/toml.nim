## A deliberately tiny TOML subset reader: art/style.toml and the per-asset
## <name>.art.toml sidecars (report §5.1 layer 2, §6.1 step 10) and a game's
## `tuning.toml` (its dials). Not a general TOML parser: only
## top-level `key = value` pairs and `[[array]]` array-of-tables are supported,
## which is all those file shapes need. Values are kept as raw strings; callers
## convert. It runs in Nim's compile-time VM too, so a game can embed a file
## with `staticRead` and parse it in a `const`.

import std/[strutils, tables]

type
  TomlTable* = OrderedTable[string, string]
  TomlDoc* = object
    top*: TomlTable
    arrays*: OrderedTable[string, seq[TomlTable]]

proc unquote(raw: string): string =
  if raw.len >= 2 and raw[0] == '"' and raw[^1] == '"':
    raw[1 ..< raw.len - 1]
  else:
    raw

proc stripComment(line: string): string =
  var inString = false
  var i = 0
  while i < line.len:
    case line[i]
    of '\\':
      if inString: inc i
    of '"':
      inString = not inString
    of '#':
      if not inString: return line[0 ..< i]
    else: discard
    inc i
  line

proc parseToml*(content: string): TomlDoc =
  result.top = initOrderedTable[string, string]()
  result.arrays = initOrderedTable[string, seq[TomlTable]]()
  var inArray = false
  var arrayName = ""
  for rawLine in content.splitLines:
    let line = stripComment(rawLine).strip()
    if line.len == 0:
      continue
    if line.startsWith("[[") and line.endsWith("]]"):
      arrayName = line[2 ..< line.len - 2].strip()
      if arrayName notin result.arrays:
        result.arrays[arrayName] = @[]
      result.arrays[arrayName].add(initOrderedTable[string, string]())
      inArray = true
      continue
    if line.startsWith("[") and line.endsWith("]"):
      # A plain [section] header. Neither style.toml nor the sidecar schema
      # uses one; treat it as "back to top-level" rather than failing loud,
      # since a stray section shouldn't break lint on an otherwise-fine file.
      inArray = false
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    let key = line[0 ..< eq].strip()
    let val = unquote(line[eq + 1 .. ^1].strip())
    if inArray:
      result.arrays[arrayName][^1][key] = val
    else:
      result.top[key] = val

proc loadToml*(path: string): TomlDoc =
  parseToml(readFile(path))

proc getStr*(t: TomlTable, key: string, default: string = ""): string =
  if t.hasKey(key): t[key] else: default

proc getInt*(t: TomlTable, key: string, default: int): int =
  if not t.hasKey(key): return default
  try:
    parseInt(t[key])
  except ValueError:
    raise newException(ValueError, key & ": expected an integer, got " & t[key])

proc getBool*(t: TomlTable, key: string, default: bool): bool =
  if not t.hasKey(key): return default
  try:
    parseBool(t[key])
  except ValueError:
    raise newException(ValueError, key & ": expected true or false, got " & t[key])

proc getFloat*(t: TomlTable, key: string, default: float): float =
  if not t.hasKey(key): return default
  try:
    parseFloat(t[key])
  except ValueError:
    raise newException(ValueError, key & ": expected a number, got " & t[key])
