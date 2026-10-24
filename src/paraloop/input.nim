# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
## Keyboard and pointer input state for paraloop games, and a **tick-indexed**
## input script for headless replay.
##
## KeyState
## --------
## Key state is a plain `KeyState` object: which keys are down and which were
## pressed on the current tick (`justPressed`, cleared by `endTick` at the tick
## boundary — the game loop reads `wasPressed` and clears it, it does not clear
## on release). `engineKeys` is the engine-wide channel that the web entry
## points and `paraloop/app`'s window key callback write into, and `app.run`
## calls `endTick(engineKeys)` after every `step`; games read it (`hello` moves
## its sprite with the arrow keys). A scripted replay drives any `KeyState`
## object, so tests can run a replay headless without a window:
##
##     var keys = newKeyState()
##     let replay = newReplay(parseScript("60:enter,300:d:15"))
##     for tick in 1 .. replay.maxTick:
##       step(replay, keys, tick)
##       tickGame(keys)      # the game sees isDown / wasPressed
##       endTick(keys)
##
## Input scripts
## -------------
## Scripts index key activity by **game tick** — never wall-clock seconds — so
## a run plays back identically on any machine (deterministic simulation +
## input-snapshot replay is the core loop of the project):
##
##     script := item ("," item)*
##     item   := tick ":" key [":" hold]
##             | tick ":ptr:" x "," y
##             | tick ":" ("click" | "rclick") ":" x "," y [":" hold]
##
##     "60:enter"           press at tick 60, release at 61
##     "300:d:15"           press at 300, hold 15 ticks, release at 315
##     "40:ptr:480,300"     the pointer moves to window pixel (480, 300) on tick 40
##     "60:click:480,300"   move there and press the left button at tick 60,
##                          release at 61 (`rclick`: the right button;
##                          `:hold` ticks as for keys)
##
## A pointer item carries its own comma (`x,y`), so a comma-separated piece
## that follows a pointer item missing its `y` is that item's `y` (and hold).
## Pointer coordinates are framebuffer pixels from the window's top-left, as
## `PointerState` holds them.
##
## Ticks start at 1, matching the tick numbers `paraloop/app`'s `run` passes
## to `step`; a tick of 0 is rejected.
##
## The empty string is the empty replay (no events). Malformed items and
## unknown keys **fail loudly** with a `KeyScriptError` naming the offending
## item; an unknown key also lists the valid keys. Two items for the same key
## whose holds overlap also fail, naming both items; a re-press on the earlier
## item's release tick is fine. Nothing is ever silently skipped.
##
## PointerState
## -------------
## The pointer is `PointerState`: where it is (`x`, `y`, framebuffer pixels from
## the window's top-left) and which mouse buttons are down (`buttons`) or went
## down since the last `endTick` (`justPressed`). `enginePointer` is the
## engine-wide channel, beside `engineKeys`: `paraloop/app`'s cursor and button
## callbacks and the web entry points write it, and `app.stepTick` clears
## `justPressed` after each tick. A game turns it into world units itself
## (`render2d.screenToWorld`) and hands the sim the result as part of that
## tick's input, never as a fact, so hovering cannot change a state hash.
## `step(replay, keys, tick)` drives `enginePointer` with the keys, so a script
## replays clicks through the same `engineKeys`/`stepTick` loop every runner uses.
##
## Web entry points
## ----------------
## Under emscripten, `Module._psKeyDown(code)` / `Module._psKeyUp(code)`
## call `keyDown`/`keyUp` with a GLFW key code from `keyNames` — the shell
## drives input through these KEEPALIVE exports and never synthesises
## KeyboardEvents (the GLFW shim reads keyCode). `Module._psPointer(x, y)` moves
## the pointer (canvas pixels times `devicePixelRatio`) and
## `Module._psButton(button, down)` presses or releases a mouse button (GLFW
## numbering: 0 left, 1 right, 2 middle).

