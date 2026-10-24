@echo off
rem Para Studio launcher for Windows: checks what Studio needs (a C compiler, git, Nim), offers to
rem install what is missing, builds `para`, prints the producer's startup checks and starts
rem `tmp\para.exe studio`, which opens the browser itself. Run through Paraloop-Studio.bat
rem (double-click); see docs/windows.md. It mirrors tools/launcher/launch.sh (macOS and Linux), with
rem two differences: it checks all three tools before it offers anything, so every offer comes in
rem one go, and it leaves finding the chat program to `para studio --check`.
rem
rem   launch.bat [--dry-run | --check] [--help]
rem
rem --dry-run (or --check, the same) runs the same checks (they only look), says what it would offer
rem to install and what each later step WOULD do; it installs, builds, fetches, opens and asks
rem nothing. Test hooks, read only in a dry run: PARALOOP_LAUNCHER_FAKE_MISSING=cc,git,nim pretends
rem those are not installed; PARALOOP_LAUNCHER_DRY_ASK=1 makes the dry run ask each offer's real
rem question and say what it WOULD do for the answer it got, still running no install.
rem
rem When something is missing it is offered, never just installed: the launcher prints what it would
rem install (name and version), from where (the exact link or winget command), into which folder and
rem how big, then asks a plain yes/no. Only y or yes is yes; Enter, anything else and an input that is
rem closed are no, and no stops with what to install by hand. The routes are the official ones:
rem winget (the app installer that comes with Windows) for the C compiler and git, installed for
rem this user only, and Nim's release zip from nim-lang.org, its published SHA-256 checked, unpacked
rem into %USERPROFILE%\.paraloop.
rem
rem What it never does: install anything without that yes, run a downloaded script, ask for an
rem administrator password, change PATH or any setting of the computer itself (PATH is only extended
rem inside this window; winget, when you say yes to it, adds the program it installed to your user
rem PATH as it always does), read or write a login or a config of claude or codex, or send anything
rem anywhere except nim-lang.org (the Nim download and its checksum), the winget install you said yes
rem to, nimble's package fetch and git. The log (tmp\launcher.log) holds only what the steps printed;
rem Studio's own output, which carries its per-run key, is never written to it.
rem
rem Plain batch, ASCII only, CRLF line endings (see .gitattributes). Written without ( ) blocks
rem and without delayed expansion on purpose: a PATH containing "Program Files (x86)" breaks the
rem first, and a folder name containing ! breaks the second (the one exception is :ask, which turns
rem it on for its own two lines so that an answer with a quote in it cannot break the script). Text
rem that is echoed must not contain the characters ampersand, pipe, less-than, greater-than, caret
rem or percent.

setlocal EnableExtensions DisableDelayedExpansion

set "NIM_VERSION=2.2.10"
set "NIM_ZIP=nim-2.2.10_x64.zip"
set "NIM_ZIP_URL=https://nim-lang.org/download/nim-2.2.10_x64.zip"
rem SHA-256 of that zip, copied from the .sha256 file nim-lang.org publishes next to it (checked
rem 2026-10-24). The install also compares the zip to the value published there at download time;
rem both must match.
set "NIM_ZIP_SHA256=fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f"
set "NIM_ZIP_SIZE=about 28 MB"
set "NIM_HOME=%USERPROFILE%\.paraloop\nim-2.2.10"
set "CC_WINGET=winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e --source winget"
set "GIT_WINGET=winget install --id Git.Git -e --source winget --scope user"
set "GIT_URL=https://git-scm.com/download/win"
set "STEPS=7"
set "STEP_NO=0"
set "STEP_NAME=starting"
set "DRY_RUN=0"

for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
cd /d "%ROOT%"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--dry-run" set "DRY_RUN=1" & shift & goto parse_args
if /i "%~1"=="--check" set "DRY_RUN=1" & shift & goto parse_args
if /i "%~1"=="--help" goto help
if /i "%~1"=="-h" goto help
if "%~1"=="/?" goto help
>&2 echo Unknown option: %~1 (try --help)
exit /b 2

