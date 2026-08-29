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
    'local backup_base=',
    'mktemp -d "$backup_base.XXXXXX"',
    'Installed release failed final manifest verification',
    'record_check "$tag"'
)) {
    if (-not $updater.Contains($contract)) { throw "macOS updater reliability contract is missing: $contract" }
}
$successReportIndex = $updater.IndexOf('{\"updated\":true')
if ($successReportIndex -lt 0 -or $updater.IndexOf('installed_integrity_valid; then') -gt $successReportIndex) {
    throw 'Final installed integrity verification occurs after the updater success report.'
}
if ($updater.IndexOf('script_path="${0:A}"') -gt $updater.IndexOf('cd -- "$HOME"')) {
    throw 'Relative updater invocation is resolved only after changing working directory.'
}
$metadataIndex = $updater.IndexOf('values="$(download_release_metadata')
$decisionIndex = $updater.IndexOf('typeset current="$(local_version)"', $metadataIndex)
$installIndex = $updater.LastIndexOf('install_release "$tag"')
if ($metadataIndex -lt 0 -or $decisionIndex -lt 0 -or
    $updater.Substring($metadataIndex, $decisionIndex - $metadataIndex).Contains('record_check "$tag"') -or
    $updater.IndexOf('record_check "$tag"', $installIndex) -lt $installIndex) {
    throw 'A failed install can still record a successful interval check before installation finishes.'
}

# Model the updater's rollback-intent-before-copy contract at every release-copy
# position. A failed copy is treated as a partial destination write, which is the
# case the prior append-after-copy ordering could not restore.
$copyOrder = @('first.txt', 'middle.txt', 'Update-ChatGPTRemote.sh', 'RELEASE-MANIFEST.sha256')
$oldFiles = [ordered]@{
    'first.txt' = 'old-first'
    'middle.txt' = 'old-middle'
    'Update-ChatGPTRemote.sh' = 'old-updater'
    'RELEASE-MANIFEST.sha256' = 'old-manifest'
}
foreach ($failurePoint in $copyOrder) {
    $installed = @{} + $oldFiles
    $backups = @{}
    $intents = [Collections.Generic.List[object]]::new()
    foreach ($relative in $copyOrder) {
        $existed = $installed.ContainsKey($relative)
        if ($existed) { $backups[$relative] = $installed[$relative] }
        $intents.Add([pscustomobject]@{ Relative = $relative; Existed = $existed })
        if ($relative -eq $failurePoint) {
            $installed[$relative] = 'partial-copy'
            for ($index = $intents.Count - 1; $index -ge 0; $index--) {
                $intent = $intents[$index]
                if ($intent.Existed) { $installed[$intent.Relative] = $backups[$intent.Relative] }
                else { $installed.Remove($intent.Relative) }
            }
            break
        }
        $installed[$relative] = "new-$relative"
    }
    foreach ($relative in $oldFiles.Keys) {
        if ($installed[$relative] -ne $oldFiles[$relative]) {
            throw "Rollback failure injection did not restore $relative after failing at $failurePoint."
        }
    }
}

$mainSection = $updater.IndexOf('for relative in "${relatives[@]}"; do')
$mainIntent = $updater.IndexOf('copied_relatives+=("$relative"); copied_existed+=("$existed")', $mainSection)
$mainReleaseCopy = $updater.IndexOf('cp -p -- "$release_root/$relative" "$destination"', $mainSection)
if ($mainSection -lt 0 -or $mainIntent -lt $mainSection -or $mainIntent -gt $mainReleaseCopy) {
    throw 'Main payload rollback intent is not recorded before copy.'
}
if ($updater.IndexOf('copied_relatives+=("$relative"); copied_existed+=("$existed")', $updater.IndexOf("relative='Update-ChatGPTRemote.sh'")) -gt
    $updater.IndexOf('cp -p -- "$release_root/$relative" "$destination"', $updater.IndexOf("relative='Update-ChatGPTRemote.sh'"))) {
    throw 'Self-updater rollback intent is recorded after copy.'
}
$manifestSection = $updater.IndexOf("relative='RELEASE-MANIFEST.sha256'")
if ($updater.IndexOf('copied_relatives+=("$relative"); copied_existed+=("$existed")', $manifestSection) -gt
    $updater.IndexOf('cp -p -- "$manifest" "$destination"', $manifestSection)) {
    throw 'Manifest rollback intent is recorded after copy.'
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
    -not $zshSemanticTest.Contains('typeset -a failure_points=(first.txt middle.txt Update-ChatGPTRemote.sh RELEASE-MANIFEST.sha256)') -or
    -not $zshSemanticTest.Contains('/bin/zsh ./Update-ChatGPTRemote.sh probe')) {
    throw 'The real-zsh AppleScript escaping regression is not wired to the shared helper.'
}

[pscustomobject]@{
    InaccessibleWorkingDirectoryGuard = $true
    DeferredIntervalRecord = $true
    FinalInstalledIntegrity = $true
    UniqueRollbackFallback = $true
    FailureInjectionPoints = $copyOrder.Count
    LaunchAgentRestoration = $true
    ExactCdpTarget = $true
    ShortcutCandidateSwap = $true
    ShortcutExactTarget = $true
    RealZshSemanticTestPresent = $true
} | ConvertTo-Json -Compress
