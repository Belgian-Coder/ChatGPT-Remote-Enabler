[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stableModulePath = Join-Path $repositoryRoot 'windows\StableInstall.ps1'
. $stableModulePath

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Version {
    param([string]$Root, [string]$Version)
    [IO.File]::WriteAllText((Join-Path $Root 'VERSION'), "$Version$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
}

function New-ReleaseManifest {
    param([string]$Root)
    $manifestPath = Join-Path $Root 'RELEASE-MANIFEST.sha256'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { Remove-Item -LiteralPath $manifestPath -Force }
    $lines = foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Root.Length + 1).Replace('\', '/')
        "{0} *{1}" -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
    }
    [IO.File]::WriteAllText($manifestPath, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('stable-launcher-resolution-' + [guid]::NewGuid().ToString('N'))
$stableRoot = Join-Path $fixtureRoot 'canonical'
$packagedSource = Join-Path $fixtureRoot 'packaged-source'
$recoveryStableRoot = Join-Path $fixtureRoot 'canonical-recovery'
$recoveryStateRoot = Join-Path $fixtureRoot 'updater-recovery-state'
$legacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.23'
$newerLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.61'
$reparseLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.22'
$processFailureLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.21'
$migrationFailureLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.20'
$sessionLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.19'
$stateRoot = Join-Path $fixtureRoot 'updater-state'
$desktopPath = Join-Path $fixtureRoot 'Desktop'
$startMenuPath = Join-Path $fixtureRoot 'StartMenu'
$startupPath = Join-Path $fixtureRoot 'Startup'
try {
    New-Item -ItemType Directory -Path $stableRoot,$packagedSource,$legacyRoot,$newerLegacyRoot,$processFailureLegacyRoot,$migrationFailureLegacyRoot,$sessionLegacyRoot,$desktopPath,$startMenuPath,$startupPath -Force | Out-Null
    Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $stableRoot
    Write-Version -Root $stableRoot -Version 'v1.5.60'
    New-ReleaseManifest -Root $stableRoot
    Assert-Condition (Test-StablePackage -Root $stableRoot -RequireManifest) 'The canonical fixture failed manifest, VERSION, and ProductVersion validation.'
    Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $packagedSource
    Write-Version -Root $packagedSource -Version 'v1.5.60'
    New-ReleaseManifest -Root $packagedSource
    Assert-Condition (Test-StablePackage -Root $packagedSource -RequireManifest) 'The packaged update fixture failed validation.'

    # Hold the detached per-session helper open while replacing the stable-root
    # copy. A lock outside the install root must never block stable updates.
    $stableTaskHost = Join-Path $stableRoot 'CodexRemoteMobileProject\UpdateSessionTaskHost.exe'
    $detachedTaskHost = Join-Path $fixtureRoot 'detached-host\UpdateSessionTaskHost.exe'
    $lockScript = Join-Path $fixtureRoot 'hold-detached-host.ps1'
    $lockSignal = Join-Path $fixtureRoot 'detached-host.locked'
    $originalBytes = $null
    New-Item -ItemType Directory -Path (Split-Path -Parent $detachedTaskHost) -Force | Out-Null
    Copy-Item -LiteralPath $stableTaskHost -Destination $detachedTaskHost -Force
    [IO.File]::WriteAllText($lockScript, @'
param([string]$Path, [string]$SignalPath)
$stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try { [IO.File]::WriteAllText($SignalPath, 'locked'); Start-Sleep -Seconds 60 } finally { $stream.Dispose() }
'@, [Text.UTF8Encoding]::new($false))
    $locker = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$lockScript,'-Path',$detachedTaskHost,'-SignalPath',$lockSignal)
    try {
        $lockDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $lockSignal -PathType Leaf) -and [DateTime]::UtcNow -lt $lockDeadline) { Start-Sleep -Milliseconds 50 }
        Assert-Condition (Test-Path -LiteralPath $lockSignal -PathType Leaf) 'Detached task-host lock process did not start.'
        $originalBytes = [IO.File]::ReadAllBytes($stableTaskHost)
        $damagedBytes = [byte[]]$originalBytes.Clone()
        $damagedBytes[$damagedBytes.Length - 1] = [byte]($damagedBytes[$damagedBytes.Length - 1] -bxor 1)
        [IO.File]::WriteAllBytes($stableTaskHost, $damagedBytes)
        Assert-Condition (-not (Test-StablePackage -Root $stableRoot -RequireManifest)) 'The stable fixture was not damaged before transactional repair.'
        $ensuredStable = Ensure-StableInstallRoot -SourceRoot $packagedSource -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LockTimeoutSeconds 10
        Assert-Condition ([string]::Equals($ensuredStable, $stableRoot, [StringComparison]::OrdinalIgnoreCase)) 'Transactional stable-root repair returned the wrong root.'
        Assert-Condition (Test-StablePackage -Root $stableRoot -RequireManifest) 'Transactional stable-root repair did not restore manifest integrity.'
        Assert-Condition ((Get-FileHash -LiteralPath $stableTaskHost -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $packagedSource 'CodexRemoteMobileProject\UpdateSessionTaskHost.exe') -Algorithm SHA256).Hash) 'The stable task host was not transactionally replaced.'
        Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'transaction.json') -PathType Leaf)) 'Successful stable-root repair left a recovery journal behind.'
        Assert-Condition (@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'rollback') -Directory -ErrorAction SilentlyContinue).Count -eq 1) 'Stable-root repair did not retain exactly one external rollback generation.'
        Assert-Condition (-not $locker.HasExited) 'Detached task-host lock process exited before stable replacement verification.'
    } finally {
        if ($locker -and -not $locker.HasExited) { Stop-Process -Id $locker.Id -Force -ErrorAction SilentlyContinue }
        if ($null -ne $originalBytes -and (Test-Path -LiteralPath $stableTaskHost)) { [IO.File]::WriteAllBytes($stableTaskHost, $originalBytes) }
    }

    # Reproduce the historical EPERM: an old task host is still locked inside
    # the install root. The first apply must leave a durable journal, and the
    # next invocation must complete recovery after the handle is released.
    New-Item -ItemType Directory -Path $recoveryStableRoot -Force | Out-Null
    Copy-StablePackageContents -SourceRoot $packagedSource -DestinationRoot $recoveryStableRoot
    New-ReleaseManifest -Root $recoveryStableRoot
    Add-Content -LiteralPath (Join-Path $recoveryStableRoot 'FEATURES.md') -Value 'force repair' -Encoding UTF8
    $lockedStableTaskHost = Join-Path $recoveryStableRoot 'CodexRemoteMobileProject\UpdateSessionTaskHost.exe'
    $stableLock = [IO.File]::Open($lockedStableTaskHost, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $blockedMessage = $null
    try {
        try { [void](Ensure-StableInstallRoot -SourceRoot $packagedSource -StableRoot $recoveryStableRoot -UpdaterStateRoot $recoveryStateRoot -LockTimeoutSeconds 10) }
        catch { $blockedMessage = $_.Exception.Message }
        Assert-Condition ($blockedMessage -match 'UNSAFE_MIXED_INSTALL') 'A locked in-root task host did not stop with a recoverable mixed-install error.'
        Assert-Condition (Test-Path -LiteralPath (Join-Path $recoveryStateRoot 'transaction.json') -PathType Leaf) 'The blocked stable update did not retain its recovery journal.'
    } finally { $stableLock.Dispose() }
    [void](Ensure-StableInstallRoot -SourceRoot $packagedSource -StableRoot $recoveryStableRoot -UpdaterStateRoot $recoveryStateRoot -LockTimeoutSeconds 10)
    Assert-Condition (Test-StablePackage -Root $recoveryStableRoot -RequireManifest) 'Stable recovery did not complete after releasing the old in-root task host.'
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $recoveryStateRoot 'transaction.json') -PathType Leaf)) 'Recovered stable update left its journal behind.'

    Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $legacyRoot
    Write-Version -Root $legacyRoot -Version 'v1.5.23'
    New-Item -ItemType Directory -Path (Join-Path $legacyRoot 'rollback') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'rollback\transaction.json'), '{"rollback":"durable"}', [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path (Join-Path $legacyRoot 'CodexRemoteMobileProject\rollback') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'CodexRemoteMobileProject\rollback\mobile.json'), '{"rollback":"mobile-durable"}', [Text.UTF8Encoding]::new($false))

    Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $newerLegacyRoot
    Write-Version -Root $newerLegacyRoot -Version 'v1.5.61'
    New-ReleaseManifest -Root $newerLegacyRoot
    foreach ($root in @($processFailureLegacyRoot, $migrationFailureLegacyRoot, $sessionLegacyRoot, $reparseLegacyRoot)) {
        Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $root
        Write-Version -Root $root -Version 'v1.5.23'
        New-ReleaseManifest -Root $root
    }

    $shell = New-Object -ComObject WScript.Shell
    $legacyDesktop = Join-Path $desktopPath 'ChatGPT Custom.lnk'
    $legacyRemote = Join-Path $desktopPath 'ChatGPT Remote Enabler.lnk'
    $legacyStartup = Join-Path $startupPath 'ChatGPT Custom Startup.lnk'
    foreach ($entry in @(
        [ordered]@{ Path = $legacyDesktop; Target = Join-Path $legacyRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'; Arguments = '--proxy' },
        [ordered]@{ Path = $legacyRemote; Target = Join-Path $legacyRoot 'ChatGPT Remote Enabler.exe'; Arguments = '' },
        [ordered]@{ Path = $legacyStartup; Target = Join-Path $legacyRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'; Arguments = '--proxy' }
    )) {
        $shortcut = $shell.CreateShortcut($entry.Path)
        $shortcut.TargetPath = $entry.Target
        $shortcut.Arguments = $entry.Arguments
        $shortcut.WorkingDirectory = $legacyRoot
        $shortcut.Save()
    }
    $migration = @(Invoke-StableShortcutMigration -StableRoot $stableRoot -DesktopPath $desktopPath -StartMenuPath $startMenuPath -StartupPath $startupPath)
    $desktopCustom = $shell.CreateShortcut($legacyDesktop)
    $desktopRemote = $shell.CreateShortcut($legacyRemote)
    $startupCustom = $shell.CreateShortcut($legacyStartup)
    Assert-Condition ([string]::Equals($desktopCustom.TargetPath, (Join-Path $stableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'), [StringComparison]::OrdinalIgnoreCase)) 'Legacy ChatGPT Custom desktop alias was not migrated to the canonical root.'
    Assert-Condition ([string]::Equals($desktopRemote.TargetPath, (Join-Path $stableRoot 'ChatGPT Remote Enabler.exe'), [StringComparison]::OrdinalIgnoreCase)) 'Legacy ChatGPT Remote Enabler alias was not migrated to the canonical root.'
    Assert-Condition ($desktopCustom.Arguments -match '--proxy') 'Desktop proxy argument was not preserved.'
    Assert-Condition ($startupCustom.Arguments -match '--proxy' -and $startupCustom.Arguments -match '--startup') 'Startup proxy/startup arguments were not preserved.'
    Assert-Condition (@($migration | Where-Object migrated).Count -ge 3) 'Expected all fixture aliases to migrate.'
    $argumentOnlyAlias = Join-Path $startMenuPath 'ChatGPT Custom (Proxy).lnk'
    $argumentOnlyShortcut = $shell.CreateShortcut($argumentOnlyAlias)
    $argumentOnlyShortcut.TargetPath = Join-Path $newerLegacyRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    $argumentOnlyShortcut.WorkingDirectory = $newerLegacyRoot
    $argumentOnlyShortcut.Arguments = $stableRoot
    $argumentOnlyShortcut.Save()
    Assert-Condition (-not (Test-StableEntryPointsMigrated -StableRoot $stableRoot -ShortcutPaths @($argumentOnlyAlias))) 'A stable path present only in shortcut arguments was mistaken for a migrated target.'
    Remove-Item -LiteralPath $argumentOnlyAlias -Force

    $referenced = [pscustomobject]@{ ExecutablePath = (Join-Path $legacyRoot 'UpdateSessionTaskHost.exe'); CommandLine = '' }
    $approvedReleaseParent = Join-Path $fixtureRoot 'releases'
    $retained = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($legacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ShortcutPaths @($legacyDesktop,$legacyRemote,$legacyStartup) -ProcessEnumerator { @($referenced) })
    Assert-Condition (Test-Path -LiteralPath $legacyRoot -PathType Container) 'A legacy root referenced by a live detached task host was removed.'
    Assert-Condition ($retained[0].reason -eq 'live-or-entrypoint-reference') 'Referenced-root cleanup did not fail closed.'

    $cleaned = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($legacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ShortcutPaths @($legacyDesktop,$legacyRemote,$legacyStartup) -ProcessEnumerator { @() })
    Assert-Condition (-not (Test-Path -LiteralPath $legacyRoot -PathType Container)) 'A verified unreferenced legacy root was not cleaned up.'
    $recoveryRoot = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'legacy-recovery') -Directory -Force)[0].FullName
    Assert-Condition (Test-Path -LiteralPath (Join-Path $recoveryRoot 'root-rollback\transaction.json') -PathType Leaf) 'Legacy root rollback material was not durably copied outside the removed root.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $recoveryRoot 'mobile-rollback\mobile.json') -PathType Leaf) 'Nested mobile rollback material was not durably copied outside the removed root.'

    $newerResult = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($newerLegacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ProcessEnumerator { @() })
    Assert-Condition ((Test-Path -LiteralPath $newerLegacyRoot -PathType Container) -and $newerResult[0].reason -eq 'newer-legacy-version-retained' -and -not $newerResult[0].cleaned) 'A newer legacy root was incorrectly removed or mislabeled as cleaned.'

    $processFailureResult = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($processFailureLegacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ProcessEnumerator { throw 'process inventory unavailable' })
    Assert-Condition ((Test-Path -LiteralPath $processFailureLegacyRoot -PathType Container) -and -not $processFailureResult[0].cleaned) 'Process-inventory failure did not retain the legacy root.'

    $liveConfig = Join-Path $fixtureRoot 'live-session\session.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $liveConfig) -Force | Out-Null
    [IO.File]::WriteAllText($liveConfig, (([ordered]@{ installRoot = $sessionLegacyRoot } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $liveCoordinator = [pscustomobject]@{ ExecutablePath = 'C:\Program Files\nodejs\node.exe'; CommandLine = '"C:\Program Files\nodejs\node.exe" "C:\state\update-session.js" --config "' + $liveConfig + '"' }
    $liveSessionResult = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($sessionLegacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ProcessEnumerator { @($liveCoordinator) })
    Assert-Condition ((Test-Path -LiteralPath $sessionLegacyRoot -PathType Container) -and $liveSessionResult[0].reason -eq 'live-or-entrypoint-reference') 'A live coordinator configuration did not retain its referenced legacy root.'
    $historicalSessionResult = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($sessionLegacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ProcessEnumerator { @() })
    Assert-Condition (-not (Test-Path -LiteralPath $sessionLegacyRoot -PathType Container)) 'A historical session record blocked obsolete-root cleanup without a live coordinator.'

    $invalidAlias = Join-Path $desktopPath 'ChatGPT Custom.lnk'
    [IO.File]::WriteAllText($invalidAlias, 'not-a-shortcut', [Text.UTF8Encoding]::new($false))
    $migrationFailureResult = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($migrationFailureLegacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ShortcutPaths @($invalidAlias) -ProcessEnumerator { @() } -MigrateEntryPoints)
    Assert-Condition ((Test-Path -LiteralPath $migrationFailureLegacyRoot -PathType Container) -and $migrationFailureResult[0].reason -eq 'entrypoint-migration-failed' -and -not $migrationFailureResult[0].cleaned) 'Failed shortcut migration did not retain the referenced legacy root.'

    $reparseTarget = Join-Path $fixtureRoot 'reparse-target'
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    $reparseLink = Join-Path $reparseLegacyRoot 'linked-data'
    New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget -Force | Out-Null
    $reparseResult = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($reparseLegacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ProcessEnumerator { @() })
    Assert-Condition ((Test-Path -LiteralPath $reparseLegacyRoot -PathType Container) -and -not $reparseResult[0].cleaned) 'A legacy root containing a reparse point was removed.'

    $preparedArtifact = Join-Path $stateRoot 'prepared\prepared-old'
    $stagingArtifact = Join-Path $stateRoot 'staging\staging-old'
    New-Item -ItemType Directory -Path $preparedArtifact,$stagingArtifact -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $preparedArtifact 'marker.txt'), 'old', [Text.UTF8Encoding]::new($false))
    $artifactResults = @(Invoke-StableUpdaterArtifactCleanup -UpdaterStateRoot $stateRoot)
    Assert-Condition (((@($artifactResults | Where-Object removed)).Count -eq 2) -and -not (Test-Path -LiteralPath $preparedArtifact) -and -not (Test-Path -LiteralPath $stagingArtifact)) 'Superseded updater artifacts were not cleaned and reported.'

    $migratedRoot = Join-Path $fixtureRoot 'stable-migrated'
    $sourceRoot = Join-Path $repositoryRoot 'windows'
    $ensured = Ensure-StableInstallRoot -SourceRoot $sourceRoot -StableRoot $migratedRoot -UpdaterStateRoot $stateRoot -LockTimeoutSeconds 10
    Assert-Condition ([string]::Equals($ensured, $migratedRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-StablePackage -Root $migratedRoot)) 'Initial legacy-root consolidation did not produce one stable root.'

    $sourceText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\Update-ChatGPTRemote.ps1') -Raw
    $customSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\ChatGPTCustomLauncher.cs') -Raw
    $rootSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\ChatGPTRemoteLauncher.cs') -Raw
    $survivorSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\UpdateSessionSurvivorLauncher.ps1') -Raw
    Assert-Condition ($sourceText.Contains('legacyInstallRoot') -and $sourceText.Contains('Invoke-StableLegacyCleanup') -and $sourceText.Contains('Invoke-PendingRecovery')) 'Interrupted legacy transaction recovery and post-update cleanup contracts are missing.'
    Assert-Condition ($customSource.Contains('PrepareDetachedTaskHost') -and $rootSource.Contains('PrepareDetachedTaskHost') -and $survivorSource.Contains('Copy-DetachedTaskHost')) 'Launch/update task hosts are still sourced from the replaceable stable root.'
    Assert-Condition (-not ($sourceText -match '(?i)junction|stable pointer')) 'The Windows design must not reintroduce a versioned pointer or junction.'
    Assert-Condition (-not ($rootSource -match '(?i)Stop-Process.*ChatGPT|Kill.*ChatGPT') -and -not ($customSource -match '(?i)Stop-Process.*ChatGPT|Kill.*ChatGPT')) 'Launcher source contains an unauthorized ChatGPT lifecycle action.'

    [pscustomobject][ordered]@{
        Ok = $true
        CanonicalStableRootValidated = $true
        LockedDetachedHostDoesNotBlockStableUpdate = $true
        DetachedTaskHostLockRegression = $true
        LegacyAliasesMigrated = $true
        StartupArgumentsPreserved = $true
        ReferencedLegacyRootRetained = $true
        LiveCoordinatorReferenceRetained = $true
        HistoricalSessionDoesNotBlockCleanup = $true
        UnreferencedLegacyRootCleaned = $true
        RollbackMaterialExternalized = $true
        InterruptedLegacyRecovery = $true
        LockedInRootFailureRecovers = $true
        NoPointerOrJunction = $true
        NoChatGptLifecycleCall = $true
    } | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
