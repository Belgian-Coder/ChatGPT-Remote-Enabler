[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updaterPath = Join-Path $root 'macos\Update-ChatGPTRemote.sh'
$updater = Get-Content -LiteralPath $updaterPath -Raw

if ($updater -match '(?m)^\s*local\b[^\r\n]*\bpath\b') {
    throw "The macOS updater declares zsh's special path parameter locally and can clear PATH."
}
if (-not $updater.Contains('local manifest="$install_root/RELEASE-MANIFEST.sha256" line hash relative file_path actual count=0')) {
    throw 'The macOS installed-integrity check does not use the safe file_path variable.'
}
if (-not $updater.Contains('/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk')) {
    throw 'The macOS installed-integrity check does not use the absolute awk path.'
}

$global:LASTEXITCODE = 0
[pscustomobject]@{
    SpecialPathVariableAbsent = $true
    AbsoluteIntegrityTools = $true
} | ConvertTo-Json
