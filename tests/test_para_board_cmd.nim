# Tests for `para board` (tools/para/boardcmd.nim), the optional visual boards:
#
# - Lavish is held to this computer: every Lavish command runs with `localEnv` (127.0.0.1, its own
#   port and state folder, usage counts off, publishing sent to a closed local port), and a board
#   link that is not a loopback address is closed again and never printed or opened;
# - `board new` writes one self-contained page from the shared template: the Studio Desk tokens
#   (checked here against the Studio page and the documentation site), the fonts as data: URIs,
#   Pip, nothing from anywhere else; the game's own palette when it has one;
# - `board open` copies pictures from inside the folder only, and without Lavish opens the page on
#   its own; `answers`, `reply` and `end` talk to Lavish only through `localEnv`;
# - `board install` never installs without a "yes": it says what, from where and into which folder,
#   and refuses when Node.js is missing or too old or the npm folder needs admin rights;
# - the optional startup-check row and the hook's line.
#
# Lavish, node and npm are this test program started again (PARA_FAKE_LAVISH=1 / PARA_FAKE_NODE=1),
# which logs its arguments and the Lavish settings it was given to FAKE_LAVISH_LOG. The real
# lavish-axi is run by hand in the PR's checklist, not here.

import std/[unittest, os, strutils, strtabs, tempfiles, base64, options, json, sequtils]
import studio_support
import tools/para/boardcmd
import tools/para/agent
import tools/para/producercmd

const repoRoot = currentSourcePath.parentDir.parentDir

proc fakeLog(line: string) =
  let f = getEnv("FAKE_LAVISH_LOG")
  if f.len > 0:
    let h = open(f, fmAppend)
    h.writeLine(line)
    h.close()

proc fakeLavishMain() =
  let args = commandLineParams()
  fakeLog("args: " & args.join(" "))
  var env: seq[string]
  for k in ["LAVISH_AXI_HOST", "LAVISH_AXI_PORT", "LAVISH_AXI_STATE_DIR", "LAVISH_AXI_TELEMETRY",
            "LAVISH_AXI_HTML_APP_API_URL", "LAVISH_AXI_NO_OPEN", "LAVISH_AXI_LINK_HOST", "LAVISH_AXI_ALLOWED_HOSTS"]:
    env.add k & "=" & getEnv(k, "<unset>")
  fakeLog("env: " & env.join(";"))
  let cmd = if args.len > 0: args[0] else: ""
  case cmd
  of "--version": echo "0.1.92"
  of "poll":
    if getEnv("FAKE_LAVISH_POLL") == "feedback":
      echo "session:\n  file: /x/look.html\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n" &
        "  \"1\",\"board picks (look): look=B (note: more red)\",button#send,board-picks,\"board picks (look): look=B (note: more red)\"\n" &
        "dom_snapshot: \"uid=1 body\"\nnext_step: \"Run `lavish-axi poll /x/look.html --agent-reply` ...\""
    else:
      echo "session:\n  file: /x/look.html\n  status: waiting\nnext_step: \"Run `lavish-axi poll /x/look.html` without --timeout-ms\""
  of "reply":
    let i = args.find("--agent-reply-file")
    fakeLog("reply-text: " & (if i >= 0: readFile(args[i + 1]).strip else: "<none>"))
    echo "reply:\n  status: accepted"
  of "end": echo "session:\n  status: ended"
  of "stop": echo "server:\n  status: stopped"
  else:
    echo "session:\n  file: /x/look.html\n  url: \"" & getEnv("FAKE_LAVISH_URL", "http://127.0.0.1:4388/session/abc123") &
      "\"\n  status: opened\nnext_step: \"Now you must run `lavish-axi poll`\""

proc fakeNodeMain() =
  ## node and npm: `--version`, `prefix -g` and `install ...`.
  let args = commandLineParams()
  fakeLog("node-npm: " & args.join(" "))
  if args == @["--version"]: echo getEnv("FAKE_NODE_VERSION", "v26.2.0")
  elif args.len >= 1 and args[0] == "prefix": echo getEnv("FAKE_NPM_PREFIX")
  elif args.len >= 1 and args[0] == "install": quit(parseInt(getEnv("FAKE_NPM_EXIT", "0")))
  else: quit(1)

when isMainModule:
  if getEnv("PARA_FAKE_NODE") == "1": # node and npm are asked before any Lavish command
    fakeNodeMain()
    quit(0)
  if getEnv("PARA_FAKE_LAVISH") == "1":
    fakeLavishMain()
    quit(0)

