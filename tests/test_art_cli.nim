# AXI-shape checks on `para art`'s output (asset pipeline report §8.3, engine
# report §5.1): TOON tables, a definitive empty state, next-step help[]
# hints, and exit codes 0 (pass) / 1 (findings) / 2 (usage error).

import unittest
import std/[os, strutils]
import tools/para/artcmd

const fixturesDir = currentSourcePath.parentDir / "fixtures" / "art"

let testTmp = getTempDir() / ("paraloop_" & $getCurrentProcessId())

suite "para art: bare invocation and --help":
  test "bare `para art` is content-first, not a blank prompt":
    let r = runArt(@[])
    check r.code == 0
    check r.output.contains("para art")
    check r.output.contains("help[")

  test "an unknown subcommand fails loud with the valid list, exit 2":
    let r = runArt(@["bogus"])
    check r.code == 2
    check r.output.startsWith("error:")
    check r.output.contains("lint")
    check r.output.contains("sheet")

proc tempDirWith(name: string, fixtures: openArray[string]): string =
  result = testTmp / name
  createDir(result)
  for f in fixtures:
    copyFile(fixturesDir / f & ".png", result / f & ".png")
    copyFile(fixturesDir / f & ".art.toml", result / f & ".art.toml")

proc waiveOutline(dir: string, fixtures: openArray[string]) =
  ## The LPC fixtures aren't drawn to hibit's outline rule; a sidecar
  ## waiver is how such a sheet passes.
  for f in fixtures:
    let sidecar = dir / f & ".art.toml"
    writeFile(sidecar, readFile(sidecar) &
      "\n[[waiver]]\nrule = \"outline\"\nreason = \"LPC art\"\n")

