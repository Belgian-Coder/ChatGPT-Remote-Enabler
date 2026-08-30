[CmdletBinding()]
param(
    [switch]$SkipMobileProjects,
    [switch]$SkipUpdate,
    [int]$ParentProcessId = 0,
    [long]$ParentProcessStartTimeFileTimeUtc = 0,
    [string]$ReadyEventName,
    [string]$RejectedEventName
)

$ErrorActionPreference = 'Stop'
$stable = Join-Path $PSScriptRoot 'CodexRemoteSimple\CodexRemoteSimple.ps1'
$mobile = Join-Path $PSScriptRoot 'CodexRemoteMobileProject\MobileProjectView.ps1'
$updater = Join-Path $PSScriptRoot 'Update-ChatGPTRemote.ps1'
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

    if (-not $SkipUpdate -and (Test-Path -LiteralPath $updater -PathType Leaf)) {
        try { & $updater -Action Auto | Write-Verbose }
        catch {
            Write-RemoteLauncherLog "$(Get-Date -Format o) [$($env:COMPUTERNAME)] automatic update skipped: $($_.Exception.Message)"
            Write-Warning "Automatic update skipped: $($_.Exception.Message)"
        }
    }

    & $stable -Action Enable -Confirm:$false
    if (-not $SkipMobileProjects) {
        & $mobile -Action Enable -Confirm:$false
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
