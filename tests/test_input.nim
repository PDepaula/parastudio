# paraloop - loop, the nim game engine
# SPDX-License-Identifier: MIT
# Headless tests for paraloop/input: key state, the tick-indexed input-script
# grammar (loud errors included), and replay. No paranim/GL — pure Nim.

import unittest, strutils
import sets
import paraloop/input

suite "input: KeyState":
  test "press marks down and just-pressed; release keeps just-pressed until the tick ends":
    var ks = newKeyState()
    check not ks.isDown(KeyW)
    check not ks.wasPressed(KeyW)
    ks.press(KeyW)
    check ks.isDown(KeyW)
    check ks.wasPressed(KeyW)
    ks.release(KeyW)
    check not ks.isDown(KeyW)
    check ks.wasPressed(KeyW)                # cleared at the boundary, not on release
    ks.endTick()
    check not ks.wasPressed(KeyW)

  test "releasing a key that is not held is a no-op; duplicate press is idempotent":
    var ks = newKeyState()
    ks.release(KeyW)
    check not ks.isDown(KeyW)
    check not ks.wasPressed(KeyW)
    ks.press(KeyW)
    ks.press(KeyW)
    check ks.isDown(KeyW)
    check ks.wasPressed(KeyW)

suite "input: engine channel":
  test "keyDown / keyUp drive engineKeys, read by the game":
    engineKeys = newKeyState()                # isolate
    check not engineKeys.isDown(KeyEnter)
    keyDown(KeyEnter)
    check engineKeys.isDown(KeyEnter)
    check engineKeys.wasPressed(KeyEnter)
    keyUp(KeyEnter)
    check not engineKeys.isDown(KeyEnter)
    check engineKeys.wasPressed(KeyEnter)     # still just-pressed until endTick
    endTick(engineKeys)
    check not engineKeys.wasPressed(KeyEnter)

suite "input: parseScript":
  test "empty script is the valid empty replay":
    let s = parseScript("")
    check s.events.len == 0
    check s.maxTick == 0

  test "default hold: release one tick after the press":
    let s = parseScript("60:enter")
    check s.events.len == 2
    check s.events[0] == KeyEvent(key: KeyEnter, tick: 60, release: false)
    check s.events[1] == KeyEvent(key: KeyEnter, tick: 61, release: true)
    check s.maxTick == 61

  test "explicit hold":
    let s = parseScript("300:d:15")
    check s.events[0] == KeyEvent(key: KeyD, tick: 300, release: false)
    check s.events[1] == KeyEvent(key: KeyD, tick: 315, release: true)
    check s.maxTick == 315

  test "multiple items, whitespace tolerated, events sorted by tick":
    let s = parseScript(" 10:w , 5:a , 20:w:2 ")
    check s.events.len == 6
    check s.events[0].key == KeyA and s.events[0].tick == 5
    check s.events[1].key == KeyA and s.events[1].tick == 6 and s.events[1].release
    check s.events[2].key == KeyW and s.events[2].tick == 10
    check s.events[3].key == KeyW and s.events[3].tick == 11 and s.events[3].release
    check s.events[4].key == KeyW and s.events[4].tick == 20
    check s.events[5].key == KeyW and s.events[5].tick == 22 and s.events[5].release
    check s.maxTick == 22

  test "unknown key fails loudly, names the item, and lists the valid keys":
    var failed = false
    try:
      discard parseScript("60:enter, 70:qwerty")
    except KeyScriptError as e:
      failed = true
      check "item 2" in e.msg
      check "\"qwerty\"" in e.msg
      check "valid keys:" in e.msg
      # the valid-key list is the whole script vocabulary, not an abbreviation
      check "0, 1, 2" in e.msg
      for k in ["w", "enter", "escape", "space", "delete", "f1", "f12", "pageup", "tab"]:
        doAssert k in e.msg, "valid keys list must mention " & k
    check failed

  test "key names match exactly: no case folding, no aliases":
    for (bad, name) in [("60:D", "D"), ("60:esc", "esc"), ("60:Enter", "Enter")]:
      var failed = false
      try:
        discard parseScript(bad)
      except KeyScriptError as e:
        failed = true
        doAssert "item 1" in e.msg, "message should name the item: " & e.msg
        doAssert "unknown key \"" & name & "\"" in e.msg, e.msg
        doAssert "valid keys:" in e.msg, e.msg
      doAssert failed, "should have failed for " & bad

  test "overlapping holds on the same key fail loudly and name both items":
    var failed = false
    try:
      discard parseScript("10:d:10, 5:w, 15:d:2")
    except KeyScriptError as e:
      failed = true
      check "item 3" in e.msg
      check "ticks 15..16" in e.msg
      check "item 1" in e.msg
      check "ticks 10..19" in e.msg
    check failed
    for bad in ["10:a, 10:a", "12:a:3, 10:a:3", "10:a:3, 12:a"]:
      var raised = false
      try:
        discard parseScript(bad)
      except KeyScriptError:
        raised = true
      doAssert raised, "should have failed for " & bad

  test "holds on different keys may overlap":
    let s = parseScript("10:d:10, 15:w:2")
    check s.events.len == 4

  test "malformed items fail loudly and name the offending item":
    let bads = [
      ("enter", ""),                                  # tickless
      ("60", "malformed"),                            # no key
      ("60:enter:15:extra", "malformed"),             # too many parts
      ("x:enter", "bad tick"),
      ("60:enter:x", "bad hold"),
      ("60:enter:0", "hold must be at least 1"),
      ("0:enter", "ticks start at 1"),
      ("0:enter:5", "ticks start at 1"),
    ]
    for (bad, want) in bads:
      var failed = false
      try:
              discard parseScript(bad)
      except KeyScriptError as e:
        failed = true
        doAssert "item 1" in e.msg, "message should name the item: " & e.msg
        if want.len > 0:
          doAssert want in e.msg, "expected \"" & want & "\" in: " & e.msg
      doAssert failed, "should have failed for " & $bad

  test "an empty item inside a script (trailing comma) fails loudly":
    var failed = false
    try:
      discard parseScript("60:enter,")
    except KeyScriptError as e:
      failed = true
      check "item 2" in e.msg
    check failed

