# Tests for the whole-app model of Para Studio: tools/para/studiodesk.em (checked against the code by
# the build) and tools/para/studio-plan.em (the same app plus what the later slices add, checked by
# nothing but this file), and the two pictures drawn from them under docs/. What is pinned here:
#
# - the plan is never behind the code: every record, event, command, view, query and processor line
#   of the checked file is in the plan with the same canonical line, every slice of it is in the plan
#   as it is, and every screen of it is in the plan with at least its commands and queries;
# - the plan is a model in its own right (every screen and slice in it names real blocks and real edges);
# - docs/studio-model.svg and docs/studio-plan.svg are exactly what `eversince pic` draws from the two
#   files, so a change to a model file that is not redrawn fails here (redraw with
#   `eversince pic tools/para/studiodesk.em docs/studio-model.svg`, and the same for the plan);
# - the page and the routes are held to the screens of the checked file: every `/api/` call in
#   tools/para/studio/index.html is a route in studioapi.nim's `handle`, the comment on each route's `of`
#   line names the model blocks it rests on (`query X`, `command X`, or `no block`), every block a route
#   the page calls is on a screen of the page, and every command and query on a screen of the page is
#   reached by a route the page calls. The routes with no panel on the page yet (the HelperApi screen's
#   three) are named here, not skipped;
# - the few rules the desk holds on its own (a game's name, a save's note) are the same as the ones the
#   shell and `para new` use, since the desk may not import them.

import std/[unittest, os, strutils, sequtils]
import eversince
import eversince/picture
import tools/para/savepoint
import tools/para/studiodesk

const
  here = currentSourcePath.parentDir
  paraDir = here.parentDir / "tools" / "para"
  docsDir = here.parentDir / "docs"
  pageScreens = ["SetupPanel", "GamesPanel", "ChatPanel", "PlayPanel", "StepsPanel", "ResumePanel", "BackupSheet", "NewGameSheet"]
    ## the screens that are panels of the page
  pagelessScreens = ["HelperApi"]
    ## the screens whose routes have no panel on the page yet: the page calls none of their routes

proc modelOf(file: string): Model =
  parseModel(readFile(paraDir / file), file)

proc unix(text: string): string =
  text.replace("\r\n", "\n")

proc behind(code, plan: Model): seq[string] =
  ## What the plan lacks of the checked file; empty when the plan is ahead of it or level with it.
  for b in code.blocks:
    let found = plan.blocks.filterIt(it.kind == b.kind and it.name == b.name)
    if found.len == 0:
      result.add "missing from the plan: " & b.canonical
    elif b.kind in codeKinds:
      if found[0].canonical != b.canonical:
        result.add "the plan's line differs: " & found[0].canonical & " (code: " & b.canonical & ")"
    elif b.kind == "screen":
      for n in b.edge("commands") & b.edge("queries"):
        if n notin found[0].edge("commands") & found[0].edge("queries"):
          result.add "the plan's screen " & b.name & " lacks " & n
  for s in code.slices:
    if plan.slices.filterIt(it.name == s.name and it.steps == s.steps).len == 0:
      result.add "slice missing from the plan, or different: " & s.name

suite "the plan is ahead of the code, never behind":
  let code = modelOf("studiodesk.em")
  let plan = modelOf("studio-plan.em")

  test "every block and slice of the checked file is in the plan, the same":
    check behind(code, plan) == newSeq[string]()

  test "every slice of the migration has landed, so the plan has nothing the checked file lacks (it may again, with the next slice)":
    check plan.blocks.len >= code.blocks.len
    check plan.slices.len >= code.slices.len
    for name in ["StopTurn", "StepClock", "TurnRunner", "PlayWindow", "PlayRunner", "PlayNow", "Helpers", "HelperRunner", "HelpersNow", "StartHelper"]:
      check plan.find(name).name == name
      check code.find(name).name == name

  test "the plan is a model in its own right: its screens and slices name real blocks and edges":
    let own = plan.blocks.filterIt(it.kind in codeKinds).mapIt(it.canonical)
    check checkModel(plan, own, "studio-plan.em").errors == newSeq[string]()

  test "a plan that is behind is told so":
    var short = plan
    short.blocks = short.blocks.filterIt(it.name != "StartPlay")
    check behind(code, short).anyIt("missing from the plan: command StartPlay" in it)
    var changed = plan
    for b in changed.blocks.mitems:
      if b.name == "StartStep": b.fields.add "extra:int"
    check behind(code, changed).anyIt("the plan's line differs" in it and "StartStep" in it)
    var fewer = plan
    for b in fewer.blocks.mitems:
      if b.name == "PlayPanel": b.edges = @[]
    check behind(code, fewer).anyIt("the plan's screen PlayPanel lacks StartPlay" in it)
    var noSlice = plan
    noSlice.slices = noSlice.slices[1 .. ^1]
    check behind(code, noSlice).anyIt("slice missing from the plan" in it)

