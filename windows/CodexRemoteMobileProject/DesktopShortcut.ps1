[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Remove', 'Probe')]
    [string]$Action = 'Probe',
    [string]$DesktopPath,
    [string]$StartMenuPath,
    [switch]$UseProxy
)

$ErrorActionPreference = 'Stop'
$computerName = $env:COMPUTERNAME.ToUpperInvariant()

$bundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$launcherPath = Join-Path $bundleRoot 'ChatGPT Custom.exe'
$rollbackRoot = Join-Path $bundleRoot 'rollback'
if (-not $DesktopPath) { $DesktopPath = [Environment]::GetFolderPath('Desktop') }
if (-not $StartMenuPath) { $StartMenuPath = [Environment]::GetFolderPath('Programs') }
$DesktopPath = [IO.Path]::GetFullPath($DesktopPath)
$StartMenuPath = [IO.Path]::GetFullPath($StartMenuPath)
$primaryArguments = if ($UseProxy) { '--proxy' } else { '' }
$primaryDescription = if ($UseProxy) {
    'Restart ChatGPT/Codex with the audited injection and Remote-control proxy.'
} else {
    'Restart ChatGPT/Codex with the audited remote Mobile projects injection.'
}
$primaryShortcutTargets = @(
    [ordered]@{ kind = 'Desktop'; path = Join-Path $DesktopPath 'ChatGPT Remote Enabler.lnk'; arguments = $primaryArguments; description = $primaryDescription },
    [ordered]@{ kind = 'StartMenu'; path = Join-Path $StartMenuPath 'ChatGPT Remote Enabler.lnk'; arguments = $primaryArguments; description = $primaryDescription }
)
$shortcutTargets = @($primaryShortcutTargets)
$summaryTargets = @($primaryShortcutTargets)
$legacyShortcutTargets = @(
    [ordered]@{ kind = 'LegacyDesktop'; path = Join-Path $DesktopPath 'ChatGPT Custom.lnk' },
    [ordered]@{ kind = 'LegacyStartMenu'; path = Join-Path $StartMenuPath 'ChatGPT Custom.lnk' },
    [ordered]@{ kind = 'LegacyStartMenuProxyTest'; path = Join-Path $StartMenuPath 'ChatGPT Custom (Proxy Test).lnk' },
    [ordered]@{ kind = 'LegacyStartMenuProxy'; path = Join-Path $StartMenuPath 'ChatGPT Custom (Proxy).lnk' }
)

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
        $entry = [ordered]@{ kind = $target.kind; path = $target.path; installed = $installed }
        if ($installed) {
            $shortcut = $shell.CreateShortcut($target.path)
            $entry.targetPath = $shortcut.TargetPath
            $entry.arguments = $shortcut.Arguments
            $entry.workingDirectory = $shortcut.WorkingDirectory
            $entry.description = $shortcut.Description
        }
        [pscustomobject]$entry
    }
    return [ordered]@{
        host = $computerName
        launcherPath = $launcherPath
        launcherPresent = Test-Path -LiteralPath $launcherPath -PathType Leaf
        requestedProxyMode = [bool]$UseProxy
        shortcuts = @($entries)
        legacyShortcuts = @($legacyShortcutTargets | ForEach-Object {
            [pscustomobject][ordered]@{ kind = $_.kind; path = $_.path; installed = Test-Path -LiteralPath $_.path -PathType Leaf }
        })
    }
}

switch ($Action) {
    'Install' {
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            throw "Launcher is missing: $launcherPath"
        }
        $backups = @()
        # Installation preserves all legacy shortcuts. Removal remains explicit.
        foreach ($target in $shortcutTargets) {
            $parent = Split-Path -Parent $target.path
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                throw "Shortcut folder is missing: $parent"
            }
            $backup = Backup-Shortcut -Path $target.path -Kind $target.kind
            if ($backup) { $backups += $backup }
            if ($PSCmdlet.ShouldProcess($target.path, 'create ChatGPT Remote Enabler shortcut')) {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($target.path)
                $shortcut.TargetPath = $launcherPath
                $shortcut.Arguments = $target.arguments
                $shortcut.WorkingDirectory = $bundleRoot
                $shortcut.Description = $target.description
                $shortcut.IconLocation = "$launcherPath,0"
                $shortcut.WindowStyle = 1
                $shortcut.Save()
            }
        }
        $result = Get-ShortcutSummary
        $result.backupPaths = @($backups)
        $result | ConvertTo-Json -Depth 4
    }
    'Remove' {
        $backups = @()
        foreach ($target in @($summaryTargets) + @($legacyShortcutTargets)) {
            $backup = Backup-Shortcut -Path $target.path -Kind $target.kind
            if ($backup) { $backups += $backup }
            if ((Test-Path -LiteralPath $target.path -PathType Leaf) -and
                $PSCmdlet.ShouldProcess($target.path, 'remove ChatGPT Custom shortcut')) {
                Remove-Item -LiteralPath $target.path -Force
            }
        }
        $result = Get-ShortcutSummary
        $result.backupPaths = @($backups)
        $result | ConvertTo-Json -Depth 4
    }
    'Probe' {
        Get-ShortcutSummary | ConvertTo-Json -Depth 4
    }
}
