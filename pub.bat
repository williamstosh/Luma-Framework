@echo off
rem ============================================================
rem  Install the PUBLISHING build of the Mafia: DE Luma mod.
rem
rem  This is the shipping configuration: every development
rem  diagnostic is compiled out, so what is left is the settings
rem  described in REPORT.md section 3.
rem
rem  Whatever is installed at the time is copied to
rem  "Luma-Mafia Definitive Edition.addon.previous" first, so
rem  pub.bat / dev.bat can be flipped back and forth without
rem  leaving a trail of timestamped backups behind.
rem
rem  ASCII only: cmd.exe reads .bat files with the OEM codepage.
rem  No "if (...)" blocks: use goto instead.
rem ============================================================
setlocal

set "GAME=F:\SteamLibrary\steamapps\common\Mafia Definitive Edition"
set "ADDON=%GAME%\Luma-Mafia Definitive Edition.addon"
set "BAK=%GAME%\Luma-Mafia Definitive Edition.addon.previous"
set "SRC=%~dp0Binaries\x64-Publishing-Release\Luma-Mafia Definitive Edition.addon"

if not exist "%GAME%" goto nogame
if not exist "%SRC%" goto nosrc

tasklist /FI "IMAGENAME eq mafiadefinitiveedition.exe" 2>NUL | find /I "mafiadefinitiveedition.exe" >NUL
if not errorlevel 1 goto running

if not exist "%ADDON%" goto docopy
copy /Y "%ADDON%" "%BAK%" >NUL

:docopy
copy /Y "%SRC%" "%ADDON%" >NUL
if errorlevel 1 goto copyfail

echo Installed: PUBLISHING build
for %%F in ("%ADDON%") do echo   size  %%~zF bytes
for %%F in ("%ADDON%") do echo   time  %%~tF
echo.
echo No development diagnostics in this build.
endlocal & exit /b 0

:running
echo [X] mafiadefinitiveedition.exe is still running - close the game first.
endlocal & exit /b 1

:nosrc
echo [X] Publishing build not found:
echo     %SRC%
echo     Build it first:  build-mafiade.bat Publishing-Release
endlocal & exit /b 1

:nogame
echo [X] Game folder not found:
echo     %GAME%
endlocal & exit /b 1

:copyfail
echo [X] Copy failed - the add-on is probably still locked by the game.
endlocal & exit /b 1
