param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $defaultConfig = Join-Path $PSScriptRoot 'config.json'
    if ([IO.Path]::GetFullPath($ConfigPath) -ne [IO.Path]::GetFullPath($defaultConfig)) {
        throw "Config not found: $ConfigPath"
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.example.json') -Destination $ConfigPath
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Exiting = $false
$script:LastRaw = ''
$script:LastStatus = $null
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter

function Brush([string]$Hex) { return $script:BrushConverter.ConvertFromString($Hex) }

function New-TextBlock {
    param([string]$Text, [double]$Size = 12, [string]$Color = '#D8DEE9', [string]$Weight = 'Normal')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontFamily = New-Object System.Windows.Media.FontFamily -ArgumentList 'Segoe UI Variable Text, Segoe UI'
    $t.FontSize = $Size
    $t.Foreground = Brush $Color
    switch ($Weight) {
        'SemiBold' { $t.FontWeight = [System.Windows.FontWeights]::SemiBold }
        'Bold' { $t.FontWeight = [System.Windows.FontWeights]::Bold }
        default { $t.FontWeight = [System.Windows.FontWeights]::Normal }
    }
    $t.TextTrimming = 'CharacterEllipsis'
    return $t
}

function Format-Reset([string]$Iso) {
    if ([string]::IsNullOrWhiteSpace($Iso)) { return '' }
    try {
        $dt = [DateTimeOffset]::Parse($Iso)
        $span = $dt - [DateTimeOffset]::Now
        if ($span.TotalSeconds -le 0) { return '即将重置' }
        if ($span.TotalDays -ge 1) { return ('{0}天{1}小时后重置' -f [int][Math]::Floor($span.TotalDays), $span.Hours) }
        if ($span.TotalHours -ge 1) { return ('{0}小时{1}分后重置' -f [int][Math]::Floor($span.TotalHours), $span.Minutes) }
        return ('{0}分后重置' -f [Math]::Max(1, [int][Math]::Ceiling($span.TotalMinutes)))
    } catch { return '' }
}

function Get-StatusPresentation([string]$Status) {
    switch ($Status) {
        'running'   { return @('运行中', '#5BE49B') }
        'completed' { return @('已结束', '#8A93A5') }
        'aborted'   { return @('已中止', '#F3B562') }
        'stale'     { return @('疑似中断', '#F3B562') }
        default     { return @('未知', '#8A93A5') }
    }
}

function New-QuotaGroup($Quota) {
    $outer = New-Object System.Windows.Controls.Border
    $outer.Background = Brush '#171A21'
    $outer.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $outer.Padding = [System.Windows.Thickness]::new(10,8,10,8)
    $outer.Margin = [System.Windows.Thickness]::new(0,0,0,8)

    $stack = New-Object System.Windows.Controls.StackPanel
    $outer.Child = $stack

    $head = New-Object System.Windows.Controls.DockPanel
    $source = New-TextBlock ([string]$Quota.source) 11 '#F4F7FB' 'SemiBold'
    [System.Windows.Controls.DockPanel]::SetDock($source, 'Left')
    [void]$head.Children.Add($source)
    $meta = @()
    if ($Quota.plan) { $meta += ([string]$Quota.plan) }
    if ($null -ne $Quota.balance -and [string]$Quota.balance -ne '') { $meta += ('credits ' + [string]$Quota.balance) }
    if ($Quota.method) { $meta += ([string]$Quota.method) }
    if ($meta.Count -gt 0) {
        $m = New-TextBlock ($meta -join ' · ') 9 '#6F7A8D' 'Normal'
        $m.HorizontalAlignment = 'Right'
        [System.Windows.Controls.DockPanel]::SetDock($m, 'Right')
        [void]$head.Children.Add($m)
    }
    [void]$stack.Children.Add($head)

    foreach ($w in @($Quota.windows)) {
        $row = New-Object System.Windows.Controls.Grid
        $row.Margin = [System.Windows.Thickness]::new(0,6,0,0)
        [void]$row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='70'}))
        [void]$row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='*'}))
        [void]$row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='62'}))

        $label = New-TextBlock ([string]$w.label) 10 '#AEB7C6' 'SemiBold'
        $label.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($label,0)
        [void]$row.Children.Add($label)

        $bar = New-Object System.Windows.Controls.ProgressBar
        $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = [double]$w.remainingPercent
        $bar.Height = 6; $bar.VerticalAlignment = 'Center'; $bar.BorderThickness = 0
        $bar.Background = Brush '#2B303B'
        $rem = [double]$w.remainingPercent
        if ($rem -le 20) { $bar.Foreground = Brush '#EF6B73' }
        elseif ($rem -le 45) { $bar.Foreground = Brush '#F3B562' }
        else { $bar.Foreground = Brush '#5BE49B' }
        [System.Windows.Controls.Grid]::SetColumn($bar,1)
        [void]$row.Children.Add($bar)

        $pct = New-TextBlock (('{0:0.#}%' -f $rem)) 10 '#F4F7FB' 'SemiBold'
        $pct.HorizontalAlignment = 'Right'; $pct.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($pct,2)
        [void]$row.Children.Add($pct)
        [void]$stack.Children.Add($row)

        $reset = Format-Reset ([string]$w.resetsAt)
        if ($reset) {
            $r = New-TextBlock $reset 9 '#697386' 'Normal'
            $r.Margin = [System.Windows.Thickness]::new(70,1,0,0)
            [void]$stack.Children.Add($r)
        }
    }
    return $outer
}

