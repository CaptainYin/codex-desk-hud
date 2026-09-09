param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$StatusPath,
    [Parameter(Mandatory=$true)][int]$ParentPid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
    return (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$script:WorkerLogPath = Join-Path (Split-Path -Parent $StatusPath) 'worker.log'

function Write-WorkerLog([string]$Message) {
    try {
        $dir = Split-Path -Parent $script:WorkerLogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $line = ('[{0:yyyy-MM-dd HH:mm:ss.fff}] {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine)
        [IO.File]::AppendAllText($script:WorkerLogPath, $line, ([System.Text.UTF8Encoding]::new($false)))
    } catch {}
}

function Write-StatusAtomically($Object) {
    $dir = Split-Path -Parent $StatusPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = $StatusPath + '.tmp'
    $json = $Object | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($tmp, $json, ([System.Text.UTF8Encoding]::new($false)))
    Move-Item -LiteralPath $tmp -Destination $StatusPath -Force
}

function Publish-Status {
    param(
        [string]$Message,
        $Sessions = @(),
        $Quotas = @(),
        $Errors = @(),
        [string]$Distro = '',
        [string]$Container = ''
    )
    $status = [pscustomobject]@{
        generatedAt = (Get-Date).ToString('o')
        message = $Message
        discovery = [pscustomobject]@{ wslDistro=$Distro; dockerContainer=$Container }
        quotas = @($Quotas)
        sessions = @($Sessions)
        errors = @($Errors)
    }
    Write-StatusAtomically $status
}

function Get-PropValue {
    param($Object, [string[]]$Names, $Default = $null)
    if ($null -eq $Object) { return $Default }
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    }
    return $Default
}

function Get-LabelForWindow([int]$Minutes) {
    switch ($Minutes) {
        300 { return '5小时' }
        10080 { return '7天' }
        default {
            if ($Minutes -ge 1440 -and $Minutes % 1440 -eq 0) { return ('{0}天' -f ($Minutes / 1440)) }
            if ($Minutes -ge 60 -and $Minutes % 60 -eq 0) { return ('{0}小时' -f ($Minutes / 60)) }
            return ('{0}分钟' -f $Minutes)
        }
    }
}

function Convert-RateLimits {
    param($RateLimits, [string]$SourceName, [string]$Method)
    if ($null -eq $RateLimits) { return $null }
    $windows = @()
    foreach ($slotName in @('primary','secondary')) {
        $slot = Get-PropValue $RateLimits @($slotName) $null
        if ($null -eq $slot) { continue }
        $used = Get-PropValue $slot @('usedPercent','used_percent') $null
        $mins = Get-PropValue $slot @('windowDurationMins','window_minutes') $null
        $reset = Get-PropValue $slot @('resetsAt','resets_at') $null
        if ($null -eq $used -or $null -eq $mins) { continue }
        $remaining = [Math]::Max(0.0, [Math]::Min(100.0, 100.0 - [double]$used))
        $resetIso = $null
        if ($null -ne $reset) {
            try { $resetIso = [DateTimeOffset]::FromUnixTimeSeconds([int64]$reset).ToLocalTime().ToString('o') } catch {}
        }
        $windows += [pscustomobject]@{
            label = Get-LabelForWindow ([int]$mins)
            windowMinutes = [int]$mins
            usedPercent = [Math]::Round([double]$used, 1)
            remainingPercent = [Math]::Round($remaining, 1)
            resetsAt = $resetIso
        }
    }
    if ($windows.Count -eq 0) { return $null }
    $plan = Get-PropValue $RateLimits @('planType','plan_type') $null
    $credits = Get-PropValue $RateLimits @('credits') $null
    $balance = if ($null -ne $credits) { Get-PropValue $credits @('balance') $null } else { $null }
    return [pscustomobject]@{
        source = $SourceName
        method = $Method
        plan = $plan
        balance = $balance
        windows = @($windows)
    }
}

function Read-FirstJsonLine([string]$Path) {
    try {
        $line = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        return ($line | ConvertFrom-Json)
    } catch { return $null }
}

function Get-SessionIndexMap([string]$CodexHome) {
    $map = @{}
    $p = Join-Path $CodexHome 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $p)) { return $map }
    try {
        Get-Content -LiteralPath $p -Encoding UTF8 | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_)) { return }
            try {
                $o = $_ | ConvertFrom-Json
                $id = Get-PropValue $o @('id','session_id','thread_id') $null
                $title = Get-PropValue $o @('thread_name','title') $null
                if ($id -and $title) { $map[[string]$id] = [string]$title }
            } catch {}
        }
    } catch {}
    return $map
}

