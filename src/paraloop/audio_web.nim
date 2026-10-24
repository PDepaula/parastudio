## The Web Audio backend for `paraloop/audio` (emscripten only):
## `openWebDevice()` returns a `Backend` that plays through the browser's
## `AudioContext`, or nil when the page has none (or `paraloop/web/audio.js`
## was not linked into the build), which `initAudio` treats as the silent
## player. `paraloop/audio_device` picks it under `-d:emscripten`.
##
## The work is in `paraloop/web/audio.js`, linked into the wasm module with
## `--pre-js` by `tools/web/build.sh` and exposed as `Module.psAudio`. This
## file is the five one-line `EM_JS` stubs that call it, plus the `Backend`
## methods that call the stubs. Same shape as the miniaudio backend: each
## recipe's PCM is loaded once at startup into one browser `AudioBuffer`, and a
## play restarts that slot's voice. The browser mixes on its own audio thread:
## no wasm runs per sample, no threads, no special hosting headers.
##
## Browsers keep an `AudioContext` suspended until the page has seen a user
## gesture: the first keydown, pointerdown or touchend resumes it, and a play
## requested before that is dropped, never queued (see `audio.js`).

import paraloop/audio

{.emit: """/*INCLUDESECTION*/
#include <emscripten.h>
""".}

{.emit: """
EM_JS(int, ps_audio_open, (void), {
  return Module.psAudio && Module.psAudio.open() ? 1 : 0;
});

EM_JS(int, ps_audio_load, (int slot, const short* pcm, int frames, int rate), {
  var first = pcm >> 1; // HEAP16 index of the first sample
  return Module.psAudio.load(slot, HEAP16.subarray(first, first + frames), rate) ? 1 : 0;
});

EM_JS(void, ps_audio_play, (int slot, double volume), {
  Module.psAudio.play(slot, volume);
});

EM_JS(void, ps_audio_master, (double volume), {
  Module.psAudio.setMaster(volume);
});

EM_JS(void, ps_audio_close, (void), {
  Module.psAudio.close();
});
""".}

proc ps_audio_open(): cint {.importc, nodecl.}
proc ps_audio_load(slot: cint, pcm: pointer, frames, rate: cint): cint {.importc, nodecl.}
proc ps_audio_play(slot: cint, volume: cdouble) {.importc, nodecl.}
proc ps_audio_master(volume: cdouble) {.importc, nodecl.}
proc ps_audio_close() {.importc, nodecl.}

type WebAudioBackend = ref object of Backend

method load*(b: WebAudioBackend, slot: int, pcm: openArray[int16], rate: int): bool =
  if pcm.len == 0: return false
  ps_audio_load(slot.cint, pcm[0].unsafeAddr, pcm.len.cint, rate.cint) == 1

method play*(b: WebAudioBackend, slot: int, volume: float) =
  ps_audio_play(slot.cint, volume.cdouble)

method setMaster*(b: WebAudioBackend, volume: float) =
  ps_audio_master(volume.cdouble)

method close*(b: WebAudioBackend) =
  ps_audio_close()

proc openWebDevice*(): Backend =
  ## The page's `AudioContext` as a `Backend`, or nil when there is none.
  if ps_audio_open() == 1: WebAudioBackend() else: nil