suite "the pictures are what the model files draw":
  test "docs/studio-model.svg is the checked file, drawn":
    check readFile(docsDir / "studio-model.svg").unix == render(modelOf("studiodesk.em")).unix

  test "docs/studio-plan.svg is the plan, drawn":
    check readFile(docsDir / "studio-plan.svg").unix == render(modelOf("studio-plan.em")).unix

  test "every panel of the page has a screen":
    let m = modelOf("studiodesk.em")
    for panel in @pageScreens & @pagelessScreens & @["TurnThread", "JobThread", "PlayThread"]:
      check m.find(panel).kind == "screen"

type
  Route = object
    ## One `of "/api/..."` line of studioapi.nim's `handle`, and what its comment says it rests on.
    meth, path: string
    kind: string          ## "query", "command", "none" (`# no block`), or "" when the comment says neither
    blocks: seq[string]
  Call = tuple[meth, path: string]
    ## One `/api/` path the page names, with the method it uses ("?" when this file cannot tell)

proc name(r: Route): string = r.meth & " " & r.path

proc readRoutes(src: string): seq[Route] =
  ## The routes of `handle`: the first `case req.path` is the GET one, the second the POST one.
  let start = src.find("proc handle(")
  let stop = src.find("\nproc ", start + 1)
  var meth = ""
  for raw in src[start ..< (if stop < 0: src.len else: stop)].splitLines:
    let line = raw.strip
    if line.startsWith("case req.path"):
      meth = if meth == "": "GET" else: "POST"
    if not line.startsWith("of \"/api/"): continue
    var r = Route(meth: meth, path: line["of \"".len ..< line.find('"', 4)])
    let hash = line.find('#')
    let tag = if hash < 0: "" else: line[hash + 1 .. ^1].strip
    if tag == "no block":
      r.kind = "none"
    else:
      for kind in ["query", "command"]:
        if tag.startsWith(kind & " "):
          r.kind = kind
          r.blocks = tag[kind.len + 1 .. ^1].split(',').mapIt(it.strip)
    result.add r

proc readCalls(page: string): seq[Call] =
  ## Every `"/api/...` the page names: through `api(METHOD, ...)`, through `startStep` (which posts), or
  ## through a bare `fetch` (a GET). Anything else comes back with method "?", so it is told, not dropped.
  var at = page.find("\"/api/")
  while at >= 0:
    var stop = at + 1
    while stop < page.len and page[stop] notin {'"', '?'}: inc stop
    let before = page[max(0, at - 16) ..< at]
    let eol = page.find('\n', stop)
    let meth =
      if before.endsWith("api(\"GET\", "): "GET"
      elif before.endsWith("api(\"POST\", "): "POST"
      elif before.endsWith("startStep("): "POST"
      elif before.endsWith("fetch(") and "method" notin page[stop ..< (if eol < 0: page.len else: eol)]: "GET"
      else: "?"
    result.add (meth, page[at + 1 ..< stop])
    at = page.find("\"/api/", stop)

proc onScreens(m: Model, n: string, screens: openArray[string]): bool =
  screens.anyIt(n in m.find(it).edge("commands") & m.find(it).edge("queries"))

proc routeDrift(routes: seq[Route], calls: seq[Call], m: Model): seq[string] =
  ## Where the routes, the page's calls and the model's screens disagree; empty when they agree.
  proc called(r: Route): bool = (meth: r.meth, path: r.path) in calls
  for r in routes:
    if routes.countIt(it.meth == r.meth and it.path == r.path) > 1:
      result.add "route " & r.name & " is in the case twice"
    case r.kind
    of "":
      result.add "route " & r.name & " names no model block: end its `of` line with `# query X`, `# command X` or `# no block`"
    of "none":
      if not r.called:
        result.add "the page never calls " & r.name & ", and it rests on no screen without a panel"
    else:
      let want = if r.meth == "GET": "query" else: "command"
      if r.kind != want:
        result.add "route " & r.name & " names a " & r.kind & "; a " & r.meth & " route rests on a " & want
      for n in r.blocks:
        if m.find(n).kind != r.kind:
          result.add "route " & r.name & " names " & r.kind & " " & n & ", which studiodesk.em does not have"
        elif r.called and not m.onScreens(n, pageScreens):
          result.add "the page calls " & r.name & ", which rests on " & n & ", but no screen of the page lists " & n
        elif not r.called and not m.onScreens(n, pagelessScreens):
          result.add "the page never calls " & r.name & ", and " & n & " is on no screen without a panel"
  for c in calls:
    if c.meth == "?":
      result.add "the page names " & c.path & " in a way this check cannot read: call it with `api(METHOD, PATH, ...)`"
    elif routes.filterIt(it.meth == c.meth and it.path == c.path).len == 0:
      result.add "the page calls " & c.meth & " " & c.path & ", which is not a route"
  for s in pageScreens:
    for n in m.find(s).edge("commands") & m.find(s).edge("queries"):
      if not routes.anyIt(n in it.blocks and it.called):
        result.add "the page's screen " & s & " lists " & n & ", but no route the page calls rests on it"
  for s in pagelessScreens:
    for n in m.find(s).edge("commands") & m.find(s).edge("queries"):
      if not routes.anyIt(n in it.blocks):
        result.add "screen " & s & " lists " & n & ", but no route rests on it"

