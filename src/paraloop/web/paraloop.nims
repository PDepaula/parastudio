# paraloop nims -- web (wasm) compiler config (task 1.7).
#
# Included from the root config.nims when `-d:emscripten` is active.
#
# Kept to the two directives every nim of this era accepts (nimscript is
# version-choppy about anything fancier: no definedValue, no os calls, some
# builds reject --outdir/--app/--html). All web-specific flags go through the
# EMCC_CFLAGS environment variable, the output path through `-o`, and the
# html shell is rendered afterwards by tools/web/postbuild.mjs.
#
#   EMCC_CFLAGS="-sINVOKE_RUN=1 -sSTACK_SIZE=8388608 ..." \
#     nim c -d:emscripten -d:release -o:tmp/web/hello/hello examples/hello/hello.nim
#
#   then:  node tools/web/postbuild.mjs --dir tmp/web/hello [--title X] [--theme #rrggbb]
#          node tools/web/smoke.mjs --dir tmp/web/hello

when defined(emscripten):
  --os:linux
  --cpu:wasm32
