@echo off
setlocal
title WinRegister - Install

echo.
echo  Installing WinRegister...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinRegister.ps1" -Install
set EXITCODE=%ERRORLEVEL%

echo.
if %EXITCODE% EQU 0 (
    echo  Done. Right-click any .exe, shortcut, or folder, then
    echo  'Show more options' -^> 'Register with Windows'.
    echo.
    echo  On Windows 11 you may need to click 'Show more options'
    echo  or use Shift+Right-click to see the entries.
) else (
    echo  Install failed. See log at:
    echo    %LOCALAPPDATA%\WinRegister\winregister.log
)
echo.
pause
endlocal
exit /b %EXITCODE%
