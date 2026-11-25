#!/usr/bin/env bash
# The studio model's size and compile-time budget. The `test` job's shard 1 in
# .github/workflows/ci.yml runs it after building tmp/para; run it by hand the
# same way from the repository root:
#
#   .github/scripts/model-budget.sh
#
# It runs `para expand` on tools/para/studiodesk.nim (the studio's desk, whose
# model file is tools/para/studiodesk.em), which compiles the module with
# `nim check --expandMacro` and writes what its Eversince blocks expand to,
# and fails when either budget is passed:
#
#   size    generated lines / written lines, over MAX_RATIO (para expand
#           --max-ratio judges it; tests/test_para_expand.nim pins how).
#   time    the wall-clock seconds of that one compile, over MAX_SECONDS.
#           Measured here only, never in a test.
#
# Measured on 2026-11-25 (nim 2.2.10 and 2.2.12, a warm workstation):
# written 1244 lines, generated 1701 to 1702, ratio 1.37; the compile took
# about 0.7 s. MAX_RATIO leaves about a tenth of headroom: a model change that
# needs more is a reason to look at the expansion, and raising the number in
# the same change says so on purpose. MAX_SECONDS is about forty times the
# measured time, so a slow or busy runner does not trip it; a macro that
# blows up compile time does.
#
# Exit 0 within both budgets, 1 over either, 2 when tmp/para is missing.

set -u

MAX_RATIO=1.50
MAX_SECONDS=30

para=./tmp/para
if [ ! -x "$para" ]; then
  echo "error: $para is missing; build it first: nim c --hints:off --outdir:tmp tools/para/para.nim"
  exit 2
fi

start=$(date +%s%N)
"$para" expand --max-ratio "$MAX_RATIO"
size=$?
end=$(date +%s%N)
ms=$(( (end - start) / 1000000 ))
secs=$(awk -v ms="$ms" 'BEGIN { printf "%.1f", ms / 1000 }')

status=0
[ "$size" -ne 0 ] && status=1
if [ "$ms" -gt $(( MAX_SECONDS * 1000 )) ]; then
  echo "error: the studio model took ${secs} s to compile, over the budget of ${MAX_SECONDS} s"
  status=1
else
  echo "compile time: ok, ${secs} s is within ${MAX_SECONDS} s"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "studio model budget: size exit $size (max ratio $MAX_RATIO), compile ${secs} s (max ${MAX_SECONDS} s)" >> "$GITHUB_STEP_SUMMARY"
fi
exit "$status"
