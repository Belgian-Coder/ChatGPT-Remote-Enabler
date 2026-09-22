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
    },
    [pscustomobject]@{
        Path = 'windows\Enable-ChatGPTRemote.ps1'
        GetFunction = 'Get-RemoteMobileReport'
        AssertFunction = 'Assert-RemoteMobileReport'
        TimeoutFunction = 'Get-RemoteMobileReadinessTimeoutMessage'
        WaitFunction = 'Wait-RemoteMobileReadiness'
    }
)

foreach ($case in $cases) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $case.Path), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Controller parse failed: $($case.Path) - $($parseErrors[0].Message)" }
    foreach ($functionName in @($case.GetFunction, $case.AssertFunction, $case.TimeoutFunction, $case.WaitFunction)) {
        $definition = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true) | Select-Object -First 1
        if ($null -eq $definition) { throw "Missing readiness function $functionName in $($case.Path)." }
        Invoke-Expression $definition.Extent.Text
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

[pscustomobject]@{
    Controllers = $cases.Count
    NestedRendererEnvelope = $true
    LegacyFlatEnvelope = $true
    TransientErrorsRetried = $true
    TimeoutRetainsLastError = $true
    IncompleteProofRejected = $true
} | ConvertTo-Json
