# `para sim --from` replays an F9 bug capture, and this file generates its own
# fixtures via examples/hello's F9 path (paraloop/app.stepTick only calls
# paraloop/dev.devTick under `-d:dev` -- see tests/test_dev.nims, the same fix
# for the same reason).
switch("define", "dev")

# Speed: this file replays whole runs through `para sim`; the
# default debug build pays for Nim's per-call stack-trace bookkeeping and
# unoptimised C. `--stacktrace:off` plus `-O1` cuts its run time several-fold;
# every runtime check (bounds, overflow, asserts) stays on, and no assertion
# changed. Delete these two lines to get stack traces back while debugging an
# unexpected exception here.
switch("stacktrace", "off")
switch("passC", "-O1")
