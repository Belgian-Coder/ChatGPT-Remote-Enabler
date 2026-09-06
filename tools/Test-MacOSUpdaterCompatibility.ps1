[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updaterPath = Join-Path $root 'macos\Update-ChatGPTRemote.sh'
$updater = Get-Content -LiteralPath $updaterPath -Raw
$nativeApplyTestPath = Join-Path $root 'tools\Test-MacOSUpdaterApply.zsh'
$nativeApplyTest = Get-Content -LiteralPath $nativeApplyTestPath -Raw

if ($updater -match '(?m)^\s*local\b[^\r\n]*\bpath\b') {
    throw "The macOS updater declares zsh's special path parameter locally and can clear PATH."
}
if (-not $updater.Contains('local manifest="$install_root/RELEASE-MANIFEST.sha256" line hash relative file_path actual count=0')) {
    throw 'The macOS installed-integrity check does not use the safe file_path variable.'
}
if (-not $updater.Contains('/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk')) {
    throw 'The macOS installed-integrity check does not use the absolute awk path.'
}
if ($updater -match 'local\s+backup_base=[^\r\n]+backup_root="\$backup_base"') {
    throw 'The macOS updater initializes backup_root from an unset same-command local under nounset.'
}
foreach ($contract in @(
    'local source safe_version backup_base backup_root',
    'source="$(assert_safe_prepared_directory "$requested_source")" || return 1',
    'backup_base="$rollback_root/$(date +%Y%m%d-%H%M%S)-$safe_version"',
    'backup_root="$backup_base"',
    'normalize_prepared_executable_modes "$temporary_staging"',
    'normalize_prepared_executable_modes "$source"'
)) {
    if (-not $updater.Contains($contract)) {
        throw "The macOS updater does not preserve sequential apply-path initialization: $contract"
    }
}
foreach ($contract in @(
    '/bin/zsh "$install_root/Update-ChatGPTRemote.sh" apply-prepared',
    'CHATGPT_REMOTE_UPDATE_INSTALL_ROOT="$install_root"',
    '"$node_bin" -e ''const result = JSON.parse(process.argv[1]);',
    '[[ "$(<"$install_root/VERSION")" == v1.5.41 ]]',
    '[[ -x "$install_root/$name" ]]',
    '[[ -x "$rollback_path/$name" ]]'
)) {
    if (-not $nativeApplyTest.Contains($contract)) {
        throw "The native macOS updater apply regression fixture is incomplete: $contract"
    }
}

$global:LASTEXITCODE = 0
[pscustomobject]@{
    SpecialPathVariableAbsent = $true
    AbsoluteIntegrityTools = $true
    SequentialApplyInitialization = $true
    PreparedExecutablesNormalized = $true
    NativeApplyRegressionPresent = $true
} | ConvertTo-Json
