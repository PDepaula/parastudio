# `para board`: visual boards, an optional way for the friend to review what the producer would
# otherwise describe in words (art options, picking a look, comparing screenshots, a plan with
# options). A board is one HTML page in games/<game>/review/, made from the shared template in
# .agents/skills/producer/board/ (the Studio Desk look, or the game's own palette), that the friend
# opens in their browser: they click choices, leave notes, press one button, and the answers come
# back to the producer.
#
# A live board runs on Lavish: `lavish-axi`, a free program (MIT licence) from the npm registry,
# https://www.npmjs.com/package/lavish-axi. It is never required and never installed by itself:
# `para board install` says what it would install, from where and into which folder, then asks a
# plain yes or no (the launchers' pattern), and only "y" or "yes" installs. It needs Node.js 22 or
# newer, which Studio itself does not. Without Lavish a board is still a page the friend opens on
# its own, whose button copies the picks for them to paste into the chat.
#
# Lavish runs a small web server on this computer. Left to itself it also listens on the computer's
# Tailscale address when Tailscale is running (its links then use the tailnet name, so a phone on
# the same tailnet can open them), it sends anonymous usage counts to its author's server, and its
# board menu can publish a copy on a public website (ht-ml.app). `para board` runs every Lavish
# command with `localEnv`: listening on 127.0.0.1 only (setting LAVISH_AXI_HOST turns the Tailscale
# listener off), usage counts off, publishing sent to a closed port on this computer so nothing can
# be uploaded, and a port and state folder of its own (tmp/lavish/) so it never reuses a server
# someone started with other settings. A board link that is not a loopback address is ended at once
# and reported (`isLocalUrl`). It never runs `lavish-axi share`, `update` or `setup`.
#
# Programs are parameters (`BoardTools`) so tests drive stand-ins; `root` is the paraloop checkout.

import std/[os, osproc, strutils, strtabs, streams, times, math, options, tables]
import art/[clihelpers, toon, profile]
import savepoint
import browser
import studiofonts
import agent
import preflight

type Run = clihelpers.Run

const
  lavishProgram* = "lavish-axi"
  lavishTested* = "0.1.92" ## the version these commands were checked with (2026-10-24)
  lavishPage* = "https://www.npmjs.com/package/lavish-axi"
  lavishInstallCommand* = "npm install -g " & lavishProgram & "@" & lavishTested
  nodeNeeded* = 22 ## Lavish's own `engines` field: node >=22
  boardInstallCommand* = "tmp/para board install"
  boardPort* = 4388 ## not Lavish's default (4387), so a server someone started by hand is never reused
  closedPort = "http://127.0.0.1:9" ## where Lavish's "publish" is sent: nothing listens there
  reviewDir* = "review"
  picturesDir* = "pictures"
  maxPictures = 24
  maxPictureBytes = 10_000_000
  maxTitle = 60
  openTimeoutMs = 60_000
  quickTimeoutMs = 20_000
  pictureExts = [".png", ".jpg", ".jpeg", ".gif", ".webp"]
  templateDir = ".." / ".." / ".agents" / "skills" / "producer" / "board"
  boardTemplate = staticRead(templateDir / "board.html")
  boardCss* = staticRead(templateDir / "board.css")
  pipSvg = staticRead(".." / "docs" / "theme" / "pip.svg")
  ## the Lavish settings `para board` always replaces, so a value set by hand cannot widen them
  droppedEnv = ["LAVISH_AXI_LINK_HOST", "LAVISH_AXI_ALLOWED_HOSTS", "LAVISH_AXI_HTML_APP_TOKEN",
                "LAVISH_AXI_UMAMI_HOST", "LAVISH_AXI_UMAMI_WEBSITE_ID", "LAVISH_AXI_IDLE_TIMEOUT_MS"]

