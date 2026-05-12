@echo off
setlocal
title WinRegister - Uninstall

echo.
echo  WinRegister Uninstall
echo  ---------------------
echo.
echo   [1] Remove right-click menu entries only (keep registered programs)
echo   [2] Remove EVERYTHING (menu entries + every registered program)
echo   [3] Cancel
echo.

set /p CHOICE="  Choose [1/2/3]: "

if "%CHOICE%"=="1" goto SOFT
if "%CHOICE%"=="2" goto PURGE
goto CANCEL

:SOFT
echo.
echo  Removing context menu entries...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinRegister.ps1" -Uninstall
goto END

:PURGE
echo.
echo  Removing context menu entries and ALL registrations...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinRegister.ps1" -Uninstall -Purge
goto END

:CANCEL
echo.
echo  Cancelled.
goto END

:END
echo.
pause
endlocal