:help
echo Para Studio launcher for Windows
echo   launch.bat [--dry-run or --check]
echo   --dry-run  check what is installed, say what it would offer to install and what each step
echo              would do; install, build and open nothing, and ask nothing (--check is the same)
echo See docs/windows.md.
exit /b 0

:args_done
if "%DRY_RUN%"=="1" set "LOG=NUL"
if not "%DRY_RUN%"=="1" set "LOG=%ROOT%\tmp\launcher.log"
set "FAKE=,"
if "%DRY_RUN%"=="1" set "FAKE=,%PARALOOP_LAUNCHER_FAKE_MISSING%,"
set "DRY_ASK="
if "%DRY_RUN%"=="1" if "%PARALOOP_LAUNCHER_DRY_ASK%"=="1" set "DRY_ASK=1"

set "ARCH=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "ARCH=%PROCESSOR_ARCHITEW6432%"
set "OSVER=Windows"
for /f "delims=" %%V in ('ver') do set "OSVER=%%V"

if "%DRY_RUN%"=="1" goto banner_dry
if not exist "%ROOT%\tmp" mkdir "%ROOT%\tmp"
echo Para Studio launcher
echo A record of what happens is kept in %LOG%
call :log "---- launcher run, %OSVER%, %ARCH%"
goto banner_done
:banner_dry
echo Para Studio launcher (dry run: nothing will be installed, built or opened)
:banner_done

rem --- step 1: a C compiler ----------------------------------------------------------------------

call :step "Checking for a C compiler (the part of your computer that builds programs)..." "C compiler"
set "HAVE_CC="
set "MISSING_CC="
if "%FAKE:,cc,=%"=="%FAKE%" call :look_cc
if not defined HAVE_CC goto cc_missing
call :ok "found a C compiler: %HAVE_CC%"
goto cc_end
:cc_missing
set "MISSING_CC=1"
call :bad "No C compiler was found."
:cc_end

rem --- step 2: git -------------------------------------------------------------------------------

call :step "Checking for git (keeps your save points)..." "git"
set "HAVE_GIT="
set "MISSING_GIT="
if "%FAKE:,git,=%"=="%FAKE%" call :look_git
if not defined HAVE_GIT goto git_missing
call :ok "git is installed."
call :git_copy_note
goto git_end
:git_missing
set "MISSING_GIT=1"
call :bad "git was not found."
:git_end

rem --- step 3: Nim -------------------------------------------------------------------------------

call :step "Checking for Nim %NIM_VERSION% (the language the games are written in)..." "Nim %NIM_VERSION%"
set "NIM_DIR="
set "OTHER_NIM="
set "MISSING_NIM="
if "%FAKE:,nim,=%"=="%FAKE%" call :look_nim
if not defined NIM_DIR goto nim_missing
call :ok "found Nim %NIM_VERSION% in %NIM_DIR%"
goto nim_end
:nim_missing
if defined OTHER_NIM call :note "Found a different Nim (%OTHER_NIM%). Paraloop needs exactly %NIM_VERSION%; the other one is left alone."
set "MISSING_NIM=1"
call :bad "Nim %NIM_VERSION% was not found."
:nim_end

if defined MISSING_CC goto offers
if defined MISSING_GIT goto offers
if defined MISSING_NIM goto offers
goto tools_ok

rem --- the offers: what is missing, what would be installed, from where; then yes or no -----------

:offers
echo.
echo ------------------------------------------------------------------------------
echo Something Studio needs is not on this computer yet. For each one below I say
echo exactly what I would install, from where and into which folder, and then ask.
echo Only y or yes is yes. Enter, or anything else, means no and installs nothing.
echo ------------------------------------------------------------------------------
set "HAVE_WINGET="
where winget >nul 2>&1
if not errorlevel 1 set "HAVE_WINGET=1"
if defined DRY_ASK set "HAVE_WINGET=1"
set "NIM_PROBLEM="
if defined MISSING_CC call :offer_cc
if defined MISSING_GIT call :offer_git
if defined MISSING_NIM call :offer_nim
if defined NIM_PROBLEM set "STEP_NO=3" & set "STEP_NAME=Nim %NIM_VERSION%" & set "PROBLEM=%NIM_PROBLEM%" & goto fail
if "%DRY_RUN%"=="1" goto offers_dry
if defined MISSING_CC goto stop_missing
if defined MISSING_GIT goto stop_missing
if defined MISSING_NIM goto stop_missing
goto tools_ok
:offers_dry
echo.
echo       would: carry on with the steps below only if every offer above is answered y
goto tools_ok

