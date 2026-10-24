# Engine notes: sound and the profile store

## Sound

`paraloop/audio` is the engine's sound module, on native and on the web. A sound is
a *recipe*: a few synth tones (wave, start/length in ms, MIDI pitch with an optional
glide, gain, envelope) that rendering turns into 16-bit PCM, handed to a backend --
the same synthesise-at-startup, one-sound-per-effect shape parasurvivors uses, with a
tiny synth in place of paramidi and its 31 MB soundfont, so a render is exact and
reproducible and unit-testable.

- `initAudio(backend, recipes, master)` renders every recipe; `play(slot, volume)`,
  `setMaster`, `setMuted`/`toggleMute`, `shutdown`. `Audio()` (no backend) is the
  silent player, and `NullBackend` records plays for tests: **nothing in `para test`,
  `para sim` or `para shot` ever opens a device** -- only a game's own entry point does,
  by importing `paraloop/audio_device` under `when isMainModule` and passing
  `openDevice()` (nil when there is no output device) to `initAudio`.
- A `Backend` gets each rendered recipe once, as PCM (`load(slot, pcm, rate)`: mono
  `int16` samples and their sample rate), then `play`, `setMaster` and `close`.
- `Throttle`/`pick` rate-limit cues deterministically in sim ticks (a per-effect gap
  and a cap on voices per observation), never the wall clock.
- A game keeps its effects as rows (a `sfxdata.nim` of its own) and decides
  what to play from facts after the fact (an `sfx.nim`, called from
  `draw`): it reads the sim and never writes it, so a run's `stateHash` is the same
  with or without sound.

A melody is easier to write as a line of text than as `tone` calls: `tune` in
`paraloop/tune` turns a small score into `seq[Tone]` -- notes `c d e f g a b` with `+`/`-`,
rests `r`, lengths that stick (`c8`), `o4`/`>`/`<` octaves and `c/e/g` chords -- and runs at
compile time, so it fits a `const` row. It is a notation over the tone synth, not a music
engine (no instruments, voices or repeats), and a bad character raises `ValueError` naming
its position. The notation is in the header of `src/paraloop/tune.nim`.

```nim
import paraloop/[audio, tune]

const levelUp = Recipe(name: "level_up", tones: tune("o5 c16 e g >c", Square))
# c5 e5 g5 c6 as 125 ms sixteenths at the default tempo of 120 quarter notes a minute;
# `tempo = ` and `gain = ` change the speed and the loudness
```

Backends (`openDevice()` picks one at compile time):

- **Native: miniaudio** through `parasound` (already a dependency); it loads the
  system's ALSA/PulseAudio/PipeWire at run time, so building needs no extra system
  package. `PARALOOP_AUDIO=off` never opens a device.
- **Web (`-d:emscripten`): Web Audio.** `src/paraloop/audio_web.nim` is a thin Nim shell
  over `src/paraloop/web/audio.js`, which `tools/web/build.sh` links into the wasm with
  `--pre-js` (a web build compiled any other way has no `Module.psAudio` and is silent
  rather than broken). Each recipe becomes one `AudioBuffer` at startup and the browser
  mixes on its own audio thread: no threads, no `SharedArrayBuffer`, no special hosting
  headers, about 2 KB of wasm.
- `-d:noaudio` leaves the device out of the build entirely (`openDevice()` is nil).

**The unlock rule (web).** Browsers keep audio locked until the page has seen a user
gesture, so the context starts `suspended` and the first `keydown`, `pointerdown` or
`touchend` resumes it. A sound requested before that is *dropped*, not queued -- a burst
replayed at the first key press would be noise -- so a game that wants its first sound
heard plays it in response to input (a title screen's Enter, a start button), not at
load. A keyboard-only player hears sound after their first key press. `para web smoke
--sound` checks this for a game that beeps on ArrowRight (see [web.md](web.md)).

Config: `PARALOOP_VOLUME=NN` (percent, run time, native) overrides a game's master
volume and `PARALOOP_AUDIO=off` never opens a device. A game's mute key and any
compile-time volume define are the game's own.

## Profile store (`paraloop/save`)

`paraloop/save` keeps the progress a game carries between runs as one versioned JSON
file in the OS data directory. It is game-agnostic: the engine reads and writes the
envelope `{"version": N, "game": "<id>", "payload": {...}}` and never looks inside the
payload; the game owns its fields, its version number and its migrations.

- Path: `profilePath(game)` is `<data home>/paraloop/<game>/profile.json`; the data
  home is `$XDG_DATA_HOME` (an absolute path, else `~/.local/share`) on Linux,
  `~/Library/Application Support` on macOS and `%APPDATA%` on Windows.
- `loadProfile(path, game, version, migrations)` never raises and never writes. Its
  `LoadResult.status` is `lsOk`, `lsMissing`, `lsCorrupt`, `lsWrongGame`, `lsNewer` or
  `lsUnavailable`; an older file is migrated one version at a time through
  `migrations` (`(fromVersion, proc (payload): payload)` entries, N -> N + 1).
- `saveProfile(path, game, version, payload)` writes a temp file beside the target and
  renames it over, so a failure leaves the old file whole. A corrupt, another game's,
  newer or older (pre-migration) file it is about to replace is copied to
  `profile.json.bak` first.
- The web target is a stub (every call reports it is unavailable) until browser
  storage lands.
