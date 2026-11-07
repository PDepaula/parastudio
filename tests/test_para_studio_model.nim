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
    for name in ["StopTurn", "StepClock", "TurnRunner", "PlayWindow", "PlayRunner", "PlayNow"]:
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
    for panel in ["SetupPanel", "GamesPanel", "ChatPanel", "PlayPanel", "StepsPanel", "ResumePanel", "BackupSheet", "NewGameSheet",
                  "TurnThread", "JobThread", "PlayThread"]:
      check m.find(panel).kind == "screen"

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
