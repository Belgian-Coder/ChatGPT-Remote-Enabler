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
    'Assert-CrsNoExistingAppForReplacement'
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
    function Get-CrsCodexProcesses {
        param([string]$ExecutablePath)
        if ($ExecutablePath -in $script:fixtureExistingExecutablePaths) {
            return @([pscustomobject]@{ Id = 9999; Path = $ExecutablePath })
        }
        return @()
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

    $controllerSource = [IO.File]::ReadAllText($controllerPath)
    $guardText = 'Assert-CrsNoExistingAppForReplacement -Package $package -LaunchPackage $launchPackage -Enabled:$RefuseExistingApp'
    $guardIndex = $controllerSource.IndexOf($guardText, [StringComparison]::Ordinal)
    $stoppedIndex = $controllerSource.IndexOf('$sessionStopped = $true', $guardIndex, [StringComparison]::Ordinal)
    $stopCallIndex = $controllerSource.IndexOf('Stop-CrsCodex -ExecutablePath', $stoppedIndex, [StringComparison]::Ordinal)
    if ($guardIndex -lt 0 -or $stoppedIndex -lt $guardIndex -or $stopCallIndex -lt $stoppedIndex -or
        -not [string]::IsNullOrWhiteSpace($controllerSource.Substring($guardIndex + $guardText.Length, $stoppedIndex - ($guardIndex + $guardText.Length)))) {
        throw 'The update-resume process guard is not immediately before the replacement stop boundary.'
    }

    [pscustomobject]@{
        AtomicWrite = $true
        FailedReplacePreservedPriorState = $true
        TemporaryFilesCleaned = $true
        TruncatedStateQuarantined = $true
        SafeDiscoveryRecovered = $true
        UnknownProxyTransportRejected = $true
        PackageIdentityEnforced = $true
        RollbackFallbackPreserved = $true
        UpdateResumeRaceRefused = $true
        ReplacementGuardAtStopBoundary = $true
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
