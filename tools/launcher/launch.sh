#!/bin/bash
# Para Studio launcher: checks what Studio needs, installs only what is missing (and only
# after asking), builds `para` and starts `tmp/para studio`, which opens the browser itself.
# Run through Paraloop-Studio.command (macOS double-click) or paraloop-studio.sh (Linux); see
# docs/mac.md. Plain bash 3.2 (what macOS ships): no associative arrays, no mapfile.
#
#   launch.sh [--dry-run | --check] [--no-studio] [--help]
#
# --dry-run (or --check, the same) says what each step WOULD do and changes nothing: no install, no
# build, no browser, and no question is asked. --no-studio does every step but the last: it sets up
# and builds, then stops without starting Studio (the one-line installer, tools/launcher/install.sh,
# runs it that way and asks about Studio itself). PARALOOP_LAUNCHER_UNATTENDED=1 is for a run with
# nobody at the keyboard (the installer's PARASTUDIO_YES=1): every offer to install is answered no
# without asking, so the run stops with what to install by hand and installs nothing. Test hooks (read only by the tests):
# PARALOOP_LAUNCHER_OS / _ARCH replace `uname -s` / `-m`, and, in a dry run only,
# PARALOOP_LAUNCHER_FAKE_CLT=missing pretends the Apple tools are missing and
# PARALOOP_LAUNCHER_FAKE_MISSING=cc,git pretends those are.
#
# When something is missing it is offered, never just installed: the launcher prints what it would
# install (name and version), from where (the exact link or command), into which folder and how big,
# then asks a plain yes/no. Only "y" or "yes" is yes; Enter, anything else and an input that is closed
# are no, and no stops with what to do by hand. The routes are the official ones: Nim's release
# archive from nim-lang.org (its published SHA-256 checked), Apple's own installer for its command line
# tools, and the Linux package manager for a C compiler and git.
#
# What it never does: run sudo except as the exact package-manager command it showed and you said yes
# to, pipe a downloaded script into a shell, edit a shell profile (Nim's folder is added to PATH for
# this run only), read or write a login or a config of claude or codex, or send anything anywhere
# except to nim-lang.org (the Nim download and its checksum), the package manager or Apple installer you
# said yes to, nimble's package fetch and git. The log (tmp/launcher.log) holds only what the steps
# printed; Studio's own output, which carries its per-run key, is never written to it.

set -eEuo pipefail

NIM_VERSION=2.2.10
NIM_BASE_URL=https://nim-lang.org/download
CLAUDE_INSTALL_URL=https://code.claude.com/docs/en/setup
CODEX_INSTALL_URL=https://developers.openai.com/codex/cli
STEPS=7

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

DRY_RUN=0
NO_STUDIO=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|--check) DRY_RUN=1 ;;
    --no-studio) NO_STUDIO=1 ;;
    -h|--help)
      echo "Para Studio launcher"
      echo "  launch.sh [--dry-run | --check] [--no-studio]"
      echo "  --dry-run    say what each step would do and what it would offer to install;"
      echo "               install, build and open nothing, and ask nothing (--check is the same)"
      echo "  --no-studio  set up and build, then stop without starting Studio"
      echo "See docs/mac.md."
      exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

OS=${PARALOOP_LAUNCHER_OS:-$(uname -s)}
ARCH=${PARALOOP_LAUNCHER_ARCH:-$(uname -m)}
if [ "$DRY_RUN" = 1 ]; then LOG=/dev/null; else LOG="$ROOT/tmp/launcher.log"; fi
STEP_NO=0
STEP_NAME="starting"
CLEANUP_DIR=""
CHILD_PID=""
STOP_AFTER_TOOLS=0

# --- talking ---------------------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
step() { STEP_NO=$((STEP_NO + 1)); STEP_NAME=$2; say ""; say "[$STEP_NO/$STEPS] $1"; log "step $STEP_NO: $2"; }
ok() { say "      ok: $*"; log "ok: $*"; }
note() { say "      $*"; log "$*"; }
would() { say "      would: $*"; }
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