proc logLines(path: string): seq[string] =
  if fileExists(path): readFile(path).strip.splitLines else: @[]

type Scratch = object
  root, log: string
  opened: seq[string]

proc scratch(games: varargs[string]): ref Scratch =
  new(result)
  result.root = newGameRepo(games)
  result.log = result.root / "tmp" / "fake.log"
  createDir(result.root / "tmp")
  putEnv("PARA_FAKE_LAVISH", "1")
  putEnv("FAKE_LAVISH_LOG", result.log)

proc done(s: ref Scratch) =
  for k in ["PARA_FAKE_LAVISH", "PARA_FAKE_NODE", "FAKE_LAVISH_LOG", "FAKE_LAVISH_POLL", "FAKE_LAVISH_URL",
            "FAKE_NODE_VERSION", "FAKE_NPM_PREFIX", "FAKE_NPM_EXIT"]:
    delEnv(k)
  removeDir(s.root)

proc tools(s: ref Scratch, lavish = true, node = "", npm = "", answer = false, said: ref seq[string] = nil): BoardTools =
  let sc = s
  BoardTools(lavish: (if lavish: getAppFilename() else: ""), node: node, npm: npm,
             openBrowser: proc (url: string): bool = sc.opened.add url; true,
             ask: proc (q: string): bool = answer,
             say: proc (line: string) = (if not said.isNil: said[].add line))

proc board(s: ref Scratch, args: varargs[string]): tuple[output: string, code: int] =
  runBoardWith(@args, s.tools(true), s.root)

proc boardWithout(s: ref Scratch, args: varargs[string]): tuple[output: string, code: int] =
  ## As `board`, on a computer without Lavish.
  runBoardWith(@args, s.tools(false), s.root)

# --- keeping Lavish on this computer ------------------------------------------------------

suite "board: Lavish stays on this computer":
  test "localEnv: loopback, its own port and state folder, no usage counts, publishing to a closed local port":
    let base = newStringTable({"PATH": "/bin", "LAVISH_AXI_LINK_HOST": "box.tail1234.ts.net",
                               "LAVISH_AXI_ALLOWED_HOSTS": "*", "LAVISH_AXI_HOST": "0.0.0.0",
                               "LAVISH_AXI_HTML_APP_TOKEN": "secret", "LAVISH_AXI_TELEMETRY": "1"})
    let e = localEnv("/r", base)
    check e["LAVISH_AXI_HOST"] == "127.0.0.1"
    check e["LAVISH_AXI_PORT"] == $boardPort and boardPort != 4387
    check e["LAVISH_AXI_STATE_DIR"] == "/r" / "tmp" / "lavish"
    check e["LAVISH_AXI_TELEMETRY"] == "0"
    check e["LAVISH_AXI_HTML_APP_API_URL"].startsWith("http://127.0.0.1:")
    check e["LAVISH_AXI_NO_OPEN"] == "1"
    check e["PATH"] == "/bin"
    for k in ["LAVISH_AXI_LINK_HOST", "LAVISH_AXI_ALLOWED_HOSTS", "LAVISH_AXI_HTML_APP_TOKEN"]:
      check not e.hasKey(k)

  test "only a loopback link counts as local":
    for url in ["http://127.0.0.1:4388/session/a", "http://localhost:4388/session/a", "http://[::1]:4388/session/a"]:
      check isLocalUrl(url)
    for url in ["http://omarchy.tail1234.ts.net:4388/session/a", "http://100.89.1.2:4388/session/a",
                "http://192.168.1.20:4388/session/a", "http://0.0.0.0:4388/session/a", "https://ht-ml.app/x",
                "http://127.0.0.1.evil.example:4388/", "http://localhost.evil.example/", "", "127.0.0.1:4388"]:
      check not isLocalUrl(url)

  test "every Lavish command gets localEnv, and none is share, update or setup":
    let s = scratch("pong")
    defer: s.done()
    check s.board("new", "look", "--game", "pong").code == 0
    check s.board("open", "games/pong/review/look.html").code == 0
    check s.board("answers", "games/pong/review/look.html").code == 0
    check s.board("reply", "games/pong/review/look.html", "-m", "thanks").code == 0
    check s.board("end", "games/pong/review/look.html").code == 0
    check s.board("stop").code == 0
    check s.board("status").code == 0
    let lines = logLines(s.log)
    let envs = lines.filterIt(it.startsWith("env: "))
    check envs.len == 6 # open, answers, reply, end, stop and status's --version; `new` runs nothing
    for e in envs:
      check "LAVISH_AXI_HOST=127.0.0.1" in e and ("LAVISH_AXI_PORT=" & $boardPort) in e
      check "LAVISH_AXI_TELEMETRY=0" in e and "LAVISH_AXI_HTML_APP_API_URL=http://127.0.0.1:9" in e
      check ("LAVISH_AXI_STATE_DIR=" & s.root / "tmp" / "lavish") in e
      check "LAVISH_AXI_LINK_HOST=<unset>" in e and "LAVISH_AXI_ALLOWED_HOSTS=<unset>" in e
    for l in lines.filterIt(it.startsWith("args: ")):
      for word in ["share", "update", "setup", "export"]:
        check word notin l["args: ".len .. ^1].splitWhitespace
    for word in ["share", "update", "setup", "export"]:
      check s.board(word).code == 2

  test "a link that is not on this computer is closed again, never opened or printed":
    let s = scratch("pong")
    defer: s.done()
    check s.board("new", "look", "--game", "pong").code == 0
    putEnv("FAKE_LAVISH_URL", "http://omarchy.tail1234.ts.net:4388/session/abc123")
    let r = s.board("open", "games/pong/review/look.html")
    check r.code == 1
    check "not on this computer only" in r.output
    check "ts.net" notin r.output and "session/abc123" notin r.output
    check s.opened.len == 0
    check logLines(s.log).anyIt(it == "args: end games/pong/review/look.html")

  test "the words the friend and the producer see say local only, and never name another address":
    check "127.0.0.1" in boardHelp and "only on this computer" in howItRuns
    for text in [boardHelp, howItRuns, whatItIs, boardsLine, noBoardsLine]:
      for bad in ["0.0.0.0", "ts.net", "tailnet", "LAN", "ht-ml.app"]:
        check bad notin text
    # the producer may run the board commands without asking, but never install or Lavish itself
    let allow = parseJson(readFile(repoRoot / ".claude" / "settings.json"))["permissions"]["allow"].mapIt(it.getStr)
    check "Bash(tmp/para board open *)" in allow and "Bash(tmp/para board answers *)" in allow
    for rule in allow:
      check "lavish" notin rule and "board install" notin rule and "npm" notin rule

