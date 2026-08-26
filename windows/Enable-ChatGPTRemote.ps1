[CmdletBinding()]
param([switch]$SkipMobileProjects, [switch]$SkipUpdate)

$ErrorActionPreference = 'Stop'
$stable = Join-Path $PSScriptRoot 'CodexRemoteSimple\CodexRemoteSimple.ps1'
$mobile = Join-Path $PSScriptRoot 'CodexRemoteMobileProject\MobileProjectView.ps1'
$updater = Join-Path $PSScriptRoot 'Update-ChatGPTRemote.ps1'

if (-not $SkipUpdate -and (Test-Path -LiteralPath $updater -PathType Leaf)) {
    try { & $updater -Action Auto | Write-Verbose } catch { Write-Warning "Automatic update skipped: $($_.Exception.Message)" }
}

& $stable -Action Enable -Confirm:$false
if (-not $SkipMobileProjects) {
    & $mobile -Action Enable -Confirm:$false
}

Write-Host 'ChatGPT Remote is enabled for this special session.' -ForegroundColor Green
Write-Host 'Use Disable-ChatGPTRemote.ps1 to return to the normal app.'
