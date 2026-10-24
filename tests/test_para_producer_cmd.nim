# Tests for `para producer-context` (the session-start hook's text) and for the
# owned file contracts around it: AGENTS.md's Start-here block repeats the
# voice core, CLAUDE.md imports AGENTS.md, and the Claude Code / Codex hook
# configs parse as SessionStart command hooks. The command is driven on
# scratch folders, so nothing here compiles or touches the real games/ folder.
# The resume digest is checked on scratch git repos (and on folders that are
# not one, or where git is slow or missing: those facts are then left out).

import std/[unittest, os, strutils, tempfiles, json, tables, times, sequtils, algorithm]
import tools/para/art/clihelpers
import tools/para/nimutil
import tools/para/savepoint
import tools/para/producercmd

const
  repoRoot = currentSourcePath().parentDir.parentDir
  editRules = ["Edit(/games/**)", "Write(/games/**)"] ## the only non-Bash rules in .claude/settings.json

proc put(root, rel, body: string) =
  let p = root / rel
  createDir(p.parentDir)
  writeFile(p, body)

proc newRoot(core = "- Call the friend \"director\".\n"): string =
  ## A scratch checkout holding only the voice core file.
  result = createTempDir("para_producer_", "")
  if core.len > 0: result.put(voiceCoreFile, core)

proc gitOk(root: string, args: varargs[string]): string =
  let r = runCaptured("git", @args, root)
  doAssert r.exitCode == 0, "git " & args.join(" ") & ": " & r.output
  r.output.strip

proc newGitRoot(): string =
  ## A scratch repo with the voice core, one game with a save point and a
  ## full set of notes files, and `tmp/` ignored like the real repo.
  result = newRoot()
  discard gitOk(result, "init", "-q")
  discard gitOk(result, "symbolic-ref", "HEAD", "refs/heads/main")
  discard gitOk(result, "config", "user.name", "Scratch")
  discard gitOk(result, "config", "user.email", "scratch@example.com")
  discard gitOk(result, "config", "commit.gpgsign", "false")
  result.put(".gitignore", "tmp/\n")
  result.put("games/mygame/PLAN.md",
    "# mygame: plan\n\nSpeed: guided\nIn progress:\n\n## Now\n\n- [x] 1. ship moves\n- [ ] 2. rocks that fall\n  - How we'll know: a test\n\n## Next\n\n- [ ] 3. score\n")
  result.put("games/mygame/mygame.nim", "echo 1\n")
  result.put("games/mygame/CHOICES.md",
    "# mygame: choices\n\n## Open\n\n### C2: rock colour?\n\n- A (recommended): grey\n\n### C3: sound?\n\n## Decided\n\n### C1: not an open one\n")
  result.put("games/mygame/PLAYTEST.md",
    "# mygame: playtest notes\n\nNewest first.\n\n## 2026-10-02\n\n- the ship feels slippery\n- fine otherwise\n\n## 2026-10-01\n\n- too slow\n")
  result.put("games/mygame/NOTES.md",
    "# mygame: notes\n\n## What works\n\n- 2026-10-01: arrow keys\n- 2026-10-02: small ship\n\n## What to avoid\n\n- 2026-10-02: no screen shake\n\n## Friend's taste\n")
  discard gitOk(result, "add", ".")
  discard gitOk(result, "commit", "-q", "-m", "start")
  discard gitOk(result, "tag", "-a", "save-mygame-1", "-m", "ship moves")

proc withPath(path: string, body: proc ()) =
  ## Runs `body` with PATH set to `path`, then puts the old one back.
  let old = getEnv("PATH")
  putEnv("PATH", path)
  try: body()
  finally: putEnv("PATH", old)

proc squash(s: string): string =
  ## Whitespace folded to single spaces, so hard-wrapped AGENTS.md lines
  ## compare equal to the one-line bullets of the voice core.
  s.splitWhitespace.join(" ")