# --- the board file -----------------------------------------------------------------------

proc tokens(css, selector: string): seq[(string, string)] =
  ## The `--name: value` pairs of the first block opened by `selector {`.
  let start = css.find(selector & " {")
  doAssert start >= 0, "no " & selector
  let body = css[css.find('{', start) + 1 ..< css.find('}', start)]
  for part in body.split(';'):
    let p = part.strip
    if p.startsWith("--"):
      let colon = p.find(':')
      result.add (p[0 ..< colon].strip, p[colon + 1 .. ^1].strip)

suite "board: the template and the Studio Desk look":
  test "board.css carries the Studio page's tokens, light and dark, value for value":
    let studio = readFile(repoRoot / "tools" / "para" / "studio" / "index.html")
    let site = readFile(repoRoot / "tools" / "docs" / "theme" / "site.css")
    for selector in [":root", ":root:not([data-theme=\"light\"])", ":root[data-theme=\"dark\"]"]:
      let mine = tokens(boardCss, selector)
      check mine.len >= 15
      check mine == tokens(studio, selector)
      # the documentation site shares them too (it adds --code-bg and leaves out the status colours)
      for (k, v) in tokens(site, selector):
        for (k2, v2) in mine:
          if k == k2: check v == v2

  test "a new board is one file: fonts inside, the stylesheet, Pip, nothing from anywhere else":
    let s = scratch("pong")
    defer: s.done()
    let r = s.board("new", "ship-look", "--game", "pong", "--title", "Pick a <look> & go")
    check r.code == 0
    check "board: games/pong/review/ship-look.html" in r.output and "the Studio Desk look" in r.output
    let html = readFile(s.root / "games/pong/review/ship-look.html")
    for f in ["nunito-latin-400-normal", "nunito-latin-700-normal", "nunito-latin-800-normal", "fredoka-latin-600-normal"]:
      check ("data:font/woff2;base64," & encode(readFile(repoRoot / "tools/para/studio/fonts" / (f & ".woff2")))) in html
    check boardCss.strip in html
    check readFile(repoRoot / "tools/docs/theme/pip.svg").strip in html
    check "{{" notin html and "}}" notin html
    check "Pick a &lt;look&gt; &amp; go" in html and "<look>" notin html
    check "<html lang=\"en\" data-lavish-annotate=\"off\" data-board=\"ship-look\">" in html # no game palette
    check "BOARD CONTENT START" in html and "BOARD CONTENT END" in html
    for bad in ["http://", "https://", "<link", "<script src", "@import", "url(http", "url(//"]:
      check bad notin html
    check "window.lavish.queuePrompt" in html and "navigator.clipboard" in html

  test "a board is not overwritten unless asked; topics and games are checked":
    let s = scratch("pong")
    defer: s.done()
    check s.board("new", "look", "--game", "pong").code == 0
    writeFile(s.root / "games/pong/review/look.html", "edited")
    check s.board("new", "look", "--game", "pong").code == 1
    check readFile(s.root / "games/pong/review/look.html") == "edited"
    check s.board("new", "look", "--game", "pong", "--replace").code == 0
    check readFile(s.root / "games/pong/review/look.html") != "edited"
    check s.board("new", "Look", "--game", "pong").code == 2
    check s.board("new", "../x", "--game", "pong").code == 2
    check s.board("new", "look", "--game", "nope").code == 2
    check s.board("new", "other").code == 0 # the only game with a PLAN.md

  test "which paths are boards":
    let s = scratch("pong")
    defer: s.done()
    var bf: BoardFile
    check boardFile(s.root, "games/pong/review/look.html", bf) == "" and bf.game == "pong" and bf.topic == "look"
    check boardFile(s.root, "./games\\pong\\review\\look.html", bf) == ""
    for bad in ["games/pong/look.html", "games/pong/review/../../x.html", "games/../review/look.html",
                "games/pong/review/look.htm", "/etc/review/look.html", "games/nope/review/look.html",
                "games/pong/review/Look.html", "tmp/look.html"]:
      check boardFile(s.root, bad, bf).len > 0