const boardHelp* = "para board install\n" &
  "para board new TOPIC [--game NAME] [--title TEXT] [--replace]\n" &
  "para board open BOARD [--picture FILE]...\n" &
  "para board answers BOARD\n" &
  "para board end BOARD\n" &
  "para board stop\n" &
  "  visual boards: a page in the friend's browser where they click choices and leave notes, and the answers come back to the producer\n" &
  "  install  says what it would install (" & lavishProgram & " " & lavishTested & " from the npm registry, MIT licence, needs Node.js " & $nodeNeeded & "+), from where and into which folder, then asks y/n; only y or yes installs, never with admin rights\n" &
  "  new      writes games/<game>/review/TOPIC.html from the shared template (the Studio Desk look, or the game's own palette); edit only between BOARD CONTENT START and END\n" &
  "  open     copies each --picture (an image inside this folder, each with its own file name) to the board's pictures/ folder and opens the board: live with Lavish, else as a page whose button copies the picks\n" &
  "  answers  what the friend has sent from the board so far\n" &
  "  end      closes the board;  stop  stops Lavish (it also stops by itself once nothing is open, or after 30 idle minutes)\n" &
  "  BOARD is games/<game>/review/<topic>.html. Lavish runs on this computer only (127.0.0.1, port " & $boardPort & "), with its usage counts and its publishing switched off; a link that is not local is closed at once\n"

type
  BoardTools* = object
    lavish*: string ## lavish-axi's path; "" = not installed
    node*, npm*: string ## for `install`; "" = not found
    openBrowser*: proc (url: string): bool
    ask*: proc (question: string): bool ## a plain yes/no; false for anything but y or yes
    say*: proc (line: string) ## prints as it goes (the offer has to be shown before the question)

  BoardFile* = object
    rel*, game*, topic*: string ## `games/<game>/review/<topic>.html`, `/` separated

proc lavishExe*(): string = findExe(lavishProgram)

proc askOnStdin(question: string): bool =
  ## Yes only for "y" or "yes" typed here; Enter, anything else and a closed input are no.
  stdout.write("  " & question & " (y/n, Enter means no) ")
  stdout.flushFile()
  var answer = ""
  try:
    if not stdin.readLine(answer): return false
  except IOError, EOFError:
    return false
  answer.strip.toLowerAscii in ["y", "yes"]

proc sayOnStdout(line: string) =
  stdout.write(line & "\n")
  stdout.flushFile()

proc realTools*(): BoardTools =
  BoardTools(lavish: lavishExe(), node: findExe("node"), npm: findExe("npm"),
             openBrowser: openInBrowser, ask: askOnStdin, say: sayOnStdout)

# --- keeping Lavish on this computer --------------------------------------------------------

proc stateDir*(root: string): string = root / "tmp" / "lavish"

