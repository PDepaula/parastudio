# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Tests for paraloop/save: the profile envelope round trip, the atomic write
# (a failed write leaves the old file whole and no temp behind), corrupt /
# wrong-game / newer-version handling (never a crash, never a lost file),
# migrations and the XDG data-directory resolution. Headless, no GL.

import std/[unittest, os, json, strutils]
import paraloop/save

const root = currentSourcePath().parentDir.parentDir / "tmp" / "test-save"

proc fresh(name: string): string =
  ## A clean directory of its own and the profile path inside it.
  let dir = root / name
  removeDir(dir)
  createDir(dir)
  dir / profileFile

proc bump(p: JsonNode): JsonNode =
  result = p
  result["migrated"] = %true

suite "paraloop/save: round trip":
  test "save then load gives the payload back, in a versioned envelope":
    let path = fresh("roundtrip").parentDir / "nested" / "deeper" / profileFile
    let payload = %*{"seen": ["a", "b"], "level": 3}
    let s = saveProfile(path, "demo", 2, payload)
    check s.ok
    check s.backup == ""
    let raw = parseJson(readFile(path))
    check raw["version"].getInt == 2
    check raw["game"].getStr == "demo"
    check raw["payload"] == payload
    let r = loadProfile(path, "demo", 2)
    check r.status == lsOk
    check r.payload == payload
    check r.version == 2
    check r.message == ""

  test "a second save replaces the first and leaves no temp file":
    let path = fresh("replace")
    check saveProfile(path, "demo", 1, %*{"n": 1}).ok
    check saveProfile(path, "demo", 1, %*{"n": 2}).ok
    check loadProfile(path, "demo", 1).payload["n"].getInt == 2
    check not fileExists(path & ".tmp")
    check not fileExists(path & ".bak")

  test "a missing file is lsMissing":
    let path = fresh("missing")
    let r = loadProfile(path, "demo", 1)
    check r.status == lsMissing
    check r.payload.isNil
    check r.path == path

suite "paraloop/save: atomic write":
  test "a write that fails keeps the old file whole and removes the temp":
    let path = fresh("atomic")
    check saveProfile(path, "demo", 1, %*{"n": 1}).ok
    let before = readFile(path)
    # Make the final rename fail: a leftover temp path that is a directory
    # cannot be written, so the write itself fails before the rename.
    createDir(path & ".tmp")
    let s = saveProfile(path, "demo", 1, %*{"n": 2})
    check not s.ok
    check s.message.contains("cannot write")
    check readFile(path) == before
    removeDir(path & ".tmp")
    check loadProfile(path, "demo", 1).payload["n"].getInt == 1

  test "a rename that fails leaves the old file and no partial temp":
    let dir = root / "atomic-rename"
    removeDir(dir)
    createDir(dir)
    # The target is a directory: the temp is written fine, the rename fails.
    let path = dir / profileFile
    createDir(path)
    let s = saveProfile(path, "demo", 1, %*{"n": 2})
    check not s.ok
    check dirExists(path)
    check not fileExists(path & ".tmp")

