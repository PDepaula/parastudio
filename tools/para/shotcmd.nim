# `para shot`: task 1.8's #1-ranked command (engine report §5.3) -- render a
# game's frames at named ticks, deterministically and in process, and with
# --check compare each against its committed golden. The game runs in a
# hidden GL window (`paraloop/app.openHeadlessWindow`, `--size WxH`) from a
# fresh start at `--seed N`, stepping to each frame's tick and capturing it
# with `paraloop/dev.captureScreenshot`, so the same tick always renders the
# same frame. With no `--script`/`--keys` no input is held; with one, its
# tick-indexed key events (`paraloop/input.parseScript`) are applied before
# each tick exactly as `app.run` would see them. Frames are named `title`
# (tick 0), `t<N>` (tick N) or `NAME=N` / `NAME=@Phase` (tick N, or the first
# tick the game is in that phase; a script file can predefine these with
# `frame NAME=SPEC` lines, see replayopts.nim); a frame lands in
# `tmp/frames/<game>_<name>.png`, its golden is `<game dir>/goldens/<name>.png`,
# and a changed frame also gets a `tmp/frames/<game>_<name>.diff.png` (changed
# pixels red over the dimmed golden). The §5.3 sample runs the future
# survivors game; hello is the game linked into para, and any other game with a
# tools/<name>_driver.nim runs through that program (gamedriver.nim,
# driverexec.nim). A live window's own frame is `para live shot`.
#
# `--fixtures DIR` is the other way to a frame, for a game whose driver offers it:
# each frame NAME is the state `DIR/NAME.fixture` states (a seed plus the facts
# the frame shows), written onto a fresh game and drawn without stepping a tick,
# so no play can move it. (A number the screen itself prints from a balance
# table -- a bar's need, max HP, a Market price -- still shows, and changing it
# changes the frame.) Every other flag a game adds (a title screen to start on,
# a saved profile) is its driver's: the run here never names a game.

import std/[options, os, osproc, strutils, strformat, sequtils, tables]
import paranim/glfw
import art/[clihelpers, toon]
import paraloop/app
import paraloop/input
import paraloop/dev
import stb_image/read as stbi
import stb_image/write as stbw
import games
import gamedriver
import driverexec
import linked
import replayopts

type
  Run = clihelpers.Run

  Image* = object
    w*, h*: int
    pixels*: seq[byte]

  Frame* = tuple[name: string, tick: int]
    ## `tick` is -1 for a phase-pinned frame until the render finds it.

  ShotMode* = enum
    smRender  ## render and list the frames
    smCheck   ## also compare each against its golden
    smUpdate  ## render and save each as its golden

  PhasePin* = tuple[name, phase: string]
    ## Frame `name` is the first tick the game is in `phase`.

  ShotOptions* = object
    ## What `para shot` adds to a bare render: the seed (the driver's `newGame(seed)`),
    ## the window (`size.width == 0`: `openHeadlessWindow`'s default), the
    ## input script, the phase-pinned frames and how long to look for them.
    seed*: int64
    size*: tuple[width, height: int]
    replay*: ReplayScript
    pins*: seq[PhasePin]
    maxTicks*: int
    tolerance*: int
      ## `--check` only: a pixel counts as changed only when some RGBA channel
      ## differs from the golden's by more than this (0: exact).
    maxDiffPx*: int
      ## `--check` only: a frame passes with up to this many changed pixels.
    title*: bool
      ## The run starts on the title screen (the driver's `onTitle`); shown in the render line.
    fixtures*: string
      ## `--fixtures DIR`: the frames are the fixtures in this directory
      ## (`NAME.fixture`), not a run from tick 0; empty for a run.
    flags*: string
      ## The flags that built these options (` --seed 7 --script x`), repeated
      ## in the commands `shoot` suggests so they reproduce the same frames.