suite "input: replay":
  test "a script drives key state tick for tick":
    let r = newReplay(parseScript("60:enter, 300:d:15"))
    var ks = newKeyState()
    for t in 1 .. 315:
      step(r, ks, t)
      if t == 59:
        check not ks.isDown(KeyEnter) and not ks.isDown(KeyD)
      if t == 60:
        check ks.isDown(KeyEnter) and ks.wasPressed(KeyEnter)
      if t == 61:
        check not ks.isDown(KeyEnter)
        check not ks.wasPressed(KeyEnter)          # tick 61's own endTick clears it
      if t == 299:
        check not ks.isDown(KeyD)
      if t == 300:
        check ks.isDown(KeyD) and ks.wasPressed(KeyD)
      if t == 314:
        check ks.isDown(KeyD)
      if t == 315:
        check not ks.isDown(KeyD)
      endTick(ks)

  test "a re-press on the release tick keeps the key held (releases before presses)":
    # 60:a:2 → down at 60, up at 62; 62:a → down at 62, up at 63:
    # 'a' is held continuously 60..62.
    let r = newReplay(parseScript("62:a, 60:a:2"))
    check r.maxTick == 63
    var ks = newKeyState()
    for t in 1 .. 63:
      step(r, ks, t)
      if t == 60: doAssert ks.isDown(KeyA), "down at press tick"
      if t == 61: doAssert ks.isDown(KeyA), "still held during hold"
      if t == 62: doAssert ks.isDown(KeyA), "re-pressed on its release tick"
      if t == 63: doAssert not ks.isDown(KeyA), "gone after the re-press's release"
      endTick(ks)

  test "just-pressed tracks presses across ticks":
    let r = newReplay(parseScript("60:a"))
    var ks = newKeyState()
    var sawPressTick = -1
    for t in 1 .. 62:
      step(r, ks, t)
      if ks.wasPressed(KeyA): sawPressTick = t
      endTick(ks)
    check sawPressTick == 60

  test "an empty script steps nothing at any tick":
    let r = newReplay(parseScript(""))
    var ks = newKeyState()
    for t in 1 .. 100:
      step(r, ks, t)
      endTick(ks)
    check ks.pressed == initHashSet[int]()
    check ks.justPressed == initHashSet[int]()

suite "input: PointerState":
  test "press marks down and just-pressed; release keeps just-pressed until the tick ends":
    var ps = newPointerState()
    check not ps.isDown(LeftButton)
    ps.press(LeftButton)
    check ps.isDown(LeftButton) and ps.wasPressed(LeftButton)
    ps.release(LeftButton)
    check not ps.isDown(LeftButton)
    check ps.wasPressed(LeftButton)
    ps.endTick()
    check not ps.wasPressed(LeftButton)

  test "moving leaves the buttons alone, and the buttons leave the position alone":
    var ps = newPointerState()
    ps.press(RightButton)
    ps.movePointer(480, 300)
    check (ps.x, ps.y) == (480, 300)
    check ps.isDown(RightButton) and not ps.isDown(LeftButton)
    ps.release(RightButton)
    check (ps.x, ps.y) == (480, 300)

  test "pointerMove / buttonDown / buttonUp drive enginePointer; unread buttons are ignored":
    enginePointer = newPointerState()
    pointerMove(12, 34)
    buttonDown(0)
    buttonDown(4)
    check (enginePointer.x, enginePointer.y) == (12, 34)
    check enginePointer.buttons == {LeftButton}
    buttonUp(0)
    check enginePointer.buttons == {}
    check enginePointer.justPressed == {LeftButton}
    enginePointer = newPointerState()

