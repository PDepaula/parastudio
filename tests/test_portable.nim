# Tests for the portable Windows zip's assembly and release plumbing (tools/launcher/build_portable.py,
# .github/workflows/portable.yml). The script is imported and its own functions run with python3
# (nothing is downloaded: the network is replaced by a stand-in), the workflow is parsed with PyYAML
# into a normalized model and its meaning asserted, and the script's --plan and --check-zip modes are
# run as the real command. Each skips when python3 (or PyYAML, for the workflow) is missing. That the
# zip really builds and its launcher really runs on Windows is checked by the `portable` workflow on
# a hosted Windows runner; that the launcher finds the folders the script makes is checked in
# tests/test_launcher_exe.nim.

import std/[unittest, os, osproc, strutils, tempfiles, json]

const
  script = "tools" / "launcher" / "build_portable.py"
  workflow = ".github" / "workflows" / "portable.yml"

let python = findExe("python3")

proc py(dir, body: string, args: varargs[string]): tuple[output: string, exitCode: int] =
  ## Runs `body` with the script imported as `bp`, in isolated mode.
  let f = dir / "helper.py"
  writeFile(f, """
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("bp", sys.argv[1])
bp = importlib.util.module_from_spec(spec); spec.loader.exec_module(bp)
""" & body)
  var cmd = "PYTHONDONTWRITEBYTECODE=1 python3 -I " & quoteShell(f) & " " & quoteShell(absolutePath(script))
  for a in args: cmd.add " " & quoteShell(a)
  execCmdEx(cmd)

suite "portable zip: downloads are checked":
  test "a download is used only when it matches both the pinned and the published checksum":
    if python.len == 0: skip()
    else:
      let dir = createTempDir("portable-fetch-", "")
      defer: removeDir(dir)
      let r = py(dir, """
import hashlib, io, pathlib, tempfile
body = b"the file"
good = hashlib.sha256(body).hexdigest()
class R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False
def run(pinned, published):
    served = {"https://x.test/f.zip": body, "https://x.test/f.zip.sha256": (published + "  f.zip\n").encode()}
    bp.open_url = lambda url, timeout: R(served[url])
    cache = pathlib.Path(tempfile.mkdtemp())
    try:
        got = bp.fetch("https://x.test/f.zip", pinned, cache)
        return {"used": got.exists()}
    except SystemExit as e:
        return {"stopped": e.code, "left": (cache / "f.zip").exists()}
bad = "0" * 64
print(json.dumps({"ok": run(good, good), "pin": run(bad, good), "pub": run(good, bad),
                  "pins": [len(bp.NIM_ZIP_SHA256), len(bp.MINGW_SHA256)]}))
""")
      check r.exitCode == 0
      let j = parseJson(r.output.strip.splitLines[^1])
      check j["ok"]["used"].getBool
      check j["pin"]["stopped"].getInt == 1
      check not j["pin"]["left"].getBool
      check j["pub"]["stopped"].getInt == 1
      check not j["pub"]["left"].getBool
      check j["pins"][0].getInt == 64
      check j["pins"][1].getInt == 64

  test "finish.exe, Nim's installer, is not allowed in the zip":
    if python.len == 0: skip()
    else:
      let dir = createTempDir("portable-forbid-", "")
      defer: removeDir(dir)
      let r = py(dir, "print(json.dumps(bp.FORBIDDEN))")
      check r.exitCode == 0
      check "Paraloop-Studio/nim-2.2.10/finish.exe" in r.output

