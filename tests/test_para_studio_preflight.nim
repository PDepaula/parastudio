# Tests for the startup checks on `para studio`'s page (tools/para/preflight.nim, the `preflight`
# proc of each adapter, and `GET /api/preflight` in studioapi.nim):
#
# - the pure readers, from fixtures in the shape the real programs wrote (Claude Code 2.1.306's
#   `auth status --json` and `.claude.json`, Codex 0.159.2's `login status` and `config.toml`) and
#   from hand-made answers that are broken or of a shape nobody knows: "could not check", never a guess;
# - the repository's own .claude/settings.json passes the edit-rule check (so a change that drops
#   Edit/Write for games/** fails here, before it fails in somebody's first chat);
# - the adapters against the stand-in programs (tests/fake_claude.nim, tests/fake_codex.nim) and a
#   scratch config folder: ready, not installed, signed out, could not check, folder not trusted,
#   edit rules missing or denied, each with its one fix line;
# - nothing is started and nothing secret comes out: no chat turn, and none of the account details
#   the programs print (an email address, a plan, other folders in the config) in the route's answer.
#
# - `para studio --check` (studiocmd.nim's `startupChecks`), which the double-click launchers run
#   before they open the page: the same checks as plain lines, one fix line under each that fails.
#
# The real `claude` and `codex` are run by hand in the PR's checklist, not here.

import std/[unittest, os, strutils, json, tempfiles, sequtils]
import fake_claude
import fake_codex
import studio_support
import tools/para/agent
import tools/para/agents
import tools/para/claudeagent
import tools/para/preflight
import tools/para/studioapi
import tools/para/studiocmd
import tools/para/studiohttp
import tools/para/boardcmd

when isMainModule:
  # one program stands in for both agents: codex is started as `login ...` or `app-server ...`, claude otherwise
  if getEnv("PARA_FAKE_CODEX") == "1" and paramCount() > 0 and paramStr(1) in ["login", "app-server"]:
    fakeCodexMain()
  elif getEnv("PARA_FAKE_CLAUDE") == "1":
    fakeClaudeMain()

const
  repoSettings = currentSourcePath.parentDir.parentDir / ".claude" / "settings.json"

  # `claude auth status --json`, as 2.1.306 printed it (the account fields are made up)
  authIn = """{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"friend@example.com","orgName":"Friend","subscriptionType":"pro"}"""
  authOut = """{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty","analyticsDisabled":false}"""

  settingsOk = """{"permissions":{"allow":["Edit(/games/**)","Write(/games/**)","Bash(tmp/para check)"]}}"""

proc claudeConfig(folders: varargs[(string, bool)]): string =
  ## A `.claude.json` that lists these folders, each trusted or not, plus things that are not ours to read.
  var projects = newJObject()
  for (folder, trusted) in folders:
    projects[folder] = %*{"allowedTools": [], "hasTrustDialogAccepted": trusted, "lastCost": 0}
  $(%*{"numStartups": 3, "userID": "USER-ID-MARKER", "projects": projects})

proc codexConfig(body: string): string = "model = \"gpt-5\"\n\n" & body

suite "preflight: reading `claude auth status`":
  test "loggedIn is the only thing read":
    check claudeSignedIn(authIn) == csOk
    check claudeSignedIn(authOut) == csFail
    check claudeSignedIn(authIn & "\n") == csOk

  test "anything that is not that answer is could-not-check, not a guess":
    check claudeSignedIn("") == csUnknown
    check claudeSignedIn("Not logged in. Run claude auth login to authenticate.") == csUnknown
    check claudeSignedIn("error: unknown command 'auth'") == csUnknown
    check claudeSignedIn("[1,2,3]") == csUnknown
    check claudeSignedIn("""{"authMethod":"none"}""") == csUnknown
    check claudeSignedIn("""{"loggedIn":"yes"}""") == csUnknown
    check claudeSignedIn("cannot run claude: no such file\n") == csUnknown

suite "preflight: reading `codex login status`":
  test "logged in, logged out, and neither":
    check codexSignedIn(0, "Logged in using ChatGPT") == csOk
    check codexSignedIn(0, "Logged in using an API key\n") == csOk
    check codexSignedIn(1, "Not logged in") == csFail
    check codexSignedIn(0, "Not logged in") == csFail # the words win over the exit code
    check codexSignedIn(1, "") == csUnknown
    check codexSignedIn(127, "cannot run codex: no such file\n") == csUnknown
    check codexSignedIn(0, "Welcome to a different program") == csUnknown