proc localEnv*(root: string, base: StringTableRef = nil): StringTableRef =
  ## This process's environment (or `base`) with Lavish held to this computer: see the top of
  ## this file. Every Lavish command `para board` runs gets exactly this.
  result = newStringTable(when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  if base.isNil:
    for k, v in envPairs(): result[k] = v
  else:
    for k, v in base: result[k] = v
  for k in droppedEnv: result.del(k)
  result["LAVISH_AXI_HOST"] = "127.0.0.1"
  result["LAVISH_AXI_PORT"] = $boardPort
  result["LAVISH_AXI_STATE_DIR"] = stateDir(root)
  result["LAVISH_AXI_TELEMETRY"] = "0"
  result["LAVISH_AXI_HTML_APP_API_URL"] = closedPort
  result["LAVISH_AXI_NO_OPEN"] = "1" # para board opens the link itself, once it has checked it

proc isLocalUrl*(url: string): bool =
  ## An http link to this computer only: 127.0.0.1, localhost or [::1]. A tailnet name, a LAN
  ## address, 0.0.0.0 or anything else is not.
  for host in ["127.0.0.1", "localhost", "[::1]"]:
    let head = "http://" & host
    if url.startsWith(head) and url.len > head.len and url[head.len] in {':', '/'}:
      return true
  false

type Drain = object
  stream: Stream
  output: string

proc drainMain(d: ptr Drain) {.thread.} =
  {.gcsafe.}:
    d.output = d.stream.readAll()

proc runLavish(t: BoardTools, root: string, args: seq[string], timeoutMs: int): tuple[output: string, code: int] =
  ## One Lavish command in `root` with `localEnv`, stopped after `timeoutMs`. Its output is read
  ## while it runs, so an answer longer than the pipe holds cannot stall it.
  var p: Process
  try:
    p = startProcess(t.lavish, workingDir = root, args = args, env = localEnv(root),
                     options = {poStdErrToStdOut})
  except OSError as e:
    return ("cannot run " & lavishProgram & ": " & e.msg & "\n", 127)
  let drain = createShared(Drain)
  drain.stream = p.outputStream
  var reader: Thread[ptr Drain]
  createThread(reader, drainMain, drain)
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while p.running and epochTime() < deadline:
    sleep(20)
  let timedOut = p.running
  if timedOut: p.kill()
  result.code = p.waitForExit()
  joinThread(reader)
  if timedOut:
    result = (lavishProgram & " did not answer within " & $(timeoutMs div 1000) & " seconds\n", 124)
  else:
    result.output = drain.output
  drain.stream = nil
  freeShared(drain)
  p.close()

proc field(output, name: string): string =
  ## The value of a top-level `name: value` line of Lavish's answer, without quotes.
  for raw in output.splitLines:
    let line = raw.strip
    if line.startsWith(name & ":"):
      return line[name.len + 1 .. ^1].strip.strip(chars = {'"'})

proc lavishVersion(t: BoardTools, root: string): string =
  let r = runLavish(t, root, @["--version"], 10_000) # --version is the one command that sends nothing anywhere even unconfigured
  if r.code == 0: r.output.strip.splitLines()[0].strip else: ""

# --- which file -------------------------------------------------------------------------------

proc validTopic*(topic: string): bool =
  topic.len in 1..40 and topic[0] in {'a'..'z'} and topic.allCharsInSet({'a'..'z', '0'..'9', '-', '_'})

proc boardFile*(root, arg: string, bf: var BoardFile): string =
  ## "" when `arg` names a board: `games/<game>/review/<topic>.html` (relative to the repo root,
  ## either slash), its game existing. Otherwise what is wrong.
  var p = arg.strip.replace('\\', '/')
  while p.startsWith("./"): p = p[2 .. ^1]
  let parts = p.split('/')
  if parts.len != 4 or parts[0] != gamesDir or parts[2] != reviewDir or not parts[3].endsWith(".html"):
    return "a board is games/<game>/review/<topic>.html, not \"" & arg & "\""
  let topic = parts[3][0 ..< ^5]
  if not validGameName(parts[1]) or not validTopic(topic):
    return "a board's game and topic are short lowercase names (letters, digits, - or _), not \"" & arg & "\""
  if not dirExists(gameDirOf(root, parts[1])):
    return "there is no game called \"" & parts[1] & "\" in " & gamesDir & "/"
  bf = BoardFile(rel: p, game: parts[1], topic: topic)
  ""

proc boardPathOf(root: string, bf: BoardFile): string = root / bf.rel

# --- the game's palette -------------------------------------------------------------------

proc channel(c, shift: int): float = ((c shr shift) and 0xFF).float / 255.0

proc luminance*(c: int): float =
  ## WCAG relative luminance of a packed 0xRRGGBB colour.
  proc lin(v: float): float = (if v <= 0.03928: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4))
  0.2126 * lin(channel(c, 16)) + 0.7152 * lin(channel(c, 8)) + 0.0722 * lin(channel(c, 0))

proc contrast*(a, b: int): float =
  let (x, y) = (luminance(a), luminance(b))
  (max(x, y) + 0.05) / (min(x, y) + 0.05)

proc saturation(c: int): float =
  let (r, g, b) = (channel(c, 16), channel(c, 8), channel(c, 0))
  max(r, max(g, b)) - min(r, min(g, b))

type GamePalette* = object
  source*: string ## the .hex file, relative to the game folder
  paper*, ink*, accent*, onAccent*, highlight*: int

proc pickRoles*(colours: seq[int]): Option[GamePalette] =
  ## The five board colours from a game's palette: the lightest is the paper, the darkest the ink,
  ## the most colourful one that still reads on the paper (3:1) the accent, with paper or ink on it
  ## (whichever reads better), and the most colourful light one the highlight. None for a palette
  ## of fewer than two colours, or one with no contrast to work with.
  if colours.len < 2: return
  var g: GamePalette
  g.paper = colours[0]
  g.ink = colours[0]
  for c in colours:
    if luminance(c) > luminance(g.paper): g.paper = c
    if luminance(c) < luminance(g.ink): g.ink = c
  if contrast(g.paper, g.ink) < 4.5: return
  g.accent = g.ink
  for c in colours:
    if c != g.paper and contrast(c, g.paper) >= 3.0 and saturation(c) > saturation(g.accent): g.accent = c
  g.onAccent = if contrast(g.paper, g.accent) >= contrast(g.ink, g.accent): g.paper else: g.ink
  g.highlight = g.accent
  for c in colours:
    if c != g.paper and luminance(c) >= 0.35 and saturation(c) > saturation(g.highlight): g.highlight = c
  some(g)

