param([string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$src = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'CodexDeskHUD.Launcher.cs') -Raw -Encoding UTF8
$out = Join-Path $OutputDirectory 'CodexDeskHUD.exe'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
Add-Type -TypeDefinition $src -Language CSharp -OutputAssembly $out -OutputType WindowsApplication
Write-Host "Built $out"
