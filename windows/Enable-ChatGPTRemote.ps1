[CmdletBinding()]
param(
    [switch]$SkipMobileProjects,
    [switch]$SkipUpdate,
    [switch]$SkipUpdateCheckOnce,
    [switch]$SkipPrelaunchUpdateOnce,
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
    for ($index = $Output.Count - 1; $index -ge 0; $index--) {
        try {
            return ([string]$Output[$index] | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            # Human-readable updater progress may precede the final JSON proof.
        }
    }
    throw 'The updater did not return JSON proof.'
}

function Invoke-UpdateRecovery {
    param([string]$UpdaterPath, [string]$InstallRoot)

    $previousLaunchGuard = [Environment]::GetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', '1', 'Process')
        $output = @(& $UpdaterPath -Action Recover -InstallRoot $InstallRoot -LaunchLockHeld 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', $previousLaunchGuard, 'Process')
    }
    foreach ($line in $output) { Write-RemoteLauncherLog ([string]$line) }
    if ($exitCode -ne 0) { throw 'Update recovery failed before launch.' }
    $recovery = Get-LastJsonResult -Output $output
    if ($recovery.integrityValid -isnot [bool] -or -not $recovery.integrityValid) {
        throw 'Update recovery did not prove installed-file integrity before launch.'
    }
    return $recovery
}

function Invoke-PrelaunchUpdate {
    param([string]$UpdaterPath, [string]$InstallRoot)

    if (-not (Test-Path -LiteralPath $UpdaterPath -PathType Leaf)) {
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=prelaunch-update skipped reason=updater-missing"
        return [pscustomobject]@{ attempted = $false; updated = $false; failed = $false }
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $updateError = $null
    $previousLaunchGuard = [Environment]::GetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', '1', 'Process')
        $output = @(& $UpdaterPath -Action Auto -Transport Git -InstallRoot $InstallRoot -LaunchLockHeld 2>&1)
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
            if ($result.skipped -is [bool] -and $result.skipped) {
                if ([string]$result.reason -notin @('auto-update-disabled', 'check-interval')) {
                    throw "The prelaunch updater returned an unknown skip reason: $($result.reason)."
                }
                $result | Add-Member -NotePropertyName updated -NotePropertyValue $false
            } elseif ($result.updated -isnot [bool]) {
                throw 'The prelaunch updater returned incomplete update proof.'
            }
            if ($result.updated -and [string]$result.method -notin @('verified-git', 'git-fast-forward')) {
                throw 'The prelaunch updater did not prove a Git-backed update.'
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

    # Network/Git discovery failures remain best effort, but a transaction
    # failure is safe to ignore only after recovery proves the install intact.
    try {
        [void](Invoke-UpdateRecovery -UpdaterPath $UpdaterPath -InstallRoot $InstallRoot)
    } catch {
        throw "Prelaunch update failed and recovery could not prove installed-file integrity: $updateError; $($_.Exception.Message)"
    }
    Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=prelaunch-update durationMs=$($timer.ElapsedMilliseconds) updated=False bestEffortFailure=$updateError"
    return [pscustomobject]@{ attempted = $true; updated = $false; failed = $true; error = $updateError }
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
    if (Test-Path -LiteralPath $updater -PathType Leaf) {
        $recoverTimer = [Diagnostics.Stopwatch]::StartNew()
        [void](Invoke-UpdateRecovery -UpdaterPath $updater -InstallRoot $PSScriptRoot)
        $recoverTimer.Stop()
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=update-recovery durationMs=$($recoverTimer.ElapsedMilliseconds)"
    }

    if (-not $SkipUpdate -and -not $SkipUpdateCheckOnce -and -not $UpdateResume -and -not $SkipPrelaunchUpdateOnce) {
        $prelaunchUpdate = Invoke-PrelaunchUpdate -UpdaterPath $updater -InstallRoot $PSScriptRoot
        if ($prelaunchUpdate.updated) {
            $reloadArguments = @('-SkipPrelaunchUpdateOnce')
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
