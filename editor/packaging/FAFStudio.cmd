@echo off
rem FAF Studio launcher: see launcher\launch.ps1 (finds the FAForever data, starts the editor).
rem Optional arguments are handed to the engine, for example:  FAFStudio.cmd /map my_map
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\launch.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\launch.ps1" %*
)
exit /b %errorlevel%