suite "producerContext: when it speaks":
  test "a friend's game with a PLAN.md: the voice core, the names, the playbook line":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md",
      "# mygame: plan\n\nSpeed: fast\nCall the friend: boss\nCall the producer: Pat\n\n## Now\n")
    let text = producerContext(root)
    check text.contains("Call the friend \"director\".")
    check text.contains("The game is games/mygame/.")
    check text.contains("Speed: fast; Call the friend: boss; Call the producer: Pat")
    check text.contains("read " & playbookFile)

  test "a game folder without a PLAN.md yet still gets the voice, with no names":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/mygame/mygame.nim", "echo 1\n")
    let text = producerContext(root)
    check text.contains("director")
    check not text.contains("The game is")
    check text.contains(playbookFile)

  test "a developer's game (one that ships a driver) beside the friend's game does not count against it":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/sample/tools/sample_driver.nim", "echo 1\n")
    root.put("games/mygame/PLAN.md", "Speed: guided\n")
    let text = producerContext(root)
    check text.contains("The game is games/mygame/.")
    check text.contains("Speed: guided")

  test "two games with a plan: it says to ask which, and names neither's settings":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/a/PLAN.md", "Call the friend: boss\n")
    root.put("games/b/PLAN.md", "Call the friend: chief\n")
    let text = producerContext(root)
    check text.contains("More than one game has a PLAN.md (a, b)")
    check not text.contains("boss")
    check not text.contains("chief")

  test "run from inside the game, the root is found by walking up":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md", "Speed: fast\n")
    createDir(root / "games" / "mygame" / "tests")
    let r = runProducerContext(@[], root / "games" / "mygame" / "tests")
    check r.code == 0
    check r.output.contains("Speed: fast")

suite "producerContext: when it stays quiet":
  test "engine checkout: only a developer's game under games/":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/sample/tools/sample_driver.nim", "echo 1\n")
    root.put("games/sample/DESIGN.md", "design\n")
    check producerContext(root) == ""
    let r = runProducerContext(@[], root)
    check r == ("", 0)

  test "no games/ folder at all":
    let root = newRoot()
    defer: removeDir(root)
    check producerContext(root) == ""

  test "a plain file under games/ is not a game":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/notes.txt", "hi\n")
    check producerContext(root) == ""

  test "the voice core file is missing or empty":
    let missing = newRoot(core = "")
    defer: removeDir(missing)
    missing.put("games/mygame/PLAN.md", "Speed: fast\n")
    check producerContext(missing) == ""
    check runProducerContext(@[], missing) == ("", 0)
    let empty = newRoot(core = "\n\n")
    defer: removeDir(empty)
    empty.put("games/mygame/PLAN.md", "Speed: fast\n")
    check producerContext(empty) == ""

  test "an odd working directory: nothing, exit 0":
    check producerContext("") == ""
    let nowhere = createTempDir("para_producer_", "")
    removeDir(nowhere)
    check producerContext(nowhere) == ""
    let bare = createTempDir("para_producer_", "")
    defer: removeDir(bare)
    check runProducerContext(@[], bare) == ("", 0)

  test "a voice core that cannot be read (here a directory) is an error: nothing, exit 0":
    let root = newRoot(core = "")
    defer: removeDir(root)
    createDir(root / voiceCoreFile)
    root.put("games/mygame/PLAN.md", "Speed: fast\n")
    check producerContext(root) == ""

  test "a PLAN.md that is a directory is not a plan: the voice, no names":
    let root = newRoot()
    defer: removeDir(root)
    createDir(root / "games" / "mygame" / "PLAN.md")
    let text = producerContext(root)
    check text.contains("director")
    check not text.contains("The game is")

suite "parseHeader: a malformed header never breaks the hook":
  test "the three lines are read, case-insensitively, from the top":
    let h = parseHeader("# x: plan\n\nSPEED: Fast\ncall the friend:  boss \nCall the producer: Pat\n")
    check h.speed == "fast"
    check h.friend == "boss"
    check h.producer == "Pat"

  test "an unknown speed, empty values and lines without a colon are ignored":
    let h = parseHeader("Speed: turbo\nCall the friend:\nCall the producer\nnonsense\n")
    check h == PlanHeader()

  test "control characters are stripped and long names are cut":
    let h = parseHeader("Call the friend: bo\x1b[31mss\t\nCall the producer: " & repeat('x', 200) & "\n")
    check h.friend == "bo[31mss"
    check h.producer.len == 40

  test "lines far below the header are not read":
    let h = parseHeader(repeat("filler\n", 30) & "Speed: fast\n")
    check h.speed == ""

  test "binary junk and an empty file give an empty header":
    check parseHeader("") == PlanHeader()
    check parseHeader("\x00\x01\x02:\xff\xfe\n:::\n") == PlanHeader()

  test "a malformed PLAN.md still gets the voice with the defaults":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md", "\x00\x01 garbage\n::: Speed\n")
    let text = producerContext(root)
    check text.contains("director")
    check not text.contains("From its PLAN.md header")