suite "input: pointer scripts":
  test "ptr moves the pointer on its tick and does not press":
    let s = parseScript("40:ptr:480,300")
    check s.events.len == 0
    check s.pointerEvents == @[PointerEvent(tick: 40, kind: PointerMove, x: 480, y: 300)]
    check s.maxTick == 40

  test "click is a move, a press, and a release one tick later":
    let s = parseScript("60:click:480,300")
    check s.pointerEvents == @[
      PointerEvent(tick: 60, kind: PointerMove, x: 480, y: 300),
      PointerEvent(tick: 60, kind: ButtonDown, button: LeftButton),
      PointerEvent(tick: 61, kind: ButtonUp, button: LeftButton)]
    check s.maxTick == 61

  test "click and rclick take a hold, and a pointer item mixes with key items":
    let s = parseScript("10:d:5,60:click:480,300:30,70:rclick:96,48,5:a")
    check s.events.len == 4
    check s.pointerEvents.len == 6
    check PointerEvent(tick: 71, kind: ButtonUp, button: RightButton) in s.pointerEvents
    check s.pointerEvents[^1] == PointerEvent(tick: 90, kind: ButtonUp, button: LeftButton)
    check s.maxTick == 90

  test "the comma of x,y is not an item boundary, but a stray piece still fails":
    check parseScript("60:click:1,2,70:enter").events.len == 2
    for bad in ["60:click:480", "60:click:480,", "60:click:480,x", "60:click:,300",
                "60:click:480,300:0", "60:click:480,300:1:2", "60:ptr:480,300:5",
                "60:ptr:480", "60:click", "60:click:", "0:click:1,2", "60:click:1,2,3",
                "60:rclick:-1,2"]:
      expect KeyScriptError:
        discard parseScript(bad)

  test "an error names the offending pointer item":
    try:
      discard parseScript("10:w,60:click:480,abc")
      fail()
    except KeyScriptError:
      let msg = getCurrentExceptionMsg()
      check "item 2" in msg and "60:click:480,abc" in msg and "y" in msg

  test "two clicks of the same button whose holds overlap fail, naming both":
    try:
      discard parseScript("60:click:1,1:10,65:click:2,2")
      fail()
    except KeyScriptError:
      let msg = getCurrentExceptionMsg()
      check "item 2" in msg and "item 1" in msg
    check parseScript("60:click:1,1:10,65:rclick:2,2").pointerEvents.len == 6
    check parseScript("60:click:1,1:5,65:click:2,2").pointerEvents.len == 6 # a re-press on the release tick

  test "a replay drives enginePointer through the key step, tick by tick":
    enginePointer = newPointerState()
    let r = newReplay(parseScript("5:ptr:10,20,60:click:480,300"))
    check r.maxTick == 61
    var ks = newKeyState()
    for t in 1 .. 62:
      step(r, ks, t)
      if t == 4: check (enginePointer.x, enginePointer.y) == (0, 0)
      if t == 5: check (enginePointer.x, enginePointer.y) == (10, 20)
      if t == 60:
        check (enginePointer.x, enginePointer.y) == (480, 300)
        check enginePointer.isDown(LeftButton) and enginePointer.wasPressed(LeftButton)
      if t == 61: check not enginePointer.isDown(LeftButton)
      endTick(ks)
      endTick(enginePointer)
      if t == 60: check not enginePointer.wasPressed(LeftButton)
    enginePointer = newPointerState()

  test "a replay into its own PointerState leaves enginePointer alone":
    enginePointer = newPointerState()
    let r = newReplay(parseScript("2:click:7,8"))
    var ks = newKeyState()
    var ps = newPointerState()
    step(r, ks, ps, 2)
    check (ps.x, ps.y) == (7, 8) and ps.wasPressed(LeftButton)
    check (enginePointer.x, enginePointer.y) == (0, 0)

  test "within a tick the release comes first, then the move, then the press":
    let r = newReplay(parseScript("60:click:1,1:5,65:click:9,9"))
    var ks = newKeyState()
    var ps = newPointerState()
    for t in 1 .. 65:
      step(r, ks, ps, t)
      endTick(ps)
    check (ps.x, ps.y) == (9, 9)
    check ps.isDown(LeftButton) # re-pressed on the release tick