import sets, tables, strutils, sequtils, algorithm

type
  KeyState* = object
    ## `pressed`: keys currently down.
    ## `justPressed`: keys pressed since the last `endTick`; release does not
    ## clear it — `endTick` does, at the tick boundary.
    pressed*: HashSet[int]
    justPressed*: HashSet[int]

  MouseButton* = enum
    ## The buttons a script and a game read; the ordinals are GLFW's button numbers.
    LeftButton, RightButton, MiddleButton

  PointerState* = object
    ## `x`, `y`: the pointer in framebuffer pixels from the window's top-left.
    ## `buttons`: the buttons currently down. `justPressed`: the buttons pressed
    ## since the last `endTick`; release does not clear it.
    x*, y*: int
    buttons*: set[MouseButton]
    justPressed*: set[MouseButton]

  KeyScriptError* = object of ValueError
    ## An input script item is malformed, names an unknown key (the message
    ## lists the valid keys), or holds a key (or mouse button) while another
    ## item holds it.

  KeyEvent* = object
    ## One key change at a specific game tick.
    key*: int      ## a GLFW key code from `keyNames`
    tick*: int     ## the game tick at which the event fires
    release*: bool ## true: key goes up; false: key goes down

  PointerEventKind* = enum
    PointerMove, ButtonDown, ButtonUp

  PointerEvent* = object
    ## One pointer change at a specific game tick: the pointer moves to
    ## (`x`, `y`), or `button` goes down or up (those leave the position alone;
    ## a click item's press is a move then a `ButtonDown` on the same tick).
    tick*: int
    kind*: PointerEventKind
    x*, y*: int          ## where the pointer goes (`PointerMove` only)
    button*: MouseButton ## which button (`ButtonDown`, `ButtonUp` only)

  InputScript* = object
    ## A parsed script. `events` is in deterministic order: by ascending tick,
    ## and within a tick releases come before presses (a re-press on the
    ## release tick keeps the key down). `pointerEvents` is the pointer's, in
    ## the same order with moves between the releases and the presses (a click
    ## lands where its item says).
    events*: seq[KeyEvent]
    pointerEvents*: seq[PointerEvent]
    maxTick*: int  ## the last tick on which any event fires (0 if empty)

  Replay* = object
    ## A script indexed by tick, for stepping once per game tick in O(1).
    script*: InputScript
    byTick: Table[int, seq[KeyEvent]]
    pointerByTick: Table[int, seq[PointerEvent]]

const
  # GLFW key codes (GLFW 3, group __KEYS). Hard-coded so this module stays
  # headless: no paranim/GL imports here, tests can import without a display.
  KeySpace* = 32
  Key0* = 48
  Key1* = 49
  Key2* = 50
  Key3* = 51
  Key4* = 52
  Key5* = 53
  Key6* = 54
  Key7* = 55
  Key8* = 56
  Key9* = 57
  KeyA* = 65
  KeyB* = 66
  KeyC* = 67
  KeyD* = 68
  KeyE* = 69
  KeyF* = 70
  KeyG* = 71
  KeyH* = 72
  KeyI* = 73
  KeyJ* = 74
  KeyK* = 75
  KeyL* = 76
  KeyM* = 77
  KeyN* = 78
  KeyO* = 79
  KeyP* = 80
  KeyQ* = 81
  KeyR* = 82
  KeyS* = 83
  KeyT* = 84
  KeyU* = 85
  KeyV* = 86
  KeyW* = 87
  KeyX* = 88
  KeyY* = 89
  KeyZ* = 90
  KeyEscape* = 256
  KeyEnter* = 257
  KeyTab* = 258
  KeyBackspace* = 259
  KeyInsert* = 260
  KeyDelete* = 261
  KeyRight* = 262
  KeyLeft* = 263
  KeyDown* = 264
  KeyUp* = 265
  KeyPageUp* = 266
  KeyPageDown* = 267
  KeyHome* = 268
  KeyEnd* = 269
  KeyF1* = 290
  KeyF2* = 291
  KeyF3* = 292
  KeyF4* = 293
  KeyF5* = 294
  KeyF6* = 295
  KeyF7* = 296
  KeyF8* = 297
  KeyF9* = 298
  KeyF10* = 299
  KeyF11* = 300
  KeyF12* = 301