suite "board: the game's own palette":
  test "pickRoles: paper and ink with real contrast, an accent that reads on the paper":
    let g = pickRoles(@[0x1a1c2c, 0x5d275d, 0xb13e53, 0xef7d57, 0xffcd75, 0xa7f070, 0x38b764, 0x257179,
                        0x29366f, 0x3b5dc9, 0x41a6f6, 0x73eff7, 0xf4f4f4, 0x94b0c2, 0x566c86, 0x333c57]).get
    check g.paper == 0xf4f4f4 and g.ink == 0x1a1c2c
    check contrast(g.accent, g.paper) >= 3.0
    check contrast(g.onAccent, g.accent) >= 3.0
    check pickRoles(@[0x123456]).isNone
    check pickRoles(@[]).isNone
    check pickRoles(@[0x808080, 0x858585]).isNone # no contrast to work with

  test "style.toml's palette, else the one .hex in art/, else the Studio look":
    let s = scratch("pong")
    defer: s.done()
    s.root.put("games/pong/art/style.toml", "profile = \"lowbit\"\npalette = \"pal.hex\"\n")
    s.root.put("games/pong/art/pal.hex", "000000\nffffff\nff0000\n")
    let r = s.board("new", "look", "--game", "pong")
    check "the game's own palette (art/pal.hex)" in r.output
    let html = readFile(s.root / "games/pong/review/look.html")
    check "data-palette=\"game\"" in html
    check "--game-paper: #FFFFFF; --game-ink: #000000; --game-accent: #FF0000;" in html
    removeFile(s.root / "games/pong/art/style.toml")
    s.root.put("games/pong/art/other.hex", "#112233\n#eeeeee\n")
    check "the Studio Desk look" in s.board("new", "two", "--game", "pong").output # two .hex files: which one is not clear
    removeFile(s.root / "games/pong/art/pal.hex")
    check "(art/other.hex)" in s.board("new", "one", "--game", "pong").output
    s.root.put("games/pong/art/other.hex", "not a colour\n")
    check "the Studio Desk look" in s.board("new", "bad", "--game", "pong").output

# --- opening, answers, reply, end ---------------------------------------------------------