suite "preflight: Claude's record of trusting a folder":
  const here = "/home/friend/parastudio"

  test "a folder answered Yes is trusted":
    check claudeTrust(claudeConfig((here, true)), [here]) == csOk

  test "a folder that was opened but not trusted, or never opened, is not trusted":
    check claudeTrust(claudeConfig((here, false)), [here]) == csFail
    check claudeTrust(claudeConfig(("/home/friend/other", true)), [here]) == csFail
    check claudeTrust(claudeConfig(), [here]) == csFail
    check claudeTrust("""{"numStartups":1}""", [here]) == csFail

  test "trusting a parent folder does not cover it (checked against Claude Code 2.1.306)":
    check claudeTrust(claudeConfig(("/home/friend", true)), [here]) == csFail
    check claudeTrust(claudeConfig((here, true)), ["/home/friend/parastudio/games"]) == csFail

  test "the same folder spelled another way still matches":
    check claudeTrust(claudeConfig((here & "/", true)), [here]) == csOk
    check claudeTrust(claudeConfig(("C:\\Users\\friend\\parastudio", true)), ["C:/Users/friend/parastudio"]) == csOk
    check claudeTrust(claudeConfig(("/private/home/friend/parastudio", true)), [here, "/private/home/friend/parastudio"]) == csOk

  test "where the key format has not been checked, a missing entry is could-not-check":
    check claudeTrust(claudeConfig(("/home/friend/other", true)), [here], strict = false) == csUnknown
    check claudeTrust(claudeConfig((here, false)), [here], strict = false) == csFail
    check claudeTrust(claudeConfig((here, true)), [here], strict = false) == csOk

  test "a file that is not the config is could-not-check":
    check claudeTrust("", [here]) == csUnknown
    check claudeTrust("this is not json", [here]) == csUnknown
    check claudeTrust("[1,2,3]", [here]) == csUnknown

suite "preflight: Codex's record of trusting a folder":
  const here = "/home/friend/parastudio"

  test "a project table with trust_level = trusted":
    check codexTrust(codexConfig("[projects.\"" & here & "\"]\ntrust_level = \"trusted\"\n"), [here]) == csOk
    check codexTrust(codexConfig("[projects.'" & here & "']\ntrust_level = 'trusted'\n"), [here]) == csOk

  test "the table of another folder, or of this one without trust, is could-not-check":
    check codexTrust(codexConfig("[projects.\"/home/friend/other\"]\ntrust_level = \"trusted\"\n"), [here]) == csUnknown
    check codexTrust(codexConfig("[projects.\"" & here & "\"]\nnote = \"x\"\n"), [here]) == csUnknown
    check codexTrust(codexConfig("[projects.\"" & here & "\"]\ntrust_level = \"untrusted\"\n"), [here]) == csUnknown
    check codexTrust("", [here]) == csUnknown

  test "trust in a later table does not leak back to this folder":
    let text = codexConfig("[projects.\"" & here & "\"]\nnote = \"x\"\n\n[projects.\"/home/friend/other\"]\ntrust_level = \"trusted\"\n")
    check codexTrust(text, [here]) == csUnknown
    check codexTrust(text, ["/home/friend/other"]) == csOk

  test "a Windows path as TOML writes it":
    check codexTrust(codexConfig("[projects.\"C:\\\\Users\\\\friend\\\\parastudio\"]\ntrust_level = \"trusted\"\n"), ["C:\\Users\\friend\\parastudio"]) == csOk

