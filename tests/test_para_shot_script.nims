# Build flags for test_para_shot_script.nim only (a file's own .nims is loaded for that file's compile).
#
# Speed: the default debug build pays for Nim's per-call stack-trace
# bookkeeping and unoptimised C. `--stacktrace:off` plus `-O1` is what turns
# this test's wall time from minutes into seconds (measured in the PR that
# added this file); every runtime check (bounds, overflow, asserts) stays on,
# and no assertion changed. Delete this file to get stack traces back while
# debugging an unexpected exception here.
switch("stacktrace", "off")
switch("passC", "-O1")