:stop_missing
echo.
echo ------------------------------------------------------------------------------
echo Studio cannot start yet: something it needs is still not on this computer.
echo Nothing you said no to was installed. To install it yourself, follow what is
echo listed below, then close this window and double-click Paraloop-Studio.bat again
echo (or double-click it again now and answer y).
echo ------------------------------------------------------------------------------
if defined MISSING_CC call :help_cc
if defined MISSING_GIT call :help_git
if defined MISSING_NIM call :help_nim
echo.
echo Already installed it and still see this message? Restart the computer once, so Windows
echo hands the new program to this window, and double-click again. Still stuck? Send the
echo captain a photo or a copy of this window.
call :log "stopped: missing cc=%MISSING_CC% git=%MISSING_GIT% nim=%MISSING_NIM%"
call :pause_window
exit /b 1

:tools_ok
if defined NIM_DIR set "PATH=%NIM_DIR%;%USERPROFILE%\.nimble\bin;%PATH%"
if "%DRY_RUN%"=="1" goto have_nimble
where nimble >nul 2>&1
if errorlevel 1 set "PROBLEM=Nim was found in %NIM_DIR% but nimble (its package tool, normally in the same folder) was not." & goto fail
:have_nimble

rem --- step 4: the game libraries ----------------------------------------------------------------

call :step "Fetching the game libraries (nimble install -d -y, then nimble setup)..." "game libraries"
call :deps_ready
if "%DEPS_READY%"=="1" goto deps_ok
if "%DRY_RUN%"=="1" goto deps_dry
call :note "The first time this takes a few minutes. Nothing is printed here while it works; it is working even when nothing moves."
call :log "$ nimble install -d -y"
call nimble install -d -y >>"%LOG%" 2>&1
if errorlevel 1 set "PROBLEM=nimble could not fetch the game libraries. Check that this computer is online, then run this again." & goto fail
call :log "$ nimble setup"
call nimble setup >>"%LOG%" 2>&1
if errorlevel 1 set "PROBLEM=nimble setup failed." & goto fail
call :deps_ready
if not "%DEPS_READY%"=="1" set "PROBLEM=The libraries were fetched but are not set up where the build expects them." & goto fail
call :ok "libraries ready."
goto deps_end
:deps_dry
call :would "run: nimble install -d -y   (downloads the libraries pinned in nimble.lock)"
call :would "run: nimble setup"
goto deps_end
:deps_ok
call :ok "the libraries are already set up."
:deps_end

rem --- step 5: build para ------------------------------------------------------------------------

call :step "Building para, the program behind Studio..." "build para"
if "%DRY_RUN%"=="1" goto build_dry
if not exist "%ROOT%\tmp" mkdir "%ROOT%\tmp"
call :note "This takes a few minutes the first time and is quicker after (only what changed is rebuilt). Nothing is printed here while it works; it is working even when nothing moves."
call :log "$ nim c --hints:off --outdir:tmp tools/para/para.nim"
call nim c --hints:off --outdir:tmp tools/para/para.nim >>"%LOG%" 2>&1
if errorlevel 1 set "PROBLEM=Building para failed. The log has the compiler's words." & goto fail
if not exist "tmp\para.exe" set "PROBLEM=The build finished but tmp\para.exe was not made." & goto fail
call :ok "built tmp\para.exe"
goto build_end
:build_dry
call :would "run: nim c --hints:off --outdir:tmp tools/para/para.nim"
:build_end

rem --- step 6: the producer's chat program: the startup checks the Studio page shows -------------

