#!/bin/bash
# Double-click this file on a Mac to start Para Studio. The steps, and what to do if macOS
# warns about this file, are in docs/mac.md; the work is done by tools/launcher/launch.sh.
cd "$(dirname "$0")" || exit 1
PARALOOP_LAUNCHER_PAUSE=1 exec /bin/bash tools/launcher/launch.sh "$@"
