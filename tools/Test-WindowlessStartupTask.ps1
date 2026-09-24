$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'windows/StableInstall.ps1')
$fixtureStableRoot = Join-Path $root 'windows'
function Get-StableInstallRoot { $fixtureStableRoot }
# All scheduler operations below are in-memory doubles, never the live service.
function Get-ScheduledTask {
    param($TaskName, $ErrorAction)
    [pscustomobject]@{
        TaskName = $TaskName
        TaskPath = '\'
        State = $(if ($script:fixtureTaskDefinition.Settings.Enabled) { 'Ready' } else { 'Disabled' })
        Settings = [pscustomobject]@{ Enabled = [bool]$script:fixtureTaskDefinition.Settings.Enabled }
        Actions = @(
            [pscustomobject]@{ Execute = $script:fixtureTaskDefinition.Actions[0].Path; Arguments = $script:fixtureTaskDefinition.Actions[0].Arguments; WorkingDirectory = $script:fixtureTaskDefinition.Actions[0].WorkingDirectory }
        )
    }
}
function New-Object {
    param($ComObject)
    if ($ComObject -eq 'WScript.Shell') { return Microsoft.PowerShell.Utility\New-Object -ComObject $ComObject }
    if ($ComObject -ne 'Schedule.Service') { throw "Unexpected COM creation: $ComObject" }
    $script:fixtureTaskService
}
$script:fixtureTaskFolder = [pscustomobject]@{}
$script:fixtureTaskFolder | Add-Member ScriptMethod GetTask { param($name) [pscustomobject]@{ Definition = $script:fixtureTaskDefinition } }
$script:fixtureTaskFolder | Add-Member ScriptMethod RegisterTaskDefinition {
    param($name, $value, $flags, $user, $password, $logon, $security)
    if ($user -cne 'fixture\user' -or $logon -ne 3 -or $null -ne $password) { throw 'Principal changed' }
    $script:registrations++
}
$script:fixtureTaskService = [pscustomobject]@{}
$script:fixtureTaskService | Add-Member ScriptMethod Connect {}
$script:fixtureTaskService | Add-Member ScriptMethod GetFolder { param($path) $script:fixtureTaskFolder }
$script:fixtureTaskService | Add-Member ScriptMethod NewTask { throw 'Unexpected rollback in successful fixture' }
foreach ($enabled in @($false, $true)) {
    foreach ($proxy in @($false, $true)) {
        $script:fixtureTaskDefinition = [pscustomobject]@{
            XmlText = '<fixture />'
            Settings = [pscustomobject]@{ Enabled = $enabled; ExecutionTimeLimit = 'PT10M' }
            Principal = [pscustomobject]@{ RunLevel = 0; LogonType = 3; UserId = 'fixture\user' }
            Triggers = @([pscustomobject]@{ Delay = 'PT30S' })
            Actions = @([pscustomobject]@{
                Path = 'powershell.exe'
                Arguments = '-NoProfile -File "C:\old\MobileProjectStartup.ps1" -Action Run' + $(if ($proxy) { ' -UseProxy' } else { '' })
                WorkingDirectory = 'C:\old'
            })
        }
        $script:registrations = 0
        if (Test-StableEntryPointsMigrated -StableRoot $fixtureStableRoot -TaskNames @('fixture')) { throw 'Raw PowerShell task was accepted as windowless' }
        foreach ($pass in 1..2) {
            $result = @(Invoke-StableTaskMigration -StableRoot $fixtureStableRoot)
            $expected = if ($proxy) { '--proxy --startup' } else { '--startup' }
            if ($result.Count -ne 1 -or -not $result[0].migrated -or $script:fixtureTaskDefinition.Actions[0].Arguments -cne $expected -or
                $script:fixtureTaskDefinition.Actions[0].Path -cne (Join-Path $fixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe') -or
                $script:fixtureTaskDefinition.Settings.Enabled -ne $enabled -or $script:fixtureTaskDefinition.Settings.ExecutionTimeLimit -cne 'PT10M' -or
                $script:fixtureTaskDefinition.Triggers[0].Delay -cne 'PT30S' -or $script:fixtureTaskDefinition.Principal.RunLevel -ne 0) { throw 'GUI task migration changed settings or failed idempotence' }
            if (-not (Test-StableEntryPointsMigrated -StableRoot $fixtureStableRoot -TaskNames @('fixture'))) { throw 'GUI task commit probe failed' }
        }
        if ($script:registrations -ne 2) { throw 'Migration did not exercise the scheduler commit' }
    }
}
$startupFixture = Join-Path ([IO.Path]::GetTempPath()) ('windowless-startup-shortcuts-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $startupFixture -Force | Out-Null
    $fixtureDesktop = Join-Path $startupFixture 'desktop'
    $fixtureMenu = Join-Path $startupFixture 'menu'
    New-Item -ItemType Directory -Path $fixtureDesktop,$fixtureMenu -Force | Out-Null
    $shell = New-Object -ComObject 'WScript.Shell'
    $canonical = Join-Path $startupFixture 'ChatGPT Remote Enabler Startup.lnk'
    $legacyProxy = Join-Path $startupFixture 'ChatGPT Custom Startup.lnk'
    $legacyDirect = Join-Path $startupFixture 'ChatGPT Custom.lnk'
    foreach ($entry in @(
        [pscustomobject]@{ Path = $canonical; Arguments = '' },
        [pscustomobject]@{ Path = $legacyProxy; Arguments = '--proxy' },
        [pscustomobject]@{ Path = $legacyDirect; Arguments = '' }
    )) {
        $shortcut = $shell.CreateShortcut($entry.Path)
        $shortcut.TargetPath = Join-Path $fixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        $shortcut.Arguments = $entry.Arguments
        $shortcut.WorkingDirectory = $fixtureStableRoot
        $shortcut.Save()
    }
    $primary = @(Invoke-StableShortcutMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture -TaskPrimary)
    if ((Test-Path -LiteralPath $canonical) -or (Test-Path -LiteralPath $legacyProxy) -or (Test-Path -LiteralPath $legacyDirect)) { throw 'An enabled task primary left an owned startup duplicate.' }

    foreach ($entry in @(
        [pscustomobject]@{ Path = $canonical; Arguments = '' },
        [pscustomobject]@{ Path = $legacyProxy; Arguments = '--proxy' },
        [pscustomobject]@{ Path = $legacyDirect; Arguments = '' }
    )) {
        $shortcut = $shell.CreateShortcut($entry.Path)
        $shortcut.TargetPath = Join-Path $fixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        $shortcut.Arguments = $entry.Arguments
        $shortcut.WorkingDirectory = $fixtureStableRoot
        $shortcut.Save()
    }
    $saveLock = [IO.File]::Open($canonical, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failedSave = @(Invoke-StableShortcutMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture)
        if (-not @($failedSave | Where-Object { $_.reason -eq 'shortcut-migration-failed' }).Count -or
            -not (Test-Path -LiteralPath $legacyProxy) -or -not (Test-Path -LiteralPath $legacyDirect)) { throw 'Failed Startup replacement removed a working alias.' }
    } finally { $saveLock.Dispose() }
    $fallback = @(Invoke-StableShortcutMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture)
    $canonicalResult = $shell.CreateShortcut($canonical)
    if (-not (Test-Path -LiteralPath $canonical) -or $canonicalResult.Arguments -cne '--proxy --startup' -or (Test-Path -LiteralPath $legacyProxy) -or (Test-Path -LiteralPath $legacyDirect)) { throw 'Startup fallback did not consolidate to one protective proxy entry.' }

    # Exercise the production fast migration as the no-journal updater does:
    # an old PowerShell task is migrated first, then its enabled canonical task
    # becomes primary and all owned Startup-folder duplicates are removed.
    foreach ($entry in @(
        [pscustomobject]@{ Path = $legacyProxy; Arguments = '--proxy' },
        [pscustomobject]@{ Path = $legacyDirect; Arguments = '' }
    )) {
        $shortcut = $shell.CreateShortcut($entry.Path)
        $shortcut.TargetPath = Join-Path $fixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        $shortcut.Arguments = $entry.Arguments
        $shortcut.WorkingDirectory = $fixtureStableRoot
        $shortcut.Save()
    }
    $script:fixtureTaskDefinition = [pscustomobject]@{
        XmlText = '<fixture />'
        Settings = [pscustomobject]@{ Enabled = $true; ExecutionTimeLimit = 'PT10M' }
        Principal = [pscustomobject]@{ RunLevel = 0; LogonType = 3; UserId = 'fixture\user' }
        Triggers = @([pscustomobject]@{ Delay = 'PT30S' })
        Actions = @([pscustomobject]@{
            Path = 'powershell.exe'
            Arguments = '-NoProfile -File "C:\old\MobileProjectStartup.ps1" -Action Run'
            WorkingDirectory = 'C:\old'
        })
    }
    $knownFixtureEntryPoints = Get-StableKnownEntryPoints -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture
    if (Test-StableEntryPointsMigrated -StableRoot $fixtureStableRoot -ShortcutPaths $knownFixtureEntryPoints.ShortcutPaths -TaskNames $knownFixtureEntryPoints.TaskNames -StartupPath $startupFixture) {
        throw 'An old PowerShell task plus owned Startup duplicates was accepted as migrated.'
    }
    $script:registrations = 0
    $entryPointMigration = Invoke-StableEntryPointMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture
    if (-not $entryPointMigration.migrated -or -not $entryPointMigration.valid -or -not $entryPointMigration.taskPrimary -or
        $script:registrations -ne 1 -or $script:fixtureTaskDefinition.Actions[0].Path -cne (Join-Path $fixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe') -or
        $script:fixtureTaskDefinition.Actions[0].Arguments -cne '--proxy --startup' -or
        (Test-Path -LiteralPath $canonical) -or (Test-Path -LiteralPath $legacyProxy) -or (Test-Path -LiteralPath $legacyDirect)) {
        throw 'The production entry-point migration did not leave one enabled canonical startup task.'
    }
    $repeatEntryPointMigration = Invoke-StableEntryPointMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture
    if ($repeatEntryPointMigration.migrated -or -not $repeatEntryPointMigration.valid -or $repeatEntryPointMigration.reason -cne 'already-migrated' -or $script:registrations -ne 1) {
        throw 'The production entry-point migration was not idempotent.'
    }

    # A canonical task and individually valid manual shortcuts are not enough:
    # same-mode legacy aliases still require consolidation, while one opposite
    # mode alias remains as the user's alternate direct/proxy choice.
    $desktopCanonical = Join-Path $fixtureDesktop 'ChatGPT Remote Enabler.lnk'
    $desktopSameMode = Join-Path $fixtureDesktop 'ChatGPT Custom.lnk'
    $menuCanonical = Join-Path $fixtureMenu 'ChatGPT Remote Enabler.lnk'
    $menuAlternateMode = Join-Path $fixtureMenu 'ChatGPT Custom.lnk'
    foreach ($entry in @(
        [pscustomobject]@{ Path = $desktopCanonical; Target = (Join-Path $fixtureStableRoot 'ChatGPT Remote Enabler.exe'); Arguments = '' },
        [pscustomobject]@{ Path = $desktopSameMode; Target = (Join-Path $fixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'); Arguments = '' },
        [pscustomobject]@{ Path = $menuCanonical; Target = (Join-Path $fixtureStableRoot 'ChatGPT Remote Enabler.exe'); Arguments = '' },
        [pscustomobject]@{ Path = $menuAlternateMode; Target = (Join-Path $fixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'); Arguments = '--proxy' }
    )) {
        $shortcut = $shell.CreateShortcut($entry.Path)
        $shortcut.TargetPath = $entry.Target
        $shortcut.Arguments = $entry.Arguments
        $shortcut.WorkingDirectory = $fixtureStableRoot
        $shortcut.Save()
    }
    if (Test-StableEntryPointsMigrated -StableRoot $fixtureStableRoot -ShortcutPaths $knownFixtureEntryPoints.ShortcutPaths -TaskNames $knownFixtureEntryPoints.TaskNames -StartupPath $startupFixture) {
        throw 'A same-mode manual shortcut alias incorrectly qualified as fully migrated.'
    }
    $manualMigration = Invoke-StableEntryPointMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture
    if (-not $manualMigration.migrated -or -not $manualMigration.valid -or (Test-Path -LiteralPath $desktopSameMode) -or
        -not (Test-Path -LiteralPath $desktopCanonical -PathType Leaf) -or -not (Test-Path -LiteralPath $menuCanonical -PathType Leaf) -or
        -not (Test-Path -LiteralPath $menuAlternateMode -PathType Leaf) -or $script:registrations -ne 2) {
        throw 'The fast entry-point migration did not consolidate same-mode aliases while preserving the alternate mode.'
    }
    $manualRepeat = Invoke-StableEntryPointMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture
    if ($manualRepeat.migrated -or -not $manualRepeat.valid -or $manualRepeat.reason -cne 'already-migrated' -or $script:registrations -ne 2) {
        throw 'The consolidated manual entry points did not pass the idempotent preflight.'
    }

    # A foreign canonical shortcut owns its filename, but owned aliases beside
    # it must still stop targeting a retired installation. Preserve both alias
    # modes and their user metadata instead of consolidating or deleting them.
    foreach ($path in @(
        $menuCanonical,
        $menuAlternateMode,
        (Join-Path $fixtureMenu 'ChatGPT Custom (Proxy Test).lnk'),
        (Join-Path $fixtureMenu 'ChatGPT Custom (Proxy).lnk')
    )) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    $foreignRoot = Join-Path $startupFixture 'foreign-owner'
    New-Item -ItemType Directory -Path $foreignRoot -Force | Out-Null
    $foreignTarget = Join-Path $foreignRoot 'Foreign Launcher.exe'
    [IO.File]::WriteAllText($foreignTarget, 'foreign', [Text.UTF8Encoding]::new($false))
    $foreignCanonical = $shell.CreateShortcut($menuCanonical)
    $foreignCanonical.TargetPath = $foreignTarget
    $foreignCanonical.Arguments = '--foreign-mode'
    $foreignCanonical.WorkingDirectory = $foreignRoot
    $foreignCanonical.Description = 'Foreign canonical metadata'
    $foreignCanonical.IconLocation = "$foreignTarget,0"
    $foreignCanonical.WindowStyle = 7
    $foreignCanonical.Save()
    $foreignBefore = $shell.CreateShortcut($menuCanonical)

    $commonDataForRetiredAlias = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonDataForRetiredAlias)) { $commonDataForRetiredAlias = $env:ProgramData }
    $retiredAliasRoot = Join-Path $commonDataForRetiredAlias 'CodexRemoteFeatures\releases\ChatGPT-Remote-Enabler-Windows-x64-v98.76.53'
    $retiredAliasTarget = Join-Path $retiredAliasRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    $directAliasPath = Join-Path $fixtureMenu 'ChatGPT Custom.lnk'
    $proxyAliasPath = Join-Path $fixtureMenu 'ChatGPT Custom (Proxy Test).lnk'
    foreach ($entry in @(
        [pscustomobject]@{ Path = $directAliasPath; Arguments = ''; Description = 'User direct metadata'; WindowStyle = 7 },
        [pscustomobject]@{ Path = $proxyAliasPath; Arguments = '--proxy'; Description = 'User proxy metadata'; WindowStyle = 3 }
    )) {
        $shortcut = $shell.CreateShortcut($entry.Path)
        $shortcut.TargetPath = $retiredAliasTarget
        $shortcut.Arguments = $entry.Arguments
        $shortcut.WorkingDirectory = $retiredAliasRoot
        $shortcut.Description = $entry.Description
        $shortcut.IconLocation = "$retiredAliasTarget,0"
        $shortcut.WindowStyle = $entry.WindowStyle
        $shortcut.Save()
    }
    if (Test-StableEntryPointsMigrated -StableRoot $fixtureStableRoot -ShortcutPaths $knownFixtureEntryPoints.ShortcutPaths -TaskNames $knownFixtureEntryPoints.TaskNames -StartupPath $startupFixture) {
        throw 'Owned aliases targeting a retired install beside a foreign canonical entry were accepted as migrated.'
    }
    $foreignMigration = Invoke-StableEntryPointMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture
    $foreignAfter = $shell.CreateShortcut($menuCanonical)
    $directAfter = $shell.CreateShortcut($directAliasPath)
    $proxyAfter = $shell.CreateShortcut($proxyAliasPath)
    $stableCustomLauncher = Join-Path $fixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    if (-not $foreignMigration.migrated -or -not $foreignMigration.valid -or
        @($foreignMigration.shortcuts | Where-Object { $_.reason -eq 'foreign-canonical-alias-retargeted' }).Count -ne 2 -or
        -not [string]::Equals($foreignAfter.TargetPath, $foreignBefore.TargetPath, [StringComparison]::OrdinalIgnoreCase) -or
        $foreignAfter.Arguments -cne $foreignBefore.Arguments -or $foreignAfter.WorkingDirectory -cne $foreignBefore.WorkingDirectory -or
        $foreignAfter.Description -cne $foreignBefore.Description -or $foreignAfter.IconLocation -cne $foreignBefore.IconLocation -or $foreignAfter.WindowStyle -ne $foreignBefore.WindowStyle -or
        -not [string]::Equals($directAfter.TargetPath, $stableCustomLauncher, [StringComparison]::OrdinalIgnoreCase) -or $directAfter.Arguments -cne '' -or
        $directAfter.Description -cne 'User direct metadata' -or $directAfter.WindowStyle -ne 7 -or
        -not [string]::Equals($proxyAfter.TargetPath, $stableCustomLauncher, [StringComparison]::OrdinalIgnoreCase) -or $proxyAfter.Arguments -cne '--proxy' -or
        $proxyAfter.Description -cne 'User proxy metadata' -or $proxyAfter.WindowStyle -ne 3 -or $script:registrations -ne 3) {
        throw 'Owned aliases beside a foreign canonical shortcut were not safely retargeted in place.'
    }
    $foreignRepeat = Invoke-StableEntryPointMigration -StableRoot $fixtureStableRoot -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $startupFixture
    if ($foreignRepeat.migrated -or -not $foreignRepeat.valid -or $foreignRepeat.reason -cne 'already-migrated' -or $script:registrations -ne 3) {
        throw 'Foreign-canonical alias retargeting did not become idempotent.'
    }

    $noncanonical = @(Invoke-StableEntryPointMigration -StableRoot (Join-Path $startupFixture 'noncanonical-root'))
    if ($noncanonical.Count -ne 1 -or $noncanonical[0].reason -cne 'noncanonical-root-requires-explicit-shortcut-folders' -or $script:registrations -ne 3) {
        throw 'A noncanonical fixture root was allowed to reach real entry-point defaults.'
    }
} finally {
    if (Test-Path -LiteralPath $startupFixture) { Remove-Item -LiteralPath $startupFixture -Recurse -Force }
}

# The startup installer must retain its exact shortcut commit probe, then
# report a fresh summary after cleanup removes the Startup shortcut for an
# enabled task primary. This isolated harness replaces only the cleanup call;
# all paths are temporary fixtures and no scheduler or real shell folder is
# consulted.
$startupSourcePath = Join-Path $root 'windows/CodexRemoteMobileProject/StartupShortcut.ps1'
$startupSource = Get-Content -LiteralPath $startupSourcePath -Raw
$cleanupCallIndex = $startupSource.IndexOf('Invoke-StableLegacyCleanup', [StringComparison]::Ordinal)
$postCleanupProbeIndex = $startupSource.LastIndexOf('$result = Get-StartupSummary', [StringComparison]::Ordinal)
$preCleanupProbeIndex = $startupSource.IndexOf('$result = Get-StartupSummary', [StringComparison]::Ordinal)
if ($preCleanupProbeIndex -lt 0 -or $cleanupCallIndex -lt 0 -or $postCleanupProbeIndex -le $cleanupCallIndex) {
    throw 'Startup install lost its pre-cleanup commit probe or post-cleanup re-probe.'
}
$startupCleanupFixture = Join-Path ([IO.Path]::GetTempPath()) ('windowless-startup-cleanup-' + [guid]::NewGuid().ToString('N'))
try {
    $startupFixturePath = Join-Path $startupCleanupFixture 'Startup'
    $startupRollback = Join-Path $startupCleanupFixture 'rollback'
    New-Item -ItemType Directory -Path $startupFixturePath,$startupRollback -Force | Out-Null
    $bundleLiteral = "'" + (Join-Path $root 'windows/CodexRemoteMobileProject').Replace("'", "''") + "'"
    $startupHarnessSource = $startupSource.Replace('$PSScriptRoot', $bundleLiteral).Replace('. $stableModule', @'
function Ensure-StableInstallRoot {
    param([string]$SourceRoot, [string]$StableRoot)
    return [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
}
function Invoke-StableLegacyCleanup {
    param(
        [string]$StableRoot,
        [string]$UpdaterStateRoot,
        [string[]]$ShortcutPaths,
        [string[]]$TaskNames,
        [string]$StartupPath,
        [switch]$MigrateEntryPoints
    )
    foreach ($path in @($ShortcutPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
    [pscustomobject][ordered]@{
        cleaned = $true
        startupPath = $StartupPath
        taskPrimary = $true
        migrateEntryPoints = [bool]$MigrateEntryPoints
    }
}
'@)
    $startupHarness = [scriptblock]::Create($startupHarnessSource)
    $startupInstall = @(& $startupHarness -Action Install -StableRoot $fixtureStableRoot -StartupPath $startupFixturePath -RollbackRoot $startupRollback -Confirm:$false | ConvertFrom-Json)
    if ($startupInstall.Count -ne 1 -or $startupInstall[0].installed -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$startupInstall[0].legacyMigration.startupPath), [IO.Path]::GetFullPath($startupFixturePath), [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath (Join-Path $startupFixturePath 'ChatGPT Remote Enabler Startup.lnk') -PathType Leaf) -or
        (Test-Path -LiteralPath $startupRollback)) {
        throw 'Startup install reported its cached pre-cleanup state or touched the wrong fixture.'
    }
} finally {
    if (Test-Path -LiteralPath $startupCleanupFixture) { Remove-Item -LiteralPath $startupCleanupFixture -Recurse -Force }
}

# Missing historical launchers are trusted only for an exact known parent and
# approved package leaf. Use a unique, absent leaf so these checks never treat
# a live installation as a fixture.
$trustedLeaf = 'ChatGPT-Remote-Enabler-Windows-x64-v98.76.54'
$commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if ([string]::IsNullOrWhiteSpace($commonData)) { $commonData = $env:ProgramData }
$localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($localData)) { $localData = $env:LOCALAPPDATA }
$trustedHistoricalRoots = @(
    (Join-Path $commonData ('CodexRemoteFeatures\releases\' + $trustedLeaf)),
    (Join-Path $commonData ('CodexRemoteFeatures\' + $trustedLeaf)),
    (Join-Path $commonData $trustedLeaf),
    (Join-Path $localData ('CodexRemoteFeatures\' + $trustedLeaf)),
    (Join-Path $localData ('CodexRemoteFeatures\releases\' + $trustedLeaf)),
    (Join-Path $localData ('Programs\' + $trustedLeaf))
)
foreach ($historicalRoot in $trustedHistoricalRoots) {
    $missingLauncher = Join-Path $historicalRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    if (-not (Test-StableOwnedLauncherPath -TargetPath $missingLauncher -StableRoot $fixtureStableRoot)) {
        throw "An accepted historical launcher parent was rejected: $historicalRoot"
    }
}
$unrelatedRoots = @(
    (Join-Path ($commonData + '-prefix') $trustedLeaf),
    (Join-Path $commonData ('CodexRemoteFeatures-sibling\' + $trustedLeaf)),
    (Join-Path $commonData ('CodexRemoteFeatures\releases-sibling\' + $trustedLeaf)),
    (Join-Path $commonData ('CodexRemoteFeatures\' + $trustedLeaf + '-sibling'))
)
foreach ($unrelatedRoot in $unrelatedRoots) {
    $missingLauncher = Join-Path $unrelatedRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    if (Test-StableOwnedLauncherPath -TargetPath $missingLauncher -StableRoot $fixtureStableRoot) {
        throw "An unrelated historical launcher parent or sibling was accepted: $unrelatedRoot"
    }
}
$wrongRelativeTarget = Join-Path $trustedHistoricalRoots[0] 'arbitrary\ChatGPT Custom.exe'
if (Test-StableOwnedLauncherPath -TargetPath $wrongRelativeTarget -StableRoot $fixtureStableRoot) {
    throw 'A missing launcher with the wrong relative path was accepted beneath a trusted parent.'
}

$startup = Get-Content -LiteralPath (Join-Path $root 'windows/CodexRemoteMobileProject/MobileProjectStartup.ps1') -Raw
if (-not $startup.Contains('New-ScheduledTaskAction -Execute $startupLauncher') -or
    -not $startup.Contains("'--proxy --startup'")) { throw 'New task installation does not use the same GUI launcher contract' }

# Exercise the actual legacy-cleanup migration prefix with only the mutating
# task/shortcut helpers stubbed. Every discovered and migrated shell path must
# remain inside the explicit temporary fixture.
$cleanupPrefixFixture = Join-Path ([IO.Path]::GetTempPath()) ('windowless-cleanup-prefix-' + [guid]::NewGuid().ToString('N'))
try {
    $cleanupDesktop = Join-Path $cleanupPrefixFixture 'desktop'
    $cleanupMenu = Join-Path $cleanupPrefixFixture 'menu'
    $cleanupStartup = Join-Path $cleanupPrefixFixture 'startup'
    $cleanupState = Join-Path $cleanupPrefixFixture 'state'
    $invalidLegacy = Join-Path $cleanupPrefixFixture 'invalid-legacy-name'
    New-Item -ItemType Directory -Path $cleanupDesktop,$cleanupMenu,$cleanupStartup,$invalidLegacy -Force | Out-Null
    $script:cleanupTaskStartupPaths = @()
    $script:cleanupShortcutCall = $null
    $script:cleanupProbe = $null
    function Test-StablePackage { param([string]$Root, [switch]$RequireManifest, [switch]$RequireExactInventory) return $true }
    function Invoke-StableTaskMigration {
        param([string]$StableRoot, [string[]]$StartupShortcutPaths)
        $script:cleanupTaskStartupPaths = @($StartupShortcutPaths)
        return @()
    }
    function Invoke-StableShortcutMigration {
        param([string]$StableRoot, [string]$DesktopPath, [string]$StartMenuPath, [string]$StartupPath, [switch]$TaskPrimary)
        $script:cleanupShortcutCall = [pscustomobject]@{ DesktopPath = $DesktopPath; StartMenuPath = $StartMenuPath; StartupPath = $StartupPath }
        return @()
    }
    function Test-StableEntryPointsMigrated {
        param([string]$StableRoot, [string[]]$ShortcutPaths, [string[]]$TaskNames, [string]$StartupPath)
        $script:cleanupProbe = [pscustomobject]@{ ShortcutPaths = @($ShortcutPaths); StartupPath = $StartupPath }
        return $true
    }
    $cleanupPrefixResult = @(Invoke-StableLegacyCleanup -StableRoot $fixtureStableRoot -UpdaterStateRoot $cleanupState -MigrateEntryPoints `
        -DesktopPath $cleanupDesktop -StartMenuPath $cleanupMenu -StartupPath $cleanupStartup `
        -LegacyRoots @($invalidLegacy) -ApprovedLegacyParents @($cleanupPrefixFixture))
    $expectedDesktop = Join-Path $cleanupDesktop 'ChatGPT Remote Enabler.lnk'
    $expectedMenu = Join-Path $cleanupMenu 'ChatGPT Remote Enabler.lnk'
    $expectedStartup = Join-Path $cleanupStartup 'ChatGPT Remote Enabler Startup.lnk'
    if (-not $script:cleanupShortcutCall -or
        -not [string]::Equals($script:cleanupShortcutCall.DesktopPath, $cleanupDesktop, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($script:cleanupShortcutCall.StartMenuPath, $cleanupMenu, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($script:cleanupShortcutCall.StartupPath, $cleanupStartup, [StringComparison]::OrdinalIgnoreCase) -or
        $expectedDesktop -notin $script:cleanupProbe.ShortcutPaths -or $expectedMenu -notin $script:cleanupProbe.ShortcutPaths -or
        $expectedStartup -notin $script:cleanupTaskStartupPaths -or $expectedStartup -notin $script:cleanupProbe.ShortcutPaths -or
        -not [string]::Equals($script:cleanupProbe.StartupPath, $cleanupStartup, [StringComparison]::OrdinalIgnoreCase) -or
        $cleanupPrefixResult.Count -ne 1 -or $cleanupPrefixResult[0].reason -cne 'legacy-root-name-not-approved') {
        throw 'Legacy cleanup did not propagate explicit Desktop, Start-menu, and Startup fixture paths through its migration prefix.'
    }
} finally {
    $resolvedCleanupFixture = [IO.Path]::GetFullPath($cleanupPrefixFixture).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedCleanupFixture) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolvedCleanupFixture) -notmatch '^windowless-cleanup-prefix-[0-9a-f]{32}$') { throw 'Unsafe cleanup-prefix fixture path.' }
    if (Test-Path -LiteralPath $resolvedCleanupFixture) { Remove-Item -LiteralPath $resolvedCleanupFixture -Recurse -Force }
}
'Windowless startup task regression passed (direct/proxy, enabled/disabled, migration and repeat).'
