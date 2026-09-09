@echo off
cd /d "%~dp0"
start "" /b wscript.exe "%~dp0Start-CodexDeskHUD.vbs"
exit /b 0
