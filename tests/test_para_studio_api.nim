# Tests for `para studio`'s routes (tools/para/studioapi.nim) against the real handler on a
# loopback port and scratch git repos (bare repos stand in for the friend's online backup and
# for the Para Studio upstream; no network).
#
# Check, Save and Backup run as a child process of "the para binary". Here that binary is this
# test program itself: started with PARA_STUDIO_TEST_CHILD=1 it answers `check`, `save` and
# `backup` with the real command code (`runCheckWith` with steps that pass or fail on request,
# `runSaveWith`, `runBackupWith` with no `gh`), so the studio's process plumbing, polling and the
# guards the verbs carry are all exercised without a compiler. The real binary is run by hand in
# the PR's checklist.

import std/[unittest, os, osproc, strutils, sequtils, json, tempfiles, times, tables, algorithm, uri, xmltree, xmlparser]
import tools/para/art/clihelpers
import tools/para/checkcmd
import tools/para/savecmd
import tools/para/backupcmd
import tools/para/newcmd

when isMainModule:
  if getEnv("PARA_STUDIO_TEST_CHILD") == "1":
    # --- the stand-in `para`: runs in the repo (the working directory) the studio started it in ---
    let args = commandLineParams()
    let sleepMs = (if getEnv("FAKE_CHECK_SLEEP_MS").len > 0: parseInt(getEnv("FAKE_CHECK_SLEEP_MS")) else: 0)
    let failing = getEnv("FAKE_CHECK_FAIL") == "1"
    let steps: seq[CheckStep] = @[("tests", proc (g: string): Run =
                     if sleepMs > 0: sleep(sleepMs)
                     if failing: ("tests output: 1 failure\n", 1) else: ("", 0)),
                  ("build", proc (g: string): Run = ("", 0))]
    var run: Run = errorOut("the test stand-in does not know \"" & (if args.len > 0: args[0] else: "") & "\"", @[])
    if args.len > 0:
      case args[0]
      of "check": run = runCheckWith(args[1 .. ^1], steps)
      of "save": run = runSaveWith(args[1 .. ^1])
      of "backup": run = runBackupWith(args[1 .. ^1], "", "/nonexistent/para-test-gh")
      of "new": run = runNew(args[1 .. ^1])
      else: discard
    stdout.write run.output
    quit run.code

import studio_support
import tools/para/studiohttp
import tools/para/studioapi

proc jsonOf(r: Reply): JsonNode = parseJson(r.body)

proc post(r: Running, path: string, body: JsonNode): Reply =
  r.request("POST", path, body = $body)

proc waitJob(r: Running, id: int, seconds = 30): JsonNode =
  ## Polls like the page does until the job ends; returns its last answer with all the output.
  var since = 0
  var output = ""
  let until = epochTime() + seconds.float
  while epochTime() < until:
    let reply = r.request("GET", "/api/job?id=" & $id & "&since=" & $since)
    doAssert reply.status == 200, reply.raw
    result = jsonOf(reply)
    output.add result["output"].getStr
    since = result["next"].getInt
    if not result["running"].getBool:
      result["output"] = %output
      return
    sleep(50)
  doAssert false, "the job did not finish in time"

proc runJob(r: Running, path: string, body: JsonNode): JsonNode =
  let started = r.post(path, body)
  doAssert started.status == 200, started.raw
  r.waitJob(jsonOf(started)["job"]["id"].getInt)

var root: string
var running: Running

proc begin(games: varargs[string]) =
  putEnv("PARA_STUDIO_TEST_CHILD", "1")
  delEnv("FAKE_CHECK_FAIL")
  delEnv("FAKE_CHECK_SLEEP_MS")
  root = newGameRepo(games)
  running = startStudio(root, getAppFilename())

proc finish() =
  running.stop()
  removeDir(root)
  delEnv("PARA_STUDIO_TEST_CHILD")

