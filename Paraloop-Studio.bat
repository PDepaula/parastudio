@echo off
rem Double-click this file on Windows to start Para Studio. The steps, and what to do if Windows
rem warns about this file, are in docs/windows.md; the work is done by tools\launcher\launch.bat.
rem It installs nothing: if something is missing it says what to install and from where, and stops.
setlocal
cd /d "%~dp0"
if not exist "tools\launcher\launch.bat" goto not_unpacked
set "PARALOOP_LAUNCHER_PAUSE=1"
call "tools\launcher\launch.bat" %*
exit /b %ERRORLEVEL%

:not_unpacked
echo.
echo I cannot find tools\launcher\launch.bat next to this file.
echo If you opened this file from inside a zip file, close this window, right-click the
echo zip file, choose Extract All, and double-click Paraloop-Studio.bat in the new folder.
echo Otherwise the parastudio folder is incomplete; ask the captain for a fresh copy.
echo.
echo Press any key to close this window.
pause >nul
exit /b 1
