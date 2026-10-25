# Para Studio one-line installer for Windows:
#
#   irm https://pdepaula.github.io/parastudio/install.ps1 | iex
#
# It checks for git (needed to make the copy), says exactly what it will do, and does it only after
# you type y: it clones Para Studio into a new folder, then runs the launcher inside that copy
# (tools\launcher\launch.bat --no-studio), which checks for a C compiler, git and Nim 2.2.10, offers
# each one that is missing with what, from where and into which folder, asks y/n again before
# installing it, fetches the game libraries (nimble install -d -y, nimble setup) and builds `para`.
# At the end it asks whether to start Studio. docs/install.md has the whole story, and how to read
# this file before running it.
#
# Options are environment variables, because a script piped into iex takes no parameters:
#   $env:PARASTUDIO_DIR = '<folder>'  where the copy goes (default: your user folder\parastudio). An
#                                     existing folder is never overwritten: a Para Studio copy is
#                                     only set up again (finished steps are skipped), anything else
#                                     is refused.
#   $env:PARASTUDIO_YES = '1'         unattended (CI): yes to this script's own question only. Offers
#                                     to install a C compiler, git or Nim are answered no, so a run
#                                     that lacks one stops with the fix and installs nothing. Studio
#                                     is not started.
#   $env:PARASTUDIO_REPO = '<url>'    the repository to clone (default: the public one; CI clones its
#                                     own checkout). The commit check below still applies.
#
# It needs no change to the execution policy (a script piped into iex is not a script file, and the
# launcher is a batch file). What it never does: download anything but the git clone (and what the
# launcher asks you about), ask for an administrator password, change a setting of the computer,
# read or write a login, or send anything anywhere else. No telemetry. Plain ASCII, so Windows
# PowerShell 5.1 and PowerShell 7 read it the same.