function Get-LeafName([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.TrimEnd([char[]]'\/')
    if ($p -match '([^\\/]+)$') { return $Matches[1] }
    return $p
}

function Get-WindowsSourceLabel($Meta) {
    $originator = [string](Get-PropValue $Meta @('originator') '')
    $sourceObj = Get-PropValue $Meta @('source') $null
    try { $source = $sourceObj | ConvertTo-Json -Compress -Depth 5 } catch { $source = [string]$sourceObj }
    $joined = ($originator + ' ' + $source).ToLowerInvariant()
    if ($joined -match 'vscode') { return 'VS Code' }
    if ($joined -match 'cli|exec|tui') { return 'Windows CLI' }
    if ($joined -match 'desktop|app') { return 'Codex App' }
    return 'Windows Codex'
}

function Read-BoundedTail([string]$Path) {
    # Read a fixed byte snapshot so long, actively appended JSONL records cannot block polling.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $count = [int][Math]::Min($stream.Length, 2MB)
        $offset = $stream.Length - $count
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $bytes = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $n = $stream.Read($bytes, $read, $count - $read)
            if ($n -eq 0) { break }
            $read += $n
        }
        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $read)
        if ($offset -gt 0) {
            $newline = $text.IndexOf("`n")
            if ($newline -lt 0) { return }
            $text = $text.Substring($newline + 1)
        }
        return ($text -split "`r?`n")
    } finally { $stream.Dispose() }
}

