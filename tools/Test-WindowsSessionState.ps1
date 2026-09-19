[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$controllerPath = Join-Path $root 'windows\CodexRemoteSimple\CodexRemoteSimple.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($controllerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Stable controller parse failed: $($errors[0].Message)" }

$functionNames = @(
    'Move-CrsDamagedState',
    'Read-CrsState',
    'Write-CrsState',
    'Get-CrsDiscoverableSession',
    'Test-CrsProxyModeProof',
    'Assert-CrsNoExistingAppForReplacement',
    'Get-CrsProcessIdentity',
    'Test-CrsExpectedDebugProcess',
    'Get-CrsOwnedProcessIdentity',
    'Stop-CrsCodex',
    'Assert-CrsNoUnownedCodexProcess'
)
$definitions = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $functionNames
}, $true)
foreach ($functionName in $functionNames) {
    $definition = $definitions | Where-Object Name -eq $functionName | Select-Object -First 1
    if (-not $definition) { throw "Stable controller function is missing: $functionName" }
    Invoke-Expression $definition.Extent.Text
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-state-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $script:StateRoot = $temporaryRoot
    $script:StatePath = Join-Path $temporaryRoot 'codexremote-simple-session.json'
    $script:LegacyStatePath = Join-Path $temporaryRoot 'legacy-session.json'

    $package = [pscustomobject]@{
        FullName = 'OpenAI.Codex_fixture'
        Version = '1.2.3.4'
        ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
    }
    $probe = [pscustomobject]@{ appAsarSha256 = ('a' * 64) }
    $launch = [pscustomobject]@{ Method = 'fixture'; ProcessId = 4242 }

    Write-CrsState -Package $package -RendererPort 24547 -MainPort $null -Probe $probe -Launch $launch -ProxyMode $false -BridgeMode 'native-renderer'
    $writtenBytes = [IO.File]::ReadAllBytes($script:StatePath)
    if ($writtenBytes.Length -lt 2 -or ($writtenBytes[0] -eq 0xEF -and $writtenBytes[1] -eq 0xBB)) {
        throw 'Atomic state writer did not produce BOM-free UTF-8 JSON.'
    }
    $written = Read-CrsState
    if (-not $written -or $written.rendererPort -ne 24547 -or $written.proxyMode -ne $false -or
        $written.bridgeMode -ne 'native-renderer') {
        throw 'Atomic state writer did not produce a readable durable session record.'
    }
    if (@(Get-ChildItem -LiteralPath $temporaryRoot -Filter '*.tmp').Count -ne 0) {
        throw 'Atomic state writer left a temporary file after success.'
    }

    Write-CrsState -Package $package -RendererPort 24548 -MainPort $null -Probe $probe -Launch $launch -ProxyMode $false -BridgeMode 'native-renderer'
    $replaced = Read-CrsState
    if (-not $replaced -or $replaced.rendererPort -ne 24548) {
        throw 'Atomic state writer did not replace an existing durable session record.'
    }
    if (@(Get-ChildItem -LiteralPath $temporaryRoot -Filter '.codexremote-simple-session.*').Count -ne 0) {
        throw 'Atomic state replacement left a temporary or replacement-backup file after success.'
    }

    $beforeFailedWrite = [IO.File]::ReadAllText($script:StatePath)
    $lock = [IO.File]::Open($script:StatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $failedAsExpected = $false
    try {
        try {
            Write-CrsState -Package $package -RendererPort 24549 -MainPort $null -Probe $probe -Launch $launch -ProxyMode $false -BridgeMode 'native-renderer'
        } catch {
            $failedAsExpected = $true
        }
    } finally {
        $lock.Dispose()
    }
    if (-not $failedAsExpected) { throw 'A forced atomic replacement failure unexpectedly succeeded.' }
    if ([IO.File]::ReadAllText($script:StatePath) -cne $beforeFailedWrite) {
        throw 'A failed atomic replacement changed the prior durable state.'
    }
    if (@(Get-ChildItem -LiteralPath $temporaryRoot -Filter '*.tmp').Count -ne 0) {
        throw 'Atomic state writer left a temporary file after failure.'
    }

    $truncated = '{"schemaVersion":2,"bridgeMode":"native-renderer"'
    [IO.File]::WriteAllText($script:StatePath, $truncated, [Text.UTF8Encoding]::new($false))
    $priorWarningPreference = $WarningPreference
    $WarningPreference = 'SilentlyContinue'
    try {
        $afterDamage = Read-CrsState
    } finally {
        $WarningPreference = $priorWarningPreference
    }
    if ($null -ne $afterDamage -or (Test-Path -LiteralPath $script:StatePath)) {
        throw 'A truncated session record was not removed from the active state path.'
    }
    $quarantined = @(Get-ChildItem -LiteralPath $temporaryRoot -Filter 'codexremote-simple-session.damaged-*.json')
    if ($quarantined.Count -ne 1 -or [IO.File]::ReadAllText($quarantined[0].FullName) -cne $truncated) {
        throw 'A truncated session record was not preserved exactly in quarantine.'
    }

    $validProcess = [pscustomobject]@{
        ProcessId = 4343
        ExecutablePath = $package.ExecutablePath
        CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=24547'
    }
    $openPort = { param([int]$Port) return $Port -eq 24547 }
    $discovered = Get-CrsDiscoverableSession -Package $package -BridgeMode 'native-renderer' -Processes @($validProcess) -PortTester $openPort
    if (-not $discovered -or $discovered.proxyMode -ne $false -or
        -not (Test-CrsProxyModeProof -State $discovered -RequestedProxyMode $false)) {
        throw 'Safe direct-mode discovery did not recover after quarantining damaged state.'
    }
    $unknownProxy = [pscustomobject]@{
        bridgeMode = 'native-renderer'
        proxyMode = $true
        proxyTransport = 'unknown-proxy-transport'
    }
    if (Test-CrsProxyModeProof -State $unknownProxy -RequestedProxyMode $true) {
        throw 'An unknown proxy transport was accepted for session adoption.'
    }
    $unknownDirect = [pscustomobject]@{
        bridgeMode = 'native-renderer'
        proxyMode = $false
        proxyTransport = 'unknown-proxy-transport'
    }
    if (Test-CrsProxyModeProof -State $unknownDirect -RequestedProxyMode $false) {
        throw 'An unknown proxy transport was accepted under a direct-mode label.'
    }
    $wrongProcess = $validProcess.PSObject.Copy()
    $wrongProcess.ExecutablePath = 'C:\Untrusted\ChatGPT.exe'
    if (Get-CrsDiscoverableSession -Package $package -BridgeMode 'native-renderer' -Processes @($wrongProcess) -PortTester $openPort) {
        throw 'A process outside the expected package executable was accepted for session adoption.'
    }

    [IO.File]::WriteAllText($script:StatePath, '{"schemaVersion":', [Text.UTF8Encoding]::new($false))
    $priorWarningPreference = $WarningPreference
    $WarningPreference = 'SilentlyContinue'
    try {
        $rollbackState = Read-CrsState -AllowInvalid
    } finally {
        $WarningPreference = $priorWarningPreference
    }
    if ($null -ne $rollbackState -or (Test-Path -LiteralPath $script:StatePath) -or
        @(Get-ChildItem -LiteralPath $temporaryRoot -Filter 'codexremote-simple-session.damaged-*.json').Count -ne 2) {
        throw 'Rollback did not retain its damaged-state fallback while preserving the record in quarantine.'
    }

    $script:fixtureExistingExecutablePaths = @()
    $script:fixtureProcessIdentities = @()
    function Get-CrsCodexProcesses {
        param([string]$ExecutablePath)
        $identities = @($script:fixtureProcessIdentities | Where-Object {
            [string]::Equals([string]$_.ExecutablePath, $ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($identities.Count -gt 0) {
            return @($identities | ForEach-Object { [pscustomobject]@{ Id = [int]$_.ProcessId; Path = [string]$_.ExecutablePath } })
        }
        if ($ExecutablePath -in $script:fixtureExistingExecutablePaths) {
            return @([pscustomobject]@{ Id = 9999; Path = $ExecutablePath })
        }
        return @()
    }
    $script:fixtureLiveIdentity = $null
    $script:fixtureStopCalls = [Collections.Generic.List[object]]::new()
    function Get-CrsProcessIdentity {
        param([int]$ProcessId, [string]$ExecutablePath)
        $fixtureIdentity = @($script:fixtureProcessIdentities | Where-Object {
            [int]$_.ProcessId -eq $ProcessId -and
            [string]::Equals([string]$_.ExecutablePath, $ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($fixtureIdentity.Count -eq 1) { return $fixtureIdentity[0] }
        if ($null -eq $script:fixtureLiveIdentity -or
            [int]$script:fixtureLiveIdentity.ProcessId -ne $ProcessId -or
            -not [string]::Equals([string]$script:fixtureLiveIdentity.ExecutablePath, $ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return $script:fixtureLiveIdentity
    }
    function Stop-Process {
        [CmdletBinding()]
        param([int]$Id, [switch]$Force)
        $script:fixtureStopCalls.Add([pscustomobject]@{ Id = $Id; Force = [bool]$Force })
        if (-not $Force) { $script:fixtureLiveIdentity = $null }
    }
    $privatePackage = [pscustomobject]@{ ExecutablePath = 'C:\Fixture\Private\ChatGPT.exe' }
    $script:fixtureExistingExecutablePaths = @([string]$package.ExecutablePath)
    Assert-CrsNoExistingAppForReplacement -Package $package -LaunchPackage $privatePackage
    $canonicalRefused = $false
    try {
        Assert-CrsNoExistingAppForReplacement -Package $package -LaunchPackage $privatePackage -Enabled
    } catch {
        $canonicalRefused = $true
    }
    $script:fixtureExistingExecutablePaths = @([string]$privatePackage.ExecutablePath)
    $privateRefused = $false
    try {
        Assert-CrsNoExistingAppForReplacement -Package $package -LaunchPackage $privatePackage -Enabled
    } catch {
        $privateRefused = $true
    }
    $script:fixtureExistingExecutablePaths = @()
    Assert-CrsNoExistingAppForReplacement -Package $package -LaunchPackage $privatePackage -Enabled
    if (-not $canonicalRefused -or -not $privateRefused) {
        throw 'Update resume did not refuse a newly appeared exact executable process.'
    }

    $samePathUnrelated = [pscustomobject]@{
        ProcessId = 5001
        ExecutablePath = [string]$package.ExecutablePath
        StartTimeFileTimeUtc = 7001L
        ProcessOwned = $true
    }
    $script:fixtureLiveIdentity = $null
    $script:fixtureStopCalls.Clear()
    $script:fixtureExistingExecutablePaths = @([string]$package.ExecutablePath)
    if (Stop-CrsCodex -Ownership $samePathUnrelated) {
        throw 'A same-path process without the owned PID and start token was treated as stoppable.'
    }
    if ($script:fixtureStopCalls.Count -ne 0) {
        throw 'A same-path unrelated process received a lifecycle signal.'
    }
    $unownedRejected = $false
    try {
        Assert-CrsNoUnownedCodexProcess -ExecutablePaths @([string]$package.ExecutablePath) -OwnedProcess $null
    } catch {
        $unownedRejected = $true
    }
    if (-not $unownedRejected) {
        throw 'An existing same-path process without ownership evidence was not rejected before replacement.'
    }

    $ownedAmongUnrelated = [pscustomobject]@{
        ProcessId = 5005
        ExecutablePath = [string]$package.ExecutablePath
        StartTimeFileTimeUtc = 7005L
        ProcessOwned = $true
    }
    $script:fixtureProcessIdentities = @(
        $ownedAmongUnrelated,
        [pscustomobject]@{
            ProcessId = 5006
            ExecutablePath = [string]$package.ExecutablePath
            StartTimeFileTimeUtc = 7006L
        }
    )
    $additionalUnownedRejected = $false
    try {
        Assert-CrsNoUnownedCodexProcess -ExecutablePaths @([string]$package.ExecutablePath) -OwnedProcess $ownedAmongUnrelated
    } catch {
        $additionalUnownedRejected = $true
    }
    $script:fixtureProcessIdentities = @()
    if (-not $additionalUnownedRejected) {
        throw 'An additional unowned same-path main process was hidden by the owned process.'
    }

    $exactDebugReader = {
        param([int]$Id)
        [pscustomobject]@{
            ProcessId = $Id
            ExecutablePath = [string]$package.ExecutablePath
            CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=24547'
        }
    }
    $unrelatedReader = {
        param([int]$Id)
        [pscustomobject]@{
            ProcessId = $Id
            ExecutablePath = [string]$package.ExecutablePath
            CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe"'
        }
    }
    if (-not (Test-CrsExpectedDebugProcess -ProcessId 5007 -ExecutablePath ([string]$package.ExecutablePath) -ExpectedPort 24547 -ProcessReader $exactDebugReader) -or
        (Test-CrsExpectedDebugProcess -ProcessId 5008 -ExecutablePath ([string]$package.ExecutablePath) -ExpectedPort 24547 -ProcessReader $unrelatedReader)) {
        throw 'Package activation ownership did not require the exact requested debug address and port.'
    }

    $pidReuse = [pscustomobject]@{
        ProcessId = 5002
        ExecutablePath = [string]$package.ExecutablePath
        StartTimeFileTimeUtc = 7002L
        ProcessOwned = $true
    }
    $script:fixtureExistingExecutablePaths = @()
    $script:fixtureLiveIdentity = [pscustomobject]@{
        ProcessId = 5002
        ExecutablePath = [string]$package.ExecutablePath
        StartTimeFileTimeUtc = 7003L
    }
    $script:fixtureStopCalls.Clear()
    if (Stop-CrsCodex -Ownership $pidReuse) {
        throw 'A PID reused with a different start token was treated as helper-owned.'
    }
    if ($script:fixtureStopCalls.Count -ne 0) {
        throw 'A PID reuse/start-token mismatch received a lifecycle signal.'
    }

    $exactOwned = [pscustomobject]@{
        ProcessId = 5003
        ExecutablePath = [string]$package.ExecutablePath
        StartTimeFileTimeUtc = 7004L
        ProcessOwned = $true
    }
    $script:fixtureLiveIdentity = [pscustomobject]@{
        ProcessId = 5003
        ExecutablePath = [string]$package.ExecutablePath
        StartTimeFileTimeUtc = 7004L
    }
    $script:fixtureStopCalls.Clear()
    if (-not (Stop-CrsCodex -Ownership $exactOwned)) {
        throw 'The exact helper-owned process was not stopped.'
    }
    if ($script:fixtureStopCalls.Count -ne 1 -or
        [int]$script:fixtureStopCalls[0].Id -ne 5003 -or
        [bool]$script:fixtureStopCalls[0].Force) {
        throw 'The exact helper-owned process did not receive one normal lifecycle stop.'
    }

    $controllerSource = [IO.File]::ReadAllText($controllerPath)
    $guardText = 'Assert-CrsNoExistingAppForReplacement -Package $package -LaunchPackage $launchPackage -Enabled:$RefuseExistingApp'
    $guardIndex = $controllerSource.IndexOf($guardText, [StringComparison]::Ordinal)
    $stoppedIndex = $controllerSource.IndexOf('$sessionStopped = $true', $guardIndex, [StringComparison]::Ordinal)
    $stopCallIndex = $controllerSource.IndexOf('Stop-CrsCodex -Ownership', $stoppedIndex, [StringComparison]::Ordinal)
    if ($guardIndex -lt 0 -or $stoppedIndex -lt $guardIndex -or $stopCallIndex -lt $stoppedIndex -or
        -not [string]::IsNullOrWhiteSpace($controllerSource.Substring($guardIndex + $guardText.Length, $stoppedIndex - ($guardIndex + $guardText.Length)))) {
        throw 'The update-resume process guard is not immediately before the replacement stop boundary.'
    }
    if ($controllerSource.Contains('Stop-CrsCodex -ExecutablePath')) {
        throw 'The stable controller still contains a path-wide ChatGPT stop call.'
    }

    [pscustomobject]@{
        AtomicWrite = $true
        ExistingStateReplaced = $true
        FailedReplacePreservedPriorState = $true
        TemporaryFilesCleaned = $true
        TruncatedStateQuarantined = $true
        SafeDiscoveryRecovered = $true
        UnknownProxyTransportRejected = $true
        PackageIdentityEnforced = $true
        RollbackFallbackPreserved = $true
        UpdateResumeRaceRefused = $true
        ReplacementGuardAtStopBoundary = $true
        SamePathUnrelatedProcessUntouched = $true
        AdditionalSamePathProcessRejected = $true
        ActivationDebugArgumentsRequired = $true
        PidReuseStartTokenMismatchRejected = $true
        ExactOwnedProcessStopped = $true
    } | ConvertTo-Json -Compress
} finally {
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ((Test-Path -LiteralPath $resolved) -and
        [IO.Path]::GetFullPath((Split-Path -Parent $resolved)) -eq $temporary -and
        [IO.Path]::GetFileName($resolved) -match '^chatgpt-remote-state-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
