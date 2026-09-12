[CmdletBinding()]
param(
    [switch]$SkipMobileProjects,
    [switch]$SkipUpdate,
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
    [string]$RejectedEventName
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
$stable = Join-Path $PSScriptRoot 'CodexRemoteSimple\CodexRemoteSimple.ps1'
$mobile = Join-Path $PSScriptRoot 'CodexRemoteMobileProject\MobileProjectView.ps1'
$desktopAppUpdater = Join-Path $PSScriptRoot 'Update-ChatGPTDesktop.ps1'
$updater = Join-Path $PSScriptRoot 'Update-ChatGPTRemote.ps1'
$updateSessionLauncher = Join-Path $PSScriptRoot 'CodexRemoteMobileProject\UpdateSessionLauncher.ps1'
$logRoot = Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures'
$logPath = Join-Path $logRoot 'startup.log'
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

function Write-RemoteLauncherLog {
    param([AllowEmptyString()][string]$Message)
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    [IO.File]::AppendAllText($logPath, "$Message$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
}

function Get-RemoteMobileReport {
    param([object[]]$Output)
    for ($index = $Output.Count - 1; $index -ge 0; $index--) {
        try {
            $value = [string]$Output[$index] | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $value.report) {
                if ($null -ne $value.report.readiness) { return $value.report.readiness }
                return $value.report
            }
        } catch {
            # Progress may precede the final JSON proof.
        }
    }
    throw 'The mobile project view did not return JSON readiness proof.'
}

function Assert-RemoteMobileReport {
    param($Report)
    if ($null -eq $Report -or $Report.mounted -isnot [bool] -or
        $Report.localRuntimeReady -isnot [bool] -or
        $Report.authoritativeInventoryReady -isnot [bool] -or
        $Report.publisherReady -isnot [bool] -or
        $Report.ready -isnot [bool]) {
        throw 'The mobile project view returned incomplete readiness proof.'
    }
}

function Get-RemoteMobileReadinessTimeoutMessage {
    param($Report, [int]$TimeoutSeconds)
    $message = "The mobile project view did not become ready within $TimeoutSeconds seconds (mounted=$($Report.mounted), localRuntimeReady=$($Report.localRuntimeReady), authoritativeInventoryReady=$($Report.authoritativeInventoryReady), publisherReady=$($Report.publisherReady), ready=$($Report.ready))."
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.error)) {
        $message += " Last readiness error: $($Report.error)"
    }
    return $message
}