& {
  # The commit this copy installs. tools/docs/build.py writes the deployed commit here when it
  # builds the docs site, so the published script and the code it clones always match. Empty in the
  # repository itself: then the newest code on main is used, after saying so.
  $PARASTUDIO_COMMIT = ''

  $ErrorActionPreference = 'Continue'  # this block only; native commands are checked by exit code
  $repo = if ($env:PARASTUDIO_REPO) { $env:PARASTUDIO_REPO } else { 'https://github.com/PDepaula/parastudio.git' }
  $dir = if ($env:PARASTUDIO_DIR) { $env:PARASTUDIO_DIR } else { Join-Path $HOME 'parastudio' }
  $yes = $env:PARASTUDIO_YES -eq '1'
  $launcher = Join-Path $dir 'tools\launcher\launch.bat'

  function Say([string]$text = '') { Write-Host $text }

  function Stop-Install([string]$why) {
    Say ''
    Say "Stopped: $why"
    Say 'Run the same line again once that is fixed: it never overwrites what is there, and finished steps are skipped.'
    throw 'Para Studio install stopped.'
  }

  function Ask([string]$question) {
    # Yes only for y or yes typed here; Enter and anything else are no.
    if ($yes) { Say "$question yes (PARASTUDIO_YES=1)"; return $true }
    $answer = Read-Host "$question (y/n, Enter means no)"
    return @('y', 'yes') -contains "$answer".Trim().ToLower()
  }

  function Have([string]$name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

  Say 'Para Studio installer'
  Say ''
  Say 'Checking what this computer has...'
  if (-not (Have 'git')) {
    # Where Git for Windows installs itself; used for this window only, like the launcher does.
    foreach ($d in @("$env:ProgramFiles\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd")) {
      if (Test-Path (Join-Path $d 'git.exe')) { $env:Path = "$d;$env:Path"; break }
    }
  }
  if (-not (Have 'git')) {
    Say '  git: not found. It is needed to make your copy (and keeps your save points).'
    Say '  Install Git for Windows from https://git-scm.com/download/win, or in a terminal run:'
    Say '    winget install --id Git.Git -e --source winget --scope user'
    Say '  then open a new PowerShell window and run this line again.'
    Stop-Install 'git is missing.'
  }
  Say "  git: $(git --version)"
  if ((Have 'gcc') -or (Have 'cc') -or (Have 'clang')) { Say '  C compiler: found' }
  else { Say '  C compiler: not found yet (the launcher offers one, and asks first)' }
  $nimVersion = if (Have 'nim') { "$(nim --version 2>$null)" } else { '' }
  if ($nimVersion -match 'Version 2\.2\.10 ') { Say '  Nim 2.2.10: found' }
  else { Say '  Nim 2.2.10: not on PATH (the launcher looks in a few more places, then offers the official download, and asks first)' }

  if ($PARASTUDIO_COMMIT) {
    $code = "commit $PARASTUDIO_COMMIT (the code this installer was published with)"
  } else {
    Say ''
    Say 'Note: this copy of the installer has no commit written into it (it was not downloaded from'
    Say 'the docs site), so it would install the newest code on main, which nobody has pinned.'
    $code = 'the newest commit on main (not pinned)'
  }

  $existing = $false
  if (Test-Path $dir) {
    git -C $dir rev-parse --git-dir *> $null
    if ((Test-Path $launcher) -and $LASTEXITCODE -eq 0) { $existing = $true }
    else { Stop-Install "$dir already exists and is not a Para Studio copy. I will not touch it. Pick another folder, for example: `$env:PARASTUDIO_DIR = `"`$HOME\parastudio2`" (see docs/install.md)." }
  }

  Say ''
  Say 'Here is what I will do, and nothing else:'
  if ($existing) {
    Say "  Folder:  $dir already holds a Para Studio copy (at commit $(git -C $dir rev-parse HEAD))."
    Say '           I will not replace or update any file in it; I only finish setting it up.'
  } else {
    Say "  What:    Para Studio, $code"
    Say "  From:    $repo (git clone)"
    Say "  Where:   $dir (a new folder)"
  }
  Say '  Then:    the launcher in that folder (tools\launcher\launch.bat) checks for a C compiler, git'
  Say '           and Nim 2.2.10. For each one missing it says what it would install, from where and'
  Say '           into which folder, and asks you y/n again before installing it.'
  Say '           Then: nimble install -d -y and nimble setup (the game libraries, into your user'
  Say '           folder\.nimble) and it builds para (tmp\para.exe in the folder). This takes a few minutes.'
  Say '  Last:    I ask whether to start Para Studio.'
  Say '  To remove it later, delete the folder.'
  Say ''
  if (-not (Ask 'Go ahead?')) { Say 'Okay, nothing was installed and nothing changed.'; return }

  if (-not $existing) {
    Say ''
    Say "Cloning into $dir..."
    git clone --quiet $repo $dir
    if ($LASTEXITCODE -ne 0) { Stop-Install "git clone did not finish. Check that this computer is online. If $dir was made, delete it before running this again." }
    if ($PARASTUDIO_COMMIT) {
      git -C $dir cat-file -e "$PARASTUDIO_COMMIT^{commit}" *> $null
      if ($LASTEXITCODE -ne 0) { git -C $dir fetch --quiet origin $PARASTUDIO_COMMIT }
      if ($LASTEXITCODE -ne 0) { Stop-Install "commit $PARASTUDIO_COMMIT was not found in $repo. Delete $dir and get the installer again from the docs site." }
      git -C $dir checkout --quiet -B main $PARASTUDIO_COMMIT
      if ($LASTEXITCODE -ne 0) { Stop-Install "git could not check out commit $PARASTUDIO_COMMIT in $dir." }
      $head = "$(git -C $dir rev-parse HEAD)".Trim()
      if ($head -ne $PARASTUDIO_COMMIT) { Stop-Install "$dir is at commit $head, not $PARASTUDIO_COMMIT. Delete $dir before running this again." }
      Say "  ok: $dir is at commit $head, the one this installer names."
    } else {
      git -C $dir checkout --quiet -B main origin/main
      if ($LASTEXITCODE -ne 0) { Stop-Install "git could not check out main in $dir." }
      Say "  ok: $dir is at commit $(git -C $dir rev-parse HEAD), the newest on main."
    }
  }

  Say ''
  Say "Running the launcher in $dir (tools\launcher\launch.bat --no-studio)..."
  $before = $env:PARALOOP_LAUNCHER_UNATTENDED
  if ($yes) { $env:PARALOOP_LAUNCHER_UNATTENDED = '1' }
  try { & $launcher --no-studio; $ran = $? } finally { $env:PARALOOP_LAUNCHER_UNATTENDED = $before }
  if (-not $ran -or $LASTEXITCODE -ne 0) { Stop-Install 'the launcher stopped; what it printed above says why.' }
  if (-not (Test-Path (Join-Path $dir 'tmp\para.exe'))) { Stop-Install 'setup is not finished yet (para.exe was not built).' }

  Say ''
  Say "Para Studio is installed in $dir."
  Say 'To start it later, double-click Paraloop-Studio.bat in that folder.'
  if ($yes) { return }
  if (-not (Ask 'Start Para Studio now?')) { return }
  & $launcher
}
