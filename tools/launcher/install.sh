#!/bin/sh
# Para Studio one-line installer for macOS and Linux:
#
#   curl -fsSL https://pdepaula.github.io/parastudio/install.sh | sh
#
# It checks for git (needed to make the copy), says exactly what it will do, and does it only after
# you type y: it clones Para Studio into a new folder, then runs the launcher inside that copy
# (tools/launcher/launch.sh --no-studio), which checks for a C compiler and Nim 2.2.10, offers each
# one that is missing with what, from where and into which folder, asks y/n again before installing
# it, fetches the game libraries (nimble install -d -y, nimble setup) and builds `para`. At the end
# it asks whether to start Studio. docs/install.md has the whole story, and how to read this file
# before running it.
#
# Options are environment variables, so they work the same when this file is piped into sh:
#   PARASTUDIO_DIR=<folder>  where the copy goes (default: $HOME/parastudio). An existing folder is
#                            never overwritten: a Para Studio copy is only set up again (finished
#                            steps are skipped), anything else is refused.
#   PARASTUDIO_YES=1         unattended (CI): yes to this script's own question only. Offers to
#                            install git, a C compiler or Nim are answered no, so a run that lacks
#                            one stops with the fix and installs nothing. Studio is not started.
#   PARASTUDIO_REPO=<url>    the repository to clone (default: the public one; CI clones its own
#                            checkout). The commit check below still applies.
#
# What it never does: download anything but the git clone (and what the launcher asks you about),
# run sudo (only the launcher can, as the exact package-manager command it showed and you said yes
# to), edit a shell profile, read or write a login, or send anything anywhere else. No telemetry.

# The commit this copy installs. tools/docs/build.py writes the deployed commit here when it builds
# the docs site, so the published script and the code it clones always match. Empty in the
# repository itself: then the newest code on main is used, after saying so.
PARASTUDIO_COMMIT=""

set -u

say() { printf '%s\n' "$*"; }

stop() { # $1 = what went wrong and what to do; exits 1
  say ""
  say "Stopped: $1"
  say "Run the same line again once that is fixed: it never overwrites what is there, and finished steps are skipped."
  exit 1
}

ask() { # $1 = the question; yes only for y or yes typed at the keyboard
  if [ "$YES" = 1 ]; then say "$1 yes (PARASTUDIO_YES=1)"; return 0; fi
  printf '%s (y/n, Enter means no) ' "$1"
  answer=""
  IFS= read -r answer <"$TTY" || answer=""
  case "$answer" in y|Y|yes|Yes|YES) return 0 ;; *) return 1 ;; esac
}

git_fix() {
  case "$(uname -s)" in
    Darwin) say "  On a Mac git comes with Apple's command line tools: run  xcode-select --install" ;;
    *) say "  Install it with your package manager, for example: sudo apt-get install git (Debian, Ubuntu),"
       say "  sudo dnf install git (Fedora) or sudo pacman -S git (Arch)" ;;
  esac
  say "  then run this line again."
}