function Write-RemoteRelaunchHandoff {
    if ([string]::IsNullOrWhiteSpace($RelaunchHandoffPath)) { return }
    $resolved = [IO.Path]::GetFullPath($RelaunchHandoffPath)
    $allowedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update-sessions\sessions')).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -ne 'relaunch-handoff.json') {
        throw 'The relaunch handoff path is outside the per-user update-session state.'
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resolved) -Force | Out-Null
    $temporary = "$resolved.tmp"
    $handoff = [ordered]@{ ready = $true; entryPointRelative = 'Enable-ChatGPTRemote.ps1'; at = [DateTime]::UtcNow.ToString('o') }
    [IO.File]::WriteAllText($temporary, (($handoff | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $resolved -Force
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
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] handshake signal failed: $($_.Exception.Message)"
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

function Show-RemoteLauncherFailure {
    param([string]$Message)
    try {
        if (-not ('ChatGPTRemoteLauncherMessage' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ChatGPTRemoteLauncherMessage {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int MessageBox(IntPtr window, string text, string caption, uint type);
}
'@
        }
        [void][ChatGPTRemoteLauncherMessage]::MessageBox(
            [IntPtr]::Zero,
            "ChatGPT Remote Enabler could not complete.`r`n`r`n$Message`r`n`r`nDetails: $logPath",
            'ChatGPT Remote Enabler',
            0x10)
    } catch {
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] failure dialog could not be shown"
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
    $processes = if ($ProcessEnumerator) { @(& $ProcessEnumerator) } else { @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue) }
    if ($processes.Count -gt 0) {
        throw 'ChatGPT.exe is running. Finish active work and close it, then retry. The launch updater will not stop or kill the app.'
    }
}

function Invoke-DesktopAppPrelaunchUpdate {
    param([string]$UpdaterPath, [scriptblock]$ProcessEnumerator)

    if (-not (Test-Path -LiteralPath $UpdaterPath -PathType Leaf)) {
        throw "The signed ChatGPT desktop updater is missing: $UpdaterPath"
    }
    Assert-DesktopAppNotRunning -ProcessEnumerator $ProcessEnumerator
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) {
        throw "Built-in Windows PowerShell was not found: $powerShell"
    }
    $output = @(& $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $UpdaterPath -Action Update 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) { Write-RemoteLauncherLog ([string]$line) }
    if ($exitCode -ne 0) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join ' '
        throw "The signed ChatGPT desktop update failed before launch (exit $exitCode): $detail"
    }
    $result = Get-CompleteJsonResult -Output $output
    if ([string]$result.Action -cne 'Update' -or [string]$result.InstalledState -cne 'Installed' -or
        $null -eq $result.Installed -or [string]$result.Installed.Name -cnotin @('OpenAI.Codex', 'OpenAI.ChatGPT-Desktop') -or
        [string]$result.Remote.Name -cne [string]$result.Installed.Name -or
        [string]$result.Installed.Publisher -cne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -or
        [string]$result.Installed.Architecture -ine 'X64') {
        throw 'The signed ChatGPT desktop updater did not prove one supported installed package.'
    }
    try {
        $installedVersion = [version]([string]$result.Installed.Version)
        $remoteVersion = [version]([string]$result.Remote.Version)
    } catch {
        throw 'The signed ChatGPT desktop updater returned invalid package-version proof.'
    }
    switch ([string]$result.Decision) {
        'Installed' {
            if ($result.CanInstall -isnot [bool] -or -not $result.CanInstall -or $installedVersion -ne $remoteVersion -or
                $null -eq $result.Manifest -or [string]$result.Manifest.Name -cne [string]$result.Installed.Name -or
                [version]([string]$result.Manifest.Version) -ne $installedVersion) {
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
        default { throw "The signed ChatGPT desktop updater returned a non-launchable decision: $($result.Decision)" }
    }
    Assert-DesktopAppNotRunning -ProcessEnumerator $ProcessEnumerator
    $timer.Stop()
    Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=desktop-app-update durationMs=$($timer.ElapsedMilliseconds) decision=$($result.Decision) installedVersion=$installedVersion remoteVersion=$remoteVersion"
    return $result
}

function Invoke-UpdateRecovery {
    param([string]$UpdaterPath, [string]$InstallRoot)

    if (-not (Test-Path -LiteralPath $UpdaterPath -PathType Leaf)) {
        throw "The Remote Enabler updater is missing: $UpdaterPath"
    }
    $previousLaunchGuard = [Environment]::GetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', '1', 'Process')
        $LASTEXITCODE = 0
        $output = @(& $UpdaterPath -Action Recover -InstallRoot $InstallRoot -LaunchLockHeld 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', $previousLaunchGuard, 'Process')
    }
    foreach ($line in $output) { Write-RemoteLauncherLog ([string]$line) }
    if ($exitCode -ne 0) { throw 'Update recovery failed before launch.' }
    $recovery = Get-LastJsonResult -Output $output
    if ($recovery.recovered -isnot [bool] -or $recovery.integrityValid -isnot [bool] -or -not $recovery.integrityValid -or
        [string]$recovery.version -notmatch '^v\d+\.\d+\.\d+$') {
        throw 'Update recovery did not prove installed-file integrity before launch.'
    }
    if ($recovery.recovered -and [string]$recovery.recoveryMode -notin @('complete-forward', 'rollback', 'unchanged')) {
        throw 'Update recovery returned an unsupported recovery mode.'
    }
    return $recovery
}

function Invoke-PrelaunchUpdate {
    param([string]$UpdaterPath, [string]$InstallRoot)

    if (-not (Test-Path -LiteralPath $UpdaterPath -PathType Leaf)) {
        throw "The Remote Enabler updater is missing: $UpdaterPath"
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $updateError = $null
    $previousLaunchGuard = [Environment]::GetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', '1', 'Process')
        $LASTEXITCODE = 0
        $output = @(& $UpdaterPath -Action Update -Transport Git -InstallRoot $InstallRoot -LaunchLockHeld 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $exitCode = 1
        $output = @()
        $updateError = $_.Exception.Message
    } finally {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', $previousLaunchGuard, 'Process')
    }
    foreach ($line in $output) { Write-RemoteLauncherLog ([string]$line) }
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
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=prelaunch-update durationMs=$($timer.ElapsedMilliseconds) updated=$($result.updated) method=$($result.method)"
        return $result
    }

    try {
        [void](Invoke-UpdateRecovery -UpdaterPath $UpdaterPath -InstallRoot $InstallRoot)
    } catch {
        throw "Prelaunch update failed and recovery could not prove installed-file integrity: $updateError; $($_.Exception.Message)"
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
    $child = Start-Process -FilePath $powerShell -ArgumentList $childArgumentString -WorkingDirectory (Split-Path -Parent $EntryPoint) -WindowStyle Hidden -PassThru
    $child.Dispose()
    Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] prelaunch update installed a new helper; reloading updated entry point"
}

function Wait-ForContinuationParent {
    if ($ContinuationParentProcessId -le 0) { return }
    if ($ContinuationParentProcessStartTimeFileTimeUtc -le 0) {
        throw 'The updated entry point continuation is missing the parent process start time.'
    }
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ContinuationParentProcessId)
        $actual = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
        if ($actual -ne $ContinuationParentProcessStartTimeFileTimeUtc) {
            throw "Continuation parent $ContinuationParentProcessId did not match the captured start time."
        }
        if (-not $process.WaitForExit(30000)) {
            throw "Continuation parent $ContinuationParentProcessId did not exit before the updated launch timeout."
        }
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] updated entry point continuation parent exited; acquiring launch mutex"
    } catch {
        throw "The updated entry point continuation could not wait for its parent: $($_.Exception.Message)"
    } finally {
        if ($process) { $process.Dispose() }
    }
}

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
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] recovered an abandoned launcher mutex"
    }
    if (-not $acquired) {
        Signal-Handshake -Rejected
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] launch rejected because another entry owns the mutex"
        throw 'Another ChatGPT Custom or ChatGPT Remote Enabler launch is still running.'
    }
    if ($handshakeRequested) {
        $parentProcess = Capture-ExactParent
        Signal-Handshake
        $handshakeReady = $true
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] launcher handoff accepted; waiting for parent $ParentProcessId to exit"
        if (-not $parentProcess.WaitForExit(30000)) {
            throw "Launcher parent $ParentProcessId did not exit after accepting the handoff."
        }
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] launcher parent exited; continuing update and launch"
    }
    $recoverTimer = [Diagnostics.Stopwatch]::StartNew()
    $recovery = Invoke-UpdateRecovery -UpdaterPath $updater -InstallRoot $PSScriptRoot
    $recoverTimer.Stop()
    Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=update-recovery durationMs=$($recoverTimer.ElapsedMilliseconds) recovered=$($recovery.recovered) mode=$($recovery.recoveryMode)"
    if ($recovery.recovered -and [string]$recovery.recoveryMode -cne 'rollback') {
        if ($RecoveryContinuation) {
            throw 'Update recovery changed installed files again after an exact recovery continuation; launch aborted to prevent a reload loop.'
        }
        $recoveryArguments = @('-RecoveryContinuation')
        if ($handshakeReady) { $recoveryArguments += '-ContinuationAfterAcceptedHandshake' }
        if ($SkipMobileProjects) { $recoveryArguments += '-SkipMobileProjects' }
        if ($SkipUpdate) { $recoveryArguments += '-SkipUpdate' }
        if ($UpdateResume) { $recoveryArguments += @('-UpdateResume', '-SkipDesktopAppUpdateOnce', '-SkipUpdateCheckOnce') }
        if ($RelaunchHandoffPath) { $recoveryArguments += @('-RelaunchHandoffPath', $RelaunchHandoffPath) }
        Start-UpdatedEntryPoint -EntryPoint $PSCommandPath -Arguments $recoveryArguments
        return
    }
    if ($recovery.recovered) {
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] rollback recovery restored an older compatible entry point; current coordinator will complete the ordered update gates"
    }

    $desktopUpdateExecuted = $false
    if (-not $SkipDesktopAppUpdateOnce -and -not $UpdateResume) {
        [void](Invoke-DesktopAppPrelaunchUpdate -UpdaterPath $desktopAppUpdater)
        $desktopUpdateExecuted = $true
    }

    $skipRemotePrelaunch = [bool]$SkipPrelaunchUpdateOnce
    if ($desktopUpdateExecuted -and $ContinuationAfterAcceptedHandshake -and $SkipPrelaunchUpdateOnce -and -not $SkipDesktopAppUpdateOnce) {
        $skipRemotePrelaunch = $false
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] legacy helper handoff detected; verifying Remote Enabler again after the desktop-app update"
    }
    if (-not $SkipUpdate -and -not $SkipUpdateCheckOnce -and -not $UpdateResume -and -not $skipRemotePrelaunch) {
        $prelaunchUpdate = Invoke-PrelaunchUpdate -UpdaterPath $updater -InstallRoot $PSScriptRoot
        if ($prelaunchUpdate.updated) {
            $reloadArguments = @('-SkipDesktopAppUpdateOnce', '-SkipPrelaunchUpdateOnce')
            if ($handshakeReady) { $reloadArguments += '-ContinuationAfterAcceptedHandshake' }
            if ($SkipMobileProjects) { $reloadArguments += '-SkipMobileProjects' }
            if ($SkipUpdate) { $reloadArguments += '-SkipUpdate' }
            if ($SkipUpdateCheckOnce) { $reloadArguments += '-SkipUpdateCheckOnce' }
            if ($UpdateResume) { $reloadArguments += '-UpdateResume' }
            if ($RelaunchHandoffPath) { $reloadArguments += @('-RelaunchHandoffPath', $RelaunchHandoffPath) }
            Start-UpdatedEntryPoint -EntryPoint $PSCommandPath -Arguments $reloadArguments
            return
        }
    }

    if ($UpdateResume -and @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Another ChatGPT/Codex process appeared during the update. The verified relaunch was aborted without closing or replacing it.'
    }
    $stableTimer = [Diagnostics.Stopwatch]::StartNew()
    & $stable -Action Enable -RefuseExistingApp:$UpdateResume -Confirm:$false
    $stableTimer.Stop()
    Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=stable-runtime durationMs=$($stableTimer.ElapsedMilliseconds)"
    if (-not $SkipMobileProjects) {
        $mobileTimer = [Diagnostics.Stopwatch]::StartNew()
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        $enableOutput = @(& $mobile -Action Enable -DeferUpdateSession -Confirm:$false 2>&1)
        $enableOutput | ForEach-Object { Write-Host $_ }
        $report = Get-RemoteMobileReport -Output $enableOutput
        Assert-RemoteMobileReport -Report $report
        while (-not $report.ready) {
            if ([DateTime]::UtcNow -ge $deadline) { throw (Get-RemoteMobileReadinessTimeoutMessage -Report $report -TimeoutSeconds 45) }
            Start-Sleep -Milliseconds 500
            $probeOutput = @(& $mobile -Action Probe 2>&1)
            $report = Get-RemoteMobileReport -Output $probeOutput
            Assert-RemoteMobileReport -Report $report
        }
        $mobileTimer.Stop()
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=mobile-readiness durationMs=$($mobileTimer.ElapsedMilliseconds) mounted=$($report.mounted) localRuntimeReady=$($report.localRuntimeReady) authoritativeInventoryReady=$($report.authoritativeInventoryReady) publisherReady=$($report.publisherReady) ready=$($report.ready)"
        try {
            $sessionTimer = [Diagnostics.Stopwatch]::StartNew()
            $sessionArguments = @{
                InstallRoot = $PSScriptRoot
                EntryPointRelative = 'Enable-ChatGPTRemote.ps1'
                SkipInitialCheck = [bool]($SkipUpdate -or $SkipUpdateCheckOnce)
            }
            & $updateSessionLauncher @sessionArguments | ForEach-Object { Write-RemoteLauncherLog ([string]$_) }
            $sessionTimer.Stop()
            Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=update-session durationMs=$($sessionTimer.ElapsedMilliseconds)"
        } catch {
            Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] update-session launch unavailable: $($_.Exception.Message)"
        }
        Write-RemoteRelaunchHandoff
    }

    Write-Host 'ChatGPT Remote is enabled for this special session.' -ForegroundColor Green
    Write-Host 'Use Disable-ChatGPTRemote.ps1 to return to the normal app.'
} catch {
    if (-not $handshakeReady) {
        Signal-Handshake -Rejected
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] launcher handoff failed: $($_.Exception.Message)"
    } else {
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] launcher worker failed: $($_.Exception.Message)"
        Show-RemoteLauncherFailure -Message $_.Exception.Message
    }
    throw
} finally {
    if ($parentProcess) { $parentProcess.Dispose() }
    if ($readyEvent) { $readyEvent.Dispose() }
    if ($rejectedEvent) { $rejectedEvent.Dispose() }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