suite "resume digest: the facts, one line each":
  test "a game with notes files and a save point: every fact is there":
    let root = newGitRoot()
    defer: removeDir(root)
    root.put("games/mygame/mygame.nim", "echo 2\n")
    root.put("games/mygame/extra.nim", "echo 3\n")
    root.put("games/mygame/PLAN.md", readFile(root / "games/mygame/PLAN.md").replace("In progress:", "In progress: 2. rocks that fall"))
    let text = producerContext(root)
    check text.contains("Where things stand")
    check text.contains("- Now (next step on the plan): 2. rocks that fall\n")
    check text.contains("- In progress marker in PLAN.md: 2. rocks that fall\n")
    check text.contains("- Last save point: save point 1 (")
    check text.contains("): ship moves\n")
    check text.contains("- Unsaved changes in games/mygame/: 3 files changed since the last save (")
    check text.contains("PLAN.md")
    check text.contains("- Open choices in CHOICES.md: 2\n")
    check text.contains("- Last playtest note: the ship feels slippery\n")
    check text.contains("- NOTES.md entries: works 2, avoid 1, taste 0\n")
    # the playbook line stays last
    check text.strip.endsWith("read " & playbookFile & " and follow it.")

  test "a game that is a repository of its own: its save point and its changes, not the outer repository's":
    let root = newGitRoot()
    defer: removeDir(root)
    # the game leaves the outer repository for one of its own, with its own save point
    discard gitOk(root, "rm", "-r", "-q", "--cached", "games")
    discard gitOk(root, "tag", "-d", "save-mygame-1")
    root.put(".gitignore", "tmp/\ngames/\n")
    discard gitOk(root, "add", ".gitignore")
    discard gitOk(root, "commit", "-q", "-m", "the game leaves")
    let g = root / "games" / "mygame"
    discard gitOk(g, "init", "-q")
    discard gitOk(g, "config", "user.name", "Scratch")
    discard gitOk(g, "config", "user.email", "scratch@example.com")
    discard gitOk(g, "config", "commit.gpgsign", "false")
    discard gitOk(g, "add", ".")
    discard gitOk(g, "commit", "-q", "-m", "start")
    discard gitOk(g, "tag", "-a", "save-mygame-1", "-m", "ship moves in its own repo")
    var text = producerContext(root)
    check text.contains("- Last save point: save point 1 (")
    check text.contains("): ship moves in its own repo\n")
    check text.contains("- Unsaved changes in games/mygame/: none\n")
    root.put("games/mygame/mygame.nim", "echo 2\n")
    root.put("README.md", "outer change\n")
    text = producerContext(root)
    check text.contains("- Unsaved changes in games/mygame/: 1 file changed since the last save (mygame.nim)")
    check "README.md" notin text

  test "nothing unsaved says so; a clean game has no marker line":
    let root = newGitRoot()
    defer: removeDir(root)
    let text = producerContext(root)
    check text.contains("- Unsaved changes in games/mygame/: none\n")
    check "In progress marker" notin text

  test "an untracked file and a deleted one are both unsaved, names are listed, extra ones counted":
    let root = newGitRoot()
    defer: removeDir(root)
    removeFile(root / "games/mygame/mygame.nim")
    for n in ["a.nim", "b.nim", "c.nim"]: root.put("games/mygame/" & n, "x\n")
    let text = producerContext(root)
    check text.contains("4 files changed since the last save (")
    check text.contains("and 1 more)")

  test "changes outside the game folder do not count as unsaved":
    let root = newGitRoot()
    defer: removeDir(root)
    root.put("README.md", "engine\n")
    check producerContext(root).contains("Unsaved changes in games/mygame/: none")

  test "the latest save point wins, and a game with none says so":
    let root = newGitRoot()
    defer: removeDir(root)
    root.put("games/mygame/mygame.nim", "echo 2\n")
    discard gitOk(root, "commit", "-q", "-am", "more")
    discard gitOk(root, "tag", "-a", "save-mygame-2", "-m", "rocks fall")
    discard gitOk(root, "tag", "-a", "save-mygame-10", "-m", "ten")
    check producerContext(root).contains("Last save point: save point 10 (")
    discard gitOk(root, "tag", "-d", "save-mygame-1", "save-mygame-2", "save-mygame-10")
    check producerContext(root).contains("Last save point: none yet")

  test "each fact is left out when its file or answer is not there":
    let root = newRoot()
    defer: removeDir(root)
    # a PLAN.md straight from the template: placeholders are not facts
    root.put("games/mygame/PLAN.md", readFile(repoRoot / "template" / "PLAN.md").replace("__GAME__", "mygame"))
    root.put("games/mygame/CHOICES.md", readFile(repoRoot / "template" / "CHOICES.md").replace("__GAME__", "mygame"))
    root.put("games/mygame/PLAYTEST.md", readFile(repoRoot / "template" / "PLAYTEST.md").replace("__GAME__", "mygame"))
    let text = producerContext(root)
    check text.contains("Where things stand")
    check "Now (next step" notin text
    check "In progress marker" notin text
    check "Last playtest note" notin text
    check "NOTES.md entries" notin text
    check text.contains("Open choices in CHOICES.md: 0\n")
    # and not a git copy: the git facts are unknown, so absent
    check "Last save point" notin text
    check "Unsaved changes" notin text

  test "no CHOICES.md at all is unknown, not zero":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md", "Speed: fast\n")
    check "Open choices" notin producerContext(root)

  test "a template NOTES.md counts as empty sections":
    check notesSummary(readFile(repoRoot / "template" / "NOTES.md")) == "works 0, avoid 0, taste 0"
    check notesSummary("") == ""

  test "several games: one compact line each, no per-fact lines":
    let root = newGitRoot()
    defer: removeDir(root)
    root.put("games/other/PLAN.md", "## Now\n\n- [ ] 1. a title screen\n")
    root.put("games/other/other.nim", "echo 1\n")
    let text = producerContext(root)
    check text.contains("More than one game has a PLAN.md (mygame, other)")
    check text.contains("- mygame: now: 2. rocks that fall; last save: save point 1 (")
    check text.contains("- other: now: 1. a title screen; ")
    check text.contains("unsaved: 2 files changed since the last save (")
    check "- Now (next step" notin text

  test "the digest does not change the voice, names or playbook lines":
    let root = newGitRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md", "Speed: fast\nCall the friend: boss\n")
    let text = producerContext(root)
    check text.contains("Call the friend \"director\".")
    check text.contains("The game is games/mygame/. From its PLAN.md header: Speed: fast; Call the friend: boss.")