call :step "Checking the producer's chat program (claude or codex: installed, signed in, folder trusted)..." "claude or codex"
if "%DRY_RUN%"=="1" goto agent_dry
rem Read-only, like the page's checks: no model is asked anything and no login is read. Whatever it
rem answers, Studio still opens, so its exit code is not looked at.
call :log "$ tmp\para.exe studio --check"
tmp\para.exe studio --check
goto agent_end
:agent_dry
call :would "run: tmp\para.exe studio --check   (the startup checks the Studio page shows: installed, signed in, folder trusted; they never stop Studio from opening)"
:agent_end

rem --- step 7: Studio ----------------------------------------------------------------------------

call :step "Starting Studio..." "start Studio"
if "%DRY_RUN%"=="1" goto studio_dry
echo       Studio opens in your browser. Keep this window open while you use it;
echo       press Ctrl+C here (then Y if it asks) or close this window to stop Studio.
echo.
call :log "starting tmp\para.exe studio (its output is not logged: it holds a per-run key)"
tmp\para.exe studio
set "STATUS=%ERRORLEVEL%"
if "%STATUS%"=="0" goto studio_stopped
if "%STATUS%"=="-1073741510" goto studio_stopped
set "PROBLEM=Studio stopped with an error (exit code %STATUS%). Copy what Studio printed above into your message too."
goto fail
:studio_stopped
echo.
echo Studio stopped. Double-click Paraloop-Studio.bat again to start it.
call :pause_window
exit /b 0
:studio_dry
call :would "run: tmp\para.exe studio   (it prints a link and opens it in your default browser)"
echo.
echo Dry run finished: nothing was installed, built or opened.
exit /b 0

rem --- the stop with a block to send the captain -------------------------------------------------

:fail
echo.
echo ==============================================================================
echo Something went wrong. Please send the captain everything between these lines.
echo ------------------------------------------------------------------------------
echo Step:     %STEP_NO% of %STEPS%, %STEP_NAME%
echo Problem:  %PROBLEM%
echo Computer: %OSVER%, %ARCH%
if "%LOG%"=="NUL" goto fail_end
echo Log file: %LOG%   (attach this file too)
call :log_tail
:fail_end
echo ==============================================================================
call :log "FAILED at step %STEP_NO% (%STEP_NAME%): %PROBLEM%"
call :pause_window
exit /b 1

rem --- talking -----------------------------------------------------------------------------------

:step
set /a STEP_NO+=1
set "STEP_NAME=%~2"
echo.
echo [%STEP_NO%/%STEPS%] %~1
call :log "step %STEP_NO%: %~2"
exit /b 0

:ok
echo       ok: %~1
call :log "ok: %~1"
exit /b 0

:bad
echo       MISSING: %~1
call :log "missing: %~1"
exit /b 0

:note
echo       %~1
call :log "%~1"
exit /b 0

:would
echo       would: %~1
exit /b 0

:log
>>"%LOG%" echo %date% %time% %~1
exit /b 0

:ask
rem $1 = the question. Sets ANSWER=yes only for y or yes typed here; Enter, anything else and an
rem input that is closed (set /p then leaves REPLY empty) are all no.
set "ANSWER=no"
set "REPLY="
set /p "REPLY=      %~1 (y/n, Enter means no) "
setlocal EnableDelayedExpansion
set "RES=no"
if /i "!REPLY!"=="y" set "RES=yes"
if /i "!REPLY!"=="yes" set "RES=yes"
endlocal & set "ANSWER=%RES%"
call :log "asked: %~1 - answer: %ANSWER%"
if not "%ANSWER%"=="yes" echo       Okay, nothing was installed.
exit /b 0

:pause_window
if not "%PARALOOP_LAUNCHER_PAUSE%"=="1" exit /b 0
if "%DRY_RUN%"=="1" exit /b 0
echo.
echo Press any key to close this window.
pause >nul
exit /b 0

