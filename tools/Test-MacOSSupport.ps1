[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updater = Get-Content -LiteralPath (Join-Path $root 'macos\Update-ChatGPTRemote.sh') -Raw
$launcher = Get-Content -LiteralPath (Join-Path $root 'macos\MobileProjectView-macOS-arm64.sh') -Raw
$shortcut = Get-Content -LiteralPath (Join-Path $root 'macos\MacOSShortcut.sh') -Raw
$processGuard = Get-Content -LiteralPath (Join-Path $root 'macos\AppProcessGuard.sh') -Raw
$startupProgress = Get-Content -LiteralPath (Join-Path $root 'macos\StartupProgress.js') -Raw
$setup = Get-Content -LiteralPath (Join-Path $root 'macos\Setup.command') -Raw
$zshSemanticTest = Get-Content -LiteralPath (Join-Path $root 'tools\Test-MacOSSupport.zsh') -Raw
$updateSession = Get-Content -LiteralPath (Join-Path $root 'macos\update-session.js') -Raw
$updateSessionPlatform = Get-Content -LiteralPath (Join-Path $root 'macos\UpdateSessionPlatform.sh') -Raw

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
if (-not $shortcut.Contains('candidate_app="$candidate_root/$shortcut_name.app"')) {
    throw 'The macOS shortcut candidate must end in .app so osacompile emits an application bundle.'
}
foreach ($contract in @('CFBundleName', 'CFBundleDisplayName', 'CFBundleIdentifier', 'com.local.chatgpt-remote-enabler')) {
    if (-not $shortcut.Contains($contract)) { throw "The macOS shortcut stable identity contract is missing: $contract" }
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
foreach ($contract in @(
    'is_owned_prepared_directory() {',
    'cleanup_failed_prepared_directory() {',
    '[[ -f "$transaction_journal" || -f "$git_transaction_journal" ]] && return 0',
    'cleanup_failed_prepared_directory "$prepared_directory"',
    'cleanup_failed_prepared_directory "$prepared_root"',
    'source_checkout && return 0',
    'installed_integrity_valid ||',
    'install_root="$canonical_install_root"',
    'stable_migration_pending=1',
    'if (( ! read_only_action )) && [[ ! -f "$transaction_journal" && ! -f "$git_transaction_journal" ]]; then',
    'CODEX_REMOTE_USE_PROXY="$startup_proxy" CODEX_STARTUP_DELAY_SECONDS="$delay" CODEX_STARTUP_REQUIRED_PATH="$required" /bin/zsh "$launcher" "${startup_arguments[@]}"'
)) {
    if (-not $updater.Contains($contract)) { throw "macOS updater stable-root/prepared-cleanup contract is missing: $contract" }
}
foreach ($contract in @('requested_proxy=0', 'shortcut_uses_proxy() {', 'startup_uses_proxy() {', 'shortcut_arguments+=(--proxy)', 'startup_arguments+=(--proxy)')) {
    if (-not $setup.Contains($contract)) { throw "macOS setup proxy-preservation contract is missing: $contract" }
}
if (-not $updateSessionPlatform.Contains('/usr/bin/awk ''{$1=$1; print}''')) {
    throw 'macOS coordinator probe does not normalize process start tokens like the launcher.'
}
foreach ($contract in @('startup_proxy=0', 'startup_arguments+=(--proxy)', 'shortcut_proxy=0', 'shortcut_arguments+=(--proxy)')) {
    if (-not $updater.Contains($contract)) { throw "macOS migration proxy-preservation contract is missing: $contract" }
}
foreach ($contract in @('progress_start()', 'progress_write update-recovery', 'progress_write update-check', 'progress_write maintenance', 'progress_write launch', 'progress_write renderer-readiness', 'progress_complete', 'CODEX_REMOTE_PROGRESS_STATE')) {
    if (-not $launcher.Contains($contract)) { throw "macOS startup progress lifecycle contract is missing: $contract" }
}
foreach ($contract in @('NSWindow', 'NSProgressIndicator', 'NSRunLoop.currentRunLoop', 'update-recovery', 'update-check', 'renderer-readiness', 'complete', 'Action required', 'private per-user')) {
    if (-not $startupProgress.Contains($contract)) { throw "macOS native startup progress helper contract is missing: $contract" }
}
foreach ($contract in @('resolve_app_bundle() {', 'resolve_app_executable() {', '"$app_executable" "${launch_arguments[@]}"', 'chatgpt-launch.log', 'timeout_seconds=35', '[[ "$requested_action" == probe ]] && timeout_seconds=12', 'return 124')) {
    if (-not $launcher.Contains($contract)) { throw "macOS permission-free application launch contract is missing: $contract" }
}
if (-not (Get-Content -LiteralPath (Join-Path $root 'macos\inject.js') -Raw).Contains('() => process.exit(0)')) {
    throw 'The macOS injector CLI does not force a clean exit after closing CDP.'
}
$gitRelease = Get-Content -LiteralPath (Join-Path $root 'macos\git-release.js') -Raw
if (-not $gitRelease.Contains('candidates.push("/opt/homebrew/bin/git", "/usr/local/bin/git", "git", "/usr/bin/git")')) {
    throw 'The macOS Git resolver does not prefer standalone Git over the Xcode shim.'
}
if ($launcher.Contains('/usr/bin/open "${open_arguments[@]}"') -or $launcher.Contains('path to application')) {
    throw 'The application launch path still depends on TCC-sensitive LaunchServices or Apple Events.'
}
foreach ($contract in @('ObjC.bindFunction("kill"', '$.__error()[0]', '--mode', 'self-test', 'acknowledgeReady')) {
    if (-not $startupProgress.Contains($contract)) { throw "macOS native startup progress runtime contract is missing: $contract" }
}
foreach ($contract in @('StartupProgress.js', 'progressRequested', 'CODEX_REMOTE_PROGRESS_ENABLED=1')) {
    if (-not $shortcut.Contains($contract)) { throw "macOS Dock shortcut progress contract is missing: $contract" }
}
foreach ($contract in @('codesign_quiet() {', 'osacompile_quiet() {', 'replacing existing signature', '/usr/bin/sed ''/replacing existing signature/d''')) {
    if (-not $shortcut.Contains($contract)) { throw "macOS codesign diagnostic suppression contract is missing: $contract" }
}
foreach ($contract in @('native_renderer_quit()', 'SystemInfo.getProcessInfo', 'bridge.sendMessageFromView({ type: "quit-app" })', '/bin/kill -TERM "$pid_value"', 'POSIX_SIGTERM', 'expected_uid', '0=SAME, 1=GONE, 2=ERROR, 3=CHANGED')) {
    if (-not $updateSessionPlatform.Contains($contract)) { throw "macOS permission-free close contract is missing: $contract" }
}
if ($updateSessionPlatform.Contains('NSRunningApplication') -or $updateSessionPlatform.Contains('terminate()') -or
    $updateSessionPlatform.Contains('do shell script') -or $updateSessionPlatform.Contains('kill -9') -or
    $updateSessionPlatform.Contains('killall') -or $updateSessionPlatform.Contains('pkill')) {
    throw 'macOS graceful close still uses the TCC-sensitive AppKit/Apple Events path or a force-kill fallback.'
}
if (-not $updateSession.Contains('CLOSE_METHODS[this.config.platform]') -or
    -not $updateSession.Contains('WM_CLOSE') -or -not $updateSession.Contains('POSIX_SIGTERM') -or
    -not $updateSession.Contains('argumentsValue.push(process.execPath)')) {
    throw 'macOS update-session close results are not method-whitelisted and Node-bound.'
}
foreach ($contract in @('match-stdin', '/bin/ps -axo pid=,command=', 'command == path', 'index(command, path " ") == 1', 'process_list="$(/bin/ps -axo pid=,command=)" || return 2', 'first="$(enumerate_processes)" || exit 2')) {
    if (-not $processGuard.Contains($contract)) { throw "macOS exact executable process-guard contract is missing: $contract" }
}
if ($launcher.Contains('/usr/bin/pgrep -x') -or $shortcut.Contains('/usr/bin/pgrep -x') -or $processGuard.Contains('/usr/bin/pgrep')) {
    throw 'A macOS launch-safety path still relies on the basename-only pgrep detector.'
}
foreach ($contract in @('matched_line=""', 'matched_line="$command_line"', '[[ "$matched_line" == *"--proxy-server=$proxy_server"*', '[[ "$matched_line" != *''--proxy-server=''*')) {
    if (-not $launcher.Contains($contract)) { throw "macOS running proxy-mode validation does not retain the exact matched process: $contract" }
}
if ($updater.Contains('"${install_root:h}" != "${legacy_release_root:A}"')) {
    throw 'macOS stable-root migration is still restricted to one legacy parent path.'
}
if ($updater.Contains('Stable install root already exists and was not replaced')) {
    throw 'macOS updater still fails when a valid canonical stable root already exists.'
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
    'exec /usr/bin/env "${environment[@]}" /bin/zsh "${updated_arguments[@]}"',
    'if ! validation="$("$node_bin" -e',
    'The updater final output record was not valid JSON proof.',
    'The updater returned more than one JSON proof record.',
    '(!value.updated && value.method !== "verified-git")',
    'New LaunchAgent failed to load; the previous definition was restored.',
    'cp -p -- "$previous_plist" "$plist"'
    '/usr/bin/awk ''{$1=$1; print}'''
)) {
    if (-not $launcher.Contains($contract)) { throw "macOS launcher reliability contract is missing: $contract" }
}
foreach ($contract in @(
    'git_release_source="$bundle_root/git-release.js"',
    'git_checkout_update_source="$bundle_root/git-checkout-update.js"',
    'update-transaction.js git-release.js git-checkout-update.js ProxyConfiguration.sh)',
    '"$update_transaction_source" "$git_release_source" "$git_checkout_update_source" "$proxy_configuration")'
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
    'set processGuardPath to "$escaped_process_guard"',
    "install_shortcut 'ChatGPT Mobile Projects'",
    'Shortcut removal failed; the application wrapper was restored.',
    'Shortcut removal did not complete; the previous shortcut was restored.',
    'if (( source_preserved )); then rm -f -- "$previous_source"; fi',
    'if (( app_preserved )); then rm -rf -- "$previous_app"; fi'
)) {
    if (-not $shortcut.Contains($contract)) { throw "macOS shortcut reliability contract is missing: $contract" }
}
if ($shortcut.Contains('Remove the stale Dock icon manually') -or
    $shortcut.Contains('Shortcut files were preserved under')) {
    throw 'Successful macOS shortcut removal still requires manual cleanup or retains auxiliary rollback material.'
}
if (([regex]::Matches($shortcut, 'escape_applescript_string "\$launcher"')).Count -ne 2 -or
    -not $zshSemanticTest.Contains('actual="$(escape_applescript_string "$input")"') -or
    -not $zshSemanticTest.Contains('"$node_bin" "$transaction_helper" apply') -or
    -not $zshSemanticTest.Contains('/bin/zsh ./Update-ChatGPTRemote.sh probe')) {
    throw 'The real-zsh AppleScript escaping regression is not wired to the shared helper.'
}
foreach ($contract in @('app_is_running || guard_status=$?', 'elif (( guard_status != 1 ))', 'refusing to risk a second instance')) {
    if (-not $launcher.Contains($contract)) { throw "macOS process-guard failure does not fail closed: $contract" }
}
foreach ($contract in @('ExactExecutableProcessGuard', 'LegacyNameProbeMissCovered', 'NoHelperOrUnrelatedMatches', 'CustomAppNamePath', 'EnumerationFailureFailClosed', 'LegacyShortcutMigrated', 'MacOSNativeStartupProgress', 'MacOSPermissionFreeGracefulClose')) {
    if (-not $zshSemanticTest.Contains($contract)) { throw "The real-zsh process-guard regression is not wired: $contract" }
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
    PreparedDirectoryCleanup = $true
    StableRootExistingAdoption = $true
    ArbitraryLegacyRootMigration = $true
    StableAliasRewire = $true
    ShortcutCandidateSwap = $true
    ShortcutExactTarget = $true
    ShortcutRemovalTransactional = $true
    ShortcutRollbackCleanup = $true
    ExactExecutableProcessGuard = $true
    LegacyShortcutMigrated = $true
    MacOSNativeStartupProgress = $true
    MacOSPermissionFreeGracefulClose = $true
    RealZshSemanticTestPresent = $true
} | ConvertTo-Json -Compress
