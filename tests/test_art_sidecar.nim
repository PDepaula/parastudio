import unittest
import std/[options, os, strutils]
import tools/para/art/sidecar

let testTmp = getTempDir() / ("paraloop_" & $getCurrentProcessId())

suite "art/sidecar: per-asset cell size and waivers":
  test "loadSidecar returns none when no <name>.art.toml exists":
    let dir = testTmp / "art_sidecar_test_missing"
    createDir(dir)
    check loadSidecar(dir / "nope.png").isNone
    removeDir(dir)

  test "cell size, profile and pivot round-trip":
    let dir = testTmp / "art_sidecar_test_basic"
    createDir(dir)
    writeFile(dir / "hero.art.toml", """
      cell_w = 64
      cell_h = 64
      profile = "hibit"
      pivot = "bottom"
    """)
    let sc = loadSidecar(dir / "hero.png")
    check sc.isSome
    check sc.get.cellW == 64
    check sc.get.cellH == 64
    check sc.get.profile == "hibit"
    check sc.get.pivot == "bottom"
    check sc.get.waivers.len == 0
    removeDir(dir)

  test "a waiver carries its rule and reason":
    let dir = testTmp / "art_sidecar_test_waiver"
    createDir(dir)
    writeFile(dir / "ghost.art.toml", """
      cell_w = 64
      cell_h = 64
      profile = "hibit"

      [[waiver]]
      rule = "alpha"
      reason = "translucent by design"
    """)
    let sc = loadSidecar(dir / "ghost.png")
    check sc.isSome
    check sc.get.waivers.len == 1
    check sc.get.waivers[0].rule == "alpha"
    check sc.get.waivers[0].reason == "translucent by design"
    removeDir(dir)

  test "a sidecar missing cell_w/cell_h fails loud, not silently":
    let dir = testTmp / "art_sidecar_test_incomplete"
    createDir(dir)
    writeFile(dir / "bad.art.toml", "profile = \"hibit\"\n")
    expect(SidecarError):
      discard loadSidecar(dir / "bad.png")
    removeDir(dir)

  test "an inline comment doesn't leak into the pivot or profile":
    let dir = testTmp / "art_sidecar_test_comment"
    createDir(dir)
    writeFile(dir / "hero.art.toml", """
      cell_w = 64
      cell_h = 64
      profile = "hibit" # hi-bit
      pivot = "bottom" # feet on the baseline
    """)
    let sc = loadSidecar(dir / "hero.png")
    check sc.get.profile == "hibit"
    check sc.get.pivot == "bottom"
    removeDir(dir)

  test "a non-integer or non-positive cell size fails loud with the path":
    let dir = testTmp / "art_sidecar_test_badcell"
    createDir(dir)
    for bad in ["64px", "64.0", "0", "-8"]:
      checkpoint bad
      writeFile(dir / "bad.art.toml", "cell_w = " & bad & "\ncell_h = 64\nprofile = \"hibit\"\n")
      try:
        discard loadSidecar(dir / "bad.png")
        check false
      except SidecarError as e:
        check e.msg.startsWith(dir / "bad.art.toml")
    removeDir(dir)

  test "pivot defaults to bottom and must be bottom or none":
    let dir = testTmp / "art_sidecar_test_pivot"
    createDir(dir)
    writeFile(dir / "hero.art.toml", "cell_w = 64\ncell_h = 64\nprofile = \"hibit\"\n")
    check loadSidecar(dir / "hero.png").get.pivot == "bottom"
    writeFile(dir / "hero.art.toml", "cell_w = 64\ncell_h = 64\nprofile = \"hibit\"\npivot = \"none\"\n")
    check loadSidecar(dir / "hero.png").get.pivot == "none"
    writeFile(dir / "hero.art.toml", "cell_w = 64\ncell_h = 64\nprofile = \"hibit\"\npivot = \"feet\"\n")
    expect(SidecarError):
      discard loadSidecar(dir / "hero.png")
    removeDir(dir)

  test "an unknown profile name fails loud with the path, not a silent default":
    let dir = testTmp / "art_sidecar_test_profile"
    createDir(dir)
    writeFile(dir / "hero.art.toml", "cell_w = 64\ncell_h = 64\nprofile = \"painted\"\n")
    try:
      discard loadSidecar(dir / "hero.png")
      check false
    except SidecarError as e:
      check e.msg.startsWith(dir / "hero.art.toml" & ": profile must be")
    removeDir(dir)

  test "an unknown key or table fails loud with the path, not silently ignored":
    let dir = testTmp / "art_sidecar_test_unknown"
    createDir(dir)
    for extra in ["pviot = \"none\"", "[[waivers]]\nrule = \"alpha\"\nreason = \"x\""]:
      writeFile(dir / "hero.art.toml", "cell_w = 64\ncell_h = 64\nprofile = \"hibit\"\n" & extra & "\n")
      checkpoint extra
      try:
        discard loadSidecar(dir / "hero.png")
        check false
      except SidecarError as e:
        check e.msg.startsWith(dir / "hero.art.toml" & ": unknown")
    removeDir(dir)

suite "art/sidecar: the optional key and the file fix writes":
  test "key is optional, lowercased, and checked":
    let dir = testTmp / "art_sidecar_test_key"
    createDir(dir)
    writeFile(dir / "a.art.toml", "cell_w = 8\ncell_h = 8\nprofile = \"hibit\"\n")
    check loadSidecar(dir / "a.png").get.key == ""
    writeFile(dir / "a.art.toml", "cell_w = 8\ncell_h = 8\nprofile = \"hibit\"\nkey = \"00FF00\"\n")
    check loadSidecar(dir / "a.png").get.key == "00ff00"
    for bad in ["0f0", "00ff0g", "magenta"]:
      writeFile(dir / "a.art.toml", "cell_w = 8\ncell_h = 8\nprofile = \"hibit\"\nkey = \"" & bad & "\"\n")
      checkpoint bad
      try:
        discard loadSidecar(dir / "a.png")
        check false
      except SidecarError as e:
        check e.msg.startsWith(dir / "a.art.toml" & ": key must be")
    removeDir(dir)

  test "writeSidecar round-trips through loadSidecar, waivers included, and only writes on a change":
    let dir = testTmp / "art_sidecar_test_write"
    createDir(dir)
    let sc = Sidecar(cellW: 96, cellH: 144, profile: "hibit", pivot: "bottom", key: "00ff00",
      waivers: @[Waiver(rule: "alpha", reason: "translucent by design")])
    check writeSidecar(dir / "hero.png", sc)
    check loadSidecar(dir / "hero.png").get == sc
    check not writeSidecar(dir / "hero.png", sc)
    var changed = sc
    changed.cellH = 96
    check writeSidecar(dir / "hero.png", changed)
    check loadSidecar(dir / "hero.png").get.cellH == 96
    removeDir(dir)

removeDir(testTmp)