:log_tail
if not exist "%LOG%" exit /b 0
set "LINES=0"
for /f %%n in ('find /c /v "" ^< "%LOG%"') do set "LINES=%%n"
if "%LINES%"=="0" exit /b 0
echo Last lines of the log:
set "FOROPT=usebackq delims="
set /a SKIP=LINES-12
if %SKIP% gtr 0 set "FOROPT=usebackq skip=%SKIP% delims="
for /f "%FOROPT%" %%L in ("%LOG%") do echo   ^| %%L
exit /b 0

rem --- offering to install (each says what, from where, where to and how big, then asks) ---------

:offer_cc
echo.
echo A C compiler is missing (the game is turned into a program by one).
if not defined HAVE_WINGET goto no_winget
echo   I can install one with winget, the app installer that comes with Windows:
echo     What:    WinLibs GCC (MinGW-w64), the newest version winget lists
echo     From:    winget's own catalog; the files come from github.com/brechtsanders/winlibs_mingw
echo     Command: %CC_WINGET%
echo     Where:   your user folder (%LOCALAPPDATA%\Microsoft\WinGet\Packages), no administrator password
echo     Size:    winget shows it as it downloads (a few hundred MB)
echo     PATH:    winget adds the compiler to your user PATH itself, as it does for every program
echo   winget may first ask you to agree to its catalog's terms; answer Y there if you agree.
if "%DRY_RUN%"=="1" if not defined DRY_ASK goto offer_dry
call :ask "Install the C compiler now?"
if not "%ANSWER%"=="yes" exit /b 0
if defined DRY_ASK call :would "install the C compiler with: %CC_WINGET%" & exit /b 0
call :log "$ %CC_WINGET%"
%CC_WINGET%
if errorlevel 1 call :note "winget did not finish (exit code %ERRORLEVEL%)." & exit /b 0
set "HAVE_CC="
call :look_cc
if not defined HAVE_CC call :note "winget finished, but this window cannot see the compiler yet." & exit /b 0
call :ok "found a C compiler: %HAVE_CC%"
set "MISSING_CC="
exit /b 0

:offer_git
echo.
echo git is missing (it keeps your save points).
if not defined HAVE_WINGET goto no_winget
echo   I can install it with winget, the app installer that comes with Windows:
echo     What:    Git for Windows, the newest version winget lists
echo     From:    winget's own catalog; the installer comes from github.com/git-for-windows
echo     Command: %GIT_WINGET%
echo     Where:   your user folder (%LOCALAPPDATA%\Programs\Git), no administrator password
echo     Size:    winget shows it as it downloads
echo     PATH:    Git's installer adds git to your user PATH itself
echo   winget may first ask you to agree to its catalog's terms; answer Y there if you agree.
if "%DRY_RUN%"=="1" if not defined DRY_ASK goto offer_dry
call :ask "Install git now?"
if not "%ANSWER%"=="yes" exit /b 0
if defined DRY_ASK call :would "install git with: %GIT_WINGET%" & exit /b 0
call :log "$ %GIT_WINGET%"
%GIT_WINGET%
if errorlevel 1 call :note "winget did not finish (exit code %ERRORLEVEL%)." & exit /b 0
set "HAVE_GIT="
call :look_git
if not defined HAVE_GIT call :note "winget finished, but this window cannot see git yet." & exit /b 0
call :ok "git is installed."
set "MISSING_GIT="
call :git_copy_note
exit /b 0

