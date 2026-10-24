# Which agent adapters exist. The studio asks for one by name; adding an agent is one more
# adapter file (see agent.nim) and one more line here. Nothing above this file names an agent.

import agent
import claudeagent
import codexagent

const
  knownAgents* = ["claude", "codex"] ## the first is the default

proc adapterNamed*(name: string, exe = ""): AgentAdapter =
  ## `exe` points a test at a stand-in program; left out, the real one is looked up on PATH.
  case name
  of "claude": newClaudeAdapter(exe)
  of "codex": newCodexAdapter(exe)
  else: raise newException(ValueError, "there is no agent called \"" & name & "\"")

proc defaultAdapter*(): AgentAdapter = adapterNamed(knownAgents[0])

proc allAdapters*(): seq[AgentAdapter] =
  ## One of each, the default first: what the studio's agent picker offers.
  for name in knownAgents: result.add adapterNamed(name)