proc gamePalette*(root, game: string): Option[GamePalette] =
  ## The game's own colours: art/style.toml's `palette`, else the only .hex file in art/. None
  ## when the game has neither, or the file cannot be read (the board then uses the Studio's look).
  let art = gameDirOf(root, game) / "art"
  var file = ""
  var colours: seq[int]
  if fileExists(art / "style.toml"):
    try:
      let style = loadStyle(art / "style.toml")
      if style.palette.len > 0: (file, colours) = (style.palettePath, style.palette)
    except ProfileError:
      discard
  if colours.len == 0 and dirExists(art):
    var hexes: seq[string]
    for kind, p in walkDir(art):
      if kind == pcFile and p.toLowerAscii.endsWith(".hex"): hexes.add p
    if hexes.len == 1:
      try:
        for raw in readFile(hexes[0]).splitLines:
          let line = raw.strip.strip(chars = {'#'})
          if line.len == 0: continue
          if line.len != 6 or not line.allCharsInSet(HexDigits): colours = @[]; break
          colours.add parseHexInt(line)
        file = hexes[0]
      except IOError:
        colours = @[]
  result = pickRoles(colours)
  if result.isSome: result.get.source = file.relativePath(gameDirOf(root, game)).replace('\\', '/')

proc hexOf(c: int): string = "#" & toHex(c, 6)

proc paletteCss*(g: GamePalette): string =
  "/* The game's own palette (" & g.source & "), so the board looks like the game. `para board new` picked\n" &
  "   these five from it; if one reads wrong, change only these lines. */\n" &
  ":root { --game-paper: " & hexOf(g.paper) & "; --game-ink: " & hexOf(g.ink) & "; --game-accent: " & hexOf(g.accent) &
  "; --game-on-accent: " & hexOf(g.onAccent) & "; --game-highlight: " & hexOf(g.highlight) & "; }\n"

# --- writing a board ------------------------------------------------------------------------

proc escapeHtml(s: string): string =
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#39;"
    else:
      if c >= ' ' and c != '\x7f': result.add c

proc boardHtml*(game, topic, title: string, palette: Option[GamePalette]): string =
  ## The template with its parts filled in: one file holding the fonts, the stylesheet and Pip.
  var style = fontFaces & boardCss
  if palette.isSome: style.add "\n" & paletteCss(palette.get)
  boardTemplate.multiReplace(
    ("{{style}}", style.strip),
    ("{{palette-attr}}", if palette.isSome: " data-palette=\"game\"" else: ""),
    ("{{pip}}", pipSvg.strip),
    ("{{title}}", escapeHtml(title)),
    ("{{game}}", escapeHtml(game)),
    ("{{topic}}", topic))

proc titleOf(topic: string): string =
  result = topic.replace('-', ' ').replace('_', ' ')
  if result.len > 0: result[0] = result[0].toUpperAscii

proc runNew(root: string, args: seq[string]): Run =
  var topic, requested, title = ""
  var replace = false
  var i = 0
  while i < args.len:
    case args[i]
    of "--game":
      inc i
      if i >= args.len: return errorOut("--game needs a name", @[])
      requested = args[i]
    of "--title":
      inc i
      if i >= args.len: return errorOut("--title needs the board's title", @[])
      title = args[i].strip
    of "--replace": replace = true
    else:
      if args[i].startsWith("-"):
        return errorOut("unknown flag \"" & args[i] & "\"", @["Valid flags: --game NAME, --title TEXT, --replace"])
      if topic.len > 0: return errorOut("para board new takes one TOPIC", @[])
      topic = args[i]
    inc i
  if not validTopic(topic):
    return errorOut("a board's topic is a short lowercase name (letters, digits, - or _), starting with a letter",
      @["For example: tmp/para board new ship-look --game mygame"])
  var game: string
  let picked = pickGame(root, requested, game)
  if picked.code != 0: return picked
  if title.len == 0: title = titleOf(topic)
  if title.len > maxTitle: title = title[0 ..< maxTitle].strip
  let bf = BoardFile(rel: gamesDir & "/" & game & "/" & reviewDir & "/" & topic & ".html", game: game, topic: topic)
  let path = boardPathOf(root, bf)
  if fileExists(path) and not replace:
    return ("error: " & bf.rel & " already exists\n" &
      toonHelp(@["Edit it, pick another topic, or add --replace to start it over from the template"]), 1)
  let palette = gamePalette(root, game)
  try:
    createDir(path.parentDir)
    writeFile(path, boardHtml(game, topic, title, palette))
  except IOError, OSError:
    return ("error: could not write " & bf.rel & ": " & getCurrentExceptionMsg() & "\n", 1)
  result.output = "board: " & bf.rel & "\n" &
    "look: " & (if palette.isSome: "the game's own palette (" & palette.get.source & ")" else: "the Studio Desk look") & "\n" &
    toonHelp(@["Edit only what is between BOARD CONTENT START and BOARD CONTENT END: one <section class=\"question\"> per question, options as in the example",
               "Pictures go in with: tmp/para board open " & bf.rel & " --picture FILE (then <img src=\"pictures/FILE-NAME\">)"])

