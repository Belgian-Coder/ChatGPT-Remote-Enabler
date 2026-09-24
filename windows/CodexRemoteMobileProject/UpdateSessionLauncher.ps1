[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallRoot,
    [Parameter(Mandatory)]
    [ValidateSet('Enable-ChatGPTRemote.ps1', 'CodexRemoteMobileProject\MobileProjectStartup.ps1')]
    [string]$EntryPointRelative,
    [string]$NodePath,
    [switch]$UseProxy,
    [switch]$ReplaceRunningApp,
    [switch]$SkipInitialCheck,
    [string]$BundleRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$bundleRootSpecified = -not [string]::IsNullOrWhiteSpace($BundleRoot)
if (-not $bundleRootSpecified) {
    $BundleRoot = $InstallRoot
} elseif (-not [IO.Path]::IsPathRooted($BundleRoot)) {
    throw 'The update-session bundle root must be an absolute path.'
} else {
    $BundleRoot = [IO.Path]::GetFullPath($BundleRoot)
}
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if ($bundleRootSpecified -and
    -not [string]::Equals($sourceRoot, [IO.Path]::GetFullPath((Join-Path $BundleRoot 'CodexRemoteMobileProject')), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The explicit update-session bundle root does not own this launcher.'
}
$stateRoot = Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update-sessions'
$stableStatePath = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures') 'codexremote-simple-session.json'

function Resolve-UpdateSessionNode {
    if ($NodePath -and (Test-Path -LiteralPath $NodePath -PathType Leaf)) { return [IO.Path]::GetFullPath($NodePath) }
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    foreach ($candidate in @(
        $(if ($command) { $command.Source }),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        'C:\Program Files\nodejs\node.exe'
    ) | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        & $candidate -e 'process.exit(parseInt(process.versions.node) >= 22 && globalThis.WebSocket ? 0 : 1)' 2>$null
        if ($LASTEXITCODE -eq 0) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw 'Node.js 22 or newer with built-in WebSocket support was not found for the update session.'
}

function Get-ExactAppIdentity {
    if (-not (Test-Path -LiteralPath $stableStatePath -PathType Leaf)) {
        throw 'The stable special-session record is missing after launch.'
    }
    $state = Get-Content -LiteralPath $stableStatePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $port = 0
    if (-not [int]::TryParse([string]$state.rendererPort, [ref]$port) -or $port -lt 1024 -or $port -gt 65535 -or
        [string]::IsNullOrWhiteSpace([string]$state.executablePath)) {
        throw 'The stable special-session record does not identify a renderer and executable.'
    }
    $expectedPath = [IO.Path]::GetFullPath([string]$state.executablePath)
    $attached = $null -ne $state.PSObject.Properties['launchMethod'] -and $state.launchMethod -ceq 'attached-existing-process'
    if ($attached -and ($null -eq $state.PSObject.Properties['launchProcessId'] -or
        $null -eq $state.PSObject.Properties['launchProcessStartTimeFileTimeUtc'] -or
        [long]$state.launchProcessStartTimeFileTimeUtc -le 0)) { throw 'The attached app session is missing its exact process identity.' }
    $candidates = @(
        Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction Stop |
            Where-Object {
                [string]::Equals([string]$_.ExecutablePath, $expectedPath, [StringComparison]::OrdinalIgnoreCase) -and
                [string]$_.CommandLine -notmatch '(?:^|\s)--type=' -and
                (($attached -and [int]$_.ProcessId -eq [int]$state.launchProcessId) -or
                 (-not $attached -and [string]$_.CommandLine -match "(?:^|\s)--remote-debugging-port(?:=|\s+)$port(?:\s|$)"))
            }
    )
    if ($candidates.Count -ne 1) { throw "Expected one exact ChatGPT application process for renderer port $port; found $($candidates.Count)." }
    $process = [Diagnostics.Process]::GetProcessById([int]$candidates[0].ProcessId)
    try {
        $actualPath = [IO.Path]::GetFullPath($process.MainModule.FileName)
        if (-not [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The exact ChatGPT process path changed during update-session capture.'
        }
        if ($attached -and $process.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [long]$state.launchProcessStartTimeFileTimeUtc) {
            throw 'The attached ChatGPT process changed during update-session capture.'
        }
        return [pscustomobject][ordered]@{
            pid = $process.Id
            startTimeFileTimeUtc = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
            executablePath = $actualPath
            rendererPort = $port
        }
    } finally {
        $process.Dispose()
    }
}

function Copy-ImmutableUpdateSessionBundle {
    param([string]$Node)
    $sources = [ordered]@{
        'update-session.js' = Join-Path $sourceRoot 'update-session.js'
        'update-session-cdp.js' = Join-Path $sourceRoot 'update-session-cdp.js'
        'coordinator-handoff.js' = Join-Path $sourceRoot 'coordinator-handoff.js'
        'RepairUpdateCoordinator.ps1' = Join-Path $sourceRoot 'RepairUpdateCoordinator.ps1'
        'UpdateSessionPlatform.ps1' = Join-Path $sourceRoot 'UpdateSessionPlatform.ps1'
        'cdp.js' = Join-Path $BundleRoot 'CodexRemoteSimple\runtime\lib\cdp.js'
        'electron-attach.js' = Join-Path $BundleRoot 'CodexRemoteSimple\runtime\lib\electron-attach.js'
        'Update-ChatGPTRemote.ps1' = Join-Path $BundleRoot 'Update-ChatGPTRemote.ps1'
        'StableInstall.ps1' = Join-Path $BundleRoot 'StableInstall.ps1'
        'UnvirtualizedShortcuts.ps1' = Join-Path $BundleRoot 'UnvirtualizedShortcuts.ps1'
        'update-transaction.js' = Join-Path $BundleRoot 'update-transaction.js'
        'git-release.js' = Join-Path $BundleRoot 'git-release.js'
        'git-checkout-update.js' = Join-Path $BundleRoot 'git-checkout-update.js'
        'ProxyConfiguration.psm1' = Join-Path $BundleRoot 'CodexRemoteMobileProject\ProxyConfiguration.psm1'
    }
    foreach ($source in $sources.Values) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Update-session dependency is missing: $source" }
    }
    $fingerprint = foreach ($entry in $sources.GetEnumerator()) {
        "$($entry.Key):$((Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    $fingerprintPath = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-session-fingerprint-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($fingerprintPath, ($fingerprint -join "`n"), [Text.UTF8Encoding]::new($false))
        $bundleHash = (Get-FileHash -LiteralPath $fingerprintPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally {
        Remove-Item -LiteralPath $fingerprintPath -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $destination = Join-Path (Join-Path $stateRoot 'bundles') $bundleHash
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        $temporary = Join-Path (Join-Path $stateRoot 'bundles') ('.pending-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporary -Force | Out-Null
        try {
            foreach ($entry in $sources.GetEnumerator()) {
                Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $temporary $entry.Key)
                $actual = (Get-FileHash -LiteralPath (Join-Path $temporary $entry.Key) -Algorithm SHA256).Hash
                $expected = (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash
                if ($actual -ne $expected) { throw "Detached update-session copy verification failed: $($entry.Key)" }
            }
            try { Move-Item -LiteralPath $temporary -Destination $destination -ErrorAction Stop }
            catch {
                if (-not (Test-Path -LiteralPath $destination -PathType Container)) { throw }
            }
        } finally {
            if ((Test-Path -LiteralPath $temporary -PathType Container) -and
                [IO.Path]::GetFullPath((Split-Path -Parent $temporary)) -eq [IO.Path]::GetFullPath((Join-Path $stateRoot 'bundles')) -and
                [IO.Path]::GetFileName($temporary) -match '^\.pending-[0-9a-f]{32}$') {
                Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($entry in $sources.GetEnumerator()) {
        $copied = Join-Path $destination $entry.Key
        if (-not (Test-Path -LiteralPath $copied -PathType Leaf) -or
            (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash) {
            throw "Detached update-session bundle is incomplete: $($entry.Key)"
        }
    }
    return $destination
}

function Get-JsonPropertyValue {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-NormalizedExistingPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { return [IO.Path]::GetFullPath($Path) } catch { return $null }
}

function Test-PlainExistingFile {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return -not $item.PSIsContainer -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
    } catch { return $false }
}

function Get-UpdateSessionLockPath {
    param([Parameter(Mandatory)][string]$StateRoot, [Parameter(Mandatory)]$App)
    $identity = "win32`0$([int]$App.pid)`0$([string]$App.startTimeFileTimeUtc)"
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($identity)
        $hash = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant().Substring(0, 24)
    } finally { $algorithm.Dispose() }
    return Join-Path (Join-Path $StateRoot 'active') "$hash.lock"
}

function Test-CoordinatorCommandLine {
    param([string]$CommandLine, [string]$ScriptPath, [string]$ConfigPath)
    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($ScriptPath) -or [string]::IsNullOrWhiteSpace($ConfigPath)) { return $false }
    $script = Get-NormalizedExistingPath $ScriptPath
    $config = Get-NormalizedExistingPath $ConfigPath
    if ($null -eq $script -or $null -eq $config) { return $false }
    $tokens = @([regex]::Matches($CommandLine, '"([^"]*)"|([^\s]+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    })
    $scriptToken = @($tokens | Where-Object { [string]::Equals([string]$_, $script, [StringComparison]::OrdinalIgnoreCase) })
    if ($scriptToken.Count -ne 1) { return $false }
    for ($index = 0; $index -lt $tokens.Count - 1; $index += 1) {
        if ([string]::Equals([string]$tokens[$index], '--config', [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$tokens[$index + 1], $config, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-ExactCoordinatorProcess {
    param([int]$ProcessId, [string]$StartToken, [string]$ExecutablePath, [string]$ScriptPath, [string]$ConfigPath)
    if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($StartToken) -or [string]::IsNullOrWhiteSpace($ExecutablePath)) { return $false }
    $expectedPath = Get-NormalizedExistingPath $ExecutablePath
    if ($null -eq $expectedPath) { return $false }
    $process = $null
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $actualPath = Get-NormalizedExistingPath $process.MainModule.FileName
        $actualStart = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        $commandLine = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine
        return $null -ne $actualPath -and
            [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($actualStart, $StartToken, [StringComparison]::Ordinal) -and
            (Test-CoordinatorCommandLine -CommandLine $commandLine -ScriptPath $ScriptPath -ConfigPath $ConfigPath)
    } catch { return $false }
    finally { if ($process) { $process.Dispose() } }
}

function Find-ReusableUpdateSession {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$BundleRoot,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$EntryPointRelative,
        [Parameter(Mandatory)][bool]$UseProxy,
        [Parameter(Mandatory)][bool]$ReplaceRunningApp,
        [Parameter(Mandatory)][bool]$AutoCheckEnabled
    )
    $sessionsRoot = Join-Path $StateRoot 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot -PathType Container)) { return $null }
    $expectedStateRoot = Get-NormalizedExistingPath $StateRoot
    $expectedInstallRoot = Get-NormalizedExistingPath $InstallRoot
    $expectedBundleRoot = Get-NormalizedExistingPath $BundleRoot
    if ($null -eq $expectedStateRoot -or $null -eq $expectedInstallRoot -or $null -eq $expectedBundleRoot) { return $null }
    $candidateDirectories = @(Get-ChildItem -LiteralPath $sessionsRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-f]{32}$' -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) } |
        Sort-Object LastWriteTimeUtc -Descending)
    foreach ($directory in $candidateDirectories) {
        $sessionPath = Join-Path $directory.FullName 'session.json'
        $statePath = Join-Path $directory.FullName 'coordinator-state.json'
        if (-not (Test-PlainExistingFile $sessionPath) -or -not (Test-PlainExistingFile $statePath)) { continue }
        try {
            $config = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $configDirectory = Get-NormalizedExistingPath ([string](Get-JsonPropertyValue $config 'sessionDirectory'))
            if (-not [string]::Equals($configDirectory, $directory.FullName, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ([string]$state.phase -notin @('active', 'degraded') -or [string]$state.sessionId -cne $directory.Name) { continue }
            $heartbeat = 0L
            if (-not [long]::TryParse([string](Get-JsonPropertyValue $state 'heartbeatAtUnixMs'), [ref]$heartbeat) -or
                $heartbeat -le 0 -or $heartbeat -gt $now -or ($now - $heartbeat) -gt 10000) { continue }
            $configApp = Get-JsonPropertyValue $config 'app'
            if ($null -eq $configApp -or [int]$configApp.pid -ne [int]$Identity.pid -or
                [string]$configApp.startTimeFileTimeUtc -cne [string]$Identity.startTimeFileTimeUtc -or
                -not [string]::Equals([string]$configApp.executablePath, [string]$Identity.executablePath, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $coordinatorIdentity = Get-JsonPropertyValue $state 'coordinatorIdentity'
            $coordinatorPid = [int]$state.coordinatorPid
            $coordinatorStart = [string](Get-JsonPropertyValue $coordinatorIdentity 'startToken')
            $coordinatorExecutable = [string](Get-JsonPropertyValue $coordinatorIdentity 'executablePath')
            $updaterPath = Get-NormalizedExistingPath ([string](Get-JsonPropertyValue $config 'updaterPath'))
            $existingBundle = if ($null -eq $updaterPath) { $null } else { Get-NormalizedExistingPath (Split-Path -Parent $updaterPath) }
            $coordinatorProcessMatches = $false
            if ($null -ne $existingBundle) {
                $coordinatorProcessMatches = Test-ExactCoordinatorProcess -ProcessId $coordinatorPid -StartToken $coordinatorStart -ExecutablePath $coordinatorExecutable -ScriptPath (Join-Path $existingBundle 'update-session.js') -ConfigPath $sessionPath
            }
            if ([int](Get-JsonPropertyValue $coordinatorIdentity 'pid') -ne $coordinatorPid -or
                -not $coordinatorProcessMatches) { continue }
            $lockPath = Get-UpdateSessionLockPath -StateRoot $expectedStateRoot -App $Identity
            if (-not (Test-PlainExistingFile $lockPath)) { continue }
            $owner = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ([int]$owner.pid -ne $coordinatorPid -or [string]$owner.startToken -cne $coordinatorStart -or
                -not [string]::Equals([string]$owner.executablePath, $coordinatorExecutable, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not [string]::Equals((Get-NormalizedExistingPath ([string](Get-JsonPropertyValue $config 'stateRoot'))), $expectedStateRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals((Get-NormalizedExistingPath ([string](Get-JsonPropertyValue $config 'installRoot'))), $expectedInstallRoot, [StringComparison]::OrdinalIgnoreCase) -or
                [int]$config.rendererPort -ne [int]$Identity.rendererPort) { continue }
            $relaunch = Get-JsonPropertyValue $config 'relaunch'
            $autoCheck = Get-JsonPropertyValue $config 'autoCheckEnabled'
            $contextMatches = $null -ne $relaunch -and $relaunch.entryPointRelative -ceq $EntryPointRelative -and
                $relaunch.useProxy -is [bool] -and [bool]$relaunch.useProxy -eq $UseProxy -and
                $relaunch.replaceRunningApp -is [bool] -and [bool]$relaunch.replaceRunningApp -eq $ReplaceRunningApp -and
                $autoCheck -is [bool] -and [bool]$autoCheck -eq $AutoCheckEnabled
            $bundlesRoot = Get-NormalizedExistingPath (Join-Path $expectedStateRoot 'bundles')
            $bundleHash = if ($null -eq $existingBundle) { $null } else { [IO.Path]::GetFileName($existingBundle) }
            if ($null -eq $existingBundle -or [IO.Path]::GetFileName($existingBundle) -notmatch '^[0-9a-f]{64}$' -or
                -not [string]::Equals((Split-Path -Parent $existingBundle), $bundlesRoot, [StringComparison]::OrdinalIgnoreCase) -or
                [string]$state.bundleHash -cne $bundleHash -or
                -not (Test-PlainExistingFile $updaterPath) -or
                -not (Test-PlainExistingFile (Join-Path $existingBundle 'update-session.js'))) { continue }
            # An owned live coordinator keeps its lock while repairing its
            # renderer connection. Do not mistake its process heartbeat for a
            # working bridge, and do not launch a duplicate beside it.
            $rendererProofAt = 0L
            $rendererConnected = Get-JsonPropertyValue $state 'rendererConnected'
            $rendererHealthy = [string]$state.phase -ceq 'active' -and
                $rendererConnected -is [bool] -and $rendererConnected -and
                [long]::TryParse([string](Get-JsonPropertyValue $state 'rendererProofAtUnixMs'), [ref]$rendererProofAt) -and
                $rendererProofAt -gt 0 -and $rendererProofAt -le $now -and ($now - $rendererProofAt) -le 10000
            $legacyRepairEligible = [string]$state.phase -ceq 'active' -and
                $null -eq $state.PSObject.Properties['rendererConnected'] -and
                $null -eq $state.PSObject.Properties['rendererProofAtUnixMs']
            return [pscustomobject][ordered]@{
                Compatible = [bool]($contextMatches -and $rendererHealthy)
                Reason = if (-not $contextMatches) { 'active-coordinator-context-mismatch' } elseif (-not $rendererHealthy) { 'active-coordinator-bridge-unhealthy' } else { $null }
                ContextMatches = [bool]$contextMatches
                LegacyRepairEligible = [bool]$legacyRepairEligible
                ProcessId = $coordinatorPid
                ProcessStartTimeFileTimeUtc = $coordinatorStart
                ProcessExecutablePath = $coordinatorExecutable
                ConfigPath = $sessionPath
                BundleHash = $bundleHash
                BundleMatchesRequested = [string]::Equals($existingBundle, $expectedBundleRoot, [StringComparison]::OrdinalIgnoreCase)
            }
        } catch { continue }
    }
    return $null
}

$node = Resolve-UpdateSessionNode
$identity = Get-ExactAppIdentity
$bundle = Copy-ImmutableUpdateSessionBundle -Node $node
$autoDisabled = $env:CHATGPT_REMOTE_AUTO_UPDATE -match '^(?:0|false|off|no)$' -or
    (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $stateRoot) 'update\auto-update-disabled') -PathType Leaf)
$autoCheckEnabled = -not $autoDisabled
$reusable = Find-ReusableUpdateSession -StateRoot $stateRoot -InstallRoot $InstallRoot -BundleRoot $bundle -Identity $identity -EntryPointRelative $EntryPointRelative -UseProxy ([bool]$UseProxy) -ReplaceRunningApp ([bool]$ReplaceRunningApp) -AutoCheckEnabled $autoCheckEnabled
$coordinatorRepair = $null
if ($null -ne $reusable -and -not $reusable.Compatible -and $reusable.LegacyRepairEligible) {
    $repairHelper = Join-Path $bundle 'RepairUpdateCoordinator.ps1'
    if (-not (Test-PlainExistingFile $repairHelper)) { throw 'The immutable legacy coordinator repair helper is unavailable.' }
    $repairOutput = @(& $repairHelper -ConfigPath ([string]$reusable.ConfigPath) `
        -CoordinatorProcessId ([int]$reusable.ProcessId) `
        -CoordinatorStartTimeFileTimeUtc ([long]$reusable.ProcessStartTimeFileTimeUtc) `
        -CoordinatorExecutablePath ([string]$reusable.ProcessExecutablePath) 2>&1)
    $repairLine = @($repairOutput | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($repairLine)) { throw "The legacy coordinator repair returned no proof: $($repairOutput -join ' ')" }
    $coordinatorRepair = $repairLine | ConvertFrom-Json -ErrorAction Stop
    if ($coordinatorRepair.repaired -eq $false -and $coordinatorRepair.reason -ceq 'legacy-coordinator-bridge-healthy' -and
        [int]$coordinatorRepair.coordinatorProcessId -eq [int]$reusable.ProcessId -and [int]$coordinatorRepair.appProcessId -eq [int]$identity.pid) {
        if ($reusable.ContextMatches) {
            [pscustomobject][ordered]@{
                started = $true
                reused = $true
                reason = $null
                legacyBridgeProven = $true
                processId = [int]$reusable.ProcessId
                processStartTimeFileTimeUtc = [string]$reusable.ProcessStartTimeFileTimeUtc
                appProcessId = $identity.pid
                rendererPort = $identity.rendererPort
                bundleHash = [string]$reusable.BundleHash
                requestedBundleHash = [IO.Path]::GetFileName($bundle)
                bundleMatchesRequested = [bool]$reusable.BundleMatchesRequested
                configPath = [string]$reusable.ConfigPath
            } | ConvertTo-Json -Compress
            return
        }
        $coordinatorRepair = $null
    }
    if ($null -ne $coordinatorRepair -and $coordinatorRepair.repaired -eq $false -and $coordinatorRepair.reason -ceq 'legacy-coordinator-bridge-present-unverified' -and
        [int]$coordinatorRepair.coordinatorProcessId -eq [int]$reusable.ProcessId -and [int]$coordinatorRepair.appProcessId -eq [int]$identity.pid) {
        $coordinatorRepair = $null
    }
    if ($null -ne $coordinatorRepair -and ($coordinatorRepair.repaired -ne $true -or
        [int]$coordinatorRepair.coordinatorProcessId -ne [int]$reusable.ProcessId -or
        [int]$coordinatorRepair.appProcessId -ne [int]$identity.pid)) {
        throw 'The legacy coordinator repair did not return exact replacement proof.'
    }
    if ($null -ne $coordinatorRepair) {
        $reusable = Find-ReusableUpdateSession -StateRoot $stateRoot -InstallRoot $InstallRoot -BundleRoot $bundle -Identity $identity -EntryPointRelative $EntryPointRelative -UseProxy ([bool]$UseProxy) -ReplaceRunningApp ([bool]$ReplaceRunningApp) -AutoCheckEnabled $autoCheckEnabled
        if ($null -ne $reusable) { throw 'The retired legacy coordinator still owns the exact update session.' }
    }
}
if ($null -ne $reusable) {
    [pscustomobject][ordered]@{
        started = [bool]$reusable.Compatible
        reused = $true
        reason = $reusable.Reason
        legacyRepairEligible = [bool]$reusable.LegacyRepairEligible
        processId = [int]$reusable.ProcessId
        processStartTimeFileTimeUtc = [string]$reusable.ProcessStartTimeFileTimeUtc
        appProcessId = $identity.pid
        rendererPort = $identity.rendererPort
        bundleHash = [string]$reusable.BundleHash
        requestedBundleHash = [IO.Path]::GetFileName($bundle)
        bundleMatchesRequested = [bool]$reusable.BundleMatchesRequested
        configPath = [string]$reusable.ConfigPath
    } | ConvertTo-Json -Compress
    return
}
$sessionDirectory = Join-Path (Join-Path $stateRoot 'sessions') ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null
$configPath = Join-Path $sessionDirectory 'session.json'
$config = [ordered]@{
    schemaVersion = 1
    platform = 'win32'
    installRoot = $InstallRoot
    stateRoot = $stateRoot
    sessionDirectory = $sessionDirectory
    updaterPath = Join-Path $bundle 'Update-ChatGPTRemote.ps1'
    platformHelperPath = Join-Path $bundle 'UpdateSessionPlatform.ps1'
    rendererPort = $identity.rendererPort
    autoCheckEnabled = $autoCheckEnabled
    skipInitialCheck = [bool]$SkipInitialCheck
    logPath = Join-Path $sessionDirectory 'update-session.log'
    app = [ordered]@{
        pid = $identity.pid
        startTimeFileTimeUtc = [string]$identity.startTimeFileTimeUtc
        executablePath = $identity.executablePath
    }
    relaunch = [ordered]@{
        entryPointRelative = $EntryPointRelative
        useProxy = [bool]$UseProxy
        replaceRunningApp = [bool]$ReplaceRunningApp
    }
    launchReceipt = [ordered]@{
        path = Join-Path $sessionDirectory 'coordinator-ready.json'
        identityPath = Join-Path $sessionDirectory 'coordinator-identity.json'
        nonce = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
        nodeSha256 = (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
        scriptSha256 = (Get-FileHash -LiteralPath (Join-Path $bundle 'update-session.js') -Algorithm SHA256).Hash.ToLowerInvariant()
        expiresAtUnixMs = [DateTimeOffset]::UtcNow.AddSeconds(30).ToUnixTimeMilliseconds()
    }
}
$temporaryConfig = "$configPath.tmp"
[IO.File]::WriteAllText($temporaryConfig, (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force

$helperPath = Join-Path $bundle 'update-session.js'
$survivorLauncher = Join-Path $sourceRoot 'UpdateSessionSurvivorLauncher.ps1'
$configHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
$launchResult = & $survivorLauncher -NodePath $node -ScriptPath $helperPath -ConfigPath $configPath -ExpectedConfigSha256 $configHash | ConvertFrom-Json -ErrorAction Stop
[pscustomobject][ordered]@{
    started = [bool]$launchResult.started
    processId = [int]$launchResult.processId
    appProcessId = $identity.pid
    rendererPort = $identity.rendererPort
    bundleHash = [IO.Path]::GetFileName($bundle)
    configPath = $configPath
    repairedLegacyCoordinator = [bool]($null -ne $coordinatorRepair)
    replacedCoordinatorProcessId = if ($null -eq $coordinatorRepair) { $null } else { [int]$coordinatorRepair.coordinatorProcessId }
} | ConvertTo-Json -Compress
