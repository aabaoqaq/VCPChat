@echo off
setlocal
chcp 65001 >nul

cd /d "%~dp0"

set "UPDATE_SCRIPT=%~dp0tools\update\VCPChatUpdate.ps1"
if not exist "%UPDATE_SCRIPT%" (
    echo [ERROR] Update script not found:
    echo         %UPDATE_SCRIPT%
    pause
    exit /b 1
)

echo ======================================================
echo               VCPChat Update Launcher
echo ======================================================
echo.

pwsh -NoProfile -ExecutionPolicy Bypass -File "%UPDATE_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo [DONE] Update script exited with code %EXIT_CODE%
) else (
    echo [DONE] Update script finished
)

pause
exit /b %EXIT_CODE%