# --- opening it ---------------------------------------------------------------------------

proc copyPictures(root: string, bf: BoardFile, files: seq[string], copied: var seq[string]): string =
  ## Copies each picture into the board's own pictures/ folder (a board can only show what sits
  ## next to it). Only an image file inside this folder, each under a name of its own: two files
  ## with one name, or a name the board already has with other content, are refused before anything
  ## is copied. "" when all went, else what is wrong.
  if files.len == 0: return ""
  let realRoot = try: expandFilename(root) except OSError: root
  let dest = boardPathOf(root, bf).parentDir / picturesDir
  var taken = initTable[string, string]() # destination name -> the --picture that wants it
  var plan: seq[(string, string)] # source, destination name
  for f in files:
    let src = if f.isAbsolute: f else: root / f
    let ext = src.splitFile.ext.toLowerAscii
    if ext notin pictureExts:
      return "\"" & f & "\" is not a picture (" & pictureExts.join(", ") & ")"
    if not fileExists(src) or symlinkExists(src):
      return "there is no picture file \"" & f & "\""
    let real = try: expandFilename(src) except OSError: ""
    if real.len == 0 or not real.isRelativeTo(realRoot):
      return "\"" & f & "\" is outside this folder; a board only shows pictures from inside it"
    if getFileSize(real) > maxPictureBytes:
      return "\"" & f & "\" is bigger than " & $(maxPictureBytes div 1_000_000) & " MB"
    var name = ""
    for c in src.extractFilename:
      name.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '.', '-', '_'}: c else: '-')
    let key = name.toLowerAscii
    if key in taken:
      return "\"" & taken[key] & "\" and \"" & f & "\" would both be " & picturesDir & "/" & name & " (names are compared without capitals, as some computers do); give one of the files another name"
    taken[key] = f
    try:
      if dirExists(dest):
        for kind, existing in walkDir(dest):
          if kind == pcFile and existing.extractFilename.toLowerAscii == key and readFile(existing) != readFile(real):
            return picturesDir & "/" & existing.extractFilename & " is already on this board with other content, so \"" & f & "\" would replace it; give the file another name"
    except IOError, OSError:
      return "could not read \"" & f & "\": " & getCurrentExceptionMsg()
    plan.add (real, name)
  for (real, name) in plan:
    try:
      createDir(dest)
      copyFile(real, dest / name)
    except IOError, OSError:
      return "could not copy \"" & name & "\": " & getCurrentExceptionMsg()
    copied.add picturesDir & "/" & name
  ""

proc fileUrl(path: string): string =
  var p = path.replace('\\', '/')
  if not p.startsWith("/"): p = "/" & p
  "file://" & p.replace(" ", "%20")

proc endQuietly(t: BoardTools, root: string, bf: BoardFile) =
  discard runLavish(t, root, @["end", bf.rel], quickTimeoutMs)

