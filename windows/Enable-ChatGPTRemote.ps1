[CmdletBinding()]
param(
    [switch]$SkipMobileProjects,
    [switch]$SkipUpdate,
    [switch]$SkipUpdateCheckOnce,
    [switch]$UpdateResume,
    [string]$RelaunchHandoffPath,
    [int]$ParentProcessId = 0,
    [long]$ParentProcessStartTimeFileTimeUtc = 0,
    [string]$ReadyEventName,
    [string]$RejectedEventName
)

$ErrorActionPreference = 'Stop'
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
$handshakeReady = $false

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
            if ($null -ne $value.report) { return $value.report }
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
    if (-not [string]::IsNullOrWhiteSpace([string]$Report.error)) {
        throw "The mobile project view reported a terminal readiness error: $($Report.error)"
    }
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

$mutex = [Threading.Mutex]::new($false, $launcherMutexName)
$acquired = $false
$parentProcess = $null
try {
    if ($handshakeRequested) {
        Assert-HandshakeParameters
        $readyEvent = [Threading.EventWaitHandle]::OpenExisting($ReadyEventName)
        $rejectedEvent = [Threading.EventWaitHandle]::OpenExisting($RejectedEventName)
    }
    try {
        $acquired = $mutex.WaitOne(0)
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
        $previousLaunchGuard = [Environment]::GetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', '1', 'Process')
            $recoverOutput = @(& $updater -Action Recover -InstallRoot $PSScriptRoot -LaunchLockHeld 2>&1)
        } finally {
            [Environment]::SetEnvironmentVariable('CHATGPT_REMOTE_LAUNCH_GUARD_HELD', $previousLaunchGuard, 'Process')
        }
        $recoverTimer.Stop()
        foreach ($line in $recoverOutput) { Write-RemoteLauncherLog ([string]$line) }
        if ($LASTEXITCODE -ne 0) { throw 'Update recovery failed before launch.' }
        $recover = [string]$recoverOutput[-1] | ConvertFrom-Json -ErrorAction Stop
        if ($recover.integrityValid -isnot [bool] -or -not $recover.integrityValid) {
            throw 'Update recovery did not prove installed-file integrity before launch.'
        }
        Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] stage=update-recovery durationMs=$($recoverTimer.ElapsedMilliseconds)"
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
            if ([DateTime]::UtcNow -ge $deadline) { throw 'The mobile project view did not become ready within 45 seconds.' }
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