suite "portable zip: the workflow's promises":
  let have = python.len > 0 and execCmdEx("python3 -c 'import yaml'").exitCode == 0
  var wf = newJNull()
  if have:
    let dir = createTempDir("portable-wf-", "")
    defer: removeDir(dir)
    let helper = dir / "wf.py"
    writeFile(helper, "import json, sys, yaml\nprint(json.dumps(yaml.safe_load(open(sys.argv[1])), default=str))\n")
    let r = execCmdEx("python3 -I " & quoteShell(helper) & " " & quoteShell(workflow))
    doAssert r.exitCode == 0, r.output
    wf = parseJson(r.output)

  proc steps(job: string): seq[JsonNode] = wf["jobs"][job]["steps"].getElems
  proc runOf(s: JsonNode): string = s{"run"}.getStr

  test "it runs on a Windows runner on pull requests, main, release tags and by hand":
    if not have: skip()
    else:
      # YAML 1.1 reads the key `on` as the boolean true.
      let on = if wf.hasKey("true"): wf["true"] else: wf["on"]
      var triggers: seq[string]
      for k, _ in on: triggers.add k
      check triggers.len == 3
      for t in ["pull_request", "push", "workflow_dispatch"]: check t in triggers
      check on["push"]["tags"].getElems.len == 1
      check on["push"]["tags"][0].getStr == "portable-v*"
      check wf["jobs"]["portable"]["runs-on"].getStr == "windows-latest"

  test "the signing hook sits between compiling and assembling, and is off until enabled":
    if not have: skip()
    else:
      let ss = steps("portable")
      var compile, hook, assemble = -1
      for i, s in ss:
        if "--launcher-only" in runOf(s): compile = i
        if s{"uses"}.getStr.startsWith("Azure/artifact-signing-action"): hook = i
        if "build_portable.py --launcher " in runOf(s) and "--launcher-only" notin runOf(s): assemble = i
      check compile >= 0
      check hook > compile
      check assemble > hook
      check "SIGNING HOOK" in ss[hook]["name"].getStr
      check ss[hook]["if"].getStr.replace(" ", "") == "${{vars.PORTABLE_SIGNING=='enabled'}}"

  test "nothing is published without a person: tag-only, draft-only, write access only there":
    if not have: skip()
    else:
      check wf["permissions"].len == 1
      check wf["permissions"]["contents"].getStr == "read"
      for name, job in wf["jobs"]:
        let writes = job.hasKey("permissions") and job["permissions"]{"contents"}.getStr == "write"
        check writes == (name == "draft-release")
      let rel = wf["jobs"]["draft-release"]
      check rel["if"].getStr.contains("refs/tags/portable-v")
      check rel["needs"].getStr == "portable"
      var creates = 0
      for name, job in wf["jobs"]:
        for s in job["steps"]:
          let r = runOf(s)
          creates += r.count("gh release create")
          check "gh release edit" notin r
          check "--latest" notin r
          check "--prerelease=false" notin r
          if "gh release create" in r: check "--draft" in r
      check creates == 1

suite "portable zip: the script's offline modes":
  test "--plan names the downloads, the checksums and the zip":
    if python.len == 0: skip()
    else:
      let (o, code) = execCmdEx("PYTHONDONTWRITEBYTECODE=1 python3 " & quoteShell(script) & " --plan")
      check code == 0
      check o.contains("https://nim-lang.org/download/nim-2.2.10_x64.zip")
      check o.contains("https://nim-lang.org/download/mingw64.7z")
      check o.contains("windows-x64.zip")

  test "--check-zip passes a zip with the layout and names what is missing from one without":
    if python.len == 0: skip()
    else:
      let dir = createTempDir("portable-zip-", "")
      defer: removeDir(dir)
      let maker = dir / "make.py"
      # Build the two zips from the script's own REQUIRED list, importing it rather than copying it.
      writeFile(maker, """
import importlib.util, sys, zipfile
spec = importlib.util.spec_from_file_location("bp", sys.argv[1])
bp = importlib.util.module_from_spec(spec); spec.loader.exec_module(bp)
with zipfile.ZipFile(sys.argv[2], "w") as z:
    for n in bp.REQUIRED: z.writestr(n, "x")
with zipfile.ZipFile(sys.argv[3], "w") as z:
    for n in bp.REQUIRED[1:]: z.writestr(n, "x")
    z.writestr(bp.FORBIDDEN[0], "x")
""")
      let good = dir / "good.zip"
      let bad = dir / "bad.zip"
      let made = execCmdEx("PYTHONDONTWRITEBYTECODE=1 python3 " & quoteShell(maker) & " " & quoteShell(script) & " " & quoteShell(good) & " " & quoteShell(bad))
      check made.exitCode == 0
      let ok = execCmdEx("PYTHONDONTWRITEBYTECODE=1 python3 " & quoteShell(script) & " --check-zip " & quoteShell(good))
      check ok.exitCode == 0
      check ok.output.contains("layout ok")
      let no = execCmdEx("PYTHONDONTWRITEBYTECODE=1 python3 " & quoteShell(script) & " --check-zip " & quoteShell(bad))
      check no.exitCode == 1
      check no.output.contains("missing: Paraloop-Studio/Paraloop-Studio.exe")
      check no.output.contains("must not be in the zip: Paraloop-Studio/nim-2.2.10/finish.exe")