:offer_nim
echo.
echo Nim %NIM_VERSION% is missing (the language the games are written in).
if /i not "%ARCH%"=="AMD64" goto nim_no_offer
echo   I can download the official release and set it up:
echo     What:    Nim %NIM_VERSION% for 64-bit Windows (nimble, its package tool, comes with it)
echo     From:    %NIM_ZIP_URL%
echo     Check:   its SHA-256 must match %NIM_ZIP_URL%.sha256
echo              and the value written in this launcher
echo     Where:   %NIM_HOME%
echo              (your user folder: no administrator password, nothing else on this PC changes)
echo     Size:    %NIM_ZIP_SIZE%
echo     PATH:    added inside this window only; your Windows settings are not changed
echo   It downloads with curl.exe and unpacks with tar.exe, both part of Windows 10 and 11.
if "%DRY_RUN%"=="1" if not defined DRY_ASK goto offer_nim_dry
call :ask "Download and install Nim %NIM_VERSION% now?"
if not "%ANSWER%"=="yes" exit /b 0
if defined DRY_ASK call :would "install Nim %NIM_VERSION%: download %NIM_ZIP_URL%, check its SHA-256, unpack it into %NIM_HOME%" & exit /b 0
call :install_nim
exit /b 0
:offer_nim_dry
call :would "ask you: Download and install Nim %NIM_VERSION% now? (y/n, Enter means no)"
call :would "on n or Enter, stop with nothing installed"
call :would "on y, download %NIM_ZIP_URL% and its .sha256 with curl.exe"
call :would "check its SHA-256 against nim-lang.org's and the one written in this launcher, and refuse to use it if either differs"
call :would "unpack it with tar.exe into %NIM_HOME%"
exit /b 0
:nim_no_offer
echo   This PC is %ARCH%; the official Nim download for Windows is for 64-bit Intel and AMD
echo   PCs (AMD64), so I do not offer to install it here.
exit /b 0

:offer_dry
call :would "ask you: Install it now? (y/n, Enter means no)"
call :would "on y, run exactly the command above"
call :would "on n or Enter, stop with nothing installed"
exit /b 0

:no_winget
echo   winget (the app installer that comes with Windows 10 and 11) was not found, so I
echo   cannot offer to install it; the steps to do it by hand are listed below.
exit /b 0

:install_nim
rem Downloads, checks and unpacks the Nim zip. On a problem it sets NIM_PROBLEM (the caller stops
rem with it) and leaves nothing installed.
where curl.exe >nul 2>&1
if errorlevel 1 set "NIM_PROBLEM=curl.exe, part of Windows 10 and 11, was not found, so Nim could not be downloaded. Install Nim by hand: see Nim in docs\windows.md." & exit /b 0
where tar.exe >nul 2>&1
if errorlevel 1 set "NIM_PROBLEM=tar.exe, part of Windows 10 and 11, was not found, so Nim could not be unpacked. Install Nim by hand: see Nim in docs\windows.md." & exit /b 0
if not exist "%USERPROFILE%\.paraloop" mkdir "%USERPROFILE%\.paraloop"
set "WORK=%USERPROFILE%\.paraloop\download-%RANDOM%%RANDOM%"
mkdir "%WORK%"
call :note "Downloading %NIM_ZIP% (%NIM_ZIP_SIZE%)..."
call :log "$ curl.exe %NIM_ZIP_URL%"
curl.exe -fL --proto "=https" --tlsv1.2 --retry 2 -o "%WORK%\%NIM_ZIP%" "%NIM_ZIP_URL%"
if errorlevel 1 set "NIM_PROBLEM=The Nim download failed. Check that this computer is online, then run this again." & goto install_nim_end
curl.exe -fsSL --proto "=https" --tlsv1.2 --retry 2 -o "%WORK%\%NIM_ZIP%.sha256" "%NIM_ZIP_URL%.sha256"
if errorlevel 1 set "NIM_PROBLEM=The Nim checksum download failed. Check that this computer is online, then run this again." & goto install_nim_end
rem The first word of the .sha256 file, and the second line of certutil's answer (the first says
rem which file; older Windows puts spaces between the bytes, removed here).
set "PUBLISHED="
for /f "usebackq tokens=1" %%H in ("%WORK%\%NIM_ZIP%.sha256") do if not defined PUBLISHED set "PUBLISHED=%%H"
if not defined PUBLISHED set "PUBLISHED=none"
set "ACTUAL="
for /f "skip=1 delims=" %%H in ('certutil -hashfile "%WORK%\%NIM_ZIP%" SHA256') do if not defined ACTUAL set "ACTUAL=%%H"
if not defined ACTUAL set "ACTUAL=none"
set "ACTUAL=%ACTUAL: =%"
call :log "sha256 actual=%ACTUAL% published=%PUBLISHED% pinned=%NIM_ZIP_SHA256%"
if /i not "%ACTUAL%"=="%NIM_ZIP_SHA256%" goto nim_bad_sum
if /i not "%ACTUAL%"=="%PUBLISHED%" goto nim_bad_sum
call :ok "checksum matches (%ACTUAL%)."
call :log "$ tar.exe -xf %NIM_ZIP%"
tar.exe -xf "%WORK%\%NIM_ZIP%" -C "%WORK%" >>"%LOG%" 2>&1
if errorlevel 1 set "NIM_PROBLEM=The downloaded Nim could not be unpacked." & goto install_nim_end
if not exist "%WORK%\nim-%NIM_VERSION%\bin\nim.exe" set "NIM_PROBLEM=The downloaded Nim did not hold nim-%NIM_VERSION%\bin\nim.exe." & goto install_nim_end
if exist "%NIM_HOME%" call :move_aside
move "%WORK%\nim-%NIM_VERSION%" "%NIM_HOME%" >nul
if errorlevel 1 set "NIM_PROBLEM=Nim could not be moved into %NIM_HOME%." & goto install_nim_end
set "NIM_DIR="
call :check_nim "%NIM_HOME%\bin\nim.exe"
if not defined NIM_DIR set "NIM_PROBLEM=Nim was unpacked into %NIM_HOME% but would not run. The Nim download may not work on this PC." & goto install_nim_end
call :ok "Nim %NIM_VERSION% installed in %NIM_HOME%"
call :note "Nothing was added to your Windows settings: this launcher finds Nim there itself every time."
set "MISSING_NIM="
:install_nim_end
if exist "%WORK%" rmdir /s /q "%WORK%"
exit /b 0
:nim_bad_sum
set "NIM_PROBLEM=The downloaded Nim does not match its published checksum, so it was NOT used and nothing was installed. Computed: %ACTUAL%. nim-lang.org publishes: %PUBLISHED%. This launcher expects: %NIM_ZIP_SHA256%."
goto install_nim_end