proc runOpen(t: BoardTools, root: string, args: seq[string]): Run =
  var target = ""
  var pictures: seq[string]
  var i = 0
  while i < args.len:
    case args[i]
    of "--picture":
      inc i
      if i >= args.len: return errorOut("--picture needs a file", @[])
      pictures.add args[i]
    else:
      if args[i].startsWith("-"): return errorOut("unknown flag \"" & args[i] & "\"", @["Valid flags: --picture FILE"])
      if target.len > 0: return errorOut("para board open takes one BOARD", @[])
      target = args[i]
    inc i
  if pictures.len > maxPictures: return errorOut("at most " & $maxPictures & " pictures on one board", @[])
  var bf: BoardFile
  let bad = boardFile(root, target, bf)
  if bad.len > 0: return errorOut(bad, @["Make one with: tmp/para board new TOPIC --game NAME"])
  if not fileExists(boardPathOf(root, bf)):
    return errorOut("there is no board " & bf.rel, @["Make it with: tmp/para board new " & bf.topic & " --game " & bf.game])
  var copied: seq[string]
  let notCopied = copyPictures(root, bf, pictures, copied)
  if notCopied.len > 0: return ("error: " & notCopied & "\nnothing was opened\n", 1)
  result.output = "board: " & bf.rel & "\n"
  if copied.len > 0: result.output.add "pictures: " & copied.join(", ") & "\n"

  if t.lavish.len == 0:
    let opened = not t.openBrowser.isNil and t.openBrowser(fileUrl(expandFilename(boardPathOf(root, bf))))
    result.output.add "mode: a page on its own (Lavish is not installed)\n" &
      "opened: " & (if opened: "yes, in the friend's browser" else: "no: ask the friend to double-click " & bf.rel) & "\n" &
      "next_step: \"Tell the friend the board is open: pick, then press Copy my picks and paste the line into the chat. " &
      "In the studio, the screenshots in the chat work as well. Lavish (a live board that sends the picks back by itself) is optional: " &
      "the friend can add it with " & boardInstallCommand & ", which asks first.\"\n"
    return
  let r = runLavish(t, root, @[bf.rel], openTimeoutMs)
  let url = field(r.output, "url")
  if r.code != 0 or url.len == 0:
    result.output.add "error: Lavish could not open the board\n" & r.output.strip & "\n"
    result.code = 1
    return
  if not isLocalUrl(url):
    t.endQuietly(root, bf)
    return ("error: Lavish gave a link that is not on this computer only, so the board was closed again and nothing was opened\n" &
      toonHelp(@["Run `tmp/para board stop`, then open it again; if it happens again, use the board as a page on its own"]), 1)
  let opened = not t.openBrowser.isNil and t.openBrowser(url)
  result.output.add "mode: live (Lavish " & field(r.output, "status") & ", only on this computer)\n" &
    "url: " & url & "\n" &
    "opened: " & (if opened: "yes, in the friend's browser" else: "no: give the friend the url above to open") & "\n" &
    "next_step: \"Tell the friend the board is open in their browser: click the choices, add a note if they want, " &
    "then press the button at the bottom, and tell you here when they have. Then run: tmp/para board answers " & bf.rel & "\"\n"

# --- answers, end ------------------------------------------------------------------

proc nextStepFor(status: string, bf: BoardFile): string =
  case status
  of "feedback":
    "Read every prompt above: the \"board picks (" & bf.topic & ")\" line is the answers (question=pick), any other line is a note the friend left on the board. " &
    "Record the picks in CHOICES.md, then close the board with: tmp/para board end " & bf.rel
  of "waiting":
    "Nothing sent yet: the friend has not pressed the button on the board. Ask them to, or carry on in the chat and run this again when they say they have."
  of "ended":
    "The friend closed the board. Do not open it again unless they ask; carry on in the chat."
  of "browser_disconnected":
    "The board's tab was closed before anything was sent. Ask the friend whether to open it again (tmp/para board open " & bf.rel & ") or carry on in the chat."
  else:
    "Lavish answered something para board does not know; read it above, and carry on in the chat if it is unclear."

proc boardArg(root: string, args: seq[string], bf: var BoardFile): string =
  ## The one BOARD argument of answers/end (flags already taken out).
  if args.len != 1: return "this needs one BOARD (games/<game>/review/<topic>.html)"
  result = boardFile(root, args[0], bf)
  if result.len == 0 and not fileExists(boardPathOf(root, bf)): result = "there is no board " & bf.rel

proc lavishNeeded(): Run =
  ("error: Lavish is not installed, so there is no live board to ask\n" &
   toonHelp(@["Without Lavish the friend copies the picks from the board and pastes them into the chat",
              "To add Lavish (optional), the friend runs " & boardInstallCommand & " in a terminal; it asks first"]), 1)

proc runAnswers(t: BoardTools, root: string, args: seq[string]): Run =
  for a in args:
    if a.startsWith("-"): return errorOut("unknown flag \"" & a & "\"", @[])
  var bf: BoardFile
  let bad = boardArg(root, args, bf)
  if bad.len > 0: return errorOut(bad, @[])
  if t.lavish.len == 0: return lavishNeeded()
  let r = runLavish(t, root, @["poll", bf.rel, "--timeout-ms", "2000"], 2000 + quickTimeoutMs)
  if r.code != 0:
    return ("error: Lavish could not read the board's answers\n" & r.output.strip & "\n", 1)
  # Lavish's own next step names its own commands, and its page outline only repeats the board:
  # para board's next step replaces both
  for line in r.output.strip.splitLines:
    if not line.startsWith("next_step:") and not line.startsWith("dom_snapshot:"): result.output.add line & "\n"
  result.output.add "next_step: " & toonCell(nextStepFor(field(r.output, "status"), bf)) & "\n"

