#!/usr/bin/env bash
# Linux: run ./paraloop-studio.sh (or double-click it in your file manager) to start Para
# Studio. Same steps as Paraloop-Studio.command; the work is done by tools/launcher/launch.sh.
cd "$(dirname "$0")" || exit 1
exec bash tools/launcher/launch.sh "$@"