function New-SessionRow($Session) {
    $p = Get-StatusPresentation ([string]$Session.status)
    $statusText = $p[0]; $statusColor = $p[1]

    $border = New-Object System.Windows.Controls.Border
    $border.Background = if ($Session.status -eq 'running') { Brush '#18221F' } else { Brush '#151820' }
    $border.CornerRadius = [System.Windows.CornerRadius]::new(9)
    $border.Padding = [System.Windows.Thickness]::new(9,7,9,7)
    $border.Margin = [System.Windows.Thickness]::new(0,0,0,6)

    $grid = New-Object System.Windows.Controls.Grid
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='15'}))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='*'}))
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='74'}))
    $border.Child = $grid

    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 7; $dot.Height = 7; $dot.Fill = Brush $statusColor
    $dot.VerticalAlignment = 'Top'; $dot.Margin = [System.Windows.Thickness]::new(0,6,0,0)
    [System.Windows.Controls.Grid]::SetColumn($dot,0)
    [void]$grid.Children.Add($dot)

    $center = New-Object System.Windows.Controls.StackPanel
    [System.Windows.Controls.Grid]::SetColumn($center,1)
    $title = New-TextBlock ([string]$Session.title) 11 '#EEF2F7' 'SemiBold'
    [void]$center.Children.Add($title)
    $subBits = @([string]$Session.source)
    if ($Session.workspace -and [string]$Session.workspace -ne [string]$Session.title) { $subBits += [string]$Session.workspace }
    if ($null -ne $Session.contextPercent) { $subBits += ('上下文 {0:0.#}%' -f [double]$Session.contextPercent) }
    $sub = New-TextBlock ($subBits -join ' · ') 9 '#737E91' 'Normal'
    $sub.Margin = [System.Windows.Thickness]::new(0,2,0,0)
    [void]$center.Children.Add($sub)
    [void]$grid.Children.Add($center)

    $right = New-Object System.Windows.Controls.StackPanel
    $right.HorizontalAlignment = 'Right'; $right.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($right,2)
    $st = New-TextBlock $statusText 10 $statusColor 'SemiBold'
    $st.HorizontalAlignment = 'Right'
    [void]$right.Children.Add($st)
    try {
        $updated = [DateTimeOffset]::Parse([string]$Session.updatedAt).ToLocalTime()
        $age = [DateTimeOffset]::Now - $updated
        $ageText = if ($age.TotalMinutes -lt 1) { '刚刚' } elseif ($age.TotalHours -lt 1) { ('{0}分前' -f [int]$age.TotalMinutes) } elseif ($age.TotalDays -lt 1) { ('{0}小时前' -f [int]$age.TotalHours) } else { ('{0}天前' -f [int]$age.TotalDays) }
        $at = New-TextBlock $ageText 9 '#687286' 'Normal'; $at.HorizontalAlignment = 'Right'
        [void]$right.Children.Add($at)
    } catch {}
    [void]$grid.Children.Add($right)
    return $border
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="MainWindow"
        Title="Codex Desk HUD"
        Width="410" MinWidth="350" MaxHeight="760"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        SizeToContent="Height" WindowStartupLocation="Manual">
    <Border x:Name="RootBorder" Background="#F21B1E25" BorderBrush="#354052" BorderThickness="1" CornerRadius="16" Padding="12">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid x:Name="HeaderBar" Grid.Row="0" Margin="2,0,2,8">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock Text="CODEX DESK HUD" Foreground="#F7F9FC" FontWeight="SemiBold" FontSize="12" FontFamily="Segoe UI Variable Text, Segoe UI"/>
                    <TextBlock x:Name="UpdatedText" Text="等待后台数据…" Foreground="#6F7A8D" FontSize="9" Margin="0,2,0,0" FontFamily="Segoe UI Variable Text, Segoe UI"/>
                </StackPanel>
                <Button x:Name="HideButton" Grid.Column="1" Content="—" Width="28" Height="24" Margin="0,0,4,0" Background="#232834" Foreground="#AAB4C4" BorderThickness="0" FontSize="12"/>
                <Button x:Name="ExitButton" Grid.Column="2" Content="×" Width="28" Height="24" Background="#232834" Foreground="#AAB4C4" BorderThickness="0" FontSize="14"/>
            </Grid>

            <StackPanel x:Name="QuotaPanel" Grid.Row="1"/>

            <Grid Grid.Row="2" Margin="1,2,1,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="会话" Foreground="#F4F7FB" FontSize="11" FontWeight="SemiBold" FontFamily="Segoe UI Variable Text, Segoe UI"/>
                <TextBlock x:Name="SessionCountText" Grid.Column="1" Text="0" Foreground="#6F7A8D" FontSize="10" FontFamily="Segoe UI Variable Text, Segoe UI"/>
            </Grid>

            <ScrollViewer Grid.Row="3" MaxHeight="390" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel x:Name="SessionPanel"/>
            </ScrollViewer>

            <TextBlock x:Name="ErrorText" Grid.Row="4" Text="" Foreground="#E8A15B" FontSize="9" TextWrapping="Wrap" Margin="1,4,1,0" MaxHeight="44" FontFamily="Segoe UI Variable Text, Segoe UI"/>
        </Grid>
    </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
