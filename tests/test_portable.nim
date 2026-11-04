# Tests for the portable Windows zip's assembly and release plumbing (tools/launcher/build_portable.py,
# .github/workflows/portable.yml), read as text and, for the script's own offline modes, run with
# python3 when there is one (it downloads nothing in --plan or --check-zip). That the zip really
# builds and its launcher really runs is checked by the `portable` workflow on a hosted Windows
# runner, which these tests cannot do: they keep the pieces that must agree in agreement (the Nim
# checksum pinned in the script and in the batch launcher), and the promises the workflow makes
# (a marked signing hook, an unsigned build says so, nothing public without a person).

import std/[unittest, os, osproc, strutils, tempfiles]

const
  script = "tools" / "launcher" / "build_portable.py"
  workflow = ".github" / "workflows" / "portable.yml"
  bat = "tools" / "launcher" / "launch.bat"

proc quoted(text, key: string): string =
  ## The value in `KEY = "value"` / `set "KEY=value"` style lines.
  for l in text.splitLines:
    let t = l.strip
    if t.startsWith(key & " = \""): return t[(key.len + 4) .. ^2]
    if t.startsWith("set \"" & key & "="): return t[(key.len + 6) .. ^2]

let python = findExe("python3")

suite "portable zip: the pins agree":
  let py = readFile(script)
  let batText = readFile(bat)

  test "the Nim version and its zip checksum are the batch launcher's":
    check quoted(py, "NIM_VERSION") == quoted(batText, "NIM_VERSION")
    check quoted(py, "NIM_ZIP_SHA256") == quoted(batText, "NIM_ZIP_SHA256")
    check quoted(py, "NIM_ZIP_SHA256").len == 64
    check quoted(py, "MINGW_SHA256").len == 64

  test "the native launcher looks for the folders the script makes":
    let nimSrc = readFile("tools" / "launcher" / "launch.nim")
    check nimSrc.contains("nimVersion = \"" & quoted(py, "NIM_VERSION") & "\"")
    check nimSrc.contains("\"mingw64\" / \"bin\"")
    check nimSrc.contains("\"nim-\" & nimVersion")
    check nimSrc.contains("exeDir / \"parastudio\"")
    check py.contains("FOLDER = \"Paraloop-Studio\"")
    check py.contains("EXE = \"Paraloop-Studio.exe\"")

  test "downloads are checked against the pinned and the published checksum, and finish.exe stays out":
    check py.contains("actual != pinned or actual != published")
    check py.contains("finish.exe")
    check py.contains("FORBIDDEN")

suite "portable zip: the workflow's promises":
  let wf = readFile(workflow)

  test "it builds on a Windows runner on pull requests and by hand":
    check wf.contains("runs-on: windows-latest")
    check wf.contains("pull_request:")
    check wf.contains("workflow_dispatch:")

  test "the signing hook is marked, off until enabled, and sits between compiling and assembling":
    check wf.contains("SIGNING HOOK")
    check wf.contains("vars.PORTABLE_SIGNING == 'enabled'")
    check wf.find("Compile the launcher") < wf.find("SIGNING HOOK")
    check wf.find("SIGNING HOOK") < wf.find("Assemble the zip")
    check wf.contains("Get-AuthenticodeSignature")
    check wf.contains("PORTABLE_REQUIRE_SIGNED")

  test "the smoke run uses a PATH with no compiler, a clean home, and never answers an offer":
    check wf.contains("is on the test PATH; the test would prove nothing")
    check wf.contains("PARALOOP_LAUNCHER_UNATTENDED")
    check wf.contains("friend-home")

  test "nothing is published without a person: tag-only, draft-only, write access only there":
    check wf.count("gh release create") == 1
    check wf.contains("--draft")
    check not wf.contains("--latest")
    check not wf.contains("gh release edit")
    check not wf.contains("--prerelease=false")
    check wf.contains("startsWith(github.ref, 'refs/tags/portable-v')")
    check wf.count("contents: write") == 1
    check wf.find("contents: write") > wf.find("draft-release:")

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
