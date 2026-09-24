[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Remove', 'Run', 'Probe', 'RepairPublisher')]
    [string]$Action = 'Probe',
    [string]$TargetUser,
    [ValidateRange(0, 300)]
    [int]$DelaySeconds = 30,
    [ValidateRange(45, 120)]
    [int]$MobileReadyTimeoutSeconds = 45,
    [string]$NodePath,
    [switch]$UseProxy,
    [switch]$ReplaceRunningApp,
    [switch]$SkipDesktopAppUpdateOnce,
    [switch]$SkipUpdateCheckOnce,
    [switch]$SkipPrelaunchUpdateOnce,
    [switch]$RecoveryContinuation,
    [switch]$UpdateResume,
    [string]$RelaunchHandoffPath,
    [switch]$ContinuationAfterAcceptedHandshake,
    [int]$ContinuationParentProcessId = 0,
    [long]$ContinuationParentProcessStartTimeFileTimeUtc = 0,
    [int]$ParentProcessId = 0,
    [long]$ParentProcessStartTimeFileTimeUtc = 0,
    [string]$ReadyEventName,
    [string]$RejectedEventName,
    [string]$LegacyPublisherScriptPath
)

$ErrorActionPreference = 'Stop'

function Set-ProcessUserTemporaryDirectory {
    $localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
        throw 'The per-user local application-data directory is unavailable.'
    }
    $temporaryDirectory = [IO.Path]::GetFullPath((Join-Path $localApplicationData 'Temp'))
    [IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
    $env:TEMP = $temporaryDirectory
    $env:TMP = $temporaryDirectory
}

Set-ProcessUserTemporaryDirectory
$taskName = 'Codex Remote Mobile Features at Logon'
$computerName = $env:COMPUTERNAME.ToUpperInvariant()

$sourceBundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$sourcePackageRoot = Split-Path -Parent $sourceBundleRoot
$stableModule = Join-Path $sourcePackageRoot 'StableInstall.ps1'
if (-not (Test-Path -LiteralPath $stableModule -PathType Leaf)) { throw "Stable installation resolver is missing: $stableModule" }
. $stableModule
$bundleParent = Get-StableInstallRoot
if (-not [string]::Equals($sourcePackageRoot, $bundleParent, [StringComparison]::OrdinalIgnoreCase)) {
    # Reconcile an extracted package before calling installed controllers with
    # new switches. The resolver preserves a healthy same/newer installation.
    $bundleParent = Ensure-StableInstallRoot -SourceRoot $sourcePackageRoot -StableRoot $bundleParent
}
$bundleRoot = Join-Path $bundleParent 'CodexRemoteMobileProject'
$stableController = Join-Path $bundleParent 'CodexRemoteSimple\CodexRemoteSimple.ps1'
$mobileController = Join-Path $bundleRoot 'MobileProjectView.ps1'
$maintenanceHelper = Join-Path $bundleRoot 'maintenance.js'
$publisherHeartbeatHelper = Join-Path $bundleRoot 'publisher-heartbeat.js'
$desktopAppUpdater = Join-Path $bundleParent 'Update-ChatGPTDesktop.ps1'
$updateController = Join-Path $bundleParent 'Update-ChatGPTRemote.ps1'
$updateSessionLauncher = Join-Path $bundleRoot 'UpdateSessionLauncher.ps1'
$startupProgressHelper = Join-Path $bundleRoot 'StartupProgress.ps1'
$proxyModule = Join-Path $bundleRoot 'ProxyConfiguration.psm1'
$logRoot = Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures'
$logPath = Join-Path $logRoot 'startup.log'
$rollbackRoot = Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\rollback'

function Assert-Controllers {
    foreach ($path in @($stableController, $mobileController, $maintenanceHelper, $publisherHeartbeatHelper, $proxyModule, $updateSessionLauncher, $startupProgressHelper)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required controller is missing: $path"
        }
    }
}

. $startupProgressHelper

function Write-StartupLog {
    param([AllowEmptyString()][string]$Message)
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    [IO.File]::AppendAllText($logPath, "$Message$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
}

function Write-CommandOutput {
    param([object[]]$Output)
    foreach ($item in $Output) { Write-StartupLog ([string]$item) }
}

function Get-MobileReport {
    param([object[]]$Output)
    for ($index = $Output.Count - 1; $index -ge 0; $index--) {
        try {
            $value = [string]$Output[$index] | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $value.report) {
                if ($null -ne $value.report.readiness) { return $value.report.readiness }
                return $value.report
            }
        } catch {
            # Human-readable progress may precede the final JSON proof.
        }
    }
    throw 'The mobile project view did not return JSON readiness proof.'
}

function Assert-MobileReport {
    param($Report)
    if ($null -eq $Report -or $Report.mounted -isnot [bool] -or
        $Report.localRuntimeReady -isnot [bool] -or
        $Report.authoritativeInventoryReady -isnot [bool] -or
        $Report.publisherReady -isnot [bool] -or
        $Report.ready -isnot [bool]) {
        throw 'The mobile project view returned incomplete readiness proof.'
    }
}

function Get-MobileReadinessTimeoutMessage {
    param($Report, [int]$TimeoutSeconds)
    $message = "The mobile project view did not become ready within $TimeoutSeconds seconds (mounted=$($Report.mounted), localRuntimeReady=$($Report.localRuntimeReady), authoritativeInventoryReady=$($Report.authoritativeInventoryReady), publisherReady=$($Report.publisherReady), ready=$($Report.ready))."
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.error)) {
        $message += " Last readiness error: $($Report.error)"
    }
    return $message
}

