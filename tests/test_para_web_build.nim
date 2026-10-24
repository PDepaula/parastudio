# Tests for the web build tooling (web ship 2): `para build`'s --define
# validation, tools/web/build.sh's argument handling (rejected before any
# compiler runs, so no emcc is needed), postbuild.mjs's build id and
# `build.json`, `para web pack`'s zip (what a static host needs, reproducible,
# never a -d:dev build, whatever the spelling of the define). Everything runs
# on a throwaway directory under tmp/; no wasm is compiled.

import std/[unittest, os, strutils, json]
import tools/para/nimutil
import tools/para/webbuild
import tools/para/webpackcmd
import tools/para/buildcmd
import tools/para/websmokecmd

const scratch = "tmp" / "web-build-scratch"

proc fakeBuild(dir, game: string, defines: seq[string] = @[], extra: seq[string] = @[]) =
  ## What `buildWeb` leaves behind, with a stand-in wasm and js, via the real
  ## postbuild step.
  removeDir(dir)
  createDir(dir)
  writeFile(dir / (game & ".js"), "// js\n")
  writeFile(dir / (game & ".wasm"), "\x00asm fake wasm bytes")
  var args = @["tools/web/postbuild.mjs", "--dir", dir, "--title", "A & B"]
  for d in defines: args.add @["--define", d]
  args.add extra
  let r = runCaptured("node", args)
  doAssert r.exitCode == 0, r.output

suite "web build flags":
  test "isValidDefine takes NAME and NAME=VALUE, nothing a shell or nim would read as more":
    for good in ["hubRun", "hubRun=true", "masterVolumeDefine=60", "x_1", "v=1.5", "a=b-c:d"]:
      check isValidDefine(good)
    for bad in ["", "=1", "1x", "a b", "a;b", "a=", "a=b c", "-d:x", "a=$(id)", "a\"b"]:
      check not isValidDefine(bad)

  test "para build: --define needs a valid define, --define, --title and --debug are web-only, --release and --debug exclude each other":
    check runBuild(@["--define"]).code == 2
    let bad = runBuild(@["--target", "web", "--define", "a;b"])
    check bad.code == 2
    check bad.output.contains("bad --define")
    let native = runBuild(@["--define", "hubRun"])
    check native.code == 2
    check native.output.contains("--define applies to --target web only")
    check runBuild(@["--debug"]).code == 2
    check runBuild(@["--title", "x"]).code == 2
    check runBuild(@["--target", "web", "--release", "--debug"]).code == 2

  test "para build: --feedback-url needs a URL and is web-only":
    check runBuild(@["--feedback-url"]).code == 2
    let native = runBuild(@["--feedback-url", "https://forms.example/x"])
    check native.code == 2
    check native.output.contains("--feedback-url applies to --target web only")

  test "para web smoke: the same flags, validated before anything builds":
    check runWebSmoke(@["--define", "a;b"]).code == 2
    check runWebSmoke(@["--bogus"]).code == 2

  test "build.sh rejects a bad --define, an unknown flag and a missing SRC/OUT with exit 2":
    check runCaptured("bash", @["tools/web/build.sh", "--define", "a;b", "x.nim", "out"]).exitCode == 2
    check runCaptured("bash", @["tools/web/build.sh", "--bogus", "x.nim", "out"]).exitCode == 2
    check runCaptured("bash", @["tools/web/build.sh", "x.nim"]).exitCode == 2