suite "board: opening one and reading the answers":
  test "open: pictures from inside the folder are copied next to the board, then the local link is opened":
    let s = scratch("pong")
    defer: s.done()
    check s.board("new", "look", "--game", "pong").code == 0
    s.root.put("games/pong/art/raw/ship a.png", "\x89PNG\r\n\x1a\nfake")
    s.root.put("tmp/studio/shots/shot-1.png", "\x89PNG\r\n\x1a\nfake")
    let r = s.board("open", "games/pong/review/look.html", "--picture", "games/pong/art/raw/ship a.png",
                    "--picture", "tmp/studio/shots/shot-1.png")
    check r.code == 0
    check "pictures: pictures/ship-a.png, pictures/shot-1.png" in r.output
    check fileExists(s.root / "games/pong/review/pictures/ship-a.png")
    check "url: http://127.0.0.1:4388/session/abc123" in r.output and "only on this computer" in r.output
    check s.opened == @["http://127.0.0.1:4388/session/abc123"]
    check "lavish-axi poll" notin r.output and "tmp/para board answers games/pong/review/look.html" in r.output
    check logLines(s.log).anyIt(it == "args: games/pong/review/look.html")

  test "open: a picture outside the folder, not a picture, or missing is refused and nothing opens":
    let s = scratch("pong")
    defer: s.done()
    check s.board("new", "look", "--game", "pong").code == 0
    let outside = createTempDir("para_board_out_", "")
    defer: removeDir(outside)
    outside.put("x.png", "png")
    s.root.put("games/pong/notes.txt", "text")
    for bad in [outside / "x.png", "games/pong/notes.txt", "games/pong/none.png", "../x.png"]:
      let r = s.board("open", "games/pong/review/look.html", "--picture", bad)
      check r.code == 1 and "nothing was opened" in r.output
    check s.opened.len == 0
    check not fileExists(s.log)
    check s.board("open", "games/pong/review/none.html").code == 2

  test "open without Lavish: the board opens as a page on its own, and the install is only mentioned":
    let s = scratch("pong")
    defer: s.done()
    check s.board("new", "look", "--game", "pong").code == 0
    let r = s.boardWithout("open", "games/pong/review/look.html")
    check r.code == 0
    check "a page on its own" in r.output and "Copy my picks" in r.output and boardInstallCommand in r.output
    check s.opened.len == 1 and s.opened[0].startsWith("file://") and s.opened[0].endsWith("/games/pong/review/look.html")
    check s.boardWithout("answers", "games/pong/review/look.html").code == 1
    check not fileExists(s.log)

  test "answers: the friend's picks, with para board's own next step in place of Lavish's":
    let s = scratch("pong")
    defer: s.done()
    check s.board("new", "look", "--game", "pong").code == 0
    putEnv("FAKE_LAVISH_POLL", "feedback")
    let r = s.board("answers", "games/pong/review/look.html")
    check r.code == 0
    check "board picks (look): look=B (note: more red)" in r.output
    check "CHOICES.md" in r.output and "tmp/para board reply games/pong/review/look.html" in r.output
    check "lavish-axi" notin r.output and "dom_snapshot" notin r.output
    check logLines(s.log).anyIt(it == "args: poll games/pong/review/look.html --timeout-ms 2000")
    delEnv("FAKE_LAVISH_POLL")
    let w = s.board("answers", "games/pong/review/look.html", "--wait", "60")
    check "status: waiting" in w.output and "Nothing sent yet" in w.output
    check logLines(s.log).anyIt(it == "args: poll games/pong/review/look.html --timeout-ms 60000")
    check s.board("answers", "games/pong/review/look.html", "--wait", "9999").code == 2

  test "reply goes through a file (no shell sees the words), and the file is gone after":
    let s = scratch("pong")
    defer: s.done()
    check s.board("new", "look", "--game", "pong").code == 0
    let words = "Thanks, director: B it is; `rm -rf` $(nothing) \"quoted\""
    let r = s.board("reply", "games/pong/review/look.html", "-m", words)
    check r.code == 0
    let lines = logLines(s.log)
    check lines.anyIt(it == "reply-text: " & words)
    check not lines.anyIt(it.startsWith("args: ") and "director" in it)
    check toSeq(walkDir(s.root / "tmp" / "lavish")).len == 0
    check s.board("reply", "games/pong/review/look.html").code == 2

# --- status and install -------------------------------------------------------------------

