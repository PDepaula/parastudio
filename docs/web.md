# Web target (wasm)

paraloop compiles for the web via Emscripten (wasm + WebGL). The web target is
one engine include — `src/paraloop/web/paraloop.nims` — plus the shell template and
webshell assets in the same directory; the repo-root `config.nims` pulls the
nims in for every `-d:emscripten` build (report §3.3, task 1.7). The nims pins
the wasm target; the emscripten `-s` settings ride on `EMCC_CFLAGS` (nimscript
of this era cannot carry them), and `tools/web/postbuild.mjs` renders the shell
(title/theme) as `index.html`, lays the webshell assets (manifest, icons) next to
the build and writes `build.json`.

Toolchain: emsdk 6.x (emcc on PATH) plus an official nim >= 2.2.12 — some
nimble-managed and distro nim installs ship a `config/nim.cfg` without the
`@if emscripten` C-compiler wiring and cannot build for this target.
`nimble webSmoke`, `para build --target web` and `para web smoke` all build
through `tools/web/build.sh`, which picks the first nim whose `config/nim.cfg` carries it,
trying `PARALOOP_WEB_NIM`, then the highest install under
`~/.nimble/nimbinaries`, then `nim` on PATH, and fails if none does. CI pins
`PARALOOP_WEB_NIM` to the official 2.2.12.

```sh
source $EMSDK/emsdk_env.sh          # emcc on PATH (emsdk 6.x), then:

para build --target web --game mygame --title "My Game"
para web pack --game mygame         # tmp/web/mygame-<build id>.zip
```

`para build --target web` is the shipping build: **release** (`-d:release`: on a large game 5.2 MB of
wasm against 8.5 MB, and 60 fps at 6x CPU throttle against 15) unless
`--debug`. `--define NAME[=VALUE]` (repeatable) is passed to nim as `-d:NAME[:VALUE]`
(a game reads it with `defined(NAME)`), `--title` is the page title. The output is one directory per game, `tmp/web/<game>/`
(emptied first, so it holds only this build): `index.html` (the shell), `<game>.js`,
`<game>.wasm`, `manifest.webmanifest`, the two icons and `build.json`. The **build id**
(`<short commit>[-dirty]-<release|debug>[-<define>...]`, e.g. `c2888e8-release-myflag`;
no timestamp) is in `build.json`, in the page as `<meta name="paraloop-build">` and as small
text in its corner (`--feedback-url URL` adds a "Send feedback" link beside it, with the id
appended as `?build=`), so a rebuild of the same commit is byte-identical (cold, same toolchain). `para web pack` zips exactly what a static host needs (`index.html`,
`<game>.js`, `<game>.wasm`, the manifest and icons; no `build.json`) with sorted entries and a
fixed time stamp, so the same build always packs to the same bytes; it refuses a `-d:dev` build.
Raw equivalent of the build, which `tools/web/build.sh [--debug] [--define D]... SRC OUT`
wraps (then `node tools/web/postbuild.mjs --dir tmp/web/hello --title "paraloop hello"`):

```sh
EMCC_CFLAGS='-sINVOKE_RUN=1 -sMAX_WEBGL_VERSION=2 -sMIN_WEBGL_VERSION=2 \
             -sSTACK_SIZE=8388608 -sALLOW_MEMORY_GROWTH=1 \
             --pre-js src/paraloop/web/audio.js' \
  nim c -d:emscripten -d:release --hints:off -o:tmp/web/hello/hello examples/hello/hello.nim
```

or the one-shot task: `nimble webSmoke` (builds, postbuilds, and smokes
`examples/hello`; it passed only if it wrote `tmp/web-smoke-passed`). Serve
`tmp/web/<game>/` with any static file server (no special headers) and open it.
`--pre-js src/paraloop/web/audio.js` is the browser half of web sound
(see [engine.md](engine.md), "Sound"); leave it out and the build is silent. `-sSINGLE_FILE=1` in `EMCC_CFLAGS` inlines the wasm for
file:// delivery; `--theme #rrggbb` (or `PARALOOP_WEB_THEME`) sets the page
background and manifest colors.

Input for web games comes through the same emscripten exports a real
keyboard and mouse use: `Module._psKeyDown`/`_psKeyUp` for keys and
`Module._psPointer(x, y)`/`_psButton(button, down)` for the pointer (canvas
pixels from the top-left, GLFW button numbers; a tap is a left click). The
shell's touch controls are optional and show only on touch devices
(`pointer: coarse`): the labelled buttons at the bottom right hold Enter, C,
Esc, Tab and M; desktop plays with the keyboard and the mouse. There is no
on-screen stick: moving is a tap on the playfield. Touch devices also get a
fullscreen toggle (where the Fullscreen API exists) and a dismissible "rotate
to landscape" notice in portrait. When the page is hidden or loses focus the
shell releases the keys and mouse buttons it holds (it never sends Esc).

Smoke test headless (Node 22+, a Chrome or Chromium binary — the task 1.7
acceptance), directly or wrapped as `para web smoke` (task 1.8, below):

```sh
node tools/web/smoke.mjs --dir tmp/web/hello --game hello [--chrome google-chrome]
```

The driver serves the build directory, loads the build in a headless Chromium
(SwiftShader software WebGL where no GPU is present) and checks over the Chrome
DevTools Protocol — no browser-automation package — that the wasm module loads
(`Module._psKeyDown` export present), that ticks run (holding ArrowRight changes
the rendered frame, then the game keeps running for `--ticks` N, default 90), and that there are zero console errors, zero page
exceptions and zero WebGL warnings (a texture unit or sampler uniform out of
range, any `INVALID_*`), and that the saved frame is not blank (more than one colour). A game whose
title screen ignores the arrows needs `--enter` (an explicit flag, never auto-detected):
the driver taps Enter and waits half a second before its input.
`--click X,Y` (also explicit) posts a real left click at that viewport pixel and
checks the canvas receives it and the engine's pointer exports are up: the
browser-to-engine path only, not that the game acted on it.
`--sound` is explicit and off by default (the `web-smoke`
CI job passes it for `hello`): Chromium then also runs under the
document-user-activation autoplay policy and the driver checks the Web Audio
backend end to end: it loaded its buffers, starts `suspended`, a real CDP key
press (`Input.dispatchKeyEvent`) moves it to `running`, and a sound plays after
the driver's ArrowRight hold, so the game under test must play a sound on that
key (`hello` does). The page sees a device with `--max-texture-units` N
combined texture units, default 32, the most WebGL2 guarantees, whatever the
host's Chromium has: paranim draws textures through a small pool of units
(`patches/paranim/gl.nim`), so a game may create more textures than that. It
saves the final frame to `tmp/web-smoke/<game>.png`. `para web smoke` builds
what ships (release unless `--debug`, with the same `--define`s as `para build`), so it
checks the artifact `para web pack` zips. The
`web-smoke` CI job runs `para web smoke --max-texture-units 2 --sound` (the default
game, which creates more textures than that, so a unit per texture fails it) on every PR that
touches the engine, template, tools, examples or build config (the `changes` job
decides; see `.github/workflows/ci.yml`).