suite "preflight: the rules that let the producer change files in games/":
  test "this repository's own .claude/settings.json passes":
    check editRulesIn(readFile(repoSettings), "") == erAllowed

  test "both rules, from either settings file":
    check editRulesIn(settingsOk, "") == erAllowed
    check editRulesIn("""{"permissions":{"allow":["Edit(/games/**)"]}}""", """{"permissions":{"allow":["Write(/games/**)"]}}""") == erAllowed
    check editRulesIn("""{"permissions":{"allow":["Edit","Write"]}}""", "") == erAllowed

  test "a missing rule, a rule for another folder, no file or a broken file is missing":
    check editRulesIn("""{"permissions":{"allow":["Edit(/games/**)"]}}""", "") == erMissing
    check editRulesIn("""{"permissions":{"allow":["Edit(/docs/**)","Write(/docs/**)"]}}""", "") == erMissing
    check editRulesIn("""{"permissions":{"allow":["Bash(tmp/para check)"]}}""", "") == erMissing
    check editRulesIn("""{"permissions":{}}""", "") == erMissing
    check editRulesIn("", "") == erMissing
    check editRulesIn("{ not json", "") == erMissing

  test "a deny rule that covers games/ blocks them, one that does not does not":
    check editRulesIn(settingsOk, """{"permissions":{"deny":["Edit(/games/**)"]}}""") == erBlocked
    check editRulesIn(settingsOk, """{"permissions":{"deny":["Write"]}}""") == erBlocked
    check editRulesIn(settingsOk, """{"permissions":{"deny":["MultiEdit(/games/mygame/**)"]}}""") == erBlocked
    check editRulesIn(settingsOk, """{"permissions":{"deny":["Bash(rm *)","Edit(/docs/**)"]}}""") == erAllowed

# --- the adapters, against the stand-ins --------------------------------------------------

type Scratch = object
  root, config, log: string

proc scratch(settings = settingsOk, localSettings = ""): Scratch =
  ## A folder with `.claude/` settings, and a place for the agent's own config; the stand-ins and
  ## the readers are pointed at both through the environment.
  result.root = createTempDir("para_preflight_", "")
  result.config = createTempDir("para_preflight_cfg_", "")
  result.log = result.root / "fake.log"
  if settings.len > 0: result.root.put(".claude/settings.json", settings)
  if localSettings.len > 0: result.root.put(".claude/settings.local.json", localSettings)
  putEnv("PARA_FAKE_CLAUDE", "1")
  putEnv("PARA_FAKE_CODEX", "1")
  putEnv("CLAUDE_CONFIG_DIR", result.config)
  putEnv("CODEX_HOME", result.config)
  putEnv("FAKE_CLAUDE_LOG", result.log)
  putEnv("FAKE_CODEX_LOG", result.log)

proc done(s: Scratch) =
  for k in ["PARA_FAKE_CLAUDE", "PARA_FAKE_CODEX", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "FAKE_CLAUDE_LOG",
            "FAKE_CODEX_LOG", "FAKE_CLAUDE_AUTH", "FAKE_CODEX_LOGIN"]:
    delEnv(k)
  removeDir(s.root)
  removeDir(s.config)

template withoutProgram(s: Scratch, body: untyped) =
  ## `claude` and `codex` are looked up on PATH when no stand-in is named: make that find nothing.
  let savedPath = getEnv("PATH")
  putEnv("PATH", s.config)
  try: body
  finally: putEnv("PATH", savedPath)

proc claudeChecks(s: Scratch, exe = getAppFilename()): seq[PreflightCheck] =
  let a = adapterNamed("claude", exe)
  a.preflight(a, s.root)

proc codexChecks(s: Scratch, exe = getAppFilename()): seq[PreflightCheck] =
  let a = adapterNamed("codex", exe)
  a.preflight(a, s.root)

proc byId(checks: seq[PreflightCheck], id: string): PreflightCheck =
  for c in checks:
    if c.id == id: return c
  doAssert false, "no check called " & id & " in " & $checks.mapIt(it.id)

