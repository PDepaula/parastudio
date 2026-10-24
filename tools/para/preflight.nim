# The startup checks behind the Studio page's "Ready" line (`GET /api/preflight`): is the producer's
# program installed, signed in, does it trust this folder, may it edit the game's files. They run
# before the first chat so a setup problem is named on the page, with one plain fix, instead of
# surfacing in the middle of a conversation.
#
# This file holds what the Claude and Codex adapters share: the shape of a check, the pure readers
# that turn a program's answer or a config file into a `CheckState` (each tested with fixtures in
# tests/test_para_studio_preflight.nim), and the few paths those files live at. The adapters
# (claudeagent.nim, codexagent.nim) decide which probes to run and word the fixes.
#
# What a check may do: run the agent program's own read-only status command, and read one config
# file in this computer's home folder or the folder's own `.claude/` files. What it never does: start
# a model turn (nothing is billed), write anything, or keep, return or log more than a yes/no from
# what it read. `claude auth status` prints an email address and a plan; `claudeSignedIn` looks at
# `loggedIn` only and the rest of the output is dropped. `~/.claude.json` holds every project the
# friend ever opened; `claudeTrust` looks at one entry's `hasTrustDialogAccepted` only.
#
# A check that cannot be answered safely says so (`csUnknown`, "could not check") rather than guess.

import std/[json, os, strutils]
import agent
import agentjson

const
  maxConfigBytes = 8_000_000 ## a config file bigger than this is not read
  editRule = "(/games/**)"   ## the scope of the two edit rules in .claude/settings.json

proc passed*(id, label: string): PreflightCheck =
  PreflightCheck(id: id, state: csOk, label: label)

proc failed*(id, label, problem, fix: string): PreflightCheck =
  PreflightCheck(id: id, state: csFail, label: label, problem: problem, fix: fix)

proc couldNotCheck*(id, label, problem, fix: string): PreflightCheck =
  PreflightCheck(id: id, state: csUnknown, label: label, problem: problem, fix: fix)

proc allOk*(checks: seq[PreflightCheck]): bool =
  for c in checks:
    if c.state != csOk: return false
  true

proc stateName*(s: CheckState): string =
  case s
  of csOk: "ok"
  of csFail: "fail"
  of csUnknown: "unknown"

# --- reading a program's answer -----------------------------------------------------

proc claudeSignedIn*(output: string): CheckState =
  ## `claude auth status --json` prints one JSON object whose `loggedIn` is true or false (and exits
  ## 0 or 1 to match). Only that yes/no is read. Anything else, such as an older claude with no
  ## `auth` command or text that is not JSON, is "could not check".
  var node: JsonNode
  try:
    node = parseJson(output)
  except CatchableError:
    return csUnknown
  let v = node.at("loggedIn")
  if v == nil or v.kind != JBool: return csUnknown
  if v.getBool: csOk else: csFail

proc codexSignedIn*(exitCode: int, output: string): CheckState =
  ## `codex login status` prints "Logged in using ChatGPT" (or "... using an API key") and exits 0,
  ## or prints "Not logged in" and exits 1.
  let t = output.toLowerAscii
  if "not logged in" in t: csFail
  elif exitCode == 0 and "logged in" in t: csOk
  else: csUnknown

# --- reading config files -----------------------------------------------------------

proc samePath(a, b: string): bool =
  proc norm(p: string): string =
    result = p.replace('\\', '/')
    while result.len > 1 and result.endsWith("/"): result.setLen(result.len - 1)
    when defined(windows): result = result.toLowerAscii
  norm(a) == norm(b)

proc claudeTrust*(configText: string, folders: openArray[string], strict = true): CheckState =
  ## Claude Code records "Yes, I trust this folder" as `projects["<folder>"].hasTrustDialogAccepted`
  ## in its `.claude.json`, for exactly that folder: trusting a parent folder does not cover it
  ## (checked with Claude Code 2.1.306). `folders` are the spellings of this folder to look for.
  ## With `strict`, a folder with no entry is "not trusted"; without it (Windows, where the key
  ## format has not been checked) it is "could not check".
  var cfg: JsonNode
  try:
    cfg = parseJson(configText)
  except CatchableError:
    return csUnknown
  if cfg.kind != JObject: return csUnknown
  var seen = false
  let projects = cfg.at("projects")
  if projects != nil and projects.kind == JObject:
    for key, entry in projects:
      for f in folders:
        if samePath(key, f):
          seen = true
          if entry.flag("hasTrustDialogAccepted"): return csOk
  if seen or strict: csFail else: csUnknown

