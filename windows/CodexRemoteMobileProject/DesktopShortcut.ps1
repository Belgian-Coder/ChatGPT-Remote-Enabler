[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Remove', 'Probe')]
    [string]$Action = 'Probe',
    [string]$DesktopPath,
    [string]$StartMenuPath,
    [string]$StableRoot,
    [string]$RollbackRoot,
    [switch]$UseProxy
)

$ErrorActionPreference = 'Stop'
$computerName = $env:COMPUTERNAME.ToUpperInvariant()

$bundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$sourcePackageRoot = Split-Path -Parent $bundleRoot
$stableModule = Join-Path $sourcePackageRoot 'StableInstall.ps1'
if (-not (Test-Path -LiteralPath $stableModule -PathType Leaf)) { throw "Stable installation resolver is missing: $stableModule" }
. $stableModule
if ([string]::IsNullOrWhiteSpace($StableRoot)) { $StableRoot = Get-StableInstallRoot }
$StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
$launcherPath = Join-Path $StableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
$rootLauncherPath = Join-Path $StableRoot 'ChatGPT Remote Enabler.exe'
if ([string]::IsNullOrWhiteSpace($RollbackRoot)) {
    $RollbackRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'ChatGPTRemoteEnabler\shortcut-rollback'
}
$rollbackRoot = [IO.Path]::GetFullPath($RollbackRoot).TrimEnd('\')
if (-not $DesktopPath) { $DesktopPath = [Environment]::GetFolderPath('Desktop') }
if (-not $StartMenuPath) { $StartMenuPath = [Environment]::GetFolderPath('Programs') }
$DesktopPath = [IO.Path]::GetFullPath($DesktopPath)
$StartMenuPath = [IO.Path]::GetFullPath($StartMenuPath)
$legacyShortcutTargets = @(
    [ordered]@{ kind = 'LegacyDesktop'; path = Join-Path $DesktopPath 'ChatGPT Custom.lnk'; launcher = $launcherPath },
    [ordered]@{ kind = 'LegacyStartMenu'; path = Join-Path $StartMenuPath 'ChatGPT Custom.lnk'; launcher = $launcherPath },
    [ordered]@{ kind = 'LegacyStartMenuProxyTest'; path = Join-Path $StartMenuPath 'ChatGPT Custom (Proxy Test).lnk'; launcher = $launcherPath },
    [ordered]@{ kind = 'LegacyStartMenuProxy'; path = Join-Path $StartMenuPath 'ChatGPT Custom (Proxy).lnk'; launcher = $launcherPath }
)

function Get-ExistingProxyPreference {
    param([string[]]$Paths)
    $shell = New-Object -ComObject WScript.Shell
    foreach ($path in @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })) {
        try {
            $shortcut = $shell.CreateShortcut($path)
            if (Test-StableOwnedLauncherPath -TargetPath ([string]$shortcut.TargetPath) -StableRoot $StableRoot) {
                return [pscustomobject]@{
                    found = $true
                    proxyMode = ([string]$shortcut.Arguments -match '(?:^|\s)--proxy(?:\s|$)')
                }
            }
        } catch { continue }
    }
    return [pscustomobject]@{ found = $false; proxyMode = $false }
}