function Write-RelaunchHandoff {
    if ([string]::IsNullOrWhiteSpace($RelaunchHandoffPath)) { return }
    $resolved = [IO.Path]::GetFullPath($RelaunchHandoffPath)
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update-sessions\sessions')).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -ne 'relaunch-handoff.json') {
        throw 'The relaunch handoff path is outside the per-user update-session state.'
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolved) -Force | Out-Null
    $temporary = "$resolved.tmp"
    $handoff = [ordered]@{ ready = $true; entryPointRelative = 'CodexRemoteMobileProject\MobileProjectStartup.ps1'; at = [DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText($temporary, (($handoff | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $resolved -Force
}

function Resolve-NodePath {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    $candidates = @(
        $NodePath,
        $(if ($command) { $command.Source }),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        'C:\Program Files\nodejs\node.exe'
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        & $candidate -e 'process.exit(parseInt(process.versions.node) >= 22 && globalThis.WebSocket ? 0 : 1)' 2>$null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    throw 'Node.js 22 or newer with built-in WebSocket support was not found for the interactive user.'
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Install and Remove require an elevated Administrator PowerShell session.'
    }
}

function Get-TaskSummary {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [ordered]@{ host = $computerName; taskName = $taskName; installed = $false }
    }
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    return [ordered]@{
        host = $computerName
        taskName = $taskName
        installed = $true
        state = [string]$task.State
        user = [string]$task.Principal.UserId
        logonType = [string]$task.Principal.LogonType
        runLevel = [string]$task.Principal.RunLevel
        command = [string]$task.Actions[0].Execute
        arguments = [string]$task.Actions[0].Arguments
        lastRunTime = $info.LastRunTime
        lastTaskResult = $info.LastTaskResult
        nextRunTime = $info.NextRunTime
        logPath = '%LOCALAPPDATA%\CodexRemoteFeatures\startup.log (resolved for the task user at runtime)'
    }
}

$launcherMutexName = 'Local\ChatGPTCustomInjectionLauncher'
$handshakeRequested = $ParentProcessId -gt 0 -or
    -not [string]::IsNullOrWhiteSpace($ReadyEventName) -or
    -not [string]::IsNullOrWhiteSpace($RejectedEventName)
$readyEvent = $null
$rejectedEvent = $null
$handshakeReady = [bool]$ContinuationAfterAcceptedHandshake
$exactContinuationRequested = $ContinuationParentProcessId -gt 0 -and $ContinuationParentProcessStartTimeFileTimeUtc -gt 0
if (($SkipDesktopAppUpdateOnce -or $SkipUpdateCheckOnce -or $SkipPrelaunchUpdateOnce) -and
    -not $UpdateResume -and -not $exactContinuationRequested) {
    throw 'Internal update-skip switches require an exact validated continuation or update-session resume.'
}
if ($RecoveryContinuation -and -not $exactContinuationRequested) {
    throw 'RecoveryContinuation requires an exact validated continuation.'
}
if ($Action -ne 'RepairPublisher' -and -not [string]::IsNullOrWhiteSpace($LegacyPublisherScriptPath)) {
    throw 'LegacyPublisherScriptPath is internal to the publisher repair action.'
}

function Signal-Handshake {
    param([switch]$Rejected)
    try {
        if ($Rejected) {
            if ($rejectedEvent) { [void]$rejectedEvent.Set() }
        } elseif ($readyEvent) {
            [void]$readyEvent.Set()
        }
    } catch {
        Write-StartupLog "$(Get-Date -Format o) [$computerName] handshake signal failed: $($_.Exception.Message)"
    }
}

function Assert-HandshakeParameters {
    if (-not $handshakeRequested) { return }
    if ($ParentProcessId -le 0 -or $ParentProcessStartTimeFileTimeUtc -le 0 -or
        $ReadyEventName -notmatch '^Local\\ChatGPTCustomLauncher-Ready-[0-9a-f]{32}$' -or
        $RejectedEventName -notmatch '^Local\\ChatGPTCustomLauncher-Rejected-[0-9a-f]{32}$' -or
        $ReadyEventName -eq $RejectedEventName) {
        throw 'The launcher handoff requires an exact parent identity and two valid unpredictable handshake events.'
    }
}

function Show-StartupFailure {
    param([string]$Message)
    if (-not $ReplaceRunningApp) { return }
    try {
        if (-not ('ChatGPTRemoteStartupMessage' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ChatGPTRemoteStartupMessage {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int MessageBox(IntPtr window, string text, string caption, uint type);
}
'@
        }
        [void][ChatGPTRemoteStartupMessage]::MessageBox(
            [IntPtr]::Zero,
            "The injected launch could not be completed.`r`n`r`n$Message`r`n`r`nDetails: $logPath",
            'ChatGPT Custom',
            0x10)
    } catch {
        Write-StartupLog "$(Get-Date -Format o) [$computerName] failure dialog could not be shown"
    }
}

function Capture-ExactParent {
    if ($ParentProcessId -le 0) { return $null }
    try {
        $process = [Diagnostics.Process]::GetProcessById($ParentProcessId)
        if ($ParentProcessStartTimeFileTimeUtc -gt 0) {
            $actual = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
            if ($actual -ne $ParentProcessStartTimeFileTimeUtc) {
                $process.Dispose()
                throw "Parent process $ParentProcessId did not match the captured start time."
            }
        }
        return $process
    } catch {
        throw "The launcher parent process could not be captured exactly: $($_.Exception.Message)"
    }
}

function Get-LastJsonResult {
    param([object[]]$Output)
    $records = @($Output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($records.Count -eq 0) { throw 'The updater did not return JSON proof.' }
    try {
        $result = $records[-1] | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'The updater final output record was not valid JSON proof.'
    }
    for ($index = 0; $index -lt $records.Count - 1; $index++) {
        try {
            [void]($records[$index] | ConvertFrom-Json -ErrorAction Stop)
            throw 'The updater returned more than one JSON proof record.'
        } catch {
            if ($_.Exception.Message -eq 'The updater returned more than one JSON proof record.') { throw }
        }
    }
    return $result
}

function Get-CompleteJsonResult {
    param([object[]]$Output)
    $text = (($Output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'The updater did not return JSON proof.' }
    try {
        $value = $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'The updater did not return one complete JSON proof document.'
    }
    if ($null -eq $value -or $value -is [array]) { throw 'The updater returned invalid JSON proof.' }
    return $value
}

function Assert-DesktopAppNotRunning {
    param([scriptblock]$ProcessEnumerator)
    $processes = @(if ($ProcessEnumerator) { & $ProcessEnumerator } else { Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue })
    if ($processes.Count -gt 0) {
        throw 'ChatGPT.exe is running. Finish active work and close it, then retry. The launch updater will not stop or kill the app.'
    }
}

function Test-DesktopAppPrelaunchRunningRefusal {
    param([AllowNull()][string]$Message)
    $direct = 'ChatGPT.exe is running. Finish active work and close it, then retry. The launch updater will not stop or kill the app.'
    $updater = 'ChatGPT.exe is running. Finish active work and close it, then retry. This updater will not stop or kill the app.'
    $normalized = [regex]::Replace([string]$Message, '\s+', ' ').Trim()
    if ([string]::Equals($normalized, $direct, [StringComparison]::Ordinal)) { return $true }
    # Windows PowerShell formats native stderr as several ErrorRecord strings
    # (path, wrapped message, CategoryInfo and FullyQualifiedErrorId). Collapse
    # only formatting whitespace, then require the complete updater refusal and
    # its standard terminator. This keeps unrelated updater errors terminal.
    $formattedRefusal = '(?:^|:\s*)' + [regex]::Escape($updater) + '(?=\s*(?:\+\s+(?:CategoryInfo|FullyQualifiedErrorId)\b|$))'
    return $normalized -match $formattedRefusal
}

function Invoke-DesktopAppPrelaunchUpdate {
    param([string]$UpdaterPath, [scriptblock]$ProcessEnumerator, [switch]$UseProxy)

    if (-not (Test-Path -LiteralPath $UpdaterPath -PathType Leaf)) {
        throw "The signed ChatGPT desktop updater is missing: $UpdaterPath"
    }
    Assert-DesktopAppNotRunning -ProcessEnumerator $ProcessEnumerator
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) {
        throw "Built-in Windows PowerShell was not found: $powerShell"
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $UpdaterPath, '-Action', 'Update')
        if ($UseProxy) { $arguments += '-UseProxy' }
        $output = @(& $powerShell @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Write-CommandOutput $output
    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join ' '
        throw "The signed ChatGPT desktop update failed before launch (exit $exitCode): $detail"
    }
    $result = Get-CompleteJsonResult -Output $output
    if ([string]$result.Decision -ceq 'RemoteUnavailableCurrentInstalled') {
        if ([string]$result.Action -cne 'Update' -or [string]$result.InstalledState -cne 'Installed' -or
            $null -eq $result.Installed -or [string]$result.Installed.Name -cnotin @('OpenAI.Codex', 'OpenAI.ChatGPT-Desktop') -or
            [string]$result.Installed.Publisher -cne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -or
            [string]$result.Installed.Architecture -ine 'X64' -or
            [string]$result.Installed.SignatureKind -ine 'Store' -or [string]$result.Installed.Status -ine 'Ok' -or
            $result.CanInstall -isnot [bool] -or $result.CanInstall -or $result.TransientFailure -isnot [bool] -or -not $result.TransientFailure) {
            throw 'The signed ChatGPT desktop updater returned inconsistent offline launch proof.'
        }
        try { $installedVersion = [version]([string]$result.Installed.Version) } catch { throw 'The signed ChatGPT desktop updater returned invalid installed-version proof.' }
        Assert-DesktopAppNotRunning -ProcessEnumerator $ProcessEnumerator
        $timer.Stop()
        Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=desktop-app-update durationMs=$($timer.ElapsedMilliseconds) decision=$($result.Decision) installedVersion=$installedVersion remoteVersion=unavailable"
        return $result
    }
    if ([string]$result.Action -cne 'Update' -or [string]$result.InstalledState -cne 'Installed' -or
        $null -eq $result.Installed -or [string]$result.Installed.Name -cnotin @('OpenAI.Codex', 'OpenAI.ChatGPT-Desktop') -or
        [string]$result.Remote.Name -cne [string]$result.Installed.Name -or
        [string]$result.Installed.Publisher -cne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -or
        [string]$result.Installed.Architecture -ine 'X64') {
        throw 'The signed ChatGPT desktop updater did not prove one supported installed package.'
    }
    try {
        $installedVersion = [version]([string]$result.Installed.Version)
        $remoteVersion = [version]([string]$result.Remote.VersionText)
    } catch {
        throw 'The signed ChatGPT desktop updater returned invalid package-version proof.'
    }
    switch ([string]$result.Decision) {
        'Installed' {
            if ($result.CanInstall -isnot [bool] -or -not $result.CanInstall -or $installedVersion -ne $remoteVersion -or
                $null -eq $result.Manifest -or [string]$result.Manifest.Name -cne [string]$result.Installed.Name -or
                [version]([string]$result.Manifest.VersionText) -ne $installedVersion) {
                throw 'The signed ChatGPT desktop updater returned inconsistent installation proof.'
            }
        }
        'EqualVersion' {
            if ($result.CanInstall -isnot [bool] -or $result.CanInstall -or $installedVersion -ne $remoteVersion) {
                throw 'The signed ChatGPT desktop updater returned inconsistent current-version proof.'
            }
        }
        'DowngradeRefused' {
            if ($result.CanInstall -isnot [bool] -or $result.CanInstall -or $installedVersion -le $remoteVersion) {
                throw 'The signed ChatGPT desktop updater returned inconsistent downgrade-refusal proof.'
            }
        }
        'UpdateDeferredCurrentInstalled' {
            if ($result.CanInstall -isnot [bool] -or $result.CanInstall -or
                $result.InstallDeferred -isnot [bool] -or -not $result.InstallDeferred -or
                $installedVersion -ge $remoteVersion -or $null -eq $result.Manifest -or
                [string]$result.Manifest.Name -cne [string]$result.Installed.Name -or
                [version]([string]$result.Manifest.VersionText) -ne $remoteVersion -or
                [string]$result.Installed.SignatureKind -ine 'Store' -or [string]$result.Installed.Status -ine 'Ok') {
                throw 'The signed ChatGPT desktop updater returned inconsistent deferred-update proof.'
            }
        }
        default { throw "The signed ChatGPT desktop updater returned a non-launchable decision: $($result.Decision)" }
    }
    Assert-DesktopAppNotRunning -ProcessEnumerator $ProcessEnumerator
    $timer.Stop()
    Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=desktop-app-update durationMs=$($timer.ElapsedMilliseconds) decision=$($result.Decision) installedVersion=$installedVersion remoteVersion=$remoteVersion"
    return $result
}

function Test-RemoteScriptSupportsParameter {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ParameterName
    )

    # Get-Command reads the script metadata without executing the updater or
    # controller. This keeps startup compatible with an older installed
    # package while the update transaction is still replacing files.
    try {
        $command = Get-Command -Name $ScriptPath -CommandType ExternalScript -ErrorAction Stop
        return $null -ne $command.Parameters -and $command.Parameters.ContainsKey($ParameterName)
    } catch {
        return $false
    }
}

function Invoke-UpdateRecovery {
    param([string]$UpdaterPath, [string]$InstallRoot, [switch]$RecoverPendingOnly)

    if (-not (Test-Path -LiteralPath $UpdaterPath -PathType Leaf)) {
        throw "The Remote Enabler updater is missing: $UpdaterPath"
    }
    $previousLaunchGuard = [Environment]::GetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', '1', 'Process')
        $global:LASTEXITCODE = 0
        $recoveryArguments = @{
            Action = 'Recover'
            InstallRoot = $InstallRoot
            LaunchLockHeld = $true
        }
        $usedRecoverPendingOnly = $RecoverPendingOnly -and
            (Test-RemoteScriptSupportsParameter -ScriptPath $UpdaterPath -ParameterName 'RecoverPendingOnly')
        if ($usedRecoverPendingOnly) { $recoveryArguments.RecoverPendingOnly = $true }
        $output = @(& $UpdaterPath @recoveryArguments 2>&1)
        $exitCode = $global:LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', $previousLaunchGuard, 'Process')
    }
    Write-CommandOutput $output
    if ($exitCode -ne 0) { throw 'Update recovery failed before launch.' }
    $recovery = Get-LastJsonResult -Output $output
    if ($usedRecoverPendingOnly -and $recovery.recoveryRequired -is [bool] -and -not $recovery.recoveryRequired) {
        if ($recovery.recovered -isnot [bool] -or $recovery.recovered -or
            $recovery.integrityValid -isnot [bool] -or $recovery.integrityValid -or
            $recovery.cleanupDeferred -isnot [bool] -or -not $recovery.cleanupDeferred -or
            [string]$recovery.version -notmatch '^v\d+\.\d+\.\d+$') {
            throw 'Pending update recovery returned an incomplete no-journal proof.'
        }
    } elseif ($recovery.recovered -isnot [bool] -or $recovery.integrityValid -isnot [bool] -or -not $recovery.integrityValid -or
        [string]$recovery.version -notmatch '^v\d+\.\d+\.\d+$') {
        throw 'Update recovery did not prove installed-file integrity before launch.'
    }
    if ($recovery.recovered -and [string]$recovery.recoveryMode -notin @('complete-forward', 'rollback', 'unchanged')) {
        throw 'Update recovery returned an unsupported recovery mode.'
    }
    $migrationProperty = $recovery.PSObject.Properties['entryPointMigration']
    if ($migrationProperty -and $null -ne $migrationProperty.Value) {
        $validProperty = $migrationProperty.Value.PSObject.Properties['valid']
        if (-not $validProperty -or $validProperty.Value -isnot [bool] -or -not $validProperty.Value) {
            $message = 'Startup entry migration is incomplete. Automatic repair will retry at the next Remote Enabler launch; the current attachment can continue.'
            Write-StartupLog ("WARNING: " + $message)
            Write-Warning -Message $message -WarningAction Continue
        }
    }
    return $recovery
}

function Wait-MobileReadiness {
    param($Report, [Parameter(Mandatory)][scriptblock]$Probe, [ValidateRange(1, 120)][int]$TimeoutSeconds)
    Assert-MobileReport -Report $Report
    # Enable already has its own renderer-discovery budget. Give the installed
    # renderer the full readiness window and tolerate a replaced probe target.
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastProbeError = $null
    while (-not $Report.ready) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $message = Get-MobileReadinessTimeoutMessage -Report $Report -TimeoutSeconds $TimeoutSeconds
            if ($lastProbeError) { $message += " Last probe error: $lastProbeError" }
            throw $message
        }
        Start-Sleep -Milliseconds 500
        try {
            $probeOutput = @(& $Probe)
        } catch {
            $lastProbeError = ($_.Exception.Message -replace '[\r\n]+', ' ')
            if ($lastProbeError.Length -gt 320) { $lastProbeError = $lastProbeError.Substring(0, 320) }
            try { Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=mobile-readiness probeRetry reason=$lastProbeError" } catch {}
            continue
        }
        # A successful invocation must still return complete boolean proof.
        $Report = Get-MobileReport -Output $probeOutput
        Assert-MobileReport -Report $Report
        $lastProbeError = $null
    }
    return $Report
}

function Get-PublisherProcessProof {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory)][string[]]$ExpectedScriptPaths,
        [Parameter(Mandatory)][int]$ParentProcessId,
        [Parameter(Mandatory)][string]$ParentStartToken,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$LockPath
    )

    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    try {
        if ($process.HasExited) { return $null }
        $startToken = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        $executablePath = [IO.Path]::GetFullPath($process.MainModule.FileName)
    } catch {
        return $null
    } finally {
        $process.Dispose()
    }
    if (-not [string]::Equals($executablePath, [IO.Path]::GetFullPath($ExpectedExecutablePath), [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $record = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.CommandLine)) { return $null }
    $commandLine = [string]$record.CommandLine
    $matchedScriptPath = $null
    foreach ($candidate in $ExpectedScriptPaths) {
        $resolvedCandidate = [IO.Path]::GetFullPath($candidate)
        if ($commandLine.IndexOf(('"' + $resolvedCandidate + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matchedScriptPath = $resolvedCandidate
            break
        }
    }
    $quotedLock = '"' + [IO.Path]::GetFullPath($LockPath) + '"'
    if ([string]::IsNullOrWhiteSpace($matchedScriptPath) -or
        $commandLine.IndexOf($quotedLock, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $commandLine -notmatch "(?i)(?:^|\s)--port\s+$Port(?:\s|$)" -or
        $commandLine -notmatch "(?i)(?:^|\s)--parent-pid\s+$ParentProcessId(?:\s|$)" -or
        $commandLine -notmatch ("(?i)(?:^|\s)--parent-start-token\s+`"?{0}`"?(?:\s|$)" -f [regex]::Escape($ParentStartToken))) {
        return $null
    }
    return [pscustomobject]@{
        processId = $ProcessId
        startToken = $startToken
        executablePath = $executablePath
        scriptPath = $matchedScriptPath
        commandLine = $commandLine
    }
}

function Get-PublisherOwnerState {
    param([Parameter(Mandatory)]$Owner, [scriptblock]$ProcessLookup)
    $ownerPid = [int]$Owner.pid
    if ($ownerPid -lt 1) { return 'unknown' }
    $process = $null
    try {
        $process = if ($ProcessLookup) { & $ProcessLookup $ownerPid } else { [Diagnostics.Process]::GetProcessById($ownerPid) }
        if ($null -eq $process -or $process.HasExited) { return 'retired' }
        $actualStartToken = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
    } catch [ArgumentException] {
        return 'retired'
    } catch {
        return 'unknown'
    } finally {
        if ($process -is [IDisposable]) { $process.Dispose() }
    }
    if ([int]$Owner.protocolVersion -eq 2 -and [string]$Owner.publisherStartToken -match '^\d+$' -and
        $actualStartToken -cne [string]$Owner.publisherStartToken) {
        return 'retired'
    }
    return 'alive'
}

function Get-PublisherHandoffState {
    param([Parameter(Mandatory)]$Marker)
    if ([int]$Marker.previousOwner.pid -lt 1 -or [string]$Marker.previousOwner.startToken -notmatch '^\d+$' -or
        [int]$Marker.requester.pid -lt 1 -or [string]$Marker.requester.startToken -notmatch '^\d+$') {
        return 'unknown'
    }
    $previousState = Get-PublisherOwnerState -Owner ([pscustomobject]@{
        pid = [int]$Marker.previousOwner.pid
        protocolVersion = 2
        publisherStartToken = [string]$Marker.previousOwner.startToken
    })
    $requesterState = Get-PublisherOwnerState -Owner ([pscustomobject]@{
        pid = [int]$Marker.requester.pid
        protocolVersion = 2
        publisherStartToken = [string]$Marker.requester.startToken
    })
    if ($previousState -ceq 'alive' -or $requesterState -ceq 'alive') { return 'alive' }
    if ($previousState -ceq 'retired' -and $requesterState -ceq 'retired') { return 'retired' }
    return 'unknown'
}

function Read-PublisherLock {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "The publisher lock is unreadable and was left untouched: $Path" }
}

function Test-PublisherLockSession {
    param($Lock, [int]$ParentProcessId, [string]$ParentStartToken, [int]$Port)
    return $null -ne $Lock -and [int]$Lock.parentPid -eq $ParentProcessId -and
        [string]$Lock.parentStartToken -ceq $ParentStartToken -and [int]$Lock.port -eq $Port -and
        [string]$Lock.token -match '^[0-9a-f]{32,128}$'
}

function Open-PublisherLockExclusive {
    param([Parameter(Mandatory)][string]$Path, [int]$TimeoutMilliseconds = 2000)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) { throw }
            Start-Sleep -Milliseconds 25
        }
    } while ($true)
}

function Publish-PublisherHandoffMarkerAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][scriptblock]$ValidateCurrent,
        [scriptblock]$ReplaceFile
    )
    $temporaryPath = "$Path.handoff-$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$Path.handoff-backup-$([Guid]::NewGuid().ToString('N')).tmp"
    $temporaryStream = $null
    $currentStream = $null
    try {
        $payload = [Text.UTF8Encoding]::new($false).GetBytes((($Marker | ConvertTo-Json -Depth 4 -Compress) + [Environment]::NewLine))
        $temporaryStream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        $temporaryStream.Write($payload, 0, $payload.Length)
        $temporaryStream.Flush($true)
        $temporaryStream.Dispose()
        $temporaryStream = $null

        $currentStream = Open-PublisherLockExclusive -Path $Path
        $bytes = New-Object byte[] ([int]$currentStream.Length)
        [void]$currentStream.Read($bytes, 0, $bytes.Length)
        $current = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
        & $ValidateCurrent $current
        $currentStream.Dispose()
        $currentStream = $null

        if ($ReplaceFile) { & $ReplaceFile $temporaryPath $Path }
        else { [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true) }
        $published = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$published.state -cne 'handoff' -or [string]$published.token -cne [string]$Marker.token) {
            throw 'The publisher handoff marker was not published atomically.'
        }
    } finally {
        if ($temporaryStream) { $temporaryStream.Dispose() }
        if ($currentStream) { $currentStream.Dispose() }
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ExactPublisherHandoffMarker {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Token)
    $stream = $null
    try {
        $stream = Open-PublisherLockExclusive -Path $Path
        $bytes = New-Object byte[] ([int]$stream.Length)
        [void]$stream.Read($bytes, 0, $bytes.Length)
        $current = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
        if ([string]$current.state -cne 'handoff' -or [string]$current.token -cne $Token) {
            throw 'The publisher handoff marker changed while it was being recovered.'
        }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Wait-ExactPublisherExit {
    param([int]$ProcessId, [string]$StartToken, [int]$TimeoutMilliseconds = 30000)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $true }
    try {
        $actual = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        if ($actual -cne $StartToken) { return $true }
        return $process.WaitForExit($TimeoutMilliseconds)
    } catch {
        return $false
    } finally {
        $process.Dispose()
    }
}

function Request-PublisherHandoff {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Owner,
        [Parameter(Mandatory)]$OwnerProof,
        [Parameter(Mandatory)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory)][string]$SuccessorScriptPath,
        [Parameter(Mandatory)][int]$ParentProcessId,
        [Parameter(Mandatory)][string]$ParentStartToken,
        [Parameter(Mandatory)][int]$Port
    )

    $requester = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $requesterStartToken = $requester.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        $requesterProcessId = $requester.Id
    } finally { $requester.Dispose() }
    $handoffToken = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N'))
    $marker = [ordered]@{
        protocolVersion = 2
        state = 'handoff'
        token = $handoffToken
        parentPid = $ParentProcessId
        parentStartToken = $ParentStartToken
        port = $Port
        executablePath = [IO.Path]::GetFullPath($ExpectedExecutablePath)
        scriptPath = [IO.Path]::GetFullPath($SuccessorScriptPath)
        previousOwner = [ordered]@{
            pid = [int]$Owner.pid
            startToken = [string]$OwnerProof.startToken
            scriptPath = [string]$OwnerProof.scriptPath
            token = [string]$Owner.token
        }
        requester = [ordered]@{
            pid = $requesterProcessId
            startToken = $requesterStartToken
        }
        createdAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }

    $validateCurrent = {
        param($current)
        if (-not (Test-PublisherLockSession -Lock $current -ParentProcessId $ParentProcessId -ParentStartToken $ParentStartToken -Port $Port) -or
            [int]$current.pid -ne [int]$Owner.pid -or [string]$current.token -cne [string]$Owner.token) {
            throw 'The publisher lock changed before the handoff request could be written.'
        }
        $recheck = Get-PublisherProcessProof -ProcessId ([int]$Owner.pid) -ExpectedExecutablePath $ExpectedExecutablePath -ExpectedScriptPaths @([string]$OwnerProof.scriptPath) -ParentProcessId $ParentProcessId -ParentStartToken $ParentStartToken -Port $Port -LockPath $Path
        if ($null -eq $recheck -or [string]$recheck.startToken -cne [string]$OwnerProof.startToken -or
            -not [string]::Equals([string]$recheck.scriptPath, [string]$OwnerProof.scriptPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The publisher process identity changed before the handoff request could be written.'
        }
    }
    Publish-PublisherHandoffMarkerAtomically -Path $Path -Marker $marker -ValidateCurrent $validateCurrent

    if (-not (Wait-ExactPublisherExit -ProcessId ([int]$Owner.pid) -StartToken ([string]$OwnerProof.startToken))) {
        throw "The exact legacy publisher process $($Owner.pid) did not retire within the handoff timeout; its recoverable marker was retained."
    }
    Remove-ExactPublisherHandoffMarker -Path $Path -Token $handoffToken
}

function Complete-PublisherHandoff {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Marker,
        [Parameter(Mandatory)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedScriptPath,
        [Parameter(Mandatory)][int]$ParentProcessId,
        [Parameter(Mandatory)][string]$ParentStartToken,
        [Parameter(Mandatory)][int]$Port
    )
    if ([int]$Marker.protocolVersion -ne 2 -or [string]$Marker.state -cne 'handoff' -or
        -not (Test-PublisherLockSession -Lock $Marker -ParentProcessId $ParentProcessId -ParentStartToken $ParentStartToken -Port $Port) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$Marker.executablePath), [IO.Path]::GetFullPath($ExpectedExecutablePath), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$Marker.scriptPath), [IO.Path]::GetFullPath($ExpectedScriptPath), [StringComparison]::OrdinalIgnoreCase) -or
        [int]$Marker.previousOwner.pid -lt 1 -or [string]$Marker.previousOwner.startToken -notmatch '^\d+$' -or
        [int]$Marker.requester.pid -lt 1 -or [string]$Marker.requester.startToken -notmatch '^\d+$') {
        throw 'The publisher handoff marker did not contain exact trusted ownership proof.'
    }

    $current = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $currentProcessId = $current.Id
        $currentStartToken = $current.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
    } finally { $current.Dispose() }
    if ([int]$Marker.requester.pid -ne $currentProcessId -or [string]$Marker.requester.startToken -cne $currentStartToken) {
        $requester = Get-Process -Id ([int]$Marker.requester.pid) -ErrorAction SilentlyContinue
        if ($null -ne $requester) {
            try {
                $requesterToken = $requester.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
                if ($requesterToken -ceq [string]$Marker.requester.startToken) {
                    throw 'Another exact startup process still owns the publisher handoff.'
                }
            } finally { $requester.Dispose() }
        }
    }
    if (-not (Wait-ExactPublisherExit -ProcessId ([int]$Marker.previousOwner.pid) -StartToken ([string]$Marker.previousOwner.startToken))) {
        throw "The exact legacy publisher process $($Marker.previousOwner.pid) did not finish its prior handoff; the recoverable marker was retained."
    }
    Remove-ExactPublisherHandoffMarker -Path $Path -Token ([string]$Marker.token)
}

function Resolve-TrustedLegacyPublisherScript {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or
        [IO.Path]::GetFileName($resolved) -cne 'publisher-heartbeat.js' -or
        [IO.Path]::GetFileName((Split-Path -Parent $resolved)) -cne 'CodexRemoteMobileProject') {
        throw 'The legacy publisher path is not an exact Remote Enabler package publisher.'
    }
    $packageRoot = Split-Path -Parent (Split-Path -Parent $resolved)
    foreach ($required in @('Enable-ChatGPTRemote.ps1', 'StableInstall.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $required) -PathType Leaf)) {
            throw 'The legacy publisher path is outside a complete Remote Enabler package layout.'
        }
    }
    return $resolved
}

function Start-PublisherHeartbeat {
    param(
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$TrustedLegacyPublisherScriptPath
    )

    $stableStatePath = Join-Path $logRoot 'codexremote-simple-session.json'
    $stableState = Get-Content -LiteralPath $stableStatePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $heartbeatPort = [int]$stableState.rendererPort
    $heartbeatParent = [int]$stableState.launchProcessId
    if ($heartbeatPort -lt 1 -or $heartbeatPort -gt 65535 -or $heartbeatParent -lt 1) {
        throw 'The stable session did not report a valid heartbeat target.'
    }
    $heartbeatProcess = [Diagnostics.Process]::GetProcessById($heartbeatParent)
    try {
        $heartbeatStartToken = $heartbeatProcess.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        $heartbeatExecutable = [IO.Path]::GetFullPath($heartbeatProcess.MainModule.FileName)
    } finally { $heartbeatProcess.Dispose() }
    if (-not [string]::Equals($heartbeatExecutable, [IO.Path]::GetFullPath([string]$stableState.executablePath), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The stable session heartbeat process identity changed.'
    }
    $heartbeatLock = Join-Path $logRoot "publisher-heartbeat-$heartbeatPort.lock"
    $nodeExecutable = [IO.Path]::GetFullPath($NodePath)
    $publisherScript = [IO.Path]::GetFullPath($publisherHeartbeatHelper)
    $sourcePublisherScript = Resolve-TrustedLegacyPublisherScript -Path $TrustedLegacyPublisherScriptPath
    $trustedPublisherScripts = @($publisherScript, $sourcePublisherScript) | Select-Object -Unique
    $startPublisher = $true
    $existingPublisher = Read-PublisherLock -Path $heartbeatLock
    if ($null -ne $existingPublisher) {
        if ([string]$existingPublisher.state -ceq 'handoff') {
            $currentHandoff = Test-PublisherLockSession -Lock $existingPublisher -ParentProcessId $heartbeatParent -ParentStartToken $heartbeatStartToken -Port $heartbeatPort
            if ($currentHandoff) {
                Complete-PublisherHandoff -Path $heartbeatLock -Marker $existingPublisher -ExpectedExecutablePath $nodeExecutable -ExpectedScriptPath $publisherScript -ParentProcessId $heartbeatParent -ParentStartToken $heartbeatStartToken -Port $heartbeatPort
            } else {
                $trustedHandoff = [int]$existingPublisher.protocolVersion -eq 2 -and
                    [string]$existingPublisher.token -match '^[0-9a-f]{32,128}$' -and
                    [string]::Equals([IO.Path]::GetFullPath([string]$existingPublisher.executablePath), $nodeExecutable, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([IO.Path]::GetFullPath([string]$existingPublisher.scriptPath), $publisherScript, [StringComparison]::OrdinalIgnoreCase)
                $handoffState = if ($trustedHandoff) { Get-PublisherHandoffState -Marker $existingPublisher } else { 'unknown' }
                if ($handoffState -cne 'retired') {
                    throw "The publisher handoff belongs to a different or unverifiable renderer session ($handoffState) and was left untouched."
                }
                Remove-ExactPublisherHandoffMarker -Path $heartbeatLock -Token ([string]$existingPublisher.token)
                Write-StartupLog "$(Get-Date -Format o) [$computerName] retired prior-session publisher handoff cleared for exact successor recovery"
            }
        } else {
            $validActiveLock = [int]$existingPublisher.pid -gt 0 -and [string]$existingPublisher.token -match '^[0-9a-f]{32,128}$' -and
                ([string]::IsNullOrWhiteSpace([string]$existingPublisher.state) -or [string]$existingPublisher.state -ceq 'active')
            if (-not $validActiveLock) { throw 'The publisher lock ownership record is invalid and was left untouched.' }
            $currentSession = Test-PublisherLockSession -Lock $existingPublisher -ParentProcessId $heartbeatParent -ParentStartToken $heartbeatStartToken -Port $heartbeatPort
            $ownerProof = if ($currentSession) {
                Get-PublisherProcessProof -ProcessId ([int]$existingPublisher.pid) -ExpectedExecutablePath $nodeExecutable -ExpectedScriptPaths $trustedPublisherScripts -ParentProcessId $heartbeatParent -ParentStartToken $heartbeatStartToken -Port $heartbeatPort -LockPath $heartbeatLock
            } else { $null }
            if ($null -eq $ownerProof) {
                $ownerState = Get-PublisherOwnerState -Owner $existingPublisher
                if ($ownerState -cne 'retired') {
                    $reason = if ($currentSession) { 'owner could not be proven' } else { 'lock belongs to a different renderer session' }
                    throw "The publisher $reason ($ownerState) and was left untouched."
                }
                Write-StartupLog "$(Get-Date -Format o) [$computerName] publisher heartbeat owner retired; successor will reclaim the exact stale lock"
            } else {
                $currentPublisher = [int]$existingPublisher.protocolVersion -eq 2 -and [string]$existingPublisher.state -ceq 'active' -and
                    [string]$existingPublisher.publisherStartToken -ceq [string]$ownerProof.startToken -and
                    [string]::Equals([IO.Path]::GetFullPath([string]$existingPublisher.executablePath), $nodeExecutable, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([IO.Path]::GetFullPath([string]$existingPublisher.scriptPath), $publisherScript, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string]$ownerProof.scriptPath, $publisherScript, [StringComparison]::OrdinalIgnoreCase)
                if ($currentPublisher) {
                    Write-StartupLog "$(Get-Date -Format o) [$computerName] publisher heartbeat reused for the exact renderer session"
                    $startPublisher = $false
                } else {
                    Request-PublisherHandoff -Path $heartbeatLock -Owner $existingPublisher -OwnerProof $ownerProof -ExpectedExecutablePath $nodeExecutable -SuccessorScriptPath $publisherScript -ParentProcessId $heartbeatParent -ParentStartToken $heartbeatStartToken -Port $heartbeatPort
                }
            }
        }
    }
    if ($startPublisher) {
        $heartbeatArguments = '--no-warnings "{0}" --port {1} --parent-pid {2} --parent-start-token "{3}" --lock-path "{4}"' -f $publisherHeartbeatHelper, $heartbeatPort, $heartbeatParent, $heartbeatStartToken, $heartbeatLock
        $heartbeatWorker = Start-StartupBackgroundProcess -FilePath $NodePath -ArgumentList $heartbeatArguments
        $heartbeatWorker.Dispose()
        Write-StartupLog "$(Get-Date -Format o) [$computerName] publisher heartbeat started for the exact renderer session"
    }
}

function Invoke-PublisherRepair {
    param(
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$TrustedLegacyPublisherScriptPath
    )
    $mutex = [Threading.Mutex]::new($false, $launcherMutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::Zero) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another ChatGPT Custom or ChatGPT Remote Enabler launch is still running.' }
        Start-PublisherHeartbeat -NodePath $NodePath -TrustedLegacyPublisherScriptPath $TrustedLegacyPublisherScriptPath
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Start-MobileBackgroundServices {
    param([Parameter(Mandatory)][string]$NodePath)

    try {
        Start-PublisherHeartbeat -NodePath $NodePath -TrustedLegacyPublisherScriptPath (Join-Path $sourceBundleRoot 'publisher-heartbeat.js')
    } catch {
        Write-StartupLog "$(Get-Date -Format o) [$computerName] publisher heartbeat unavailable: $($_.Exception.Message)"
    }

    Write-StartupLog "$(Get-Date -Format o) [$computerName] renderer enabled; arming background update monitoring before readiness polling"
    try {
        $sessionTimer = [Diagnostics.Stopwatch]::StartNew()
        $sessionArguments = @{
            InstallRoot = $bundleParent
            EntryPointRelative = 'CodexRemoteMobileProject\MobileProjectStartup.ps1'
            NodePath = $NodePath
            UseProxy = [bool]$UseProxy
            ReplaceRunningApp = [bool]$ReplaceRunningApp
            SkipInitialCheck = [bool]$SkipUpdateCheckOnce
        }
        Write-CommandOutput @(& $updateSessionLauncher @sessionArguments 2>&1)
        $sessionTimer.Stop()
        Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=update-session durationMs=$($sessionTimer.ElapsedMilliseconds)"
    } catch {
        Write-StartupLog "$(Get-Date -Format o) [$computerName] update-session launch unavailable: $($_.Exception.Message)"
    }
}

function Invoke-PrelaunchUpdate {
    param([string]$UpdaterPath, [string]$InstallRoot, [switch]$UseProxy)

    if (-not (Test-Path -LiteralPath $UpdaterPath -PathType Leaf)) {
        throw "The Remote Enabler updater is missing: $UpdaterPath"
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $updateError = $null
    $manifestPath = Join-Path $InstallRoot 'RELEASE-MANIFEST.sha256'
    $manifestBeforeUpdate = $null
    try { $manifestBeforeUpdate = [IO.File]::ReadAllText($manifestPath) } catch {}
    $previousLaunchGuard = [Environment]::GetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', '1', 'Process')
        $global:LASTEXITCODE = 0
        $output = @(& $UpdaterPath -Action Update -Transport Git -InstallRoot $InstallRoot -LaunchLockHeld -UseProxy:$UseProxy 2>&1)
        $exitCode = $global:LASTEXITCODE
    } catch {
        $exitCode = 1
        $output = @()
        $updateError = $_.Exception.Message
    } finally {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', $previousLaunchGuard, 'Process')
    }
    Write-CommandOutput $output
    if ($null -eq $updateError -and $exitCode -eq 0) {
        try {
            $result = Get-LastJsonResult -Output $output
            if ($result.updated -isnot [bool]) {
                throw 'The prelaunch updater returned incomplete update proof.'
            }
            if (($result.updated -and [string]$result.method -notin @('verified-git', 'git-fast-forward')) -or
                (-not $result.updated -and [string]$result.method -cne 'verified-git')) {
                throw 'The prelaunch updater did not prove a Git-backed update.'
            }
            if ([string]$result.archiveSha256 -notmatch '^[a-f0-9]{64}$') {
                throw 'The prelaunch updater did not return an exact archive hash.'
            }
            if ($result.updated) {
                if ([string]$result.version -notmatch '^v\d+\.\d+\.\d+$') {
                    throw 'The prelaunch updater did not return an exact installed version.'
                }
            } elseif ([string]$result.latestVersion -notmatch '^v\d+\.\d+\.\d+$' -or
                [string]$result.localVersion -notmatch '^v\d+\.\d+\.\d+$') {
                throw 'The prelaunch updater did not return exact current-version proof.'
            }
        } catch {
            $updateError = $_.Exception.Message
        }
    } elseif ($null -eq $updateError) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join ' '
        $updateError = "The verified Git prelaunch update failed (exit $exitCode): $detail"
    }
    $timer.Stop()

    if ($null -eq $updateError) {
        if ($result.updated) {
            # A successful replacement must be checked before the old in-memory
            # launcher is allowed to hand off to the updated script.
            [void](Invoke-UpdateRecovery -UpdaterPath $UpdaterPath -InstallRoot $InstallRoot)
        }
        Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=prelaunch-update durationMs=$($timer.ElapsedMilliseconds) updated=$($result.updated) method=$($result.method)"
        return $result
    }

    try {
        $recovered = Invoke-UpdateRecovery -UpdaterPath $UpdaterPath -InstallRoot $InstallRoot
    } catch {
        throw "Prelaunch update failed and recovery could not prove installed-file integrity: $updateError; $($_.Exception.Message)"
    }
    if ($exitCode -ne 0) {
        # A failed download/check must not make an intact installed helper
        # unusable offline. Successful-but-malformed updater proof still fails.
        # Strict recovery has verified the installed contents. Equal manifests
        # avoid an offline respawn and retain the coordinator after rollback.
        # Changed or unknown contents still require a reload, even at the same
        # version or when an applied update already removed its journal.
        $reloadRequired = $true
        try {
            $manifestAfterUpdate = [IO.File]::ReadAllText($manifestPath)
            $reloadRequired = [string]::IsNullOrWhiteSpace($manifestBeforeUpdate) -or
                [string]::IsNullOrWhiteSpace($manifestAfterUpdate) -or
                -not [string]::Equals($manifestBeforeUpdate, $manifestAfterUpdate, [StringComparison]::Ordinal)
        } catch {}
        $reason = ([string]$updateError -replace '[\r\n]+', ' ')
        if ($reason.Length -gt 320) { $reason = $reason.Substring(0, 320) }
        Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=prelaunch-update durationMs=$($timer.ElapsedMilliseconds) updateUnavailable=true recovered=$($recovered.recovered) mode=$($recovered.recoveryMode) reloadRequired=$reloadRequired reason=$reason"
        return [pscustomobject]@{
            updated = $false
            updateUnavailable = $true
            method = 'integrity-recovery'
            reloadRequired = [bool]$reloadRequired
            recovered = [bool]$recovered.recovered
            recoveryMode = [string]$recovered.recoveryMode
            version = [string]$recovered.version
        }
    }
    throw "The required verified Git prelaunch update failed before launch: $updateError"
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-UpdatedEntryPoint {
    param(
        [string]$EntryPoint,
        [string[]]$Arguments
    )

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) {
        throw "Built-in Windows PowerShell was not found: $powerShell"
    }
    $current = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $currentStartTimeFileTimeUtc = $current.StartTime.ToUniversalTime().ToFileTimeUtc()
        $currentProcessId = $current.Id
    } finally {
        $current.Dispose()
    }
    $childArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
        '-File', $EntryPoint, '-ContinuationParentProcessId', [string]$currentProcessId,
        '-ContinuationParentProcessStartTimeFileTimeUtc', [string]$currentStartTimeFileTimeUtc
    ) + $Arguments
    $childArgumentString = ($childArguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join ' '
    # The continuation child waits for this process to exit while this process
    # still owns the launch mutex, removing the release-then-spawn race.
    $child = Start-StartupBackgroundProcess -FilePath $powerShell -ArgumentList $childArgumentString -WorkingDirectory (Split-Path -Parent $EntryPoint)
    $child.Dispose()
    Write-StartupLog "$(Get-Date -Format o) [$computerName] reloading the validated on-disk entry point after update or recovery"
}

function Wait-ForContinuationParent {
    if ($ContinuationParentProcessId -le 0) { return }
    if ($ContinuationParentProcessStartTimeFileTimeUtc -le 0) {
        throw 'The updated entry point continuation is missing the parent process start time.'
    }
    $process = $null
    $process = Get-Process -Id $ContinuationParentProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        Write-StartupLog "$(Get-Date -Format o) [$computerName] updated entry point continuation parent already exited; acquiring launch mutex"
        return
    }
    try {
        $actual = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
        if ($actual -ne $ContinuationParentProcessStartTimeFileTimeUtc) {
            throw "Continuation parent $ContinuationParentProcessId did not match the captured start time."
        }
        if (-not $process.WaitForExit(30000)) {
            throw "Continuation parent $ContinuationParentProcessId did not exit before the updated launch timeout."
        }
        Write-StartupLog "$(Get-Date -Format o) [$computerName] updated entry point continuation parent exited; acquiring launch mutex"
    } catch {
        throw "The updated entry point continuation could not wait for its parent: $($_.Exception.Message)"
    } finally {
        if ($process) { $process.Dispose() }
    }
}

switch ($Action) {
    'Run' {
        Write-StartupLog "$(Get-Date -Format o) [$computerName] startup run begins"
        $mutex = [Threading.Mutex]::new($false, $launcherMutexName)
        $acquired = $false
        $parentProcess = $null
        try {
            if ($handshakeRequested) {
                Assert-HandshakeParameters
                $readyEvent = [Threading.EventWaitHandle]::OpenExisting($ReadyEventName)
                $rejectedEvent = [Threading.EventWaitHandle]::OpenExisting($RejectedEventName)
            }
            Wait-ForContinuationParent
            try {
                $mutexWaitTimeout = if ($ContinuationParentProcessId -gt 0) { [TimeSpan]::FromSeconds(30) } else { [TimeSpan]::Zero }
                $acquired = $mutex.WaitOne($mutexWaitTimeout)
            } catch [Threading.AbandonedMutexException] {
                $acquired = $true
                Write-StartupLog "$(Get-Date -Format o) [$computerName] recovered an abandoned launcher mutex"
            }
            if (-not $acquired) {
                Signal-Handshake -Rejected
                Write-StartupLog "$(Get-Date -Format o) [$computerName] startup run rejected because another launch owns the mutex"
                throw 'Another ChatGPT Custom or ChatGPT Remote Enabler launch is still running.'
            }
            if ($handshakeRequested) {
                $parentProcess = Capture-ExactParent
                Signal-Handshake
                $handshakeReady = $true
                Write-StartupLog "$(Get-Date -Format o) [$computerName] launcher handoff accepted; waiting for parent $ParentProcessId to exit"
                if (-not $parentProcess.WaitForExit(30000)) {
                    throw "Launcher parent $ParentProcessId did not exit after accepting the handoff."
                }
                Write-StartupLog "$(Get-Date -Format o) [$computerName] launcher parent exited; continuing update and launch"
            }

            try {
                # Existing sessions skip upgrades and maintenance, but still recover an
                # interrupted helper installation. The stable
                # controller validates the exact process, endpoint and requested proxy mode.
                $appProcesses = @(Get-StartupChatGPTMainProcesses)
                $attachExistingSession = $appProcesses.Count -gt 0
                if ($attachExistingSession -and $UpdateResume) { throw 'ChatGPT is already open. Update relaunch was cancelled without changing it.' }
                if (-not $attachExistingSession -or $ReplaceRunningApp) { Start-StartupProgress -Message 'Checking the installed ChatGPT app...' }
                Set-StartupProgress -Message 'Recovering any interrupted update...'
                $recoverTimer = [Diagnostics.Stopwatch]::StartNew()
                $recovery = Invoke-UpdateRecovery -UpdaterPath $updateController -InstallRoot $bundleParent -RecoverPendingOnly
                $recoverTimer.Stop()
                Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=update-recovery durationMs=$($recoverTimer.ElapsedMilliseconds) recovered=$($recovery.recovered) mode=$($recovery.recoveryMode)"
                if ($recovery.recovered -and [string]$recovery.recoveryMode -cne 'rollback') {
                    if ($RecoveryContinuation) {
                        throw 'Update recovery changed installed files again after an exact recovery continuation; launch aborted to prevent a reload loop.'
                    }
                    $recoveryArguments = @('-Action', 'Run', '-RecoveryContinuation')
                    if ($handshakeReady) { $recoveryArguments += '-ContinuationAfterAcceptedHandshake' }
                    if ($UseProxy) { $recoveryArguments += '-UseProxy' }
                    if ($ReplaceRunningApp) { $recoveryArguments += '-ReplaceRunningApp' }
                    if ($UpdateResume) { $recoveryArguments += @('-UpdateResume', '-SkipDesktopAppUpdateOnce', '-SkipUpdateCheckOnce') }
                    if ($RelaunchHandoffPath) { $recoveryArguments += @('-RelaunchHandoffPath', $RelaunchHandoffPath) }
                    if ($NodePath) { $recoveryArguments += @('-NodePath', $NodePath) }
                    $recoveryArguments += @('-MobileReadyTimeoutSeconds', [string]$MobileReadyTimeoutSeconds)
                    Start-UpdatedEntryPoint -EntryPoint $PSCommandPath -Arguments $recoveryArguments
                    return
                }
                if ($recovery.recovered) {
                    Write-StartupLog "$(Get-Date -Format o) [$computerName] rollback recovery restored an older compatible entry point; current coordinator will complete the ordered update gates"
                }

                $proxyServer = $null
                if ($UseProxy) {
                    Set-StartupProgress -Message 'Loading the protected proxy configuration...'
                    Import-Module $proxyModule -Force
                    $proxyServer = Get-ChatGPTRemoteProxy -AllowEnvironmentFallback
                    Write-StartupLog "$(Get-Date -Format o) [$computerName] protected all-connections proxy configuration loaded"
                }

                $attachExistingSession = @(Get-StartupChatGPTMainProcesses).Count -gt 0
                $skipRemotePrelaunch = [bool]$SkipPrelaunchUpdateOnce -or $attachExistingSession
                if (-not $SkipUpdateCheckOnce -and -not $UpdateResume -and -not $skipRemotePrelaunch) {
                    Set-StartupProgress -Message 'Checking and updating Remote Enabler...'
                    $prelaunchUpdate = Invoke-PrelaunchUpdate -UpdaterPath $updateController -InstallRoot $bundleParent -UseProxy:$UseProxy
                    if ($prelaunchUpdate.updated -or $prelaunchUpdate.reloadRequired) {
                        $reloadArguments = @('-Action', 'Run', '-SkipPrelaunchUpdateOnce')
                        if ($handshakeReady) { $reloadArguments += '-ContinuationAfterAcceptedHandshake' }
                        if ($UseProxy) { $reloadArguments += '-UseProxy' }
                        if ($ReplaceRunningApp) { $reloadArguments += '-ReplaceRunningApp' }
                        if ($SkipUpdateCheckOnce) { $reloadArguments += '-SkipUpdateCheckOnce' }
                        if ($UpdateResume) { $reloadArguments += '-UpdateResume' }
                        if ($RelaunchHandoffPath) { $reloadArguments += @('-RelaunchHandoffPath', $RelaunchHandoffPath) }
                        if ($NodePath) { $reloadArguments += @('-NodePath', $NodePath) }
                        $reloadArguments += @('-MobileReadyTimeoutSeconds', [string]$MobileReadyTimeoutSeconds)
                        Start-UpdatedEntryPoint -EntryPoint $PSCommandPath -Arguments $reloadArguments
                        return
                    }
                }
                $attachExistingSession = @(Get-StartupChatGPTMainProcesses).Count -gt 0
                $desktopUpdateAttachOnly = $false
                if (-not $attachExistingSession -and -not $SkipDesktopAppUpdateOnce -and -not $UpdateResume) {
                    Set-StartupProgress -Message 'Checking the installed ChatGPT app...'
                    try {
                        [void](Invoke-DesktopAppPrelaunchUpdate -UpdaterPath $desktopAppUpdater -UseProxy:$UseProxy)
                    } catch {
                        $desktopUpdateError = [string]$_.Exception.Message
                        if (-not (Test-DesktopAppPrelaunchRunningRefusal -Message $desktopUpdateError) -or $UpdateResume) { throw }
                        $attachExistingSession = @(Get-StartupChatGPTMainProcesses).Count -gt 0
                        if (-not $attachExistingSession) { throw }
                        $desktopUpdateAttachOnly = $true
                        Write-StartupLog "$(Get-Date -Format o) [$computerName] desktop-app update observed the app opening during its final running-app check; continuing in refreshed attach mode"
                    }
                }
                Assert-Controllers
                $node = Resolve-NodePath
                if ($UseProxy) { Set-StartupProgress -Message 'Preparing the protected all-connections proxy bridge...' }
                $maintenanceTimer = [Diagnostics.Stopwatch]::StartNew()
                Set-StartupProgress -Message 'Preparing the local ChatGPT session...'
                $attachExistingSession = $desktopUpdateAttachOnly -or @(Get-StartupChatGPTMainProcesses).Count -gt 0
                if (-not $attachExistingSession) { Write-CommandOutput @(& $node --no-warnings $maintenanceHelper --best-effort --startup 2>&1) }
                $maintenanceTimer.Stop()
                Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=maintenance durationMs=$($maintenanceTimer.ElapsedMilliseconds)"
                # The VS Code extension and other Codex clients run a codex.exe
                # app-server process. It is not the desktop Electron app and
                # must not block or be terminated by a ChatGPT Custom launch.
                $appProcesses = @(Get-StartupChatGPTMainProcesses)
                $attachExistingSession = $desktopUpdateAttachOnly -or $appProcesses.Count -gt 0
                $debugApp = @($appProcesses | Where-Object { $_.CommandLine -match '--remote-debugging-port(?:=|\s)' })
                if ($UpdateResume -and $appProcesses.Count -gt 0) {
                    throw 'Another ChatGPT/Codex process appeared during the update. The verified relaunch was aborted without closing or replacing it.'
                }
                if ($debugApp.Count -ne 0) {
                    Write-StartupLog "$(Get-Date -Format o) [$computerName] existing debug session found; validating its durable proxy transport before reuse"
                }
                $stableTimer = [Diagnostics.Stopwatch]::StartNew()
                Set-StartupProgress -Message $(if ($attachExistingSession) { 'Attaching to the running ChatGPT session...' } else { 'Launching ChatGPT with Remote enabled...' })
                for ($stableAttempt = 1; $stableAttempt -le 2; $stableAttempt++) {
                    try {
                        $attachExistingSession = if ($desktopUpdateAttachOnly) { $true } else { @(Get-StartupChatGPTMainProcesses).Count -gt 0 }
                        if ($UpdateResume -and $attachExistingSession) {
                            throw 'Another ChatGPT/Codex process appeared during the update. The verified relaunch was aborted without closing or replacing it.'
                        }
                        $stableArguments = @{
                            Action = 'Enable'
                            UseProxy = [bool]$UseProxy
                            RefuseExistingApp = $true
                            TimeoutSeconds = [Math]::Min(60, [Math]::Max(20, $MobileReadyTimeoutSeconds))
                            Confirm = $false
                        }
                        $supportsAttachOnly = Test-RemoteScriptSupportsParameter -ScriptPath $stableController -ParameterName 'AttachOnly'
                        if ($supportsAttachOnly) {
                            $stableArguments.AttachOnly = [bool]$attachExistingSession
                        } elseif ($attachExistingSession) {
                            throw 'The installed Remote Enabler controller cannot safely attach to the running ChatGPT session; it does not support AttachOnly and the app was left running.'
                        }
                        if ($UseProxy) { $stableArguments.ProxyServer = $proxyServer }
                        Write-CommandOutput @(& $stableController @stableArguments 2>&1)
                        break
                    } catch {
                        $stableError = $_.Exception.Message
                        if ($stableAttempt -ge 2 -or $UpdateResume -or $stableError -like 'ChatGPT is already open, but a matching Remote Enabler session*' -or $stableError -like 'Runtime inspector hook unavailable:*') {
                            Write-StartupLog "$(Get-Date -Format o) [$computerName] stable bridge failed on attempt ${stableAttempt}: $stableError"
                            throw
                        }
                        Write-StartupLog "$(Get-Date -Format o) [$computerName] stable bridge failed on attempt ${stableAttempt}: $stableError; retrying once"
                        Start-Sleep -Seconds 2
                    }
                }
                $stableTimer.Stop()
                Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=stable-runtime durationMs=$($stableTimer.ElapsedMilliseconds)"
                $mobileTimer = [Diagnostics.Stopwatch]::StartNew()
                Set-StartupProgress -Message 'Loading Device projects and remote connections...'
                $targetWaitMilliseconds = [Math]::Min(30000, $MobileReadyTimeoutSeconds * 1000)
                Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=mobile-target-discovery configuredReadinessTimeoutSeconds=$MobileReadyTimeoutSeconds requestedTargetWaitMs=$targetWaitMilliseconds effectiveEnableTargetWaitMs=30000"
                $enableOutput = @(& $mobileController -Action Enable -NodePath $node -TargetWaitMilliseconds $targetWaitMilliseconds -DeferUpdateSession -Confirm:$false 2>&1)
                Write-CommandOutput $enableOutput
                $report = Get-MobileReport -Output $enableOutput
                Start-MobileBackgroundServices -NodePath $node
                $report = Wait-MobileReadiness -Report $report -TimeoutSeconds $MobileReadyTimeoutSeconds -Probe {
                    $probeOutput = @(& $mobileController -Action Probe -NodePath $node 2>&1)
                    Write-CommandOutput $probeOutput
                    $probeOutput
                }
                $mobileTimer.Stop()
                Write-StartupLog "$(Get-Date -Format o) [$computerName] stage=mobile-readiness durationMs=$($mobileTimer.ElapsedMilliseconds) mounted=$($report.mounted) localRuntimeReady=$($report.localRuntimeReady) authoritativeInventoryReady=$($report.authoritativeInventoryReady) publisherReady=$($report.publisherReady) ready=$($report.ready)"
                Stop-StartupProgress
                Write-StartupLog "$(Get-Date -Format o) [$computerName] interactive startup completed"
                Write-RelaunchHandoff
                Write-StartupLog "$(Get-Date -Format o) [$computerName] startup run completed"
            } catch {
                Write-StartupLog "$(Get-Date -Format o) [$computerName] startup run failed: $($_.Exception.Message)"
                if ($handshakeReady) {
                    Stop-StartupProgress
                    Show-StartupFailure -Message $_.Exception.Message
                }
                throw
            }
        } catch {
            if (-not $handshakeReady) {
                Signal-Handshake -Rejected
                Write-StartupLog "$(Get-Date -Format o) [$computerName] startup handoff failed: $($_.Exception.Message)"
            }
            throw
        } finally {
            Stop-StartupProgress
            if ($parentProcess) { $parentProcess.Dispose() }
            if ($readyEvent) { $readyEvent.Dispose() }
            if ($rejectedEvent) { $rejectedEvent.Dispose() }
            if ($acquired) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    'Install' {
        Assert-Administrator
        Assert-Controllers
        if (-not $TargetUser) {
            $TargetUser = (Get-CimInstance Win32_ComputerSystem).UserName
            if (-not $TargetUser) { $TargetUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        }
        if ($TargetUser -notmatch '^[^\\]+\\[^\\]+$') { throw 'TargetUser must use DOMAIN\user form.' }
        New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = Join-Path $rollbackRoot "startup-task-$computerName-$stamp.xml"
            Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath $backupPath -Encoding Unicode
        }
        $startupLauncher = Join-Path $bundleRoot 'ChatGPT Custom.exe'
        if (-not (Test-Path -LiteralPath $startupLauncher -PathType Leaf)) {
            throw "The windowless startup launcher was not found: $startupLauncher"
        }
        $arguments = if ($UseProxy) { '--proxy --startup' } else { '--startup' }
        $taskAction = New-ScheduledTaskAction -Execute $startupLauncher -Argument $arguments -WorkingDirectory $bundleRoot
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser
        if ($DelaySeconds -gt 0) { $trigger.Delay = "PT${DelaySeconds}S" }
        $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        if ($PSCmdlet.ShouldProcess("$computerName scheduled task '$taskName'", "register for $TargetUser")) {
            Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'Starts the capability-tested Codex remote controller and mobile project view after interactive logon.' -Force | Out-Null
        }
        Get-TaskSummary | ConvertTo-Json -Depth 4
    }
    'Remove' {
        Assert-Administrator
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing -and $PSCmdlet.ShouldProcess("$computerName scheduled task '$taskName'", 'unregister')) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        Get-TaskSummary | ConvertTo-Json -Depth 4
    }
    'RepairPublisher' {
        if ([string]::IsNullOrWhiteSpace($NodePath) -or -not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
            throw 'RepairPublisher requires the exact Node.js executable path.'
        }
        if ([string]::IsNullOrWhiteSpace($LegacyPublisherScriptPath)) {
            throw 'RepairPublisher requires the exact invoking package publisher path.'
        }
        Invoke-PublisherRepair -NodePath $NodePath -TrustedLegacyPublisherScriptPath $LegacyPublisherScriptPath
    }
    'Probe' {
        Get-TaskSummary | ConvertTo-Json -Depth 4
    }
}
