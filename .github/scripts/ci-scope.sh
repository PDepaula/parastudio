#!/usr/bin/env bash
# Which parts of CI a change needs: reads the changed paths (one per line,
# renames as both paths) on stdin and prints `key=value` lines for
# $GITHUB_OUTPUT. The `changes` job in .github/workflows/ci.yml runs it; run
# it by hand to see what a diff would trigger:
#
#   git diff --name-only origin/main... | .github/scripts/ci-scope.sh
#
# Outputs
#   engine     the engine-level jobs (web-smoke, template-smoke) are needed:
#              src/, template/, tools/para/, tools/web/, examples/,
#              patches/, .github/workflows/, config.nims, paraloop.nimble,
#              nimble.lock (unchanged from before this script existed)
#   full       the whole test suite is needed: engine, or any path that is not
#              known to belong to one narrower area (fail open), or no paths
#   game       games/<name>/ code, tests, goldens
#   art        the art pipeline: tools/art, `para art` (tools/para/artcmd.nim
#              and the art modules but not art/clihelpers.nim or art/toon.nim,
#              which every `para` command imports), tests/fixtures/art,
#              tests/test_art_*, games/*/art, games/*/assets, games/*/atlas
#   docs_only  every path is documentation no test reads: no tests run
#   areas      the `para test --area` value: `all` when full, else the
#              comma-joined game/art that changed, empty when docs_only
#   sim        the sim gate (6 minutes of game time) is needed: full or game
#
# Which test files an area runs is tools/para/testplan.nim's job (the import
# closure of each test file), not this script's: this one only buckets paths.

set -u

engine=false full=false game=false art=false any=false

while IFS= read -r f; do
  [ -z "$f" ] && continue
  any=true
  case "$f" in
    # Art code under tools/para is listed first so it buckets as art for the
    # test job, yet still counts as `engine` for the build jobs.
    tools/para/artcmd.nim|tools/para/art/fix.nim|tools/para/art/lint.nim|\
    tools/para/art/profile.nim|tools/para/art/sheet.nim|tools/para/art/sidecar.nim|\
    tools/para/art/toml.nim)
      engine=true; art=true ;;
    # The old `engine` set: these also run web-smoke and template-smoke.
    src/*|template/*|tools/para/*|tools/web/*|examples/*|patches/*|\
    .github/workflows/*|config.nims|paraloop.nimble|nimble.lock)
      engine=true; full=true ;;
    # tests/test_para_usage.nim reads skills/para/SKILL.md, so it is a test
    # input, not documentation.
    skills/para/*)
      full=true ;;
    # Documentation: no test reads it. (src/, template/ and
    # tools/para/ are matched above, so their .md files still count as engine.)
    *.md|docs/*|skills/*|LICENSE*|.github/ISSUE_TEMPLATE/*)
      ;;
    games/*/art/*|games/*/assets/*|games/*/atlas/*)
      art=true ;;
    tools/art/*|tests/fixtures/art/*|tests/test_art_*)
      art=true ;;
    games/*)
      game=true ;;
    # Anything else (tests/, the runner image, root dotfiles, a new top-level
    # directory) is not known to be narrow: run everything.
    *)
      full=true ;;
  esac
done

if [ "$any" = false ]; then
  # No changed-file list (the API call failed, or an empty diff): fail open.
  engine=true full=true
fi

docs_only=false
if [ "$any" = true ] && [ "$full" = false ] && [ "$game" = false ] &&
   [ "$art" = false ] && [ "$engine" = false ]; then
  docs_only=true
fi

areas=""
if [ "$full" = true ]; then
  areas=all
else
  [ "$game" = true ] && areas="game"
  [ "$art" = true ] && areas="${areas:+$areas,}art"
fi

sim=false
if [ "$full" = true ] || [ "$game" = true ]; then sim=true; fi

cat <<EOF
engine=$engine
full=$full
game=$game
art=$art
docs_only=$docs_only
areas=$areas
sim=$sim
EOF
