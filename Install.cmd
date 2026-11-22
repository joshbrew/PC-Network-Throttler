@echo off
setlocal
title Network Throttler Setup
set "ntPs=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "ntChoice=%SystemRoot%\System32\choice.exe"

:menu
echo.
echo Network Throttler Setup
echo -----------------------
"%SystemRoot%\System32\reg.exe" query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PCUploadLimit" /v InstallLocation >nul 2>&1
if errorlevel 1 goto fresh
echo  1. Update or add features ^(keep saved limits^)
echo  2. Clean reinstall ^(uninstall, then start with default settings^)
echo  3. Uninstall ^(remove the app and its saved limits^)
echo  0. Exit
echo.
"%ntChoice%" /C 1230 /N /M "Choose [1/2/3/0]: "
if errorlevel 255 goto failed
if errorlevel 4 goto cancel
if errorlevel 3 goto uninstall
if errorlevel 2 goto reinstall
if errorlevel 1 goto install
goto cancel

:fresh
echo  1. Install
echo  0. Exit
echo.
"%ntChoice%" /C 10 /N /M "Choose [1/0]: "
if errorlevel 255 goto failed
if errorlevel 2 goto cancel
if errorlevel 1 goto install
goto cancel

:install
set "ntMode=Install"
goto shortcut

:reinstall
echo.
"%ntChoice%" /C YN /N /M "Remove saved limits and app rules and reinstall? [Y/N]: "
if errorlevel 255 goto failed
if errorlevel 2 goto menu
if not errorlevel 1 goto cancel
set "ntMode=Reinstall"
goto shortcut

:uninstall
echo.
"%ntChoice%" /C YN /N /M "Uninstall Network Throttler and remove its saved limits? [Y/N]: "
if errorlevel 255 goto failed
if errorlevel 2 goto menu
if not errorlevel 1 goto cancel
echo.
echo Uninstalling Network Throttler. Windows may ask for administrator approval.
"%ntPs%" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0scripts\Install.ps1" -Mode Uninstall %*
if errorlevel 1 goto failed
echo.
echo Uninstall complete.
pause
exit /b 0

:shortcut
echo.
set "ntShortcut=Create"
"%ntChoice%" /C YN /N /M "Create or keep a desktop shortcut? [Y/N]: "
if errorlevel 255 goto failed
if not errorlevel 1 goto cancel
if errorlevel 2 set "ntShortcut=Remove"

set "ntPacketSupport="
for %%A in (%*) do if /I "%%~A"=="-WithPacketSupport" goto setup
if /I not "%PROCESSOR_ARCHITECTURE%"=="AMD64" goto setup
if /I "%ntMode%"=="Reinstall" goto packetSupport
"%SystemRoot%\System32\sc.exe" query PCUploadLimitShaper >nul 2>&1
if not errorlevel 1 goto setup

:packetSupport
echo.
echo Download and per-app limits use a signed Windows packet driver.
"%ntChoice%" /C YN /N /M "Include download and per-app limits? [Y/N]: "
if errorlevel 255 goto failed
if not errorlevel 1 goto cancel
if not errorlevel 2 set "ntPacketSupport=-WithPacketSupport"

:setup
echo.
echo Running setup. Windows may ask for administrator approval.
"%ntPs%" -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0scripts\Install.ps1" -Mode %ntMode% -DesktopShortcut %ntShortcut% %ntPacketSupport% %*
if errorlevel 1 goto failed
echo.
echo Setup complete. You can also open the app with Run.cmd.
"%ntChoice%" /C YN /N /M "Open Network Throttler when setup closes? [Y/N]: "
if errorlevel 255 goto failed
if errorlevel 2 exit /b 0
if not errorlevel 1 goto cancel
call "%~dp0Run.cmd"
exit /b %errorlevel%

:failed
echo.
echo Setup could not complete. See the message above.
pause
exit /b 1

:cancel
exit /b 0