$headerBar = $window.FindName('HeaderBar')
$hideButton = $window.FindName('HideButton')
$exitButton = $window.FindName('ExitButton')
$quotaPanel = $window.FindName('QuotaPanel')
$sessionPanel = $window.FindName('SessionPanel')
$sessionCountText = $window.FindName('SessionCountText')
$updatedText = $window.FindName('UpdatedText')
$errorText = $window.FindName('ErrorText')

# Apply config-driven window options.
try {
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $cfg.Topmost) { $window.Topmost = [bool]$cfg.Topmost }
    if ($null -ne $cfg.Opacity) { $window.Opacity = [Math]::Max(0.35, [Math]::Min(1.0, [double]$cfg.Opacity)) }
} catch {}

$stateDir = Join-Path $env:LOCALAPPDATA 'CodexDeskHUD'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$statePath = Join-Path $stateDir 'hud-state.json'
$statusPath = Join-Path $stateDir ('status-{0}.json' -f $PID)
$workerPath = Join-Path $PSScriptRoot 'CodexDeskHUD.Worker.ps1'

$positionLoaded = $false
try {
    if (Test-Path -LiteralPath $statePath) {
        $pos = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $pos.left -and $null -ne $pos.top) {
            $window.Left = [double]$pos.left
            $window.Top = [double]$pos.top
            $positionLoaded = $true
        }
    }
} catch {}
if (-not $positionLoaded) {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $window.Left = [Math]::Max($wa.Left, $wa.Right - $window.Width - 18)
    $window.Top = $wa.Top + 18
}

$workerArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -StatusPath "{2}" -ParentPid {3}' -f $workerPath, $ConfigPath, $statusPath, $PID
$workerPsi = New-Object System.Diagnostics.ProcessStartInfo
$workerPsi.FileName = Join-Path $PSHOME 'powershell.exe'
$workerPsi.Arguments = $workerArgs
$workerPsi.UseShellExecute = $false
$workerPsi.CreateNoWindow = $true
$workerPsi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$workerPsi.WorkingDirectory = $PSScriptRoot
$worker = New-Object System.Diagnostics.Process
$worker.StartInfo = $workerPsi
[void]$worker.Start()
$script:WorkerExitReported = $false

function Save-WindowPosition {
    try {
        $obj = @{ left=$window.Left; top=$window.Top } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($statePath, $obj, ([Text.UTF8Encoding]::new($false)))
    } catch {}
}

