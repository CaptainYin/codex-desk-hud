param(
    [switch]$AutoStart,
    [switch]$DesktopShortcut
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dst = Join-Path $env:LOCALAPPDATA 'CodexDeskHUD'
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$preserveConfig = Test-Path -LiteralPath (Join-Path $dst 'config.json')
Get-ChildItem -LiteralPath $src -File | ForEach-Object {
    if (-not ($preserveConfig -and $_.Name -eq 'config.json')) {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dst $_.Name) -Force
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $dst 'config.json'))) {
    Copy-Item -LiteralPath (Join-Path $dst 'config.example.json') -Destination (Join-Path $dst 'config.json')
}

try {
    & (Join-Path $dst 'Build-Launcher.ps1') -OutputDirectory $dst
} catch {
    Write-Warning ('Native launcher build failed; using hidden VBS launcher. ' + $_.Exception.Message)
}

$nativeLauncher = Join-Path $dst 'CodexDeskHUD.exe'
$launcher = if (Test-Path -LiteralPath $nativeLauncher) { $nativeLauncher } else { Join-Path $dst 'Start-CodexDeskHUD.vbs' }
$shell = New-Object -ComObject WScript.Shell

if ($AutoStart) {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnk = $shell.CreateShortcut((Join-Path $startup 'Codex Desk HUD.lnk'))
    $lnk.TargetPath = $launcher
    $lnk.WorkingDirectory = $dst
    $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
    $lnk.Save()
}

if ($DesktopShortcut) {
    $desk = [Environment]::GetFolderPath('Desktop')
    $lnk = $shell.CreateShortcut((Join-Path $desk 'Codex Desk HUD.lnk'))
    $lnk.TargetPath = $launcher
    $lnk.WorkingDirectory = $dst
    $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
    $lnk.Save()
}

Write-Host "Installed to $dst"
Write-Host "Config: $(Join-Path $dst 'config.json')"
Start-Process $launcher -WindowStyle Hidden