proc renderLine(opts: ShotOptions): string =
  let (w, h) = if opts.size.width > 0: opts.size else: (1024, 768)
  (if opts.fixtures.len > 0: &"render: fixtures in {opts.fixtures}, window {w}x{h}"
   else: &"render: seed {opts.seed}, window {w}x{h}") &
    (if opts.title: ", from the title screen" else: "") &
    (if opts.replay.source.len > 0:
       &", script {opts.replay.source} ({opts.replay.script.events.len} key events)"
     else: "") & "\n"

const
  unresolvedTick* = -1
  defaultMaxTicks* = 36000
    ## 10 minutes of game time: how long a `@Phase` frame is searched for.

proc decodePng*(path: string): Image =
  var w, h, ch: int
  let pixels = stbi.load(path, w, h, ch, stbi.RGBA)
  Image(w: w, h: h, pixels: pixels)

proc channelsDiffer(a, b: openArray[byte], i, tolerance: int): bool =
  for c in 0 .. 3:
    if abs(a[i + c].int - b[i + c].int) > tolerance: return true

proc diffPixelCount*(a, b: Image, tolerance = 0): int =
  ## Number of RGBA pixels with some channel differing by more than
  ## `tolerance` (0: any difference), or -1 when the dimensions differ.
  if a.w != b.w or a.h != b.h: return -1
  var i = 0
  while i < a.pixels.len:
    if channelsDiffer(a.pixels, b.pixels, i, tolerance):
      inc result
    i += 4

proc writeDiffPng*(frame, golden: Image, path: string, tolerance = 0) =
  ## Same-size images only: pixels changed beyond `tolerance` in red, the rest
  ## the golden's pixel at a third of its brightness.
  var pixels = newSeq[byte](golden.pixels.len)
  var i = 0
  while i < pixels.len:
    if channelsDiffer(frame.pixels, golden.pixels, i, tolerance):
      pixels[i] = 255
    else:
      for c in 0 .. 2: pixels[i + c] = golden.pixels[i + c] div 3
    pixels[i + 3] = 255
    i += 4
  stbw.writePNG(path, golden.w, golden.h, 4, pixels)

proc parseFrames*(spec: string, frames: var seq[Frame], pins: var seq[PhasePin],
                  named: seq[NamedFrame] = @[]): Run =
  ## `title,t600,boss=@Tribulation,mid=900` -> `frames`
  ## `@[("title", 0), ("t600", 600), ("boss", -1), ("mid", 900)]` and `pins`
  ## `@[("boss", "Tribulation")]`; a bare name is looked up among `named` (a
  ## script file's `frame` lines). Code 0, or a usage error naming the first
  ## item that is none of these forms.
  frames.setLen 0
  pins.setLen 0
  for item in spec.split(','):
    var name = item
    var tickSpec = ""
    let eq = item.find('=')
    if eq >= 0:
      name = item[0 ..< eq]
      tickSpec = item[eq + 1 .. ^1]
    elif item == "title":
      tickSpec = "0"
    elif item.len > 1 and item[0] == 't' and item[1 .. ^1].allCharsInSet(Digits):
      tickSpec = item[1 .. ^1]
    else:
      for n in named:
        if n.name == item: tickSpec = n.spec
      if tickSpec.len == 0:
        return errorOut(&"unknown frame \"{item}\"",
          @["Frames are `title` (tick 0), `t<N>` (tick N), `NAME=N` or `NAME=@Phase`, comma-separated: --at title,t600,levelup=@LevelUp"] &
          (if named.len > 0: @["This script names: " & named.mapIt(it.name).join(", ")] else: @[]))
    if (eq >= 0 and not isFrameName(name)) or tickSpec.len == 0:
      return errorOut(&"bad frame \"{item}\"",
        @["A frame name is letters, digits, `_` and `-` (not `title` or `t<N>`): --at levelup=@LevelUp"])
    if frames.anyIt(it.name == name):
      return errorOut(&"frame \"{name}\" is listed twice", @[])
    if tickSpec.startsWith("@"):
      if tickSpec.len < 2 or not tickSpec[1 .. ^1].allCharsInSet(IdentChars):
        return errorOut(&"frame \"{item}\": bad phase \"{tickSpec}\"",
          @["A phase pin is `NAME=@Phase`, e.g. levelup=@LevelUp"])
      frames.add (name, unresolvedTick)
      pins.add (name, tickSpec[1 .. ^1])
    elif tickSpec.allCharsInSet(Digits):
      try:
        frames.add (name, tickSpec.parseInt)
      except ValueError:
        return errorOut(&"frame \"{item}\": tick out of range", @[])
    else:
      return errorOut(&"frame \"{item}\": \"{tickSpec}\" is neither a tick nor @Phase", @[])
  ("", 0)

