# `para web smoke`: wraps task 1.7's build -> postbuild -> CDP smoke driver
# (engine report §5.3 rank 6) as one command with a TOON checks table instead
# of the driver's own plain `ok`/`fail` lines, and records the outcome as the
# game's `web` status, pass or fail (judged by real exit codes throughout --
# `node`'s and `nim`'s, never a nimble task's, which nimble 0.22.2 always
# reports as 0; AGENTS.md).

import std/[strutils, strformat, sequtils]
import art/[clihelpers, toon]
import nimutil
import games
import webbuild

type Run = clihelpers.Run

proc isSummaryTail(rest: string): bool =
  ## `smoke.mjs`'s final line reads `N ok, M failed` after a `fail  ` prefix
  ## -- the same prefix a failing check's own line uses, so this is how the
  ## two are told apart.
  let parts = rest.split(", ")
  if parts.len != 2: return false
  let a = parts[0].split(' ')
  let b = parts[1].split(' ')
  a.len == 2 and b.len == 2 and a[0].len > 0 and a[0].allCharsInSet(Digits) and a[1] == "ok" and
    b[0].len > 0 and b[0].allCharsInSet(Digits) and b[1] == "failed"

proc parseSmokeOutput*(output: string): tuple[rows: seq[seq[string]], summary: string, allOk: bool] =
  ## `tools/web/smoke.mjs`'s own output: `page  <url>`, then `ok  <name>` /
  ## `fail  <name>` per check (each optionally followed by indented detail
  ## lines), then a final `pass  N/M checks` or `fail  N ok, M failed` line.
  let lines = output.splitLines
  type Entry = tuple[idx: int, status, text: string]
  var entries: seq[Entry]
  var summaryLine = ""
  for idx, rawLine in lines:
    if rawLine.startsWith("ok  "):
      entries.add (idx, "ok", rawLine["ok  ".len .. ^1])
    elif rawLine.startsWith("fail  "):
      let rest = rawLine["fail  ".len .. ^1]
      if isSummaryTail(rest): summaryLine = rawLine
      else: entries.add (idx, "fail", rest)
    elif rawLine.startsWith("pass  "):
      summaryLine = rawLine

  var rows: seq[seq[string]]
  for k, e in entries:
    let nextIdx = if k + 1 < entries.len: entries[k + 1].idx else: lines.len
    var detail: seq[string]
    for j in e.idx + 1 ..< nextIdx:
      if lines[j].startsWith("    "): detail.add lines[j].strip
    rows.add @[e.text, e.status, detail.join(" ")]

  (rows, summaryLine.strip, summaryLine.startsWith("pass"))

const webSmokeHelp* = "para web smoke [--game NAME] [--debug] [--define NAME[=VALUE]]... [--enter]\n" &
  "               [--click X,Y] [--ticks N] [--max-texture-units N] [--chrome PATH] [--sound] [--full]\n" &
  "  builds the wasm target (a release build, the one that ships, unless --debug; --define as in\n" &
  "  `para build`), postbuilds the shell, and drives it headlessly over CDP (needs emcc, node, a chromium)\n" &
  "  fails on any WebGL warning; the page sees a device with N combined texture units (default 32, WebGL2's guarantee)\n" &
  "  --enter taps Enter before the ArrowRight hold, for a game whose title screen ignores the arrows (an\n" &
  "    explicit flag, never auto-detected)\n" &
  "  --click X,Y posts a real left click at that viewport pixel after the ticks and requires the canvas to get it\n" &
  "    and the engine's pointer exports to be up (the browser-to-engine path only, not that the game acted;\n" &
  "    e.g. --define startRoom=Glade --enter --click 480,300)\n" &
  "  e.g. para web smoke --game hello --enter\n" &
  "  --sound adds the sound checks (off by default): the audio context unlocks on a real key press and a sound plays;\n" &
  "    the driver holds ArrowRight, so the game under test must beep on it (hello does)\n"

