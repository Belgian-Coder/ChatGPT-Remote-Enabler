[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updater = Get-Content -LiteralPath (Join-Path $root 'macos\Update-ChatGPTRemote.sh') -Raw
$launcher = Get-Content -LiteralPath (Join-Path $root 'macos\MobileProjectView-macOS-arm64.sh') -Raw
$shortcut = Get-Content -LiteralPath (Join-Path $root 'macos\MacOSShortcut.sh') -Raw
$zshSemanticTest = Get-Content -LiteralPath (Join-Path $root 'tools\Test-MacOSSupport.zsh') -Raw

foreach ($contract in @(
    'cd -- "$HOME"',
    'invoke_transaction_helper apply',
    'recover_pending_transaction',
    '.chatgpt-remote-release.zip',
    'acquire_launch_guard',
    'UPDATE_RECOVERY_REQUIRED',
    'record_check "$tag"'
)) {
    if (-not $updater.Contains($contract)) { throw "macOS updater reliability contract is missing: $contract" }
}
if ($updater.IndexOf('script_path="${0:A}"') -gt $updater.IndexOf('cd -- "$HOME"')) {
    throw 'Relative updater invocation is resolved only after changing working directory.'
}
$metadataIndex = $updater.LastIndexOf('values="$(download_release_metadata')
$applyIndex = $updater.LastIndexOf('apply_prepared_release "$tag"')
$recordIndex = $updater.LastIndexOf('record_check "$tag"')
if ($metadataIndex -lt 0 -or $applyIndex -lt $metadataIndex -or $recordIndex -lt $applyIndex) {
    throw 'A failed transactional apply can still record a successful interval check.'
}
$launchGuardIndex = $updater.LastIndexOf('  acquire_launch_guard')
$updateLockIndex = $updater.LastIndexOf('acquire_lock')
if ($launchGuardIndex -lt 0 -or $updateLockIndex -lt $launchGuardIndex) {
    throw 'macOS updater lock order is not launch guard then update lock.'
}
if ($updater.Contains("cleanup`nlock_acquired=0") -or $updater.Contains('Could not reacquire update lock')) {
    throw 'macOS updater still releases and reacquires its lock during one update transaction.'
}
$windowsTransaction = Join-Path $root 'windows\update-transaction.js'
$macTransaction = Join-Path $root 'macos\update-transaction.js'
if ((Get-FileHash $windowsTransaction -Algorithm SHA256).Hash -ne (Get-FileHash $macTransaction -Algorithm SHA256).Hash) {
    throw 'Windows and macOS transaction helpers differ.'
}

foreach ($contract in @(
    'const targets = JSON.parse(text);',
    'target?.url === "app://-/index.html"',
    'New LaunchAgent failed to load; the previous definition was restored.',
    'cp -p -- "$previous_plist" "$plist"'
)) {
    if (-not $launcher.Contains($contract)) { throw "macOS launcher reliability contract is missing: $contract" }
}
foreach ($contract in @(
    'candidate_source=',
    'candidate_app=',
    'Shortcut candidate failed validation; the installed shortcut was left unchanged.',
    'escape_applescript_string() {',
    'set launcherPath to \"$escaped_launcher\"',
    '/usr/bin/pgrep -x Codex'
)) {
    if (-not $shortcut.Contains($contract)) { throw "macOS shortcut reliability contract is missing: $contract" }
}
if (([regex]::Matches($shortcut, 'escape_applescript_string "\$launcher"')).Count -ne 2 -or
    -not $zshSemanticTest.Contains('actual="$(escape_applescript_string "$input")"') -or
    -not $zshSemanticTest.Contains('"$node_bin" "$transaction_helper" apply') -or
    -not $zshSemanticTest.Contains('/bin/zsh ./Update-ChatGPTRemote.sh probe')) {
    throw 'The real-zsh AppleScript escaping regression is not wired to the shared helper.'
}

$global:LASTEXITCODE = 0
[pscustomobject]@{
    InaccessibleWorkingDirectoryGuard = $true
    DeferredIntervalRecord = $true
    TransactionHelperParity = $true
    ContinuousUpdateLock = $true
    LaunchGuardOrdering = $true
    LaunchAgentRestoration = $true
    ExactCdpTarget = $true
    ShortcutCandidateSwap = $true
    ShortcutExactTarget = $true
    RealZshSemanticTestPresent = $true
} | ConvertTo-Json -Compress