proc parseFrames*(spec: string, frames: var seq[Frame]): Run =
  ## Fixed-tick frames only (`title`, `t<N>`, `NAME=N`): a phase pin is a
  ## usage error here, since there is nowhere to return it.
  var pins: seq[PhasePin]
  result = parseFrames(spec, frames, pins)
  if result.code == 0 and pins.len > 0:
    return errorOut(&"frame \"{pins[0].name}\" is pinned to a phase", @["Use the overload that takes pins"])

proc parseFixtureFrames*(dir, spec: string, fixtures: ShotFixtures, frames: var seq[Frame]): Run =
  ## `--fixtures DIR` with `--at`/`--update-golden` `spec`: `all` (or no spec) is every
  ## `NAME.fixture` in `dir`, else comma-separated frame names, each of which must have its
  ## fixture there. Ticks stay unresolved until the render reads each fixture's own.
  frames.setLen 0
  if not dirExists(dir):
    return errorOut(&"--fixtures: no directory {dir}", @[])
  let held = fixtures.names(dir)
  let names = if spec.len == 0 or spec == "all": held else: spec.split(',')
  if names.len == 0:
    return errorOut(&"--fixtures: no {fixtures.ext} files in {dir}", @[])
  for name in names:
    if not isFrameName(name):
      return errorOut(&"bad frame \"{name}\"",
        @["With --fixtures a frame is the name of a fixture (letters, digits, `_` and `-`), or `all`: --at sect,seclusion"])
    if name notin held:
      return errorOut(&"no fixture \"{name}\" in {dir}",
        @["The fixtures there: " & (if held.len > 0: held.join(", ") else: "none")])
    if frames.anyIt(it.name == name):
      return errorOut(&"frame \"{name}\" is listed twice", @[])
    frames.add (name, unresolvedTick)
  ("", 0)

proc framePath(game: Game, name: string): string =
  "tmp" / "frames" / (game.name & "_" & name & ".png")

proc goldenPath(game: Game, name: string): string =
  game.dir / "goldens" / (name & ".png")

template inShotWindow(opts: ShotOptions) {.dirty.} =
  ## Opens the hidden GL window `opts.size` asks for (an error `Run` returned from the enclosing
  ## proc when there is no display or the size is not what the display gives) and closes it when
  ## that proc ends.
  let (reqW, reqH) = if opts.size.width > 0: opts.size else: (1024, 768)
  let win = openHeadlessWindow(reqW, reqH)
  if win == nil:
    return errorOut("cannot open a hidden GL window (no display)",
      @["para shot renders through GLFW: run it where DISPLAY is set, or under xvfb-run"])
  defer:
    win.destroyWindow()
    glfwTerminate()
  let (fbW, fbH) = windowSize()
  if opts.size.width > 0 and (fbW, fbH) != opts.size:
    return errorOut(&"asked for a {reqW}x{reqH} window, got a {fbW}x{fbH} framebuffer",
      @["The display scales the window (HiDPI) or caps its size; the size is pinned only when they match"])

proc captureFrame(g: ShotGame, path, name: string): Run =
  ## Draws `g`'s current state and saves it to `path`.
  g.draw()
  let (w, h) = windowSize()
  if not tryRemoveFile(path) or not captureScreenshot(path, w, h) or not fileExists(path):
    return errorOut(&"could not capture frame \"{name}\" to {path}", @[])

