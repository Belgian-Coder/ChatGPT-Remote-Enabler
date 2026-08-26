[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Remove', 'Probe')]
    [string]$Action = 'Probe',
    [string]$StartupPath,
    [switch]$UseProxy
)

$ErrorActionPreference = 'Stop'
$computerName = $env:COMPUTERNAME.ToUpperInvariant()
$bundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$launcherPath = Join-Path $bundleRoot 'ChatGPT Custom.exe'
$rollbackRoot = Join-Path $bundleRoot 'rollback'
if (-not $StartupPath) { $StartupPath = [Environment]::GetFolderPath('Startup') }
$StartupPath = [IO.Path]::GetFullPath($StartupPath)
$shortcutPath = Join-Path $StartupPath 'ChatGPT Remote Enabler Startup.lnk'
$legacyDisabledPath = "$shortcutPath.disabled"

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
        $result.proxyMode = $shortcut.Arguments -eq '--proxy'
    }
    return $result
}

switch ($Action) {
    'Install' {
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            throw "Launcher is missing: $launcherPath"
        }
        if (-not (Test-Path -LiteralPath $StartupPath -PathType Container)) {
            throw "Startup folder is missing: $StartupPath"
        }

        $backups = @()
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
            $shortcut.Arguments = if ($UseProxy) { '--proxy' } else { '' }
            $shortcut.WorkingDirectory = $bundleRoot
            $shortcut.Description = if ($UseProxy) {
                'Start ChatGPT/Codex with the audited injection and Remote-control proxy after sign-in.'
            } else {
                'Start ChatGPT/Codex with the audited injection after sign-in.'
            }
            $shortcut.IconLocation = "$launcherPath,0"
            $shortcut.WindowStyle = 1
            $shortcut.Save()
        }

        $result = Get-StartupSummary
        $result.backupPaths = @($backups)
        $result | ConvertTo-Json -Depth 4
    }
    'Remove' {
        $backups = @()
        foreach ($artifact in @(
            [ordered]@{ path = $shortcutPath; label = 'startup-shortcut' },
            [ordered]@{ path = $legacyDisabledPath; label = 'legacy-disabled-startup-shortcut' }
        )) {
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
