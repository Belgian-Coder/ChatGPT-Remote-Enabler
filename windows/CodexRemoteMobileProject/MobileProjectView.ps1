[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Enable', 'Disable', 'Probe', 'EnableAutoMaintenance', 'DisableAutoMaintenance', 'PreviewAutoMaintenance', 'RunAutoMaintenance', 'EnableAutoArchive', 'DisableAutoArchive', 'PreviewAutoArchive', 'RunAutoArchive', 'EnableAutoRegistration', 'DisableAutoRegistration', 'ReconcileAutoRegistrations', 'RemoveAutoRegistrations')]
    [string]$Action = 'Probe',
    [string]$NodePath,
    [switch]$DeferUpdateSession
)

$ErrorActionPreference = 'Stop'
$bundleParent = Split-Path -Parent $PSScriptRoot
$stableRoot = Join-Path $bundleParent 'CodexRemoteSimple'
$sessionPath = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures') 'codexremote-simple-session.json'
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    $sessionPath = Join-Path $stableRoot '.codexremote-simple-session.json'
}
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    throw 'No CodexRemoteSimple special-session record exists. Run the stable Enable action first.'
}

function Resolve-MobileNode {
    param([string]$RequestedPath)
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    foreach ($candidate in @(
        $RequestedPath,
        $(if ($command) { $command.Source }),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe')
    ) | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        & $candidate -e 'process.exit(parseInt(process.versions.node) >= 22 && globalThis.WebSocket ? 0 : 1)' 2>$null
        if ($LASTEXITCODE -eq 0) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw 'Node.js 22 or newer was not found. See the per-user Node.js instructions in README.md.'
}
$NodePath = Resolve-MobileNode -RequestedPath $NodePath

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
    'EnableAutoArchive' { 'archive-auto-on' }
    'DisableAutoArchive' { 'archive-auto-off' }
    'PreviewAutoArchive' { 'archive-preview' }
    'RunAutoArchive' { 'archive-run' }
    'EnableAutoMaintenance' { 'maintenance-auto-on' }
    'DisableAutoMaintenance' { 'maintenance-auto-off' }
    'PreviewAutoMaintenance' { 'maintenance-preview' }
    'RunAutoMaintenance' { 'maintenance-run' }
    'ReconcileAutoRegistrations' { 'auto-reconcile' }
    'RemoveAutoRegistrations' { 'auto-remove' }
    default { $Action.ToLowerInvariant() }
}
& $NodePath (Join-Path $PSScriptRoot 'inject.js') --action $nodeAction --port $port --local-name $env:COMPUTERNAME
if ($LASTEXITCODE -ne 0) { throw "Mobile project view action failed with exit code $LASTEXITCODE." }

# Legacy launchers may have updated these files while their pre-update startup
# script is still running. Bootstrap the session helper on that first Enable.
# Current coordinators defer this until readiness and supply exact resume flags.
if ($Action -eq 'Enable' -and -not $DeferUpdateSession) {
    try {
        if ($session.proxyMode -isnot [bool]) { throw 'The stable session does not report an exact proxy mode.' }
        $sessionLauncher = Join-Path $PSScriptRoot 'UpdateSessionLauncher.ps1'
        & $sessionLauncher -InstallRoot $bundleParent -EntryPointRelative 'CodexRemoteMobileProject\MobileProjectStartup.ps1' -NodePath $NodePath -UseProxy:([bool]$session.proxyMode) | Out-Null
    } catch {
        Write-Warning "Update status could not be attached after enabling the sidebar: $($_.Exception.Message)"
    }
}