proc renderFixtureFrames(frames: var seq[Frame], paths: seq[string], opts: ShotOptions,
                         fixtures: ShotFixtures): Run =
  ## `--fixtures`: each frame is the state of `opts.fixtures/<name>.fixture` on a fresh game (its own
  ## seed), drawn as it stands -- not one tick is stepped, so the frame is the same whichever frames
  ## are asked for and in whatever order. `frames[i].tick` is written back from the fixture.
  inShotWindow(opts)
  for i in 0 ..< frames.len:
    var loaded: tuple[game: ShotGame, tick: int]
    engineKeys = newKeyState()
    try:
      loaded = fixtures.load(opts.fixtures / (frames[i].name & fixtures.ext))
    except CatchableError:
      return errorOut(getCurrentExceptionMsg(), @[fixtures.formatHelp])
    loaded.game.init()
    frames[i].tick = loaded.tick
    let captured = captureFrame(loaded.game, paths[i], frames[i].name)
    if captured.code != 0:
      return captured
  ("", 0)

proc renderFramesFor(frames: var seq[Frame], paths: seq[string], opts: ShotOptions,
                     newGame: proc (seed: int64): ShotGame): Run =
  ## Runs `newGame(opts.seed)`'s game from tick 0 in a hidden window, capturing
  ## `frames[i]` to `paths[i]` as its tick is reached (a phase-pinned frame:
  ## the first tick the game's `phase` names its phase, which is then written back to
  ## `frames[i].tick`). The script's key events are applied before each tick,
  ## the way `app.run`'s window callback would deliver them.
  inShotWindow(opts)
  engineKeys = newKeyState()
  let replay = newReplay(opts.replay.script)
  let g = newGame(opts.seed)
  g.init()
  var pinOf = newSeq[string](frames.len)
  for pin in opts.pins:
    for i, f in frames:
      if f.name == pin.name: pinOf[i] = pin.phase
  var pending = toSeq(0 ..< frames.len)
  var phasesSeen: seq[string]
  var tick = 0
  while true:
    let phase = if g.phase.isNil: "" else: g.phase()
    if phase.len > 0 and phase notin phasesSeen: phasesSeen.add phase
    var still: seq[int]
    for idx in pending:
      if frames[idx].tick == tick or (pinOf[idx].len > 0 and pinOf[idx] == phase):
        frames[idx].tick = tick
        let captured = captureFrame(g, paths[idx], frames[idx].name)
        if captured.code != 0:
          return captured
      else:
        still.add idx
    pending = still
    if pending.len == 0: break
    for idx in pending:
      if pinOf[idx].len > 0 and tick >= opts.maxTicks:
        return errorOut(&"frame \"{frames[idx].name}\": phase {pinOf[idx]} not reached in {opts.maxTicks} ticks",
          @["Phases seen: " & (if phasesSeen.len > 0: phasesSeen.join(", ") else: "none (this game has no phases)"),
            "Raise the search with --max-ticks N, or fix the script's input"])
    inc tick
    input.step(replay, engineKeys, tick)
    g.stepTick(tick)
  ("", 0)