pause_before_close() {
  if [ "${PARALOOP_LAUNCHER_PAUSE:-0}" = 1 ] && [ -t 0 ] && [ "$DRY_RUN" = 0 ]; then
    printf '\nPress Return to close this window. '
    read -r _ </dev/tty || true
  fi
}

computer_summary() {
  local ver
  if [ "$OS" = Darwin ] && command -v sw_vers >/dev/null 2>&1; then ver="macOS $(sw_vers -productVersion)"; else ver="$OS $(uname -r 2>/dev/null || true)"; fi
  printf '%s, %s' "$ver" "$ARCH"
}

fail() {
  trap - ERR
  set +e
  local what=$1
  say ""
  say "=============================================================================="
  say "Something went wrong. Please send the captain everything between these lines."
  say "------------------------------------------------------------------------------"
  say "Step:     $STEP_NO of $STEPS, $STEP_NAME"
  say "Problem:  $what"
  say "Computer: $(computer_summary)"
  if [ "$LOG" != /dev/null ]; then
    say "Log file: $LOG   (attach this file too)"
    if [ -s "$LOG" ]; then
      say "Last lines of the log:"
      tail -n 12 "$LOG" | sed 's/^/  | /'
    fi
  fi
  say "=============================================================================="
  log "FAILED at step $STEP_NO ($STEP_NAME): $what"
  pause_before_close
  exit 1
}

on_unexpected_error() {
  fail "A command stopped unexpectedly (script line $1)."
}

cleanup() {
  if [ -n "$CLEANUP_DIR" ] && [ -d "$CLEANUP_DIR" ]; then rm -rf "$CLEANUP_DIR"; fi
}

on_interrupt() {
  if [ -n "$CHILD_PID" ]; then kill "$CHILD_PID" 2>/dev/null || true; fi
  say ""
  say "Stopped. Double-click again to start over; finished steps are skipped."
  exit 130
}

trap 'on_unexpected_error $LINENO' ERR
trap cleanup EXIT
trap on_interrupt INT TERM

# Runs a command with its output going to the log, printing a dot every few seconds so the
# window does not look frozen. Returns the command's exit status.
run_logged() {
  log "\$ $*"
  "$@" >>"$LOG" 2>&1 &
  CHILD_PID=$!
  local ticks=0
  printf '      working'
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    sleep 1
    ticks=$((ticks + 1))
    if [ $((ticks % 5)) = 0 ]; then printf '.'; fi
  done
  printf '\n'
  local status=0
  wait "$CHILD_PID" || status=$?
  CHILD_PID=""
  return "$status"
}

