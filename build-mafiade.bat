@echo off
rem ============================================================
rem  Luma mod for Mafia: Definitive Edition - local build script
rem  Same pattern as build.bat / opti-build\build.bat: located via
rem  %~dp0, the whole folder can be moved anywhere.
rem
rem  ASCII only (cmd.exe reads .bat with the OEM codepage).
rem  No "if (...)" blocks (the "(x86)" in the MSBuild path would
rem  terminate the block early) - use goto.
rem ============================================================
setlocal

rem --- MUST clear proxy vars first, otherwise MSBuild fails with MSB6001 ---
set "http_proxy="
set "https_proxy="
set "HTTP_PROXY="
set "HTTPS_PROXY="

set "MSBUILD=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
if not exist "%MSBUILD%" goto nomsbuild

set "PROJ=%~dp0Source\Games\Mafia Definitive Edition\Mafia Definitive Edition.vcxproj"
set "CONFIG=%~1"
if "%CONFIG%"=="" set "CONFIG=Development-Release"

echo === Building Mafia Definitive Edition Luma mod - %CONFIG% x64 ===
echo Project: %PROJ%
echo Output : %~dp0Binaries\x64-%CONFIG%\
echo.

rem --- The project file targets v145 (upstream standard, VS 2026). This machine has only VS 2022
rem     BuildTools (v143), so the toolset is overridden on the command line instead of editing the
rem     .vcxproj - a machine specific toolset must not travel into the upstream pull request.
"%MSBUILD%" "%PROJ%" /p:Configuration=%CONFIG% /p:Platform=x64 /p:SolutionDir=%~dp0 /p:SolutionName=Luma /p:PlatformToolset=v143 /m /nologo /v:m
set "RC=%ERRORLEVEL%"
echo.
echo BUILD_EXIT=%RC%
if not "%RC%"=="0" goto done

echo.
echo === Artifacts ===
dir /b "%~dp0Binaries\x64-%CONFIG%\*.addon"

:done
endlocal & exit /b %RC%

:nomsbuild
echo [X] MSBuild not found: %MSBUILD%
endlocal & exit /b 1