suite "para studio api: the page and the facts":
  setup: begin("pong")
  teardown: finish()

  test "the page is served with a Content-Security-Policy whose nonce is the one on its script and style blocks":
    let r = running.request("GET", "/?token=" & running.srv.token, withToken = false)
    check r.status == 200
    check r.headers["content-type"].startsWith("text/html")
    let csp = r.headers["content-security-policy"]
    check "default-src 'none'" in csp
    check "frame-ancestors 'none'" in csp
    check "font-src data:;" in csp      # the fonts are inside the page: nothing may ask for a web font
    check csp.count("font-src") == 1
    check "img-src data: blob:" in csp  # so the favicon has to be a data: address
    let nonce = csp.split("script-src 'nonce-")[1].split("'")[0]
    check nonce.len >= 32
    check csp.split("style-src 'nonce-")[1].split("'")[0] == nonce
    check "__NONCE__" notin r.body
    check r.body.count("<script nonce=\"" & nonce & "\">") == r.body.count("<script")
    check r.body.count("<style nonce=\"" & nonce & "\">") == r.body.count("<style")
    let again = running.request("GET", "/?token=" & running.srv.token, withToken = false)
    check again.headers["content-security-policy"] != csp

  test "the favicon is a valid SVG document that loads, with nothing outside it":
    let r = running.request("GET", "/?token=" & running.srv.token, withToken = false)
    let tag = r.body.split("<link rel=\"icon\"")[1].split(">")[0]
    let href = tag.split("href=\"")[1].split("\"")[0]
    check href.startsWith("data:image/svg+xml,")
    let svg = parseXml(decodeUrl(href["data:image/svg+xml,".len .. ^1], decodePlus = false))
    check svg.tag == "svg"
    check svg.attr("xmlns") == "http://www.w3.org/2000/svg"
    check svg.findAll("ellipse").len > 0
    for tagName in ["script", "image", "use", "foreignObject", "style"]:
      check svg.findAll(tagName).len == 0

  test "in a real browser: bubbles, Pip, theme, the notes moved off the message box, fonts, favicon and Content-Security-Policy hold":
    var chrome = getEnv("CHROME_BIN")
    if chrome.len == 0:
      for c in ["chromium", "google-chrome", "chromium-browser", "chrome"]:
        if findExe(c).len > 0:
          chrome = findExe(c)
          break
    let node = findExe("node")
    if chrome.len == 0 or node.len == 0:
      skip()
    else:
      let origin = "http://127.0.0.1:" & $running.srv.port
      let probe = parentDir(currentSourcePath()) / "studio_page_probe.mjs"
      let (output, code) = execCmdEx(quoteShellCommand([node, probe, origin & "/?token=" & running.srv.token, chrome]))
      if code != 0: echo output
      require code == 0
      let seen = parseJson(output.strip.splitLines[^1])

      # the page asks for nothing but this server and data: pictures, and nothing is refused or throws
      for u in seen["requests"].getElems:
        check u.getStr.startsWith(origin & "/") or u.getStr.startsWith("data:") or u.getStr.startsWith("blob:")
      check seen["problems"].getElems.len == 0

      # at a wide and a narrow window nothing is written under the message box; the two notes are one
      # click away, in the startup checks and in the help, and the chips and Pip beside the producer show
      for width in ["1280", "600"]:
        let w = seen["layout"][width]
        check w["underBox"].getElems.len == 0
        check w["calmText"].getStr.startsWith("Nothing is sent until")
        check not w["calmShown"].getBool and w["calmInReady"].getBool
        check w["costText"].getStr.len > 0
        check not w["costShown"].getBool and w["costInReady"].getBool and w["costInHelp"].getBool
        check w["aboutInHelp"].getInt >= 1
        check w["chipsShown"].getBool
        check w["avatarDrawn"].getBool
        check w["avatarShown"].getBool
        # a bubble on each side: filled, rounded, the director's to the right, and the text stays text
        for side in ["you", "prod"]:
          check w[side]["background"].getStr != "rgba(0, 0, 0, 0)"
          check w[side]["radius"].getStr != "0px"
        check w["youRight"].getBool
        check w["prodTextIsText"].getBool
      check seen["layout"]["600"]["avatarBox"].getFloat < seen["layout"]["1280"]["avatarBox"].getFloat
      # Pip is a mascot, not an icon: at least three times the area it had (30px beside a message and in
      # the sidebar, 72px on the greeting, 26px and 56px on a phone)
      let wide = seen["layout"]["1280"]
      check wide["avatarBox"].getFloat >= 52 and wide["sideBox"].getFloat >= 52 and wide["helloBox"].getFloat >= 125
      check seen["layout"]["600"]["avatarBox"].getFloat >= 45 and seen["layout"]["600"]["helloBox"].getFloat >= 97
      # the page's own fonts load (from inside the page, so the policy above allows them)
      check seen["fonts"]["text"].getBool and seen["fonts"]["headings"].getBool

      # on a phone the closed drawer is off-screen and out of the tab order; open, it takes focus; closed again, it is gone again
      let drawer = seen["drawer"]
      check drawer["closed"]["visibility"].getStr == "hidden" and not drawer["closed"]["canFocusInside"].getBool
      check drawer["open"]["visibility"].getStr == "visible" and drawer["open"]["canFocusInside"].getBool and drawer["open"]["left"].getFloat >= 0
      check drawer["reclosed"]["visibility"].getStr == "hidden" and not drawer["reclosed"]["canFocusInside"].getBool
      check seen["drawerWide"]["visibility"].getStr == "visible" and seen["drawerWide"]["canFocusInside"].getBool

      # Pip looks different idle, thinking and talking; reduced motion stills every state
      let pip = seen["pip"]
      check pip["idle"]["state"].getStr == "idle" and pip["thinking"]["state"].getStr == "thinking" and pip["talking"]["state"].getStr == "talking"
      var birdMoves: seq[string]
      for state in ["idle", "thinking", "talking"]:
        check pip[state]["bird"].getStr != "none"
        birdMoves.add pip[state]["bird"].getStr
        check seen["pipReduced"][state]["bird"].getStr == "none"
        check seen["pipReduced"][state]["jaw"].getStr == "none"
      check birdMoves.deduplicate.len == 3
      check pip["thinking"]["dots"].getStr != "none" and pip["idle"]["dots"].getStr == "none" and pip["talking"]["dots"].getStr == "none"
      check pip["talking"]["arcs"].getStr != "none" and pip["idle"]["arcs"].getStr == "none" and pip["thinking"]["arcs"].getStr == "none"
      check pip["talking"]["jaw"].getStr != "none" and pip["idle"]["jaw"].getStr == "none"

      # the favicon decodes as a picture in the browser
      check seen["favicon"]["scheme"].getStr == "data:image/svg+xml"
      check seen["favicon"]["width"].getInt > 0 and seen["favicon"]["height"].getInt > 0

      # the look follows the computer: purple with gold in the dark, white with purple in the light, warn stays orange
      let theme = seen["theme"]
      check theme["followsDark"]["theme"].getStr == ""
      check theme["followsDark"]["bg"].getStr == "rgb(28, 19, 48)"
      check theme["followsDark"]["accent"].getStr == "#ffe953"
      check theme["followsLight"]["bg"].getStr == "rgb(255, 255, 255)"
      check theme["followsLight"]["accent"].getStr == "#2a1b47"
      for warn in [seen["warnDark"].getStr, seen["warnLight"].getStr]:
        let rgb = warn.replace("rgb(", "").replace(")", "").split(", ").mapIt(parseInt(it))
        check rgb[0] > rgb[1] and rgb[1] > rgb[2] and rgb[0] > 150   # orange, never red or yellow
      # the toggle goes light, dark, back to following the computer; the pick is remembered across a reload
      let picks = theme["picks"].getElems
      check picks.mapIt(it["theme"].getStr) == @["light", "dark", ""]
      check picks[0]["bg"].getStr == "rgb(255, 255, 255)" and picks[1]["bg"].getStr == "rgb(28, 19, 48)"
      check picks.mapIt(it["label"].getStr).deduplicate.len == 3
      check theme["remembered"]["theme"].getStr == "dark"
      check theme["remembered"]["bg"].getStr == "rgb(28, 19, 48)"

  test "state: the game, the friend's name and the resume facts":
    let s = jsonOf(running.request("GET", "/api/state"))
    check s["games"].getElems.len == 1
    check s["game"].getStr == "pong"
    check s["friend"].getStr == "Sam"
    let f = s["facts"]
    check f["now"].getStr == "make the ship move"
    check f["lastSave"]["n"].getInt == 1
    check f["lastSave"]["note"].getStr == "first save"
    check f["unsaved"]["count"].getInt == 0
    check f["checked"].getBool == false
    check s["job"].kind == JNull
    # no token leaks into a fact
    check running.srv.token notin $s

  test "state: unsaved files are counted, and a note in the plan cannot smuggle control characters":
    root.put("games/pong/pong.nim", "echo 2\n")
    root.put("games/pong/new.nim", "echo 3\n")
    let s = jsonOf(running.request("GET", "/api/state"))
    check s["facts"]["unsaved"]["count"].getInt == 2
    check "pong.nim" in $s["facts"]["unsaved"]["names"]
    root.put("games/pong/PLAN.md", "# pong\n\n## Now\n- [ ] do a thing\x01\x1b[31m red\n")
    let t = jsonOf(running.request("GET", "/api/state"))
    check "\x1b" notin t["facts"]["now"].getStr
    check "\x01" notin t["facts"]["now"].getStr

  test "state: an unknown game is a 404, a missing .. in the name is refused":
    check running.request("GET", "/api/state?game=nope").status == 404
    check running.request("GET", "/api/state?game=..%2f..%2fetc").status == 404
    check running.request("GET", "/api/savepoints?game=nope").status == 404

  test "save points: oldest first, with the date and the note":
    let d = jsonOf(running.request("GET", "/api/savepoints"))
    check d["game"].getStr == "pong"
    check d["points"].getElems.len == 1
    check d["points"][0]["n"].getInt == 1
    check d["points"][0]["note"].getStr == "first save"

  test "an unknown route is a 404 and a bad JSON body is a 400":
    check running.request("GET", "/api/nope").status == 404
    check running.request("POST", "/api/nope", body = "{}").status == 404
    check running.request("POST", "/api/check", body = "not json").status == 400
    check running.request("POST", "/api/check", body = "[1,2]").status == 400

