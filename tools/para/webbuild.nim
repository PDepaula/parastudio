# The web build the `para` commands share: `para build --target web`,
# `para web smoke` and `para web pack` all go build.sh -> postbuild.mjs through
# `buildWeb`, so the artifact a smoke run checks is the one `pack` zips, and a
# game's web output lives in one directory (`tmp/web/<game>/`: `index.html`,
# `<game>.js`, `<game>.wasm`, manifest, icons, `build.json`).

import std/[os, json, strutils, strformat]
import nimutil
import games

const webRoot* = "tmp" / "web"

proc webOutDir*(game: string): string =
  webRoot / game

proc isValidDefine*(d: string): bool =
  ## `NAME` or `NAME=VALUE`, the shape build.sh accepts (an identifier, then
  ## an optional value of letters, digits and `_.:-`).
  let parts = d.split('=', 1)
  let name = parts[0]
  if name.len == 0 or name[0] notin IdentStartChars or
      not name.allCharsInSet(IdentChars): return false
  parts.len == 1 or (parts[1].len > 0 and parts[1].allCharsInSet(IdentChars + {'.', ':', '-'}))

type WebBuild* = object
  ok*: bool
  failedStep*: string ## "build" or "postbuild" when not `ok`
  output*: string     ## the failing step's whole output; the postbuild's when `ok`
  id*: string         ## `build.json`'s build id
  dir*: string
  wasmBytes*: int64

proc buildWeb*(game: Game, debug: bool, defines: seq[string], title: string,
               feedbackUrl = ""): WebBuild =
  ## Compiles `game` to wasm (release unless `debug`), then renders the shell
  ## and `build.json` next to it. The output directory is emptied first, so it
  ## only ever holds this build. A non-empty `feedbackUrl` puts a "Send
  ## feedback" link on the page (postbuild.mjs checks it is an http(s) URL).
  result.dir = webOutDir(game.name)
  if dirExists(result.dir): removeDir(result.dir)
  createDir(result.dir)

  var buildArgs = @["tools/web/build.sh"]
  if debug: buildArgs.add "--debug"
  for d in defines: buildArgs.add @["--define", d]
  buildArgs.add @[game.source, result.dir / game.name]
  let build = runCaptured("bash", buildArgs)
  if build.exitCode != 0:
    return WebBuild(failedStep: "build", output: build.output, dir: result.dir)

  var postArgs = @["tools/web/postbuild.mjs", "--dir", result.dir, "--title", title,
                   "--mode", (if debug: "debug" else: "release")]
  for d in defines: postArgs.add @["--define", d]
  if feedbackUrl.len > 0: postArgs.add @["--feedback-url", feedbackUrl]
  let post = runCaptured("node", postArgs)
  if post.exitCode != 0:
    return WebBuild(failedStep: "postbuild", output: post.output, dir: result.dir)

  result.ok = true
  result.output = post.output
  try:
    result.id = parseFile(result.dir / "build.json")["id"].getStr
  except CatchableError:
    discard
  let wasm = result.dir / (game.name & ".wasm")
  if fileExists(wasm): result.wasmBytes = getFileSize(wasm)

proc readBuildInfo*(dir: string): JsonNode =
  ## `dir/build.json`, or `nil` when there is none (or it is not JSON).
  try:
    result = parseFile(dir / "build.json")
  except CatchableError:
    result = nil

proc describe*(w: WebBuild): string =
  &"wrote {w.dir / \"index.html\"}, {w.wasmBytes} bytes of wasm, build {w.id}"
