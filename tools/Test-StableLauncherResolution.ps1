[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stableModulePath = Join-Path $repositoryRoot 'windows\StableInstall.ps1'
. $stableModulePath
. (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\StartupProgress.ps1')

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
$recoverySourceRoot = Join-Path $fixtureRoot 'packaged-recovery-source'
$recoveryStableRoot = Join-Path $fixtureRoot 'canonical-recovery'
$recoveryStateRoot = Join-Path $fixtureRoot 'updater-recovery-state'
$legacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.23'
$newerLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.73'
$reparseLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.22'
$processFailureLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.21'
$migrationFailureLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.20'
$sessionLegacyRoot = Join-Path (Join-Path $fixtureRoot 'releases') 'ChatGPT-Remote-Enabler-Windows-x64-v1.5.19'
$stateRoot = Join-Path $fixtureRoot 'updater-state'
$desktopPath = Join-Path $fixtureRoot 'Desktop'
$startMenuPath = Join-Path $fixtureRoot 'StartMenu'
$startupPath = Join-Path $fixtureRoot 'Startup'
$currentVersion = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\VERSION') -Raw).Trim()
try {
    $expectedDefaultRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'CodexRemoteFeatures\ChatGPT-Remote-Enabler-Windows-x64'
    Assert-Condition ([string]::Equals((Get-StableInstallRoot), $expectedDefaultRoot, [StringComparison]::OrdinalIgnoreCase)) 'The canonical stable root is not current-user LocalAppData.'
    Assert-Condition (Test-StableLegacyRoot -Path (Get-StableMachineInstallRoot)) 'The former machine-wide stable root is not recognized as a legacy migration source.'
    New-Item -ItemType Directory -Path $stableRoot,$packagedSource,$recoverySourceRoot,$legacyRoot,$newerLegacyRoot,$processFailureLegacyRoot,$migrationFailureLegacyRoot,$sessionLegacyRoot,$desktopPath,$startMenuPath,$startupPath -Force | Out-Null
    Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $stableRoot
    Write-Version -Root $stableRoot -Version $currentVersion
    New-ReleaseManifest -Root $stableRoot
    Assert-Condition (Test-StablePackage -Root $stableRoot -RequireManifest) 'The canonical fixture failed manifest, VERSION, and ProductVersion validation.'
    $runtimeRollback = Join-Path $stableRoot 'CodexRemoteMobileProject\rollback'
    New-Item -ItemType Directory -Path $runtimeRollback -Force | Out-Null
    $allowedRuntimeRollback = @(
        'startup-task-fixture-20260915-120000.xml',
        'desktop-shortcut-fixture-20260915-120000-001.lnk',
        'startmenu-shortcut-fixture-20260915-120000-001.lnk',
        'legacydesktop-shortcut-fixture-20260915-120000-001.lnk',
        'legacystartmenu-shortcut-fixture-20260915-120000-001.lnk',
        'legacystartmenuproxytest-shortcut-fixture-20260915-120000-001.lnk',
        'legacystartmenuproxy-shortcut-fixture-20260915-120000-001.lnk',
        'startup-shortcut-fixture-20260915-120000-001.lnk',
        'legacy-disabled-startup-shortcut-fixture-20260915-120000-001.disabled',
        'legacy-disabled-startup-shortcut-fixture-20260915-120000-002.lnk',
        'legacy-startup-shortcut-fixture-20260915-120000-001.lnk'
    )
    foreach ($name in $allowedRuntimeRollback) {
        [IO.File]::WriteAllText((Join-Path $runtimeRollback $name), 'fixture', [Text.UTF8Encoding]::new($false))
    }
    Assert-Condition (Test-StablePackage -Root $stableRoot -RequireManifest) 'Installed-package validation rejected a rollback filename produced by a supported launcher.'
    [IO.File]::WriteAllText((Join-Path $runtimeRollback 'legacy-startup-shortcut-fixture-unsafe.lnk'), 'fixture', [Text.UTF8Encoding]::new($false))
    Assert-Condition (-not (Test-StablePackage -Root $stableRoot -RequireManifest)) 'Installed-package validation accepted a malformed rollback filename.'
    Remove-Item -LiteralPath $runtimeRollback -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $stableRoot 'unlisted-runtime.ps1'), 'throw "must not load"', [Text.UTF8Encoding]::new($false))
    Assert-Condition (-not (Test-StablePackage -Root $stableRoot -RequireManifest)) 'Installed-package validation accepted arbitrary unlisted code.'
    Remove-Item -LiteralPath (Join-Path $stableRoot 'unlisted-runtime.ps1') -Force
    $mobileDirectory = Join-Path $stableRoot 'CodexRemoteMobileProject'
    $externalMobileDirectory = Join-Path $fixtureRoot 'external-mobile-project'
    Move-Item -LiteralPath $mobileDirectory -Destination $externalMobileDirectory
    New-Item -ItemType Junction -Path $mobileDirectory -Target $externalMobileDirectory | Out-Null
    Assert-Condition (-not (Test-StablePackage -Root $stableRoot -RequireManifest)) 'Installed-package validation accepted manifest files through an internal junction.'
    [IO.Directory]::Delete($mobileDirectory)
    Move-Item -LiteralPath $externalMobileDirectory -Destination $mobileDirectory
    $noncanonicalCleanup = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -MigrateEntryPoints)
    Assert-Condition ($noncanonicalCleanup.Count -eq 1 -and $noncanonicalCleanup[0].reason -eq 'noncanonical-stable-root') 'A noncanonical fixture root was allowed to scan or migrate live entry points.'
    $noncanonicalTask = @(Invoke-StableTaskMigration -StableRoot $stableRoot)
    Assert-Condition ($noncanonicalTask.Count -eq 1 -and $noncanonicalTask[0].reason -eq 'noncanonical-stable-root') 'A noncanonical fixture root was allowed to migrate the durable logon task.'
    $unsafeShortcutMigration = @(Invoke-StableShortcutMigration -StableRoot $stableRoot -StartupPath (Join-Path $fixtureRoot 'Startup'))
    Assert-Condition ($unsafeShortcutMigration.Count -eq 1 -and $unsafeShortcutMigration[0].reason -eq 'noncanonical-root-requires-explicit-shortcut-folders') 'A noncanonical migration was allowed to default to real shortcut folders.'
    Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $packagedSource
    Write-Version -Root $packagedSource -Version $currentVersion
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
    $lockArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Path "{1}" -SignalPath "{2}"' -f $lockScript,$detachedTaskHost,$lockSignal
    $locker = Start-StartupBackgroundProcess -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $lockArguments
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

    # Missing helper files must be repairable by setup without deleting the
    # permanent installation first, while retaining downgrade protection.
    $previousVersion = 'v1.0.0'
    Write-Version -Root $stableRoot -Version $previousVersion
    $retiredHelper = Join-Path $stableRoot 'retired-helper.txt'
    [IO.File]::WriteAllText($retiredHelper, 'previous release helper')
    New-ReleaseManifest -Root $stableRoot
    Remove-Item -LiteralPath $stableTaskHost -Force
    Remove-Item -LiteralPath (Join-Path $stableRoot 'VERSION') -Force
    $missingVersionRejected = $false
    try { [void](Ensure-StableInstallRoot -SourceRoot $packagedSource -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LockTimeoutSeconds 10) }
    catch { $missingVersionRejected = $_.Exception.Message -like '*VERSION is missing*' }
    Assert-Condition ($missingVersionRejected -and -not (Test-Path -LiteralPath $stableTaskHost)) 'Setup repaired a damaged root without known version metadata.'
    Write-Version -Root $stableRoot -Version 'invalid-version'
    $invalidVersionRejected = $false
    try { [void](Ensure-StableInstallRoot -SourceRoot $packagedSource -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LockTimeoutSeconds 10) }
    catch { $invalidVersionRejected = $_.Exception.Message -like '*VERSION is invalid*' }
    Assert-Condition ($invalidVersionRejected -and -not (Test-Path -LiteralPath $stableTaskHost)) 'Setup repaired a damaged root with malformed version metadata.'
    $newerVersion = 'v999.0.0'
    Write-Version -Root $stableRoot -Version $newerVersion
    $downgradeRejected = $false
    try { [void](Ensure-StableInstallRoot -SourceRoot $packagedSource -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LockTimeoutSeconds 10) }
    catch { $downgradeRejected = $_.Exception.Message -like '*cannot repair or replace newer stable installation*' }
    Assert-Condition $downgradeRejected 'A missing helper bypassed the stable installation downgrade guard.'
    Write-Version -Root $stableRoot -Version $previousVersion
    $stableManifest = Join-Path $stableRoot 'RELEASE-MANIFEST.sha256'
    $manifestBytes = [IO.File]::ReadAllBytes($stableManifest)
    Remove-Item -LiteralPath $stableManifest -Force
    $unrecognizedRejected = $false
    try { [void](Ensure-StableInstallRoot -SourceRoot $packagedSource -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LockTimeoutSeconds 10) }
    catch { $unrecognizedRejected = $_.Exception.Message -like '*unrecognized directory*' }
    Assert-Condition $unrecognizedRejected 'Setup overwrote an incomplete directory without installation metadata.'
    [IO.File]::WriteAllBytes($stableManifest, $manifestBytes)
    [void](Ensure-StableInstallRoot -SourceRoot $packagedSource -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LockTimeoutSeconds 10)
    Assert-Condition (Test-StablePackage -Root $stableRoot -RequireManifest) 'Setup could not repair a missing required helper.'
    Assert-Condition (-not (Test-Path -LiteralPath $retiredHelper)) 'Cross-version repair retained a retired manifest-listed helper.'
    Assert-Condition ((Get-StableVersion -Root $stableRoot) -ceq $currentVersion) 'Cross-version repair did not install the packaged version.'
    Assert-Condition (@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'rollback') -Directory -ErrorAction SilentlyContinue).Count -eq 1) 'Missing-file repair retained more than one rollback.'

    # Reproduce the historical EPERM: an old task host is still locked inside
    # the install root. The first apply must leave a durable journal, and the
    # next invocation must complete recovery after the handle is released.
    New-Item -ItemType Directory -Path $recoveryStableRoot -Force | Out-Null
    Copy-StablePackageContents -SourceRoot $packagedSource -DestinationRoot $recoveryStableRoot
    New-ReleaseManifest -Root $recoveryStableRoot
    Add-Content -LiteralPath (Join-Path $recoveryStableRoot 'FEATURES.md') -Value 'force repair' -Encoding UTF8
    Copy-StablePackageContents -SourceRoot $packagedSource -DestinationRoot $recoverySourceRoot
    $replacementTaskHost = Join-Path $recoverySourceRoot 'CodexRemoteMobileProject\UpdateSessionTaskHost.exe'
    $replacementBytes = [IO.File]::ReadAllBytes($replacementTaskHost)
    $replacementBytes[$replacementBytes.Length - 1] = [byte]($replacementBytes[$replacementBytes.Length - 1] -bxor 1)
    [IO.File]::WriteAllBytes($replacementTaskHost, $replacementBytes)
    New-ReleaseManifest -Root $recoverySourceRoot
    Assert-Condition (Test-StablePackage -Root $recoverySourceRoot -RequireManifest) 'The executable-replacement source fixture failed package validation.'
    $lockedStableTaskHost = Join-Path $recoveryStableRoot 'CodexRemoteMobileProject\UpdateSessionTaskHost.exe'
    # Deny delete sharing for the executable that must be replaced. The
    # dedicated source fixture differs at that exact path, so this models the
    # historical EPERM instead of merely locking an unchanged package file.
    $stableLock = [IO.File]::Open($lockedStableTaskHost, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $blockedMessage = $null
    try {
        try { [void](Ensure-StableInstallRoot -SourceRoot $recoverySourceRoot -StableRoot $recoveryStableRoot -UpdaterStateRoot $recoveryStateRoot -LockTimeoutSeconds 10) }
        catch { $blockedMessage = $_.Exception.Message }
        Assert-Condition ($blockedMessage -match 'UNSAFE_MIXED_INSTALL') 'A locked in-root task host did not stop with a recoverable mixed-install error.'
        Assert-Condition (Test-Path -LiteralPath (Join-Path $recoveryStateRoot 'transaction.json') -PathType Leaf) 'The blocked stable update did not retain its recovery journal.'
    } finally { $stableLock.Dispose() }
    [void](Ensure-StableInstallRoot -SourceRoot $recoverySourceRoot -StableRoot $recoveryStableRoot -UpdaterStateRoot $recoveryStateRoot -LockTimeoutSeconds 10)
    Assert-Condition (Test-StablePackage -Root $recoveryStableRoot -RequireManifest) 'Stable recovery did not complete after releasing the old in-root task host.'
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $recoveryStateRoot 'transaction.json') -PathType Leaf)) 'Recovered stable update left its journal behind.'

    Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $legacyRoot
    Write-Version -Root $legacyRoot -Version 'v1.5.23'
    New-Item -ItemType Directory -Path (Join-Path $legacyRoot 'rollback') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'rollback\transaction.json'), '{"rollback":"durable"}', [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path (Join-Path $legacyRoot 'CodexRemoteMobileProject\rollback') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'CodexRemoteMobileProject\rollback\mobile.json'), '{"rollback":"mobile-durable"}', [Text.UTF8Encoding]::new($false))

    Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $newerLegacyRoot
    Write-Version -Root $newerLegacyRoot -Version 'v9.9.9'
    New-ReleaseManifest -Root $newerLegacyRoot
    foreach ($root in @($processFailureLegacyRoot, $migrationFailureLegacyRoot, $sessionLegacyRoot, $reparseLegacyRoot)) {
        Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $root
        Write-Version -Root $root -Version 'v1.5.23'
        New-ReleaseManifest -Root $root
    }

    $shell = New-Object -ComObject WScript.Shell
    $legacyDesktop = Join-Path $desktopPath 'ChatGPT Custom.lnk'
    $legacyRemote = Join-Path $desktopPath 'ChatGPT Remote Enabler.lnk'
    $legacyMenuCustom = Join-Path $startMenuPath 'ChatGPT Custom.lnk'
    $legacyMenuProxyTest = Join-Path $startMenuPath 'ChatGPT Custom (Proxy Test).lnk'
    $foreignMenuProxy = Join-Path $startMenuPath 'ChatGPT Custom (Proxy).lnk'
    $legacyMenuRemote = Join-Path $startMenuPath 'ChatGPT Remote Enabler.lnk'
    $canonicalStartup = Join-Path $startupPath 'ChatGPT Remote Enabler Startup.lnk'
    $legacyStartup = Join-Path $startupPath 'ChatGPT Custom Startup.lnk'
    $desktopCanonical = $shell.CreateShortcut($legacyRemote)
    $desktopCanonical.TargetPath = Join-Path $stableRoot 'ChatGPT Remote Enabler.exe'
    $desktopCanonical.Arguments = ''
    $desktopCanonical.WorkingDirectory = $stableRoot
    $desktopCanonical.Save()
    $menuCanonical = $shell.CreateShortcut($legacyMenuRemote)
    $menuCanonical.TargetPath = Join-Path $stableRoot 'ChatGPT Remote Enabler.exe'
    $menuCanonical.Arguments = ''
    $menuCanonical.WorkingDirectory = $stableRoot
    $menuCanonical.Save()
    foreach ($entry in @(
        [ordered]@{ Path = $legacyDesktop; Target = Join-Path $legacyRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'; Arguments = '--proxy' },
        [ordered]@{ Path = $legacyMenuCustom; Target = Join-Path $legacyRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'; Arguments = '--proxy' },
        [ordered]@{ Path = $legacyMenuProxyTest; Target = Join-Path $legacyRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'; Arguments = '--proxy' },
        [ordered]@{ Path = $legacyStartup; Target = Join-Path $legacyRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'; Arguments = '--proxy' }
    )) {
        $shortcut = $shell.CreateShortcut($entry.Path)
        $shortcut.TargetPath = $entry.Target
        $shortcut.Arguments = $entry.Arguments
        $shortcut.WorkingDirectory = $legacyRoot
        $shortcut.Save()
    }
    $foreignRoot = Join-Path $fixtureRoot 'foreign-user-files'
    New-Item -ItemType Directory -Path $foreignRoot -Force | Out-Null
    $foreignExecutable = Join-Path $foreignRoot 'ChatGPT Custom.exe'
    [IO.File]::WriteAllText($foreignExecutable, 'foreign user executable', [Text.UTF8Encoding]::new($false))
    $foreignShortcut = $shell.CreateShortcut($foreignMenuProxy)
    $foreignShortcut.TargetPath = $foreignExecutable
    $foreignShortcut.Arguments = '--proxy'
    $foreignShortcut.Save()
    $migration = @(Invoke-StableShortcutMigration -StableRoot $stableRoot -DesktopPath $desktopPath -StartMenuPath $startMenuPath -StartupPath $startupPath)
    $desktopRemote = $shell.CreateShortcut($legacyRemote)
    $desktopCustom = $shell.CreateShortcut($legacyDesktop)
    $menuRemote = $shell.CreateShortcut($legacyMenuRemote)
    $menuCustom = $shell.CreateShortcut($legacyMenuCustom)
    $startupCanonical = $shell.CreateShortcut($canonicalStartup)
    Assert-Condition ([string]::Equals($desktopRemote.TargetPath, (Join-Path $stableRoot 'ChatGPT Remote Enabler.exe'), [StringComparison]::OrdinalIgnoreCase) -and [string]::IsNullOrWhiteSpace($desktopRemote.Arguments) -and [string]::Equals($desktopCustom.TargetPath, (Join-Path $stableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'), [StringComparison]::OrdinalIgnoreCase) -and $desktopCustom.Arguments -match '--proxy') 'Mixed desktop modes did not retain the canonical direct entry and one proxy alias.'
    Assert-Condition ([string]::Equals($menuRemote.TargetPath, (Join-Path $stableRoot 'ChatGPT Remote Enabler.exe'), [StringComparison]::OrdinalIgnoreCase) -and [string]::IsNullOrWhiteSpace($menuRemote.Arguments) -and [string]::Equals($menuCustom.TargetPath, (Join-Path $stableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'), [StringComparison]::OrdinalIgnoreCase) -and $menuCustom.Arguments -match '--proxy' -and -not (Test-Path -LiteralPath $legacyMenuProxyTest)) 'Mixed Start-menu modes did not retain the canonical direct entry and consolidate proxy duplicates.'
    Assert-Condition (Test-Path -LiteralPath $foreignMenuProxy -PathType Leaf) 'A foreign same-name Start-menu shortcut was removed.'
    Assert-Condition ([string]::Equals($startupCanonical.TargetPath, (Join-Path $stableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'), [StringComparison]::OrdinalIgnoreCase) -and $startupCanonical.Arguments -match '--proxy' -and $startupCanonical.Arguments -match '--startup' -and -not (Test-Path -LiteralPath $legacyStartup -PathType Leaf)) 'Startup migration did not consolidate to one canonical proxy/startup entry.'
    Assert-Condition (@($migration | Where-Object { $_.removed -and $_.reason -eq 'owned-legacy-shortcut-consolidated' }).Count -eq 1) 'Expected only same-mode manual aliases to be consolidated.'
    $danglingTrustedTarget = Join-Path (Get-StableMachineInstallRoot) 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    $danglingWrongRelativeTarget = Join-Path (Get-StableMachineInstallRoot) 'arbitrary\ChatGPT Custom.exe'
    $danglingForeignTarget = Join-Path $foreignRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    Assert-Condition (Test-StableOwnedLauncherPath -TargetPath $danglingTrustedTarget -StableRoot $stableRoot) 'A dangling launcher in a trusted ProgramData install path was rejected as foreign.'
    Assert-Condition (-not (Test-StableOwnedLauncherPath -TargetPath $danglingWrongRelativeTarget -StableRoot $stableRoot)) 'A same-name launcher with the wrong relative path beneath a trusted root was accepted as owned.'
    Assert-Condition (-not (Test-StableOwnedLauncherPath -TargetPath $danglingForeignTarget -StableRoot $stableRoot)) 'A dangling same-name launcher in an arbitrary user path was accepted as owned.'
    $danglingShortcut = $shell.CreateShortcut($legacyDesktop)
    $danglingShortcut.TargetPath = $danglingTrustedTarget
    $danglingShortcut.Arguments = '--proxy'
    $danglingShortcut.Save()
    [void](Invoke-StableShortcutMigration -StableRoot $stableRoot -DesktopPath $desktopPath -StartMenuPath $startMenuPath -StartupPath $startupPath)
    $migratedDangling = $shell.CreateShortcut($legacyDesktop)
    Assert-Condition ([string]::Equals($migratedDangling.TargetPath, (Join-Path $stableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'), [StringComparison]::OrdinalIgnoreCase) -and $migratedDangling.Arguments -match '--proxy') 'A trusted dangling legacy launcher was not migrated while preserving proxy mode.'
    $argumentOnlyAlias = Join-Path $startMenuPath 'Argument Only.lnk'
    $argumentOnlyShortcut = $shell.CreateShortcut($argumentOnlyAlias)
    $argumentOnlyShortcut.TargetPath = Join-Path $newerLegacyRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    $argumentOnlyShortcut.WorkingDirectory = $newerLegacyRoot
    $argumentOnlyShortcut.Arguments = $stableRoot
    $argumentOnlyShortcut.Save()
    Assert-Condition (-not (Test-StableEntryPointsMigrated -StableRoot $stableRoot -ShortcutPaths @($argumentOnlyAlias))) 'A stable path present only in shortcut arguments was mistaken for a migrated target.'
    Remove-Item -LiteralPath $argumentOnlyAlias -Force

    $referenced = [pscustomobject]@{ ExecutablePath = (Join-Path $legacyRoot 'UpdateSessionTaskHost.exe'); CommandLine = '' }
    $approvedReleaseParent = Join-Path $fixtureRoot 'releases'
    $retained = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($legacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ShortcutPaths @($legacyDesktop,$legacyRemote,$legacyStartup,$foreignMenuProxy) -ProcessEnumerator { @($referenced) })
    Assert-Condition (Test-Path -LiteralPath $legacyRoot -PathType Container) 'A legacy root referenced by a live detached task host was removed.'
    Assert-Condition ($retained[0].reason -eq 'live-or-entrypoint-reference') 'Referenced-root cleanup did not fail closed.'

    $cleaned = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($legacyRoot) -ApprovedLegacyParents @($approvedReleaseParent) -ShortcutPaths @($legacyDesktop,$legacyRemote,$legacyStartup,$foreignMenuProxy) -ProcessEnumerator { @() })
    Assert-Condition (-not (Test-Path -LiteralPath $legacyRoot -PathType Container)) 'A verified unreferenced legacy root was not cleaned up.'
    $recoveryRoot = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'legacy-recovery') -Directory -Force)[0].FullName
    Assert-Condition (Test-Path -LiteralPath (Join-Path $recoveryRoot 'root-rollback\transaction.json') -PathType Leaf) 'Legacy root rollback material was not durably copied outside the removed root.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $recoveryRoot 'mobile-rollback\mobile.json') -PathType Leaf) 'Nested mobile rollback material was not durably copied outside the removed root.'

    # Exercise the production default parent policy, redirecting only its data
    # directory joins into this disposable fixture. Never create a test release
    # beneath the user's real installation or change live entry points.
    & {
        $realLocalData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        $realCommonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        $fixtureLocalData = Join-Path $fixtureRoot 'local-data'
        $fixtureCommonData = Join-Path $fixtureRoot 'common-data'
        $localLegacyRoot = Join-Path $fixtureLocalData 'CodexRemoteFeatures\releases\ChatGPT-Remote-Enabler-Windows-x64-v1.5.18'
        New-Item -ItemType Directory -Path $localLegacyRoot -Force | Out-Null
        Copy-StablePackageContents -SourceRoot (Join-Path $repositoryRoot 'windows') -DestinationRoot $localLegacyRoot
        Write-Version -Root $localLegacyRoot -Version 'v1.5.18'
        New-ReleaseManifest -Root $localLegacyRoot
        function Join-Path {
            param([string[]]$Path, [string]$ChildPath)
            $mappedPaths = @($Path | ForEach-Object {
                if ([string]::Equals($_, $realLocalData, [StringComparison]::OrdinalIgnoreCase)) { $fixtureLocalData }
                elseif ([string]::Equals($_, $realCommonData, [StringComparison]::OrdinalIgnoreCase)) { $fixtureCommonData }
                else { $_ }
            })
            Microsoft.PowerShell.Management\Join-Path -Path $mappedPaths -ChildPath $ChildPath
        }
        $localCleaned = @(Invoke-StableLegacyCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -LegacyRoots @($localLegacyRoot) -ProcessEnumerator { @() })
        Assert-Condition ($localCleaned.Count -eq 1 -and $localCleaned[0].cleaned -and -not (Test-Path -LiteralPath $localLegacyRoot)) 'Default cleanup policy did not retire a verified unreferenced LocalAppData releases package.'
    }

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

    $auxiliaryPaths = @(
        (Join-Path $stableRoot 'rollback'),
        (Join-Path $stableRoot 'CodexRemoteMobileProject\rollback'),
        (Join-Path (Split-Path -Parent $stateRoot) 'shortcut-rollback'),
        (Join-Path (Split-Path -Parent $stateRoot) 'rollback')
    )
    foreach ($path in $auxiliaryPaths) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $path 'obsolete.txt'), 'obsolete auxiliary rollback', [Text.UTF8Encoding]::new($false))
    }
    $auxiliaryResults = @(Invoke-StableAuxiliaryRollbackCleanup -StableRoot $stableRoot -UpdaterStateRoot $stateRoot -ProcessEnumerator { @() })
    Assert-Condition ($auxiliaryResults.Count -eq 4 -and @($auxiliaryResults | Where-Object removed).Count -eq 4 -and @($auxiliaryPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) 'Successful cleanup did not remove every auxiliary rollback category.'

    $retentionState = Join-Path $fixtureRoot 'retention-state'
    $retentionRollback = Join-Path $retentionState 'rollback'
    $retentionLegacy = Join-Path $retentionState 'legacy-recovery'
    New-Item -ItemType Directory -Path $retentionRollback,$retentionLegacy -Force | Out-Null
    $rollbackFixtures = @()
    foreach ($index in 1..7) {
        $directory = Join-Path $retentionRollback ("20260912-12000$index-000-v1.5.$index")
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory 'VERSION'), "v1.5.$index`n", [Text.UTF8Encoding]::new($false))
        [IO.Directory]::SetLastWriteTimeUtc($directory, [datetime]::SpecifyKind([datetime]"2026-09-12T12:00:0${index}", [DateTimeKind]::Utc))
        $rollbackFixtures += $directory
    }
    foreach ($index in 1..4) {
        $directory = Join-Path $retentionLegacy ("legacy-$index")
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory 'marker.txt'), "$index`n", [Text.UTF8Encoding]::new($false))
        [IO.Directory]::SetLastWriteTimeUtc($directory, [datetime]::SpecifyKind([datetime]"2026-09-12T12:01:0${index}", [DateTimeKind]::Utc))
    }
    [IO.File]::WriteAllText((Join-Path $retentionState 'transaction.json'), (([ordered]@{ backupRoot = $rollbackFixtures[0] } | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
    $retentionResult = @(Invoke-StableRollbackRetention -UpdaterStateRoot $retentionState -ProcessEnumerator { @() })
    Assert-Condition (@(Get-ChildItem -LiteralPath $retentionRollback -Directory).Count -eq 2) 'Rollback retention did not keep the newest generation plus the journal-referenced generation.'
    Assert-Condition ((Test-Path -LiteralPath $rollbackFixtures[0] -PathType Container) -and (@($retentionResult | Where-Object reason -eq 'retained-active-journal-reference')).Count -eq 1) 'Active-journal rollback material was not retained and reported.'
    Assert-Condition (@(Get-ChildItem -LiteralPath $retentionLegacy -Directory).Count -eq 0) 'Legacy-recovery retention did not remove every unreferenced generation.'
    Remove-Item -LiteralPath (Join-Path $retentionState 'transaction.json') -Force
    $rollbackProcess = [pscustomobject]@{ ExecutablePath = 'C:\Program Files\nodejs\node.exe'; CommandLine = '"C:\Program Files\nodejs\node.exe" "' + (Join-Path $rollbackFixtures[0] 'worker.js') + '"' }
    $retentionWithLiveProcess = @(Invoke-StableRollbackRetention -UpdaterStateRoot $retentionState -ProcessEnumerator { @($rollbackProcess) })
    Assert-Condition (@(Get-ChildItem -LiteralPath $retentionRollback -Directory).Count -eq 2 -and (@($retentionWithLiveProcess | Where-Object reason -eq 'retained-live-process-reference')).Count -eq 1) 'Live-process rollback material was not retained and reported.'
    $retentionAfterJournal = @(Invoke-StableRollbackRetention -UpdaterStateRoot $retentionState -ProcessEnumerator { @() })
    Assert-Condition (@(Get-ChildItem -LiteralPath $retentionRollback -Directory).Count -eq 1 -and -not (Test-Path -LiteralPath $rollbackFixtures[0])) 'Rollback material was not pruned to one generation after its journal reference disappeared.'
    Assert-Condition (@($retentionAfterJournal | Where-Object removed).Count -eq 1) 'Post-journal rollback pruning was not reported.'

    $migratedRoot = Join-Path $fixtureRoot 'stable-migrated'
    $sourceRoot = Join-Path $repositoryRoot 'windows'
    $ensured = Ensure-StableInstallRoot -SourceRoot $sourceRoot -StableRoot $migratedRoot -UpdaterStateRoot $stateRoot -LockTimeoutSeconds 10
    Assert-Condition ([string]::Equals($ensured, $migratedRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-StablePackage -Root $migratedRoot)) 'Initial legacy-root consolidation did not produce one stable root.'

    $sourceText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\Update-ChatGPTRemote.ps1') -Raw
    $stableSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\StableInstall.ps1') -Raw
    $customSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\ChatGPTCustomLauncher.cs') -Raw
    $rootSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\ChatGPTRemoteLauncher.cs') -Raw
    $survivorSource = Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\UpdateSessionSurvivorLauncher.ps1') -Raw
    Assert-Condition ($sourceText.Contains('legacyInstallRoot') -and $sourceText.Contains('Invoke-StableLegacyCleanup') -and $sourceText.Contains('Invoke-PendingRecovery')) 'Interrupted legacy transaction recovery and post-update cleanup contracts are missing.'
    Assert-Condition ($customSource.Contains('PrepareDetachedTaskHost') -and $rootSource.Contains('PrepareDetachedTaskHost') -and $survivorSource.Contains('Copy-DetachedTaskHost')) 'Launch/update task hosts are still sourced from the replaceable stable root.'
    Assert-Condition (-not ($sourceText -match '(?i)junction|stable pointer')) 'The Windows design must not reintroduce a versioned pointer or junction.'
    Assert-Condition ($stableSource.Contains('$action.Path = $startupLauncher') -and $stableSource.Contains('foreign-canonical-shortcut-retained')) 'Stable migration lost the windowless logon launcher or foreign shortcut protection.'
    Assert-Condition (-not ($rootSource -match '(?i)Stop-Process.*ChatGPT|Kill.*ChatGPT') -and -not ($customSource -match '(?i)Stop-Process.*ChatGPT|Kill.*ChatGPT')) 'Launcher source contains an unauthorized ChatGPT lifecycle action.'

    [pscustomobject][ordered]@{
        Ok = $true
        CanonicalStableRootValidated = $true
        CurrentUserStableRoot = $true
        MachineStableRootRecognizedAsLegacy = $true
        NoncanonicalEntryPointMigrationRejected = $true
        BoundedRollbackRetention = $true
        LockedDetachedHostDoesNotBlockStableUpdate = $true
        DetachedTaskHostLockRegression = $true
        LegacyAliasesConsolidated = $true
        StartupArgumentsPreserved = $true
        ReferencedLegacyRootRetained = $true
        LiveCoordinatorReferenceRetained = $true
        HistoricalSessionDoesNotBlockCleanup = $true
        UnreferencedLegacyRootCleaned = $true
        RollbackMaterialExternalized = $true
        AuxiliaryRollbackRemoved = $true
        InterruptedLegacyRecovery = $true
        LockedInRootFailureRecovers = $true
        NoPointerOrJunction = $true
        NoChatGptLifecycleCall = $true
    } | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
