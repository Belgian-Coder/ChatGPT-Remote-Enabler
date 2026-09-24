[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$launcherSource = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\UpdateSessionLauncher.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-bundle-root-test-' + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA

function Write-FixtureFile {
    param([string]$Path, [string]$Value)

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

try {
    $installRoot = Join-Path $temporaryRoot 'installed-old'
    $candidateRoot = Join-Path $temporaryRoot 'candidate-new'
    $candidateMobileRoot = Join-Path $candidateRoot 'CodexRemoteMobileProject'
    $env:LOCALAPPDATA = Join-Path $temporaryRoot 'user-state'
    New-Item -ItemType Directory -Path $installRoot,$candidateMobileRoot,$env:LOCALAPPDATA -Force | Out-Null

    $mobileSources = [ordered]@{
        'update-session.js' = 'candidate:update-session.js'
        'update-session-cdp.js' = 'candidate:update-session-cdp.js'
        'UpdateSessionPlatform.ps1' = 'candidate:UpdateSessionPlatform.ps1'
        'coordinator-handoff.js' = 'candidate:coordinator-handoff.js'
        'RepairUpdateCoordinator.ps1' = 'candidate:RepairUpdateCoordinator.ps1'
    }
    $dependencyPaths = [ordered]@{
        'cdp.js' = 'CodexRemoteSimple\runtime\lib\cdp.js'
        'electron-attach.js' = 'CodexRemoteSimple\runtime\lib\electron-attach.js'
        'Update-ChatGPTRemote.ps1' = 'Update-ChatGPTRemote.ps1'
        'StableInstall.ps1' = 'StableInstall.ps1'
        'UnvirtualizedShortcuts.ps1' = 'UnvirtualizedShortcuts.ps1'
        'update-transaction.js' = 'update-transaction.js'
        'git-release.js' = 'git-release.js'
        'git-checkout-update.js' = 'git-checkout-update.js'
        'ProxyConfiguration.psm1' = 'CodexRemoteMobileProject\ProxyConfiguration.psm1'
    }
    foreach ($entry in $mobileSources.GetEnumerator()) {
        Write-FixtureFile -Path (Join-Path $candidateMobileRoot $entry.Key) -Value $entry.Value
    }
    foreach ($entry in $dependencyPaths.GetEnumerator()) {
        Write-FixtureFile -Path (Join-Path $installRoot $entry.Value) -Value ("installed:" + $entry.Key)
        Write-FixtureFile -Path (Join-Path $candidateRoot $entry.Value) -Value ("candidate:" + $entry.Key)
    }

    $launcherText = Get-Content -LiteralPath $launcherSource -Raw
    $tailMarker = '$node = Resolve-UpdateSessionNode'
    $tailIndex = $launcherText.IndexOf($tailMarker, [StringComparison]::Ordinal)
    if ($tailIndex -lt 1 -or $launcherText.IndexOf($tailMarker, $tailIndex + 1, [StringComparison]::Ordinal) -ge 0) {
        throw 'The update-session launcher execution boundary changed.'
    }
    $fixtureLauncher = Join-Path $candidateMobileRoot 'UpdateSessionLauncher.ps1'
$fixtureTail = @'
$bundle = Copy-ImmutableUpdateSessionBundle -Node 'unused'
$reuse = $null
$commandLinePositive = Test-CoordinatorCommandLine -CommandLine ('node.exe "{0}" --config "{1}"' -f (Join-Path $bundle 'update-session.js'), (Join-Path $env:TEMP 'session.json')) -ScriptPath (Join-Path $bundle 'update-session.js') -ConfigPath (Join-Path $env:TEMP 'session.json')
$commandLineNegative = Test-CoordinatorCommandLine -CommandLine ('node.exe "{0}.sibling" --config "{1}"' -f (Join-Path $bundle 'update-session.js'), (Join-Path $env:TEMP 'session.json')) -ScriptPath (Join-Path $bundle 'update-session.js') -ConfigPath (Join-Path $env:TEMP 'session.json')
if ($env:TEST_UPDATE_SESSION_REUSE_SCENARIO) {
    $scenario = [string]$env:TEST_UPDATE_SESSION_REUSE_SCENARIO
    $stateRoot = Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update-sessions'
    $sessionDirectory = Join-Path (Join-Path $stateRoot 'sessions') ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null
    $app = [pscustomobject][ordered]@{ pid = 14304; startTimeFileTimeUtc = '134000000000000000'; executablePath = 'C:\fixture\ChatGPT.exe'; rendererPort = 9229 }
    $coordinatorProcess = $null
    try {
        $coordinatorExecutable = [IO.Path]::GetFullPath((Get-Process -Id $PID).MainModule.FileName)
        $sessionPath = Join-Path $sessionDirectory 'session.json'
        $retainedBundle = $bundle
        if ($scenario -ceq 'retained') {
            $retainedBundle = Join-Path (Join-Path $stateRoot 'bundles') ('a' * 64)
            Copy-Item -LiteralPath $bundle -Destination $retainedBundle -Recurse -Force
        }
        $coordinatorScript = Join-Path $retainedBundle 'update-session.js'
        $processStartInfo = New-Object Diagnostics.ProcessStartInfo
        $processStartInfo.FileName = $coordinatorExecutable
        $processStartInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -NoExit -Command "Start-Sleep -Seconds 60" "' + $coordinatorScript + '" --config "' + $sessionPath + '"'
        $processStartInfo.UseShellExecute = $false
        $processStartInfo.CreateNoWindow = $true
        $coordinatorProcess = [Diagnostics.Process]::Start($processStartInfo)
        Start-Sleep -Milliseconds 150
        $coordinatorProcess.Refresh()
        $coordinatorStart = $coordinatorProcess.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        $config = [ordered]@{
            schemaVersion = 1; platform = 'win32'; installRoot = $InstallRoot; stateRoot = $stateRoot; sessionDirectory = $sessionDirectory
            updaterPath = Join-Path $retainedBundle 'Update-ChatGPTRemote.ps1'; platformHelperPath = Join-Path $retainedBundle 'UpdateSessionPlatform.ps1'; rendererPort = $app.rendererPort
            autoCheckEnabled = $scenario -cne 'auto-mismatch'; skipInitialCheck = $true; relaunch = [ordered]@{ entryPointRelative = 'Enable-ChatGPTRemote.ps1'; useProxy = [bool]($scenario -in @('mismatch', 'legacy-mismatch')); replaceRunningApp = $false }
            app = $app; launchReceipt = [ordered]@{ path = Join-Path $sessionDirectory 'coordinator-ready.json'; identityPath = Join-Path $sessionDirectory 'coordinator-identity.json' }
        }
        $state = [ordered]@{ schemaVersion = 1; sessionId = [IO.Path]::GetFileName($sessionDirectory); bundleHash = [IO.Path]::GetFileName($retainedBundle); coordinatorPid = $coordinatorProcess.Id; coordinatorIdentity = [ordered]@{ pid = $coordinatorProcess.Id; startToken = $coordinatorStart; executablePath = $coordinatorExecutable }; phase = 'active'; heartbeatAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        if ($scenario -ceq 'stale') { $state.heartbeatAtUnixMs = [DateTimeOffset]::UtcNow.AddSeconds(-20).ToUnixTimeMilliseconds() }
        if ($scenario -cnotin @('legacy-health', 'legacy-mismatch')) {
            $state.rendererConnected = $true
            $state.rendererProofAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }
        if ($scenario -ceq 'stale-renderer') { $state.rendererProofAtUnixMs = [DateTimeOffset]::UtcNow.AddSeconds(-20).ToUnixTimeMilliseconds() }
        if ($scenario -ceq 'degraded') { $state.phase = 'degraded'; $state.rendererConnected = $false }
        [IO.File]::WriteAllText($sessionPath, (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sessionDirectory 'coordinator-state.json'), (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $lockPath = Get-UpdateSessionLockPath -StateRoot $stateRoot -App $app
        New-Item -ItemType Directory -Path (Split-Path -Parent $lockPath) -Force | Out-Null
        $owner = [ordered]@{ pid = $coordinatorProcess.Id; startToken = $coordinatorStart; executablePath = $coordinatorExecutable }
        if ($scenario -ceq 'foreign') { $owner = [ordered]@{ pid = $PID; startToken = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture); executablePath = [IO.Path]::GetFullPath((Get-Process -Id $PID).MainModule.FileName) } }
        [IO.File]::WriteAllText($lockPath, (($owner | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        $reuse = Find-ReusableUpdateSession -StateRoot $stateRoot -InstallRoot $InstallRoot -BundleRoot $bundle -Identity $app -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -UseProxy:$false -ReplaceRunningApp:$false -AutoCheckEnabled:$true
    } finally {
        if ($coordinatorProcess) { try { if (-not $coordinatorProcess.HasExited) { $coordinatorProcess.Kill() } } catch {} ; $coordinatorProcess.Dispose() }
    }
}
[pscustomobject][ordered]@{
    bundlePath = $bundle
    bundleRoot = $BundleRoot
    installRoot = $InstallRoot
    commandLinePositive = $commandLinePositive
    commandLineNegative = $commandLineNegative
    reuse = $reuse
} | ConvertTo-Json -Compress
'@
    Write-FixtureFile -Path $fixtureLauncher -Value ($launcherText.Substring(0, $tailIndex) + $fixtureTail)

    $defaultResult = & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$defaultResult.installRoot), [IO.Path]::GetFullPath($installRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$defaultResult.bundleRoot), [IO.Path]::GetFullPath($installRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The default bundle root no longer preserves the installed-root behavior.'
    }
    foreach ($entry in $mobileSources.GetEnumerator()) {
        if ((Get-Content -LiteralPath (Join-Path $defaultResult.bundlePath $entry.Key) -Raw) -cne $entry.Value) {
            throw "The default snapshot did not use the launcher-owned $($entry.Key)."
        }
    }
    foreach ($entry in $dependencyPaths.GetEnumerator()) {
        if ((Get-Content -LiteralPath (Join-Path $defaultResult.bundlePath $entry.Key) -Raw) -cne ("installed:" + $entry.Key)) {
            throw "The default snapshot did not preserve the installed $($entry.Key)."
        }
    }

    $explicitResult = & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -BundleRoot $candidateRoot | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$explicitResult.installRoot), [IO.Path]::GetFullPath($installRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$explicitResult.bundleRoot), [IO.Path]::GetFullPath($candidateRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'An explicit bundle root changed the target install root or was not retained.'
    }
    foreach ($entry in $mobileSources.GetEnumerator()) {
        if ((Get-Content -LiteralPath (Join-Path $explicitResult.bundlePath $entry.Key) -Raw) -cne $entry.Value) {
            throw "The explicit snapshot did not use the launcher-owned $($entry.Key)."
        }
    }
    foreach ($entry in $dependencyPaths.GetEnumerator()) {
        if ((Get-Content -LiteralPath (Join-Path $explicitResult.bundlePath $entry.Key) -Raw) -cne ("candidate:" + $entry.Key)) {
            throw "The explicit snapshot did not use the candidate $($entry.Key)."
        }
    }
    if ([string]::Equals([string]$defaultResult.bundlePath, [string]$explicitResult.bundlePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Different dependency engines unexpectedly produced the same immutable bundle.'
    }
    if (-not $defaultResult.commandLinePositive -or $defaultResult.commandLineNegative) {
        throw 'Coordinator command-line binding did not distinguish the immutable script and session configuration.'
    }
    $reuseScenarios = [ordered]@{}
    foreach ($scenario in @('healthy', 'retained', 'stale', 'foreign', 'mismatch', 'auto-mismatch', 'legacy-health', 'legacy-mismatch', 'stale-renderer', 'degraded')) {
        $previousScenario = $env:TEST_UPDATE_SESSION_REUSE_SCENARIO
        try {
            $env:TEST_UPDATE_SESSION_REUSE_SCENARIO = $scenario
            $reuseScenarios[$scenario] = & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' | ConvertFrom-Json
        } finally { $env:TEST_UPDATE_SESSION_REUSE_SCENARIO = $previousScenario }
    }
    if (-not $reuseScenarios.healthy.reuse.Compatible -or
        -not $reuseScenarios.retained.reuse.Compatible -or
        $reuseScenarios.retained.reuse.BundleMatchesRequested -or
        $null -ne $reuseScenarios.stale.reuse -or
        $null -ne $reuseScenarios.foreign.reuse -or
        $reuseScenarios.mismatch.reuse.Compatible -or
        [string]$reuseScenarios.mismatch.reuse.Reason -cne 'active-coordinator-context-mismatch' -or
        $reuseScenarios.'auto-mismatch'.reuse.Compatible -or
        [string]$reuseScenarios.'auto-mismatch'.reuse.Reason -cne 'active-coordinator-context-mismatch') {
        throw 'Coordinator reuse did not fail closed for stale, foreign, or incompatible ownership.'
    }
    foreach ($scenario in @('legacy-health', 'stale-renderer', 'degraded')) {
        $candidate = $reuseScenarios[$scenario].reuse
        if ($null -eq $candidate -or $candidate.Compatible -or $candidate.Reason -cne 'active-coordinator-bridge-unhealthy') {
            throw "An owned $scenario coordinator must report its unhealthy bridge without being bypassed by a duplicate."
        }
    }
    if ($reuseScenarios.'legacy-mismatch'.reuse.Compatible -or
        $reuseScenarios.'legacy-mismatch'.reuse.ContextMatches -or
        [string]$reuseScenarios.'legacy-mismatch'.reuse.Reason -cne 'active-coordinator-context-mismatch') {
        throw 'A context-mismatched legacy coordinator was incorrectly treated as compatible.'
    }
    if (-not $reuseScenarios.'legacy-health'.reuse.LegacyRepairEligible -or
        -not $reuseScenarios.'legacy-mismatch'.reuse.LegacyRepairEligible -or
        $reuseScenarios.'stale-renderer'.reuse.LegacyRepairEligible -or
        $reuseScenarios.degraded.reuse.LegacyRepairEligible) {
        throw 'Legacy repair eligibility did not remain limited to an owned active coordinator without renderer-health fields or became tied to relaunch context.'
    }
    Write-FixtureFile -Path (Join-Path $candidateRoot 'git-release.js') -Value 'candidate:git-release.js:changed'
    $helperChangedResult = & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -BundleRoot $candidateRoot | ConvertFrom-Json
    if ([string]::Equals([string]$explicitResult.bundlePath, [string]$helperChangedResult.bundlePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A Git helper change did not change the immutable update-session bundle fingerprint.'
    }
    if ((Get-Content -LiteralPath (Join-Path $helperChangedResult.bundlePath 'git-release.js') -Raw) -cne 'candidate:git-release.js:changed') {
        throw 'The Git helper fingerprint selected a snapshot without the changed helper.'
    }

    foreach ($relative in @('Update-ChatGPTRemote.ps1', 'StableInstall.ps1', 'update-transaction.js', 'git-release.js', 'git-checkout-update.js')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot "windows\$relative") -Destination (Join-Path $candidateRoot $relative) -Force
    }
    $actualResult = & $fixtureLauncher -InstallRoot $candidateRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -BundleRoot $candidateRoot | ConvertFrom-Json
    $actualUpdater = Join-Path $actualResult.bundlePath 'Update-ChatGPTRemote.ps1'
    $shell = if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -PathType Leaf) {
        Join-Path $PSHOME 'pwsh.exe'
    } elseif ($env:SystemRoot) {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        throw 'No PowerShell host is available for the detached Git helper resolution fixture.'
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $actualOutput = @(& $shell -NoProfile -NonInteractive -File $actualUpdater -Action Check -InstallRoot $candidateRoot -Transport Git -Repository invalid 2>&1)
        $actualExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $actualText = [string]::Join([Environment]::NewLine, @($actualOutput | ForEach-Object { [string]$_ }))
    if ($actualExitCode -eq 0 -or $actualText -notmatch 'Repository must use a validated owner/name form') {
        throw "The detached updater did not resolve and execute its real Git release helper: $actualText"
    }
    $mixedRootRejected = $false
    try {
        & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -BundleRoot $installRoot | Out-Null
    } catch {
        $mixedRootRejected = $_.Exception.Message -match 'does not own this launcher'
    }
    if (-not $mixedRootRejected) { throw 'An explicit root from a different launcher tree was not rejected.' }

    $global:LASTEXITCODE = 0
    [pscustomobject][ordered]@{
        DefaultUsesInstallRootDependencies = $true
        ExplicitUsesCandidateDependencies = $true
        InstallRootRemainsTarget = $true
        LauncherOwnedControllerFiles = $true
        GitUpdaterHelpersBundled = $true
        GitHelperChangesFingerprint = $true
        DetachedUpdaterResolvesRealGitHelper = $true
        DistinctImmutableBundles = $true
        MixedExplicitRootRejected = $true
        CoordinatorCommandLineBinding = $true
        HealthyCoordinatorReuse = $true
        RetainedBundleReuseReported = $true
        StaleAndForeignCoordinatorRejected = $true
        IncompatibleCoordinatorReported = $true
    } | ConvertTo-Json -Compress
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^chatgpt-remote-bundle-root-test-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath $resolved -PathType Container)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
