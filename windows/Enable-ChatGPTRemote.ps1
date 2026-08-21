[CmdletBinding()]
param([switch]$SkipMobileProjects)

$ErrorActionPreference = 'Stop'
$stable = Join-Path $PSScriptRoot 'CodexRemoteSimple\CodexRemoteSimple.ps1'
$mobile = Join-Path $PSScriptRoot 'CodexRemoteMobileProject\MobileProjectView.ps1'

& $stable -Action Enable
if (-not $SkipMobileProjects) {
    & $mobile -Action Enable
}

Write-Host 'ChatGPT Remote is enabled for this special session.' -ForegroundColor Green
Write-Host 'Use Disable-ChatGPTRemote.ps1 to return to the normal app.'
