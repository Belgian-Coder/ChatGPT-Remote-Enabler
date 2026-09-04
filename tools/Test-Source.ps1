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
    'windows\CodexRemoteSimple\runtime\api-proxy-bridge.js',
    'windows\CodexRemoteSimple\runtime\prepare-proxy-runtime.js',
    'macos\renderer-mobile-project-view.js',
    'macos\inject.js'
    'windows\CodexRemoteMobileProject\maintenance.js'
    'macos\maintenance.js'
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
    'windows\CodexRemoteMobileProject\MobileProjectStartup.ps1',
    'windows\CodexRemoteMobileProject\ProxyConfiguration.ps1',
    'windows\CodexRemoteMobileProject\ProxyConfiguration.psm1',
    'windows\CodexRemoteSimple\runtime\PackageProcessLauncher.ps1',
    'tools\Build-Release.ps1',
    'tools\Test-BuildReleaseArchive.ps1',
    'tools\Test-BuildReleasePrivacy.ps1',
    'tools\Test-Source.ps1',
    'tools\Test-WindowsUpdaterCompatibility.ps1'
    'tools\Test-WindowsUpdaterNonGit.ps1'
    'tools\Test-WindowsControllerReliability.ps1'
    'tools\Test-PackageProcessLauncher.ps1'
    'tools\Test-ProxyRuntimePreparer.ps1'
    'tools\Test-MacOSUpdaterCompatibility.ps1'
    'tools\Test-MacOSSupport.ps1'
    'tools\Test-WindowsNodeProbe.ps1'
    'tools\Test-Maintenance.ps1',
    'tools\Test-ProxyConfiguration.ps1'
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
$windowsMaintenance = Join-Path $root 'windows\CodexRemoteMobileProject\maintenance.js'
$macMaintenance = Join-Path $root 'macos\maintenance.js'
if ((Get-FileHash -LiteralPath $windowsMaintenance -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $macMaintenance -Algorithm SHA256).Hash) {
    throw 'Windows and macOS maintenance sources differ.'
}
$renderer = Get-Content -LiteralPath $windowsRenderer -Raw
$requiredContracts = @(
    'const VERSION = 62;',
    'hostDisplayName: config.localDisplayName || null',
    'codex-remote-mobile-verified-thread-ids-v2',
    'THREAD_VISIBILITY_CONTRACT_VERSION',
    'VERIFIED_THREAD_IDS_FUTURE_SKEW_MS',
    'loadVerifiedThreadIds();',
    'rememberVerifiedThreadIds(hostId, inventory.threads)',
    'pruneVerifiedThreadIds();',
    'preferredThreadInventory',
    'scopedThreadsAreFresh',
    'serializePeerInventory',
    'taskIsAuthoritative',
    'threadScope: "user-visible"',
    'USER_VISIBLE_THREAD_SOURCE_KINDS = Object.freeze(["cli", "vscode"])',
    'includeInternalSources ? MAINTENANCE_THREAD_SOURCE_KINDS : USER_VISIBLE_THREAD_SOURCE_KINDS',
    'listAllLocalThreadInventory',
    'localThreadListGates',
    'THREAD_LIST_REGISTRY_SLOT',
    'CODEX_REMOTE_REQUEST_TIMEOUT',
    'localThreadListRecoveryPending',
    'params.useStateDbOnly = true',
    'threadIds.has(threadId)',
    'sendRequestWithTimeout',
    'state.autoArchiveGeneration',
    'AUTO_ARCHIVE_LOCK_KEY',
    'REMOTE_UNREAD_ACK_KEY',
    'freshInventory(hostId)',
    'listAllRuntimeThreads',
    'state.threadInventories',
    'new Map(discoverRemoteRuntimes(discovery.runtimes))',
    '!authoritativeIds.has(hostId)',
    '!authoritativeIds.get(hostId).has(task.conversationId)',
    'state.hostConnectivity',
    'navigateToLocalConversation',
    'AUTO_ARCHIVE_ENABLED_KEY',
    'thread/list',
    'thread/archive',
    'thread/delete',
    'AUTO_DELETE_AFTER_ARCHIVE_DAYS',
    'statusType === "notLoaded"',
    'state.autoReconciliationTimer',
    'function nativeProjectNewAction',
    'function nativeGlobalNewChatAction',
    'mode: "native-project-button"'
)
foreach ($contract in $requiredContracts) {
    if (-not $renderer.Contains($contract)) { throw "Renderer contract is missing: $contract" }
}
foreach ($internalSource in @('"appServer"', '"exec"', '"subAgent"', '"subAgentReview"', '"subAgentCompact"', '"subAgentThreadSpawn"', '"subAgentOther"', '"unknown"')) {
    if (-not $renderer.Contains($internalSource)) { throw "Maintenance source-kind contract is missing: $internalSource" }
}
if ($renderer -match 'availability\.set\(normalizedHostId, true\)') {
    throw 'A cached request client must not be treated as proof that a host is online.'
}
foreach ($forbiddenContract in @('selectNativeConnectionGrouping', 'trim() === "By connection"')) {
    if ($renderer.Contains($forbiddenContract)) { throw "Renderer still mutates native grouping: $forbiddenContract" }
}