$proxyModeExplicit = $PSBoundParameters.ContainsKey('UseProxy')
$desktopUseProxy = [bool]$UseProxy
$startMenuUseProxy = [bool]$UseProxy
if (-not $proxyModeExplicit) {
    $desktopPreference = Get-ExistingProxyPreference -Paths @(
        (Join-Path $DesktopPath 'ChatGPT Remote Enabler.lnk'),
        (Join-Path $DesktopPath 'ChatGPT Custom.lnk')
    )
    $startMenuPreference = Get-ExistingProxyPreference -Paths @(
        (Join-Path $StartMenuPath 'ChatGPT Remote Enabler.lnk'),
        (Join-Path $StartMenuPath 'ChatGPT Custom.lnk'),
        (Join-Path $StartMenuPath 'ChatGPT Custom (Proxy Test).lnk'),
        (Join-Path $StartMenuPath 'ChatGPT Custom (Proxy).lnk')
    )
    $desktopUseProxy = [bool]$desktopPreference.proxyMode
    $startMenuUseProxy = [bool]$startMenuPreference.proxyMode
    if (-not $desktopPreference.found -and $startMenuPreference.found) {
        $desktopUseProxy = [bool]$startMenuPreference.proxyMode
    } elseif (-not $startMenuPreference.found -and $desktopPreference.found) {
        $startMenuUseProxy = [bool]$desktopPreference.proxyMode
    }
}
$effectiveUseProxy = $desktopUseProxy -or $startMenuUseProxy
$desktopArguments = if ($desktopUseProxy) { '--proxy' } else { '' }
$startMenuArguments = if ($startMenuUseProxy) { '--proxy' } else { '' }
$desktopDescription = if ($desktopUseProxy) {
    'Open ChatGPT with Remote Enabler and proxy mode, or attach to a compatible running session.'
} else {
    'Open ChatGPT with Remote Enabler, or attach to a compatible running session.'
}
$startMenuDescription = if ($startMenuUseProxy) {
    'Open ChatGPT with Remote Enabler and proxy mode, or attach to a compatible running session.'
} else {
    'Open ChatGPT with Remote Enabler, or attach to a compatible running session.'
}
$primaryShortcutTargets = @(
    [ordered]@{ kind = 'Desktop'; path = Join-Path $DesktopPath 'ChatGPT Remote Enabler.lnk'; arguments = $desktopArguments; description = $desktopDescription },
    [ordered]@{ kind = 'StartMenu'; path = Join-Path $StartMenuPath 'ChatGPT Remote Enabler.lnk'; arguments = $startMenuArguments; description = $startMenuDescription }
)
$shortcutTargets = @($primaryShortcutTargets)
$summaryTargets = @($primaryShortcutTargets)

function Backup-Shortcut {
    param([string]$Path, [string]$Kind)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupPath = Join-Path $rollbackRoot "$($Kind.ToLowerInvariant())-shortcut-$computerName-$stamp.lnk"
    Copy-Item -LiteralPath $Path -Destination $backupPath
    return $backupPath
}

function Get-ShortcutSummary {
    $shell = New-Object -ComObject WScript.Shell
    $entries = foreach ($target in $summaryTargets) {
        $installed = Test-Path -LiteralPath $target.path -PathType Leaf
        $entry = [ordered]@{ kind = $target.kind; path = $target.path; installed = $installed; owned = $false }
        if ($installed) {
            $shortcut = $shell.CreateShortcut($target.path)
            $entry.targetPath = $shortcut.TargetPath
            $entry.arguments = $shortcut.Arguments
            $entry.workingDirectory = $shortcut.WorkingDirectory
            $entry.description = $shortcut.Description
            $entry.owned = Test-StableOwnedLauncherPath -TargetPath ([string]$shortcut.TargetPath) -StableRoot $StableRoot
        }
        [pscustomobject]$entry
    }
    return [ordered]@{
        host = $computerName
        stableRoot = $StableRoot
        launcherPath = $rootLauncherPath
        launcherPresent = Test-Path -LiteralPath $rootLauncherPath -PathType Leaf
        requestedProxyMode = [bool]$effectiveUseProxy
        shortcuts = @($entries)
        legacyShortcuts = @($legacyShortcutTargets | ForEach-Object {
            $installed = Test-Path -LiteralPath $_.path -PathType Leaf
            $entry = [ordered]@{ kind = $_.kind; path = $_.path; installed = $installed; owned = $false }
            if ($installed) {
                $shortcut = $shell.CreateShortcut($_.path)
                $entry.targetPath = $shortcut.TargetPath
                $entry.arguments = $shortcut.Arguments
                $entry.owned = Test-StableOwnedLauncherPath -TargetPath ([string]$shortcut.TargetPath) -StableRoot $StableRoot
            }
            [pscustomobject]$entry
        })
    }
}

