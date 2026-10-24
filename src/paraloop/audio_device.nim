## The device behind `paraloop/audio`'s `Backend`: `openDevice()` returns the
## platform's backend, or nil when there is no device (headless CI, a machine
## with no sound server, `PARALOOP_AUDIO=off`), which `initAudio` treats as the
## silent player.
##
## - Native: miniaudio, playing through the system's default output. Same shape
##   as parasurvivors' `audio.nim`: each rendered sound is wrapped as WAV and
##   decoded from memory into its own `ma_sound` on one `ma_engine`, and a
##   play seeks it to the start and restarts it.
## - Web (`-d:emscripten`): the Web Audio backend in `paraloop/audio_web`
##   (the browser half is `paraloop/web/audio.js`, linked by
##   `tools/web/build.sh`). It plays after the page's first key press, click or
##   touch; until then the browser keeps audio locked and plays are dropped.
## - `-d:noaudio`: a stub whose `openDevice` is nil, on every target.
##
## A game's entry point imports this under `when isMainModule` and opens it in
## `run`'s path only, so the logic modules, the tests, `para sim` and `para
## shot` (which import the game as a library) never compile a backend nor
## touch a device.

import paraloop/audio

when defined(noaudio):
  proc openDevice*(): Backend = nil
elif defined(emscripten):
  import paraloop/audio_web
  proc openDevice*(): Backend = openWebDevice()
else:
  import parasound/miniaudio
  import parasound/dr_wav # compiles the drwav symbols miniaudio.c's WAV decoder links against

  # Bindings parasound does not expose; the symbols live in its compiled
  # miniaudio.c (parasurvivors declares the same ones).
  proc ma_sound_seek_to_pcm_frame(pSound: pointer, frameIndex: uint64): ma_result {.cdecl, importc.}
  proc ma_sound_set_volume(pSound: pointer, volume: cfloat) {.cdecl, importc.}
  proc ma_engine_set_volume(pEngine: pointer, volume: cfloat): ma_result {.cdecl, importc.}

  # The opaque miniaudio structs live in `seq[uint64]`, not `seq[uint8]`: they
  # hold 64-bit atomics, which must be 8-aligned, and a byte seq's payload is
  # only 8-aligned by luck on x86-64 (on wasm32 it traps).
  type
    MiniaudioBackend = ref object of Backend
      engine: seq[uint64] ## opaque `ma_engine`, sized by `ma_engine_size`
      wavs: seq[seq[byte]] ## the decoders read these in place, so they live as long as the sounds
      decoders: seq[seq[uint64]]
      sounds: seq[seq[uint64]]
      ready: seq[bool]

  proc slotFor(b: MiniaudioBackend, slot: int) =
    if slot >= b.ready.len:
      b.wavs.setLen(slot + 1)
      b.decoders.setLen(slot + 1)
      b.sounds.setLen(slot + 1)
      b.ready.setLen(slot + 1)

  proc words(bytes: csize_t): int =
    ## How many uint64 words hold `bytes` bytes.
    (bytes.int + 7) div 8

  method load*(b: MiniaudioBackend, slot: int, pcm: openArray[int16], rate: int): bool =
    b.slotFor(slot)
    b.wavs[slot] = toWav(pcm, rate)
    b.decoders[slot] = newSeq[uint64](words(ma_decoder_size()))
    if MA_SUCCESS != ma_decoder_init_memory(b.wavs[slot][0].addr, b.wavs[slot].len.csize_t, nil,
                                            b.decoders[slot][0].addr):
      return false
    b.sounds[slot] = newSeq[uint64](words(ma_sound_size()))
    if MA_SUCCESS != ma_sound_init_from_data_source(b.engine[0].addr, b.decoders[slot][0].addr, 0,
                                                    nil, b.sounds[slot][0].addr):
      discard ma_decoder_uninit(b.decoders[slot][0].addr)
      return false
    b.ready[slot] = true
    true

  method play*(b: MiniaudioBackend, slot: int, volume: float) =
    if slot < 0 or slot >= b.ready.len or not b.ready[slot]: return
    ma_sound_set_volume(b.sounds[slot][0].addr, volume.cfloat)
    discard ma_sound_seek_to_pcm_frame(b.sounds[slot][0].addr, 0)
    discard ma_sound_start(b.sounds[slot][0].addr)

  method setMaster*(b: MiniaudioBackend, volume: float) =
    discard ma_engine_set_volume(b.engine[0].addr, volume.cfloat)

  method close*(b: MiniaudioBackend) =
    for i in 0 ..< b.ready.len:
      if b.ready[i]:
        ma_sound_uninit(b.sounds[i][0].addr)
        discard ma_decoder_uninit(b.decoders[i][0].addr)
        b.ready[i] = false
    ma_engine_uninit(b.engine[0].addr)

  proc openDevice*(): Backend =
    ## The default output device, or nil when `PARALOOP_AUDIO=off` or miniaudio
    ## cannot open one (it says which on stderr).
    if audioOff():
      return nil
    let b = MiniaudioBackend(engine: newSeq[uint64](words(ma_engine_size())))
    let res = ma_engine_init(nil, b.engine[0].addr)
    if MA_SUCCESS != res:
      stderr.writeLine "audio: no output device (" & $res & "), running silent"
      return nil
    b