proc smokeSteps(game: Game, debug: bool, defines: seq[string], enter: bool, click, ticks, textureUnits,
                chrome: string, sound, full: bool): Run =
  ## build.sh -> postbuild.mjs -> smoke.mjs for `game`, stopping at the
  ## first step that fails.
  let built = buildWeb(game, debug, defines, "paraloop " & game.name)
  if not built.ok:
    result.output = &"error: web {built.failedStep} failed\n"
    result.output.add lastLines(built.output, 20)
    result.output.add toonHelp(@[
      "Run `para web smoke --full` to see the whole log",
      &"Run `para build --target web --game {game.name}` on its own"])
    result.code = 1
    if full: result.output.add "\nfull output:\n" & built.output
    return

  var smokeArgs = @["tools/web/smoke.mjs", "--dir", built.dir, "--game", game.name]
  if enter: smokeArgs.add "--enter"
  if click.len > 0: smokeArgs.add @["--click", click]
  if ticks.len > 0: smokeArgs.add @["--ticks", ticks]
  if textureUnits.len > 0: smokeArgs.add @["--max-texture-units", textureUnits]
  if chrome.len > 0: smokeArgs.add @["--chrome", chrome]
  if sound: smokeArgs.add "--sound"
  let smoke = runCaptured("node", smokeArgs)

  let (rows, summary, allOk) = parseSmokeOutput(smoke.output)
  if rows.len == 0:
    result.output = "error: `node tools/web/smoke.mjs` produced no parseable checks\n"
    result.output.add lastLines(smoke.output, 20)
    result.output.add toonHelp(@["Run `para web smoke --full` to see the whole output"])
    result.code = 1
  else:
    result.output.add &"build: {built.id}, {built.wasmBytes} bytes of wasm\n"
    result.output.add toonTable("checks", ["name", "status", "detail"], rows)
    if summary.len > 0: result.output.add summary & "\n"
    if allOk and smoke.exitCode == 0:
      result.code = 0
    else:
      result.output.add toonHelp(@["Run `para web smoke --full` to see the raw driver output"])
      result.code = 1

  if full:
    result.output.add "\nfull output:\n" & smoke.output

proc runWebSmoke*(args: seq[string]): Run =
  var gameName = "hello"
  var debug = false
  var defines: seq[string]
  var enter = false
  var click = ""
  var ticks = ""
  var textureUnits = ""
  var chrome = ""
  var sound = false
  var full = false
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (webSmokeHelp, 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      gameName = args[i]
    of "--debug":
      debug = true
    of "--define":
      inc i
      if i >= args.len: return errorOut("--define needs NAME or NAME=VALUE", @[])
      if not isValidDefine(args[i]):
        return errorOut(&"bad --define \"{args[i]}\"", @["A define is NAME or NAME=VALUE, e.g. --define startRoom=Glade"])
      defines.add args[i]
    of "--enter":
      enter = true
    of "--click":
      inc i
      if i >= args.len: return errorOut("--click needs X,Y", @[])
      let xy = args[i].split(',')
      if xy.len != 2 or not xy.allIt(it.len > 0 and it.allCharsInSet(Digits)):
        return errorOut(&"bad --click \"{args[i]}\"", @["A click is X,Y in whole viewport pixels, e.g. --click 480,300"])
      click = args[i]
    of "--ticks":
      inc i
      if i >= args.len: return errorOut("--ticks needs a number", @[])
      ticks = args[i]
    of "--max-texture-units":
      inc i
      if i >= args.len: return errorOut("--max-texture-units needs a number", @[])
      textureUnits = args[i]
    of "--chrome":
      inc i
      if i >= args.len: return errorOut("--chrome needs a path", @[])
      chrome = args[i]
    of "--sound":
      sound = true
    of "--full":
      full = true
    else:
      return errorOut(&"unknown flag \"{a}\"",
        @["Valid flags: --game NAME, --debug, --define NAME[=VALUE], --enter, --click X,Y, --ticks N, --max-texture-units N, --chrome PATH, --sound, --full"])
    inc i

  var game: Game
  let notFound = resolveGame(gameName, game)
  if notFound.code != 0: return notFound

  result = smokeSteps(game, debug, defines, enter, click, ticks, textureUnits, chrome, sound, full)
  recordStatus(game.name, "web", (if result.code == 0: "smoke ok " else: "smoke failed ") & today())