proc shoot*(game: Game, frameList: seq[Frame], mode: ShotMode, driver: ShotDriver,
            opts = ShotOptions(maxTicks: defaultMaxTicks)): Run =
  ## Renders `frameList` of `game` through `driver` under `opts` and,
  ## per `mode`, lists, checks or saves them as goldens.
  var frames = frameList
  let paths = frames.mapIt(framePath(game, it.name))
  let rendered =
    if opts.fixtures.len > 0 and driver.fixtures.isSome:
      renderFixtureFrames(frames, paths, opts, driver.fixtures.get)
    else:
      renderFramesFor(frames, paths, opts, driver.newGame)
  if rendered.code != 0:
    if mode == smCheck: recordStatus(game.name, "goldens", "check failed")
    return rendered

  # Phase-pinned frames are named by their resolved tick, so the suggested
  # commands pin them to it and reproduce without the phase search.
  proc atName(f: Frame): string =
    if opts.pins.anyIt(it.name == f.name): f.name & "=" & $f.tick else: f.name
  let atNames = frames.map(atName).join(",")
  case mode
  of smRender:
    result.output = toonTable("frames", ["name", "tick", "path"],
      toSeq(0 ..< frames.len).mapIt(@[frames[it].name, $frames[it].tick, paths[it]]))
    result.output.add renderLine(opts)
    result.output.add toonHelp(@[
      &"Run `para shot --game {game.name}{opts.flags} --at {atNames} --check` " &
        "to compare them against the goldens"])
  of smUpdate:
    for i, f in frames:
      createDir(goldenPath(game, f.name).parentDir)
      copyFile(paths[i], goldenPath(game, f.name))
    result.output = toonTable("frames", ["name", "tick", "path", "diff"],
      toSeq(0 ..< frames.len).mapIt(@[frames[it].name, $frames[it].tick, paths[it],
                                      "golden updated"]))
    result.output.add renderLine(opts)
  of smCheck:
    var rows: seq[seq[string]]
    var changed: seq[string]
    var changedAt: seq[string]
    var reads: seq[string]
    for i, f in frames:
      let golden = goldenPath(game, f.name)
      let diffPath = paths[i].changeFileExt("diff.png")
      discard tryRemoveFile(diffPath)
      var diff: string
      var changedFrame = true
      if not fileExists(golden):
        diff = "no golden"
        reads.add &"Read {paths[i]}"
      else:
        let a = decodePng(paths[i])
        let b = decodePng(golden)
        let n = diffPixelCount(a, b, opts.tolerance)
        if n < 0:
          diff = &"size differs {a.w}x{a.h} vs {b.w}x{b.h}"
          reads.add &"Read {paths[i]} and {golden}"
        elif n > opts.maxDiffPx:
          diff = &"{n} px changed"
          writeDiffPng(a, b, diffPath, opts.tolerance)
          reads.add &"Read {paths[i]} and {diffPath}"
        else:
          changedFrame = false
          let exact = diffPixelCount(a, b)
          diff = if exact == 0: "identical"
                 else: &"within tolerance ({exact} px differ, {n} beyond {opts.tolerance} per channel)"
      if changedFrame:
        changed.add f.name
        changedAt.add atName(f)
      rows.add @[f.name, $f.tick, paths[i], diff]
    result.output = toonTable("frames", ["name", "tick", "path", "diff"], rows)
    result.output.add &"changed: {changed.len} of {frames.len} frames\n"
    result.output.add renderLine(opts)
    recordStatus(game.name, "goldens", &"{changed.len} changed")
    if changed.len > 0:
      result.output.add toonHelp(reads & @[
        &"Run `para shot --game {game.name}{opts.flags} --update-golden {changedAt.join(\",\")}` if the change is intended"])
      result.code = 1

proc shotHelp*(driver: ShotDriver): string =
  "para shot [--game NAME] [--at FRAMES] [--check] [REPLAY]\n" &
  "para shot [--game NAME] --update-golden FRAMES [REPLAY]\n" &
  "  renders FRAMES (default title) headless from a fresh run: `title` = tick 0, `t<N>` = tick N,\n" &
  "  `NAME=N` = tick N, `NAME=@Phase` = the first tick the game is in that phase (a game that has\n" &
  "  phases names them in its own docs), comma-separated;\n" &
  "  --check diffs each against <game dir>/goldens/<name>.png, --update-golden saves them as the\n" &
  "  goldens. Games: hello (linked into para), and any game with a games/<name>/tools/<name>_driver.nim\n" &
  "  REPLAY pins the run so a frame is repeatable:\n" &
  "    --script FILE | --keys \"60:enter,300:right:15\"  tick-indexed input (paraloop/input's script\n" &
  "      grammar); a file may also hold `frame NAME=SPEC` lines (named frames, shot by default),\n" &
  "      `#` comments and one item list per line\n" &
  "    --seed N        the game's seed (default 0)\n" &
  driver.flags.flagHelp &
  "    --fixtures DIR  render states, not a run, for a game that has fixture files: frame NAME is\n" &
  "      DIR/NAME.fixture, drawn without stepping a tick. --at / --update-golden take fixture names or\n" &
  "      `all` (every fixture in DIR, the default); no --script/--keys/--seed/--max-ticks or game flag\n" &
  "      (the fixture holds its seed and screen)\n" &
  "    --size WxH      the window in pixels (default 1024x768); an error if the display won't give it\n" &
  "    --max-ticks N   how long to look for a @Phase frame (default 36000)\n" &
  "  --check is exact by default (one differing channel of one pixel is a change). Software GL\n" &
  "  rounds a blend or a clear colour one or two steps differently from one Mesa to the next, so a\n" &
  "  check that must hold across machines can allow for that:\n" &
  "    --tolerance N   a pixel is changed only if a channel differs by more than N (0..255, default 0)\n" &
  "    --max-diff-px N a frame passes with up to N changed pixels (default 0)\n"