function Get-WindowsSessionSnapshot {
    param([string]$CodexHome, [int]$MaxSessions, [double]$StaleMinutes)
    $result = [ordered]@{ sessions = @(); latestRateLimits = $null }
    $sessionRoot = Join-Path $CodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $sessionRoot)) { return [pscustomobject]$result }
    $titles = Get-SessionIndexMap $CodexHome
    $files = @(Get-ChildItem -LiteralPath $sessionRoot -Filter 'rollout-*.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First ([Math]::Max($MaxSessions * 4, 20)))
    $rateMtime = [DateTime]::MinValue
    foreach ($file in $files) {
        if ($result.sessions.Count -ge $MaxSessions) { break }
        $first = Read-FirstJsonLine $file.FullName
        $meta = if ($first -and $first.type -eq 'session_meta') { $first.payload } else { $null }
        if ($null -ne $meta) {
            $parent = Get-PropValue $meta @('parent_thread_id','parentThreadId') $null
            if ($parent) { continue }
        }
        $id = if ($meta) { [string](Get-PropValue $meta @('id','session_id','sessionId') '') } else { '' }
        if ([string]::IsNullOrWhiteSpace($id)) {
            if ($file.Name -match '([0-9a-fA-F-]{20,})\.jsonl$') { $id = $Matches[1] } else { $id = $file.BaseName }
        }
        $cwd = if ($meta) { [string](Get-PropValue $meta @('cwd') '') } else { '' }
        $tail = @()
        try { $tail = @(Read-BoundedTail $file.FullName) } catch {}
        $life = $null
        $tokenPayload = $null
        for ($i = $tail.Count - 1; $i -ge 0 -and ($null -eq $life -or $null -eq $tokenPayload); $i--) {
            $line = $tail[$i]
            if ($null -eq $life -and ($line -match '^.{0,100}"type"\s*:\s*"event_msg".*"type"\s*:\s*"(task_started|task_complete|turn_aborted)"')) {
                try {
                    $o = $line | ConvertFrom-Json
                    if ($o.type -eq 'event_msg') {
                        $t = [string](Get-PropValue $o.payload @('type') '')
                        if ($t -in @('task_started','task_complete','turn_aborted')) { $life = $t }
                    }
                } catch {}
            }
            if ($null -eq $tokenPayload -and $line -match '^.{0,100}"type"\s*:\s*"event_msg".*"type"\s*:\s*"token_count"') {
                try {
                    $o = $line | ConvertFrom-Json
                    if ($o.type -eq 'event_msg' -and $o.payload.type -eq 'token_count') { $tokenPayload = $o.payload }
                } catch {}
            }
        }
        $ageMin = ((Get-Date).ToUniversalTime() - $file.LastWriteTimeUtc).TotalMinutes
        $status = 'unknown'
        if ($life -eq 'task_started') { $status = if ($ageMin -gt $StaleMinutes) { 'stale' } else { 'running' } }
        elseif ($life -eq 'task_complete') { $status = 'completed' }
        elseif ($life -eq 'turn_aborted') { $status = 'aborted' }

        $contextPct = $null
        $totalTokens = $null
        if ($tokenPayload) {
            $info = Get-PropValue $tokenPayload @('info') $null
            if ($info) {
                $lastUsage = Get-PropValue $info @('last_token_usage','lastTokenUsage') $null
                $totalTokens = if ($lastUsage) { Get-PropValue $lastUsage @('total_tokens','totalTokens') $null } else { $null }
                $contextWindow = Get-PropValue $info @('model_context_window','modelContextWindow') $null
                if ($null -ne $totalTokens -and $null -ne $contextWindow -and [double]$contextWindow -gt 0) {
                    $contextPct = [Math]::Min(100.0, [Math]::Round(([double]$totalTokens / [double]$contextWindow) * 100.0, 1))
                }
            }
            $rl = Get-PropValue $tokenPayload @('rate_limits','rateLimits') $null
            if ($rl -and $file.LastWriteTimeUtc -gt $rateMtime) { $result.latestRateLimits = $rl; $rateMtime = $file.LastWriteTimeUtc }
        }

        $title = if ($titles.ContainsKey($id)) { $titles[$id] } else { Get-LeafName $cwd }
        if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Session ' + $id.Substring(0, [Math]::Min(8, $id.Length)) }
        $result.sessions += [pscustomobject]@{
            id = $id
            title = $title
            workspace = Get-LeafName $cwd
            source = Get-WindowsSourceLabel $meta
            status = $status
            lifecycle = $life
            updatedAt = $file.LastWriteTime.ToString('o')
            contextPercent = $contextPct
            totalTokens = $totalTokens
        }
    }
    return [pscustomobject]$result
}

function Invoke-WslText {
    param([string]$Distro, [string[]]$CommandArgs, [int]$TimeoutMs = 5000)
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl)) { $wsl = 'wsl.exe' }
    $safeArgs = @()
    if ($Distro) { $safeArgs += @('-d', $Distro) }
    $safeArgs += '--exec'
    $safeArgs += $CommandArgs
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wsl
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = ($safeArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {}; throw 'WSL command timed out' }
    $out = $outTask.Result
    $err = $errTask.Result
    if ($p.ExitCode -ne 0) { throw ("WSL command failed ({0}): {1}" -f $p.ExitCode, $err.Trim()) }
    return $out
}

function Resolve-WslDistro([string]$Configured) {
    if ($Configured) { return $Configured }
    try {
        $text = Invoke-WslText '' @('sh','-lc','printf %s "${WSL_DISTRO_NAME:-}"') 2500
        if ($text.Trim() -and $text.Trim() -notmatch '^docker-desktop') { return $text.Trim() }
    } catch {}
    try {
        $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
        if (-not (Test-Path -LiteralPath $wsl)) { $wsl = 'wsl.exe' }
        $rows = & $wsl -l -q 2>$null
        foreach ($r in $rows) {
            $name = ([string]$r).Replace([char]0,'').Trim()
            if ($name -and $name -notmatch '^docker-desktop') { return $name }
        }
    } catch {}
    return ''
}