function Complete-ShortcutBackups {
    param([string[]]$Paths)
    foreach ($path in @($Paths | Where-Object { $_ } | Select-Object -Unique)) {
        $resolved = [IO.Path]::GetFullPath($path)
        $parent = [IO.Path]::GetFullPath((Split-Path -Parent $resolved)).TrimEnd('\')
        if (-not [string]::Equals($parent, $rollbackRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Shortcut backup escaped its rollback root: $resolved"
        }
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { Remove-Item -LiteralPath $resolved -Force -ErrorAction Stop }
    }
    if ((Test-Path -LiteralPath $rollbackRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $rollbackRoot -Force -ErrorAction Stop).Count -eq 0) {
        Remove-Item -LiteralPath $rollbackRoot -Force -ErrorAction Stop
    }
}

switch ($Action) {
    'Install' {
        $backups = @()
        $stableRootResolved = Ensure-StableInstallRoot -SourceRoot $sourcePackageRoot -StableRoot $StableRoot
        $launcherPath = Join-Path $stableRootResolved 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        $rootLauncherPath = Join-Path $stableRootResolved 'ChatGPT Remote Enabler.exe'
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf) -or -not (Test-Path -LiteralPath $rootLauncherPath -PathType Leaf)) {
            throw "Stable launchers are missing: $stableRootResolved"
        }
        $shell = New-Object -ComObject WScript.Shell
        foreach ($target in $shortcutTargets) {
            $existing = Get-StableShortcutRecord -Shell $shell -Path $target.path -StableRoot $stableRootResolved
            if ($existing -and -not $existing.owned) {
                throw "Refusing to overwrite a foreign shortcut at $($target.path)."
            }
        }
        foreach ($target in $shortcutTargets) {
            $parent = Split-Path -Parent $target.path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                throw "Shortcut folder is missing: $parent"
            }
            $backup = Backup-Shortcut -Path $target.path -Kind $target.kind
            if ($backup) { $backups += $backup }
            if ($PSCmdlet.ShouldProcess($target.path, 'create ChatGPT Remote Enabler shortcut')) {
                $shortcut = $shell.CreateShortcut($target.path)
                $shortcut.TargetPath = $rootLauncherPath
                $shortcut.Arguments = $target.arguments
                $shortcut.WorkingDirectory = $stableRootResolved
                $shortcut.Description = $target.description
                $shortcut.IconLocation = "$rootLauncherPath,0"
                $shortcut.WindowStyle = 1
                $shortcut.Save()
            }
        }
        $result = Get-ShortcutSummary
        if (-not $result.launcherPresent -or @($result.shortcuts | Where-Object { -not $_.installed -or -not $_.owned }).Count -ne 0) {
            throw 'Shortcut installation did not pass its commit probe; rollback copies were retained.'
        }
        foreach ($shortcut in @($result.shortcuts)) {
            $expected = @($shortcutTargets | Where-Object kind -eq $shortcut.kind)[0]
            if (-not [string]::Equals([IO.Path]::GetFullPath([string]$shortcut.targetPath), [IO.Path]::GetFullPath($rootLauncherPath), [StringComparison]::OrdinalIgnoreCase) -or
                [string]$shortcut.arguments -cne [string]$expected.arguments -or
                -not [string]::Equals([IO.Path]::GetFullPath([string]$shortcut.workingDirectory), [IO.Path]::GetFullPath($stableRootResolved), [StringComparison]::OrdinalIgnoreCase)) {
                throw "The $($shortcut.kind) shortcut failed its exact commit probe; rollback copies were retained."
            }
        }
        # Remove validated aliases after both canonical entries have committed.
        # Keep one alternate-mode alias per folder when it is the only remaining
        # direct/proxy choice; same-mode duplicates are consolidated. Foreign
        # same-named/user-created shortcuts are retained and reported.
        $shell = New-Object -ComObject WScript.Shell
        $canonicalProxyByKind = @{}
        foreach ($entry in @($result.shortcuts)) {
            $canonicalProxyByKind[[string]$entry.kind] = ([string]$entry.arguments -match '(?:^|\s)--proxy(?:\s|$)')
        }
        $retainedAlternateByKind = @{}
        foreach ($target in $legacyShortcutTargets) {
            $record = Get-StableShortcutRecord -Shell $shell -Path $target.path -StableRoot $stableRootResolved
            if (-not $record -or -not $record.owned) { continue }
            $kind = if ($target.kind -eq 'LegacyDesktop') { 'Desktop' } else { 'StartMenu' }
            $canonicalProxy = [bool]$canonicalProxyByKind[$kind]
            if ([bool]$record.proxyMode -ne $canonicalProxy -and -not $retainedAlternateByKind.ContainsKey($kind)) {
                $backup = Backup-Shortcut -Path $target.path -Kind $target.kind
                if ($backup) { $backups += $backup }
                $alternate = $shell.CreateShortcut($target.path)
                $alternate.TargetPath = $launcherPath
                $alternate.Arguments = if ($record.proxyMode) { '--proxy' } else { '' }
                $alternate.WorkingDirectory = $stableRootResolved
                $alternate.Description = 'ChatGPT Remote Enabler compatibility entry point.'
                $alternate.IconLocation = "$launcherPath,0"
                $alternate.WindowStyle = 1
                $alternate.Save()
                $writtenAlternate = Get-StableShortcutRecord -Shell $shell -Path $target.path -StableRoot $stableRootResolved
                if (-not $writtenAlternate -or -not $writtenAlternate.owned -or
                    ([bool]$writtenAlternate.proxyMode -ne [bool]$record.proxyMode)) {
                    throw "The $kind alternate-mode shortcut failed its exact commit probe; rollback copies were retained."
                }
                $retainedAlternateByKind[$kind] = $true
                continue
            }
            $backup = Backup-Shortcut -Path $target.path -Kind $target.kind
            if ($backup) { $backups += $backup }
            if ($PSCmdlet.ShouldProcess($target.path, 'remove obsolete owned ChatGPT Custom shortcut')) {
                Remove-Item -LiteralPath $target.path -Force -ErrorAction Stop
            }
        }
        $result = Get-ShortcutSummary
        foreach ($kind in @('Desktop','StartMenu')) {
            $canonicalProxy = [bool]$canonicalProxyByKind[$kind]
            $legacyKind = if ($kind -eq 'Desktop') { 'LegacyDesktop' } else { 'LegacyStartMenu','LegacyStartMenuProxyTest','LegacyStartMenuProxy' }
            $ownedAliases = @($result.legacyShortcuts | Where-Object { $_.installed -and $_.owned -and $_.kind -in @($legacyKind) })
            if (@($ownedAliases | Where-Object { ([string]$_.arguments -match '(?:^|\s)--proxy(?:\s|$)') -eq $canonicalProxy }).Count -gt 0 -or
                @($ownedAliases | Where-Object { ([string]$_.arguments -match '(?:^|\s)--proxy(?:\s|$)') -ne $canonicalProxy }).Count -gt 1) {
                throw 'Owned legacy shortcut consolidation did not pass its mode commit probe; rollback copies were retained.'
            }
        }
        Complete-ShortcutBackups -Paths $backups
        $result.backupPaths = @()
        $result.stableRoot = $stableRootResolved
        $result.legacyMigration = @(Invoke-StableLegacyCleanup -StableRoot $stableRootResolved -ShortcutPaths (@($shortcutTargets.path) + @($legacyShortcutTargets.path)) -TaskNames @('Codex Remote Mobile Features at Logon') -MigrateEntryPoints)
        $result | ConvertTo-Json -Depth 4
    }
    'Remove' {
        $backups = @()
        $shell = New-Object -ComObject WScript.Shell
        foreach ($target in @($summaryTargets) + @($legacyShortcutTargets)) {
            $record = Get-StableShortcutRecord -Shell $shell -Path $target.path -StableRoot $StableRoot
            if (-not $record -or -not $record.owned) { continue }
            $backup = Backup-Shortcut -Path $target.path -Kind $target.kind
            if ($backup) { $backups += $backup }
            if ((Test-Path -LiteralPath $target.path -PathType Leaf) -and
                $PSCmdlet.ShouldProcess($target.path, 'remove owned ChatGPT Remote Enabler shortcut')) {
                Remove-Item -LiteralPath $target.path -Force
            }
        }
        $result = Get-ShortcutSummary
        if (@($result.shortcuts | Where-Object { $_.installed -and $_.owned }).Count -ne 0 -or
            @($result.legacyShortcuts | Where-Object { $_.installed -and $_.owned }).Count -ne 0) {
            throw 'Owned shortcut removal did not pass its commit probe; rollback copies were retained.'
        }
        Complete-ShortcutBackups -Paths $backups
        $result.backupPaths = @()
        $result | ConvertTo-Json -Depth 4
    }
    'Probe' {
        Get-ShortcutSummary | ConvertTo-Json -Depth 4
    }
}
