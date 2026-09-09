$ErrorActionPreference = 'SilentlyContinue'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Desk HUD.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Desk HUD.lnk'
Remove-Item -LiteralPath $startupLink -Force
Remove-Item -LiteralPath $desktopLink -Force
Write-Host 'Shortcuts removed. Close the HUD, then delete %LOCALAPPDATA%\CodexDeskHUD if you also want to remove settings.'
