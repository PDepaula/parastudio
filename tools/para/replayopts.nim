# The scripted-replay flags `para shot` and `para sim` share: `--script FILE`
# or `--keys "..."` (a tick-indexed input script in `paraloop/input`'s
# `parseScript` grammar), `--seed N` and `--size WxH`. Keeping them here means
# both commands read a script, a seed and a window size the same way, so a
# script that drives a golden frame drives the sim gate too.
#
# A script file is `parseScript` text with a few conveniences for files:
# one or more items per line (a trailing comma is fine), `#` starts a comment,
# and a `frame NAME=SPEC` line names a frame for `para shot` (`SPEC` is a tick
# `600` or a phase `@LevelUp`, see `shotcmd.parseFrames`). `--keys` takes the
# bare `parseScript` string.

import std/[strutils, strformat, sequtils]
import art/clihelpers
import paraloop/input

type
  NamedFrame* = tuple[name, spec: string]
    ## A `frame NAME=SPEC` line of a script file.

  ReplayScript* = object
    ## What `--script`/`--keys` resolved to. `source` is for messages; the
    ## empty script (no flag given) has no events and an empty `source`.
    script*: InputScript
    frames*: seq[NamedFrame]
    source*: string

proc isFrameName*(name: string): bool =
  ## A frame name is a file name stem: letters, digits, `_` and `-`, and not
  ## one of the built-in frame forms `title` or `t<N>`.
  name.len > 0 and name.allIt(it in IdentChars or it == '-') and not name[0].isDigit and
    name != "title" and not (name.len > 1 and name[0] == 't' and name[1 .. ^1].allCharsInSet(Digits))

proc splitScriptText(text: string): tuple[items: string, frames: seq[string]] =
  ## A script file's lines -> `parseScript` text plus its `frame` directives.
  var items: seq[string]
  for raw in text.splitLines:
    var line = raw
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    line = line.strip
    if line.len == 0: continue
    if line.startsWith("frame ") or line.startsWith("frame\t"):
      result.frames.add line[6 .. ^1].strip
    else:
      items.add line.strip(chars = {',', ' ', '\t'}, leading = false)
  result.items = items.join(",")

proc loadReplayScript*(file, keys: string, replay: var ReplayScript): Run =
  ## Code 0 with `replay` filled (empty when neither flag was given), or a
  ## usage error naming the unreadable file or the script item that does not
  ## parse (`parseScript`'s own message).
  replay = ReplayScript()
  if file.len > 0 and keys.len > 0:
    return errorOut("--script FILE and --keys \"...\" are two ways to give one script; pass one", @[])
  var text = keys
  if file.len > 0:
    try:
      text = readFile(file)
    except IOError, OSError:
      return errorOut(&"cannot read script {file}: {getCurrentExceptionMsg()}", @[])
    replay.source = file
  elif keys.len > 0:
    replay.source = "--keys"
  let (items, frames) = splitScriptText(text)
  try:
    replay.script = parseScript(items)
  except KeyScriptError:
    return errorOut(getCurrentExceptionMsg(),
      @["Items are <tick>:<key>[:<holdTicks>], comma-separated, ticks from 1: --keys \"60:enter,300:right:15\""])
  for f in frames:
    let kv = f.split('=', 1)
    if kv.len != 2 or not isFrameName(kv[0].strip) or kv[1].strip.len == 0:
      return errorOut(&"{replay.source}: bad frame line \"frame {f}\"",
        @["A frame line is `frame NAME=TICK` or `frame NAME=@Phase`, e.g. `frame levelup=@LevelUp`; NAME is letters, digits, `_` and `-`, not `title` or `t<N>`"])
    if replay.frames.anyIt(it.name == kv[0].strip):
      return errorOut(&"{replay.source}: frame \"{kv[0].strip}\" is named twice", @[])
    replay.frames.add (kv[0].strip, kv[1].strip)

proc parseSeedFlag*(text: string, seed: var int64): Run =
  try:
    seed = text.parseBiggestInt.int64
  except ValueError:
    return errorOut(&"--seed takes a whole number, got \"{text}\"", @[])
  ("", 0)

proc parseSizeFlag*(text: string, size: var tuple[width, height: int]): Run =
  ## `960x540` -> `(960, 540)`.
  let parts = text.toLowerAscii.split('x')
  var w, h = 0
  try:
    if parts.len == 2:
      w = parts[0].parseInt
      h = parts[1].parseInt
  except ValueError:
    w = 0
  if parts.len != 2 or w notin 1 .. 16384 or h notin 1 .. 16384:
    return errorOut(&"--size takes WIDTHxHEIGHT in pixels, got \"{text}\"",
      @["Example: --size 960x540"])
  size = (w, h)
  ("", 0)