:move_aside
set "ASIDE=%NIM_HOME%.old-%RANDOM%%RANDOM%"
move "%NIM_HOME%" "%ASIDE%" >nul
call :note "An older folder was in the way; it was moved to %ASIDE%"
exit /b 0

rem --- what to install by hand, for the stop above -----------------------------------------------

:help_cc
echo.
echo A C compiler (the game is turned into a program by one). Not found.
echo   In a normal terminal run:   %CC_WINGET%
echo   Any MinGW-w64 gcc works; if you already have one, make sure its bin folder is on PATH.
exit /b 0

:help_git
echo.
echo git (keeps your save points). Not found.
echo   Download Git for Windows from %GIT_URL%
echo   or in a normal terminal run:   %GIT_WINGET%
echo   Say yes to the defaults.
exit /b 0

:help_nim
echo.
echo Nim %NIM_VERSION% (the language the games are written in). Not found.
echo   Download %NIM_ZIP_URL%
echo   Unzip it somewhere permanent such as C:\nim, then run finish.exe inside the unzipped folder
echo   and let it add the Nim folders to your PATH. It does not need to install a compiler;
echo   you installed one above. It must be exactly %NIM_VERSION%; another Nim is left alone.
exit /b 0

rem --- finding things (looking only; extending PATH only inside this window) ---------------------

:git_copy_note
git -C "%ROOT%" rev-parse --git-dir >nul 2>&1
if errorlevel 1 call :note "Note: this folder was not copied with git (for example, it came from a zip file), so save points will not work until the captain gives you a git copy. Studio still starts."
exit /b 0