function Resolve-DockerContainer([string]$Distro, [string]$Configured) {
    if ($Configured) { return $Configured }
    if (-not $Distro) { return '' }
    try {
        $text = Invoke-WslText $Distro @('docker','ps','--format','{{.Names}}|{{.Image}}|{{.Command}}') 4000
        $rows = @($text -split "`r?`n" | Where-Object { $_.Trim() })
        $hits = @($rows | Where-Object { $_ -match '(?i)codex' })
        $pick = if ($hits.Count -eq 1) { $hits[0] } elseif ($rows.Count -eq 1) { $rows[0] } else { $null }
        if ($pick) { return ($pick -split '\|', 2)[0].Trim() }
    } catch {}
    return ''
}

function Invoke-DockerProbe {
    param($Config, [string]$Distro, [string]$Container, [string]$ProbeScript, [string]$Runtime)
    if (-not $Distro -or -not $Container) { throw 'WSL distro or Docker container is not configured/detected.' }
    if ($Container -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Unsafe Docker container name.' }
    $probeHome = [string]$Config.Docker.CodexHome
    $max = [int]$Config.MaxSessionsPerSource
    $stale = [double]$Config.RunningStaleMinutes
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl)) { $wsl = 'wsl.exe' }
    $argParts = @('-d', $Distro, '--exec', 'docker', 'exec', '-i')
    if ($probeHome) { $argParts += @('-e', ('PROBE_CODEX_HOME=' + $probeHome)) }
    $argParts += @(
        '-e', ('PROBE_MAX_SESSIONS=' + $max),
        '-e', ('PROBE_STALE_MINUTES=' + $stale),
        $Container, $Runtime, '-')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wsl
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = ($argParts | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } }) -join ' '
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($ProbeScript)
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(7000)) { try { $p.Kill() } catch {}; throw 'Docker probe timed out.' }
    $out = $outTask.Result.Trim()
    $err = $errTask.Result.Trim()
    if ($p.ExitCode -ne 0) { throw ("Docker probe failed ({0}): {1}" -f $p.ExitCode, $err) }
    if (-not $out) { throw 'Docker probe returned no data.' }
    return ($out | ConvertFrom-Json)
}

function Resolve-WindowsCodex([string]$Configured) {
    if ($Configured) { return $Configured }
    if ($env:CODEX_PATH -and (Test-Path -LiteralPath $env:CODEX_PATH)) { return $env:CODEX_PATH }
    foreach ($name in @('codex.exe','codex.cmd','codex')) {
        try {
            $c = Get-Command $name -ErrorAction Stop | Select-Object -First 1
            if ($c.Source) { return $c.Source }
            if ($c.Path) { return $c.Path }
        } catch {}
    }
    $desktopBins = @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    if ($desktopBins.Count -gt 0) { return $desktopBins[0].FullName }
    $fallbacks = @(
        (Join-Path $env:APPDATA 'npm\codex.cmd'),
        (Join-Path $env:APPDATA 'npm\codex.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\codex.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\codex.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\codex.cmd'),
        (Join-Path $env:ProgramFiles 'nodejs\codex.exe')
    )
    foreach ($p in $fallbacks) { if (Test-Path -LiteralPath $p) { return $p } }
    return ''
}

function Quote-CmdArg([string]$s) {
    if ($s -notmatch '[\s"]') { return $s }
    return '"' + ($s -replace '"','\"') + '"'
}