proc runEnd(t: BoardTools, root: string, args: seq[string]): Run =
  for a in args:
    if a.startsWith("-"): return errorOut("unknown flag \"" & a & "\"", @[])
  var bf: BoardFile
  let bad = boardArg(root, args, bf)
  if bad.len > 0: return errorOut(bad, @[])
  if t.lavish.len == 0: return ("board: " & bf.rel & "\nended: there was no live board (Lavish is not installed)\n", 0)
  let r = runLavish(t, root, @["end", bf.rel], quickTimeoutMs)
  if r.code != 0: return ("error: Lavish could not close the board\n" & r.output.strip & "\n", 1)
  ("board: " & bf.rel & "\nended: yes (Lavish stops by itself once nothing is open, or after 30 idle minutes; tmp/para board stop stops it now)\n", 0)

proc runStop(t: BoardTools, root: string): Run =
  if t.lavish.len == 0: return ("lavish: not installed, so not running\n", 0)
  let r = runLavish(t, root, @["stop"], quickTimeoutMs)
  if r.code != 0: return ("error: Lavish did not stop\n" & r.output.strip & "\n", 1)
  ("lavish: stopped\n", 0)

# --- the startup row and install -------------------------------------------------------------------

const
  whatItIs* = "optional: a board for reviewing things visually, where the friend clicks choices and leaves notes, and the answers come back to the producer"
  howItRuns* = "only on this computer (127.0.0.1, port " & $boardPort & "), with its usage counts and its publishing switched off"

proc boardCheck*(lavish = lavishExe()): PreflightCheck =
  ## The optional row of the startup checks (the Studio page, `para studio --check`): never a
  ## failure, never in the "ready" count. Only looks the program up; runs nothing.
  if lavish.len > 0:
    passed("boards", "Lavish is installed (optional: visual boards)")
  else:
    failed("boards", "Lavish (visual boards)",
      "Optional, not installed. Lavish is a board for reviewing things visually: you click choices and leave notes, and it comes back to the producer. Without it the producer uses the studio's screenshots.",
      "To add it, run in a terminal in this folder: " & boardInstallCommand & "  (it says what it installs and from where, and asks first)")

proc nodeMajor*(versionText: string): int =
  ## 26 from "v26.2.0"; 0 when it is not a version.
  var t = versionText.strip
  if t.startsWith("v"): t = t[1 .. ^1]
  let major = t.split('.')[0]
  if major.len in 1..3 and major.allCharsInSet(Digits): parseInt(major) else: 0

proc canWrite*(dir: string): bool =
  ## Whether this user can make a file in `dir` (tried, then removed).
  if not dirExists(dir): return false
  let probe = dir / (".para-write-test-" & $getCurrentProcessId())
  try:
    writeFile(probe, "")
    removeFile(probe)
    true
  except IOError, OSError:
    false

proc npmFolder(prefix: string): string =
  ## Where `npm install -g` writes: <prefix>/lib/node_modules on macOS and Linux, the prefix on Windows.
  when defined(windows): prefix
  else: (if dirExists(prefix / "lib"): prefix / "lib" else: prefix)

