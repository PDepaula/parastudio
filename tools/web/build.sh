#!/usr/bin/env bash
# Shared web-build step (task 1.7's emscripten build, engine report §3.3):
# picks a nim whose config/nim.cfg carries the `@if emscripten` C-compiler
# wiring (some nimble-managed installs and distro nims don't -- docs/web.md),
# then compiles SRC to OUT with paraloop's web EMCC flags. Used by both
# `nimble webSmoke` and `para build --target web` / `para web smoke` (task
# 1.8), so the selection logic and flags live in exactly one place.
#
# A release build (`-d:release`) is the default: it is the build that ships
# (5.2 MB of wasm against 8.5 MB, and 60 fps at 6x CPU throttle against 15 in
# the scout's measurement). `--debug` selects the debug build, and each
# `--define NAME[=VALUE]` is passed to nim as `-d:NAME[:VALUE]` (repeatable).
#
# usage: tools/web/build.sh [--debug] [--define NAME[=VALUE]]... SRC OUT
set -euo pipefail

MODE=release
DEFINES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) MODE=debug; shift ;;
    --define)
      [ $# -ge 2 ] || { echo "build.sh: --define needs NAME[=VALUE]" >&2; exit 2; }
      if ! [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*(=[A-Za-z0-9_.:-]+)?$ ]]; then
        echo "build.sh: bad --define \"$2\" (want NAME or NAME=VALUE)" >&2
        exit 2
      fi
      DEFINES+=("-d:${2/=/:}")
      shift 2 ;;
    --*) echo "build.sh: unknown flag \"$1\"" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || { echo "usage: build.sh [--debug] [--define NAME[=VALUE]]... SRC OUT" >&2; exit 2; }
SRC="$1"
OUT="$2"

NIM=
for n in "${PARALOOP_WEB_NIM:-}" $(ls -1d ~/.nimble/nimbinaries/nim-*/bin/nim 2>/dev/null | sort -rV) "$(command -v nim || true)"; do
  [ -n "$n" ] || continue
  if [ -x "$n" ] && grep -q '^@if emscripten' "$(dirname "$(readlink -f "$n")")/../config/nim.cfg" 2>/dev/null; then
    NIM=$n
    break
  fi
done
if [ -z "$NIM" ]; then
  echo "build.sh: no nim with the '@if emscripten' wiring in its config/nim.cfg -- set PARALOOP_WEB_NIM to an official nim >= 2.2.12" >&2
  exit 1
fi
# At most two C compiles at once, as config.nims does for native builds (which
# skips emscripten): a 3-CPU runner container still reports every host core, and
# a cold compile of a large game otherwise runs one clang per core. Scheduling
# only: the same objects, the same wasm.
NIMFLAGS=(--parallelBuild:2)
[ "$MODE" = release ] && NIMFLAGS+=("-d:release")
[ ${#DEFINES[@]} -gt 0 ] && NIMFLAGS+=("${DEFINES[@]}")
echo "build.sh: building ($MODE${NIMFLAGS[*]+: ${NIMFLAGS[*]}}) with $NIM" >&2

# src/paraloop/web/audio.js is the browser half of paraloop/audio_web.nim (Web
# Audio), pre-pended to the module so `Module.psAudio` exists before main.
AUDIO_JS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/paraloop/web/audio.js"

export EMCC_CFLAGS="-sINVOKE_RUN=1 -sMAX_WEBGL_VERSION=2 -sMIN_WEBGL_VERSION=2 -sSTACK_SIZE=8388608 -sALLOW_MEMORY_GROWTH=1 --pre-js \"$AUDIO_JS\""
"$NIM" c -d:emscripten ${NIMFLAGS[@]+"${NIMFLAGS[@]}"} --hints:off -o:"$OUT" "$SRC"