suite "para studio api: several games, or none":
  teardown: finish()

  test "with several games the page has to pick; naming one works":
    begin("pong", "tetris")
    let s = jsonOf(running.request("GET", "/api/state"))
    check s["games"].getElems.len == 2
    check s["game"].kind == JNull
    check s["facts"].kind == JNull
    check running.request("POST", "/api/check", body = "{}").status == 400
    check jsonOf(running.request("POST", "/api/check", body = "{}"))["error"].getStr == "which-game"
    let t = jsonOf(running.request("GET", "/api/state?game=tetris"))
    check t["game"].getStr == "tetris"
    check t["facts"]["now"].getStr == "make the ship move"

  test "started with --game the studio starts on that game":
    root = newGameRepo("pong", "tetris")
    putEnv("PARA_STUDIO_TEST_CHILD", "1")
    running = startStudio(root, getAppFilename(), "tetris")
    check jsonOf(running.request("GET", "/api/state"))["game"].getStr == "tetris"

  test "no game with a PLAN.md: an empty list, not an error":
    begin()
    let s = jsonOf(running.request("GET", "/api/state"))
    check s["games"].getElems.len == 0
    check s["game"].kind == JNull
    check running.request("POST", "/api/check", body = "{}").status == 400

suite "para studio api: a new game from the page":
  teardown: finish()

  test "the name is checked in plain words first; then `para new` runs as a step and the game is there":
    begin()
    root.put("template/PLAN.md", "# __GAME__: plan\n\nCall the friend: director\n")
    root.put("template/template.nim", "echo \"__GAME__\"\n")
    for (body, code) in [(%*{}, "needs-name"), (%*{"name": "  "}, "needs-name"), (%*{"name": "Space Frogs"}, "bad-name"),
                         (%*{"name": "1st"}, "bad-name"), (%*{"name": "../x"}, "bad-name"), (%*{"name": repeat('a', 41)}, "bad-name")]:
      let r = running.post("/api/new", body)
      check r.status == 400
      check jsonOf(r)["error"].getStr == code
      check "small letters" in jsonOf(r)["message"].getStr or "name" in jsonOf(r)["message"].getStr
    let started = running.post("/api/new", %*{"name": "space_frogs"})
    check started.status == 200
    let job = jsonOf(started)["job"]
    check job["kind"].getStr == "new"
    let done = running.waitJob(job["id"].getInt)
    check done["code"].getInt == 0
    check fileExists(root / "games/space_frogs/PLAN.md")
    check readFile(root / "games/space_frogs/space_frogs.nim") == "echo \"space_frogs\"\n"
    let s = jsonOf(running.request("GET", "/api/state"))
    check s["games"].getElems.mapIt(it.getStr) == @["space_frogs"]
    # a name that is taken is refused before anything runs
    let again = running.post("/api/new", %*{"name": "space_frogs"})
    check again.status == 409 and jsonOf(again)["error"].getStr == "exists"

  test "a new game waits for a running step, like Check and Save":
    begin("pong")
    putEnv("FAKE_CHECK_SLEEP_MS", "1500")
    let first = running.post("/api/check", %*{"game": "pong"})
    check first.status == 200
    check running.post("/api/new", %*{"name": "frogs"}).status == 409
    discard running.waitJob(jsonOf(first)["job"]["id"].getInt)

  test "open a terminal: only where the system has one standard way (macOS), else plainly not":
    begin("pong")
    when defined(macosx):
      check terminalCommand(root) == @["open", "-a", "Terminal", root] # not run here: it would open a window
    else:
      check terminalCommand(root).len == 0
      let r = running.post("/api/terminal", %*{})
      check r.status == 501 and jsonOf(r)["error"].getStr == "no-terminal"

