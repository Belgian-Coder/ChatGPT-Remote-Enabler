[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'CodexRemoteSimple.ps1'
& $entry -Action Rollback -Confirm:$false
if (-not $?) { exit 1 }
