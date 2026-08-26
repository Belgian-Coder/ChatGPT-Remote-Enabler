[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$node = (Get-Command node.exe -ErrorAction Stop).Source
$javascript = @(
    'windows\CodexRemoteMobileProject\renderer-mobile-project-view.js',
    'windows\CodexRemoteMobileProject\inject.js',
    'windows\CodexRemoteSimple\runtime\renderer-payload.js',
    'windows\CodexRemoteSimple\runtime\orchestrator.js',
    'macos\renderer-mobile-project-view.js',
    'macos\inject.js'
)
foreach ($relative in $javascript) {
    & $node --check (Join-Path $root $relative)
    if ($LASTEXITCODE -ne 0) { throw "Node syntax validation failed: $relative" }
}

$powershell = @(
    'windows\Update-ChatGPTRemote.ps1',
    'windows\CodexRemoteMobileProject\MobileProjectView.ps1',
    'windows\CodexRemoteMobileProject\DesktopShortcut.ps1',
    'windows\CodexRemoteMobileProject\StartupShortcut.ps1',
    'tools\Build-Release.ps1',
    'tools\Test-Source.ps1',
    'tools\Test-WindowsUpdaterCompatibility.ps1'
)
foreach ($relative in $powershell) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "PowerShell syntax validation failed: $relative - $($errors[0].Message)" }
}

$windowsRenderer = Join-Path $root 'windows\CodexRemoteMobileProject\renderer-mobile-project-view.js'
$macRenderer = Join-Path $root 'macos\renderer-mobile-project-view.js'
if ((Get-FileHash -LiteralPath $windowsRenderer -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $macRenderer -Algorithm SHA256).Hash) {
    throw 'Windows and macOS renderer sources differ.'
}
$renderer = Get-Content -LiteralPath $windowsRenderer -Raw
$requiredContracts = @(
    'const VERSION = 45;',
    'REMOTE_UNREAD_ACK_KEY',
    'freshInventory(hostId)',
    'NATIVE_INVENTORY_MAX_ROUNDS',
    'AUTO_ARCHIVE_ENABLED_KEY',
    'thread/list',
    'thread/archive',
    'statusType === "notLoaded"',
    'state.autoReconciliationTimer',
    'function nativeProjectNewAction',
    'function nativeGlobalNewChatAction',
    'mode: "native-project-button"'
)
foreach ($contract in $requiredContracts) {
    if (-not $renderer.Contains($contract)) { throw "Renderer contract is missing: $contract" }
}
foreach ($forbiddenContract in @('selectNativeConnectionGrouping', 'trim() === "By connection"')) {
    if ($renderer.Contains($forbiddenContract)) { throw "Renderer still mutates native grouping: $forbiddenContract" }
}

if (Test-Path -LiteralPath (Join-Path $root '.github\workflows')) {
    throw 'GitHub Actions workflows are not allowed in this repository.'
}

& $node (Join-Path $root 'windows\CodexRemoteSimple\tests\RendererOverrides.SelfTest.js')
if ($LASTEXITCODE -ne 0) { throw 'Stable renderer self-test failed.' }

git -C $root diff --check
if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed.' }

[pscustomobject]@{
    JavaScriptFiles = $javascript.Count
    PowerShellFiles = $powershell.Count
    RendererVersion = 45
    RendererParity = $true
    StableRendererSelfTest = $true
} | ConvertTo-Json