proc runShotWith*(args: seq[string], driver: ShotDriver, ownGame = defaultGame): Run =
  ## `para shot` over `driver`'s game. A game's own binary (`driverMain`) calls this with the
  ## command line it was handed and its own name as `ownGame`, the game a `--game`-less command
  ## line runs.
  var gameName = ownGame
  var atSpec, updateSpec = ""
  var scriptFile, keysText = ""
  var opts = ShotOptions(maxTicks: defaultMaxTicks)
  var check = false
  var seedGiven = false
  var runFlags: seq[string] ## the flags that shape a run, which `--fixtures` has no use for
  var extras: Extras
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (shotHelp(driver), 0)
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      gameName = args[i]
    of "--at":
      inc i
      if i >= args.len: return errorOut("--at needs frame names, e.g. title,t600", @[])
      atSpec = args[i]
    of "--update-golden":
      inc i
      if i >= args.len: return errorOut("--update-golden needs frame names, e.g. t600", @[])
      updateSpec = args[i]
    of "--check":
      check = true
    of "--script":
      inc i
      if i >= args.len: return errorOut("--script needs a file", @[])
      scriptFile = args[i]
      runFlags.add "--script"
      opts.flags.add " --script " & quoteShell(args[i])
    of "--keys":
      inc i
      if i >= args.len: return errorOut("--keys needs a script, e.g. \"60:enter,300:right:15\"", @[])
      keysText = args[i]
      runFlags.add "--keys"
      opts.flags.add " --keys " & quoteShell(args[i])
    of "--seed":
      inc i
      if i >= args.len: return errorOut("--seed needs a number", @[])
      let bad = parseSeedFlag(args[i], opts.seed)
      if bad.code != 0: return bad
      seedGiven = true
      runFlags.add "--seed"
      opts.flags.add " --seed " & args[i]
    of "--tolerance", "--max-diff-px":
      inc i
      if i >= args.len: return errorOut(&"{a} needs a number", @[])
      var n = -1
      try:
        n = args[i].parseInt
      except ValueError:
        discard
      if n < 0 or (a == "--tolerance" and n > 255):
        return errorOut(&"{a} takes a whole number {(if a == \"--tolerance\": \"from 0 to 255\" else: \"of at least 0\")}, got \"{args[i]}\"", @[])
      if a == "--tolerance": opts.tolerance = n else: opts.maxDiffPx = n
    of "--fixtures":
      inc i
      if i >= args.len: return errorOut("--fixtures needs a directory", @[])
      opts.fixtures = args[i]
      opts.flags.add " --fixtures " & quoteShell(args[i])
    of "--size":
      inc i
      if i >= args.len: return errorOut("--size needs WIDTHxHEIGHT, e.g. 960x540", @[])
      let bad = parseSizeFlag(args[i], opts.size)
      if bad.code != 0: return bad
      opts.flags.add " --size " & args[i]
    of "--max-ticks":
      inc i
      if i >= args.len: return errorOut("--max-ticks needs a number", @[])
      try:
        opts.maxTicks = args[i].parseInt
      except ValueError:
        opts.maxTicks = 0
      if opts.maxTicks < 1:
        return errorOut(&"--max-ticks takes a whole number of at least 1, got \"{args[i]}\"", @[])
      runFlags.add "--max-ticks"
      opts.flags.add " --max-ticks " & args[i]
    else:
      var bad: Run
      let flag = a
      if driver.flags.takeExtra(args, i, extras, bad):
        if bad.code != 0: return bad
        runFlags.add flag
        opts.flags.add " " & flag & (if extras[flag].len > 0: " " & quoteShell(extras[flag]) else: "")
      else:
        return errorOut(&"unknown flag \"{a}\"",
          @["Valid flags: --game NAME, --at FRAMES, --check, --update-golden FRAMES, " &
            "--script FILE, --keys SCRIPT, --seed N, --fixtures DIR, --size WxH, --max-ticks N, --tolerance N, --max-diff-px N" &
            driver.flags.mapIt(", " & it.flag & (if it.arg.len > 0: " " & it.arg else: "")).join])
    inc i

  if (opts.tolerance > 0 or opts.maxDiffPx > 0) and not check:
    return errorOut("--tolerance and --max-diff-px loosen --check; pass --check too", @[])
  if updateSpec.len > 0 and (atSpec.len > 0 or check):
    return errorOut("--update-golden FRAMES renders and saves those frames; drop --at/--check", @[])

  var game: Game
  let notFound = resolveGame(gameName, game)
  if notFound.code != 0: return notFound
  if not driver.prepare.isNil:
    let bad = driver.prepare(extras)
    if bad.len > 0: return errorOut(bad, @[])
  if not seedGiven and not driver.defaultSeed.isNil:
    let implied = driver.defaultSeed()
    if implied.isSome: opts.seed = implied.get # (seed, profile, script) reproduces the saved run
  opts.title = not driver.onTitle.isNil and driver.onTitle()

  if opts.fixtures.len > 0:
    if runFlags.len > 0:
      return errorOut(&"{runFlags[0]} shapes a run, and --fixtures renders states, not runs",
        @["A fixture holds its own seed and screen; drop " & runFlags.join(", ")])
    if driver.fixtures.isNone:
      return errorOut(&"--fixtures renders a game's fixture files, and {game.name} has none", @[])
    var fixtureFrames: seq[Frame]
    let spec = if updateSpec.len > 0: updateSpec else: atSpec
    let badFixtures = parseFixtureFrames(opts.fixtures, spec, driver.fixtures.get, fixtureFrames)
    if badFixtures.code != 0: return badFixtures
    let mode = if updateSpec.len > 0: smUpdate elif check: smCheck else: smRender
    return shoot(game, fixtureFrames, mode, driver, opts)

  let badScript = loadReplayScript(scriptFile, keysText, opts.replay)
  if badScript.code != 0: return badScript

  var frames: seq[Frame]
  let spec =
    if updateSpec.len > 0: updateSpec
    elif atSpec.len > 0: atSpec
    elif opts.replay.frames.len > 0: opts.replay.frames.mapIt(it.name).join(",")
    else: "title"
  let badFrames = parseFrames(spec, frames, opts.pins, opts.replay.frames)
  if badFrames.code != 0: return badFrames
  if opts.pins.len > 0 and not driver.hasPhases:
    return errorOut(&"frame \"{opts.pins[0].name}\" is pinned to a phase, and {game.name} has no phases",
      @[&"Pin it to a tick instead: --at {opts.pins[0].name}=600"])

  let mode = if updateSpec.len > 0: smUpdate elif check: smCheck else: smRender
  shoot(game, frames, mode, driver, opts)

proc runShot*(args: seq[string]): Run =
  ## `para shot`: a linked game's driver renders in process; any other game that ships a
  ## driver program gets this command line (see driverexec.nim).
  let gameName = gameFlag(args)
  let linkedDriver = linkedShot(gameName)
  if linkedDriver.isSome:
    return runShotWith(args, linkedDriver.get)
  runGameDriver(gameName, "shot", args)
