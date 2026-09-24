$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# Execute each entrypoint's actual root-resolution block with an older, valid
# installed package. New entrypoints must promote their packaged controllers
# before invoking them; installed launches must retain the cheap direct path.
foreach ($entry in @(
    @{ Path = 'windows/Enable-ChatGPTRemote.ps1'; Variable = 'runtimeRoot'; End = '$stable = Join-Path' },
    @{ Path = 'windows/CodexRemoteMobileProject/MobileProjectStartup.ps1'; Variable = 'bundleParent'; End = '$bundleRoot = Join-Path' }
)) {
    $entryText = Get-Content -LiteralPath (Join-Path $root $entry.Path) -Raw
    $start = $entryText.IndexOf('$' + $entry.Variable + ' = Get-StableInstallRoot')
    $end = $entryText.IndexOf($entry.End, $start)
    if ($start -lt 0 -or $end -le $start) { throw 'Missing package bootstrap boundary.' }
    $bootstrap = [scriptblock]::Create($entryText.Substring($start, $end - $start))
    & {
        $fixtureInstalledRoot = 'C:\Fixture\Installed'
        function Get-StableInstallRoot { $fixtureInstalledRoot }
        function Test-StablePackage { param($Root) return $true }
        function Ensure-StableInstallRoot {
            param($SourceRoot, $StableRoot)
            if ($SourceRoot -ne 'C:\Fixture\Extracted' -or $StableRoot -ne $fixtureInstalledRoot) { throw 'Wrong package migration roots.' }
            $script:bootstrapPromotions++
            return $StableRoot
        }
        foreach ($extracted in @($true, $false)) {
            $sourcePackageRoot = if ($extracted) { 'C:\Fixture\Extracted' } else { $fixtureInstalledRoot }
            $script:bootstrapPromotions = 0
            . $bootstrap
            if ($script:bootstrapPromotions -ne [int]$extracted) { throw "New package bootstrap skipped older controllers or slowed installed startup: $($entry.Path)" }
            if ((Get-Variable -Name $entry.Variable -ValueOnly) -ne $fixtureInstalledRoot) { throw 'Bootstrap did not resolve the canonical controller root.' }
        }
    }
}
$source = Join-Path $root 'windows/CodexRemoteSimple/CodexRemoteSimple.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
$switch = $ast.Find({ param($node) $node -is [Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$Action' }, $true)
$enable = @($switch.Clauses | Where-Object { $_.Item1.Value -eq 'Enable' })[0].Item2.Extent.Text
$runEnable = [scriptblock]::Create("switch ('Enable') { 'Enable' $enable }")
# Execute the actual branch with only fixture transports. No controller top-level
# code, real process operations, network or installed-app state is invoked.
$AttachOnly = $true; $UseProxy = $false; $legacyDeviceKeyCompatibilityNeeded = $false
$node = @{}; $state = @{}; $package = @{}; $bridgeMode = 'native-renderer'
$compatibility = @{ bridgeMode = 'native-renderer' }
function Invoke-CrsProbeExisting { return $fixtureProbe }
function Get-CrsDiscoverableSession { return $null }
function Test-CrsProxyModeProof { return $fixtureModeMatches }
function Test-CrsLegacyDeviceKeyModeProof { return $true }
function Invoke-CrsManagedNativeSessionRepair {
    if ($fixtureRepair) { return [pscustomobject]@{ Attempted = $true; Repaired = $true; Reason = $null } }
    return [pscustomobject]@{ Attempted = $false; Repaired = $false; Reason = $null }
}
function Start-CrsPackagedCodex { throw 'FORBIDDEN: launch' }
function Stop-CrsCodex { throw 'FORBIDDEN: stop' }
function New-CrsProxyRuntimePackage { throw 'FORBIDDEN: prepare runtime' }
function Connect-CrsExistingApp { param($Package, $Node, $Compatibility, $ProxyMode, $LegacyDeviceKeysRequired) return $fixtureAttachAllowed }
foreach ($scenario in @('compatible', 'mode-mismatch', 'missing', 'invalid', 'ordinary-attach', 'managed-repair')) {
    $fixtureAttachAllowed = $scenario -eq 'ordinary-attach'
    $fixtureRepair = $scenario -eq 'managed-repair'
    $fixtureProbe = if ($scenario -in @('missing', 'ordinary-attach', 'managed-repair')) { $null } else { [pscustomobject]@{ ok = $true; renderer = @{ probe = @{ proof = ($scenario -ne 'invalid') } } } }
    $fixtureModeMatches = $scenario -ne 'mode-mismatch'
    $caught = $null
    try { & $runEnable } catch { $caught = $_.Exception.Message }
    if ($scenario -in @('compatible', 'ordinary-attach', 'managed-repair')) {
        if ($caught) { throw "Compatible session did not attach: $caught" }
    } elseif ($caught -notlike 'ChatGPT is already open, but a matching Remote Enabler session*') {
        throw "Unsafe or incorrect attachment result for ${scenario}: $caught"
    }
}
foreach ($relative in @('windows/Enable-ChatGPTRemote.ps1', 'windows/CodexRemoteMobileProject/MobileProjectStartup.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $root $relative) -Raw
    foreach ($contract in @('$skipRemotePrelaunch = [bool]$SkipPrelaunchUpdateOnce -or $attachExistingSession', 'if (-not $attachExistingSession -and -not $SkipDesktopAppUpdateOnce', '$recovery = Invoke-UpdateRecovery', 'Get-StartupChatGPTMainProcesses', 'RefuseExistingApp = $true', 'Test-RemoteScriptSupportsParameter -ScriptPath')) {
        if (-not $text.Contains($contract)) { throw "Missing existing-session update/launch guard in ${relative}: $contract" }
    }
}
# Verify the non-executing command metadata probe distinguishes a current
# controller from the older rollback controller that has no AttachOnly switch.
$capabilityTokens = $null; $capabilityErrors = $null
$capabilityAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'windows/Enable-ChatGPTRemote.ps1'), [ref]$capabilityTokens, [ref]$capabilityErrors)
if ($capabilityErrors.Count) { throw $capabilityErrors[0] }
$capabilityDefinition = $capabilityAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-RemoteScriptSupportsParameter' }, $true)
if (-not $capabilityDefinition) { throw 'Controller parameter capability probe is missing.' }
. ([scriptblock]::Create($capabilityDefinition.Extent.Text))
$capabilityFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('remote-enabler-capability-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $capabilityFixtureRoot -Force | Out-Null
    $supportedController = Join-Path $capabilityFixtureRoot 'supported.ps1'
    $legacyController = Join-Path $capabilityFixtureRoot 'legacy.ps1'
    [IO.File]::WriteAllText($supportedController, 'param([switch]$AttachOnly, [switch]$RefuseExistingApp)', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($legacyController, 'param([switch]$RefuseExistingApp)', [Text.UTF8Encoding]::new($false))
    if (-not (Test-RemoteScriptSupportsParameter -ScriptPath $supportedController -ParameterName 'AttachOnly') -or
        (Test-RemoteScriptSupportsParameter -ScriptPath $legacyController -ParameterName 'AttachOnly')) {
        throw 'Controller parameter capability detection misclassified the supported or legacy fixture.'
    }
} finally {
    if (Test-Path -LiteralPath $capabilityFixtureRoot) { Remove-Item -LiteralPath $capabilityFixtureRoot -Recurse -Force }
}
# Exercise the read-only process filter with fixture data; never enumerate or
# launch the real desktop app from this regression.
. (Join-Path $root 'windows/StableInstall.ps1')
$fixturePackageRoot = 'C:\Fixture\OpenAI.Codex'
$fixturePrivateRoot = 'C:\Fixture\PrivateRuntime'
$fixtureProcesses = @(
    [pscustomobject]@{ ProcessId = 11; ExecutablePath = "$fixturePackageRoot\app\ChatGPT.exe"; CommandLine = 'ChatGPT.exe' },
    [pscustomobject]@{ ProcessId = 12; ExecutablePath = "$fixturePackageRoot\app\ChatGPT.exe"; CommandLine = 'ChatGPT.exe --type=renderer' },
    [pscustomobject]@{ ProcessId = 13; ExecutablePath = 'C:\Other\ChatGPT.exe'; CommandLine = 'ChatGPT.exe' },
    [pscustomobject]@{ ProcessId = 14; ExecutablePath = "$fixturePrivateRoot\session\ChatGPT.exe"; CommandLine = 'ChatGPT.exe --remote-debugging-port=9222' },
    [pscustomobject]@{ ProcessId = 15; ExecutablePath = "${fixturePrivateRoot}Other\ChatGPT.exe"; CommandLine = 'ChatGPT.exe' },
    [pscustomobject]@{ ProcessId = 16; ExecutablePath = $null; CommandLine = 'ChatGPT.exe' }
)
$detected = @(Get-StartupChatGPTMainProcesses -ProcessEnumerator { $fixtureProcesses } -PackageEnumerator { [pscustomobject]@{ InstallLocation = $fixturePackageRoot } } -PrivateRuntimeRoot $fixturePrivateRoot)
if (($detected.ProcessId -join ',') -ne '11,14') { throw 'Startup app detection admitted a renderer, unrelated executable or runtime-prefix sibling.' }
$fixtureProcesses = @($fixtureProcesses | Where-Object { $_.ProcessId -in @(12,13,15,16) })
if (@(Get-StartupChatGPTMainProcesses -ProcessEnumerator { $fixtureProcesses } -PackageEnumerator { [pscustomobject]@{ InstallLocation = $fixturePackageRoot } } -PrivateRuntimeRoot $fixturePrivateRoot).Count) { throw 'Child-only or unrelated processes incorrectly blocked startup.' }
$enumerationFailed = $false
try { Get-StartupChatGPTMainProcesses -ProcessEnumerator { throw 'Fixture enumeration failed' } | Out-Null } catch { $enumerationFailed = $_.Exception.Message -eq 'Fixture enumeration failed' }
if (-not $enumerationFailed) { throw 'Process enumeration failure was treated as permission to launch.' }

# Run the actual startup preflight through the recovery call. Ordinary app
# autostart must proceed to attachment without a disruptive progress window;
# ordinary and managed attachment recover an interrupted installation.
$startupText = Get-Content -LiteralPath (Join-Path $root 'windows/CodexRemoteMobileProject/MobileProjectStartup.ps1') -Raw
$preflightStart = $startupText.IndexOf('$appProcesses = @(Get-StartupChatGPTMainProcesses)')
$preflightEnd = $startupText.IndexOf('$recoverTimer.Stop()', $preflightStart)
if ($preflightStart -lt 0 -or $preflightEnd -lt 0) { throw 'Startup preflight test boundary is missing.' }
$preflight = [scriptblock]::Create($startupText.Substring($preflightStart, $preflightEnd - $preflightStart))
function Get-StartupChatGPTMainProcesses { $fixtureStartupProcesses }
foreach ($launcherText in @($startupText, (Get-Content -LiteralPath (Join-Path $root 'windows/Enable-ChatGPTRemote.ps1') -Raw))) {
    $gateEnd = $launcherText.IndexOf('$skipRemotePrelaunch =')
    $gateStart = $launcherText.LastIndexOf('$attachExistingSession = @(Get-StartupChatGPTMainProcesses).Count -gt 0', $gateEnd)
    if ($gateStart -lt 0 -or $launcherText.Substring($gateStart, $gateEnd - $gateStart).Trim() -ne '$attachExistingSession = @(Get-StartupChatGPTMainProcesses).Count -gt 0') { throw 'Helper update gate must refresh process discovery immediately before its decision.' }
    $gateLineEnd = $launcherText.IndexOf("`n", $gateEnd)
    $gate = [scriptblock]::Create($launcherText.Substring($gateStart, $gateLineEnd - $gateStart))
    $attachExistingSession = $false; $SkipPrelaunchUpdateOnce = $false
    $fixtureStartupProcesses = @([pscustomobject]@{CommandLine='ChatGPT.exe'})
    if (-not (& { . $gate; $skipRemotePrelaunch })) { throw 'An app opened during recovery must skip the helper update.' }
}
function Write-StartupLog { param($Message) }
function Start-StartupProgress { param($Message) $script:progressStarted++ }
function Set-StartupProgress { param($Message) }
function Invoke-UpdateRecovery { param($UpdaterPath, $InstallRoot) $script:recoveryStarted++; @{ recovered = $false } }
$UpdateResume = $false; $ReplaceRunningApp = $false
$computerName = 'Fixture'; $updateController = 'Fixture'; $bundleParent = 'Fixture'
foreach ($scenario in @('ordinary', 'managed', 'closed')) {
    $script:progressStarted = 0; $script:recoveryStarted = 0
    $fixtureStartupProcesses = switch ($scenario) {
        'ordinary' { [pscustomobject]@{ CommandLine = 'ChatGPT.exe' } }
        'managed' { [pscustomobject]@{ CommandLine = 'ChatGPT.exe --remote-debugging-port=9222' } }
        'closed' { @() }
    }
    & $preflight
    $expectedProgress = [int]($scenario -eq 'closed')
    $expectedRecovery = 1
    if ($script:progressStarted -ne $expectedProgress -or $script:recoveryStarted -ne $expectedRecovery) { throw "Incorrect progress/recovery behavior for $scenario" }
}
$ReplaceRunningApp = $true
$fixtureStartupProcesses = [pscustomobject]@{ CommandLine = 'ChatGPT.exe' }
$rootText = Get-Content -LiteralPath (Join-Path $root 'windows/Enable-ChatGPTRemote.ps1') -Raw
$rootStart = $rootText.IndexOf('$appProcesses = @(Get-StartupChatGPTMainProcesses)')
$rootEnd = $rootText.IndexOf('$recoverTimer.Stop()', $rootStart)
if ($rootStart -lt 0 -or $rootEnd -lt 0) { throw 'Root preflight test boundary is missing.' }
$rootPreflight = [scriptblock]::Create($rootText.Substring($rootStart, $rootEnd - $rootStart))
foreach ($manualPreflight in @($preflight, $rootPreflight)) {
    $script:progressStarted = 0; $script:recoveryStarted = 0
    $caught = $null
    try { & $manualPreflight } catch { $caught = $_.Exception.Message }
    if ($caught -or $script:progressStarted -ne 1 -or $script:recoveryStarted -ne 1) {
        throw "Manual ordinary-app launch did not continue to attachment: $caught"
    }
}
if (-not $startupText.Contains("`$stableError -like 'ChatGPT is already open, but a matching Remote Enabler session*'")) {
    throw 'Deterministic managed-session refusal must not be retried.'
}
# Execute the final controller dispatch as well as the early preflight. This
# catches stale decisions and late guards that would refuse an ordinary app.
$mobileLateStart = $startupText.IndexOf('$appProcesses = @(Get-StartupChatGPTMainProcesses)', $preflightEnd)
$mobileLateEnd = $startupText.IndexOf('$stableTimer.Stop()', $mobileLateStart)
$rootLateEnd = $rootText.IndexOf('$stableTimer.Stop()')
$rootLateStart = $rootText.LastIndexOf('$stableTimer = [Diagnostics.Stopwatch]::StartNew()', $rootLateEnd)
if ($mobileLateStart -lt 0 -or $mobileLateEnd -lt 0 -or $rootLateStart -lt 0 -or $rootLateEnd -lt 0) { throw 'Late attachment dispatch boundary missing.' }
$dispatches = @(
    [scriptblock]::Create($startupText.Substring($mobileLateStart, $mobileLateEnd - $mobileLateStart)),
    [scriptblock]::Create($rootText.Substring($rootLateStart, $rootLateEnd - $rootLateStart))
)
$script:controllerSupportsAttachOnly = $true
function Test-RemoteScriptSupportsParameter {
    param($ScriptPath, $ParameterName)
    return [bool]$script:controllerSupportsAttachOnly
}
$stableController = $stable = {
    param($Action, $UseProxy, $AttachOnly, $RefuseExistingApp, $TimeoutSeconds, $Confirm)
    $script:dispatchCount++
    $script:dispatchedAttach = $AttachOnly
    if (-not $RefuseExistingApp) { throw 'Dispatch lost process-replacement protection.' }
}
function Write-CommandOutput { param($Output) }
$MobileReadyTimeoutSeconds = 45; $ReplaceRunningApp = $false
foreach ($dispatch in $dispatches) {
    foreach ($scenario in @('late-open', 'already-open', 'closed', 'update-race')) {
        $attachExistingSession = $scenario -eq 'already-open'
        $fixtureStartupProcesses = if ($scenario -eq 'closed') { @() } else { [pscustomobject]@{CommandLine='ChatGPT.exe'} }
        $UpdateResume = $scenario -eq 'update-race'
        $script:dispatchCount = 0; $script:dispatchedAttach = $null; $caught = $null
        try { & $dispatch } catch { $caught = $_.Exception.Message }
        if ($UpdateResume) {
            if ($script:dispatchCount -ne 0 -or $caught -notlike 'Another ChatGPT/Codex process appeared*') { throw 'Update race must refuse replacement.' }
        } elseif ($caught -or $script:dispatchCount -ne 1 -or $script:dispatchedAttach -ne ($scenario -ne 'closed')) {
            throw "Incorrect final attachment dispatch for ${scenario}: $caught"
        }
    }
}
$UpdateResume = $false
$script:controllerSupportsAttachOnly = $false
$stableController = $stable = {
    param($Action, $UseProxy, $AttachOnly, $RefuseExistingApp, $TimeoutSeconds, $Confirm)
    $script:dispatchCount++
    $script:attachKeySeen = $PSBoundParameters.ContainsKey('AttachOnly')
    if (-not $RefuseExistingApp) { throw 'Dispatch lost process-replacement protection.' }
}
$fixtureStartupProcesses = @()
$script:dispatchCount = 0; $script:attachKeySeen = $false; $caught = $null
try { & $dispatches[1] } catch { $caught = $_.Exception.Message }
if ($caught -or $script:dispatchCount -ne 1 -or $script:attachKeySeen) {
    throw "Legacy cold launch did not omit AttachOnly safely: $caught"
}
$fixtureStartupProcesses = [pscustomobject]@{ CommandLine = 'ChatGPT.exe' }
$script:dispatchCount = 0; $caught = $null
try { & $dispatches[1] } catch { $caught = $_.Exception.Message }
if ($script:dispatchCount -ne 0 -or $caught -notlike '*does not support AttachOnly*left running*') {
    throw "Legacy running-session guard did not refuse replacement: $caught"
}
$script:controllerSupportsAttachOnly = $true
# Exercise the root launcher's only retryable race: the first dispatch starts
# with no app, the controller reports that one appeared during replacement,
# and a fresh probe makes the second dispatch AttachOnly. The controller is a
# fixture scriptblock; no app is launched, replaced, or restarted.
$rootText = Get-Content -LiteralPath (Join-Path $root 'windows/Enable-ChatGPTRemote.ps1') -Raw
if (-not $rootText.Contains('for ($stableAttempt = 1; $stableAttempt -le 2; $stableAttempt++)') -or
    -not $rootText.Contains("ChatGPT/Codex appeared while the replacement session was preparing*")) {
    throw 'Root launcher is missing its bounded, context-neutral existing-app race retry.'
}
$script:fixtureStartupProcesses = @()
$UpdateResume = $false
$script:rootLauncherLog = @()
function Write-RemoteLauncherLog { param($Message) $script:rootLauncherLog += [string]$Message }
$script:dispatchCount = 0; $script:dispatchedAttach = $null; $caught = $null
$stable = {
    param($Action, $UseProxy, $AttachOnly, $RefuseExistingApp, $TimeoutSeconds, $Confirm)
    $script:dispatchCount++
    if ($script:dispatchCount -eq 1) {
        $script:fixtureStartupProcesses = [pscustomobject]@{ CommandLine = 'ChatGPT.exe' }
        throw 'ChatGPT/Codex appeared while the replacement session was preparing. It was left running and the launch was aborted.'
    }
    if (-not $RefuseExistingApp) { throw 'Dispatch lost process-replacement protection.' }
    $script:dispatchedAttach = $AttachOnly
}
try { & $dispatches[1] } catch { $caught = $_.Exception.Message }
if ($caught -or $script:dispatchCount -ne 2 -or $script:dispatchedAttach -ne $true) {
    throw "Root existing-app race did not retry once in attach mode: $caught"
}
# Deterministic managed-session refusal and startup-only mode mismatch remain
# terminal even when an app is already present; neither may consume the retry.
foreach ($deterministicError in @(
    'ChatGPT is already open, but a matching Remote Enabler session is active.',
    'The running ordinary app cannot acquire startup-only proxy or legacy-key settings through attachment.'
)) {
    $script:fixtureStartupProcesses = [pscustomobject]@{ CommandLine = 'ChatGPT.exe' }
    $script:dispatchCount = 0; $script:dispatchedAttach = $null; $caught = $null
    $stable = {
        param($Action, $UseProxy, $AttachOnly, $RefuseExistingApp, $TimeoutSeconds, $Confirm)
        $script:dispatchCount++
        throw $script:deterministicError
    }
    $script:deterministicError = $deterministicError
    try { & $dispatches[1] } catch { $caught = $_.Exception.Message }
    if ($script:dispatchCount -ne 1 -or [string]::IsNullOrWhiteSpace($caught)) {
        throw "Deterministic root refusal was retried or changed: $deterministicError / $caught"
    }
}
# Mobile startup already has a two-attempt loop; keep UpdateResume strict when
# an app appears after the first controller dispatch. The second attempt must
# stop at its per-attempt guard without dispatching an attach.
$mobileText = Get-Content -LiteralPath (Join-Path $root 'windows/CodexRemoteMobileProject/MobileProjectStartup.ps1') -Raw
$mobileLoopStart = $mobileText.IndexOf('for ($stableAttempt = 1; $stableAttempt -le 2; $stableAttempt++)')
$mobileGuard = $mobileText.IndexOf('if ($UpdateResume -and $attachExistingSession)', $mobileLoopStart)
if ($mobileLoopStart -lt 0 -or $mobileGuard -lt $mobileLoopStart) { throw 'Mobile startup lost its per-attempt UpdateResume guard.' }
$script:fixtureStartupProcesses = @()
$UpdateResume = $true
$script:dispatchCount = 0; $script:dispatchedAttach = $null; $script:sleepCount = 0; $caught = $null
function Start-Sleep { param([int]$Seconds) $script:sleepCount++ }
$stableController = {
    param($Action, $UseProxy, $AttachOnly, $RefuseExistingApp, $TimeoutSeconds, $Confirm)
    $script:dispatchCount++
    $script:fixtureStartupProcesses = [pscustomobject]@{ CommandLine = 'ChatGPT.exe' }
    throw 'ChatGPT/Codex appeared while the replacement session was preparing. It was left running and the launch was aborted.'
}
try { & $dispatches[0] } catch { $caught = $_.Exception.Message }
if ($script:dispatchCount -ne 1 -or $script:sleepCount -ne 0 -or $caught -notlike 'ChatGPT/Codex appeared while the replacement session was preparing*') {
    throw "Mobile UpdateResume race did not stop before a second attach dispatch: $caught"
}
$UpdateResume = $false

# Exercise both entrypoints' desktop-app update gate with a fixture updater.
# The fixture changes only process-enumerator data; no updater, package, or
# ChatGPT process is launched. The source classifier is loaded from the root
# entrypoint so the concrete refusal proof stays coupled to production code.
$rootAstTokens = $null; $rootAstErrors = $null
$rootAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'windows/Enable-ChatGPTRemote.ps1'), [ref]$rootAstTokens, [ref]$rootAstErrors)
if ($rootAstErrors.Count) { throw $rootAstErrors[0] }
$runningRefusalAst = @($rootAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-DesktopAppPrelaunchRunningRefusal' }, $true))[0]
if ($null -eq $runningRefusalAst) { throw 'Desktop-app running-refusal classifier is missing.' }
. ([scriptblock]::Create($runningRefusalAst.Extent.Text))
foreach ($entrypointText in @($rootText, $startupText)) {
    if (-not $entrypointText.Contains('function Test-DesktopAppPrelaunchRunningRefusal') -or
        -not $entrypointText.Contains('desktopUpdateAttachOnly = $true')) {
        throw 'Both entrypoints must contain the narrow desktop-update attach recovery.'
    }
}
# Reproduce the real child updater stderr path. Windows PowerShell emits a
# native -File Write-Error as several formatted ErrorRecord strings, while a
# PowerShell 7 parent sees the same child output through 2>&1. Verify the
# classifier recognizes only the exact refusal after the production wrapper
# joins those records, and still rejects a generic updater error.
$stderrFixture = Join-Path ([IO.Path]::GetTempPath()) ('remote-enabler-desktop-update-stderr-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    @'
param([ValidateSet('refusal', 'generic')][string]$Mode)
if ($Mode -eq 'refusal') {
    Write-Error -Message 'ChatGPT.exe is running. Finish active work and close it, then retry. This updater will not stop or kill the app.' -ErrorAction Continue
} else {
    Write-Error -Message 'The signed ChatGPT desktop updater returned invalid package proof.' -ErrorAction Continue
}
exit 1
'@ | Set-Content -LiteralPath $stderrFixture -Encoding UTF8
    $desktopChildPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $desktopChildPowerShell -PathType Leaf)) { throw 'Windows PowerShell child fixture is unavailable.' }
    $stderrErrorAction = $ErrorActionPreference
    try {
        # The production updater gate uses Continue so expected child stderr can
        # be joined and classified before the nonzero exit is rethrown.
        $ErrorActionPreference = 'Continue'
        foreach ($stderrMode in @('refusal', 'generic')) {
            $nativeOutput = @(& $desktopChildPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $stderrFixture -Mode $stderrMode 2>&1)
            $nativeExitCode = $LASTEXITCODE
            $nativeDetail = ($nativeOutput | ForEach-Object { [string]$_ }) -join ' '
            $nativeMessage = "The signed ChatGPT desktop update failed before launch (exit $nativeExitCode): $nativeDetail"
            $nativeRecognized = Test-DesktopAppPrelaunchRunningRefusal -Message $nativeMessage
            if ($nativeExitCode -ne 1) { throw "Native stderr fixture returned an unexpected exit code for $stderrMode." }
            if ($stderrMode -eq 'refusal' -and -not $nativeRecognized) { throw "Native Windows PowerShell refusal formatting was not recognized: $nativeMessage" }
            if ($stderrMode -eq 'generic' -and $nativeRecognized) { throw 'Native generic updater failure was incorrectly recognized as a running-app refusal.' }
        }
    } finally {
        $ErrorActionPreference = $stderrErrorAction
    }
} finally {
    Remove-Item -LiteralPath $stderrFixture -Force -ErrorAction SilentlyContinue
}
$desktopUpdateBlocks = @(
    [pscustomobject]@{
        Name = 'root'
        Text = $rootText
        EndToken = '$stableTimer = [Diagnostics.Stopwatch]::StartNew()'
    },
    [pscustomobject]@{
        Name = 'mobile'
        Text = $startupText
        EndToken = 'Assert-Controllers'
    }
)
function Invoke-DesktopAppPrelaunchUpdate {
    param([string]$UpdaterPath, [scriptblock]$ProcessEnumerator, [switch]$UseProxy)
    $script:desktopUpdateCalls++
    switch ($script:desktopUpdateMode) {
        'race-updater' {
            $script:fixtureStartupProcesses = [pscustomobject]@{ CommandLine = 'ChatGPT.exe' }
            throw 'The signed ChatGPT desktop update failed before launch (exit 1): ChatGPT.exe is running. Finish active work and close it, then retry. This updater will not stop or kill the app.'
        }
        'race-helper' {
            throw 'ChatGPT.exe is running. Finish active work and close it, then retry. The launch updater will not stop or kill the app.'
        }
        'generic' {
            $script:fixtureStartupProcesses = [pscustomobject]@{ CommandLine = 'ChatGPT.exe' }
            throw 'The signed ChatGPT desktop update failed before launch (exit 1): generic update failure.'
        }
        default { return }
    }
}
$desktopAppUpdater = 'fixture-updater'; $UseProxy = $false; $SkipDesktopAppUpdateOnce = $false; $UpdateResume = $false
function Assert-Controllers {}
foreach ($desktopBlock in $desktopUpdateBlocks) {
    $desktopStart = $desktopBlock.Text.IndexOf('$desktopUpdateAttachOnly = $false')
    $desktopEnd = $desktopBlock.Text.IndexOf($desktopBlock.EndToken, $desktopStart)
    if ($desktopStart -lt 0 -or $desktopEnd -le $desktopStart) { throw "Desktop update fixture boundary missing: $($desktopBlock.Name)" }
    $desktopGate = [scriptblock]::Create($desktopBlock.Text.Substring($desktopStart, $desktopEnd - $desktopStart))

    $script:fixtureStartupProcesses = @(); $script:desktopUpdateMode = 'race-updater'; $script:desktopUpdateCalls = 0
    $attachExistingSession = $false; $desktopUpdateAttachOnly = $false; $caught = $null
    try { . $desktopGate } catch { $caught = $_.Exception.Message }
    if ($caught -or $script:desktopUpdateCalls -ne 1 -or -not $desktopUpdateAttachOnly -or -not $attachExistingSession) {
        throw "$($desktopBlock.Name) did not convert the concrete running-app update refusal into attach mode: $caught"
    }

    $script:fixtureStartupProcesses = @(); $script:desktopUpdateMode = 'race-helper'; $script:desktopUpdateCalls = 0
    $attachExistingSession = $false; $desktopUpdateAttachOnly = $false; $caught = $null
    try { . $desktopGate } catch { $caught = $_.Exception.Message }
    if (-not $caught -or $script:desktopUpdateCalls -ne 1 -or $desktopUpdateAttachOnly -or $attachExistingSession) {
        throw "$($desktopBlock.Name) bypassed a running-app refusal without fresh app proof."
    }

    $script:fixtureStartupProcesses = @(); $script:desktopUpdateMode = 'generic'; $script:desktopUpdateCalls = 0
    $attachExistingSession = $false; $desktopUpdateAttachOnly = $false; $caught = $null
    try { . $desktopGate } catch { $caught = $_.Exception.Message }
    if (-not $caught -or $script:desktopUpdateCalls -ne 1 -or $desktopUpdateAttachOnly) {
        throw "$($desktopBlock.Name) bypassed a generic desktop-update failure."
    }
}

