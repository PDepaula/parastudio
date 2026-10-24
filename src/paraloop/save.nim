# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
## paraloop/save: a game-agnostic profile store -- the progress a game keeps
## between runs, as one versioned JSON file in the OS data directory. The
## engine never looks inside the payload; a game owns its fields, its
## version number and its migrations.
##
## File shape (`profile.json`):
##
##   {"version": 3, "game": "mygame", "payload": { ...the game's... }}
##
## - Path: `profilePath(game)` -> `<data home>/paraloop/<game>/profile.json`.
##   Data home is `$XDG_DATA_HOME` (else `~/.local/share`) on Linux and other
##   unixes, `~/Library/Application Support` on macOS and `%APPDATA%` on
##   Windows. An empty or relative `XDG_DATA_HOME` is ignored, as the XDG
##   spec says.
## - `loadProfile` never raises and never writes. It returns a `LoadResult`
##   whose `status` is `lsOk`, `lsMissing`, `lsCorrupt` (unreadable, not
##   JSON, or not an envelope), `lsWrongGame` (another game's file) or
##   `lsNewer` (written by a newer build of this game). An older version is
##   walked up to the current one through `migrations` (version N -> N + 1,
##   one entry per step); a gap or a throwing step is `lsCorrupt`.
## - `saveProfile` writes a temp file beside the target and renames it over,
##   so a crash or a full disk leaves the old file whole, never half of a
##   new one. When the file it is about to replace is corrupt, another
##   game's, newer than `version` or older than it (the first save after an
##   upgrade, which rewrites it in the new format), that file is first copied
##   to `profile.json.bak`, so a bad or pre-migration file is never silently
##   destroyed.
## - Web (`-d:emscripten`): a stub. Every call reports `lsUnavailable` /
##   a failed `SaveResult` until browser storage lands.

import std/[json, os]

type
  LoadStatus* = enum
    lsOk          ## `payload` is the game's, migrated to the asked version
    lsMissing     ## no file yet: a first run
    lsCorrupt     ## unreadable, not JSON, not an envelope, or cannot migrate
    lsWrongGame   ## the envelope names another game
    lsNewer       ## written by a newer version than this build understands
    lsUnavailable ## this target has no profile storage (web, for now)

  LoadResult* = object
    status*: LoadStatus
    payload*: JsonNode ## the game's payload when `status == lsOk`, else nil
    version*: int      ## the version found in the file (0 when unknown)
    message*: string   ## one line saying why, empty on `lsOk`
    path*: string

  SaveResult* = object
    ok*: bool
    message*: string   ## why a save failed, empty on success
    path*: string
    backup*: string    ## the `.bak` written for a file it replaced, if any

  Migration* = proc (payload: JsonNode): JsonNode {.nimcall.}
    ## Turns a version-N payload into a version-(N + 1) one.

  Migrations* = seq[tuple[fromVersion: int, migrate: Migration]]

const
  profileFile* = "profile.json"
  webStub* = defined(emscripten)
    ## True where profile storage is a stub (real web storage is a later step).

proc dataHome*(): string =
  ## The OS's per-user data directory (no `paraloop/<game>` suffix). Empty on
  ## the web stub.
  when webStub:
    ""
  elif defined(windows):
    getEnv("APPDATA", getHomeDir() / "AppData" / "Roaming")
  elif defined(macosx):
    getHomeDir() / "Library" / "Application Support"
  else:
    let xdg = getEnv("XDG_DATA_HOME")
    if xdg.len > 0 and xdg.isAbsolute: xdg else: getHomeDir() / ".local" / "share"

proc profilePath*(game: string): string =
  ## `<data home>/paraloop/<game>/profile.json`; empty on the web stub.
  when webStub:
    ""
  else:
    dataHome() / "paraloop" / game / profileFile

proc envelope*(game: string, version: int, payload: JsonNode): JsonNode =
  %*{"version": version, "game": game, "payload": payload}

proc fail(path: string, status: LoadStatus, message: string, version = 0): LoadResult =
  LoadResult(status: status, version: version, message: message, path: path)

proc parseProfile*(text, game: string, version: int,
                   migrations: Migrations = @[]): LoadResult =
  ## `loadProfile` for text already in hand (and its tests).
  var root: JsonNode
  try:
    root = parseJson(text)
  except JsonParsingError, ValueError:
    return fail("", lsCorrupt, "not valid JSON: " & getCurrentExceptionMsg())
  if root.kind != JObject or root{"version"}.isNil or root{"version"}.kind != JInt or
      root{"game"}.isNil or root{"game"}.kind != JString or root{"payload"}.isNil:
    return fail("", lsCorrupt, "not a profile: needs \"version\", \"game\" and \"payload\"")
  let found = root["version"].getInt
  if root["game"].getStr != game:
    return fail("", lsWrongGame,
      "profile belongs to \"" & root["game"].getStr & "\", not \"" & game & "\"", found)
  if found < 1:
    return fail("", lsCorrupt, "version " & $found & " is below 1", found)
  if found > version:
    return fail("", lsNewer,
      "profile is version " & $found & ", this build reads up to " & $version, found)
  var payload = root["payload"]
  var at = found
  while at < version:
    var step: Migration
    for m in migrations:
      if m.fromVersion == at: step = m.migrate
    if step.isNil:
      return fail("", lsCorrupt, "no migration from version " & $at & " to " & $(at + 1), found)
    try:
      payload = step(payload)
    except CatchableError:
      return fail("", lsCorrupt,
        "migration from version " & $at & " failed: " & getCurrentExceptionMsg(), found)
    if payload.isNil:
      return fail("", lsCorrupt, "migration from version " & $at & " returned nothing", found)
    inc at
  LoadResult(status: lsOk, payload: payload, version: found)

proc loadProfile*(path, game: string, version: int,
                  migrations: Migrations = @[]): LoadResult =
  ## Reads `path`; see the module doc for the statuses. Never raises, never
  ## writes: a corrupt file stays exactly as it was.
  when webStub:
    result = fail(path, lsUnavailable, "profile storage is not available on the web yet")
  else:
    if not fileExists(path):
      return fail(path, lsMissing, "no profile at " & path)
    var text: string
    try:
      text = readFile(path)
    except IOError, OSError:
      return fail(path, lsCorrupt, "cannot read: " & getCurrentExceptionMsg())
    result = parseProfile(text, game, version, migrations)
    result.path = path

proc saveProfile*(path, game: string, version: int, payload: JsonNode): SaveResult =
  ## Atomically replaces `path` with `payload` as `game`'s version-`version`
  ## profile. Never raises; on failure the old file is untouched and the temp
  ## file is gone.
  result.path = path
  when webStub:
    result.message = "profile storage is not available on the web yet"
  else:
    let tmp = path & ".tmp"
    try:
      createDir(path.parentDir)
      # No migrations here, so an older file reads as `lsCorrupt` (no step):
      # the same `.bak` as a bad one, which is the pre-migration original kept.
      let existing = loadProfile(path, game, version)
      if existing.status in {lsCorrupt, lsWrongGame, lsNewer}:
        let bak = path & ".bak"
        copyFile(path, bak)
        result.backup = bak
      block write:
        let f = open(tmp, fmWrite)
        defer: f.close()
        f.write(pretty(envelope(game, version, payload)))
        f.write("\n")
        f.flushFile()
      moveFile(tmp, path)
      result.ok = true
    except CatchableError, Defect:
      discard tryRemoveFile(tmp)
      result.ok = false
      result.message = "cannot write " & path & ": " & getCurrentExceptionMsg()
