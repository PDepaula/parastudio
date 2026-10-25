#!/usr/bin/env bash
# Checks the one-line installers the docs build published against the repository's own:
# tmp/site/install.sh and install.ps1 must be tools/launcher/install.sh and install.ps1 with only
# the empty commit line filled in, with the commit that is checked out. So there is no second,
# hand-kept copy that could drift. Run after `uv run tools/docs/build.py`; exits 1 on a difference.
#
#   .github/scripts/installer-copy-check.sh [SITE_DIR]   (default: tmp/site)
set -euo pipefail

site=${1:-tmp/site}
head=$(git rev-parse HEAD)
status=0

check() { # $1 = source, $2 = its empty commit line, $3 = that line with the commit in it
  local src=$1 pub
  pub="$site/$(basename "$1")"
  if [ ! -f "$pub" ]; then echo "installer-copy-check: $pub is missing"; status=1; return; fi
  if [ "$(grep -cFx -- "$2" "$src")" != 1 ]; then
    echo "installer-copy-check: $src must have exactly one line: $2"; status=1; return
  fi
  if awk -v empty="$2" -v stamped="$3" '$0 == empty { print stamped; next } { print }' "$src" | cmp -s - "$pub"; then
    echo "installer-copy-check: $pub is $src with commit $head written in"
  else
    echo "installer-copy-check: $pub is not $src with only commit $head written in:"
    diff "$src" "$pub" | head -n 20 || true
    status=1
  fi
}

check tools/launcher/install.sh 'PARASTUDIO_COMMIT=""' "PARASTUDIO_COMMIT=\"$head\""
check tools/launcher/install.ps1 "  \$PARASTUDIO_COMMIT = ''" "  \$PARASTUDIO_COMMIT = '$head'"
exit "$status"
