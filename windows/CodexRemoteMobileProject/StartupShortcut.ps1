[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Remove', 'Probe')]
    [string]$Action = 'Probe',
    [string]$StartupPath,
    [string]$StableRoot,
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
$rollbackRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'ChatGPTRemoteEnabler\shortcut-rollback'
if (-not $StartupPath) { $StartupPath = [Environment]::GetFolderPath('Startup') }
$StartupPath = [IO.Path]::GetFullPath($StartupPath)
$shortcutPath = Join-Path $StartupPath 'ChatGPT Remote Enabler Startup.lnk'
$legacyDisabledPath = "$shortcutPath.disabled"
$legacyStartupPaths = @(
    (Join-Path $StartupPath 'ChatGPT Custom Startup.lnk'),
    (Join-Path $StartupPath 'ChatGPT Custom.lnk'),
    (Join-Path $StartupPath 'ChatGPT Remote Enabler.lnk')
)

function Backup-StartupArtifact {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $extension = [IO.Path]::GetExtension($Path)
    $backupPath = Join-Path $rollbackRoot "$Label-$computerName-$stamp$extension"
    Copy-Item -LiteralPath $Path -Destination $backupPath
    return $backupPath
}

function Get-StartupSummary {
    $installed = Test-Path -LiteralPath $shortcutPath -PathType Leaf
    $result = [ordered]@{
        host = $computerName
        shortcutPath = $shortcutPath
        stableRoot = $StableRoot
        installed = $installed
        legacyDisabledPresent = Test-Path -LiteralPath $legacyDisabledPath -PathType Leaf
        launcherPath = $launcherPath
        launcherPresent = Test-Path -LiteralPath $launcherPath -PathType Leaf
    }
    if ($result.launcherPresent) {
        $result.launcherVersion = (Get-Item -LiteralPath $launcherPath).VersionInfo.FileVersion
    }
    if ($installed) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $result.targetPath = $shortcut.TargetPath
        $result.arguments = $shortcut.Arguments
        $result.workingDirectory = $shortcut.WorkingDirectory
        $result.description = $shortcut.Description
        $result.proxyMode = $shortcut.Arguments -match '(?:^|\s)--proxy(?:\s|$)'
        $result.startupMode = $shortcut.Arguments -match '(?:^|\s)--startup(?:\s|$)'
    }
    return $result
}

switch ($Action) {
    'Install' {
        if (-not (Test-Path -LiteralPath $StartupPath -PathType Container)) {
            throw "Startup folder is missing: $StartupPath"
        }

        $backups = @()
        $stableRootResolved = Ensure-StableInstallRoot -SourceRoot $sourcePackageRoot -StableRoot $StableRoot
        $launcherPath = Join-Path $stableRootResolved 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            throw "Stable launcher is missing: $launcherPath"
        }
        $backup = Backup-StartupArtifact -Path $shortcutPath -Label 'startup-shortcut'
        if ($backup) { $backups += $backup }
        $legacyBackup = Backup-StartupArtifact -Path $legacyDisabledPath -Label 'legacy-disabled-startup-shortcut'
        if ($legacyBackup) { $backups += $legacyBackup }

        if ((Test-Path -LiteralPath $legacyDisabledPath -PathType Leaf) -and
            $PSCmdlet.ShouldProcess($legacyDisabledPath, 'remove obsolete disabled startup shortcut')) {
            Remove-Item -LiteralPath $legacyDisabledPath -Force
        }
        if ($PSCmdlet.ShouldProcess($shortcutPath, 'create ChatGPT Remote Enabler startup shortcut')) {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $launcherPath
            $shortcut.Arguments = if ($UseProxy) { '--proxy --startup' } else { '--startup' }
            $shortcut.WorkingDirectory = $stableRootResolved
            $shortcut.Description = if ($UseProxy) {
                'Start ChatGPT/Codex with the audited injection and Remote-control proxy after sign-in.'
            } else {
                'Start ChatGPT/Codex with the audited injection after sign-in.'
            }
            $shortcut.IconLocation = "$launcherPath,0"
            $shortcut.WindowStyle = 1
            $shortcut.Save()
        }

        foreach ($legacyPath in $legacyStartupPaths) {
            if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { continue }
            $legacyBackup = Backup-StartupArtifact -Path $legacyPath -Label 'legacy-startup-shortcut'
            if ($legacyBackup) { $backups += $legacyBackup }
            if ($PSCmdlet.ShouldProcess($legacyPath, 'migrate legacy startup shortcut')) {
                $shell = New-Object -ComObject WScript.Shell
                $existing = $shell.CreateShortcut($legacyPath)
                $legacyArguments = [string]$existing.Arguments
                $migrated = $shell.CreateShortcut($legacyPath)
                $migrated.TargetPath = $launcherPath
                $migrated.Arguments = if ($legacyArguments -match '(?:^|\s)--proxy(?:\s|$)') { '--proxy --startup' } else { '--startup' }
                $migrated.WorkingDirectory = $stableRootResolved
                $migrated.Description = 'ChatGPT Remote Enabler compatibility startup entry point.'
                $migrated.IconLocation = "$launcherPath,0"
                $migrated.WindowStyle = 1
                $migrated.Save()
            }
        }

        $result = Get-StartupSummary
        $result.backupPaths = @($backups)
        $result.stableRoot = $stableRootResolved
        $result.legacyMigration = @(Invoke-StableLegacyCleanup -StableRoot $stableRootResolved -ShortcutPaths (@($shortcutPath) + @($legacyStartupPaths)) -TaskNames @('Codex Remote Mobile Features at Logon') -MigrateEntryPoints)
        $result | ConvertTo-Json -Depth 4
    }
    'Remove' {
        $backups = @()
        foreach ($artifact in @(
            [ordered]@{ path = $shortcutPath; label = 'startup-shortcut' },
            [ordered]@{ path = $legacyDisabledPath; label = 'legacy-disabled-startup-shortcut' }
        ) + @($legacyStartupPaths | ForEach-Object {
            [ordered]@{ path = $_; label = 'legacy-startup-shortcut' }
        })) {
            $backup = Backup-StartupArtifact -Path $artifact.path -Label $artifact.label
            if ($backup) { $backups += $backup }
            if ((Test-Path -LiteralPath $artifact.path -PathType Leaf) -and
                $PSCmdlet.ShouldProcess($artifact.path, 'remove ChatGPT Remote Enabler startup artifact')) {
                Remove-Item -LiteralPath $artifact.path -Force
            }
        }
        $result = Get-StartupSummary
        $result.backupPaths = @($backups)
        $result | ConvertTo-Json -Depth 4
    }
    'Probe' {
        Get-StartupSummary | ConvertTo-Json -Depth 4
    }
}