main() {
  REPO=${PARASTUDIO_REPO:-https://github.com/PDepaula/parastudio.git}
  DIR=${PARASTUDIO_DIR:-$HOME/parastudio}
  YES=${PARASTUDIO_YES:-0}
  # Piped into sh, this script's input is the download, so answers are read from the terminal.
  TTY=/dev/tty
  if [ "$YES" != 1 ] && ! (true <"$TTY") 2>/dev/null; then
    stop "there is no terminal to type an answer in. Run this from a terminal window (or set PARASTUDIO_YES=1 for an unattended run)."
  fi

  say "Para Studio installer"
  say ""
  say "Checking what this computer has..."
  command -v git >/dev/null 2>&1 || { say "  git: not found. It is needed to make your copy (and keeps your save points)."; git_fix; stop "git is missing."; }
  say "  git: $(git --version)"
  command -v bash >/dev/null 2>&1 || stop "bash was not found; the launcher needs it. Install bash with your package manager, then run this again."
  if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1; then
    say "  C compiler: found"
  else
    say "  C compiler: not found yet (the launcher offers one, and asks first)"
  fi
  case "$(nim --version 2>/dev/null)" in
    *"Version 2.2.10 "*) say "  Nim 2.2.10: found" ;;
    *) say "  Nim 2.2.10: not on PATH (the launcher looks in a few more places, then offers the official download, and asks first)" ;;
  esac

  if [ -n "$PARASTUDIO_COMMIT" ]; then
    CODE="commit $PARASTUDIO_COMMIT (the code this installer was published with)"
  else
    say ""
    say "Note: this copy of the installer has no commit written into it (it was not downloaded from"
    say "the docs site), so it would install the newest code on main, which nobody has pinned."
    CODE="the newest commit on main (not pinned)"
  fi

  EXISTING=0
  if [ -e "$DIR" ]; then
    if [ -f "$DIR/tools/launcher/launch.sh" ] && git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
      EXISTING=1
    else
      stop "$DIR already exists and is not a Para Studio copy. I will not touch it. Pick another folder, for example: PARASTUDIO_DIR=\"\$HOME/parastudio2\" (see docs/install.md)."
    fi
  fi

  say ""
  say "Here is what I will do, and nothing else:"
  if [ "$EXISTING" = 1 ]; then
    say "  Folder:  $DIR already holds a Para Studio copy (at commit $(git -C "$DIR" rev-parse HEAD))."
    say "           I will not replace or update any file in it; I only finish setting it up."
  else
    say "  What:    Para Studio, $CODE"
    say "  From:    $REPO (git clone)"
    say "  Where:   $DIR (a new folder)"
  fi
  say "  Then:    the launcher in that folder (tools/launcher/launch.sh) checks for a C compiler and"
  say "           Nim 2.2.10. For each one missing it says what it would install, from where and into"
  say "           which folder, and asks you y/n again before installing it."
  say "           Then: nimble install -d -y and nimble setup (the game libraries, into ~/.nimble)"
  say "           and it builds para (tmp/para in the folder). This takes a few minutes."
  say "  Last:    I ask whether to start Para Studio."
  say "  To remove it later, delete the folder."
  say ""
  ask "Go ahead?" || { say "Okay, nothing was installed and nothing changed."; exit 1; }

  if [ "$EXISTING" = 0 ]; then
    say ""
    say "Cloning into $DIR..."
    git clone --quiet "$REPO" "$DIR" || stop "git clone did not finish. Check that this computer is online. If $DIR was made, delete it before running this again."
    if [ -n "$PARASTUDIO_COMMIT" ]; then
      git -C "$DIR" cat-file -e "$PARASTUDIO_COMMIT^{commit}" 2>/dev/null \
        || git -C "$DIR" fetch --quiet origin "$PARASTUDIO_COMMIT" \
        || stop "commit $PARASTUDIO_COMMIT was not found in $REPO. Delete $DIR and get the installer again from the docs site."
      git -C "$DIR" checkout --quiet -B main "$PARASTUDIO_COMMIT" || stop "git could not check out commit $PARASTUDIO_COMMIT in $DIR."
      HEAD=$(git -C "$DIR" rev-parse HEAD)
      [ "$HEAD" = "$PARASTUDIO_COMMIT" ] || stop "$DIR is at commit $HEAD, not $PARASTUDIO_COMMIT. Delete $DIR before running this again."
      say "  ok: $DIR is at commit $HEAD, the one this installer names."
    else
      git -C "$DIR" checkout --quiet -B main origin/main || stop "git could not check out main in $DIR."
      say "  ok: $DIR is at commit $(git -C "$DIR" rev-parse HEAD), the newest on main."
    fi
  fi

  say ""
  say "Running the launcher in $DIR (tools/launcher/launch.sh --no-studio)..."
  if [ "$YES" = 1 ]; then
    PARALOOP_LAUNCHER_UNATTENDED=1 bash "$DIR/tools/launcher/launch.sh" --no-studio </dev/null || stop "the launcher stopped; what it printed above says why."
  else
    bash "$DIR/tools/launcher/launch.sh" --no-studio <"$TTY" || stop "the launcher stopped; what it printed above says why."
  fi
  # Apple's installer for its command line tools runs on its own: the launcher stops after opening it.
  [ -x "$DIR/tmp/para" ] || stop "setup is not finished yet (para was not built). When the installer the launcher opened is done, run this line again."

  say ""
  say "Para Studio is installed in $DIR."
  case "$(uname -s)" in
    Darwin) say "To start it later, double-click Paraloop-Studio.command in that folder." ;;
    *) say "To start it later, run: $DIR/paraloop-studio.sh" ;;
  esac
  if [ "$YES" = 1 ]; then return 0; fi
  ask "Start Para Studio now?" || return 0
  exec bash "$DIR/tools/launcher/launch.sh" <"$TTY"
}

# Everything runs from here, after the whole file has arrived: a download cut off half way runs nothing.
main