suite "the page's routes are the screens' commands and queries":
  let m = modelOf("studiodesk.em")
  let routes = readRoutes(readFile(paraDir / "studioapi.nim"))
  let page = readFile(paraDir / "studio" / "index.html")
  let calls = readCalls(page)

  test "the routes, the page's calls and the screens of studiodesk.em agree":
    check routeDrift(routes, calls, m) == newSeq[string]()

  test "every route and every call was read":
    check routes.len > 0 and calls.len > 0
    check routes.allIt(it.meth in ["GET", "POST"])
    check page.count("\"/api/") == calls.len
    let step = page[page.find("async function startStep(") .. ^1]
    check "await api(\"POST\", path, body)" in step[0 ..< step.find("\n}")]

  test "the routes with no panel on the page yet are the HelperApi screen's three, and the page calls none of them":
    let uncalled = routes.filterIt((meth: it.meth, path: it.path) notin calls).mapIt(it.name)
    check uncalled == @["GET /api/helpers", "POST /api/helper/start", "POST /api/helper/stop"]
    for r in routes:
      if r.name in uncalled:
        check r.blocks.len > 0
        check r.blocks.allIt(m.onScreens(it, pagelessScreens))

  test "a page or a route that drifts is told so":
    check routeDrift(routes, calls & @[(meth: "POST", path: "/api/chat/rename")], m).anyIt(
      "the page calls POST /api/chat/rename, which is not a route" in it)
    check routeDrift(routes, readCalls("const u = base + \"/api/state\";"), m).anyIt("cannot read" in it)
    check routeDrift(routes, readCalls("fetch(\"/api/play/stop\", { method: \"POST\" });"), m).anyIt("cannot read" in it)
    var untagged = routes
    untagged[0].kind = ""
    check routeDrift(untagged, calls, m).anyIt("names no model block" in it)
    var renamed = routes
    for r in renamed.mitems:
      if r.path == "/api/chat/send": r.blocks = @["SendMessage"]
    check routeDrift(renamed, calls, m).anyIt("names command SendMessage, which studiodesk.em does not have" in it)
    check routeDrift(renamed, calls, m).anyIt("the page's screen ChatPanel lists StartTurn" in it)
    var wrongKind = routes
    for r in wrongKind.mitems:
      if r.path == "/api/play" and r.meth == "GET": (r.kind, r.blocks) = ("command", @["StopPlay"])
    check routeDrift(wrongKind, calls, m).anyIt("GET /api/play names a command" in it)
    check routeDrift(routes, calls & @[(meth: "POST", path: "/api/helper/start")], m).anyIt(
      "rests on StartHelper, but no screen of the page lists StartHelper" in it)
    check routeDrift(routes.filterIt(it.path != "/api/helper/stop"), calls, m).anyIt(
      "screen HelperApi lists StopHelper, but no route rests on it" in it)
    check routeDrift(routes & @[Route(meth: "GET", path: "/api/secret", kind: "none")], calls, m).anyIt(
      "the page never calls GET /api/secret" in it)

suite "the desk's own copies of the shell's rules":
  test "a game's name is the one `para new` makes":
    for name in ["", "pong", "space_frogs", "a", "a1_b2", "Pong", "1st", "_x", "space frogs", "../x", "a-b", "é", "x\n", "a".repeat(41), "z9"]:
      check goodGameName(name) == validGameName(name)

  test "a save's note is one short line":
    check validNote("")
    check validNote("the ship moves")
    check validNote("x".repeat(maxNoteChars))
    check not validNote("x".repeat(maxNoteChars + 1))
    for bad in ["two\nlines", "tab\there", "bell\x07", "del\x7f"]: check not validNote(bad)