suite "para studio api: check":
  setup: begin("pong")
  teardown: finish()

  test "a passing check runs `para check` as a child and reports it":
    root.put("games/pong/pong.nim", "echo 2\n")
    let started = running.post("/api/check", %*{"game": "pong"})
    check started.status == 200
    let job = jsonOf(started)["job"]
    check job["kind"].getStr == "check"
    let done = running.waitJob(job["id"].getInt)
    check done["running"].getBool == false
    check done["code"].getInt == 0
    check "check: pass" in done["output"].getStr
    # the stamp the child wrote is what the state shows
    check jsonOf(running.request("GET", "/api/state"))["facts"]["checked"].getBool

  test "a failing check shows its output and a non-zero code":
    putEnv("FAKE_CHECK_FAIL", "1")
    let done = running.runJob("/api/check", %*{"game": "pong"})
    check done["code"].getInt == 1
    check "check: FAIL" in done["output"].getStr
    check "1 failure" in done["output"].getStr

  test "only one step runs at a time; a second is refused, not queued":
    putEnv("FAKE_CHECK_SLEEP_MS", "1200")
    let first = running.post("/api/check", %*{"game": "pong"})
    check first.status == 200
    let second = running.post("/api/check", %*{"game": "pong"})
    check second.status == 409
    check jsonOf(second)["error"].getStr == "busy"
    check running.post("/api/save", %*{"game": "pong", "message": "x"}).status == 409
    # the state tells a reloaded page that a step is running
    check jsonOf(running.request("GET", "/api/state"))["job"]["running"].getBool
    let done = running.waitJob(jsonOf(first)["job"]["id"].getInt)
    check done["code"].getInt == 0
    # and a new one can start afterwards
    check running.post("/api/check", %*{"game": "pong"}).status == 200

  test "a job that is not there is a 404, and bad job requests are 400":
    check running.request("GET", "/api/job?id=99").status == 404
    check running.request("GET", "/api/job?id=abc").status == 400
    check running.request("GET", "/api/job").status == 400
    check running.request("GET", "/api/job?id=1&since=-5").status == 400

  test "a game name that is not a game never reaches a command":
    for bad in ["../x", "pong --list", "-m", "PONG", "pong\n", "pong "]:
      let r = running.post("/api/check", %*{"game": bad})
      check r.status in [400, 404]