suite "para art lint: exit codes and TOON shape":
  test "the fixtures directory prints §7.2's table, the waivers and the real findings":
    let r = runArt(@["lint", fixturesDir])
    check r.code == 1
    check r.output.contains("sheets[12]{file,size,cell,grid,colors,semi_alpha_px,empty_cells,edge_touch_cells,outline,palette}:")
    for row in [
        "zombie.png,576x256,64x64,ok,16,0,0,0",
        "skeleton.png,576x256,64x64,ok,6,0,0,0",
        "ghost.png,576x256,64x64,ok,0,19148,0,0",
        "bat.png,96x128,32x32,ok,6,0,0,6",
        "koalio.png,128x32,18x26,BAD,172,609,unmeasured,unmeasured,unmeasured",
        "painted.png,210x100,70x100,ok,2626,1399,0,3",
        "otto.png,1152x512,128x128,ok,29,0,0,0",
        "otto_attack.png,1536x768,192x192,ok,31,0,0,0",
        "imma.png,576x256,64x64,ok,35,0,0,2",
        "lina_attack.png,1152x768,192x192,ok,28,0,0,0",
        "gino.png,1152x512,128x128,ok,24,0,0,0",
        "gino_attack.png,832x256,64x64,ok,39,0,0,20"]:
      check r.output.contains("  " & fixturesDir / row & ",")
    check r.output.contains("  " & fixturesDir / "zombie.png,576x256,64x64,ok,16,0,0,0,3967 px,-\n")
    check r.output.contains("style: hibit (builtin default)")
    check r.output.contains("style: lowbit (builtin default)")
    check r.output.contains("waived: " & fixturesDir / "ghost.png alpha")
    check r.output.contains("waived: " & fixturesDir / "koalio.png grid")
    # bat's and gino_attack's side clips (not their bottom-pivot touches),
    # koalio's unmeasured cells and colours/alpha beyond its grid waiver,
    # painted.png's painted-style colours, and the LPC sheets' missing
    # hibit outline are the real findings among the twelve.
    check r.output.contains("lint: 12 of 12 failed")
    check r.output.contains("bat.png: edge")
    check r.output.contains("gino_attack.png: outline, edge")
    check r.output.contains("zombie.png: outline")
    check r.output.contains("ghost.png: outline")
    check r.output.contains("koalio.png: cells unmeasured, colors, alpha")
    check r.output.contains("painted.png: colors, alpha, outline, edge")

  test "an unknown flag fails loud with exit 2, never silently ignored":
    let r = runArt(@["lint", fixturesDir, "--nonsense"])
    check r.code == 2
    check r.output.startsWith("error:")

  test "--profile and --full are not flags; the sidecar or style.toml decides the profile":
    check runArt(@["lint", fixturesDir, "--profile", "lowbit"]).code == 2
    check runArt(@["lint", fixturesDir, "--full"]).code == 2

  test "an explicit --style that doesn't exist is a usage error, not the builtin defaults":
    let r = runArt(@["lint", fixturesDir, "--style", fixturesDir / "stlye.toml"])
    check r.code == 2
    check r.output.startsWith("error:")
    check r.output.contains("stlye.toml")

  test "a style.toml palette fails off-palette colours on every profile and lists them":
    let dir = tempDirWith("art_cli_test_palette", ["gino", "bat"])
    writeFile(dir / "style.toml", "profile = \"hibit\" # the game's look\npalette = \"palette.hex\"\n")
    writeFile(dir / "palette.hex", "000000\nffffff\n")
    let r = runArt(@["lint", dir, "--style", dir / "style.toml"])
    check r.code == 1
    check r.output.contains("style: hibit (" & dir / "style.toml" & ")")
    check r.output.contains("palette: " & dir / "palette.hex" & " (2 colours, every asset)")
    check r.output.contains(",7149 px,23 off\n") # gino uses ffffff, not 000000
    check r.output.contains("off_palette: " & dir / "gino.png ")
    check r.output.contains("gino.png: palette, outline")
    # bat's sidecar names lowbit, not the style's hibit; the palette is
    # the game's, so it still applies.
    check r.output.contains("style: lowbit (builtin default)")
    check r.output.contains("off_palette: " & dir / "bat.png ")
    check r.output.contains("bat.png: palette, edge")
    check r.output.contains("lint: 2 of 2 failed")
    removeDir(dir)

  test "each sheet gets the nearest art/style.toml above it, up to the repo root":
    let outer = testTmp / "art_cli_test_discovery"
    let repo = outer / "repo"
    createDir(repo / ".git")
    createDir(outer / "art")
    writeFile(outer / "art" / "style.toml", "profile = \"bogus\"\n") # outside the repo
    createDir(repo / "art")
    writeFile(repo / "art" / "style.toml", "profile = \"lowbit\"\n")
    let game = tempDirWith("art_cli_test_discovery" / "repo" / "games" / "g" / "art", ["gino"])
    writeFile(game / "style.toml", "profile = \"hibit\"\npalette = \"palette.hex\"\n")
    writeFile(game / "palette.hex", "000000\nffffff\n")
    let other = tempDirWith("art_cli_test_discovery" / "repo" / "games" / "h" / "sprites", ["bat"])
    # Run from wherever the tests run, not from the game: discovery follows
    # the linted paths, not the working directory.
    let r = runArt(@["lint", game, other])
    check r.code == 1
    check r.output.contains("style: hibit (" & game / "style.toml" & ")")
    check r.output.contains("palette: " & game / "palette.hex")
    check r.output.contains("gino.png: palette")
    check r.output.contains("style: lowbit (" & repo / "art" / "style.toml" & ")")
    check r.output.contains("bat.png: edge")

    # A sheet with no art/style.toml inside its repo gets the builtin
    # defaults; the walk stops at the repo root instead of reaching the
    # bogus one outside it.
    let loose = tempDirWith("art_cli_test_discovery" / "repo" / "loose", ["zombie"])
    removeFile(repo / "art" / "style.toml")
    let bare = runArt(@["lint", loose])
    check bare.code == 1
    check bare.output.contains("style: hibit (builtin default)")
    check bare.output.contains("zombie.png: outline")

    # --style overrides discovery for every sheet.
    let forced = runArt(@["lint", game, "--style", outer / "art" / "style.toml"])
    check forced.code == 2
    check forced.output.contains("bogus")
    removeDir(outer)

  test "a sidecar and style.toml written with the old punchclub name still lint, as hibit":
    let dir = tempDirWith("art_cli_test_alias", ["zombie"])
    writeFile(dir / "zombie.art.toml", "cell_w = 64\ncell_h = 64\nprofile = \"punchclub\"\n")
    let bare = runArt(@["lint", dir])
    check bare.code == 1
    check bare.output.contains("style: hibit (builtin default)")
    check bare.output.contains("zombie.png: outline")
    writeFile(dir / "style.toml", "profile = \"punchclub\"\n")
    let styled = runArt(@["lint", dir, "--style", dir / "style.toml"])
    check styled.code == 1
    check styled.output.contains("style: hibit (" & dir / "style.toml" & ")")
    check styled.output.contains("zombie.png: outline")
    removeDir(dir)

  test "a malformed sidecar value is a usage error naming the file, not a crash":
    let dir = tempDirWith("art_cli_test_badsidecar", ["zombie"])
    writeFile(dir / "zombie.art.toml", "cell_w = 64px\ncell_h = 64\nprofile = \"hibit\"\n")
    let r = runArt(@["lint", dir])
    check r.code == 2
    check r.output.startsWith("error: " & dir / "zombie.art.toml")
    writeFile(dir / "zombie.art.toml", "cell_w = 64\ncell_h = 64\nprofile = \"lowbits\"\n")
    let unknown = runArt(@["lint", dir])
    check unknown.code == 2
    check unknown.output.startsWith("error: " & dir / "zombie.art.toml")
    check unknown.output.contains("lowbits")
    removeDir(dir)

  test "a path that doesn't exist is a usage error, exit 2":
    let r = runArt(@["lint", "/no/such/path/at/all"])
    check r.code == 2
    check r.output.startsWith("error:")

  test "an empty directory is a definitive empty state, not silent success":
    let dir = testTmp / "art_cli_test_empty"
    createDir(dir)
    let r = runArt(@["lint", dir])
    check r.code == 1
    check r.output.contains("sheets[0]{")
    check r.output.contains("lint: 0 assets found")
    removeDir(dir)

  test "--failing narrows the table to the assets that actually fail":
    let dir = tempDirWith("art_cli_test_failing", ["zombie", "koalio", "gino_attack"])
    waiveOutline(dir, ["zombie", "gino_attack"])
    let r = runArt(@["lint", dir, "--failing"])
    check r.code == 1
    check r.output.contains("sheets[2]{")
    check r.output.contains("koalio.png")
    check r.output.contains("gino_attack.png")
    check not r.output.contains("zombie.png")
    removeDir(dir)

  test "same-named sheets in different folders are told apart by their path":
    let a = tempDirWith("art_cli_test_samename" / "a", ["zombie"])
    waiveOutline(a, ["zombie"])
    let b = testTmp / "art_cli_test_samename" / "b"
    createDir(b)
    copyFile(fixturesDir / "bat.png", b / "zombie.png")
    copyFile(fixturesDir / "bat.art.toml", b / "zombie.art.toml")
    let r = runArt(@["lint", a, b])
    check r.code == 1
    check r.output.contains("  " & a / "zombie.png" & ",576x256,")
    check r.output.contains("  " & b / "zombie.png" & ",96x128,")
    check r.output.contains("  " & b / "zombie.png" & ": edge\n")
    check not r.output.contains(a / "zombie.png" & ": ")
    # A file argument prints exactly as given.
    let f = runArt(@["lint", b / "zombie.png"])
    check f.output.contains("  " & b / "zombie.png" & ": edge\n")
    removeDir(testTmp / "art_cli_test_samename")

  test "a passing set exits 0":
    let dir = tempDirWith("art_cli_test_passing", ["zombie", "ghost"])
    waiveOutline(dir, ["zombie", "ghost"])
    let r = runArt(@["lint", dir / "zombie.png", dir / "ghost.png"])
    check r.code == 0
    check r.output.contains("lint: 0 of 2 failed")
    check r.output.contains("waived: " & dir / "zombie.png outline - LPC art")
    removeDir(dir)

