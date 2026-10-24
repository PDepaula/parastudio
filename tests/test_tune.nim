## paraloop/tune, headless: a text score becomes the right tones (pitch,
## start, length), renders to a known PCM, evaluates at compile time and
## names the position of a bad character. Nothing here opens a device.

import std/[unittest, sequtils, strutils]
import paraloop/[audio, tune]

func fnv(pcm: openArray[int16]): int64 =
  ## FNV-1a over the samples: a stable fingerprint of a render.
  var h = 0xcbf29ce484222325'u64
  for s in pcm:
    h = (h xor uint64(uint16(s))) * 0x100000001b3'u64
  cast[int64](h)

func pcmHash(tones: seq[Tone]): int64 =
  fnv(render(Recipe(name: "t", tones: tones)))

const arpeggio = tune("o5 c16 e g >c") ## evaluated by the compiler

func notes(tones: seq[Tone]): seq[float] = tones.mapIt(it.note)
func starts(tones: seq[Tone]): seq[int] = tones.mapIt(it.startMs)
func lens(tones: seq[Tone]): seq[int] = tones.mapIt(it.lenMs)

proc rejects(text: string, at: int, what = ""): bool =
  ## Whether `tune(text)` raises a ValueError naming position `at`.
  try:
    discard tune(text)
    false
  except ValueError as e:
    (" at " & $at & " in ") in e.msg and what in e.msg

suite "tune: notes":
  test "the letters are the C major scale from middle C, o4 holds middle C":
    check tune("c d e f g a b").notes == @[60.0, 62, 64, 65, 67, 69, 71]
    check tune("o4 a").notes == @[69.0]

  test "+ sharpens and - flattens, and they stack":
    check tune("c+ d- f++ b--").notes == @[61.0, 61, 67, 69]

  test "o sets the octave, > goes up one and < down one":
    check tune("o5 c").notes == @[72.0]
    check tune("c > c > c < c").notes == @[60.0, 72, 84, 72]
    check tune("o2 c <c o4 c").notes == @[36.0, 24, 60]

  test "spaces and bar lines are ignored":
    check tune("c d|e f").notes == tune("cdef").notes
    check tune("  c\n\td ").notes == @[60.0, 62]

  test "wave and gain apply to every tone":
    for t in tune("c e g", Square, gain = 0.25):
      check t.wave == Square
      check t.gain == 0.25
    check tune("c")[0].wave == Triangle

suite "tune: time":
  test "a quarter note at 120 is 500 ms, one tone after another":
    let t = tune("c d e")
    check t.starts == @[0, 500, 1000]
    check t.lens == @[500, 500, 500]

  test "a length sticks until it changes":
    let t = tune("c8 d e c4 d")
    check t.lens == @[250, 250, 250, 500, 500]
    check t.starts == @[0, 250, 500, 750, 1250]

  test "tempo is quarter notes a minute":
    check tune("c", tempo = 60).lens == @[1000]
    check tune("c8", tempo = 60).lens == @[500]
    check tune("c1", tempo = 240).lens == @[1000]

  test "a rest advances time and sounds nothing":
    let t = tune("c2 r4 c4", tempo = 60)
    check t.starts == @[0, 3000]
    check t.len == 2

  test "a rest's length sticks too":
    check tune("r8 c d").starts == @[250, 500]

suite "tune: chords":
  test "notes joined by / start together":
    let t = tune("c/e/g d")
    check t.starts == @[0, 0, 0, 500]
    check t.notes == @[60.0, 64, 67, 62]

  test "the next note waits for the chord's longest note":
    let t = tune("c2/e8 g8")
    check t.starts == @[0, 0, 1000]
    check t.lens == @[1000, 250, 250]

  test "a chord can hold a rest":
    check tune("r/c d").starts == @[0, 500]

suite "tune: renders":
  test "the compile-time value is the run-time value":
    check arpeggio == tune("o5 c16 e g >c")
    check arpeggio.notes == @[72.0, 76, 79, 84]
    check arpeggio.starts == @[0, 125, 250, 375]
    check arpeggio.lens == @[125, 125, 125, 125]

  test "known tunes render to known PCM":
    check pcmHash(arpeggio) == 227682007747772442'i64
    check pcmHash(tune("o4 c2/e/g r4 c4/e/g", Square, tempo = 90, gain = 0.3)) ==
      972507222792047922'i64
    check render(Recipe(name: "t", tones: arpeggio)).len == msToFrames(500)

  test "a tune is a Recipe row: loaded and played through a backend":
    let backend = NullBackend()
    var player = initAudio(backend, [
      Recipe(name: "plain", tones: @[tone(Triangle, 0, 100, 69.0)]),
      Recipe(name: "melody", tones: tune("o5 c16 e g >c") & tone(Sine, 0, 500, 48.0))])
    check backend.loaded == @[0, 1]
    player.play(1, 0.8)
    check backend.plays == @[(slot: 1, volume: 0.8)]

suite "tune: bad input":
  test "an unknown character raises ValueError naming its position":
    check rejects("c x", 2, "'x'")
    check rejects("x", 0)
    check rejects("c d e h", 6, "'h'")
    check rejects("C", 0) # letters are lower case

  test "a number with no note or octave to belong to is bad":
    check rejects("c 4", 2)
    check rejects("4", 0)

  test "an accidental after a length is bad":
    check rejects("c4+", 2)

  test "o needs a number, a length is at least 1":
    check rejects("c o", 2, "octave")
    check rejects("c d0", 2, "length")

  test "a tempo below 1 is bad":
    expect ValueError: discard tune("c", tempo = 0)