suite "resume digest: the plan, the choices, the playtest notes":
  test "nowStep: the first unticked box, else the first bullet, never a placeholder":
    check nowStep("## Now\n\n- [x] 1. done\n- [ ] 2. next\n- [ ] 3. later\n") == "2. next"
    check nowStep("## Now\n\n- 1. plain bullet\n") == "1. plain bullet"
    check nowStep("## Now\n\n- [x] 1. done\n") == ""
    check nowStep("## Now\n\n- [ ] 1. <first playable, one sentence>\n") == ""
    check nowStep("## Next\n\n- [ ] 1. not now\n") == ""
    check nowStep("") == ""
    check nowStep("## now (this week)\n- [ ] 1. case and suffix\n") == "1. case and suffix"

  test "openChoiceCount: only entries under Open, not the template's blank one":
    check openChoiceCount("## Open\n\n### C1: <question in plain words>\n\n## Decided\n") == 0
    check openChoiceCount("## Open\n\n### C4: a?\n### C5: b?\n\n## Decided\n\n### C1: old\n") == 2
    check openChoiceCount("## Decided\n\n### C1: old\n") == -1
    check openChoiceCount("") == -1
    check openChoiceCount(readFile(repoRoot / "template" / "CHOICES.md")) == 0

  test "lastPlaytestLine: the newest bullet, nothing from the template":
    check lastPlaytestLine("# t\n\nNewest first.\n\n## 2026-10-02\n\n- newest\n- older\n\n## 2026-10-01\n\n- oldest\n") == "newest"
    check lastPlaytestLine(readFile(repoRoot / "template" / "PLAYTEST.md")) == ""
    check lastPlaytestLine("- before any heading\n") == ""
    check lastPlaytestLine("") == ""

  test "the In progress marker is a header line; empty means none":
    check parseHeader("# x: plan\n\nSpeed: fast\nIn progress: 3. rocks\n").inProgress == "3. rocks"
    check parseHeader("# x: plan\nIn progress:\n").inProgress == ""
    check parseHeader(readFile(repoRoot / "template" / "PLAN.md")).inProgress == ""
    check parseHeader("In progress: " & repeat('x', 300)).inProgress.len == 100