suite "postbuild: index.html, build id, build.json":
  test "one game per directory: index.html carries the title and the build id, build.json the facts":
    let dir = scratch / "post"
    fakeBuild(dir, "g", @["hubRun", "x=1"])
    let html = readFile(dir / "index.html")
    check html.contains("<title>A &amp; B</title>")
    check html.contains("<script src=\"g.js\"></script>")
    let info = parseFile(dir / "build.json")
    let id = info["id"].getStr
    check id.endsWith("-release-hubRun-x_1")
    check html.contains("<meta name=\"paraloop-build\" content=\"" & id & "\">")
    check info["game"].getStr == "g"
    check info["mode"].getStr == "release"
    check info["defines"].getElems.len == 2
    check fileExists(dir / "manifest.webmanifest")
    check fileExists(dir / "icon-192.png")

  test "the default id is <commit>[-dirty]-<mode>-<defines>, no timestamp":
    let dir = scratch / "id"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "g.js", "")
    let r = runCaptured("node", @["tools/web/postbuild.mjs", "--dir", dir, "--mode", "debug",
                                   "--define", "hubRun", "--define", "a=1"])
    check r.exitCode == 0
    let id = parseFile(dir / "build.json")["id"].getStr
    check id.endsWith("-debug-a_1-hubRun")
    check id.len > "-debug-a_1-hubRun".len
    # the same inputs give the same id (the second run reads the same commit)
    discard runCaptured("node", @["tools/web/postbuild.mjs", "--dir", dir, "--mode", "debug",
                                   "--define", "hubRun", "--define", "a=1"])
    check parseFile(dir / "build.json")["id"].getStr == id

  test "the build id is visible page text, and there is no feedback link without --feedback-url":
    let dir = scratch / "info"
    fakeBuild(dir, "g", @["hubRun"])
    let html = readFile(dir / "index.html")
    let id = parseFile(dir / "build.json")["id"].getStr
    check html.contains("<span id=\"buildid\">" & id & "</span>")
    check not html.contains("Send feedback")
    check not html.contains("id=\"feedback\"")
    check not html.contains("{{PARALOOP_")
    # an empty URL is the same as none (a workflow passes the variable through)
    fakeBuild(dir, "g", @["hubRun"], @["--feedback-url", ""])
    check not readFile(dir / "index.html").contains("Send feedback")

  test "--feedback-url adds a link outside the canvas with the build id as a build parameter":
    let dir = scratch / "fb"
    fakeBuild(dir, "g", @["hubRun"], @["--feedback-url", "https://forms.example/f?usp=pp&entry.1=x"])
    let html = readFile(dir / "index.html")
    let id = parseFile(dir / "build.json")["id"].getStr
    check html.contains("<a id=\"feedback\" href=\"https://forms.example/f?usp=pp&amp;entry.1=x&amp;build=" &
                        id & "\" target=\"_blank\" rel=\"noopener noreferrer\">Send feedback</a>")
    check html.find("</canvas>") < html.find("id=\"feedback\"")
    # a URL with no query gets `?build=`, and a fragment stays last
    fakeBuild(dir, "g", @["hubRun"], @["--feedback-url", "https://forms.example/f#top"])
    check readFile(dir / "index.html").contains("href=\"https://forms.example/f?build=" & id & "#top\"")

  test "--feedback-url takes only an http(s) URL, and says so":
    let dir = scratch / "fbbad"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "g.js", "")
    for bad in ["javascript:alert(1)", "forms.example/f", "ftp://forms.example/f", "data:text/html,x"]:
      let r = runCaptured("node", @["tools/web/postbuild.mjs", "--dir", dir, "--feedback-url", bad])
      check r.exitCode == 1
      check r.output.contains("--feedback-url must be an http(s) URL")
    let missing = runCaptured("node", @["tools/web/postbuild.mjs", "--dir", dir, "--feedback-url"])
    check missing.exitCode == 1
    check missing.output.contains("--feedback-url needs a URL")

  test "two games in one directory is an error, not a silent pick":
    let dir = scratch / "two"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "a.js", "")
    writeFile(dir / "b.js", "")
    let r = runCaptured("node", @["tools/web/postbuild.mjs", "--dir", dir])
    check r.exitCode == 1
    check r.output.contains("exactly one")

suite "para web pack":
  test "zips exactly what a static host needs and says what it left out":
    let dir = scratch / "pack"
    fakeBuild(dir, "g")
    writeFile(dir / "stale-other-game.wasm", "stale")
    let zip = scratch / "pack.zip"
    let r = runWebPack(@["--dir", dir, "--out", zip])
    check r.code == 0
    let id = parseFile(dir / "build.json")["id"].getStr
    check r.output.startsWith("pack: ok, wrote " & zip & ", build " & id)
    for name in ["index.html", "g.js", "g.wasm", "manifest.webmanifest", "icon-192.png", "icon-512.png"]:
      check r.output.contains(name)
    check r.output.contains("left out: ")
    check r.output.contains("build.json")
    check r.output.contains("stale-other-game.wasm")
    let bytes = readFile(zip)
    check bytes.startsWith("PK\3\4")
    check not bytes.contains("build.json")
    check not bytes.contains("stale-other-game.wasm")

  test "the same build packs to the same bytes":
    let dir = scratch / "repro"
    fakeBuild(dir, "g")
    let a = scratch / "repro-a.zip"
    let b = scratch / "repro-b.zip"
    check runWebPack(@["--dir", dir, "--out", a]).code == 0
    check runWebPack(@["--dir", dir, "--out", b]).code == 0
    check readFile(a) == readFile(b)

  test "a -d:dev build is refused in every spelling: it carries the dev control channel":
    for spelling in ["dev", "dev=1", "dev=true", "Dev", "d_ev"]:
      let dir = scratch / "dev"
      fakeBuild(dir, "g", @[spelling])
      let zip = scratch / "dev.zip"
      let r = runWebPack(@["--dir", dir, "--out", zip])
      check r.code == 2
      check r.output.contains("-d:dev")
      check not fileExists(zip)

  test "isDevDefine reads a define name the way nim's defined() does":
    for dev in ["dev", "dev=1", "dev=true", "Dev", "DEV", "dEv=0", "d_ev", "D_E_V=x"]:
      check isDevDefine(dev)
    for other in ["devMode", "dev2", "hubRun", "mode=dev", "xdev", "de", ""]:
      check not isDevDefine(other)

  test "a define that only starts with dev is not a dev build":
    let dir = scratch / "devish"
    fakeBuild(dir, "g", @["devMode"])
    check runWebPack(@["--dir", dir, "--out", scratch / "devish.zip"]).code == 0

  test "no build.json is a usage error naming the build command":
    let dir = scratch / "none"
    removeDir(dir)
    createDir(dir)
    let r = runWebPack(@["--dir", dir])
    check r.code == 2
    check r.output.contains("para build --target web")

  test "a missing file stops the pack, naming it":
    let dir = scratch / "missing"
    fakeBuild(dir, "g")
    removeFile(dir / "g.wasm")
    let r = runWebPack(@["--dir", dir, "--out", scratch / "missing.zip"])
    check r.code == 1
    check r.output.contains("g.wasm")

removeDir(scratch)
