@echo off
rem Para Studio launcher for Windows: checks what Studio needs (a C compiler, git, Nim), builds
rem `para` and starts `tmp\para.exe studio`, which opens the browser itself. Run through
rem Paraloop-Studio.bat (double-click); see docs/windows.md. It mirrors tools/launcher/launch.sh
rem (macOS and Linux), with two differences: that one offers to install Nim after asking and
rem checks for the producer's chat program; this one never installs anything and leaves the chat
rem program to Studio. When something is missing it says what to install and from where, and
rem stops.
rem
rem   launch.bat [--dry-run] [--help]
rem
rem --dry-run runs the same checks (they only look) and says what each later step WOULD do; it
rem builds nothing, fetches nothing and opens nothing. Test hook, read only in a dry run:
rem PARALOOP_LAUNCHER_FAKE_MISSING=cc,git,nim pretends those are not installed.
rem
rem What it never does: install anything, change PATH or any setting of the computer (PATH is only
rem extended inside this window), or send anything anywhere except nimble's package fetch and git.
rem The log (tmp\launcher.log) holds only what the steps printed; Studio's own output, which
rem carries its per-run key, is never written to it.
rem
rem Plain batch, ASCII only, CRLF line endings (see .gitattributes). Written without ( ) blocks
rem and without delayed expansion on purpose: a PATH containing "Program Files (x86)" breaks the
rem first, and a folder name containing ! breaks the second. Text that is echoed must not contain
rem the characters ampersand, pipe, less-than, greater-than, caret or percent.

setlocal EnableExtensions DisableDelayedExpansion

set "NIM_VERSION=2.2.10"
set "NIM_ZIP_URL=https://nim-lang.org/download/nim-2.2.10_x64.zip"
set "GIT_URL=https://git-scm.com/download/win"
set "STEPS=6"
set "STEP_NO=0"
set "STEP_NAME=starting"
set "DRY_RUN=0"

for %%I in ("%~dp0..\..") do set "ROOT=%%~fI"
cd /d "%ROOT%"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--dry-run" set "DRY_RUN=1" & shift & goto parse_args
if /i "%~1"=="--help" goto help
if /i "%~1"=="-h" goto help
if "%~1"=="/?" goto help
>&2 echo Unknown option: %~1 (try --help)
exit /b 2

:help
echo Para Studio launcher for Windows
echo   launch.bat [--dry-run]
echo   --dry-run  check what is installed and say what each step would do; build and open nothing
echo See docs/windows.md.
exit /b 0

:args_done
if "%DRY_RUN%"=="1" set "LOG=NUL"
if not "%DRY_RUN%"=="1" set "LOG=%ROOT%\tmp\launcher.log"
set "FAKE=,"
if "%DRY_RUN%"=="1" set "FAKE=,%PARALOOP_LAUNCHER_FAKE_MISSING%,"

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
git -C "%ROOT%" rev-parse --git-dir >nul 2>&1
if errorlevel 1 call :note "Note: this folder was not copied with git (for example, it came from a zip file), so save points will not work until the captain gives you a git copy. Studio still starts."
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
set "PATH=%NIM_DIR%;%USERPROFILE%\.nimble\bin;%PATH%"
goto nim_end
:nim_missing
if defined OTHER_NIM call :note "Found a different Nim (%OTHER_NIM%). Paraloop needs exactly %NIM_VERSION%; the other one is left alone."
set "MISSING_NIM=1"
call :bad "Nim %NIM_VERSION% was not found."
:nim_end

if defined MISSING_CC goto stop_missing
if defined MISSING_GIT goto stop_missing
if defined MISSING_NIM goto stop_missing
goto tools_ok

:stop_missing
echo.
echo ------------------------------------------------------------------------------
echo Studio cannot start yet: something it needs is not on this computer.
echo Nothing was installed or changed; this launcher never installs anything itself.
echo Install what is listed below, then close this window and double-click
echo Paraloop-Studio.bat again.
echo ------------------------------------------------------------------------------
if defined MISSING_CC call :help_cc
if defined MISSING_GIT call :help_git
if defined MISSING_NIM call :help_nim
echo.
echo Already installed it and still see this message? Restart the computer once, so Windows
echo hands the new program to this window, and double-click again. Still stuck? Send the
echo captain a photo or a copy of this window.
call :log "stopped: missing cc=%MISSING_CC% git=%MISSING_GIT% nim=%MISSING_NIM%"
if "%DRY_RUN%"=="1" echo.
if "%DRY_RUN%"=="1" echo Dry run finished: something is missing, so a real run would stop here. Nothing was installed, built or opened.
call :pause_window
exit /b 1

:tools_ok
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

rem --- step 6: Studio ----------------------------------------------------------------------------

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

rem --- what to install, for the stop above -------------------------------------------------------

:help_cc
echo.
echo A C compiler (the game is turned into a program by one). Not found.
echo   In a normal terminal run:   winget install --id BrechtSanders.WinLibs.POSIX.UCRT -e
echo   Any MinGW-w64 gcc works; if you already have one, make sure its bin folder is on PATH.
exit /b 0

:help_git
echo.
echo git (keeps your save points). Not found.
echo   Download Git for Windows from %GIT_URL%
echo   or in a normal terminal run:   winget install --id Git.Git -e
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
for %%D in ("C:\nim\bin" "C:\nim\nim-%NIM_VERSION%\bin" "C:\nim-%NIM_VERSION%\bin" "%USERPROFILE%\nim-%NIM_VERSION%\bin" "%USERPROFILE%\.nimble\bin" "%USERPROFILE%\.choosenim\toolchains\nim-%NIM_VERSION%\bin" "%ProgramFiles%\nim\bin" "%LOCALAPPDATA%\Programs\nim\bin") do if not defined NIM_DIR if exist "%%~D\nim.exe" call :check_nim "%%~D\nim.exe"
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
