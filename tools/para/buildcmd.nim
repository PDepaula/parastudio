# `para build`: replaces `nimble build`/raw `nim c` flag lore (engine report
# §5.3 rank 5) with one command, structured compiler errors, and a
# `--full` escape hatch for the whole instantiation chain.

import std/[os, strformat, sequtils]
import art/[clihelpers, toon]
import nimutil
import games
import webbuild
import savepoint

type Run = clihelpers.Run

const buildHelp = "para build [--game NAME] [--lane ID] [--target native|web] [--release | --debug] [--define NAME[=VALUE]]...\n" &
  "                [--title TEXT] [--feedback-url URL] [--full]\n" &
  "  compiles examples/<game>/<game>.nim or games/<game>/<game>.nim; --target web needs emcc and node\n" &
  "  native: a debug build unless --release. web: a release build (the one that ships) unless --debug;\n" &
  "    --define passes -d:NAME[:VALUE] to nim (repeatable; a game reads it with defined(NAME));\n" &
  "    it also renders the shell, so tmp/web/<game>/ holds index.html + <game>.js + <game>.wasm + manifest,\n" &
  "    icons and build.json, with a build id (short commit, mode and defines: no timestamp) stamped into\n" &
  "    the page; --title sets the page title (default \"paraloop <game>\"); --feedback-url adds a\n" &
  "    \"Send feedback\" link to that http(s) URL (the build id appended as ?build=). `para web pack` zips it\n" &
  "  --lane ID: build a helper's lane of the game (games/<game>.<id>/, `para lane`) instead, natively, into\n" &
  "    tmp/lanes/<game>.<id>/ (its own compile cache too, so it never slows the game's own build)\n"

proc runBuild*(args: seq[string]): Run =
  var gameName = "hello"
  var target = "native"
  var release = false
  var debug = false
  var full = false
  var defines: seq[string]
  var title = ""
  var feedbackUrl = ""
  var lane = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (buildHelp, 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      gameName = args[i]
    of "--target":
      inc i
      if i >= args.len: return errorOut("--target needs \"native\" or \"web\"", @[])
      target = args[i]
      if target notin ["native", "web"]:
        return errorOut(&"unknown target \"{target}\"", @["Valid targets: native, web"])
    of "--release":
      release = true
    of "--debug":
      debug = true
    of "--define":
      inc i
      if i >= args.len: return errorOut("--define needs NAME or NAME=VALUE", @[])
      if not isValidDefine(args[i]):
        return errorOut(&"bad --define \"{args[i]}\"", @["A define is NAME or NAME=VALUE, e.g. --define startRoom=Glade"])
      defines.add args[i]
    of "--title":
      inc i
      if i >= args.len: return errorOut("--title needs the page title", @[])
      title = args[i]
    of "--feedback-url":
      inc i
      if i >= args.len: return errorOut("--feedback-url needs a URL", @[])
      feedbackUrl = args[i]
    of "--full":
      full = true
    of "--lane":
      inc i
      if i >= args.len: return errorOut("--lane needs the lane id", @[])
      lane = args[i]
    else:
      return errorOut(&"unknown flag \"{a}\"",
        @["Valid flags: --game NAME, --lane ID, --target native|web, --release, --debug, --define NAME[=VALUE], --title TEXT, --feedback-url URL, --full"])
    inc i

  if release and debug:
    return errorOut("--release and --debug are opposites", @["Drop one of them"])
  if debug and target == "native":
    return errorOut("--debug applies to --target web only",
      @["A native build is a debug build unless --release is given"])
  if title.len > 0 and target == "native":
    return errorOut("--title applies to --target web only", @[])
  if feedbackUrl.len > 0 and target == "native":
    return errorOut("--feedback-url applies to --target web only", @[])
  if defines.len > 0 and target == "native":
    return errorOut("--define applies to --target web only",
      @["For a native build with a define, run `nim c -d:NAME ...` directly"])
  var game: Game
  var outDir = "tmp"
  if lane.len > 0:
    if target != "native" or release:
      return errorOut("--lane builds a native debug build only", @["Land the lane first for any other build"])
    if not validLaneId(lane) or not validGameName(gameName) or
       not fileExists(laneDir("", gameName, lane) / (gameName & ".nim")):
      return errorOut(&"{gameName} has no lane called \"{lane}\"", @["List them with `para lane list --game " & gameName & "`"])
    game = (gameName, laneDir("", gameName, lane))
    outDir = "tmp" / "lanes" / laneName(gameName, lane)
  else:
    let notFound = resolveGame(gameName, game)
    if notFound.code != 0: return notFound
  let src = game.source

  var outPath: string
  var res: ProcResult
  if target == "web":
    let built = buildWeb(game, debug, defines, if title.len > 0: title else: "paraloop " & gameName,
                         feedbackUrl)
    if built.ok:
      result.output = &"build: ok, {built.describe}\n"
      if full: result.output.add "\nfull output:\n" & built.output
      return
    if built.failedStep == "postbuild":
      result.output = "error: web postbuild failed\n" & lastLines(built.output, 20)
      result.code = 1
      return
    res = ProcResult(output: built.output, exitCode: 1)
  else:
    createDir(outDir)
    outPath = outDir / gameName
    var nimArgs = @["c", "--hints:off"]
    if release: nimArgs.add "-d:release"
    nimArgs.add @["--outdir:" & outDir, src]
    res = runCaptured("nim", nimArgs)

  if res.exitCode == 0:
    let sizeInfo = if fileExists(outPath): &", {getFileSize(outPath)} bytes" else: ""
    result.output = &"build: ok, wrote {outPath}{sizeInfo}\n"
    result.code = 0
  else:
    let diags = parseNimDiagnostics(res.output).filterIt(it.severity == "Error")
    if diags.len > 0:
      result.output = &"error: build failed ({diags.len} error{(if diags.len == 1: \"\" else: \"s\")})\n"
      result.output.add toonTable("errors", ["at", "msg"], diags.mapIt(@[it.at, it.msg]))
    else:
      result.output = "error: build failed (no parseable compiler diagnostics)\n"
      result.output.add lastLines(res.output, 20)
    result.output.add toonHelp(@[
      &"Run `para build --target {target} --game {gameName}" & (if lane.len > 0: " --lane " & lane else: "") &
        " --full` to see the whole compiler output"])
    result.code = 1

  if full:
    result.output.add "\nfull output:\n" & res.output
