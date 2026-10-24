switch("mm", "orc")

# Repo-local nimcache split per target, program and build mode: every worktree
# gets its own build state instead of sharing ~/.cache/nim/<project>_d (report
# §2.3 #16, §3.4 R8), and tests, a dev window and a release build compiling at
# once never share a cache dir.
const
  nimcacheTarget = when defined(emscripten): "web" else: "native"
  nimcacheMode = when defined(dev): "dev" elif defined(release): "r" else: "d"
switch("nimcache", thisDir() & "/.nimcache/" & nimcacheTarget & "/" &
  projectName() & "_" & nimcacheMode)

# At most two C compiles at once. Nim starts one gcc per C file, up to the host's core count, and a
# container's `--cpus 3` is a quota, so it still reports all 32 cores; the nim process itself sits
# at 3.4-3.8 GB resident for the whole C phase. A cold compile of a game test then peaked at 6.1-6.3
# GB (nim plus three cc1, up to 1.2 GB each), over a 6 GB CI container; with two it peaks at 5.1 GB
# and is no slower on 3 CPUs. Scheduling only: the same C files, objects and binary.
when not defined(emscripten):
  switch("parallelBuild", "2")

# The engine lives in src/paraloop/; `import paraloop/sim` resolves through this.
switch("path", thisDir() & "/src")

when defined(emscripten):
  # Web target (report §3.3 `src/paraloop/web` row, task 1.7): the engine include
  # pins the wasm target; the emscripten `-s` settings ride on EMCC_CFLAGS, the
  # output path on `-o`, and tools/web/postbuild.mjs renders the shell
  # (title/theme) and webshell assets next to the build (docs/web.md).
  include "src/paraloop/web/paraloop.nims"

# Swap in a patched pararules 1.4.0 engine: deterministic rule firing and match
# order (no pointer- or table-history-dependent iteration) for paraloop/sim's
# replay and snapshot/restore, plus parasurvivors' fix for copying a leaf node's
# match table once per queued `then`. See the header of
# patches/pararules/engine.nim and patches/pararules/engine.diff.
patchFile("pararules", "engine", "patches/pararules/engine")

# Swap in a patched pararules 1.4.0 `pararules` (the macros). `schema` emits one
# generic `insert` and one generic `retract` instead of an overload per value
# type, which Nim resolved by re-instantiating `Session` for every candidate at
# every call (about 87 % of a large game's semantic-analysis time).
# `staticRuleset`'s match type is one array of slots instead of an object
# variant with a branch per rule, whose lifetime hooks were most of the
# generated C. Compile time, compiler memory and C size; no rule, query or hash
# changes. See the header of patches/pararules/pararules.nim and pararules.diff.
patchFile("pararules", "pararules", "patches/pararules/pararules")

# Swap in a patched paranim 0.12.0 `gl`: textures draw from a small fixed pool
# of texture units, bound at draw time, instead of one never-reused unit each
# (a device with 32 units, WebGL2's guarantee, cannot hold a game with 182
# textures). See the header of patches/paranim/gl.nim and gl.diff.
patchFile("paranim", "gl", "patches/paranim/gl")
# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