suite "para studio api: save keeps the guards of `para save`":
  setup: begin("pong")
  teardown: finish()

  test "a note is required, one line, and not too long":
    check running.post("/api/save", %*{"game": "pong"}).status == 400
    check running.post("/api/save", %*{"game": "pong", "message": "   "}).status == 400
    check running.post("/api/save", %*{"game": "pong", "message": "two\nlines"}).status == 400
    check running.post("/api/save", %*{"game": "pong", "message": 'x'.repeat(201)}).status == 400
    check running.post("/api/save", %*{"game": "pong", "message": 5}).status == 400

  test "saving without a fresh passing check is refused in plain words, and nothing is saved":
    root.put("games/pong/pong.nim", "echo 2\n")
    let before = gitOk(root, "rev-parse", "HEAD")
    let done = running.runJob("/api/save", %*{"game": "pong", "message": "the ship moves"})
    check done["code"].getInt == 1
    check "checks have not passed" in done["output"].getStr
    check "Nothing was saved" in done["output"].getStr
    check gitOk(root, "rev-parse", "HEAD") == before

  test "check, then save: a new numbered save point with the note":
    root.put("games/pong/pong.nim", "echo 2\n")
    check running.runJob("/api/check", %*{"game": "pong"})["code"].getInt == 0
    let done = running.runJob("/api/save", %*{"game": "pong", "message": "the ship moves; it's \"fast\" & fun"})
    check done["code"].getInt == 0
    check "Saved as save point 2" in done["output"].getStr
    let points = jsonOf(running.request("GET", "/api/savepoints"))["points"].getElems
    check points.len == 2
    check points[1]["note"].getStr == "the ship moves; it's \"fast\" & fun"
    let s = jsonOf(running.request("GET", "/api/state"))
    check s["facts"]["unsaved"]["count"].getInt == 0
    check s["facts"]["lastSave"]["n"].getInt == 2

  test "an edit after the check makes the check stale, so the save is refused":
    root.put("games/pong/pong.nim", "echo 2\n")
    check running.runJob("/api/check", %*{"game": "pong"})["code"].getInt == 0
    root.put("games/pong/pong.nim", "echo 3\n")
    check not jsonOf(running.request("GET", "/api/state"))["facts"]["checked"].getBool
    let done = running.runJob("/api/save", %*{"game": "pong", "message": "late edit"})
    check done["code"].getInt == 1
    check "checks have not passed" in done["output"].getStr

  test "a note that looks like a flag is just a note":
    root.put("games/pong/pong.nim", "echo 2\n")
    check running.runJob("/api/check", %*{"game": "pong"})["code"].getInt == 0
    let done = running.runJob("/api/save", %*{"game": "pong", "message": "--list --back 1 --yes"})
    check done["code"].getInt == 0
    check jsonOf(running.request("GET", "/api/savepoints"))["points"][1]["note"].getStr == "--list --back 1 --yes"