suite "preflight: Claude, against a stand-in claude":
  test "all four pass: ready":
    let s = scratch()
    defer: s.done()
    s.config.put(".claude.json", claudeConfig((s.root, true)))
    let checks = s.claudeChecks()
    check checks.mapIt(it.id) == @["installed", "signed-in", "trusted", "edits"]
    check checks.mapIt(it.state) == @[csOk, csOk, csOk, csOk]
    check allOk(checks)
    check checks.allIt(it.problem.len == 0 and it.fix.len == 0)

  test "not signed in: one plain fix line, and the rest still checked":
    let s = scratch()
    defer: s.done()
    putEnv("FAKE_CLAUDE_AUTH", "out")
    s.config.put(".claude.json", claudeConfig((s.root, true)))
    let checks = s.claudeChecks()
    check not allOk(checks)
    let c = checks.byId("signed-in")
    check c.state == csFail
    check c.problem == "Claude is not signed in."
    check "run: claude" in c.fix and "\n" notin c.fix
    check checks.byId("trusted").state == csOk and checks.byId("edits").state == csOk

  test "an answer in a shape nobody knows is could-not-check, with a fix that is only a hint":
    for mode in ["garbage", "noauth"]:
      let s = scratch()
      putEnv("FAKE_CLAUDE_AUTH", mode)
      s.config.put(".claude.json", claudeConfig((s.root, true)))
      let c = s.claudeChecks().byId("signed-in")
      check c.state == csUnknown
      check c.problem.startsWith("Could not check")
      check c.fix.startsWith("If the producer says")
      s.done()

  test "a folder Claude has never been opened in is not trusted, and the fix says where and what to answer":
    let s = scratch()
    defer: s.done()
    let c = s.claudeChecks().byId("trusted") # no .claude.json at all
    check c.state == csFail
    check s.root in c.fix and "Yes, I trust this folder" in c.fix and "run: claude" in c.fix

  test "other folders trusted, this one not":
    let s = scratch()
    defer: s.done()
    s.config.put(".claude.json", claudeConfig(("/somewhere/else", true), (s.root, false)))
    check s.claudeChecks().byId("trusted").state == csFail

  test "a config file that is not JSON is could-not-check":
    let s = scratch()
    defer: s.done()
    s.config.put(".claude.json", "not json at all")
    let c = s.claudeChecks().byId("trusted")
    check c.state == csUnknown and c.problem.startsWith("Could not check")

  test "missing edit rules, a missing settings file and a deny rule each fail with their own fix":
    block missingRule:
      let s = scratch("""{"permissions":{"allow":["Edit(/games/**)"]}}""")
      defer: s.done()
      let c = s.claudeChecks().byId("edits")
      check c.state == csFail and c.fix == editsMissingFix and "git checkout" in c.fix
    block noFile:
      let s = scratch("")
      defer: s.done()
      check s.claudeChecks().byId("edits").state == csFail
    block denied:
      let s = scratch(settingsOk, """{"permissions":{"deny":["Write(/games/**)"]}}""")
      defer: s.done()
      let c = s.claudeChecks().byId("edits")
      check c.state == csFail and c.fix == editsBlockedFix

  test "claude not installed: say so with the setup page; sign-in and trust are not asked":
    let s = scratch()
    defer: s.done()
    var checks: seq[PreflightCheck]
    s.withoutProgram: checks = s.claudeChecks("")
    check checks.mapIt(it.id) == @["installed", "edits"]
    check checks[0].state == csFail
    check installUrl in checks[0].fix
    check checks[1].state == csOk

  test "nothing is started, and none of what the program printed or the config holds comes out":
    let s = scratch()
    defer: s.done()
    s.config.put(".claude.json", claudeConfig((s.root, true), ("/somewhere/else", true)))
    let shown = $(%s.claudeChecks().mapIt(%*{"id": it.id, "label": it.label, "problem": it.problem, "fix": it.fix}))
    check "friend@example.com" notin shown and "claude.ai" notin shown
    check "USER-ID-MARKER" notin shown and "/somewhere/else" notin shown
    check not fileExists(s.log) # the stand-in logs every turn it is asked to run; there was none

suite "preflight: Codex, against a stand-in codex":
  test "signed in and trusted: ready; no edit rules are asked for":
    let s = scratch()
    defer: s.done()
    s.config.put("config.toml", codexConfig("[projects.\"" & s.root & "\"]\ntrust_level = \"trusted\"\n"))
    let checks = s.codexChecks()
    check checks.mapIt(it.id) == @["installed", "signed-in", "trusted"]
    check allOk(checks)

  test "signed out":
    let s = scratch()
    defer: s.done()
    putEnv("FAKE_CODEX_LOGIN", "out")
    let c = s.codexChecks().byId("signed-in")
    check c.state == csFail and "run: codex" in c.fix

  test "a folder with no record is could-not-check, never a failure":
    let s = scratch()
    defer: s.done()
    let c = s.codexChecks().byId("trusted")
    check c.state == csUnknown and c.problem.startsWith("Could not check") and "run: codex" in c.fix

  test "an answer in a shape nobody knows":
    let s = scratch()
    defer: s.done()
    putEnv("FAKE_CODEX_LOGIN", "garbage")
    check s.codexChecks().byId("signed-in").state == csUnknown

  test "codex not installed":
    let s = scratch()
    defer: s.done()
    var checks: seq[PreflightCheck]
    s.withoutProgram: checks = s.codexChecks("")
    check checks.len == 1 and checks[0].state == csFail and "codex" in checks[0].fix

# --- the route -----------------------------------------------------------------------------

