## Sound effects for paraloop games: a recipe is a handful of synth tones
## (data), rendered once at startup to 16-bit PCM and handed to a `Backend`
## that plays it. Ported from parasurvivors' `audio.nim` (synthesise at
## startup -> one sound per effect, restarted on each play) with the
## paramidi/soundfont generator swapped for the tiny synth below: no 31 MB
## soundfont to embed, and a render that is exact and reproducible, so it can
## be unit tested.
##
## This module is pure Nim: it never imports `parasound`, so a game's headless
## logic and tests can use it and `para test`, `para sim` and `para shot` never
## open or require an audio device. The device is `paraloop/audio_device`
## (miniaudio natively, Web Audio under `-d:emscripten`; imported by a game's
## own entry point); anything that never installs a backend is silent --
## `Audio()` is a no-op player, and `NullBackend` is one that records what it
## was asked to play.
##
## Pieces:
## - `Tone`/`Recipe`: the synth description (SFX are rows of these, in the
##   game's `data.nim`); `render`, `toWav`: offline synthesis.
##   `paraloop/tune` writes a row's tones as a line of text instead.
## - `Audio`: `initAudio` renders every recipe into a backend slot; `play`
##   (with a volume), `setMaster`, `setMuted`/`toggleMute`, `shutdown`.
## - `Throttle`: deterministic rate limiting of cues, counted in sim ticks
##   (never wall-clock), so a burst of pickups or hits cannot become noise.
##
## Config (native): `PARALOOP_AUDIO=off` never opens a device,
## `PARALOOP_VOLUME=NN` sets the master volume in percent (`audioDisabled`,
## `configuredMaster`).

import std/[math, algorithm, os, strutils, sequtils]

const
  sampleRate* = 44100 ## Hz; every recipe renders mono at this rate

type
  Wave* = enum
    Sine, Square, Triangle, Saw, Noise
      ## `Noise` is white noise through a one-pole low-pass whose brightness
      ## follows the tone's pitch (a higher note is a brighter hiss).

  Tone* = object
    ## One synth voice, positioned in its recipe. Pitch is a MIDI note number
    ## (69 = A4, 440 Hz; fractions allowed) gliding linearly from `note` to
    ## `noteEnd` over the tone. `gain` is 0..1 before the recipe's mix; the
    ## envelope is a linear attack and release (decay) around full level.
    wave*: Wave
    startMs*, lenMs*: int
    note*, noteEnd*: float
    gain*: float
    attackMs*, releaseMs*: int

  Recipe* = object
    ## A named effect: tones summed (and clamped) into one mono buffer, as
    ## long as the latest tone ends.
    name*: string
    tones*: seq[Tone]

func tone*(wave: Wave, startMs, lenMs: int, note: float, noteEnd = NaN,
           gain = 0.5, attackMs = 4, releaseMs = -1): Tone =
  ## A row-friendly constructor: `noteEnd` defaults to a steady `note`, the
  ## release to the whole tone after its attack (a plain decay).
  Tone(wave: wave, startMs: startMs, lenMs: lenMs, note: note,
       noteEnd: if noteEnd.isNaN: note else: noteEnd, gain: gain,
       attackMs: attackMs, releaseMs: if releaseMs < 0: lenMs - attackMs else: releaseMs)

func midiHz*(note: float): float =
  ## MIDI note number to Hz (69 = 440 Hz).
  440.0 * pow(2.0, (note - 69.0) / 12.0)

func msToFrames*(ms: int): int =
  ms * sampleRate div 1000

func recipeMs*(r: Recipe): int =
  ## The recipe's length in milliseconds: the latest tone's end.
  for t in r.tones:
    result = max(result, t.startMs + t.lenMs)

func recipeFrames*(r: Recipe): int =
  ## The exact length `render` produces.
  msToFrames(recipeMs(r))

func envelope(t: Tone, i, n: int): float =
  ## Linear attack in, linear release out, over the tone's `n` frames.
  let a = msToFrames(t.attackMs)
  let r = msToFrames(t.releaseMs)
  result = 1.0
  if a > 0 and i < a:
    result = float(i) / float(a)
  if r > 0 and i >= n - r:
    result = min(result, float(n - i) / float(r))