## Script-key name → GLFW key code. Names match exactly (lowercase) in scripts.
const
  keyNames* = {
    "space": KeySpace,
    "0": Key0, "1": Key1, "2": Key2, "3": Key3, "4": Key4,
    "5": Key5, "6": Key6, "7": Key7, "8": Key8, "9": Key9,
    "a": KeyA, "b": KeyB, "c": KeyC, "d": KeyD, "e": KeyE,
    "f": KeyF, "g": KeyG, "h": KeyH, "i": KeyI, "j": KeyJ,
    "k": KeyK, "l": KeyL, "m": KeyM, "n": KeyN, "o": KeyO,
    "p": KeyP, "q": KeyQ, "r": KeyR, "s": KeyS, "t": KeyT,
    "u": KeyU, "v": KeyV, "w": KeyW, "x": KeyX, "y": KeyY,
    "z": KeyZ,
    "escape": KeyEscape, "enter": KeyEnter,
    "tab": KeyTab, "backspace": KeyBackspace, "insert": KeyInsert,
    "delete": KeyDelete, "up": KeyUp, "down": KeyDown, "left": KeyLeft,
    "right": KeyRight, "home": KeyHome, "end": KeyEnd,
    "pageup": KeyPageUp, "pagedown": KeyPageDown,
    "f1": KeyF1, "f2": KeyF2, "f3": KeyF3, "f4": KeyF4, "f5": KeyF5,
    "f6": KeyF6, "f7": KeyF7, "f8": KeyF8, "f9": KeyF9, "f10": KeyF10,
    "f11": KeyF11, "f12": KeyF12
  }.toTable

proc validKeyListText*(): string =
  ## The sorted, comma-separated key names — used in error messages and
  ## available to tooling that wants to document the script vocabulary.
  var names: seq[string]
  for name in keyNames.keys:
    names.add name
  result = names.sorted.join(", ")

# ---- KeyState ---------------------------------------------------------------

proc newKeyState*(): KeyState =
  result.pressed = initHashSet[int]()
  result.justPressed = initHashSet[int]()

proc press*(ks: var KeyState, key: int) =
  ## A key goes down: marks it `pressed` and `justPressed`.
  ks.pressed.incl(key)
  ks.justPressed.incl(key)

proc release*(ks: var KeyState, key: int) =
  ## A key goes up: un-marks it `pressed`. A release of a key that is not down
  ## is a no-op, and release does not clear `justPressed`.
  ks.pressed.excl(key)

proc endTick*(ks: var KeyState) =
  ## Clear `justPressed` at a tick boundary (the game loop calls this once
  ## per tick, after it has read the state for that tick).
  ks.justPressed = initHashSet[int]()

proc isDown*(ks: KeyState, key: int): bool =
  ## Is `key` currently held down?
  ks.pressed.contains(key)

proc wasPressed*(ks: KeyState, key: int): bool =
  ## Was `key` pressed since the last `endTick`?
  ks.justPressed.contains(key)

# ---- the engine input channel ------------------------------------------------

# ---- PointerState ------------------------------------------------------------

proc newPointerState*(): PointerState =
  PointerState()

proc movePointer*(ps: var PointerState, x, y: int) =
  ## The pointer moves to framebuffer pixel (`x`, `y`).
  ps.x = x
  ps.y = y

proc press*(ps: var PointerState, button: MouseButton) =
  ## A button goes down: marks it down and `justPressed`.
  ps.buttons.incl button
  ps.justPressed.incl button

