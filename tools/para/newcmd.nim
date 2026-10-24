# `para new <game>`: creates games/<game>/ from template/ (engine report
# §3.3 `template/` row, task 1.9), substituting the `__GAME__` placeholder
# for the game's name in file contents and renaming `template.nim` /
# `tests/test_template.nim` to match. Nothing else needs registering:
# `games.listGames` already walks `games/<name>/<name>.nim`, so `para test`,
# `para build --game`, `para web smoke --game` and `para --game` find it as
# soon as the files exist.
#
# The new game is also its own git repository (`git init` inside games/<game>/,
# with the template's `.gitignore`), so `para save`, `para check` and
# `para backup` keep its work there and never touch the repository around
# `games/`. No first commit is made: the first `para save` is the first save
# point. If git is missing the game is still created, and `para new` says so.

import std/[os, strutils, strformat, sequtils]
import art/[clihelpers, toon]
import games
import nimutil

type Run = clihelpers.Run

const
  placeholder = "__GAME__"
  templateDir = "template"

const newHelp = "para new <game>\n" &
  "  creates games/<game>/ from template/, ready for `para test --filter games/<game>/` and `para web smoke --game <game>`\n" &
  "  includes games/<game>/reports/, where read-only scouts write one <topic>.md each\n" &
  "  makes games/<game>/ a git repository of its own (with a .gitignore), where `para save` keeps its save points\n" &
  "  <game>: lowercase letters, digits and \"_\", starting with a letter (a valid Nim module name)\n"

proc validGameName(name: string): bool =
  ## Lowercase ascii letters, digits and `_`, starting with a letter: a name
  ## `nim c games/<name>/<name>.nim` can compile. Nim requires a compiled
  ## file's module name (its filename, sans extension) to be a valid Nim
  ## identifier -- a hyphen fails with "invalid module name", not just an
  ## import-time issue, and `<name>.nim` is also `para build`/`para web
  ## smoke`'s compile target -- so this is stricter than a plain directory
  ## name would need to be.
  name.len > 0 and name[0] in {'a'..'z'} and
    name.allIt(it in {'a'..'z', '0'..'9', '_'})

proc destPath(rel, gameName: string): string =
  ## `template.nim` -> `<game>.nim`; `tests/test_template.nim` ->
  ## `tests/test_<game>.nim`; anything else keeps its relative path.
  case rel
  of templateDir & ".nim": gameName & ".nim"
  of "tests" / ("test_" & templateDir & ".nim"): "tests" / ("test_" & gameName & ".nim")
  else: rel

proc copyTemplate(destDir, gameName: string) =
  for path in walkDirRec(templateDir, yieldFilter = {pcFile}):
    let rel = path.relativePath(templateDir)
    let dest = destDir / destPath(rel, gameName)
    createDir(dest.parentDir)
    writeFile(dest, readFile(path).replace(placeholder, gameName))

proc initRepo(dest: string): string =
  ## `git init` inside the new game, never anywhere else. "" when it worked, else the
  ## sentence to tell the person (the game itself is fine without it).
  if existsEnv("GIT_DIR") or existsEnv("GIT_WORK_TREE"):
    return "git is pointed at another repository by GIT_DIR/GIT_WORK_TREE, so the game did not get a repository of its own"
  var r = runCaptured("git", @["init", "-q", "-b", "main"], dest)
  if r.exitCode != 0 and r.exitCode != 127:
    r = runCaptured("git", @["init", "-q"], dest) # a git older than 2.28 has no -b
  if r.exitCode == 127:
    return "git is not installed, or is not on the PATH, so the game did not get a repository of its own yet"
  if r.exitCode != 0:
    return "git could not make a repository for the game: " & lastLines(r.output, 3).strip
  ""

proc runNew*(args: seq[string]): Run =
  var name = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--help", "-h":
      return (newHelp, 0)
    else:
      if a.startsWith("-"):
        return errorOut(&"unknown flag \"{a}\"", @["Valid flags: --help"])
      if name.len > 0:
        return errorOut("para new takes exactly one game name", @["Run `para new --help`"])
      name = a
    inc i

  if name.len == 0:
    return errorOut("para new needs a game name", @["Run `para new --help`"])
  if not validGameName(name):
    return errorOut("\"" & name & "\" is not a valid game name",
      @["Use lowercase letters, digits and \"_\", starting with a letter " &
        "(it must compile as a Nim module name)"])
  if not dirExists(templateDir):
    return errorOut(templateDir & "/ not found", @["Run `para new` from the repo root"])

  for g in listGames():
    if g.name == name:
      return errorOut("\"" & name & "\" already exists (" & g.dir & ")", @[])

  let dest = "games" / name
  copyTemplate(dest, name)
  let repoProblem = initRepo(dest)

  result.output = "new: wrote " & dest & "\n"
  if repoProblem.len > 0:
    result.output.add "note: " & repoProblem & "\n"
  result.output.add toonHelp(@[
    (if repoProblem.len == 0: &"{dest}/ is a git repository of its own: `para save` keeps its save points there"
     else: "Once git works, run `git init` inside " & dest & " so `para save` has somewhere to save to"),
    &"Run `para test --filter games/{name}/` to run its tests",
    &"Scouts write their reports to games/{name}/reports/<topic>.md (see its README.md)",
    &"Run `para web smoke --game {name}` to check the wasm build",
    &"Run `para build --game {name}` to compile it natively"])
  result.code = 0
