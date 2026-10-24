## paraloop/audio, headless: the synth is exact and reproducible, the WAV
## wrapper is well formed, the player routes to a backend (here a
## `NullBackend`: no device is ever opened) honouring volume, master and mute,
## and the throttle is deterministic in ticks.

import std/[unittest, sequtils, math, algorithm]
import paraloop/audio

const chirp = Recipe(name: "chirp", tones: @[
  tone(Sine, 0, 100, 69.0),
  tone(Square, 50, 100, 60.0, 72.0, gain = 0.3),
  tone(Noise, 0, 40, 80.0)])

type
  Picky = ref object of Backend
    played: int
  Closing = ref object of NullBackend
    closed: int
  Recorder = ref object of Backend
    pcm: seq[seq[int16]]
    rates: seq[int]

method load(b: Picky, slot: int, pcm: openArray[int16], rate: int): bool = slot != 1
method play(b: Picky, slot: int, volume: float) = inc b.played
method load(b: Recorder, slot: int, pcm: openArray[int16], rate: int): bool =
  b.pcm.add @pcm
  b.rates.add rate
  true
method close(b: Closing) = inc b.closed

suite "audio: synth":
  test "a recipe is as long as its latest tone, exactly":
    check recipeMs(chirp) == 150
    check recipeFrames(chirp) == 150 * sampleRate div 1000
    check render(chirp).len == recipeFrames(chirp)

  test "an empty recipe renders nothing":
    check render(Recipe(name: "none")).len == 0
    check recipeFrames(Recipe(name: "none")) == 0

  test "rendering is reproducible, sample for sample":
    check render(chirp) == render(chirp)

  test "a steady sine at A4 crosses zero 880 times a second":
    let pcm = render(Recipe(name: "a4", tones: @[tone(Sine, 0, 1000, 69.0, gain = 1.0,
                                                      attackMs = 0, releaseMs = 0)]))
    check pcm.len == sampleRate
    var crossings = 0
    for i in 1 ..< pcm.len:
      if (pcm[i - 1] < 0) != (pcm[i] < 0): inc crossings
    check abs(crossings - 880) <= 2

  test "tones past the recipe's end are cut, never overrun the buffer":
    check render(Recipe(name: "x", tones: @[tone(Saw, 0, 20, 60.0), tone(Saw, 10, 20, 60.0)])).len ==
      msToFrames(30)

  test "the mix is clamped to 16 bits, however many tones pile up":
    let loud = Recipe(name: "loud", tones: toSeq(1 .. 12).mapIt(
      tone(Square, 0, 50, 60.0, gain = 1.0, attackMs = 0, releaseMs = 0)))
    for s in render(loud):
      check s >= -32767 and s <= 32767

  test "the envelope fades the tone in and out":
    let pcm = render(Recipe(name: "e", tones: @[tone(Square, 0, 100, 60.0, gain = 1.0,
                                                     attackMs = 20, releaseMs = 40)]))
    check pcm[0] == 0
    check abs(int(pcm[pcm.len div 2])) > 20000
    check abs(int(pcm[^1])) < 2000

  test "midiHz is the equal-tempered scale":
    check abs(midiHz(69.0) - 440.0) < 1e-9
    check abs(midiHz(81.0) - 880.0) < 1e-9
    check abs(midiHz(60.0) - 261.6255653) < 1e-6

suite "audio: WAV":
  test "the wrapper is a mono 16-bit RIFF file the samples fit in exactly":
    let pcm = render(chirp)
    let wav = toWav(pcm)
    check wav.len == 44 + pcm.len * 2
    check wav[0 .. 3] == @[byte('R'), byte('I'), byte('F'), byte('F')]
    check wav[8 .. 15] == "WAVEfmt ".mapIt(byte(it))
    check wav[36 .. 39] == "data".mapIt(byte(it))
    proc le32(i: int): int = int(wav[i]) or (int(wav[i + 1]) shl 8) or (int(wav[i + 2]) shl 16) or (int(wav[i + 3]) shl 24)
    check le32(4) == wav.len - 8
    check le32(24) == sampleRate
    check le32(40) == pcm.len * 2
    check int(wav[22]) == 1 # mono
    check int(wav[34]) == 16 # bits

  test "samples round-trip through the wrapper":
    let wav = toWav(@[int16 0, 1, -1, 32767, -32768])
    check wav[44 .. ^1] == @[byte 0, 0, 1, 0, 0xff, 0xff, 0xff, 0x7f, 0x00, 0x80]