if (Test-Path -LiteralPath (Join-Path $root '.github\workflows')) {
    throw 'GitHub Actions workflows are not allowed in this repository.'
}

foreach ($relative in @('windows\CodexRemoteMobileProject\inject.js', 'macos\inject.js')) {
    $injector = Get-Content -LiteralPath (Join-Path $root $relative) -Raw
    foreach ($contract in @('const PROBE_TIMEOUT_MS = 10000;', 'version: report.version')) {
        if (-not $injector.Contains($contract)) { throw "Injector reliability contract is missing in ${relative}: $contract" }
    }
    if ($injector.Contains('version: 55') -or $injector -match 'probe\?\.\(\).*?, 5000\)') {
        throw "Injector retains stale session-version or short probe behavior: $relative"
    }
}

& (Join-Path $root 'tools\Test-BuildReleasePrivacy.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Build release privacy self-test failed.' }

& (Join-Path $root 'tools\Test-BuildReleaseArchive.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Build release archive self-test failed.' }

& $node (Join-Path $root 'windows\CodexRemoteSimple\tests\RendererOverrides.SelfTest.js')
if ($LASTEXITCODE -ne 0) { throw 'Stable renderer self-test failed.' }

& $node (Join-Path $root 'windows\CodexRemoteSimple\tests\PackageCompatibility.SelfTest.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Windows package compatibility self-test failed.' }

& $node (Join-Path $root 'windows\CodexRemoteMobileProject\tests\TitleProvenance.SelfTest.js')
if ($LASTEXITCODE -ne 0) { throw 'Title provenance self-test failed.' }

& $node (Join-Path $root 'windows\CodexRemoteMobileProject\tests\ThreadVisibility.SelfTest.js')
if ($LASTEXITCODE -ne 0) { throw 'Thread visibility self-test failed.' }

& $node (Join-Path $root 'windows\CodexRemoteMobileProject\tests\TaskStatus.SelfTest.js')
if ($LASTEXITCODE -ne 0) { throw 'Task status self-test failed.' }

& (Join-Path $root 'tools\Test-Maintenance.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Maintenance self-test failed.' }

& (Join-Path $root 'tools\Test-ProxyConfiguration.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Proxy configuration self-test failed.' }

& (Join-Path $root 'tools\Test-WindowsNodeProbe.ps1') -NodePath $node
if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell Node capability probe self-test failed.' }

& (Join-Path $root 'tools\Test-WindowsUpdaterNonGit.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Windows packaged updater self-test failed.' }

& (Join-Path $root 'tools\Test-WindowsControllerReliability.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Windows controller reliability self-test failed.' }

& (Join-Path $root 'tools\Test-PackageProcessLauncher.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Package process launcher self-test failed.' }

& (Join-Path $root 'tools\Test-ProxyRuntimePreparer.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Private proxy runtime preparer self-test failed.' }

& (Join-Path $root 'tools\Test-MacOSUpdaterCompatibility.ps1')
if ($LASTEXITCODE -ne 0) { throw 'macOS updater compatibility self-test failed.' }

& (Join-Path $root 'tools\Test-MacOSSupport.ps1')
if ($LASTEXITCODE -ne 0) { throw 'macOS support reliability self-test failed.' }

git -C $root diff --check
if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed.' }

[pscustomobject]@{
    JavaScriptFiles = $javascript.Count
    PowerShellFiles = $powershell.Count
    RendererVersion = 62
    RendererParity = $true
    MaintenanceParity = $true
    InjectorVersionProof = $true
    InjectorProbeTimeout = $true
    BuildReleasePrivacySelfTest = $true
    BuildReleaseArchiveSelfTest = $true
    MaintenanceSelfTest = $true
    ProxyConfigurationSelfTest = $true
    WindowsPowerShellNodeProbeSelfTest = $true
    WindowsPackagedUpdaterSelfTest = $true
    WindowsControllerReliabilitySelfTest = $true
    PackageProcessLauncherSelfTest = $true
    ProxyRuntimePreparerSelfTest = $true
    MacOSUpdaterCompatibilitySelfTest = $true
    MacOSSupportReliabilitySelfTest = $true
    StableRendererSelfTest = $true
    PackageCompatibilitySelfTest = $true
    TitleProvenanceSelfTest = $true
    ThreadVisibilitySelfTest = $true
    TaskStatusSelfTest = $true
} | ConvertTo-Json