proc release*(ps: var PointerState, button: MouseButton) =
  ## A button goes up; a release of a button that is not down is a no-op, and
  ## release does not clear `justPressed`.
  ps.buttons.excl button

proc endTick*(ps: var PointerState) =
  ## Clear `justPressed` at a tick boundary, as for `KeyState`.
  ps.justPressed = {}

proc isDown*(ps: PointerState, button: MouseButton): bool =
  button in ps.buttons

proc wasPressed*(ps: PointerState, button: MouseButton): bool =
  button in ps.justPressed

var engineKeys* = newKeyState()
## The engine-wide key state: the native key callback and the web entry
## points (`keyDown`/`keyUp`) write here, games read it each tick. Tests may
## reset it to `newKeyState()`.

proc keyDown*(key: int) =
  ## A platform key-press event (native callback or `Module._psKeyDown`).
  press(engineKeys, key)

proc keyUp*(key: int) =
  ## A platform key-release event (native callback or `Module._psKeyUp`).
  release(engineKeys, key)

var enginePointer* = newPointerState()
## The engine-wide pointer: the native cursor and button callbacks and the web
## entry points write here, games read it each tick. Tests may reset it to
## `newPointerState()`.

proc pointerMove*(x, y: int) =
  ## A platform pointer-move event (native callback or `Module._psPointer`).
  movePointer(enginePointer, x, y)

proc buttonDown*(button: int) =
  ## A platform button-press event (native callback or `Module._psButton`). A
  ## button the game does not read (GLFW's 3 and up) is ignored.
  if button in ord(MouseButton.low) .. ord(MouseButton.high):
    press(enginePointer, MouseButton(button))

proc buttonUp*(button: int) =
  ## A platform button-release event.
  if button in ord(MouseButton.low) .. ord(MouseButton.high):
    release(enginePointer, MouseButton(button))

