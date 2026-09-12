[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updater = Get-Content -LiteralPath (Join-Path $root 'macos\Update-ChatGPTRemote.sh') -Raw
$launcher = Get-Content -LiteralPath (Join-Path $root 'macos\MobileProjectView-macOS-arm64.sh') -Raw
$shortcut = Get-Content -LiteralPath (Join-Path $root 'macos\MacOSShortcut.sh') -Raw
$zshSemanticTest = Get-Content -LiteralPath (Join-Path $root 'tools\Test-MacOSSupport.zsh') -Raw
$updateSession = Get-Content -LiteralPath (Join-Path $root 'macos\update-session.js') -Raw

foreach ($contract in @(
    'cd -- "$HOME"',
    'invoke_transaction_helper apply',
    'recover_pending_transaction',
    '.chatgpt-remote-release.zip',
    'if (!value.method) value.method = process.argv[2]',
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
    'const report = value?.report?.readiness ?? value?.report;',
    'Last readiness proof: $summary',
    'prelaunch_update "$node_bin"',
    'CHATGPT_REMOTE_UPDATE_TRANSPORT=git',
    'CODEX_REMOTE_LAUNCH_GUARD_TOKEN=$launch_guard_token',
    'CODEX_REMOTE_SKIP_PRELAUNCH_UPDATE_ONCE=1',
    'CODEX_REMOTE_RECOVERY_CONTINUATION=1',
    'Update recovery did not prove installed-file integrity before launch.',
    'typeof value.recovered !== "boolean"',
    '["complete-forward", "rollback", "unchanged"].includes(value.recoveryMode)',
    'continue_with_updated_launcher',
    'exec /usr/bin/env "${environment[@]}" /bin/zsh "$script_path" "$action"',
    'if ! validation="$("$node_bin" -e',
    'The updater final output record was not valid JSON proof.',
    'The updater returned more than one JSON proof record.',
    '(!value.updated && value.method !== "verified-git")',
    'New LaunchAgent failed to load; the previous definition was restored.',
    'cp -p -- "$previous_plist" "$plist"'
)) {
    if (-not $launcher.Contains($contract)) { throw "macOS launcher reliability contract is missing: $contract" }
}
foreach ($contract in @(
    'git_release_source="$bundle_root/git-release.js"',
    'git_checkout_update_source="$bundle_root/git-checkout-update.js"',
    'update-transaction.js git-release.js git-checkout-update.js)',
    '"$update_transaction_source" "$git_release_source" "$git_checkout_update_source")'
)) {
    if (-not $launcher.Contains($contract)) { throw "macOS detached updater helper is missing from its immutable bundle: $contract" }
}
if ($launcher.Contains('reported a terminal readiness error')) {
    throw 'macOS launcher still treats a transient renderer readiness error as terminal.'
}
$recoverCallIndex = $launcher.LastIndexOf('  recover_update "$node_bin"')
$prelaunchCallIndex = $launcher.LastIndexOf('  prelaunch_update "$node_bin"')
$handoffCallIndex = $launcher.LastIndexOf('  continue_with_updated_launcher')
$debugEndpointIndex = $launcher.LastIndexOf('  if ! debug_endpoint_ready "$node_bin"; then')
if ($recoverCallIndex -lt 0 -or $prelaunchCallIndex -le $recoverCallIndex -or
    $handoffCallIndex -le $prelaunchCallIndex -or $debugEndpointIndex -le $handoffCallIndex) {
    throw 'macOS verified update/recovery is not ordered before renderer endpoint discovery.'
}
if (-not $zshSemanticTest.Contains('PrelaunchRecoveryFailClosed') -or
    -not $zshSemanticTest.Contains('PrelaunchStrictFinalJsonProof') -or
    -not $zshSemanticTest.Contains('PrelaunchCurrentMethodRequired') -or
    -not $zshSemanticTest.Contains('InheritedLaunchGuard') -or
    -not $zshSemanticTest.Contains('SourceCheckoutInterpreterHandoff')) {
    throw 'The real-zsh prelaunch recovery and launch-guard handoff regressions are not wired.'
}
if (-not $updateSession.Contains('env.CODEX_REMOTE_SKIP_PRELAUNCH_UPDATE_ONCE = "1";')) {
    throw 'The macOS detached update-session relaunch can repeat the prelaunch update.'
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
    NestedReadinessEnvelope = $true
    TransientReadinessRetried = $true
    GitUpdaterHelpersBundled = $true
    PrelaunchUpdateBeforeDiscovery = $true
    PrelaunchIntegrityRecovery = $true
    PrelaunchStrictFinalJsonProof = $true
    PrelaunchCurrentMethodRequired = $true
    UpdatedEntryPointGuardHandoff = $true
    SourceCheckoutInterpreterHandoff = $true
    DetachedRelaunchSkipsPrelaunchUpdate = $true
    ShortcutCandidateSwap = $true
    ShortcutExactTarget = $true
    RealZshSemanticTestPresent = $true
} | ConvertTo-Json -Compress