function Render-Status($Status) {
    $quotaPanel.Children.Clear()
    foreach ($q in @($Status.quotas)) { [void]$quotaPanel.Children.Add((New-QuotaGroup $q)) }
    if (@($Status.quotas).Count -eq 0) {
        $quotaHint = if (@($Status.errors | Where-Object { $_ -match 'quota|fatal' }).Count) { '额度读取失败，请查看下方错误或 worker.log' } else { '额度：正在读取…' }
        $empty = New-TextBlock $quotaHint 10 '#6F7A8D' 'Normal'
        $empty.Margin = [System.Windows.Thickness]::new(1,2,1,10)
        [void]$quotaPanel.Children.Add($empty)
    }

    $sessionPanel.Children.Clear()
    $sessions = @($Status.sessions)
    $sessionCountText.Text = [string]$sessions.Count
    if ($sessions.Count -eq 0) {
        $e = New-TextBlock '暂未发现 Codex 会话' 10 '#6F7A8D' 'Normal'
        $e.Margin = [System.Windows.Thickness]::new(2,6,2,10)
        [void]$sessionPanel.Children.Add($e)
    } else {
        foreach ($s in $sessions) { [void]$sessionPanel.Children.Add((New-SessionRow $s)) }
    }

    try {
        $dt = [DateTimeOffset]::Parse([string]$Status.generatedAt).ToLocalTime()
        $disc = $Status.discovery
        $suffix = ''
        if ($disc -and $disc.dockerContainer) { $suffix = ' · Docker: ' + [string]$disc.dockerContainer }
        $msg = [string]$Status.message
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = '已连接后台' }
        $updatedText.Text = ('{0} · {1:HH:mm:ss}{2}' -f $msg, $dt, $suffix)
    } catch { $updatedText.Text = '已连接后台' }

    $errs = @($Status.errors | Where-Object { $_ })
    if ($errs.Count -gt 0) { $errorText.Text = ($errs | Select-Object -First 2) -join '  |  ' }
    else { $errorText.Text = '' }
}

$headerBar.Add_MouseLeftButtonDown({
    param($sender,$e)
    if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        try { $window.DragMove() } catch {}
    }
})
$headerBar.Add_MouseLeftButtonUp({ Save-WindowPosition })
$hideButton.Add_Click({ $window.Hide() })
$exitButton.Add_Click({ $script:Exiting = $true; $window.Close() })
$window.Add_Closing({
    param($sender,$e)
    if (-not $script:Exiting) { $e.Cancel = $true; $window.Hide(); return }
    Save-WindowPosition
})

# Tray icon and controls.
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Text = 'Codex Desk HUD'
$notify.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $menu.Items.Add('显示 / 隐藏 HUD')
$configItem = $menu.Items.Add('打开 config.json')
$refreshItem = $menu.Items.Add('重新读取配置')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$quitItem = $menu.Items.Add('退出')
$notify.ContextMenuStrip = $menu

$toggle = {
    if ($window.IsVisible) { $window.Hide() } else { $window.Show(); $window.Activate(); $window.Topmost = $true }
}
$showItem.add_Click($toggle)
$notify.add_DoubleClick($toggle)
$configItem.add_Click({ try { Start-Process notepad.exe -ArgumentList ('"' + $ConfigPath + '"') } catch {} })
$refreshItem.add_Click({
    try {
        $cfg2 = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $cfg2.Topmost) { $window.Topmost = [bool]$cfg2.Topmost }
        if ($null -ne $cfg2.Opacity) { $window.Opacity = [Math]::Max(0.35, [Math]::Min(1.0, [double]$cfg2.Opacity)) }
    } catch {}
})
$quitItem.add_Click({ $script:Exiting = $true; $window.Close() })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(850)
$timer.Add_Tick({
    if ($worker -and $worker.HasExited -and -not $script:WorkerExitReported) {
        $script:WorkerExitReported = $true
        $updatedText.Text = '后台进程已退出'
        $errorText.Text = '后台发生启动错误。请查看 %LOCALAPPDATA%\CodexDeskHUD\worker.log，或运行 Debug-CodexDeskHUD.cmd。'
    }
    if (-not (Test-Path -LiteralPath $statusPath)) { return }
    try {
        $raw = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8
        if ($raw -and $raw -ne $script:LastRaw) {
            $status = $raw | ConvertFrom-Json
            $script:LastRaw = $raw
            $script:LastStatus = $status
            Render-Status $status
        }
    } catch { $errorText.Text = '界面更新失败：' + $_.Exception.Message }
})
$timer.Start()

try {
    [void]$window.ShowDialog()
} finally {
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    try { if ($worker -and -not $worker.HasExited) { $worker.Kill() } } catch {}
    try { Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue } catch {}
}
