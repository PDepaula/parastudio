import unittest
import std/[options, os, strutils]
import tools/para/art/profile

let testTmp = getTempDir() / ("paraloop_" & $getCurrentProcessId())

proc writeStyle(name, content: string): string =
  let dir = testTmp / name
  createDir(dir)
  result = dir / "style.toml"
  writeFile(result, content)

suite "art/profile: builtin low-bit/hi-bit defaults and style.toml overrides":
  test "the two builtins match the asset pipeline report's §4.2 reading":
    check builtinLowBit.maxColors == 16
    check builtinLowBit.outlineRequired == false
    check builtinHiBit.maxColors == 48
    check builtinHiBit.outlineRequired == true

  test "with no style.toml, resolveProfile returns the builtin untouched":
    let p = resolveProfile("hibit", none(Style))
    check p.maxColors == builtinHiBit.maxColors
    check p.source == "builtin default"

  test "a style.toml for this profile overrides only the keys it sets":
    let path = writeStyle("art_profile_test", "profile = \"hibit\"\nmax_colors = 24 # tighter\n")
    let p = resolveProfile("hibit", some(loadStyle(path)))
    check p.maxColors == 24
    check p.outlineRequired == builtinHiBit.outlineRequired # untouched
    check p.source == path
    removeDir(path.parentDir)

  test "punchclub is accepted as an alias of hibit wherever a profile is read":
    check canonicalProfileName("punchclub") == "hibit"
    check canonicalProfileName("hibit") == "hibit"
    check canonicalProfileName("lowbit") == "lowbit"
    check builtinProfile("punchclub").get.name == "hibit"
    check builtinProfile("punchclub").get.maxColors == builtinHiBit.maxColors
    # a style.toml written with the old name overlays the same profile, and a
    # sidecar using either name picks it up
    let path = writeStyle("art_profile_test_alias", "profile = \"punchclub\"\nmax_colors = 24\n")
    let style = loadStyle(path)
    check style.profile.name == "hibit"
    check resolveProfile("punchclub", some(style)).maxColors == 24
    check resolveProfile("hibit", some(style)).maxColors == 24
    removeDir(path.parentDir)

  test "a style.toml for a different profile is not misapplied":
    let path = writeStyle("art_profile_test2", "profile = \"lowbit\"\nmax_colors = 4\n")
    let p = resolveProfile("hibit", some(loadStyle(path)))
    check p.maxColors == builtinHiBit.maxColors
    check p.source == "builtin default"
    removeDir(path.parentDir)

  test "a style.toml that doesn't name a known profile fails loud":
    let path = writeStyle("art_profile_test3", "max_colors = 4\n")
    expect(ProfileError):
      discard loadStyle(path)
    writeFile(path, "profile = \"punchclb\"\n")
    expect(ProfileError):
      discard loadStyle(path)
    removeDir(path.parentDir)

  test "a missing style.toml or a malformed value fails loud with the path":
    expect(ProfileError):
      discard loadStyle(testTmp / "no_such_dir" / "stlye.toml")
    let path = writeStyle("art_profile_test4", "profile = \"lowbit\"\nmax_colors = lots\n")
    try:
      discard loadStyle(path)
      check false
    except ProfileError as e:
      check e.msg == path & ": max_colors: expected an integer, got lots"
    removeDir(path.parentDir)

  test "an unknown key or value that used to be a setting fails loud, not silently ignored":
    let path = writeStyle("art_profile_test6", "profile = \"hibit\"\nmax_colours = 24\n")
    try:
      discard loadStyle(path)
      check false
    except ProfileError as e:
      check e.msg.startsWith(path & ": unknown key \"max_colours\"")
    # Hard alpha and the bottom pivot are shared by both pixel profiles
    # (report §4.2), so a style.toml can't turn them off.
    for line in ["alpha = 0", "alpha = \"soft\"", "pivot = \"none\""]:
      writeFile(path, "profile = \"hibit\"\n" & line & "\n")
      checkpoint line
      expect(ProfileError):
        discard loadStyle(path)
    writeFile(path, "profile = \"hibit\"\n[[refs]]\nfile = \"a.png\"\n")
    expect(ProfileError):
      discard loadStyle(path)
    removeDir(path.parentDir)

  test "palette is read relative to the style.toml, one RRGGBB per line":
    let path = writeStyle("art_profile_test5",
      "profile = \"hibit\"\npalette = \"palette.hex\"\n")
    writeFile(path.parentDir / "palette.hex", "000000\n#FF0044\n\nffffff\n")
    let style = loadStyle(path)
    check style.palette == @[0x000000, 0xff0044, 0xffffff]
    check style.palettePath == path.parentDir / "palette.hex"
    check style.profile.source == path
    writeFile(path.parentDir / "palette.hex", "000000\nnot-a-colour\n")
    expect(ProfileError):
      discard loadStyle(path)
    removeFile(path.parentDir / "palette.hex")
    expect(ProfileError):
      discard loadStyle(path)
    removeDir(path.parentDir)

removeDir(testTmp)