# The one way the launcher asks. Yes only for "y" or "yes" typed here; Enter, any other answer and an
# input that is closed (nothing can be typed) are all no. An unattended run never asks: it is no.
ask_yes_no() {
  local answer=""
  if [ "${PARALOOP_LAUNCHER_UNATTENDED:-0}" = 1 ]; then
    say "      $1 No: this is an unattended run, and nothing is installed without a person typing y."
    log "asked: $1 -> no (unattended)"
    return 1
  fi
  printf '      %s (y/n, Enter means no) ' "$1"
  if ! IFS= read -r answer; then
    printf '\n'
    say "      (no answer could be read, so the answer is no)"
    answer=""
  fi
  log "asked: $1 -> ${answer:-(no answer)}"
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# The answer was no: nothing was installed. Says what to do by hand and stops.
declined() {
  say ""
  say "      Okay, nothing was installed and nothing changed."
  say "      $1"
  log "declined: $1"
  pause_before_close
  exit 1
}

faked_missing() { # $1 = cc|git: true in a dry run told to pretend it is missing
  [ "$DRY_RUN" = 1 ] || return 1
  case ",${PARALOOP_LAUNCHER_FAKE_MISSING:-}," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# --- finding things (no login-shell PATH needed) ----------------------------------------------

# Where a Nim 2.2.10 may already live, besides the PATH of this window.
nim_candidate_dirs() {
  printf '%s\n' \
    "$HOME/.paraloop/nim-$NIM_VERSION/bin" \
    "$HOME/.nimble/bin" \
    "$HOME/.choosenim/toolchains/nim-$NIM_VERSION/bin" \
    "/opt/homebrew/bin" \
    "/usr/local/bin" \
    "/opt/nim/bin" \
    "/usr/local/nim/bin"
}

nim_version_of() { # $1 = path to a nim program; prints its version number or nothing
  local out
  out=$("$1" --version 2>/dev/null || true)
  case "$out" in
    *"Version "*) out=${out#*Version }; printf '%s' "${out%% *}" ;;
  esac
}

find_wanted_nim() { # sets NIM_DIR to the folder of a Nim $NIM_VERSION; sets OTHER_NIM when only another version is around
  NIM_DIR=""
  OTHER_NIM=""
  local candidates dir c v
  candidates=$(command -v nim 2>/dev/null || true)
  while IFS= read -r dir; do
    candidates="$candidates"$'\n'"$dir/nim"
  done <<EOF
$(nim_candidate_dirs)
EOF
  while IFS= read -r c; do
    if [ -z "$c" ] || [ ! -x "$c" ]; then continue; fi
    v=$(nim_version_of "$c")
    if [ "$v" = "$NIM_VERSION" ]; then NIM_DIR=$(dirname "$c"); return 0; fi
    if [ -n "$v" ] && [ -z "$OTHER_NIM" ]; then OTHER_NIM="$v at $c"; fi
  done <<EOF
$candidates
EOF
  return 0
}

nim_platform() { # the name nim-lang.org uses for this computer, or nothing
  case "$OS/$ARCH" in
    Darwin/arm64) echo macosx_arm64 ;;
    Darwin/x86_64) echo macosx_x64 ;;
    Linux/x86_64) echo linux_x64 ;;
    Linux/aarch64|Linux/arm64) echo linux_arm64 ;;
  esac
}

# SHA-256 of nim-$NIM_VERSION-<platform>.tar.xz, copied from the .sha256 files nim-lang.org
# publishes next to each download (checked 2026-10-23). The install also compares the archive to
# the value published there at download time; both must match.
nim_download_size() {
  case "$1" in
    macosx_arm64) echo "about 15 MB" ;;
    macosx_x64)   echo "about 15 MB" ;;
    linux_x64)    echo "about 18 MB" ;;
    linux_arm64)  echo "about 16 MB" ;;
  esac
}

nim_pinned_sha256() {
  case "$1" in
    macosx_arm64) echo 9a3b012d0680d11d6163dd2f145470b090c1045f5e634f42daf119bea1cb2b5e ;;
    macosx_x64)   echo 35df59b9bbe9f5dfcdf40a82b41037e6ac499e2ec0be6688cd3dd0e55c8bc851 ;;
    linux_x64)    echo 0a3a38752e97e9d44aa479b3a7b37336dfe0176daf22ee5b5218ad0991ecd211 ;;
    linux_arm64)  echo cd86a6e2bcbf029c4870aa51df5c0169345dbf9959889112fd15d403c13ae33a ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

