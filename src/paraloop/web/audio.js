// paraloop's browser sound backend: the Web Audio half of paraloop/audio_web.nim.
//
// Linked into the wasm module with `--pre-js` (tools/web/build.sh) and
// exposed as `Module.psAudio`; the Nim side reaches it through five one-line
// EM_JS stubs (open, load, play, master, close), so this file is plain
// browser code with no knowledge of wasm memory. Rendered sounds arrive as
// 16-bit PCM once at startup and live in the browser as AudioBuffers; the
// browser mixes them on its own audio thread, so a slow game frame can never
// glitch a sound and no wasm code runs per sample.
//
// Autoplay: a context starts `suspended` until the page has seen a user
// gesture. keydown, pointerdown and touchend each try to resume it (touchend
// is the event iOS Safari honours). A play requested while the context is
// not running is dropped and counted, never queued: a burst replayed the
// moment the player first touches the page would be noise.
//
// `Module.psAudio.stats()` is the test hook tools/web/smoke.mjs reads.
(function () {
  "use strict";

  var UNLOCK_EVENTS = ["keydown", "pointerdown", "touchend"];

  var ctx = null; // the AudioContext; null before open() and after close()
  var master = null; // the GainNode every voice feeds
  var buffers = []; // slot -> AudioBuffer
  var voices = []; // slot -> the source node last started in that slot
  var plays = 0;
  var dropped = 0;

  function unlock() {
    if (ctx && ctx.state !== "running") {
      var resumed = ctx.resume();
      if (resumed && resumed.catch) resumed.catch(function () {});
    }
  }

  function open() {
    if (ctx) return true;
    var AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) return false;
    ctx = new AudioContextClass();
    master = ctx.createGain();
    master.connect(ctx.destination);
    UNLOCK_EVENTS.forEach(function (type) {
      window.addEventListener(type, unlock, true);
    });
    return true;
  }

  // `pcm` is an Int16Array of mono samples at `rate` Hz.
  function load(slot, pcm, rate) {
    if (!ctx || pcm.length === 0) return false;
    var buffer = ctx.createBuffer(1, pcm.length, rate);
    var out = buffer.getChannelData(0);
    for (var i = 0; i < pcm.length; i++) out[i] = pcm[i] / 32768;
    buffers[slot] = buffer;
    return true;
  }

  // One voice per slot: a new play restarts the sound from its beginning.
  function play(slot, volume) {
    if (!ctx || !buffers[slot]) return;
    if (ctx.state !== "running") {
      dropped++;
      return;
    }
    var old = voices[slot];
    if (old) {
      try { old.stop(); } catch (e) { /* already ended */ }
    }
    var source = ctx.createBufferSource();
    var gain = ctx.createGain();
    source.buffer = buffers[slot];
    gain.gain.value = volume;
    source.connect(gain);
    gain.connect(master);
    source.start();
    voices[slot] = source;
    plays++;
  }

  function setMaster(volume) {
    if (master) master.gain.value = volume;
  }

  function close() {
    if (!ctx) return;
    UNLOCK_EVENTS.forEach(function (type) {
      window.removeEventListener(type, unlock, true);
    });
    var closing = ctx.close();
    if (closing && closing.catch) closing.catch(function () {});
    ctx = master = null;
    buffers = [];
    voices = [];
  }

  function stats() {
    return {
      state: ctx ? ctx.state : "closed",
      buffers: buffers.filter(Boolean).length,
      plays: plays,
      dropped: dropped,
    };
  }

  Module.psAudio = {
    open: open, load: load, play: play, setMaster: setMaster, close: close, stats: stats,
  };
})();