suite "resume digest: untrusted text, length, and git that cannot answer":
  test "control characters in the plan, notes and save note never reach the digest":
    let root = newGitRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md", "In progress: step\x1b[31m red\n\n## Now\n\n- [ ] 2. rocks\x07\x1b]0;x\x07 fall\n")
    root.put("games/mygame/PLAYTEST.md", "## d\n\n- fun\x1b[2J\x00 and loud\n")
    discard gitOk(root, "tag", "-a", "save-mygame-2", "-m", "note\x1b[1mbold")
    let text = producerContext(root)
    check '\x1b' notin text
    check '\x07' notin text
    check '\x00' notin text
    check text.contains("rocks]0;x fall")
    check text.contains("Last playtest note: fun[2J and loud")

  test "every value is one line and capped":
    let root = newGitRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md", "## Now\n\n- [ ] " & repeat("w", 500) & "\n")
    root.put("games/mygame/PLAYTEST.md", "## d\n\n- " & repeat("p", 500) & "\n")
    for line in producerContext(root).splitLines:
      if line.startsWith("- "): check line.len < 160

  test "the whole digest is capped, with the voice and playbook lines still there":
    let root = newGitRoot()
    defer: removeDir(root)
    for i in 1 .. 30:
      let g = "game" & $i
      root.put("games/" & g & "/PLAN.md", "## Now\n\n- [ ] " & repeat("s", 90) & "\n")
    let text = producerContext(root)
    let a = text.find("Where things stand")
    let b = text.find("\nBefore replying, read")
    check a > 0 and b > a
    check b - a < 2200
    check text.contains("more games")
    check text.contains("Call the friend \"director\".")

  test "a folder that is not a git copy: the file facts stay, the git facts go":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md", "## Now\n\n- [ ] 2. rocks\n")
    let text = producerContext(root)
    check text.contains("Now (next step on the plan): 2. rocks")
    check "Last save point" notin text
    check "Unsaved changes" notin text

  test "a broken .git folder is unknown too, not an error":
    let root = newRoot()
    defer: removeDir(root)
    createDir(root / ".git")
    root.put("games/mygame/PLAN.md", "## Now\n\n- [ ] 2. rocks\n")
    let text = producerContext(root)
    check text.contains("Now (next step on the plan): 2. rocks")
    check "Unsaved changes" notin text
    check runProducerContext(@[], root).code == 0

  test "git missing from the PATH: the same":
    let root = newGitRoot()
    defer: removeDir(root)
    var text: string
    withPath("", proc () = text = producerContext(root))
    check text.contains("Now (next step on the plan): 2. rocks that fall")
    check "Last save point" notin text
    check "Unsaved changes" notin text
    check text.contains("director")

  when not defined(windows):
    test "a git that hangs is stopped: the git facts are left out, quickly":
      let root = newGitRoot()
      defer: removeDir(root)
      let fake = createTempDir("para_fakegit_", "")
      defer: removeDir(fake)
      writeFile(fake / "git", "#!/bin/sh\nsleep 20\n")
      setFilePermissions(fake / "git", {fpUserRead, fpUserWrite, fpUserExec})
      let oldMs = quickGitMs
      quickGitMs = 150
      defer: quickGitMs = oldMs
      var text: string
      let t0 = epochTime()
      withPath(fake & ":" & getEnv("PATH"), proc () = text = producerContext(root))
      check epochTime() - t0 < 5.0
      check text.contains("Now (next step on the plan): 2. rocks that fall")
      check "Last save point" notin text
      check "Unsaved changes" notin text
      check text.contains("director")

suite "producerContext: PARALOOP_UI=studio":
  test "exactly studio adds one short plain line, before the digest, leaving the rest as it was":
    let root = newGitRoot()
    defer: removeDir(root)
    let plain = producerContext(root, "")
    let studio = producerContext(root, "studio")
    check studio != plain
    check studio.contains(studioLine)
    check studio.contains("press Play")
    check studio.contains("press Check") and studio.contains("press Save")
    check studio.contains("do not give terminal commands")
    check studio.contains("Show me a screenshot") # the screenshot button is named, once
    check studioLine.count("screenshot") == 1
    check "screenshot" notin plain.toLowerAscii # nothing of the studio leaks into the plain text
    check studioLine.len < 300 and "\n" notin studioLine
    # the one line is the only difference, and it sits between the game line and the digest
    check studio.replace("\n" & studioLine & "\n", "") == plain
    check studio.find("The game is games/mygame/.") < studio.find(studioLine)
    check studio.find(studioLine) < studio.find("Where things stand")
    check studio.strip.endsWith("read " & playbookFile & " and follow it.")

  test "absent or any other value changes nothing, byte for byte":
    let root = newGitRoot()
    defer: removeDir(root)
    let plain = producerContext(root, "")
    for other in ["Studio", "STUDIO", " studio", "studio ", "studio\n", "1", "true", "web", "terminal", "studio,web"]:
      check producerContext(root, other) == plain
    check studioLine notin plain

  test "the digest keeps its own cap with the line on: many games, line and playbook line both there":
    let root = newGitRoot()
    defer: removeDir(root)
    for i in 1 .. 30:
      root.put("games/game" & $i & "/PLAN.md", "## Now\n\n- [ ] " & repeat("s", 90) & "\n")
    let text = producerContext(root, "studio")
    let a = text.find("Where things stand")
    let b = text.find("\nBefore replying, read")
    check a > text.find(studioLine) and text.find(studioLine) > 0
    check b - a < 2200
    check text.contains("more games")

  test "a first session (a game folder, no PLAN.md yet) still gets the line":
    let root = newRoot()
    defer: removeDir(root)
    createDir(root / "games" / "mygame")
    let text = producerContext(root, "studio")
    check text.contains(studioLine)
    check text.contains("Call the friend \"director\".")

  test "an engine checkout stays silent even with studio set":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/sample/tools/sample_driver.nim", "echo 1\n")
    check producerContext(root, "studio") == ""
    check producerContext("", "studio") == ""

  test "the command reads PARALOOP_UI from the environment, and unset means no line":
    let root = newRoot()
    defer: removeDir(root)
    root.put("games/mygame/PLAN.md", "# mygame: plan\n\nSpeed: guided\n\n## Now\n")
    let old = getEnv(uiEnvVar)
    defer:
      if old.len > 0: putEnv(uiEnvVar, old) else: delEnv(uiEnvVar)
    delEnv(uiEnvVar)
    let plain = runProducerContext(@[], root)
    check plain.code == 0
    check studioLine notin plain.output
    putEnv(uiEnvVar, "studio")
    let studio = runProducerContext(@[], root)
    check studio.code == 0
    check studio.output.contains(studioLine)
    putEnv(uiEnvVar, "studio2")
    check runProducerContext(@[], root) == plain

suite "runProducerContext: arguments":
  test "--help prints usage, exit 0":
    let r = runProducerContext(@["--help"])
    check r.code == 0
    check r.output.startsWith("para producer-context")

  test "a stray argument is a usage error, exit 2":
    let r = runProducerContext(@["bogus"])
    check r.code == 2
    check r.output.startsWith("error:")

suite "owned file contracts: voice core, AGENTS.md, CLAUDE.md, hook configs":
  test "every voice-core bullet appears in AGENTS.md's Start-here block":
    # Drift guard for the single source of truth: AGENTS.md repeats the voice
    # core verbatim because an agent reads it with no hook and no tool call.
    let core = readFile(repoRoot / voiceCoreFile)
    let agents = squash(readFile(repoRoot / "AGENTS.md"))
    let block0 = agents[agents.find("## Making a game? Start here") ..< agents.find("Stack: Nim")]
    var bullets = 0
    for line in core.splitLines:
      if line.strip.len == 0: continue
      inc bullets
      check squash(line) in block0
    check bullets > 0

  test "CLAUDE.md and GEMINI.md import AGENTS.md":
    # Owned import contract: Claude Code and Gemini CLI only see AGENTS.md
    # through these one-line import files.
    check readFile(repoRoot / "CLAUDE.md").strip == "@AGENTS.md"
    check readFile(repoRoot / "GEMINI.md").strip == "@AGENTS.md"

  test "both hook configs declare a SessionStart command hook with a timeout":
    type
      Hook = object
        `type`: string
        command: string
        timeout: int
      Matcher = object
        hooks: seq[Hook]
      HookConfig = object
        hooks: Table[string, seq[Matcher]]
    for f in [".claude/settings.json", ".codex/hooks.json"]:
      let cfg = parseJson(readFile(repoRoot / f)).to(HookConfig)
      check cfg.hooks.hasKey("SessionStart")
      let hooks = cfg.hooks["SessionStart"]
      check hooks.len == 1
      check hooks[0].hooks.len == 1
      check hooks[0].hooks[0].`type` == "command"
      check hooks[0].hooks[0].command.len > 0
      check hooks[0].hooks[0].timeout > 0

  test ".claude/settings.json: no codex exec is allowed without the permission prompt":
    let perms = parseJson(readFile(repoRoot / ".claude" / "settings.json"))["permissions"]
    check not perms.hasKey("deny")
    for entry in perms["allow"]:
      check "codex" notin entry.getStr

  test ".claude/settings.json: the producer may edit files under games/ and nothing else":
    # a headless `claude -p` refuses any edit that no rule allows, so without these two rules the
    # producer cannot write PITCH.md/PLAN.md/... and a helper cannot build; they stay on games/**
    # (project-root-relative, gitignore-style) so the playbooks, settings and engine stay read-only
    let allow = parseJson(readFile(repoRoot / ".claude" / "settings.json"))["permissions"]["allow"].mapIt(it.getStr)
    check allow.filterIt(it.startsWith("Edit") or it.startsWith("Write") or it.startsWith("MultiEdit") or
                         it.startsWith("NotebookEdit")).sorted == @editRules.sorted
    for rule in allow:
      let tool = rule.split('(')[0]
      if tool in ["Edit", "Write", "MultiEdit", "NotebookEdit"]:
        check rule.endsWith(")")
        let path = rule[tool.len + 1 .. ^2]
        check path.startsWith("/games/") # "/" is the project root; "//" is the disk root, "~" is home
        check ".." notin path and "~" notin path and "\\" notin path and "!" notin path
        for outside in [".claude", ".agents", "tools", "src", "docs", "tests", "template", "skills", "AGENTS.md", "CLAUDE.md"]:
          check outside notin path
      else:
        check tool == "Bash" # no bare `Edit`, `Write`, `Read`, `WebFetch`, `mcp__...` or wildcard rule
    check "Bash" notin allow and "Bash(*)" notin allow and "Edit" notin allow and "Write" notin allow
    check "Edit(*)" notin allow and "Edit(**)" notin allow and "Write(*)" notin allow and "Write(**)" notin allow

  test ".claude/settings.json: the permission allow-list is narrow, and the hook is still there":
    let cfg = parseJson(readFile(repoRoot / ".claude" / "settings.json"))
    check cfg["hooks"]["SessionStart"][0]["hooks"][0]["command"].getStr.contains("tmp/para producer-context")
    let allow = cfg["permissions"]["allow"]
    check allow.len > 0
    # nothing that destroys, publishes, fetches, or leaves the repo; nothing that reruns a whole suite
    let banned = ["push", "force", "reset", "clean", "checkout", "rebase", "rm ", "rm-", "sudo", "gh ", "curl", "wget",
                  "ssh", "nimble", "bash", "sh -c", "eval", "xargs", "--yes", "--back", "--set-aside", "--push", "--update-golden",
                  "web ", "shot", "balance", "live", "commit", "tag ", "merge", "fetch", "pull", "remote add", "git add", ".."]
    for entry in allow:
      let rule = entry.getStr
      if rule in editRules: continue
      check rule.startsWith("Bash(") and rule.endsWith(")")
      check rule notin ["Bash(*)", "Bash(tmp/para:*)", "Bash(tmp/para *)", "Bash(git:*)", "Bash(git *)", "Bash(nim:*)", "Bash(nim *)"]
      check "&&" notin rule and ";" notin rule and "|" notin rule and ">" notin rule
      for word in banned:
        check word notin rule
      # a rule is a para subcommand, or one of a few exact read-only probes, or the one CLI build line
      check rule.startsWith("Bash(tmp/para ") or rule in ["Bash(nim c --hints:off --outdir:tmp tools/para/para.nim)",
        "Bash(git --version)", "Bash(nim -v)", "Bash(cc --version)", "Bash(git remote get-url origin)"]
      if rule.startsWith("Bash(tmp/para test"): check rule == "Bash(tmp/para test --filter games/*)"