suite "board: status and the install offer":
  test "status says what it is, whether it is there, and how it runs":
    let s = scratch("pong")
    defer: s.done()
    let here = s.board("status")
    check "lavish: installed (lavish-axi 0.1.92, checked with " & lavishTested & ")" in here.output
    check "127.0.0.1" in here.output
    let absent = s.boardWithout("status")
    check absent.code == 0 and "not installed" in absent.output and boardInstallCommand in absent.output
    check "board for reviewing things visually" in absent.output

  test "already installed: nothing to do":
    let s = scratch("pong")
    defer: s.done()
    let r = runBoardWith(@["install"], s.tools(lavish = true), s.root)
    check r.code == 0 and "already installed" in r.output

  test "no Node.js, an old one, or an npm folder that needs admin rights: nothing is offered or run":
    let s = scratch("pong")
    defer: s.done()
    putEnv("PARA_FAKE_NODE", "1")
    let fake = getAppFilename()
    var r = runBoardWith(@["install"], s.tools(lavish = false), s.root)
    check r.code == 1 and "nothing was installed" in r.output and "https://nodejs.org" in r.output
    putEnv("FAKE_NODE_VERSION", "v20.11.0")
    r = runBoardWith(@["install"], s.tools(lavish = false, node = fake, npm = fake, answer = true), s.root)
    check r.code == 1 and "Node.js " & $nodeNeeded & " or newer" in r.output and "v20.11.0" in r.output
    putEnv("FAKE_NODE_VERSION", "v22.1.0")
    putEnv("FAKE_NPM_PREFIX", s.root / "no-such-folder")
    r = runBoardWith(@["install"], s.tools(lavish = false, node = fake, npm = fake, answer = true), s.root)
    check r.code == 1 and "admin rights" in r.output and lavishInstallCommand in r.output
    check not logLines(s.log).anyIt("install" in it and "node-npm" in it)

  test "the offer says what, from where and into which folder, and a no installs nothing":
    let s = scratch("pong")
    defer: s.done()
    putEnv("PARA_FAKE_NODE", "1")
    putEnv("FAKE_NPM_PREFIX", s.root / "tmp")
    let fake = getAppFilename()
    var said = new(seq[string])
    let r = runBoardWith(@["install"], s.tools(lavish = false, node = fake, npm = fake, answer = false, said = said), s.root)
    check r.code == 0 and "nothing was installed" in r.output
    let offer = said[].join("\n")
    check ("What:    " & lavishProgram & " " & lavishTested) in offer and "MIT licence" in offer
    check ("From:    the npm registry, " & lavishPage) in offer and "no account" in offer
    check ("Into:    " & s.root / "tmp") in offer and "no admin rights" in offer
    check "Node.js " & $nodeNeeded in offer and ("Command: " & lavishInstallCommand) in offer
    check not logLines(s.log).anyIt(it.startsWith("node-npm: install"))

  test "a yes runs exactly the pinned npm install, and nothing else":
    let s = scratch("pong")
    defer: s.done()
    putEnv("PARA_FAKE_NODE", "1")
    putEnv("FAKE_NPM_PREFIX", s.root / "tmp")
    let fake = getAppFilename()
    let savedPath = getEnv("PATH")
    putEnv("PATH", s.root / "tmp") # so the real lavish-axi, if this computer has one, is not found after
    defer: putEnv("PATH", savedPath)
    let r = runBoardWith(@["install"], s.tools(lavish = false, node = fake, npm = fake, answer = true), s.root)
    check r.code == 0 and "installed into" in r.output
    let installs = logLines(s.log).filterIt(it.startsWith("node-npm: install"))
    check installs == @["node-npm: install -g --no-fund --no-audit " & lavishProgram & "@" & lavishTested]
    check not logLines(s.log).anyIt("sudo" in it)

# --- the startup check row and the hook ---------------------------------------------------

suite "board: the optional startup check and the hook":
  test "the row: ok when installed, an optional absent row (never a failure) with the install command when not":
    let here = boardCheck(getAppFilename())
    check here.state == csOk and here.id == "boards" and "optional" in here.label
    let absent = boardCheck("")
    check absent.id == "boards" and absent.state != csOk
    check absent.problem.startsWith("Optional, not installed")
    check "board for reviewing things visually" in absent.problem and "screenshots" in absent.problem
    check boardInstallCommand in absent.fix and "asks first" in absent.fix

  test "the hook says whether Lavish is there, and never to install it yourself":
    let root = newGameRepo("pong")
    defer: removeDir(root)
    root.put(voiceCoreFile, readFile(repoRoot / voiceCoreFile))
    let yes = producerContext(root, "", boards = true)
    check boardsLine in yes and noBoardsLine notin yes
    check "tmp/para board new" in boardsLine and "tmp/para board answers" in boardsLine
    let no = producerContext(root, "", boards = false)
    check noBoardsLine in no and "never install Lavish yourself" in noBoardsLine