proc newBare(): string =
  result = createTempDir("para_studio_bare_", "")
  discard gitOk(result, "init", "-q", "--bare")

suite "para studio api: backup keeps the guards of `para backup`":
  var bare: string
  setup:
    begin("pong")
    bare = newBare()
  teardown:
    removeDir(bare)
    finish()

  test "not set up: says so with the steps, and offers nothing to press":
    let b = jsonOf(running.request("GET", "/api/backup"))
    check b["setUp"].getBool == false
    check b["steps"].getElems.len > 0
    check "git remote add backup" in $b["steps"]

  test "set up: shows where it goes, never the login in the address":
    discard gitOk(root, "remote", "add", "backup", "https://github.com/alice/pong-backup")
    let b = jsonOf(running.request("GET", "/api/backup"))
    check b["setUp"].getBool
    check b["url"].getStr == "https://github.com/alice/pong-backup"
    check b["branch"].getStr == "main"
    check b["problem"].getStr == ""
    discard gitOk(root, "remote", "set-url", "backup", "https://alice:ghp_secret@github.com/alice/pong-backup")
    let c = running.request("GET", "/api/backup")
    check "ghp_secret" notin c.raw
    check "password" in jsonOf(c)["problem"].getStr

  test "a backup runs only when the request says the friend said yes":
    discard gitOk(root, "remote", "add", "backup", bare)
    check running.post("/api/backup", %*{}).status == 400
    check running.post("/api/backup", %*{"confirm": false}).status == 400
    check running.post("/api/backup", %*{"confirm": "yes"}).status == 400
    check gitOk(bare, "for-each-ref").len == 0

  test "without the friend saying the repository is private, a local or non-GitHub address is refused":
    discard gitOk(root, "remote", "add", "backup", bare)
    let done = running.runJob("/api/backup", %*{"confirm": true})
    check done["code"].getInt == 1
    check "--is-private" in done["output"].getStr
    check "Nothing was uploaded" in done["output"].getStr
    check gitOk(bare, "for-each-ref").len == 0

  test "with their yes and Private: the branch and the save points go to the backup, nothing else":
    discard gitOk(root, "remote", "add", "backup", bare)
    discard gitOk(root, "branch", "scratch-work")
    let done = running.runJob("/api/backup", %*{"confirm": true, "isPrivate": true})
    check done["code"].getInt == 0
    check "Backed up" in done["output"].getStr
    check gitOk(bare, "for-each-ref", "--format=%(refname)").splitLines ==
      @["refs/heads/main", "refs/tags/save-pong-1"]

  test "a backup that is also origin, or points at the Para Studio project, is refused":
    discard gitOk(root, "remote", "add", "origin", bare)
    discard gitOk(root, "remote", "add", "backup", bare)
    let same = running.runJob("/api/backup", %*{"confirm": true, "isPrivate": true})
    check same["code"].getInt == 1
    check "same repository as another remote" in same["output"].getStr
    discard gitOk(root, "remote", "remove", "origin")
    discard gitOk(root, "remote", "set-url", "backup", "https://github.com/PDepaula/parastudio")
    let upstream = running.runJob("/api/backup", %*{"confirm": true, "isPrivate": true})
    check upstream["code"].getInt == 1
    check "Para Studio project" in upstream["output"].getStr
    check gitOk(bare, "for-each-ref").len == 0

  test "an online copy that is ahead is never forced over":
    discard gitOk(root, "remote", "add", "backup", bare)
    check running.runJob("/api/backup", %*{"confirm": true, "isPrivate": true})["code"].getInt == 0
    let other = createTempDir("para_studio_other_", "")
    defer: removeDir(other)
    discard gitOk(other, "clone", "-q", "-b", "main", bare, "w")
    discard gitOk(other / "w", "config", "user.name", "O")
    discard gitOk(other / "w", "config", "user.email", "o@example.com")
    other.put("w/x.txt", "x\n")
    discard gitOk(other / "w", "add", ".")
    discard gitOk(other / "w", "commit", "-q", "-m", "elsewhere")
    discard gitOk(other / "w", "push", "-q", "origin", "main")
    let theirs = gitOk(bare, "rev-parse", "main")
    root.put("games/pong/pong.nim", "echo 2\n")
    discard gitOk(root, "commit", "-q", "-am", "more")
    let done = running.runJob("/api/backup", %*{"confirm": true, "isPrivate": true})
    check done["code"].getInt == 1
    check "the upload failed" in done["output"].getStr
    check gitOk(bare, "rev-parse", "main") == theirs

