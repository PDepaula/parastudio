# The `para` AXI CLI (engine report §5, task 1.8): bare view, `art`
# (task A1/A2), `test`, `check`, `save`, `backup`, `build`, `sim`, `shot`, `driver`, `live`,
# `web smoke`, `setup hooks`, `producer-context` and `studio`. Every subcommand is a plain `run(args): (output, code)` proc
# (`art/clihelpers.Run`), and so is `dispatch` below; the main block just
# prints and quits with its result -- no direct stdout/exit calls anywhere
# else, so tests can call each one without a subprocess (see
# tests/test_art_cli.nim and its task-1.8 siblings).

import std/[os, strformat, strutils]
import art/clihelpers
import artcmd
import testcmd
import checkcmd
import savecmd
import backupcmd
import buildcmd
import simcmd
import shotcmd
import driverexec
import livecmd
import websmokecmd
import webpackcmd
import homecmd
import hookscmd
import newcmd
import producercmd
import studiocmd
import usage

proc runGroup(group, sub: string, args: seq[string], help: string,
              run: proc (args: seq[string]): Run): Run =
  ## A command group with one subcommand (`setup hooks`): bare or `--help`
  ## prints its usage, exit 0.
  if args.len == 0 or args[0] in ["--help", "-h"]:
    return (help, 0)
  if args[0] != sub:
    return errorOut(&"unknown command \"{group} {args[0]}\"", @[&"Valid commands: {group} {sub}"])
  run(args[1 .. ^1])

const webHelp = webSmokeHelp & "\n" & webPackHelp

proc runWeb(args: seq[string]): Run =
  ## `web smoke` and `web pack`: bare or `--help` prints both usages, exit 0.
  if args.len == 0 or args[0] in ["--help", "-h"]:
    return (webHelp, 0)
  case args[0]
  of "smoke": runWebSmoke(args[1 .. ^1])
  of "pack": runWebPack(args[1 .. ^1])
  else:
    errorOut(&"unknown command \"web {args[0]}\"", @["Valid commands: web smoke, web pack"])

proc dispatch*(args: seq[string]): Run =
  if args.len == 0:
    return runHome()
  let rest = args[1 .. ^1]
  case args[0]
  of "art": runArt(rest)
  of "new": runNew(rest)
  of "test": runTest(rest)
  of "check": runCheck(rest)
  of "save": runSave(rest)
  of "backup": runBackup(rest)
  of "build": runBuild(rest)
  of "sim": runSim(rest)
  of "shot": runShot(rest)
  of "driver": runDriverCommand(rest)
  of "live": runLive(rest)
  of "web": runWeb(rest)
  of "producer-context": runProducerContext(rest)
  of "studio": runStudio(rest)
  of "setup": runGroup("setup", "hooks", rest, setupHooksHelp, runSetupHooks)
  of "--version": ("para 0.1.0\n", 0)
  of "--help", "-h": (paraHelp, 0)
  else:
    if args[0].startsWith("-"):
      errorOut(&"unknown flag \"{args[0]}\"", @["Valid flags: --help, --version"])
    else:
      errorOut(&"unknown command \"{args[0]}\"",
        @["Valid commands: " & paraCommands.join(", "), "Run `para --help` to see all commands"])

when isMainModule:
  let run = dispatch(commandLineParams())
  stdout.write(run.output)
  quit(run.code)
