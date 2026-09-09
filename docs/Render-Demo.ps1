# Render the real HUD controls with synthetic data; no session files or desktop capture.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$repo = Split-Path -Parent $PSScriptRoot
$src = Get-Content (Join-Path $repo 'CodexDeskHUD.ps1') -Raw -Encoding UTF8
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
foreach ($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$xamlAssignment = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$xaml'}, $false)
. ([scriptblock]::Create($xamlAssignment.Extent.Text))
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$quotaPanel = $window.FindName('QuotaPanel')
$sessionPanel = $window.FindName('SessionPanel')
$sessionCountText = $window.FindName('SessionCountText')
$updatedText = $window.FindName('UpdatedText')
$errorText = $window.FindName('ErrorText')
$now = [DateTimeOffset]::Now
$quotas = foreach ($source in @('Windows / Codex App', 'WSL Docker')) {
    [pscustomobject]@{source=$source;plan='';balance=$null;method='Demo data';windows=@(
        [pscustomobject]@{label='5小时';remainingPercent=72;resetsAt=$now.AddHours(3).ToString('o')},
        [pscustomobject]@{label='7天';remainingPercent=58;resetsAt=$now.AddDays(4).ToString('o')}
    )}
}
$sessions = @(
    [pscustomobject]@{title='Build a dashboard';workspace='demo-web';source='Codex App';status='running';contextPercent=24;updatedAt=$now.ToString('o')},
    [pscustomobject]@{title='Run container tests';workspace='demo-service';source='WSL Docker';status='running';contextPercent=36;updatedAt=$now.ToString('o')},
    [pscustomobject]@{title='Update documentation';workspace='demo-docs';source='Windows CLI';status='completed';contextPercent=18;updatedAt=$now.AddMinutes(-8).ToString('o')}
)
Render-Status ([pscustomobject]@{generatedAt=$now.ToString('o');message='监控正常';discovery=[pscustomobject]@{dockerContainer='demo-container'};quotas=$quotas;sessions=$sessions;errors=@()})
$updatedText.Text = 'Windows + WSL Docker · 演示数据'
$root = $window.Content
$window.Content = $null
$root.Width = 410
$root.Measure([Windows.Size]::new(410,1000))
$height = [Math]::Ceiling($root.DesiredSize.Height)
$root.Arrange([Windows.Rect]::new(0,0,410,$height))
$root.UpdateLayout()
$bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(820,[int]($height*2),192,192,[Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($root)
$encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$output = Join-Path $PSScriptRoot 'hud-demo.png'
$stream = [IO.File]::Create($output)
try { $encoder.Save($stream) } finally { $stream.Dispose() }
Write-Host 'Rendered docs/hud-demo.png using synthetic data'
