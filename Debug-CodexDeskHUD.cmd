@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo Codex Desk HUD debug mode
echo ============================================================
echo This window is expected to stay open in debug mode.
echo Worker log: %LOCALAPPDATA%\CodexDeskHUD\worker.log
echo.
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexDeskHUD.ps1"
echo.
echo HUD exited. Last worker log entries:
powershell.exe -NoProfile -Command "$p=Join-Path $env:LOCALAPPDATA 'CodexDeskHUD\worker.log'; if(Test-Path $p){Get-Content $p -Tail 80}else{'worker.log does not exist'}"
echo.
pause