function Read-RpcResponseById {
    param([System.Diagnostics.Process]$Process, [int]$Id, [int]$TimeoutMs)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $task = $Process.StandardOutput.ReadLineAsync()
        if (-not $task.Wait($remaining)) { return $null }
        $line = $task.Result
        if ($null -eq $line) { return $null }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $o = $line | ConvertFrom-Json
            if ($null -ne $o.PSObject.Properties['id'] -and [string]$o.id -eq [string]$Id) { return $o }
        } catch {}
    }
    return $null
}

function Invoke-AppServerProcess {
    param([string]$FileName, [string]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stderrDrain = $p.StandardError.ReadToEndAsync()
    try {
        $init = @{ jsonrpc='2.0'; id=1; method='initialize'; params=@{ clientInfo=@{ name='codex_desk_hud'; title='Codex Desk HUD'; version='0.1.0' } } } | ConvertTo-Json -Compress -Depth 8
        $p.StandardInput.WriteLine($init)
        $p.StandardInput.Flush()
        $r1 = Read-RpcResponseById $p 1 4500
        if ($null -eq $r1) { throw 'No initialize response from codex app-server.' }
        if ($null -ne $r1.PSObject.Properties['error']) { throw ('Initialize failed: ' + ($r1.error | ConvertTo-Json -Compress)) }
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"initialized"}')
        $p.StandardInput.WriteLine('{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}')
        $p.StandardInput.Flush()
        $r2 = Read-RpcResponseById $p 2 5000
        if ($null -eq $r2) { throw 'No rate-limit response from codex app-server.' }
        if ($null -ne $r2.PSObject.Properties['error']) { throw ('Rate-limit read failed: ' + ($r2.error | ConvertTo-Json -Compress)) }
        return $r2.result
    } finally {
        try { $p.StandardInput.Close() } catch {}
        if (-not $p.HasExited) { try { $p.Kill() } catch {} }
        try { $p.Dispose() } catch {}
    }
}

function Select-CodexRateLimits($RpcResult) {
    if ($null -eq $RpcResult) { return $null }
    $byId = Get-PropValue $RpcResult @('rateLimitsByLimitId') $null
    if ($byId) {
        $codex = $byId.PSObject.Properties['codex']
        if ($codex -and $codex.Value) { return $codex.Value }
    }
    return (Get-PropValue $RpcResult @('rateLimits') $null)
}

function Get-WindowsOfficialQuota($Config) {
    $codex = Resolve-WindowsCodex ([string]$Config.Windows.CodexCommand)
    if (-not $codex) { throw 'Windows Codex CLI executable not found.' }
    foreach ($mode in @('--listen stdio://','')) {
        try {
            if ([IO.Path]::GetExtension($codex).ToLowerInvariant() -eq '.cmd') {
                $cmdArgs = '/d /s /c ""' + $codex + '" app-server ' + $mode + '"'
                $r = Invoke-AppServerProcess (Join-Path $env:SystemRoot 'System32\cmd.exe') $cmdArgs
            } else {
                $r = Invoke-AppServerProcess $codex ('app-server ' + $mode)
            }
            $rl = Select-CodexRateLimits $r
            if ($rl) { return (Convert-RateLimits $rl 'Windows / Codex App' 'official app-server') }
        } catch {
            if ($mode -eq '') { throw }
        }
    }
    throw 'Quota response contains no usable windows.'
}

function Get-DockerOfficialQuota($Config, [string]$Distro, [string]$Container) {
    if (-not $Distro -or -not $Container) { throw 'Docker target not available.' }
    $codexCmd = [string]$Config.Docker.CodexCommand
    if (-not $codexCmd) { $codexCmd = 'codex' }
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl)) { $wsl = 'wsl.exe' }
    foreach ($modeParts in @(@('--listen','stdio://'), @())) {
        try {
            $parts = @('-d',$Distro,'--exec','docker','exec','-i',$Container,$codexCmd,'app-server') + $modeParts
            $rpcArguments = ($parts | ForEach-Object { Quote-CmdArg $_ }) -join ' '
            $r = Invoke-AppServerProcess $wsl $rpcArguments
            $rl = Select-CodexRateLimits $r
            if ($rl) { return (Convert-RateLimits $rl 'WSL Docker' 'official app-server') }
        } catch {
            if ($modeParts.Count -eq 0) { throw }
        }
    }
    throw 'Quota response contains no usable windows.'
}

$probePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'CodexRemoteProbe.js'
$probePyPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'CodexRemoteProbe.py'

# Anything fatal from this point forward should become visible in the HUD and worker.log.
trap {
    $fatal = $_.Exception.Message
    Write-WorkerLog ('FATAL: ' + $fatal)
    try { Publish-Status -Message '后台启动失败' -Errors @('Worker fatal: ' + $fatal) } catch {}
    break
}

Write-WorkerLog ('Worker starting. ParentPid=' + $ParentPid + '; Config=' + $ConfigPath + '; Status=' + $StatusPath)
Publish-Status -Message '后台已启动，正在读取配置…'

$probeScript = Get-Content -LiteralPath $probePath -Raw -Encoding UTF8
$probePyScript = Get-Content -LiteralPath $probePyPath -Raw -Encoding UTF8
$windowsQuotaCache = $null
$dockerQuotaCache = $null
$nextQuotaRefresh = [DateTime]::MinValue
$quotaErrors = @()
$distro = ''
$container = ''

function Get-CachedQuotaArray {
    $q = @()
    if ($null -ne $windowsQuotaCache) { $q += $windowsQuotaCache }
    if ($null -ne $dockerQuotaCache) { $q += $dockerQuotaCache }
    return $q
}

while ($true) {
    try { Get-Process -Id $ParentPid -ErrorAction Stop | Out-Null } catch {
        Write-WorkerLog 'Parent process exited; worker stopping.'
        break
    }

    $errors = @()
    try { $config = Get-Config } catch {
        $msg = 'Config: ' + $_.Exception.Message
        Write-WorkerLog $msg
        try { Publish-Status -Message '配置读取失败' -Errors @($msg) -Distro $distro -Container $container } catch {}
        Start-Sleep -Seconds 3
        continue
    }

    $maxSessions = [int]$config.MaxSessionsPerSource
    if ($maxSessions -lt 1) { $maxSessions = 8 }
    $staleMinutes = [double]$config.RunningStaleMinutes
    if ($staleMinutes -lt 1) { $staleMinutes = 30 }
    $allSessions = @()
    $winSnap = $null
    $dockerSnap = $null

    # Publish before doing any WSL/Docker/app-server work. This is intentionally early.
    try { Publish-Status -Message '正在扫描 Windows Codex 会话…' -Sessions $allSessions -Quotas @(Get-CachedQuotaArray) -Errors @($errors) -Distro $distro -Container $container } catch {}

    if ($config.Windows.Enabled) {
        $winHome = [string]$config.Windows.CodexHome
        if (-not $winHome) { $winHome = Join-Path $env:USERPROFILE '.codex' }
        try {
            $winSnap = Get-WindowsSessionSnapshot $winHome $maxSessions $staleMinutes
            $allSessions += @($winSnap.sessions)
        } catch {
            $errors += ('Windows sessions: ' + $_.Exception.Message)
            Write-WorkerLog ('Windows sessions: ' + $_.Exception.Message)
        }
    }

    try { Publish-Status -Message 'Windows 会话已读取，正在检查 WSL / Docker…' -Sessions $allSessions -Quotas @(Get-CachedQuotaArray) -Errors @($errors) -Distro $distro -Container $container } catch {}

    if ($config.Docker.Enabled) {
        try {
            $configuredDistro = [string]$config.Docker.WslDistro
            $configuredContainer = [string]$config.Docker.Container
            if ($configuredDistro) { $distro = $configuredDistro }
            elseif (-not $distro) { $distro = Resolve-WslDistro '' }
            if ($configuredContainer) { $container = $configuredContainer }
            elseif (-not $container) { $container = Resolve-DockerContainer $distro '' }
            if ($distro -and $container) {
                try {
                    $dockerSnap = Invoke-DockerProbe $config $distro $container $probeScript 'node'
                } catch {
                    Write-WorkerLog ('Docker node probe failed, trying python3: ' + $_.Exception.Message)
                    $dockerSnap = Invoke-DockerProbe $config $distro $container $probePyScript 'python3'
                }
                $allSessions += @($dockerSnap.sessions)
            } else {
                $errors += 'WSL Docker: 未自动找到 distro/container；请在 config.json 中填写 Docker.WslDistro 和 Docker.Container。'
            }
        } catch {
            if (-not ([string]$config.Docker.Container)) { $container = '' }
            $errors += ('WSL Docker sessions: ' + $_.Exception.Message)
            Write-WorkerLog ('WSL Docker sessions: ' + $_.Exception.Message)
        }
    }

    $allSessions = @($allSessions | Sort-Object @{Expression={ if ($_.status -eq 'running') { 0 } elseif ($_.status -eq 'stale') { 1 } else { 2 } }}, @{Expression={ try { [DateTimeOffset]::Parse([string]$_.updatedAt).UtcDateTime } catch { [DateTime]::MinValue } }; Descending=$true})
    $quotasNow = @(Get-CachedQuotaArray)
    try { Publish-Status -Message '会话已更新；正在刷新额度…' -Sessions $allSessions -Quotas $quotasNow -Errors @($errors) -Distro $distro -Container $container } catch {}

    # Quota calls can be slow. They run only after session information is already visible.
    if ((Get-Date) -ge $nextQuotaRefresh) {
        $quotaErrors = @()
        if ($config.Windows.Enabled) {
            try {
                $windowsQuotaCache = Get-WindowsOfficialQuota $config
            } catch {
                if ($winSnap -and $winSnap.latestRateLimits) {
                    $windowsQuotaCache = Convert-RateLimits $winSnap.latestRateLimits 'Windows / Codex App' '日志缓存（非实时）'
                } else {
                    $quotaErrors += ('Windows quota: ' + $_.Exception.Message)
                }
                Write-WorkerLog ('Windows quota: ' + $_.Exception.Message)
            }
            $quotasNow = @(Get-CachedQuotaArray)
            try { Publish-Status -Message 'Windows 额度已检查；正在检查 Docker 额度…' -Sessions $allSessions -Quotas $quotasNow -Errors @($errors) -Distro $distro -Container $container } catch {}
        }

        if ($config.Docker.Enabled -and $distro -and $container) {
            try {
                $dockerQuotaCache = Get-DockerOfficialQuota $config $distro $container
            } catch {
                $quotaErrors += ('WSL Docker quota: ' + $_.Exception.Message)
                if ($dockerSnap -and $dockerSnap.latestRateLimits) {
                    $dockerQuotaCache = Convert-RateLimits $dockerSnap.latestRateLimits 'WSL Docker' '日志缓存（非实时）'
                } else {
                    $quotaErrors += ('WSL Docker quota: ' + $_.Exception.Message)
                }
                Write-WorkerLog ('WSL Docker quota: ' + $_.Exception.Message)
            }
        }

        $qsec = [int]$config.QuotaRefreshSeconds
        if ($qsec -lt 20) { $qsec = 90 }
        $nextQuotaRefresh = (Get-Date).AddSeconds($qsec)
    }

    $quotas = @(Get-CachedQuotaArray)
    try {
        Publish-Status -Message $(if (@($errors + $quotaErrors).Count) { '部分数据读取失败' } else { '监控正常' }) -Sessions $allSessions -Quotas $quotas -Errors @($errors + $quotaErrors) -Distro $distro -Container $container
    } catch {
        Write-WorkerLog ('Status write failed: ' + $_.Exception.Message)
    }

    $sec = [int]$config.RefreshSeconds
    if ($sec -lt 1) { $sec = 3 }
    Start-Sleep -Seconds $sec
}
