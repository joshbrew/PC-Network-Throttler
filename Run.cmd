@echo off
setlocal
title Network Throttler
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0scripts\Run.ps1"
if errorlevel 3 goto failed
if errorlevel 2 goto setup
if errorlevel 1 goto failed
exit /b 0

:setup
echo Starting Network Throttler setup.
call "%~dp0Install.cmd"
exit /b %errorlevel%

:failed
pause
exit /b 1