func render*(r: Recipe): seq[int16] =
  ## The recipe as mono 16-bit PCM at `sampleRate`: reproducible (the noise is
  ## a fixed-seed generator per tone) and exactly `recipeFrames(r)` long.
  let total = recipeFrames(r)
  var mix = newSeq[float](total)
  for ti, t in r.tones:
    let start = msToFrames(t.startMs)
    let n = min(msToFrames(t.lenMs), total - start)
    var
      phase = 0.0
      noise = uint32(0x9E3779B9'u32) xor uint32(ti * 7919 + 1)
      lp = 0.0
    for i in 0 ..< n:
      let f = if n > 1: float(i) / float(n - 1) else: 0.0
      let hz = midiHz(t.note + (t.noteEnd - t.note) * f)
      var s: float
      case t.wave
      of Sine: s = sin(2.0 * PI * phase)
      of Square: s = (if phase < 0.5: 1.0 else: -1.0)
      of Triangle: s = 4.0 * abs(phase - 0.5) - 1.0
      of Saw: s = 2.0 * phase - 1.0
      of Noise:
        noise = noise * 1664525'u32 + 1013904223'u32
        let white = float(noise shr 8) / float(1 shl 23) - 1.0
        lp += (white - lp) * min(1.0, hz / float(sampleRate div 2))
        s = lp * 2.0
      phase += hz / float(sampleRate)
      phase -= floor(phase)
      mix[start + i] += s * t.gain * envelope(t, i, n)
  result = newSeq[int16](total)
  for i, v in mix:
    result[i] = int16(round(clamp(v, -1.0, 1.0) * 32767.0))

proc put16(b: var seq[byte], v: int) =
  b.add byte(v and 0xff)
  b.add byte((v shr 8) and 0xff)

proc put32(b: var seq[byte], v: int) =
  put16(b, v and 0xffff)
  put16(b, (v shr 16) and 0xffff)

proc toWav*(samples: openArray[int16], rate = sampleRate): seq[byte] =
  ## A mono 16-bit RIFF/WAVE file in memory (44-byte header + the samples),
  ## the form miniaudio's decoder reads.
  let dataBytes = samples.len * 2
  result = newSeqOfCap[byte](44 + dataBytes)
  for c in "RIFF": result.add byte(c)
  put32(result, 36 + dataBytes)
  for c in "WAVEfmt ": result.add byte(c)
  put32(result, 16)
  put16(result, 1) # PCM
  put16(result, 1) # mono
  put32(result, rate)
  put32(result, rate * 2)
  put16(result, 2)
  put16(result, 16)
  for c in "data": result.add byte(c)
  put32(result, dataBytes)
  for s in samples:
    put16(result, int(s) and 0xffff)

# ---------------------------------------------------------------- backends

type
  Backend* = ref object of RootObj
    ## Where rendered sounds go. `paraloop/audio_device` has the miniaudio
    ## one and `paraloop/audio_web` the Web Audio one; `NullBackend` records
    ## instead of playing.

  NullBackend* = ref object of Backend
    ## Accepts every sound and plays none: what `para test` and headless runs
    ## use, and a recorder for tests (`loaded`, `plays`, `master`).
    loaded*: seq[int]
    plays*: seq[tuple[slot: int, volume: float]]
    master*: float

method load*(b: Backend, slot: int, pcm: openArray[int16], rate: int): bool {.base.} =
  ## Registers `pcm` (mono 16-bit samples at `rate` Hz) under `slot`; false
  ## when it cannot be loaded. The backend copies what it needs: `pcm` is the
  ## caller's, only valid for the call.
  false

method play*(b: Backend, slot: int, volume: float) {.base.} =
  ## Starts the sound in `slot` from its beginning at `volume` (0..1).
  discard

method setMaster*(b: Backend, volume: float) {.base.} =
  discard

method close*(b: Backend) {.base.} =
  discard

method load*(b: NullBackend, slot: int, pcm: openArray[int16], rate: int): bool =
  b.loaded.add slot
  true

method play*(b: NullBackend, slot: int, volume: float) =
  b.plays.add (slot, volume)

method setMaster*(b: NullBackend, volume: float) =
  b.master = volume

# ---------------------------------------------------------------- the player

type
  Audio* = object
    ## The engine's sound player. `Audio()` has no backend and is silent.
    backend: Backend
    loaded: seq[bool]
    master: float
    muted: bool

proc applyMaster(a: Audio) =
  if a.backend != nil:
    a.backend.setMaster(if a.muted: 0.0 else: a.master)

proc initAudio*(backend: Backend, recipes: openArray[Recipe], master = 0.7): Audio =
  ## Renders every recipe and loads it into `backend` under its index in
  ## `recipes`. A nil backend (no device) is the silent player; a recipe the
  ## backend refuses stays unloaded and plays as nothing.
  result.master = clamp(master, 0.0, 1.0)
  result.backend = backend
  result.loaded = newSeq[bool](recipes.len)
  if backend == nil:
    return
  for i, r in recipes:
    result.loaded[i] = backend.load(i, render(r), sampleRate)
  result.applyMaster()

func enabled*(a: Audio): bool =
  ## Whether anything will ever be heard: a backend is installed. Callers
  ## skip the work of deciding what to play when it is false.
  a.backend != nil

func master*(a: Audio): float = a.master
func muted*(a: Audio): bool = a.muted

proc play*(a: Audio, slot: int, volume = 1.0) =
  ## Plays recipe `slot` at `volume` (times the master volume); nothing when
  ## muted, silent or the slot never loaded.
  if a.backend == nil or a.muted or slot < 0 or slot >= a.loaded.len or not a.loaded[slot]:
    return
  a.backend.play(slot, clamp(volume, 0.0, 1.0))

proc setMaster*(a: var Audio, volume: float) =
  a.master = clamp(volume, 0.0, 1.0)
  a.applyMaster()

proc setMuted*(a: var Audio, muted: bool) =
  a.muted = muted
  a.applyMaster()

proc toggleMute*(a: var Audio) =
  a.setMuted(not a.muted)

proc shutdown*(a: var Audio) =
  if a.backend != nil:
    a.backend.close()
    a.backend = nil

# ---------------------------------------------------------------- throttle

type
  Cue* = object
    ## A request to play recipe `slot`: louder `priority` wins a crowded tick,
    ## the same slot is not heard again within `gapTicks` ticks.
    slot*, priority*, gapTicks*: int
    volume*: float

  Throttle* = object
    ## Per-slot memory of the tick each slot last played on.
    lastTick: seq[int]

const neverPlayed = low(int) div 2 ## a tick so long ago no gap reaches it

proc pick*(t: var Throttle, tick: int, cues: openArray[Cue], maxVoices: int): seq[Cue] =
  ## The cues worth playing on `tick`, in play order: highest priority first
  ## (ties by slot), one per slot, none still inside its slot's `gapTicks`,
  ## at most `maxVoices`. Pure in `tick`, never the wall clock, so a replay
  ## always sounds the same.
  var order = @cues
  order.sort(proc (x, y: Cue): int =
    if x.priority != y.priority: cmp(y.priority, x.priority) else: cmp(x.slot, y.slot))
  for c in order:
    if result.len >= maxVoices: break
    if c.slot < 0 or result.anyIt(it.slot == c.slot): continue # one voice per slot per batch
    if c.slot >= t.lastTick.len:
      let had = t.lastTick.len
      t.lastTick.setLen(c.slot + 1)
      for i in had ..< t.lastTick.len:
        t.lastTick[i] = neverPlayed
    let since = tick - t.lastTick[c.slot]
    if since >= 0 and since < c.gapTicks: continue # a negative `since` is a restarted run's clock
    t.lastTick[c.slot] = tick
    result.add c

# ---------------------------------------------------------------- config

func audioDisabled*(value: string): bool =
  ## `PARALOOP_AUDIO=off` (also `0`, `false`, `no`) means never open a device.
  value.toLowerAscii in ["off", "0", "false", "no"]

func parseVolume*(value: string, fallback: float): float =
  ## A percent string (`"40"`) as a 0..1 volume; `fallback` when it is empty
  ## or not a number.
  try:
    clamp(parseFloat(value.strip) / 100.0, 0.0, 1.0)
  except ValueError:
    fallback

proc audioOff*(): bool =
  audioDisabled(getEnv("PARALOOP_AUDIO"))

proc configuredMaster*(default: float): float =
  ## The master volume: `PARALOOP_VOLUME` (percent) when set, else `default`.
  parseVolume(getEnv("PARALOOP_VOLUME"), default)