# Probe a disposable console child, not ChatGPT, to verify the process creation
# flags suppress the console itself (including under Windows Terminal defaults).
. (Join-Path $root 'windows/CodexRemoteMobileProject/StartupProgress.ps1')
$consoleProbePath = Join-Path ([IO.Path]::GetTempPath()) ('remote-enabler-console-probe-' + [guid]::NewGuid().ToString('N') + '.txt')
$consoleProbe = $null
try {
    $probeSource = 'Add-Type -TypeDefinition ''using System; using System.Runtime.InteropServices; public static class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }''; [IO.File]::WriteAllText(''' + $consoleProbePath.Replace("'", "''") + ''', [ConsoleProbe]::GetConsoleWindow().ToInt64().ToString())'
    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeSource))
    # Execute the actual process creation statements at every changed worker
    # site, substituting only the executable and probe payload. No app launches.
    $powerShell = (Get-Process -Id $PID).Path
    $workerArguments = "-NoProfile -NonInteractive -EncodedCommand $encodedProbe"
    $workerStarts = @([scriptblock]::Create('Start-StartupBackgroundProcess -FilePath $powerShell -ArgumentList $workerArguments'))
    foreach ($site in @(
        @{ path = 'windows/CodexRemoteSimple/CodexRemoteSimple.ps1'; begin = '$workerStart ='; end = '$proxyWorker = [Diagnostics.Process]::Start($workerStart)'; result = '$proxyWorker' },
        @{ path = 'windows/CodexRemoteMobileProject/UpdateSessionSurvivorLauncher.ps1'; begin = '$cleanupStart ='; end = '$cleanupProcess = [Diagnostics.Process]::Start($cleanupStart)'; result = '$cleanupProcess' }
    )) {
        $siteText = Get-Content -LiteralPath (Join-Path $root $site.path) -Raw
        $begin = $siteText.IndexOf($site.begin)
        $end = $siteText.IndexOf($site.end, $begin)
        if ($begin -lt 0 -or $end -lt 0) { throw "Missing worker launch boundary: $($site.path)" }
        $statements = $siteText.Substring($begin, $end + $site.end.Length - $begin)
        if ($site.result -eq '$cleanupProcess') {
            $statements = $statements -replace '(?m)^\s*\$cleanupStart\.Arguments = .*$', '    $cleanupStart.Arguments = $workerArguments'
        }
        $workerStarts += [scriptblock]::Create($statements + "`n" + $site.result)
    }
    foreach ($workerStartProbe in $workerStarts) {
        if (Test-Path -LiteralPath $consoleProbePath) { Remove-Item -LiteralPath $consoleProbePath -Force }
        $consoleProbe = & $workerStartProbe
        if (-not $consoleProbe.WaitForExit(30000)) { throw 'Disposable console probe timed out.' }
        if ($consoleProbe.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $consoleProbePath) -or (Get-Content -LiteralPath $consoleProbePath -Raw).Trim() -ne '0') { throw 'Background worker allocated a console or failed its probe.' }
        $consoleProbe.Dispose(); $consoleProbe = $null
    }
} finally {
    if ($consoleProbe) { $consoleProbe.Dispose() }
    if (Test-Path -LiteralPath $consoleProbePath) { Remove-Item -LiteralPath $consoleProbePath -Force }
}
# The detached cleanup worker must receive complete paths even when the user's
# profile/state directory contains spaces. Exercise only a disposable owned tree.
$cleanupFixture = Join-Path ([IO.Path]::GetTempPath()) ('remote enabler cleanup ' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $cleanupFixture 'state with spaces'
$detachedDirectory = Join-Path $cleanupFixture 'detached host'
try {
    New-Item -ItemType Directory -Path $stateRoot, $detachedDirectory -Force | Out-Null
    $fixtureExe = Join-Path $detachedDirectory 'UpdateSessionTaskHost.exe'
    [IO.File]::WriteAllText($fixtureExe, 'fixture')
    $cleanupAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'windows/CodexRemoteMobileProject/UpdateSessionSurvivorLauncher.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw $errors[0] }
    foreach ($functionName in @('Assert-PlainLaunchPath', 'Start-DetachedTaskHostCleanup')) {
        $definition = $cleanupAst.Find({ param($astNode) $astNode -is [Management.Automation.Language.FunctionDefinitionAst] -and $astNode.Name -eq $functionName }, $true)
        if (-not $definition) { throw "Missing cleanup function: $functionName" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    if (-not [IO.Path]::GetFullPath($detachedDirectory).StartsWith(([IO.Path]::GetFullPath($cleanupFixture) + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup fixture escaped its root.' }
    Start-DetachedTaskHostCleanup -ProcessId ([int]::MaxValue) -ExecutablePath $fixtureExe
    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(15)
    while ((Test-Path -LiteralPath $detachedDirectory) -and [DateTime]::UtcNow -lt $cleanupDeadline) { Start-Sleep -Milliseconds 100 }
    if (Test-Path -LiteralPath $detachedDirectory) { throw 'Detached cleanup did not receive the complete spaced path.' }
} finally {
    $fixtureResolved = [IO.Path]::GetFullPath($cleanupFixture)
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($fixtureResolved) -ne $temporaryParent -or [IO.Path]::GetFileName($fixtureResolved) -notmatch '^remote enabler cleanup [0-9a-f]{32}$') { throw 'Unsafe cleanup fixture root.' }
    if (Test-Path -LiteralPath $fixtureResolved) { Remove-Item -LiteralPath $fixtureResolved -Recurse -Force }
}
# The coordinator must recognize an attached ordinary process by exact PID,
# executable and creation token, without requiring a startup debugger argument.
$identitySource = Join-Path $root 'windows/CodexRemoteMobileProject/UpdateSessionLauncher.ps1'
$identityAst = [Management.Automation.Language.Parser]::ParseFile($identitySource, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors[0] }
$identityDefinition = $identityAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ExactAppIdentity' }, $true)
. ([scriptblock]::Create($identityDefinition.Extent.Text))
$stableStatePath = Join-Path ([IO.Path]::GetTempPath()) ('attached-identity-' + [guid]::NewGuid().ToString('N') + '.json')
$fixtureProcess = [Diagnostics.Process]::GetCurrentProcess()
try {
    $hookDefinition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Open-CrsInspectorHook' }, $true)
    . ([scriptblock]::Create($hookDefinition.Extent.Text))
    $hookError = $null
    try { $unexpectedMapping = Open-CrsInspectorHook -Process $fixtureProcess -WaitMilliseconds 0; $unexpectedMapping.Dispose() } catch { $hookError = $_.Exception.Message }
    if ($hookError -notlike 'Runtime inspector hook unavailable:*left running*') { throw "Missing hook must produce a specific non-disruptive error: $hookError" }
    $fixtureAppPath = $fixtureProcess.MainModule.FileName
    $fixtureStarted = $fixtureProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
    function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) [pscustomobject]@{ ProcessId = $PID; ExecutablePath = $fixtureAppPath; CommandLine = 'ordinary-app' } }
    foreach ($scenario in @('valid', 'reused-pid', 'different-pid')) {
        $saved = @{ rendererPort = 9229; executablePath = $fixtureAppPath; launchMethod = 'attached-existing-process'; launchProcessId = $(if ($scenario -eq 'different-pid') { $PID + 1 } else { $PID }); launchProcessStartTimeFileTimeUtc = $(if ($scenario -eq 'reused-pid') { $fixtureStarted - 10000 } else { $fixtureStarted }) }
        $saved | ConvertTo-Json | Set-Content -LiteralPath $stableStatePath -Encoding utf8
        $caught = $null; $identityResult = $null
        try { $identityResult = Get-ExactAppIdentity } catch { $caught = $_.Exception.Message }
        if ($scenario -eq 'valid') {
            if ($caught -or $identityResult.pid -ne $PID) { throw "Ordinary attached identity was rejected: $caught" }
        } elseif (-not $caught) { throw "Changed process identity was accepted: $scenario" }
    }
} finally {
    $fixtureProcess.Dispose()
    if (Test-Path -LiteralPath $stableStatePath) { Remove-Item -LiteralPath $stableStatePath -Force }
}
# Run the real reuse probe with a disposable native child. It first exercises
# foreign listener rejection, then reaches the orchestrator's native stderr
# fallback. In Windows PowerShell 5.1, Stop would otherwise bypass that path.
& {
    $probeRoot = Join-Path ([IO.Path]::GetTempPath()) ('attachment-stderr-' + [guid]::NewGuid().ToString('N'))
    $previousRuntimeRoot = Get-Variable -Name RuntimeRoot -Scope Script -ErrorAction SilentlyContinue
    try {
        New-Item -ItemType Directory -Path $probeRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $probeRoot 'attach-existing.cjs'), 'const fs = require("fs"); const calls = require("path").join(__dirname, "calls.txt"); if (process.argv.includes("--verify-only")) { fs.appendFileSync(calls, "verify\n"); console.log(JSON.stringify({pid:123,rendererPort:9229,transport:"electron-main-inspector-v1"})); } else { fs.appendFileSync(calls, "orchestrator\n"); process.stderr.write("Fixture orchestrator failure\\n"); process.exitCode = 1; }', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $probeRoot 'orchestrator.js'), 'const fs = require("fs"); fs.appendFileSync(require("path").join(__dirname, "calls.txt"), "orchestrator\n"); process.stderr.write("Fixture orchestrator failure\\n"); process.exitCode = 1;', [Text.UTF8Encoding]::new($false))
        $script:RuntimeRoot = $probeRoot
        $definition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CrsProbeExisting' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        function Test-CrsPortOpen { param($Port) return $true }
        $script:probeEndpointCalls = 0
        $script:probeEndpointSequence = @($true, $false)
        function Test-CrsOwnedRendererEndpoint {
            param([int]$ProcessId, [int]$Port)
            $index = [Math]::Min($script:probeEndpointCalls, $script:probeEndpointSequence.Count - 1)
            $script:probeEndpointCalls++
            return [bool]$script:probeEndpointSequence[$index]
        }
        $script:probeIdentityCalls = 0
        function Get-CrsProcessIdentity {
            param($ProcessId, $ExecutablePath)
            $script:probeIdentityCalls++
            return [pscustomobject]@{ StartTimeFileTimeUtc = 123L }
        }
        $fixtureState = [pscustomobject]@{ rendererPort = 9229; bridgeMode = 'native-renderer'; launchMethod = 'attached-existing-process'; launchProcessId = 123; executablePath = 'C:\Fixture\ChatGPT.exe'; launchProcessStartTimeFileTimeUtc = 123L }
        $ErrorActionPreference = 'Stop'
        $node = @{ Path = (Get-Command node.exe -ErrorAction Stop).Source }
        $result = Invoke-CrsProbeExisting -Node $node -State $fixtureState
        $calls = if (Test-Path -LiteralPath (Join-Path $probeRoot 'calls.txt')) { Get-Content -LiteralPath (Join-Path $probeRoot 'calls.txt') } else { @() }
        if ($null -ne $result -or $script:probeEndpointCalls -ne 2 -or $script:probeIdentityCalls -ne 1 -or ($calls -join ',') -ne 'verify' -or $ErrorActionPreference -ne 'Stop') {
            throw 'Foreign listener ownership was not rejected before the orchestrator probe.'
        }
        $script:probeEndpointCalls = 0
        $script:probeEndpointSequence = @($true, $true)
        Remove-Item -LiteralPath (Join-Path $probeRoot 'calls.txt') -Force
        $result = Invoke-CrsProbeExisting -Node $node -State $fixtureState
        $calls = Get-Content -LiteralPath (Join-Path $probeRoot 'calls.txt')
        if ($null -ne $result -or ($calls -join ',') -ne 'verify,orchestrator' -or $ErrorActionPreference -ne 'Stop') {
            throw 'Native orchestrator stderr did not return unknown and restore the caller error policy.'
        }
    } finally {
        if ($previousRuntimeRoot) { $script:RuntimeRoot = $previousRuntimeRoot.Value } else { Remove-Variable -Name RuntimeRoot -Scope Script -ErrorAction SilentlyContinue }
        $resolvedProbeRoot = [IO.Path]::GetFullPath($probeRoot).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolvedProbeRoot) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolvedProbeRoot) -notmatch '^attachment-stderr-[0-9a-f]{32}$') { throw 'Unsafe native-error fixture cleanup root.' }
        if (Test-Path -LiteralPath $resolvedProbeRoot) { Remove-Item -LiteralPath $resolvedProbeRoot -Recurse -Force }
    }
}
# Exercise ordinary Node-inspector attachment with a foreign listener before
# and after the service response. Neither case may reach the bridge or state
# writer even when the response claims the expected PID and endpoint.
& {
    $connectDefinition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Connect-CrsExistingApp' }, $true)
    if (-not $connectDefinition) { throw 'Missing ordinary attachment function.' }
    . ([scriptblock]::Create($connectDefinition.Extent.Text))
    $connectProcess = [Diagnostics.Process]::GetCurrentProcess()
    $connectPid = [int]$connectProcess.Id
    $connectExe = [IO.Path]::GetFullPath($connectProcess.MainModule.FileName)
    $script:connectPid = $connectPid
    $script:connectExe = $connectExe
    $connectFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('ordinary-attach-' + [guid]::NewGuid().ToString('N'))
    $previousRuntimeRoot = Get-Variable -Name RuntimeRoot -Scope Script -ErrorAction SilentlyContinue
    try {
        New-Item -ItemType Directory -Path $connectFixtureRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $connectFixtureRoot 'attach-existing.cjs'), "console.log(JSON.stringify({pid:$connectPid,rendererPort:9229,transport:'electron-main-inspector-v1'}));", [Text.UTF8Encoding]::new($false))
        $script:RuntimeRoot = $connectFixtureRoot
        $TimeoutSeconds = 1
        $connectPackage = [pscustomobject]@{ ExecutablePath = $connectExe }
        $connectCompatibility = [pscustomobject]@{ bridgeMode = 'native-renderer' }
        $connectNode = [pscustomobject]@{ Path = (Get-Command node.exe -ErrorAction Stop).Source }
        $script:connectEndpointCalls = 0
        $script:connectEndpointSequence = @($false)
        $script:connectHookCalls = 0; $script:connectBridgeCalls = 0; $script:connectWriteCalls = 0
        function Get-CimInstance {
            param($ClassName, $Filter, $ErrorAction)
            [pscustomobject]@{ ProcessId = $script:connectPid; ExecutablePath = $script:connectExe; CommandLine = 'ordinary-app' }
        }
        function Test-CrsPortOpen { param($Port) return $true }
        function Test-CrsOwnedRendererEndpoint {
            param([int]$ProcessId, [int]$Port)
            $index = [Math]::Min($script:connectEndpointCalls, $script:connectEndpointSequence.Count - 1)
            $script:connectEndpointCalls++
            return $ProcessId -eq $script:connectPid -and $Port -eq 9229 -and [bool]$script:connectEndpointSequence[$index]
        }
        function Open-CrsInspectorHook {
            param($Process, [int]$WaitMilliseconds)
            $script:connectHookCalls++
            $mapping = [pscustomobject]@{}
            $mapping | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -Force
            return $mapping
        }
        function Invoke-CrsBridge {
            param($Node, [int]$RendererPort, $MainPort, [string]$ProxyServer, [string]$BridgeMode)
            $script:connectBridgeCalls++
            return [pscustomobject]@{ ok = $true; renderer = @{ probe = @{ proof = $true } } }
        }
        function Write-CrsState {
            param($Package, [int]$RendererPort, $MainPort, $Probe, $Launch, [bool]$ProxyMode, [string]$BridgeMode)
            $script:connectWriteCalls++
        }

        foreach ($case in @(
            @{ Name = 'foreign-before-service'; Sequence = @($false); ExpectedMessage = '*different local process*'; ExpectedHooks = 0; ExpectedEndpointCalls = 1 },
            @{ Name = 'foreign-after-service'; Sequence = @($true, $false); ExpectedMessage = '*changed ownership*'; ExpectedHooks = 1; ExpectedEndpointCalls = 2 },
            @{ Name = 'owned'; Sequence = @($true, $true); ExpectedMessage = $null; ExpectedHooks = 1; ExpectedEndpointCalls = 2 }
        )) {
            $script:connectEndpointCalls = 0
            $script:connectEndpointSequence = $case.Sequence
            $script:connectHookCalls = 0; $script:connectBridgeCalls = 0; $script:connectWriteCalls = 0
            $caught = $null
            try { $attached = Connect-CrsExistingApp -Package $connectPackage -Node $connectNode -Compatibility $connectCompatibility -ProxyMode $false -LegacyDeviceKeysRequired $false } catch { $caught = $_.Exception.Message }
            if ($case.ExpectedMessage) {
                if ($caught -notlike $case.ExpectedMessage -or $script:connectHookCalls -ne $case.ExpectedHooks -or $script:connectEndpointCalls -ne $case.ExpectedEndpointCalls -or
                    $script:connectBridgeCalls -ne 0 -or $script:connectWriteCalls -ne 0) { throw "Foreign inspector listener was not refused safely: $($case.Name): $caught" }
            } elseif ($caught -or $attached -ne $true -or $script:connectHookCalls -ne 1 -or $script:connectEndpointCalls -ne 2 -or
                $script:connectBridgeCalls -ne 1 -or $script:connectWriteCalls -ne 1) { throw "Owned inspector attachment regressed: $caught" }
        }
    } finally {
        $connectProcess.Dispose()
        if ($previousRuntimeRoot) { $script:RuntimeRoot = $previousRuntimeRoot.Value } else { Remove-Variable -Name RuntimeRoot -Scope Script -ErrorAction SilentlyContinue }
        $resolvedConnectRoot = [IO.Path]::GetFullPath($connectFixtureRoot).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolvedConnectRoot) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolvedConnectRoot) -notmatch '^ordinary-attach-[0-9a-f]{32}$') { throw 'Unsafe ordinary-attachment fixture cleanup root.' }
        if (Test-Path -LiteralPath $resolvedConnectRoot) { Remove-Item -LiteralPath $resolvedConnectRoot -Recurse -Force }
    }
}
# Exercise the managed native-renderer repair as a pure fixture. The fixture
# process is this test host; every endpoint, bridge and state write
# is replaced before the production repair function is invoked.
& {
    $repairDefinition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CrsManagedNativeSessionRepair' }, $true)
    if (-not $repairDefinition) { throw 'Missing managed native-session repair function.' }
    . ([scriptblock]::Create($repairDefinition.Extent.Text))
    $ownershipDefinition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CrsOwnedProcessIdentity' }, $true)
    . ([scriptblock]::Create($ownershipDefinition.Extent.Text))
    $repairFixtureProcess = [Diagnostics.Process]::GetCurrentProcess()
    $repairFixturePid = [int]$repairFixtureProcess.Id
    $repairFixtureExe = [IO.Path]::GetFullPath($repairFixtureProcess.MainModule.FileName)
    $repairFixtureStart = [long]$repairFixtureProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
    $script:repairFixturePid = $repairFixturePid
    $script:repairFixtureExe = $repairFixtureExe
    $script:repairIdentityExe = $repairFixtureExe
    $script:repairFixtureStart = $repairFixtureStart
    try {
        $ownedEndpointDefinition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-CrsOwnedRendererEndpoint' }, $true)
        . ([scriptblock]::Create($ownedEndpointDefinition.Extent.Text))
        function Get-NetTCPConnection {
            param($LocalAddress, $LocalPort, $State, $ErrorAction)
            return $script:repairTcpRows
        }
        $script:repairTcpRows = @([pscustomobject]@{ OwningProcess = $repairFixturePid })
        if (-not (Test-CrsOwnedRendererEndpoint -ProcessId $repairFixturePid -Port 9333)) { throw 'Owned loopback endpoint fixture was rejected.' }
        $script:repairTcpRows = @([pscustomobject]@{ OwningProcess = $repairFixturePid + 1 })
        if (Test-CrsOwnedRendererEndpoint -ProcessId $repairFixturePid -Port 9333) { throw 'Foreign loopback endpoint fixture was accepted.' }
        function Get-CrsProcessIdentity {
            param([int]$ProcessId, [string]$ExecutablePath)
            if ($ProcessId -ne $script:repairFixturePid -or
                -not [string]::Equals($ExecutablePath, $script:repairIdentityExe, [StringComparison]::OrdinalIgnoreCase)) { return $null }
            [pscustomobject]@{
                ProcessId = $script:repairFixturePid
                ExecutablePath = $script:repairIdentityExe
                StartTimeFileTimeUtc = $script:repairFixtureStart
            }
        }
        function Test-CrsExpectedDebugProcess {
            param([int]$ProcessId, [string]$ExecutablePath, [int]$ExpectedPort, [scriptblock]$ProcessReader)
            $script:repairEndpointChecks++
            return $script:repairEndpointOwned -and $ProcessId -eq $script:repairFixturePid -and $ExpectedPort -eq 9333 -and
                [string]::Equals($ExecutablePath, $script:repairIdentityExe, [StringComparison]::OrdinalIgnoreCase)
        }
        function Test-CrsOwnedRendererEndpoint {
            param([int]$ProcessId, [int]$Port)
            $script:repairOwnedEndpointChecks++
            return $script:repairEndpointOwned -and $ProcessId -eq $script:repairFixturePid -and $Port -eq 9333
        }
        function Test-CrsProxyModeProof {
            param($State, [bool]$RequestedProxyMode, [string]$RequestedProxyFingerprint)
            return [bool]$script:repairProxyProof
        }
        function Test-CrsLegacyDeviceKeyModeProof {
            param($State, [bool]$Required)
            return [bool]$script:repairLegacyProof
        }
        function Invoke-CrsBridge {
            param($Node, [int]$RendererPort, $MainPort, [string]$ProxyServer, [string]$BridgeMode)
            $script:repairBridgeCalls++
            if ($BridgeMode -cne 'native-renderer' -or $RendererPort -ne 9333) { throw 'Wrong repair bridge arguments.' }
            return [pscustomobject]@{ ok = $true; renderer = @{ probe = @{ proof = $true } } }
        }
        function Write-CrsState {
            param($Package, [int]$RendererPort, $MainPort, $Probe, $Launch, [bool]$ProxyMode, [string]$BridgeMode, [string]$ProxyFingerprint, [bool]$LegacyDeviceKeyCompatibility)
            $script:repairWriteCalls++
            $script:repairWrittenPackage = $Package
            $script:repairWrittenLaunch = $Launch
            $script:repairWrittenProxy = $ProxyMode
            $script:repairWrittenLegacy = $LegacyDeviceKeyCompatibility
        }
        function New-RepairState {
            param([long]$Start = 0, [string]$Exe, [string]$Mode = 'native-renderer', [bool]$Proxy = $false, [bool]$Legacy = $false)
            if ($Start -le 0) { $Start = $script:repairFixtureStart }
            if ([string]::IsNullOrWhiteSpace($Exe)) { $Exe = $script:repairFixtureExe }
            [pscustomobject]@{
                bridgeMode = $Mode
                launchMethod = 'ApplicationActivationManager'
                launchProcessId = $script:repairFixturePid
                launchProcessOwned = $true
                launchProcessStartTimeFileTimeUtc = $Start
                executablePath = $Exe
                rendererPort = 9333
                proxyMode = $Proxy
                proxyTransport = $null
                proxyFingerprint = $null
                legacyDeviceKeyCompatibility = $Legacy
            }
        }
        $repairPackage = [pscustomobject]@{ ExecutablePath = $repairFixtureExe; FullName = 'fixture'; Version = '1' }
        $repairCompatibility = [pscustomobject]@{ bridgeMode = 'native-renderer' }
        $repairNode = [pscustomobject]@{ Path = 'fixture-node' }
        $script:repairEndpointOwned = $true
        $script:repairProxyProof = $true
        $script:repairLegacyProof = $true

        $script:repairEndpointChecks = 0; $script:repairOwnedEndpointChecks = 0; $script:repairBridgeCalls = 0; $script:repairWriteCalls = 0
        $script:repairWrittenLaunch = $null; $script:repairWrittenPackage = $null
        $valid = Invoke-CrsManagedNativeSessionRepair -Package $repairPackage -Node $repairNode -State (New-RepairState) -Compatibility $repairCompatibility -ProxyMode $false -ProxyFingerprint $null -LegacyDeviceKeysRequired $false
        if (-not $valid.Attempted -or -not $valid.Repaired -or $script:repairEndpointChecks -ne 1 -or $script:repairOwnedEndpointChecks -ne 1 -or $script:repairBridgeCalls -ne 1 -or $script:repairWriteCalls -ne 1 -or
            $script:repairWrittenLaunch.Method -ne 'ApplicationActivationManager' -or -not $script:repairWrittenLaunch.ProcessOwned -or
            [long]$script:repairWrittenLaunch.ProcessStartTimeFileTimeUtc -ne $repairFixtureStart) { throw 'Valid managed native-session repair did not preserve exact ownership and reinject the bridge.' }

        # A retained proxy/legacy-compatible private runtime is repairable when
        # both requested modes and the exact saved executable are proved.
        $privateExe = Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\patched-chatgpt\retained\app\ChatGPT.exe'
        $script:repairIdentityExe = $privateExe
        $privateState = New-RepairState -Exe $privateExe -Proxy $true -Legacy $true
        $privateState.proxyTransport = 'all-connections-proxy-v1'
        $privateState.proxyFingerprint = ('a' * 64)
        $private = Invoke-CrsManagedNativeSessionRepair -Package $repairPackage -Node $repairNode -State $privateState -Compatibility $repairCompatibility -ProxyMode $true -ProxyFingerprint ('a' * 64) -LegacyDeviceKeysRequired $true
        if (-not $private.Repaired -or $script:repairWrittenProxy -ne $true -or $script:repairWrittenLegacy -ne $true -or
            $script:repairWrittenPackage.ExecutablePath -ne $privateExe) { throw 'Matching private proxy/legacy session was not repaired with retained executable metadata.' }
        $script:repairIdentityExe = $repairFixtureExe

        foreach ($case in @(
            @{ Name = 'same-PID foreign endpoint'; State = (New-RepairState); Endpoint = $false; Proxy = $true; Legacy = $true },
            @{ Name = 'mode mismatch'; State = (New-RepairState); Endpoint = $true; Proxy = $false; Legacy = $true },
            @{ Name = 'legacy bridge mode'; State = (New-RepairState -Mode 'legacy-main-shim'); Endpoint = $true; Proxy = $true; Legacy = $true },
            @{ Name = 'legacy mode unavailable'; State = (New-RepairState); Endpoint = $true; Proxy = $true; Legacy = $false }
        )) {
            $script:repairEndpointOwned = [bool]$case.Endpoint
            $script:repairProxyProof = [bool]$case.Proxy
            $script:repairLegacyProof = [bool]$case.Legacy
            $beforeEndpoint = $script:repairOwnedEndpointChecks; $beforeBridge = $script:repairBridgeCalls; $beforeWrite = $script:repairWriteCalls
            $failure = Invoke-CrsManagedNativeSessionRepair -Package $repairPackage -Node $repairNode -State $case.State -Compatibility $repairCompatibility -ProxyMode $false -ProxyFingerprint $null -LegacyDeviceKeysRequired ($case.Name -eq 'legacy mode unavailable')
            if (-not $failure.Attempted -or $failure.Repaired -or [string]::IsNullOrWhiteSpace([string]$failure.Reason) -or
                $script:repairOwnedEndpointChecks -ne $beforeEndpoint -or $script:repairBridgeCalls -ne $beforeBridge -or $script:repairWriteCalls -ne $beforeWrite) { throw "Unsafe managed-session repair was accepted: $($case.Name)" }
        }
        $script:repairEndpointOwned = $true; $script:repairProxyProof = $true; $script:repairLegacyProof = $true
        $foreignExe = New-RepairState -Exe (Join-Path ([IO.Path]::GetTempPath()) 'foreign-chatgpt.exe')
        $foreign = Invoke-CrsManagedNativeSessionRepair -Package $repairPackage -Node $repairNode -State $foreignExe -Compatibility $repairCompatibility -ProxyMode $false -ProxyFingerprint $null -LegacyDeviceKeysRequired $false
        if ($foreign.Attempted -or $foreign.Repaired) { throw 'Stale foreign executable record was accepted for managed-session repair.' }
        # Exercise the real Enable branch and repair/ownership functions:
        # a previous managed app must not veto attachment to the current ordinary app.
        $deadState = New-RepairState
        $deadState.launchProcessId = $repairFixturePid + 1
        foreach ($staleState in @($deadState, (New-RepairState -Start ($repairFixtureStart - 1)), $foreignExe)) {
            $state = $staleState; $package = $repairPackage; $node = $repairNode
            $compatibility = $repairCompatibility; $bridgeMode = 'native-renderer'
            $AttachOnly = $true; $UseProxy = $false; $legacyDeviceKeyCompatibilityNeeded = $false
            $fixtureProbe = $null; $fixtureModeMatches = $true
            $script:ordinaryFallbackCalls = 0
            function Connect-CrsExistingApp {
                param($Package, $Node, $Compatibility, $ProxyMode, $LegacyDeviceKeysRequired)
                $script:ordinaryFallbackCalls++
                return $true
            }
            $beforeBridge = $script:repairBridgeCalls
            & $runEnable
            if ($script:ordinaryFallbackCalls -ne 1 -or $script:repairBridgeCalls -ne $beforeBridge) { throw 'Stale managed state blocked ordinary attachment or triggered repair.' }
        }
    } finally {
        $repairFixtureProcess.Dispose()
    }
}
'Existing session attachment regression passed (managed reuse, ordinary attachment, exact coordinator identity, autostart, recovery, native-error fallback and console-free background child).'