suite "preflight: GET /api/preflight":
  var s: Scratch
  var running: Running
  let startDir = getCurrentDir()

  setup:
    s = scratch()
    # the studio's folder is its own scratch repository; the checks read that folder's .claude/ files
    let repo = newGameRepo("pong")
    repo.put(".claude/settings.json", settingsOk)
    s.config.put(".claude.json", claudeConfig((repo, true)))
    s.config.put("config.toml", codexConfig("[projects.\"" & repo & "\"]\ntrust_level = \"trusted\"\n"))
    removeDir(s.root)
    s.root = repo
    s.log = repo / "fake.log"
    putEnv("FAKE_CLAUDE_LOG", s.log)
    putEnv("FAKE_CODEX_LOG", s.log)
    running = startStudio(repo, getAppFilename(), "", adapterNamed("claude", getAppFilename()),
                          others = @[adapterNamed("codex", getAppFilename())])

  teardown:
    running.stop()
    setCurrentDir(startDir)
    s.done()

  test "it needs the page's key like every other route":
    check running.request("GET", "/api/preflight", withToken = false).status == 403
    check running.request("GET", "/api/preflight", headers = @[("X-Studio-Token", "nope")], withToken = false).status == 403
    check running.request("GET", "/api/preflight", host = "evil.example:80").status == 403

  test "ready: the producer's name and every check ok, with no problem or fix on a passing one":
    let r = running.request("GET", "/api/preflight?game=pong")
    check r.status == 200
    let d = parseJson(r.body)
    check d["agent"].getStr == "claude" and d["label"].getStr == "Claude"
    check d["ready"].getBool
    check d["checks"].getElems.mapIt(it["id"].getStr) == @["installed", "signed-in", "trusted", "edits"]
    for c in d["checks"]:
      check c["state"].getStr == "ok" and c["label"].getStr.len > 0
      check not c.hasKey("problem") and not c.hasKey("fix")
    # the first-run helper's command names this folder; a terminal is offered only where there is a standard one
    check d["folder"].getStr == s.root
    check d["terminal"].getBool == (terminalCommand(s.root).len > 0)

  test "not ready: the failing check carries its problem and its fix; the others stay short":
    putEnv("FAKE_CLAUDE_AUTH", "out")
    let d = parseJson(running.request("GET", "/api/preflight").body)
    check not d["ready"].getBool
    let bad = d["checks"].getElems.filterIt(it["state"].getStr != "ok")
    check bad.len == 1 and bad[0]["id"].getStr == "signed-in" and bad[0]["state"].getStr == "fail"
    check bad[0]["problem"].getStr.len > 0 and "run: claude" in bad[0]["fix"].getStr

  test "it follows the producer picked for the game":
    check running.request("POST", "/api/agent/pick", body = """{"game":"pong","agent":"codex"}""").status == 200
    let d = parseJson(running.request("GET", "/api/preflight?game=pong").body)
    check d["agent"].getStr == "codex" and d["label"].getStr == "Codex"
    check d["checks"].getElems.mapIt(it["id"].getStr) == @["installed", "signed-in", "trusted"]
    check d["ready"].getBool

  test "it works before a game exists, and asks again every time":
    let again = running.request("GET", "/api/preflight")
    check again.status == 200 and parseJson(again.body)["ready"].getBool
    putEnv("FAKE_CLAUDE_AUTH", "out")
    check not parseJson(running.request("GET", "/api/preflight").body)["ready"].getBool
    putEnv("FAKE_CLAUDE_AUTH", "in")
    check parseJson(running.request("GET", "/api/preflight").body)["ready"].getBool

  test "the optional row (Lavish, for visual boards) is listed apart and never counted":
    let savedPath = getEnv("PATH")
    putEnv("PATH", s.root / "no-such-folder") # no lavish-axi on this computer
    var d: JsonNode
    try: d = parseJson(running.request("GET", "/api/preflight").body)
    finally: putEnv("PATH", savedPath)
    check d["ready"].getBool
    check d["checks"].getElems.allIt(it["id"].getStr != "boards")
    let opt = d["optional"].getElems
    check opt.len == 1 and opt[0]["id"].getStr == "boards" and opt[0]["state"].getStr == "absent"
    check opt[0]["command"].getStr == boardInstallCommand # the page shows it to copy; it installs nothing itself
    check "board for reviewing things visually" in opt[0]["problem"].getStr
    check lavishPage in opt[0]["about"].getStr and "MIT" in opt[0]["about"].getStr

  test "opening it starts no turn, and the answer holds no account detail":
    let body = running.request("GET", "/api/preflight").body
    check "friend@example.com" notin body and "USER-ID-MARKER" notin body
    check not fileExists(s.log)

