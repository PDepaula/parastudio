#!/usr/bin/env bash
# Helpers for .github/workflows/platform-check.yml: time each step of the
# first-playable path and collect the results as one job-summary table.
#
#   platform-check.sh mark NAME        record the wall time since the previous mark
#                                      (covers the action step in between) as NAME
#   platform-check.sh run NAME CMD...  run CMD, record its wall time and exit code as
#                                      NAME; a failure is recorded, not fatal
#   platform-check.sh probe NAME CMD...  like run, but only for facts (versions, what is
#                                      preinstalled); never counted as a failure
#   platform-check.sh summary          print the table (to $GITHUB_STEP_SUMMARY when
#                                      set) and exit 1 if any `run` step failed
#
# State lives in $RUNNER_TEMP/platform-check.{rows,mark}. Times are whole seconds.

set -u
dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
rows="$dir/platform-check.rows"
markfile="$dir/platform-check.mark"

now() { date +%s; }

cmd="${1:-}"; shift || true
case "$cmd" in
  mark)
    t=$(now)
    prev=$t
    [ -f "$markfile" ] && prev=$(cat "$markfile")
    printf 'step\t%s\t%s\tok\t\n' "$1" "$((t - prev))" >> "$rows"
    echo "$t" > "$markfile"
    ;;
  run|probe)
    name="$1"; shift
    echo "::group::$name: $*"
    start=$(now)
    out=$("$@" 2>&1); code=$?
    end=$(now)
    printf '%s\n' "$out"
    echo "::endgroup::"
    [ "$code" -eq 0 ] && status=ok || status="FAIL($code)"
    kind=$cmd
    # One line of evidence per row: the last non-empty output line, trimmed.
    note=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-260 | tr '\t|' '  ')
    printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$name" "$((end - start))" "$status" "$note" >> "$rows"
    echo "$(now)" > "$markfile"
    [ "$code" -ne 0 ] && echo "::warning::$name failed (exit $code)"
    exit 0
    ;;
  summary)
    failed=0
    awk -F'\t' '$1 == "run" && $4 != "ok" { bad = 1 } END { exit bad }' "$rows" || failed=1
    {
      echo "## ${PLATFORM_LABEL:-platform} first-playable check"
      echo
      echo "| step | kind | seconds | result | last output line |"
      echo "|---|---|---:|---|---|"
      while IFS=$'\t' read -r kind name secs status note; do
        echo "| $name | $kind | $secs | $status | \`$note\` |"
      done < "$rows"
      echo
      if [ "$failed" -eq 0 ]; then echo "**All checked steps passed.**"; else echo "**At least one step failed.**"; fi
      echo
      echo "Not checked here: that a window opens. A hosted runner has no GPU, so that needs real hardware (see docs/platforms.md)."
    } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit "$failed"
    ;;
  *)
    echo "usage: $0 mark|run|probe|summary ..." >&2
    exit 2
    ;;
esac