suite "para art lint: koalio's grid stays BAD with its waiver shown":
  test "linting koalio alone shows the BAD grid, the waiver and its unmeasured cell rules":
    let r = runArt(@["lint", fixturesDir / "koalio.png"])
    check r.code == 1
    check r.output.contains("  " & fixturesDir / "koalio.png,128x32,18x26,BAD,172,609,unmeasured,unmeasured,unmeasured,-\n")
    check r.output.contains("waived: " & fixturesDir / "koalio.png grid - hand-offset")
    check r.output.contains("koalio.png: cells unmeasured, colors, alpha")

suite "para art sheet: TOON shape and file output":
  test "builds a contact sheet PNG and lists every tile":
    let dir = testTmp / "art_cli_sheet_test"
    let outPath = dir / "sheet.png"
    let r = runArt(@["sheet", fixturesDir, "--out", outPath])
    check r.code == 0
    check r.output.contains("tiles[12]{file,x,y,w,h}:")
    check r.output.contains("wrote " & outPath)
    check fileExists(outPath)
    removeDir(dir)

  test "a non-numeric or non-positive --cols/--max-tile is a usage error, not a crash":
    let outPath = testTmp / "art_cli_sheet_badnum" / "sheet.png"
    for args in [@["--cols", "0"], @["--cols", "-1"], @["--cols", "abc"],
                 @["--max-tile", "-5"], @["--max-tile", "x"]]:
      let r = runArt(@["sheet", fixturesDir, "--out", outPath] & args)
      checkpoint $args
      check r.code == 2
      check r.output.startsWith("error:")
    check not fileExists(outPath)

removeDir(testTmp)