when defined(emscripten):
  ## KEEPALIVE entry points for the web shell, which sends GLFW key codes:
  ## `Module._psKeyDown(87)`, `Module._psKeyUp(87)`. The exportc route
  ## needs no `-s EXPORTED_FUNCTIONS` list. Native builds use `keyDown`/`keyUp`
  ## from the GLFW callback instead, so there is nothing to export.
  {.emit: "#include <emscripten.h>".}

  proc psKeyDown(key: cint) {.exportc, codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
    keyDown(key.int)

  proc psKeyUp(key: cint) {.exportc, codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
    keyUp(key.int)

  proc psPointer(x, y: cint) {.exportc, codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
    pointerMove(x.int, y.int)

  proc psButton(button, down: cint) {.exportc, codegenDecl: "EMSCRIPTEN_KEEPALIVE $# $#$#".} =
    if down != 0: buttonDown(button.int) else: buttonUp(button.int)

# ---- input-script parser -------------------------------------------------------

proc badItem(itemIdx: int, item, problem: string) {.raises: [KeyScriptError].} =
  ## Loud failure: name the offending item (1-based) and what is wrong.
  raise newException(KeyScriptError, "input script item " & $itemIdx & " (" & item &
    "): " & problem)

proc parseUintOr(raw: string, itemIdx: int, item, field: string): int =
  if raw.len in 1 .. 9 and raw.all(isDigit):
    return raw.parseInt
  badItem(itemIdx, item, "bad " & field & " \"" & raw &
    "\" (expected a non-negative integer)")

proc parseKeyOr(raw: string, itemIdx: int, item: string): int =
  if keyNames.hasKey(raw):
    return keyNames[raw]
  badItem(itemIdx, item, "unknown key \"" & raw &
    "\"; valid keys: " & validKeyListText())

const pointerItemKinds = ["ptr", "click", "rclick"]
  ## The script words that name a pointer item rather than a key.

const itemShapes = "expected <tick>:<key>[:<holdTicks>], <tick>:ptr:<x>,<y> or " &
  "<tick>:click:<x>,<y>[:<holdTicks>], e.g. \"60:enter\", \"300:d:15\" or \"60:click:480,300\""

proc splitItems(text: string): seq[string] =
  ## The script's comma-separated items, trimmed. A pointer item holds a comma
  ## of its own (`x,y`), so the piece after a `tick:ptr:x` / `tick:click:x`
  ## that is still missing its `y` belongs to that item.
  for piece in text.split(','):
    let item = piece.strip
    if result.len > 0 and ',' notin result[^1]:
      let parts = result[^1].split(':')
      if parts.len == 3 and parts[1].strip in pointerItemKinds:
        result[^1].add "," & item
        continue
    result.add item

proc parseScript*(text: string): InputScript =
  ## Parse a tick-indexed input script into `InputScript` (see the module
  ## header for the grammar). Raises `KeyScriptError`, never skips.
  if text.strip.len == 0:
    return InputScript(events: @[], maxTick: 0)

  type Hold = tuple[idx: int, item: string, at, until: int]
  var events: seq[KeyEvent]
  var pointerEvents: seq[tuple[idx: int, event: PointerEvent]]
  var holds: Table[int, seq[Hold]]
    ## keyed by key code, or by `-1 - ord(button)` for a mouse button
  let items = splitItems(text)
  for i in 0 ..< items.len:
    let item = items[i]
    if item.len == 0:
      badItem(i + 1, item, "empty item (" & itemShapes & ")")
    let parts = item.split(':')
    if parts.len < 2:
      badItem(i + 1, item, "malformed (" & itemShapes & ")")
    let at = parseUintOr(parts[0].strip, i + 1, item, "tick")
    if at < 1:
      badItem(i + 1, item, "tick must be at least 1 (ticks start at 1, as in app.run)")

    let word = parts[1].strip
    if word in pointerItemKinds:
      let isMove = word == "ptr"
      if parts.len notin (if isMove: [3, 3] else: [3, 4]):
        badItem(i + 1, item, "malformed (" & itemShapes & ")")
      let xy = parts[2].split(',')
      if xy.len != 2:
        badItem(i + 1, item, "malformed (a pointer item needs <x>,<y>; " & itemShapes & ")")
      let x = parseUintOr(xy[0].strip, i + 1, item, "x")
      let y = parseUintOr(xy[1].strip, i + 1, item, "y")
      pointerEvents.add (idx: i, event: PointerEvent(tick: at, kind: PointerMove, x: x, y: y))
      if not isMove:
        let hold = if parts.len == 4: parseUintOr(parts[3].strip, i + 1, item, "hold") else: 1
        if hold < 1:
          badItem(i + 1, item, "hold must be at least 1 tick")
        let button = if word == "click": LeftButton else: RightButton
        holds.mgetOrPut(-1 - ord(button), @[]).add (idx: i + 1, item: item, at: at, until: at + hold)
        pointerEvents.add (idx: i, event: PointerEvent(tick: at, kind: ButtonDown, button: button))
        pointerEvents.add (idx: i, event: PointerEvent(tick: at + hold, kind: ButtonUp, button: button))
      continue

    if parts.len notin [2, 3]:
      badItem(i + 1, item, "malformed (" & itemShapes & ")")
    let key = parseKeyOr(word, i + 1, item)
    let hold = if parts.len == 3:
      parseUintOr(parts[2].strip, i + 1, item, "hold")
    else:
      1
    if hold < 1:
      badItem(i + 1, item, "hold must be at least 1 tick")

    holds.mgetOrPut(key, @[]).add (idx: i + 1, item: item, at: at, until: at + hold)

    events.add KeyEvent(key: key, tick: at, release: false)
    events.add KeyEvent(key: key, tick: at + hold, release: true)

  var clash: tuple[later, other: Hold]
  for group in holds.mvalues:
    group.sort(proc (a, b: Hold): int = cmp((a.at, a.idx), (b.at, b.idx)))
    for j in 1 ..< group.len:
      let (prev, next) = (group[j - 1], group[j])
      if next.at < prev.until:
        let pair = if next.idx > prev.idx: (later: next, other: prev)
                   else: (later: prev, other: next)
        if clash.later.idx == 0 or pair.later.idx < clash.later.idx:
          clash = pair
  if clash.later.idx > 0:
    let (h, o) = clash
    badItem(h.idx, h.item, "holds ticks " & $h.at & ".." & $(h.until - 1) &
      ", overlapping item " & $o.idx & " (" & o.item & ") holding ticks " &
      $o.at & ".." & $(o.until - 1) & " on the same key or button")

  # Deterministic order: by tick, and within a tick releases (a key finishing)
  # come before presses (a key re-starting), so a re-press on the release tick
  # keeps the key down.
  events.sort(proc (a, b: KeyEvent): int =
    if a.tick != b.tick: return a.tick.cmp(b.tick)
    if a.release != b.release: return if a.release: -1 else: 1  # releases first
    return a.key.cmp(b.key))
  result.events = events
  if events.len > 0:
    result.maxTick = events[^1].tick

  # The pointer's order: by tick; within one, a button release, then the moves
  # (in script order, the last wins), then the presses, so a click lands on the
  # pixel its item names.
  func rank(kind: PointerEventKind): int =
    case kind
    of ButtonUp: 0
    of PointerMove: 1
    of ButtonDown: 2
  pointerEvents.sort(proc (a, b: tuple[idx: int, event: PointerEvent]): int =
    if a.event.tick != b.event.tick: return a.event.tick.cmp(b.event.tick)
    if a.event.kind != b.event.kind: return rank(a.event.kind).cmp(rank(b.event.kind))
    return a.idx.cmp(b.idx))
  for p in pointerEvents:
    result.pointerEvents.add p.event
  if pointerEvents.len > 0:
    result.maxTick = max(result.maxTick, result.pointerEvents[^1].tick)

# ---- replay ---------------------------------------------------------------

proc newReplay*(script: InputScript): Replay =
  ## Index a parsed script by tick, ready to be stepped once per game tick.
  result.script = script
  for e in script.events:
    if not result.byTick.hasKey(e.tick):
      result.byTick[e.tick] = @[]
    result.byTick[e.tick].add(e)
  for e in script.pointerEvents:
    result.pointerByTick.mgetOrPut(e.tick, @[]).add(e)

proc maxTick*(replay: Replay): int =
  ## The last tick on which the replay fires an event (0 if empty) — the
  ## highest tick to `step` to.
  replay.script.maxTick

proc step*(replay: Replay, pointer: var PointerState, tick: int) =
  ## Apply every pointer event scheduled for `tick` (releases, then moves, then
  ## presses) to `pointer`.
  for e in replay.pointerByTick.getOrDefault(tick):
    case e.kind
    of PointerMove: movePointer(pointer, e.x, e.y)
    of ButtonDown: press(pointer, e.button)
    of ButtonUp: release(pointer, e.button)

proc step*(replay: Replay, keys: var KeyState, pointer: var PointerState, tick: int) =
  ## Apply every event scheduled for `tick` to `keys` (releases before presses)
  ## and `pointer`. Ticks with no events do nothing.
  for e in replay.byTick.getOrDefault(tick):
    if e.release:
      release(keys, e.key)
    else:
      press(keys, e.key)
  step(replay, pointer, tick)

proc step*(replay: Replay, keys: var KeyState, tick: int) =
  ## `step` into `keys`, with the script's pointer events going to the engine
  ## channel `enginePointer`: the runners that drive a game through `engineKeys`
  ## (`para sim`, a test) replay clicks without a second argument.
  step(replay, keys, enginePointer, tick)