proc codexTrust*(tomlText: string, folders: openArray[string]): CheckState =
  ## Codex records trust in `config.toml` as a table `[projects."<folder>"]` holding
  ## `trust_level = "trusted"`. Only that is looked for (a line scan, not a TOML parser). A folder
  ## with no such entry is "could not check", not "not trusted": whether Codex also trusts a
  ## folder through its parent has not been checked.
  var inEntry = false
  for raw in tomlText.splitLines:
    let line = raw.strip
    if line.startsWith("["):
      inEntry = false
      for quote in ['"', '\'']:
        let head = "[projects." & quote
        if line.startsWith(head) and line.endsWith($quote & "]"):
          let path = line[head.len ..< line.len - 2].replace("\\\\", "\\")
          for f in folders:
            if samePath(path, f): inEntry = true
    elif inEntry and line.startsWith("trust_level"):
      let eq = line.find('=')
      if eq > 0 and line[eq + 1 .. ^1].strip(chars = Whitespace + {'"', '\''}) == "trusted":
        return csOk
  csUnknown

proc ruleList(settingsText, list: string): seq[string] =
  ## `permissions.<list>` of one settings file; empty when the file is missing or is not JSON.
  if settingsText.len == 0: return
  try:
    let rules = parseJson(settingsText).at("permissions", list)
    if rules != nil and rules.kind == JArray:
      for r in rules:
        if r.kind == JString: result.add r.getStr.strip
  except CatchableError:
    discard

type EditRules* = enum
  erAllowed  ## both rules are there and nothing denies them
  erMissing  ## the allow list lacks Edit or Write for games/** (or the file is gone or broken)
  erBlocked  ## a deny rule covers edits in games/

proc editRulesIn*(projectSettings, localSettings: string): EditRules =
  ## What the folder's `.claude/settings.json` (and the friend's `.claude/settings.local.json`)
  ## say about changing files in games/. A headless `claude -p` turn cannot ask, so without
  ## `Edit(/games/**)` and `Write(/games/**)` every file write is refused. No model is called.
  let allow = ruleList(projectSettings, "allow") & ruleList(localSettings, "allow")
  let deny = ruleList(projectSettings, "deny") & ruleList(localSettings, "deny")
  for d in deny:
    for tool in ["Edit", "Write", "MultiEdit"]:
      if d == tool or (d.startsWith(tool & "(") and "games" in d): return erBlocked
  for tool in ["Edit", "Write"]:
    if tool notin allow and tool & editRule notin allow: return erMissing
  erAllowed

# --- where the files are --------------------------------------------------------------

proc readSmallFile*(path: string): tuple[found, readable: bool, text: string] =
  ## `found` false when there is no such file; `readable` false when it is too big or cannot be read.
  if not fileExists(path): return
  result.found = true
  try:
    if getFileSize(path) > maxConfigBytes: return
    result.text = readFile(path)
    result.readable = true
  except IOError, OSError:
    discard

proc folderForms*(root: string): seq[string] =
  ## `root` as given and with symbolic links resolved: a program may have recorded either.
  result.add root
  try:
    let real = expandFilename(root)
    if real != root: result.add real
  except OSError:
    discard

proc claudeConfigFile*(): string =
  ## Where Claude Code keeps its per-folder answers: `$CLAUDE_CONFIG_DIR/.claude.json` when that is
  ## set, else `.claude.json` in the home folder.
  let dir = getEnv("CLAUDE_CONFIG_DIR")
  if dir.len > 0: dir / ".claude.json" else: getHomeDir() / ".claude.json"

proc codexConfigFile*(): string =
  let dir = getEnv("CODEX_HOME")
  (if dir.len > 0: dir else: getHomeDir() / ".codex") / "config.toml"