find_agent() { # $1 = claude|codex; prints the path of the program, or nothing
  local found d
  found=$(command -v "$1" 2>/dev/null || true)
  if [ -n "$found" ]; then printf '%s' "$found"; return 0; fi
  for d in "$HOME/.local/bin" "$HOME/.claude/local" "$HOME/.npm-global/bin" "$HOME/.volta/bin" "$HOME/.bun/bin" \
           "/opt/homebrew/bin" "/usr/local/bin" "$HOME"/.nvm/versions/node/*/bin; do
    if [ -x "$d/$1" ] && [ ! -d "$d/$1" ]; then printf '%s' "$d/$1"; return 0; fi
  done
}

# --- the steps -------------------------------------------------------------------------------

have_cc() { command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1; }

# The install command for $1 (cc or git) with this Linux's own package manager, or nothing when
# none is known. Without -y: the package manager shows the size and asks once more itself.
linux_package_command() {
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$1" = cc ]; then echo "sudo apt-get install build-essential"; else echo "sudo apt-get install git"; fi
  elif command -v dnf >/dev/null 2>&1; then
    if [ "$1" = cc ]; then echo "sudo dnf install gcc"; else echo "sudo dnf install git"; fi
  elif command -v pacman >/dev/null 2>&1; then
    if [ "$1" = cc ]; then echo "sudo pacman -S --needed base-devel"; else echo "sudo pacman -S --needed git"; fi
  elif command -v zypper >/dev/null 2>&1; then
    if [ "$1" = cc ]; then echo "sudo zypper install gcc"; else echo "sudo zypper install git"; fi
  fi
}

# Offers to install $1 (cc or git) with the Linux package manager. $2 says what it is, $3 what to do by
# hand when the answer is no or there is no package manager this launcher knows.
offer_linux_package() {
  local cmd manager
  cmd=$(linux_package_command "$1")
  if [ -z "$cmd" ]; then fail "$3"; fi
  manager=$(printf '%s' "$cmd" | awk '{print $2}')
  say "      I can install it with your Linux's own package manager ($manager):"
  say "        What:    $2, the version your Linux ships"
  say "        From:    the package servers $manager is already set up to use (nothing new is added)"
  say "        Command: $cmd"
  say "        Where:   the usual system folders, which is why it asks for your password (sudo)"
  say "        Size:    $manager shows it and asks you once more before it downloads anything"
  if [ "$DRY_RUN" = 1 ]; then
    would "ask you: Run that command now? (y/n, Enter means no)"
    would "on y, run exactly: $cmd   (your password is typed into sudo, never into this launcher)"
    would "on n or Enter, stop here with nothing installed"
    return 0
  fi
  if ! ask_yes_no "Run that command now?"; then declined "$3"; fi
  log "\$ $cmd"
  # shellcheck disable=SC2086  # the command is one of the fixed strings above; splitting it is the point
  $cmd || fail "The install command stopped without finishing: $cmd. $3"
}

step_tools() {
  if [ "$OS" = Darwin ]; then
    step "Checking Apple's command line tools (the part of macOS that builds programs)..." "Apple command line tools"
    local missing=0
    if [ "$DRY_RUN" = 1 ] && [ "${PARALOOP_LAUNCHER_FAKE_CLT:-}" = missing ]; then
      missing=1
    elif [ "$DRY_RUN" = 1 ] && ! command -v xcode-select >/dev/null 2>&1; then
      would "run: xcode-select -p   (not available on this computer, so assuming they are present)"
    elif ! xcode-select -p >/dev/null 2>&1; then
      missing=1
    fi
    if [ "$missing" = 1 ]; then
      say "      Apple's command line tools are not installed yet. Studio needs them to build programs"
      say "      (git comes with them). I can open Apple's own installer for them:"
      say "        What:    Command Line Tools for Xcode, the version Apple offers for this macOS, free"
      say "        From:    Apple, through macOS's own installer (this launcher downloads nothing)"
      say "        Command: xcode-select --install"
      say "        Where:   /Library/Developer/CommandLineTools (macOS may ask for your Mac password)"
      say "        Size:    Apple's window shows it before anything downloads"
      if [ "$DRY_RUN" = 1 ]; then
        would "ask you: Open Apple's installer now? (y/n, Enter means no)"
        would "on y, run: xcode-select --install, tell you a window will pop up (click Install, wait for it to finish, then double-click this file again), and stop here without an error"
        would "on n or Enter, stop here with nothing installed"
        STOP_AFTER_TOOLS=1
        return 0
      fi
      if ! ask_yes_no "Open Apple's installer now?"; then
        declined "When you are ready, open Terminal, run: xcode-select --install  click Install, wait until it is done, then double-click Paraloop-Studio.command again."
      fi
      say "      A window is about to pop up: click Install, wait until it says it is done,"
      say "      then double-click Paraloop-Studio.command again."
      log "xcode-select --install"
      xcode-select --install >>"$LOG" 2>&1 || true
      pause_before_close
      exit 0
    fi
    ok "Apple's command line tools are installed."
  else
    step "Checking for a C compiler (the part of your computer that builds programs)..." "C compiler"
    if ! faked_missing cc && have_cc; then
      ok "found a C compiler."
      return 0
    fi
    say "      No C compiler was found."
    offer_linux_package cc "a C compiler (gcc and the usual build tools)" \
      "Install a C compiler with your package manager (on Debian/Ubuntu: sudo apt install build-essential; on Fedora: sudo dnf install gcc; on Arch: sudo pacman -S base-devel), then run this again."
    if [ "$DRY_RUN" = 0 ]; then
      have_cc || fail "The install finished but no C compiler can be found yet. Open a new terminal window and run this again."
      ok "found a C compiler."
    fi
  fi
}

step_git() {
  step "Checking for git (keeps your save points)..." "git"
  if ! faked_missing git && command -v git >/dev/null 2>&1; then
    ok "git is installed."
  elif [ "$OS" = Darwin ]; then
    fail "git was not found. On a Mac it comes with Apple's command line tools: run xcode-select --install, wait for it to finish, then double-click this file again."
  else
    say "      git was not found."
    offer_linux_package git "git" "Install git with your package manager (on Debian/Ubuntu: sudo apt install git; on Fedora: sudo dnf install git; on Arch: sudo pacman -S git), then run this again."
    if [ "$DRY_RUN" = 0 ]; then
      command -v git >/dev/null 2>&1 || fail "The install finished but git cannot be found yet. Open a new terminal window and run this again."
      ok "git is installed."
    fi
  fi
  if command -v git >/dev/null 2>&1 && ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    note "Note: this folder was not copied with git (for example, it came from a zip file), so save points will not work until the captain gives you a git copy. Studio still starts."
  fi
}

step_nim() {
  step "Checking for Nim $NIM_VERSION (the language the games are written in)..." "Nim $NIM_VERSION"
  find_wanted_nim
  if [ -n "$NIM_DIR" ]; then
    ok "found Nim $NIM_VERSION in $NIM_DIR"
  else
    local platform dest url
    platform=$(nim_platform)
    dest="$HOME/.paraloop/nim-$NIM_VERSION"
    if [ -n "$OTHER_NIM" ]; then note "Found a different Nim ($OTHER_NIM). Paraloop needs exactly $NIM_VERSION; the other one is left alone."; fi
    if [ -z "$platform" ]; then
      fail "This computer ($OS $ARCH) has no official Nim $NIM_VERSION download I know how to use. Install Nim $NIM_VERSION yourself from https://nim-lang.org/install.html, then run this again."
    fi
    url="$NIM_BASE_URL/nim-$NIM_VERSION-$platform.tar.xz"
    say "      Nim $NIM_VERSION is not installed. I can download the official release and set it up:"
    say "        What:    Nim $NIM_VERSION for $platform (nimble, its package tool, comes with it)"
    say "        From:    $url"
    say "        Check:   its SHA-256 must match $url.sha256 and the value written in this launcher"
    say "        Where:   $dest"
    say "                 (your home folder: no password, nothing else on this computer changes)"
    say "        Size:    $(nim_download_size "$platform")"
    say "        PATH:    added for this run only; your shell settings are not changed"
    if [ "$DRY_RUN" = 1 ]; then
      would "ask you: Download and install Nim $NIM_VERSION now? (y/n, Enter means no)"
      would "on n or Enter, stop here and change nothing"
      would "on y, download $url from nim-lang.org"
      would "check its SHA-256 against $url.sha256 and against the value written in this launcher, and refuse to use it if either differs"
      would "unpack it into $dest (your home folder, no sudo, nothing else on the computer changes)"
      return 0
    fi
    if ! ask_yes_no "Download and install Nim $NIM_VERSION now?"; then
      declined "Studio cannot build games without Nim. Double-click again when you are ready, or install Nim $NIM_VERSION yourself from https://nim-lang.org/install.html."
    fi
    install_nim "$platform" "$dest"
    NIM_DIR="$dest/bin"
  fi
  PATH="$NIM_DIR:$HOME/.nimble/bin:$PATH"
  export PATH
  if [ "$DRY_RUN" = 0 ] && ! command -v nimble >/dev/null 2>&1; then
    fail "Nim was found in $NIM_DIR but nimble (its package tool, normally in the same folder) was not."
  fi
}

install_nim() { # $1 = platform, $2 = destination folder
  local platform=$1 dest=$2 archive pinned published actual work
  archive="nim-$NIM_VERSION-$platform.tar.xz"
  pinned=$(nim_pinned_sha256 "$platform")
  work=$(mktemp -d "${TMPDIR:-/tmp}/paraloop-nim.XXXXXX")
  CLEANUP_DIR=$work
  note "Downloading $archive ($(nim_download_size "$platform"))..."
  log "\$ curl $NIM_BASE_URL/$archive"
  curl -fL --proto '=https' --tlsv1.2 --retry 2 --progress-bar -o "$work/$archive" "$NIM_BASE_URL/$archive" \
    || fail "The Nim download failed. Check that this computer is online, then run this again."
  published=$(curl -fsSL --proto '=https' --tlsv1.2 --retry 2 "$NIM_BASE_URL/$archive.sha256" 2>>"$LOG" | awk '{print $1}') \
    || fail "The Nim checksum download failed. Check that this computer is online, then run this again."
  actual=$(sha256_of "$work/$archive")
  log "sha256 actual=$actual published=$published pinned=$pinned"
  if [ "$actual" != "$pinned" ] || [ "$actual" != "$published" ]; then
    fail "The downloaded Nim does not match its published checksum, so it was NOT used and nothing was installed. Computed: $actual. nim-lang.org publishes: $published. This launcher expects: $pinned."
  fi
  ok "checksum matches ($actual)."
  tar -xf "$work/$archive" -C "$work" >>"$LOG" 2>&1 || fail "The downloaded Nim could not be unpacked."
  mkdir -p "$HOME/.paraloop"
  if [ -e "$dest" ]; then
    local aside
    aside="$dest.old-$(date +%s)"
    mv "$dest" "$aside"
    note "An older folder was in the way; it was moved to $aside"
  fi
  mv "$work/nim-$NIM_VERSION" "$dest"
  if [ "$(nim_version_of "$dest/bin/nim")" != "$NIM_VERSION" ]; then
    fail "Nim was unpacked into $dest but would not run. Send the captain this message; the Nim download for $platform may not work on this computer."
  fi
  ok "Nim $NIM_VERSION installed in $dest"
  note "Nothing was added to your shell settings: this launcher finds Nim there itself every time."
}

deps_ready() { # nimble.paths exists, is newer than the files it comes from, and points at folders that exist
  [ -f nimble.paths ] || return 1
  if [ nimble.lock -nt nimble.paths ] || [ paraloop.nimble -nt nimble.paths ]; then return 1; fi
  grep -q 'nimble.paths' config.nims || return 1
  local dir
  while IFS= read -r dir; do
    [ -d "$dir" ] || return 1
  done < <(sed -n 's/^--path:"\(.*\)"$/\1/p' nimble.paths)
  return 0
}

step_packages() {
  step "Fetching the game libraries (nimble install -d -y, then nimble setup)..." "game libraries"
  if deps_ready; then
    ok "the libraries are already set up."
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    would "run: nimble install -d -y   (downloads the libraries pinned in nimble.lock)"
    would "run: nimble setup"
    return 0
  fi
  note "The first time this takes a few minutes. It is working even when nothing moves."
  run_logged nimble install -d -y || fail "nimble could not fetch the game libraries. Check that this computer is online, then run this again."
  run_logged nimble setup || fail "nimble setup failed."
  deps_ready || fail "The libraries were fetched but are not set up where the build expects them."
  ok "libraries ready."
}

para_is_fresh() { # tmp/para exists and no source it is built from is newer
  [ -x tmp/para ] || return 1
  local f dirs newer
  for f in config.nims paraloop.nimble nimble.lock nimble.paths; do
    if [ -e "$f" ] && [ "$f" -nt tmp/para ]; then return 1; fi
  done
  dirs="tools/para src template patches examples"
  local existing=""
  for f in $dirs; do [ -d "$f" ] && existing="$existing $f"; done
  # shellcheck disable=SC2086  # the word splitting is the point: one argument per folder
  newer=$(find $existing -type f \( -name '*.nim' -o -name '*.nims' -o -name '*.html' -o -name '*.toml' -o -name '*.patch' \) -newer tmp/para 2>/dev/null || true)
  [ -z "$newer" ]
}

step_build() {
  step "Building para, the program behind Studio..." "build para"
  if para_is_fresh; then
    ok "tmp/para is already built and up to date."
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    would "run: nim c --hints:off --outdir:tmp tools/para/para.nim"
    return 0
  fi
  mkdir -p tmp
  note "This takes a few minutes the first time and is quicker after. It is working even when nothing moves."
  run_logged nim c --hints:off --outdir:tmp tools/para/para.nim || fail "Building para failed. The log has the compiler's words."
  [ -x tmp/para ] || fail "The build finished but tmp/para was not made."
  ok "built tmp/para"
}

step_agent() {
  step "Checking the producer's chat program (claude or codex: installed, signed in, folder trusted)..." "claude or codex"
  local claude codex out line
  claude=$(find_agent claude)
  codex=$(find_agent codex)
  if [ -n "$claude" ]; then ok "found Claude Code: $claude"; PATH="$PATH:$(dirname "$claude")"; fi
  if [ -n "$codex" ]; then ok "found Codex: $codex"; PATH="$PATH:$(dirname "$codex")"; fi
  export PATH
  if [ -z "$claude" ] && [ -z "$codex" ]; then
    say "      Neither Claude Code nor Codex is installed. The producer's chat needs one of them."
    say "      Install one from its official page, then open it once and sign in there:"
    say "        Claude Code: $CLAUDE_INSTALL_URL"
    say "        Codex:       $CODEX_INSTALL_URL"
    say "      Studio never handles sign-in and never sees your password or key: you sign in once,"
    say "      inside that program's own window, and Studio just uses the program you installed."
    say "      You can still open Studio now; the chat starts working once one of them is installed."
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    would "run: tmp/para studio --check   (the startup checks the Studio page shows: signed in, folder trusted; they never stop Studio from opening)"
    return 0
  fi
  # Read-only, like the page's checks: no model is asked anything and no login is read. Whatever it
  # answers, Studio still opens.
  out=$(tmp/para studio --check 2>&1) || true
  while IFS= read -r line; do note "$line"; done <<EOF
$out
EOF
}

step_studio() {
  step "Starting Studio..." "start Studio"
  if [ "$NO_STUDIO" = 1 ]; then
    note "not started now (--no-studio)."
    if [ "$DRY_RUN" = 1 ]; then say ""; say "Dry run finished: nothing was installed, built or opened."; fi
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    would "run: tmp/para studio   (it prints a link and opens it in your default browser)"
    say ""
    say "Dry run finished: nothing was installed, built or opened."
    return 0
  fi
  say "      Studio opens in your browser. Keep this window open while you use it;"
  say "      press Ctrl+C here (or close this window) to stop Studio."
  say ""
  log "starting tmp/para studio (its output is not logged: it holds a per-run key)"
  local status=0 stopped=0
  trap 'stopped=1' INT
  tmp/para studio || status=$?
  trap on_interrupt INT
  if [ "$status" != 0 ] && [ "$stopped" = 0 ]; then
    fail "Studio stopped with an error (exit code $status). Copy what Studio printed above into your message too."
  fi
  say ""
  say "Studio stopped. Double-click this file again to start it."
  pause_before_close
}

main() {
  if [ "$DRY_RUN" = 1 ]; then
    say "Para Studio launcher (dry run: nothing will be installed, built or opened)"
  else
    mkdir -p tmp
    if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 2000000 ]; then mv "$LOG" "$LOG.1"; fi
    say "Para Studio launcher"
    say "A record of what happens is kept in $LOG"
    log "---- launcher run, $(computer_summary)"
  fi
  step_tools
  if [ "$STOP_AFTER_TOOLS" = 1 ]; then
    say ""
    say "Dry run finished: nothing was installed, built or opened."
    return 0
  fi
  step_git
  step_nim
  step_packages
  step_build
  step_agent
  step_studio
}

main
