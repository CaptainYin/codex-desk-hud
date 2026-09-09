$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Get-ChildItem $repo -Filter '*.ps1' -Recurse | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw $errors[0] }
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'CodexDeskHUD.Worker.ps1'), [ref]$tokens, [ref]$errors)
foreach ($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$missing = Convert-RateLimits ([pscustomobject]@{primary=$null;secondary=$null}) 'demo' 'test'
Assert ($null -eq $missing) 'Missing allowance must stay unavailable'
$quota = Convert-RateLimits ([pscustomobject]@{primary=[pscustomobject]@{usedPercent=100;windowDurationMins=300;resetsAt=1900000000}}) 'demo' 'test'
Assert ($quota.windows[0].remainingPercent -eq 0) 'Exhausted allowance must display zero'
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('hud-tests-' + [Guid]::NewGuid().ToString('N'))
$sessionDir = Join-Path $workspace 'sessions'
New-Item -ItemType Directory -Path $sessionDir | Out-Null
try {
    $file = Join-Path $sessionDir 'rollout-demo.jsonl'
    $meta = '{"type":"session_meta","payload":{"id":"demo-session","cwd":"demo-project","originator":"codex_cli"}}'
    $irrelevant = '{"type":"response_item","payload":{"text":"' + ('x' * 4MB) + 'token_count task_started"}}'
    $token = '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":25,"window_minutes":300}}}}'
    $complete = '{"type":"event_msg","payload":{"type":"task_complete"}}'
    [IO.File]::WriteAllText($file, ($meta,$irrelevant,$token,$complete -join "`n"), [Text.UTF8Encoding]::new($false))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $snapshot = Get-WindowsSessionSnapshot $workspace 8 30
    Assert ($watch.Elapsed.TotalSeconds -lt 10) 'Large-record scan exceeded ten seconds'
    Assert (@($snapshot.sessions).Count -eq 1) 'Expected one synthetic session'
    Assert ($snapshot.sessions[0].status -eq 'completed') 'Lifecycle should be completed'
    Assert ($null -ne $snapshot.latestRateLimits) 'Expected quota event from tail'
    $q = Convert-RateLimits $snapshot.latestRateLimits 'demo' 'test'
    Assert ($q.windows[0].remainingPercent -eq 75) 'Snake-case quota conversion failed'
    Write-Host ('PASS: syntax, missing/exhausted quota, bounded large-record scan ({0:n2}s), lifecycle and quota extraction' -f $watch.Elapsed.TotalSeconds)
} finally {
    # Delete only the explicit fixture files and empty directories created above.
    Remove-Item -LiteralPath (Join-Path $sessionDir 'rollout-demo.jsonl') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sessionDir -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $workspace -ErrorAction SilentlyContinue
}