suite "paraloop/save: bad files":
  test "unreadable JSON and non-envelopes are lsCorrupt, and the file is not touched":
    for text in ["", "{not json", "[1, 2]", "42", "{\"version\": 1}",
                 "{\"version\": \"1\", \"game\": \"demo\", \"payload\": {}}",
                 "{\"version\": 0, \"game\": \"demo\", \"payload\": {}}"]:
      let path = fresh("corrupt")
      writeFile(path, text)
      let r = loadProfile(path, "demo", 1)
      check r.status == lsCorrupt
      check r.message.len > 0
      check readFile(path) == text
      check not fileExists(path & ".bak")

  test "saving over a corrupt file keeps it as .bak first":
    let path = fresh("corrupt-save")
    writeFile(path, "{half a profi")
    let s = saveProfile(path, "demo", 1, %*{"n": 1})
    check s.ok
    check s.backup == path & ".bak"
    check readFile(path & ".bak") == "{half a profi"
    check loadProfile(path, "demo", 1).status == lsOk

  test "another game's file is lsWrongGame and is backed up, not lost":
    let path = fresh("wrong-game")
    check saveProfile(path, "other", 1, %*{"x": 1}).ok
    let r = loadProfile(path, "demo", 1)
    check r.status == lsWrongGame
    check r.message.contains("other")
    let s = saveProfile(path, "demo", 1, %*{"n": 1})
    check s.ok
    check parseJson(readFile(path & ".bak"))["game"].getStr == "other"

  test "a newer version is lsNewer and is backed up before an older build overwrites it":
    let path = fresh("newer")
    check saveProfile(path, "demo", 5, %*{"x": 1}).ok
    let r = loadProfile(path, "demo", 4)
    check r.status == lsNewer
    check r.version == 5
    check r.payload.isNil
    check saveProfile(path, "demo", 4, %*{"n": 1}).ok
    check parseJson(readFile(path & ".bak"))["version"].getInt == 5

  test "an older version is backed up before the first save in the new one rewrites it":
    let path = fresh("older")
    check saveProfile(path, "demo", 1, %*{"n": 1}).ok
    let before = readFile(path)
    let s = saveProfile(path, "demo", 2, %*{"n": 1, "added": true})
    check s.ok
    check s.backup == path & ".bak"
    check readFile(path & ".bak") == before
    check parseJson(readFile(path))["version"].getInt == 2
    # the file is current now: a further save is not backed up again
    check saveProfile(path, "demo", 2, %*{"n": 2}).backup == ""
    check readFile(path & ".bak") == before

suite "paraloop/save: migrations":
  test "an older profile is walked up one version at a time":
    var order: seq[int]
    let path = fresh("migrate")
    check saveProfile(path, "demo", 1, %*{"n": 1}).ok
    let steps: Migrations = @[
      (1, proc (p: JsonNode): JsonNode = bump(p)),
      (2, proc (p: JsonNode): JsonNode =
        p["two"] = %2
        p)]
    let r = loadProfile(path, "demo", 3, steps)
    check r.status == lsOk
    check r.version == 1
    check r.payload["migrated"].getBool
    check r.payload["two"].getInt == 2
    check readFile(path).contains("\"version\": 1") # loading never rewrites

  test "a missing step or a throwing step is lsCorrupt, not a crash":
    let path = fresh("migrate-bad")
    check saveProfile(path, "demo", 1, %*{}).ok
    check loadProfile(path, "demo", 2).status == lsCorrupt
    let boom: Migrations = @[(1, proc (p: JsonNode): JsonNode = raise newException(ValueError, "boom"))]
    let r = loadProfile(path, "demo", 2, boom)
    check r.status == lsCorrupt
    check r.message.contains("boom")

suite "paraloop/save: data directory":
  test "XDG_DATA_HOME wins when it is an absolute path":
    let was = getEnv("XDG_DATA_HOME")
    defer:
      if was.len > 0: putEnv("XDG_DATA_HOME", was) else: delEnv("XDG_DATA_HOME")
    putEnv("XDG_DATA_HOME", "/srv/xdg-data")
    when defined(linux) or (defined(unix) and not defined(macosx)):
      check dataHome() == "/srv/xdg-data"
      check profilePath("demo") == "/srv/xdg-data/paraloop/demo/profile.json"
      # relative and empty values are ignored, as the XDG spec says
      putEnv("XDG_DATA_HOME", "relative/dir")
      check profilePath("demo") == getHomeDir() / ".local" / "share" / "paraloop" / "demo" / "profile.json"
      delEnv("XDG_DATA_HOME")
      check dataHome() == getHomeDir() / ".local" / "share"
    else:
      check profilePath("demo").endsWith("paraloop" / "demo" / "profile.json")
