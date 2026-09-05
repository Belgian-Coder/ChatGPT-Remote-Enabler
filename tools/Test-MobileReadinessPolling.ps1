[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$cases = @(
    [pscustomobject]@{
        Path = 'windows\CodexRemoteMobileProject\MobileProjectStartup.ps1'
        GetFunction = 'Get-MobileReport'
        AssertFunction = 'Assert-MobileReport'
        TimeoutFunction = 'Get-MobileReadinessTimeoutMessage'
    },
    [pscustomobject]@{
        Path = 'windows\Enable-ChatGPTRemote.ps1'
        GetFunction = 'Get-RemoteMobileReport'
        AssertFunction = 'Assert-RemoteMobileReport'
        TimeoutFunction = 'Get-RemoteMobileReadinessTimeoutMessage'
    }
)

foreach ($case in $cases) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $case.Path), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Controller parse failed: $($case.Path) - $($parseErrors[0].Message)" }
    foreach ($functionName in @($case.GetFunction, $case.AssertFunction, $case.TimeoutFunction)) {
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
}

[pscustomobject]@{
    Controllers = $cases.Count
    NestedRendererEnvelope = $true
    LegacyFlatEnvelope = $true
    TransientErrorsRetried = $true
    TimeoutRetainsLastError = $true
    IncompleteProofRejected = $true
} | ConvertTo-Json