:look_cc
where gcc >nul 2>&1
if not errorlevel 1 set "HAVE_CC=gcc" & exit /b 0
where cc >nul 2>&1
if not errorlevel 1 set "HAVE_CC=cc" & exit /b 0
where clang >nul 2>&1
if not errorlevel 1 set "HAVE_CC=clang" & exit /b 0
for %%D in ("C:\mingw64\bin" "C:\msys64\ucrt64\bin" "C:\msys64\mingw64\bin" "%ProgramFiles%\mingw-w64\bin") do if not defined HAVE_CC if exist "%%~D\gcc.exe" call :use_cc_dir "%%~D"
for /d %%P in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\BrechtSanders.WinLibs*") do if not defined HAVE_CC if exist "%%~P\mingw64\bin\gcc.exe" call :use_cc_dir "%%~P\mingw64\bin"
exit /b 0

:use_cc_dir
set "HAVE_CC=gcc in %~1 (not on PATH; used for this window only)"
set "PATH=%~1;%PATH%"
exit /b 0

:look_git
where git >nul 2>&1
if not errorlevel 1 set "HAVE_GIT=1" & exit /b 0
if exist "%ProgramFiles%\Git\cmd\git.exe" call :use_git_dir "%ProgramFiles%\Git\cmd"
if not defined HAVE_GIT if exist "%LOCALAPPDATA%\Programs\Git\cmd\git.exe" call :use_git_dir "%LOCALAPPDATA%\Programs\Git\cmd"
exit /b 0

:use_git_dir
set "HAVE_GIT=1"
set "PATH=%~1;%PATH%"
exit /b 0

:look_nim
for /f "delims=" %%P in ('where nim 2^>nul') do if not defined NIM_DIR call :check_nim "%%P"
for %%D in ("%NIM_HOME%\bin" "C:\nim\bin" "C:\nim\nim-%NIM_VERSION%\bin" "C:\nim-%NIM_VERSION%\bin" "%USERPROFILE%\nim-%NIM_VERSION%\bin" "%USERPROFILE%\.nimble\bin" "%USERPROFILE%\.choosenim\toolchains\nim-%NIM_VERSION%\bin" "%ProgramFiles%\nim\bin" "%LOCALAPPDATA%\Programs\nim\bin") do if not defined NIM_DIR if exist "%%~D\nim.exe" call :check_nim "%%~D\nim.exe"
exit /b 0

:check_nim
rem $1 = path to a nim.exe: sets NIM_DIR when it is Nim %NIM_VERSION%, else notes it in OTHER_NIM
set "NIM_VER="
set "VERFILE=%TEMP%\paraloop-nim-version-%RANDOM%.txt"
"%~1" --version >"%VERFILE%" 2>nul
for /f "usebackq tokens=1-4" %%a in ("%VERFILE%") do if "%%c"=="Version" set "NIM_VER=%%d"
del "%VERFILE%" >nul 2>&1
if "%NIM_VER%"=="%NIM_VERSION%" for %%I in ("%~1") do set "NIM_DIR=%%~dpI"
if defined NIM_VER if not defined OTHER_NIM set "OTHER_NIM=%NIM_VER% at %~1"
exit /b 0

:deps_ready
rem sets DEPS_READY=1 when nimble.paths exists, config.nims uses it, no file it comes from
rem (nimble.lock, paraloop.nimble) is strictly newer, and every --path folder in it still exists
set "DEPS_READY="
if not exist "nimble.paths" exit /b 0
findstr /c:"nimble.paths" config.nims >nul 2>&1
if errorlevel 1 exit /b 0
set "STALE="
call :newer_than_paths "nimble.lock"
call :newer_than_paths "paraloop.nimble"
if defined STALE exit /b 0
for /f "usebackq tokens=1* delims=:" %%A in ("nimble.paths") do if "%%A"=="--path" call :path_gone %%B
if defined STALE exit /b 0
set "DEPS_READY=1"
exit /b 0

:newer_than_paths
rem $1 = a file; sets STALE=1 when it exists and is strictly newer than nimble.paths
if not exist "%~1" exit /b 0
xcopy /L /D /Y "%~1" "nimble.paths" 2>nul | findstr /i /x /c:"%~1" >nul
if not errorlevel 1 set "STALE=1"
exit /b 0

:path_gone
rem $1 = a folder from a --path line of nimble.paths: sets STALE=1 when it no longer exists
if not exist "%~1\" set "STALE=1"
exit /b 0
