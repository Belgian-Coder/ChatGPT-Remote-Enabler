[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$mobile = Join-Path $PSScriptRoot 'CodexRemoteMobileProject\Disable-MobileProjectView.ps1'
$restore = Join-Path $PSScriptRoot 'CodexRemoteSimple\Restore-NormalCodex.ps1'

if (Test-Path -LiteralPath $mobile -PathType Leaf) {
    & $mobile
}
& $restore
