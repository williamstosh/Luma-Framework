@echo off
rem ============================================================
rem  Luma Graphics Analyzer - local build script
rem  Same pattern as opti-build\build.bat: located via %~dp0,
rem  the whole folder can be moved anywhere.
rem
rem  NOTE: keep this file ASCII-only. cmd.exe reads .bat using the
rem  OEM codepage (GBK here), so any non-ASCII byte garbles the
rem  script and breaks every command.
rem  NOTE: no "if (...)" blocks - the "(x86)" in the MSBuild path
rem  contains a ")" that terminates the block early. Use goto.
rem ============================================================
setlocal

rem --- MUST clear proxy vars first, otherwise MSBuild fails with MSB6001 ---
set "http_proxy="
set "https_proxy="
set "HTTP_PROXY="
set "HTTPS_PROXY="

set "MSBUILD=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
if not exist "%MSBUILD%" goto nomsbuild

set "PROJ=%~dp0Source\Graphics Analyzer\Graphics Analyzer.vcxproj"

echo === Building Graphics Analyzer - Development-Release x64 ===
echo Project: %PROJ%
echo Output : %~dp0Binaries\x64-Development-Release\
echo.

"%MSBUILD%" "%PROJ%" /p:Configuration=Development-Release /p:Platform=x64 /p:SolutionDir=%~dp0 /p:SolutionName=Luma /m /nologo /v:m
set "RC=%ERRORLEVEL%"
echo.
echo BUILD_EXIT=%RC%
if not "%RC%"=="0" goto done

echo.
echo === Artifacts ===
dir /b "%~dp0Binaries\x64-Development-Release\*.addon"

:done
endlocal & exit /b %RC%

:nomsbuild
echo [X] MSBuild not found: %MSBUILD%
endlocal & exit /b 1