proc beginOwnRepo() =
  ## `begin("pong")`, but with games/pong a git repository of its own (as `para new` makes it) and
  ## the repository around it ignoring games/, like the public tool.
  putEnv("PARA_STUDIO_TEST_CHILD", "1")
  delEnv("FAKE_CHECK_FAIL")
  delEnv("FAKE_CHECK_SLEEP_MS")
  root = newGameRepo("pong")
  discard gitOk(root, "rm", "-r", "-q", "--cached", "games")
  root.put(".gitignore", "tmp/\ngames/\n")
  discard gitOk(root, "add", ".gitignore")
  discard gitOk(root, "commit", "-q", "-m", "the game leaves this repository")
  discard gitOk(root, "tag", "-d", "save-pong-1")
  let g = root / "games" / "pong"
  discard gitOk(g, "init", "-q")
  discard gitOk(g, "symbolic-ref", "HEAD", "refs/heads/main")
  discard gitOk(g, "config", "user.name", "Scratch")
  discard gitOk(g, "config", "user.email", "scratch@example.com")
  discard gitOk(g, "config", "commit.gpgsign", "false")
  discard gitOk(g, "add", ".")
  discard gitOk(g, "commit", "-q", "-m", "start")
  discard gitOk(g, "tag", "-a", "save-pong-1", "-m", "first save")
  running = startStudio(root, getAppFilename())

