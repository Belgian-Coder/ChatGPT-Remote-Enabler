[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$retryLogs = [Collections.Generic.List[string]]::new()
$failRetryLogging = $false
function Write-StartupLog { param([string]$Message) if ($failRetryLogging) { throw 'fixture log is unavailable' }; [void]$retryLogs.Add($Message) }
function Write-RemoteLauncherLog { param([string]$Message) if ($failRetryLogging) { throw 'fixture log is unavailable' }; [void]$retryLogs.Add($Message) }
$cases = @(
    [pscustomobject]@{
        Path = 'windows\CodexRemoteMobileProject\MobileProjectStartup.ps1'
        GetFunction = 'Get-MobileReport'
        AssertFunction = 'Assert-MobileReport'
        TimeoutFunction = 'Get-MobileReadinessTimeoutMessage'
        WaitFunction = 'Wait-MobileReadiness'
        BackgroundFunction = 'Start-MobileBackgroundServices'
        EnableMarker = '$enableOutput = @(& $mobileController -Action Enable'
        ReportMarker = '$report = Get-MobileReport -Output $enableOutput'
        BackgroundMarker = 'Start-MobileBackgroundServices -NodePath $node'
        WaitMarker = '$report = Wait-MobileReadiness -Report $report'
        ReadyMarker = 'stage=mobile-readiness durationMs='
        HandoffMarker = 'Write-RelaunchHandoff'
    },
    [pscustomobject]@{
        Path = 'windows\Enable-ChatGPTRemote.ps1'
        GetFunction = 'Get-RemoteMobileReport'
        AssertFunction = 'Assert-RemoteMobileReport'
        TimeoutFunction = 'Get-RemoteMobileReadinessTimeoutMessage'
        WaitFunction = 'Wait-RemoteMobileReadiness'
        BackgroundFunction = 'Start-RemoteMobileBackgroundServices'
        EnableMarker = '$enableOutput = @(& $mobile -Action Enable'
        ReportMarker = '$report = Get-RemoteMobileReport -Output $enableOutput'
        BackgroundMarker = 'Start-RemoteMobileBackgroundServices -NodePath $node'
        WaitMarker = '$report = Wait-RemoteMobileReadiness -Report $report'
        ReadyMarker = 'stage=mobile-readiness durationMs='
        HandoffMarker = 'Write-RemoteRelaunchHandoff'
    }
)

foreach ($case in $cases) {
    $sourcePath = Join-Path $root $case.Path
    $sourceText = Get-Content -LiteralPath $sourcePath -Raw
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Controller parse failed: $($case.Path) - $($parseErrors[0].Message)" }
    foreach ($functionName in @($case.GetFunction, $case.AssertFunction, $case.TimeoutFunction, $case.WaitFunction, $case.BackgroundFunction, 'Get-LastJsonResult')) {
        $definition = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true) | Select-Object -First 1
        if ($null -eq $definition) { throw "Missing readiness function $functionName in $($case.Path)." }
        Invoke-Expression $definition.Extent.Text
    }

    $enableIndex = $sourceText.IndexOf($case.EnableMarker, [StringComparison]::Ordinal)
    $reportIndex = $sourceText.IndexOf($case.ReportMarker, $enableIndex, [StringComparison]::Ordinal)
    $backgroundIndex = $sourceText.IndexOf($case.BackgroundMarker, $reportIndex, [StringComparison]::Ordinal)
    $waitIndex = $sourceText.IndexOf($case.WaitMarker, $backgroundIndex, [StringComparison]::Ordinal)
    $readyIndex = $sourceText.IndexOf($case.ReadyMarker, $waitIndex, [StringComparison]::Ordinal)
    $handoffIndex = $sourceText.IndexOf($case.HandoffMarker, $readyIndex, [StringComparison]::Ordinal)
    if ($enableIndex -lt 0 -or $reportIndex -lt $enableIndex -or $backgroundIndex -lt $reportIndex -or
        $waitIndex -lt $backgroundIndex -or $readyIndex -lt $waitIndex -or $handoffIndex -lt $readyIndex) {
        throw "Background services are not attached before readiness polling while success evidence remains gated in $($case.Path)."
    }

    $transient = [pscustomobject]@{
        mounted = $false
        localRuntimeReady = $false
        authoritativeInventoryReady = $false
        publisherReady = $false
        ready = $false
        error = 'Mobile project view is not mounted'
    }
    $nestedJson = [pscustomobject]@{ action = 'probe'; ok = $true; report = [pscustomobject]@{ readiness = $transient } } | ConvertTo-Json -Depth 5 -Compress
    $nested = & $case.GetFunction -Output @('human-readable progress', $nestedJson)
    if ($null -eq $nested -or $nested.ready -isnot [bool] -or $nested.error -cne $transient.error) {
        throw "Nested renderer readiness was not extracted by $($case.Path)."
    }
    $legacyJson = [pscustomobject]@{ action = 'probe'; ok = $true; report = $transient } | ConvertTo-Json -Depth 4 -Compress
    $legacy = & $case.GetFunction -Output @($legacyJson)
    if ($null -eq $legacy -or $legacy.ready -isnot [bool] -or $legacy.error -cne $transient.error) {
        throw "Legacy flat readiness was not preserved by $($case.Path)."
    }
    & $case.AssertFunction -Report $transient
    $timeout = & $case.TimeoutFunction -Report $transient -TimeoutSeconds 45
    if ($timeout -notlike '*mounted=False*' -or $timeout -notlike '*Last readiness error: Mobile project view is not mounted*') {
        throw "Timeout evidence was incomplete for $($case.Path): $timeout"
    }

    $incomplete = [pscustomobject]@{
        mounted = $false
        localRuntimeReady = $false
        authoritativeInventoryReady = $false
        ready = $false
        error = 'fixture'
    }
    $rejected = $false
    try { & $case.AssertFunction -Report $incomplete } catch { $rejected = $_.Exception.Message -like '*incomplete readiness proof*' }
    if (-not $rejected) { throw "Incomplete readiness proof was accepted by $($case.Path)." }

    $readyReport = $transient.PSObject.Copy()
    foreach ($field in @('mounted','localRuntimeReady','authoritativeInventoryReady','publisherReady','ready')) { $readyReport.$field = $true }
    $readyReport.error = $null
    $readyJson = @{ report = @{ readiness = $readyReport } } | ConvertTo-Json -Depth 5 -Compress
    $attempts = @{ count = 0 }
    $retryLogs.Clear()
    $result = & $case.WaitFunction -Report $transient -TimeoutSeconds 3 -Probe {
        $attempts.count++
        if ($attempts.count -eq 1) { throw ("fixture renderer was replaced`n" + ('x' * 400)) }
        return $readyJson
    }
    if (-not $result.ready -or $attempts.count -ne 2) { throw 'A transient probe failure did not recover.' }
    if ($retryLogs.Count -ne 1 -or $retryLogs[0] -notlike '*stage=mobile-readiness probeRetry reason=fixture renderer was replaced*' -or
        $retryLogs[0] -match '[\r\n]') { throw 'A recovered probe failure did not produce one bounded, single-line retry record.' }
    $reason = $retryLogs[0].Substring($retryLogs[0].IndexOf('reason=') + 'reason='.Length)
    if ($reason.Length -ne 320) { throw 'The readiness retry diagnostic was not bounded.' }
    $failRetryLogging = $true
    $attempts.count = 0
    try {
        $result = & $case.WaitFunction -Report $transient -TimeoutSeconds 3 -Probe {
            $attempts.count++
            if ($attempts.count -eq 1) { throw 'fixture renderer was replaced while log unavailable' }
            return $readyJson
        }
        if (-not $result.ready -or $attempts.count -ne 2) { throw 'Unavailable diagnostic logging prevented readiness recovery.' }
    } finally { $failRetryLogging = $false }
    $result = & $case.WaitFunction -Report $readyReport -TimeoutSeconds 1 -Probe { throw 'A ready renderer must not be probed.' }
    if (-not $result.ready) { throw 'Initial ready evidence was not retained.' }
    $timedOut = $false
    try { & $case.WaitFunction -Report $transient -TimeoutSeconds 1 -Probe { throw 'fixture connection unavailable' } } catch {
        $timedOut = $_.Exception.Message -like '*Last probe error: fixture connection unavailable*'
    }
    if (-not $timedOut) { throw 'Readiness retries did not retain their final transport failure.' }
    $malformedRejected = $false
    try { & $case.WaitFunction -Report $transient -TimeoutSeconds 3 -Probe { '{"report":{"ready":true}}' } } catch {
        $malformedRejected = $_.Exception.Message -like '*incomplete readiness proof*'
    }
    if (-not $malformedRejected) { throw 'Malformed successful probe output was treated as a transient error.' }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-readiness-services-' + [guid]::NewGuid().ToString('N'))
$sequencePath = Join-Path $fixtureRoot 'sequence.log'
$sessionLauncher = Join-Path $fixtureRoot 'UpdateSessionLauncher.ps1'
$publisherRepair = Join-Path $fixtureRoot 'CodexRemoteMobileProject\MobileProjectStartup.ps1'
$previousSequencePath = [Environment]::GetEnvironmentVariable('CHATGPT_REMOTE_READINESS_TEST_SEQUENCE', 'Process')
try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $sessionSource = @'
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$EntryPointRelative,
    [string]$NodePath,
    [switch]$UseProxy,
    [switch]$ReplaceRunningApp,
    [switch]$SkipInitialCheck
)
[IO.File]::AppendAllText($env:CHATGPT_REMOTE_READINESS_TEST_SEQUENCE, "update$([Environment]::NewLine)")
'{"started":true}'
'@
    [IO.File]::WriteAllText($sessionLauncher, $sessionSource, [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path (Split-Path -Parent $publisherRepair) -Force | Out-Null
    $publisherRepairSource = @'
[CmdletBinding()]
param(
    [string]$Action,
    [string]$NodePath,
    [string]$LegacyPublisherScriptPath
)
if ($Action -cne 'RepairPublisher' -or [string]::IsNullOrWhiteSpace($NodePath) -or [string]::IsNullOrWhiteSpace($LegacyPublisherScriptPath)) {
    throw 'Publisher repair fixture received incomplete arguments.'
}
[IO.File]::AppendAllText($env:CHATGPT_REMOTE_READINESS_TEST_SEQUENCE, "heartbeat$([Environment]::NewLine)")
'@
    [IO.File]::WriteAllText($publisherRepair, $publisherRepairSource, [Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_READINESS_TEST_SEQUENCE', $sequencePath, 'Process')
    function Start-StartupBackgroundProcess {
        param([string]$FilePath, [object]$ArgumentList)
        [IO.File]::AppendAllText($env:CHATGPT_REMOTE_READINESS_TEST_SEQUENCE, "heartbeat$([Environment]::NewLine)")
        return [IO.MemoryStream]::new()
    }
    function Write-CommandOutput { param([object[]]$Output) foreach ($item in $Output) { Write-StartupLog ([string]$item) } }
    function Start-PublisherHeartbeat {
        param([string]$NodePath, [string]$TrustedLegacyPublisherScriptPath)
        if ([string]::IsNullOrWhiteSpace($NodePath) -or [string]::IsNullOrWhiteSpace($TrustedLegacyPublisherScriptPath)) {
            throw 'Publisher wrapper fixture received incomplete arguments.'
        }
        [IO.File]::AppendAllText($env:CHATGPT_REMOTE_READINESS_TEST_SEQUENCE, "heartbeat$([Environment]::NewLine)")
    }

    $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $stableState = [ordered]@{
            rendererPort = 9222
            launchProcessId = $PID
            executablePath = $currentProcess.MainModule.FileName
        }
    } finally { $currentProcess.Dispose() }
    $logRoot = $fixtureRoot
    [IO.File]::WriteAllText((Join-Path $logRoot 'codexremote-simple-session.json'), ($stableState | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $publisherHeartbeatHelper = Join-Path $fixtureRoot 'publisher-heartbeat.js'
    $updateSessionLauncher = $sessionLauncher
    $runtimeRoot = $fixtureRoot
    $bundleParent = $fixtureRoot
    $sourceBundleRoot = Join-Path $fixtureRoot 'CodexRemoteMobileProject'
    $sourcePackageRoot = $fixtureRoot
    $computerName = 'FIXTURE'
    $UseProxy = $false
    $ReplaceRunningApp = $false
    $SkipUpdate = $false
    $SkipUpdateCheckOnce = $false

    foreach ($case in $cases) {
        Remove-Item -LiteralPath $sequencePath -Force -ErrorAction SilentlyContinue
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $case.Path), [ref]$tokens, [ref]$parseErrors)
        $definition = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $case.BackgroundFunction
        }, $true) | Select-Object -First 1
        Invoke-Expression $definition.Extent.Text
        $started = & $case.BackgroundFunction -NodePath (Join-Path $fixtureRoot 'node.exe')
        if ($started -isnot [bool] -or -not $started) { throw 'Successful background startup did not return true.' }
        $sequence = @(Get-Content -LiteralPath $sequencePath)
        if ($sequence.Count -ne 2 -or $sequence[0] -cne 'heartbeat' -or $sequence[1] -cne 'update') {
            throw "Background services were not attached heartbeat-first for $($case.Path): $($sequence -join ', ')"
        }
        foreach ($failureResult in @('{"started":false,"reused":true,"reason":"active-coordinator-bridge-unhealthy"}', '{"started":"true"}', '{}', 'invalid-json')) {
            [IO.File]::WriteAllText($sessionLauncher, $sessionSource.Replace('{"started":true}', $failureResult), [Text.UTF8Encoding]::new($false))
            $retryLogs.Clear()
            $started = & $case.BackgroundFunction -NodePath (Join-Path $fixtureRoot 'node.exe')
            if ($started -isnot [bool] -or $started) { throw "Unavailable coordinator was reported healthy: $failureResult" }
            if (-not @($retryLogs | Where-Object { $_ -like '*update-session launch unavailable:*' }).Count) {
                throw 'Unavailable coordinator was not diagnosed.'
            }
        }
        [IO.File]::WriteAllText($sessionLauncher, $sessionSource, [Text.UTF8Encoding]::new($false))
    }
} finally {
    Remove-Item Function:\Start-StartupBackgroundProcess -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-PublisherHeartbeat -ErrorAction SilentlyContinue
    Remove-Item Function:\Write-CommandOutput -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_READINESS_TEST_SEQUENCE', $previousSequencePath, 'Process')
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    Controllers = $cases.Count
    BackgroundServicesBeforeReadiness = $true
    HeartbeatStartsBeforeUpdate = $true
    NestedRendererEnvelope = $true
    LegacyFlatEnvelope = $true
    TransientErrorsRetried = $true
    TimeoutRetainsLastError = $true
    IncompleteProofRejected = $true
} | ConvertTo-Json