proc runInstall(t: BoardTools, root: string): Run =
  if t.lavish.len > 0:
    let v = lavishVersion(t, root)
    return ("lavish: already installed (" & (if v.len > 0: lavishProgram & " " & v else: lavishProgram) & "); nothing to do\n", 0)
  proc stop(why, what: string): Run =
    ("lavish: not installed, and nothing was installed\n" & "why: " & why & "\n" &
     toonHelp(@[what, "Lavish is optional: boards work without it, as pages the friend copies the picks from"]), 1)
  if t.node.len == 0 or t.npm.len == 0:
    return stop("Lavish needs Node.js " & $nodeNeeded & " or newer (with npm), and it is not installed on this computer",
                "Install Node.js " & $nodeNeeded & " or newer from https://nodejs.org (the LTS download), then run " & boardInstallCommand & " again")
  let nv = execCmdEx(quoteShell(t.node) & " --version")
  let major = nodeMajor(nv.output)
  if major < nodeNeeded:
    return stop("Lavish needs Node.js " & $nodeNeeded & " or newer; this computer has " & (if major > 0: nv.output.strip else: "a version I could not read"),
                "Update Node.js from https://nodejs.org, then run " & boardInstallCommand & " again")
  let pr = execCmdEx(quoteShell(t.npm) & " prefix -g")
  let prefix = pr.output.strip.splitLines()[^1].strip
  if pr.exitCode != 0 or prefix.len == 0:
    return stop("npm did not say where it installs programs", "Run " & lavishInstallCommand & " yourself if you want Lavish")
  let into = npmFolder(prefix)
  if not canWrite(into):
    return stop("npm installs programs into " & into & ", which needs admin rights on this computer, and para board never uses them",
                "If you want Lavish anyway, run " & lavishInstallCommand & " yourself (it may ask for your password), or set npm up with a folder of your own first")
  var say = t.say
  if say.isNil: say = proc (line: string) = discard
  say("Lavish (visual boards) is not installed. It is " & whatItIs & ".")
  say("I can install it with npm:")
  say("  What:    " & lavishProgram & " " & lavishTested & ", a free program by Kun Chen (MIT licence), about 15 MB with what it needs")
  say("  From:    the npm registry, " & lavishPage & " (no account, no sign-in)")
  say("  Into:    " & into & " (your own npm folder, no admin rights)")
  say("  Needs:   Node.js " & $nodeNeeded & " or newer (this computer has " & nv.output.strip & ")")
  say("  Command: " & lavishInstallCommand)
  say("  When the studio runs it, it stays " & howItRuns & ".")
  if t.ask.isNil or not t.ask("Install Lavish now?"):
    return ("lavish: not installed. Okay, nothing was installed and nothing changed\n" &
      toonHelp(@["Boards still work as pages the friend copies the picks from; run " & boardInstallCommand & " again any time"]), 0)
  say("Installing, this takes about half a minute...")
  let r = execCmdEx(quoteShell(t.npm) & " install -g --no-fund --no-audit " & lavishProgram & "@" & lavishTested)
  if r.exitCode != 0:
    return ("lavish: the install stopped without finishing\n" & r.output.strip.splitLines[^min(8, r.output.strip.splitLines.len) .. ^1].join("\n") & "\n" &
      toonHelp(@["Nothing else changed; Lavish stays optional"]), 1)
  let found = lavishExe()
  if found.len == 0:
    return ("lavish: installed into " & into & ", but this terminal cannot find " & lavishProgram & " yet\n" &
      toonHelp(@["Open a new terminal (and restart the studio) so it is found"]), 0)
  ("lavish: installed (" & lavishProgram & " " & lavishTested & ")\n" &
   toonHelp(@["Restart the studio (or the producer's session) so it sees Lavish"]), 0)

# --- the command ------------------------------------------------------------------------

proc findCheckout(start: string): string =
  var dir = start
  while dir.len > 0:
    if fileExists(dir / "paraloop.nimble"): return dir
    let parent = dir.parentDir
    if parent == dir: break
    dir = parent

proc runBoardWith*(args: seq[string], t: BoardTools, root = ""): Run =
  if args.len > 0 and args[0] in ["--help", "-h"]: return (boardHelp, 0)
  let repo = if root.len > 0: root else: findCheckout(getCurrentDir())
  if repo.len == 0:
    return errorOut("this is not a paraloop folder", @["Run `para board` from inside the paraloop folder (the one with paraloop.nimble)"])
  if args.len == 0: return (boardHelp, 0)
  let sub = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]
  if rest.len > 0 and rest[0] in ["--help", "-h"]: return (boardHelp, 0)
  case sub
  of "install":
    if rest.len > 0: return errorOut("para board install takes no arguments", @[])
    runInstall(t, repo)
  of "new": runNew(repo, rest)
  of "open": runOpen(t, repo, rest)
  of "answers": runAnswers(t, repo, rest)
  of "end": runEnd(t, repo, rest)
  of "stop":
    if rest.len > 0: return errorOut("para board stop takes no arguments", @[])
    runStop(t, repo)
  else:
    errorOut("unknown command \"board " & sub & "\"",
      @["Valid commands: board install, board new, board open, board answers, board end, board stop"])

proc runBoard*(args: seq[string]): Run =
  runBoardWith(args, realTools())