# --- `para studio --check` -------------------------------------------------------------------

suite "preflight: para studio --check":
  test "a ready producer: every check ok, exit 0; a program that is not installed is not listed":
    let s = scratch()
    defer: s.done()
    s.config.put(".claude.json", claudeConfig((s.root, true)))
    var r: tuple[output: string, code: int]
    s.withoutProgram:
      r = startupChecks(s.root, @[adapterNamed("claude", getAppFilename()), adapterNamed("codex", "")])
    check r.code == 0
    check "Startup checks" in r.output
    check "Claude: ready" in r.output
    for label in ["Claude is installed", "Claude is signed in", "Claude trusts this folder"]:
      check ("ok:  " & label) in r.output
    check "Codex" notin r.output
    check "fix:" notin r.output
    check "never stop Studio from opening" in r.output

  test "signed out and not trusted: each failing check has its problem and one fix line, exit 1":
    let s = scratch()
    defer: s.done()
    putEnv("FAKE_CLAUDE_AUTH", "out")
    let r = startupChecks(s.root, @[adapterNamed("claude", getAppFilename())])
    check r.code == 1
    check "Claude: not ready yet" in r.output
    check "no:  Claude is signed in. Claude is not signed in." in r.output
    check ("fix: " & signedOutFix) in r.output
    check "no:  Claude trusts this folder" in r.output
    check ("fix: " & trustFix(s.root)) in r.output

  test "both installed: both are checked; one ready is enough for exit 0":
    let s = scratch()
    defer: s.done()
    s.config.put(".claude.json", claudeConfig((s.root, true)))
    putEnv("FAKE_CODEX_LOGIN", "out")
    let r = startupChecks(s.root, @[adapterNamed("claude", getAppFilename()), adapterNamed("codex", getAppFilename())])
    check r.code == 0
    check "Claude: ready" in r.output and "Codex: not ready yet" in r.output
    check "run: codex" in r.output

  test "neither installed: the first one's not-installed line and where to get it, exit 1":
    let s = scratch()
    defer: s.done()
    var r: tuple[output: string, code: int]
    s.withoutProgram:
      r = startupChecks(s.root, @[adapterNamed("claude", ""), adapterNamed("codex", "")])
    check r.code == 1
    check "no:  Claude is installed" in r.output
    check installUrl in r.output
    check "Codex" notin r.output

  test "nothing is started, and no account detail comes out":
    let s = scratch()
    defer: s.done()
    s.config.put(".claude.json", claudeConfig((s.root, true), ("/somewhere/else", true)))
    let r = startupChecks(s.root, @[adapterNamed("claude", getAppFilename())])
    check "friend@example.com" notin r.output and "USER-ID-MARKER" notin r.output
    check "/somewhere/else" notin r.output
    check not fileExists(s.log)

  test "an optional program that is missing is listed, with how to add it, and never makes it not ready":
    let s = scratch()
    defer: s.done()
    s.config.put(".claude.json", claudeConfig((s.root, true)))
    let r = startupChecks(s.root, @[adapterNamed("claude", getAppFilename())], @[boardCheck("")])
    check r.code == 0
    check "Claude: ready" in r.output
    check "Optional (Studio works without these):" in r.output
    check "  --:  Lavish (visual boards). Optional, not installed." in r.output
    check ("\n       To add it, run in a terminal in this folder: " & boardInstallCommand) in r.output
    check "fix:" notin r.output # an optional program is never something to fix
    let here = startupChecks(s.root, @[adapterNamed("claude", getAppFilename())], @[boardCheck(getAppFilename())])
    check "  ok:  Lavish is installed (optional: visual boards)" in here.output and here.code == 0

  test "the flag starts no server and opens no browser":
    let s = scratch()
    defer: s.done()
    var opened = false
    proc onOpen(url: string): bool = opened = true
    proc onReady(srv: ptr HttpServer) = requestStop(srv)
    var r: tuple[output: string, code: int]
    s.withoutProgram:
      r = runStudioWith(@["--check"], StudioHooks(announce: proc (line: string) = discard,
                        openBrowser: onOpen, ready: onReady), root = s.root)
    check "Startup checks" in r.output
    check "para studio is running" notin r.output
    check not opened
    check "--check" in studioHelp