suite "audio: the player":
  test "initAudio renders every recipe into its slot":
    let b = NullBackend()
    let a = initAudio(b, [chirp, chirp], master = 0.5)
    check b.loaded == @[0, 1]
    check b.master == 0.5
    check a.enabled

  test "a backend is handed each recipe's rendered PCM and its sample rate":
    let b = Recorder()
    discard initAudio(b, [chirp, Recipe(name: "none")])
    check b.pcm == @[render(chirp), newSeq[int16]()]
    check b.rates == @[sampleRate, sampleRate]

  test "play passes the volume (clamped) through at the slot":
    let b = NullBackend()
    let a = initAudio(b, [chirp, chirp])
    a.play(1, 0.25)
    a.play(0, 3.0)
    check b.plays == @[(slot: 1, volume: 0.25), (slot: 0, volume: 1.0)]

  test "an unknown slot plays nothing":
    let b = NullBackend()
    let a = initAudio(b, [chirp])
    a.play(5)
    a.play(-1)
    check b.plays.len == 0

  test "mute drops the engine to zero and stops plays; unmute restores the master":
    let b = NullBackend()
    var a = initAudio(b, [chirp], master = 0.6)
    a.toggleMute()
    check a.muted
    check b.master == 0.0
    a.play(0)
    check b.plays.len == 0
    a.toggleMute()
    check not a.muted
    check b.master == 0.6
    a.play(0)
    check b.plays.len == 1

  test "the master volume is clamped and survives a mute":
    let b = NullBackend()
    var a = initAudio(b, [chirp])
    a.setMaster(2.0)
    check a.master == 1.0
    check b.master == 1.0
    a.setMuted(true)
    a.setMaster(0.3)
    check b.master == 0.0
    a.setMuted(false)
    check b.master == 0.3

  test "no backend is the silent player: nothing to do, nothing to fail":
    var a = initAudio(nil, [chirp])
    check not a.enabled
    a.play(0)
    a.toggleMute()
    a.shutdown()
    var plain: Audio
    plain.play(0)
    check not plain.enabled

  test "a backend that refuses a recipe leaves its slot silent":
    let b = Picky()
    let a = initAudio(b, [chirp, chirp, chirp])
    a.play(0)
    a.play(1)
    a.play(2)
    check b.played == 2

  test "shutdown closes the backend once and goes silent":
    let b = Closing()
    var a = initAudio(b, [chirp])
    a.shutdown()
    a.shutdown()
    check b.closed == 1
    check not a.enabled
    a.play(0)
    check b.plays.len == 0

suite "audio: throttle":
  proc cue(slot, priority, gap: int): Cue =
    Cue(slot: slot, priority: priority, gapTicks: gap, volume: 1.0)

  test "the same slot twice in one batch plays once":
    var t: Throttle
    check t.pick(10, [cue(1, 5, 0), cue(1, 5, 0)], 4).len == 1

  test "a slot is held back for its gap, counted in ticks":
    var t: Throttle
    check t.pick(10, [cue(1, 5, 4)], 4).len == 1
    check t.pick(11, [cue(1, 5, 4)], 4).len == 0
    check t.pick(13, [cue(1, 5, 4)], 4).len == 0
    check t.pick(14, [cue(1, 5, 4)], 4).len == 1

  test "a held-back cue does not extend its own hold":
    var t: Throttle
    discard t.pick(10, [cue(1, 5, 4)], 4)
    for tick in 11 .. 13:
      check t.pick(tick, [cue(1, 5, 4)], 4).len == 0
    check t.pick(14, [cue(1, 5, 4)], 4).len == 1

  test "a crowded batch keeps the highest priorities, ties by slot":
    var t: Throttle
    let got = t.pick(1, [cue(7, 1, 0), cue(3, 9, 0), cue(2, 5, 0), cue(5, 5, 0)], 3)
    check got.mapIt(it.slot) == @[3, 2, 5]

  test "a cue the cap dropped is not marked as played":
    var t: Throttle
    discard t.pick(1, [cue(1, 9, 10), cue(2, 1, 10)], 1)
    check t.pick(2, [cue(2, 1, 10)], 1).len == 1

  test "the order cues arrive in does not change the outcome":
    let cues = [cue(4, 3, 0), cue(1, 3, 0), cue(9, 8, 0), cue(2, 1, 0)]
    var a, b: Throttle
    check a.pick(1, cues, 3) == b.pick(1, cues.toSeq.reversed, 3)

  test "a restarted clock (ticks going backwards) is not stuck behind the old run":
    var t: Throttle
    discard t.pick(5000, [cue(1, 5, 60)], 4)
    check t.pick(3, [cue(1, 5, 60)], 4).len == 1

  test "the same cues on the same ticks always give the same plays":
    proc play(): seq[int] =
      var t: Throttle
      for tick in 1 .. 200:
        for c in t.pick(tick, [cue(tick mod 3, 1, 7), cue(tick mod 5, 2, 11)], 2):
          result.add tick * 10 + c.slot
    check play() == play()

suite "audio: config":
  test "PARALOOP_AUDIO off spellings":
    for v in ["off", "OFF", "0", "false", "no"]:
      check audioDisabled(v)
    for v in ["", "on", "1", "yes"]:
      check not audioDisabled(v)

  test "volume is a percent, clamped, with a fallback":
    check parseVolume("40", 0.7) == 0.4
    check parseVolume(" 250 ", 0.7) == 1.0
    check parseVolume("-5", 0.7) == 0.0
    check parseVolume("", 0.7) == 0.7
    check parseVolume("loud", 0.7) == 0.7