suite "para studio api: a game that is a repository of its own":
  var bare: string
  setup:
    beginOwnRepo()
    bare = newBare()
  teardown:
    removeDir(bare)
    finish()

  test "the save points and the unsaved count come from the game's repository":
    check jsonOf(running.request("GET", "/api/savepoints"))["points"].len == 1
    root.put("games/pong/pong.nim", "echo 2\n")
    let facts = jsonOf(running.request("GET", "/api/state"))["facts"]
    check facts["lastSave"]["n"].getInt == 1
    check facts["unsaved"]["count"].getInt == 1
    check facts["unsaved"]["names"][0].getStr == "pong.nim"

  test "Check then Save keeps the save point in the game's repository, and the outer one is untouched":
    root.put("games/pong/pong.nim", "echo 2\n")
    let outer = gitOk(root, "rev-parse", "HEAD")
    check running.runJob("/api/check", %*{"game": "pong"})["code"].getInt == 0
    let saved = running.runJob("/api/save", %*{"game": "pong", "message": "ship moves"})
    check saved["code"].getInt == 0
    check "Saved as save point 2" in saved["output"].getStr
    check gitOk(root / "games" / "pong", "tag", "--list", "save-*").splitLines.sorted == @["save-pong-1", "save-pong-2"]
    check gitOk(root, "rev-parse", "HEAD") == outer
    check gitOk(root, "tag", "--list").len == 0

  test "backup: the page is told it is the game's own repository, and the upload comes from there":
    let none = jsonOf(running.request("GET", "/api/backup?game=pong"))
    check none["own"].getBool
    check none["game"].getStr == "pong"
    check not none["setUp"].getBool
    check "git -C games/pong remote add backup" in $none["steps"]
    discard gitOk(root / "games" / "pong", "remote", "add", "backup", bare)
    # a backup remote on the outer repository is not what this game's backup looks at
    check jsonOf(running.request("GET", "/api/backup?game=pong"))["setUp"].getBool
    check running.post("/api/backup", %*{"game": "pong"}).status == 400
    let done = running.runJob("/api/backup", %*{"game": "pong", "confirm": true, "isPrivate": true})
    check done["code"].getInt == 0
    check gitOk(bare, "for-each-ref", "--format=%(refname)").splitLines.sorted ==
      @["refs/heads/main", "refs/tags/save-pong-1"]
    check jsonOf(running.request("GET", "/api/backup?game=nope")).hasKey("error")
