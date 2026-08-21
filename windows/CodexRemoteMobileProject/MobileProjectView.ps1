[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Enable', 'Disable', 'Probe', 'EnableAutoRegistration', 'DisableAutoRegistration', 'RemoveAutoRegistrations')]
    [string]$Action = 'Probe',
    [string]$NodePath
)

$ErrorActionPreference = 'Stop'
$bundleParent = Split-Path -Parent $PSScriptRoot
$stableRoot = Join-Path $bundleParent 'CodexRemoteSimple'
$sessionPath = Join-Path $stableRoot '.codexremote-simple-session.json'
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    throw 'No CodexRemoteSimple special-session record exists. Run the stable Enable action first.'
}

if (-not $NodePath) {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    $NodePath = if ($command) { $command.Source } else { Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe' }
}
if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw 'Node.js was not found. Pass -NodePath explicitly.' }

$session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
$port = [int]$session.rendererPort
if ($port -lt 1024 -or $port -gt 65535) { throw 'The stable session record contains an invalid renderer port.' }

if ($Action -ne 'Probe' -and -not $PSCmdlet.ShouldProcess('the current special Codex renderer session', "$Action the mobile-style device-filtered project view")) { return }

if ($Action -eq 'Enable') {
    $badgeController = Join-Path $bundleParent 'CodexRemoteSidebarExperimental\ProjectLabels.ps1'
    if (Test-Path -LiteralPath $badgeController -PathType Leaf) {
        & $badgeController -Action Disable -NodePath $NodePath -Confirm:$false
    }
}

$nodeAction = switch ($Action) {
    'EnableAutoRegistration' { 'auto-on' }
    'DisableAutoRegistration' { 'auto-off' }
    'RemoveAutoRegistrations' { 'auto-remove' }
    default { $Action.ToLowerInvariant() }
}
& $NodePath (Join-Path $PSScriptRoot 'inject.js') --action $nodeAction --port $port --local-name $env:COMPUTERNAME
if ($LASTEXITCODE -ne 0) { throw "Mobile project view action failed with exit code $LASTEXITCODE." }
