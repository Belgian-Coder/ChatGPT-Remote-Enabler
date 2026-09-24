[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [Parameter(Mandatory)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$CoordinatorProcessId,
    [Parameter(Mandatory)]
    [ValidateRange(1, [long]::MaxValue)]
    [long]$CoordinatorStartTimeFileTimeUtc,
    [Parameter(Mandatory)]
    [string]$CoordinatorExecutablePath,
    [ValidateRange(1, 30)]
    [int]$GuardTimeoutSeconds = 5,
    [ValidateRange(100, 10000)]
    [int]$ProofIntervalMilliseconds = 500,
    [switch]$ImportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepairNormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'A coordinator-repair path is not absolute.' }
    return [IO.Path]::GetFullPath($Path)
}

function Test-RepairPlainFile {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return -not $item.PSIsContainer -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
    } catch { return $false }
}

function Get-RepairFileText {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-RepairPlainFile $Path)) { throw "A coordinator-repair proof file is unavailable: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -le 0 -or $item.Length -gt 1MB) { throw "A coordinator-repair proof file has an unsafe size: $Path" }
    return [IO.File]::ReadAllText($Path)
}

function Get-RepairJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-RepairPlainFile $Path)) { throw "A coordinator-repair JSON file is unavailable: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -le 0 -or $item.Length -gt 1MB) { throw "A coordinator-repair JSON file has an unsafe size: $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
}

function Get-RepairHistoryEvidence {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{ Exists = $false; Text = $null; Entries = @() }
    }
    $text = Get-RepairFileText $Path
    $trimmed = $text.Trim()
    if (-not $trimmed.StartsWith('[', [StringComparison]::Ordinal) -or
        -not $trimmed.EndsWith(']', [StringComparison]::Ordinal)) {
        throw 'The legacy coordinator history is not a JSON array.'
    }
    $entries = @($text | ConvertFrom-Json -ErrorAction Stop)
    return [pscustomobject][ordered]@{ Exists = $true; Text = $text; Entries = $entries }
}

function Get-RepairProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-RepairExactProcess {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][long]$StartTimeFileTimeUtc,
        [Parameter(Mandatory)][string]$ExecutablePath
    )
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        return $process.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $StartTimeFileTimeUtc -and
            [string]::Equals((Get-RepairNormalizedPath $process.MainModule.FileName), (Get-RepairNormalizedPath $ExecutablePath), [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
    finally { if ($process) { $process.Dispose() } }
}

function Test-RepairCoordinatorCommandLine {
    param([Parameter(Mandatory)][string]$CommandLine, [Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$ConfigPath)
    $tokens = @([regex]::Matches($CommandLine, '"([^"]*)"|([^\s]+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value }
    })
    $script = Get-RepairNormalizedPath $ScriptPath
    $config = Get-RepairNormalizedPath $ConfigPath
    if (@($tokens | Where-Object { [string]::Equals([string]$_, $script, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { return $false }
    for ($index = 0; $index -lt $tokens.Count - 1; $index += 1) {
        if ([string]::Equals([string]$tokens[$index], '--config', [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$tokens[$index + 1], $config, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-RepairDescendantProcessIds {
    param([Parameter(Mandatory)][int]$ProcessId)
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId,ParentProcessId)
    $parents = [Collections.Generic.HashSet[int]]::new()
    [void]$parents.Add($ProcessId)
    $descendants = [Collections.Generic.HashSet[int]]::new()
    do {
        $added = $false
        foreach ($process in $processes) {
            $pidValue = [int]$process.ProcessId
            if ($pidValue -le 0 -or $descendants.Contains($pidValue)) { continue }
            if ($parents.Contains([int]$process.ParentProcessId)) {
                [void]$descendants.Add($pidValue)
                [void]$parents.Add($pidValue)
                $added = $true
            }
        }
    } while ($added)
    return @($descendants | Sort-Object)
}

function Get-RepairSnapshot {
    param([Parameter(Mandatory)]$Context)
    $configText = Get-RepairFileText $Context.ConfigPath
    $lockText = Get-RepairFileText $Context.LockPath
    $historyEvidence = Get-RepairHistoryEvidence $Context.HistoryPath
    $config = $configText | ConvertFrom-Json -ErrorAction Stop
    $state = Get-RepairJson $Context.StatePath
    $owner = $lockText | ConvertFrom-Json -ErrorAction Stop
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($Context.CoordinatorProcessId)" -ErrorAction Stop
    return [pscustomobject][ordered]@{
        CapturedAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Config = $config
        ConfigText = $configText
        State = $state
        LockOwner = $owner
        LockText = $lockText
        History = @($historyEvidence.Entries | ForEach-Object { $_ })
        HistoryExists = [bool]$historyEvidence.Exists
        HistoryText = $historyEvidence.Text
        CommandLine = [string]$process.CommandLine
        DescendantProcessIds = @(Get-RepairDescendantProcessIds $Context.CoordinatorProcessId)
    }
}

function Assert-RepairSnapshot {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Snapshot,
        $Baseline = $null
    )
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $config = $Snapshot.Config
    $state = $Snapshot.State
    $owner = $Snapshot.LockOwner
    if ($null -eq $config -or $null -eq $state -or $null -eq $owner) { throw 'Coordinator repair evidence is incomplete.' }
    if (-not [string]::Equals((Get-RepairNormalizedPath ([string]$config.sessionDirectory)), $Context.SessionDirectory, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-RepairNormalizedPath ([string]$config.stateRoot)), $Context.SessionStateRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The coordinator session ownership changed.'
    }
    if ([int]$config.app.pid -ne $Context.AppProcessId -or
        [long]$config.app.startTimeFileTimeUtc -ne $Context.AppStartTimeFileTimeUtc -or
        -not [string]::Equals((Get-RepairNormalizedPath ([string]$config.app.executablePath)), $Context.AppExecutablePath, [StringComparison]::OrdinalIgnoreCase) -or
        [int]$config.rendererPort -ne $Context.RendererPort) {
        throw 'The exact ChatGPT identity or renderer port changed.'
    }
    if ([string]$state.phase -cne 'active' -or [string]$state.sessionId -cne ([IO.Path]::GetFileName($Context.SessionDirectory)) -or
        [int]$state.coordinatorPid -ne $Context.CoordinatorProcessId -or
        [int]$state.coordinatorIdentity.pid -ne $Context.CoordinatorProcessId -or
        [string]$state.coordinatorIdentity.startToken -cne ([string]$Context.CoordinatorStartTimeFileTimeUtc) -or
        -not [string]::Equals((Get-RepairNormalizedPath ([string]$state.coordinatorIdentity.executablePath)), $Context.CoordinatorExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The legacy coordinator state identity changed.'
    }
    if ($null -ne $state.PSObject.Properties['rendererConnected'] -or $null -ne $state.PSObject.Properties['rendererProofAtUnixMs']) {
        throw 'The coordinator publishes renderer-health proof and is not eligible for legacy repair.'
    }
    $heartbeat = 0L
    if (-not [long]::TryParse([string]$state.heartbeatAtUnixMs, [ref]$heartbeat) -or $heartbeat -le 0 -or
        $heartbeat -gt $now -or ($now - $heartbeat) -gt 10000) { throw 'The legacy coordinator heartbeat is not fresh.' }
    if ([int]$owner.pid -ne $Context.CoordinatorProcessId -or
        [string]$owner.startToken -cne ([string]$Context.CoordinatorStartTimeFileTimeUtc) -or
        -not [string]::Equals((Get-RepairNormalizedPath ([string]$owner.executablePath)), $Context.CoordinatorExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The coordinator lock is not owned by the exact legacy process.'
    }
    if (-not (Test-RepairCoordinatorCommandLine -CommandLine $Snapshot.CommandLine -ScriptPath $Context.CoordinatorScriptPath -ConfigPath $Context.ConfigPath)) {
        throw 'The exact process command line is not the owned coordinator invocation.'
    }
    if (@($Snapshot.DescendantProcessIds).Count -ne 0) { throw 'The legacy coordinator still owns a child process.' }
    $observedHistoryStates = @('checked', 'current', 'available', 'unavailable')
    $mutatingHistoryStates = @('preparing', 'queued', 'updating', 'closing', 'restarting')
    $terminalHistoryStates = @('error', 'cancelled', 'hot-reload-confirmed', 'restart-confirmed')
    $knownHistoryStates = @($observedHistoryStates) + @($mutatingHistoryStates) + @($terminalHistoryStates)
    $historyEntries = @($Snapshot.History | ForEach-Object { $_ })
    $pendingMutationState = $null
    $previousHistoryAt = 0L
    foreach ($entry in $historyEntries) {
        $entryAt = 0L
        if ($null -eq $entry -or [string]$entry.state -cnotin $knownHistoryStates -or
            -not [long]::TryParse([string]$entry.at, [ref]$entryAt) -or $entryAt -le 0 -or
            $entryAt -gt $now -or $entryAt -lt $previousHistoryAt) {
            throw 'The legacy coordinator history contains an unknown, malformed, future, or out-of-order state.'
        }
        $previousHistoryAt = $entryAt
        if ([string]$entry.state -cin $mutatingHistoryStates) { $pendingMutationState = [string]$entry.state }
        elseif ([string]$entry.state -cin $terminalHistoryStates) { $pendingMutationState = $null }
        elseif ([string]$entry.state -ceq 'unavailable' -and $pendingMutationState -cin @('preparing', 'queued')) {
            $pendingMutationState = $null
        }
    }
    if ($null -ne $pendingMutationState) { throw 'The legacy coordinator history ends with an unfinished mutation.' }
    foreach ($journal in @($Context.TransactionJournalPath, $Context.GitTransactionJournalPath)) {
        if (Test-Path -LiteralPath $journal -PathType Leaf) { throw 'A pending update journal blocks coordinator repair.' }
    }
    $processTest = Get-RepairProperty $Context 'ExactProcessTest'
    $coordinatorMatches = if ($processTest -is [scriptblock]) {
        [bool](& $processTest $Context.CoordinatorProcessId $Context.CoordinatorStartTimeFileTimeUtc $Context.CoordinatorExecutablePath)
    } else {
        Test-RepairExactProcess -ProcessId $Context.CoordinatorProcessId -StartTimeFileTimeUtc $Context.CoordinatorStartTimeFileTimeUtc -ExecutablePath $Context.CoordinatorExecutablePath
    }
    if (-not $coordinatorMatches) {
        throw 'The exact legacy coordinator process changed.'
    }
    $appMatches = if ($processTest -is [scriptblock]) {
        [bool](& $processTest $Context.AppProcessId $Context.AppStartTimeFileTimeUtc $Context.AppExecutablePath)
    } else {
        Test-RepairExactProcess -ProcessId $Context.AppProcessId -StartTimeFileTimeUtc $Context.AppStartTimeFileTimeUtc -ExecutablePath $Context.AppExecutablePath
    }
    if (-not $appMatches) {
        throw 'The exact ChatGPT process changed.'
    }
    if ($null -ne $Baseline) {
        if ($Snapshot.ConfigText -cne $Baseline.ConfigText -or $Snapshot.LockText -cne $Baseline.LockText -or
            [bool]$Snapshot.HistoryExists -ne [bool]$Baseline.HistoryExists -or
            $Snapshot.HistoryText -cne $Baseline.HistoryText) {
            throw 'Coordinator configuration, lock ownership, or durable history changed during repair.'
        }
    }
    return $true
}

function Assert-RepairBridgeProof {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Proof)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($null -eq $Proof -or $Proof.publicBridgeMissing -ne $true -or $Proof.internalBridgeMissing -ne $true -or
        [int]$Proof.appProcessId -ne $Context.AppProcessId -or
        [string]$Proof.appStartTimeFileTimeUtc -cne ([string]$Context.AppStartTimeFileTimeUtc) -or
        [int]$Proof.rendererPort -ne $Context.RendererPort -or
        [int]$Proof.coordinatorProcessId -ne $Context.CoordinatorProcessId) {
        throw 'The renderer bridge failure proof is incomplete or belongs to another session.'
    }
    $sampled = 0L
    if (-not [long]::TryParse([string]$Proof.sampledAtUnixMs, [ref]$sampled) -or $sampled -le 0 -or
        $sampled -gt $now -or ($now - $sampled) -gt 10000) { throw 'The renderer bridge failure proof is stale.' }
    return $true
}

function Invoke-RepairCore {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][scriptblock]$CaptureSnapshot,
        [Parameter(Mandatory)][scriptblock]$CaptureBridgeProof,
        [Parameter(Mandatory)][scriptblock]$AcquireGuards,
        [Parameter(Mandatory)][scriptblock]$FreezeCoordinator,
        [Parameter(Mandatory)][scriptblock]$ResumeCoordinator,
        [Parameter(Mandatory)][scriptblock]$TerminateCoordinator,
        [Parameter(Mandatory)][scriptblock]$WaitCoordinatorExit,
        [Parameter(Mandatory)][scriptblock]$ReleaseGuards,
        [int]$ProofIntervalMilliseconds = 500
    )
    $baseline = & $CaptureSnapshot $Context
    [void](Assert-RepairSnapshot -Context $Context -Snapshot $baseline)
    [void](Assert-RepairBridgeProof -Context $Context -Proof (& $CaptureBridgeProof $Context))
    Start-Sleep -Milliseconds $ProofIntervalMilliseconds
    [void](Assert-RepairBridgeProof -Context $Context -Proof (& $CaptureBridgeProof $Context))
    $guards = $null
    $freeze = $null
    $terminated = $false
    try {
        $guards = & $AcquireGuards $Context
        $guarded = & $CaptureSnapshot $Context
        [void](Assert-RepairSnapshot -Context $Context -Snapshot $guarded -Baseline $baseline)
        [void](Assert-RepairBridgeProof -Context $Context -Proof (& $CaptureBridgeProof $Context))
        $freeze = & $FreezeCoordinator $Context
        try {
            $frozen = & $CaptureSnapshot $Context
            [void](Assert-RepairSnapshot -Context $Context -Snapshot $frozen -Baseline $baseline)
            [void](Assert-RepairBridgeProof -Context $Context -Proof (& $CaptureBridgeProof $Context))
            & $TerminateCoordinator $Context $freeze
            if (-not (& $WaitCoordinatorExit $Context $freeze)) { throw 'The exact frozen coordinator did not exit.' }
            $terminated = $true
        } finally {
            if ($null -ne $freeze -and -not $terminated) { & $ResumeCoordinator $Context $freeze }
            if ($null -ne $freeze -and $freeze -is [IDisposable]) { $freeze.Dispose() }
        }
    } finally {
        if ($null -ne $guards) { & $ReleaseGuards $Context $guards }
    }
    return [pscustomobject][ordered]@{ repaired = $true; coordinatorProcessId = $Context.CoordinatorProcessId; appProcessId = $Context.AppProcessId }
}

function Initialize-RepairNativeMethods {
    if ('ChatGPTRemoteCoordinatorRepairNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public sealed class ChatGPTRemoteCoordinatorFreeze : IDisposable
{
    public IntPtr ProcessHandle { get; private set; }
    public uint ProcessId { get; private set; }
    public uint DebuggerThreadId { get; private set; }
    public uint PendingEventProcessId { get; private set; }
    public uint PendingEventThreadId { get; private set; }
    public bool Attached { get; private set; }
    public bool ExitProven { get; internal set; }

    internal ChatGPTRemoteCoordinatorFreeze(IntPtr handle, uint processId, uint debuggerThreadId)
    { ProcessHandle = handle; ProcessId = processId; DebuggerThreadId = debuggerThreadId; }
    internal void MarkAttached(uint eventProcessId, uint eventThreadId)
    { Attached = true; PendingEventProcessId = eventProcessId; PendingEventThreadId = eventThreadId; }
    public void MarkDetached() { Attached = false; }
    public void Dispose() { if (ProcessHandle != IntPtr.Zero) { ChatGPTRemoteCoordinatorRepairNative.CloseHandle(ProcessHandle); ProcessHandle = IntPtr.Zero; } }
}

public static class ChatGPTRemoteCoordinatorRepairNative
{
    const uint PROCESS_TERMINATE = 0x0001;
    const uint PROCESS_QUERY_INFORMATION = 0x0400;
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const uint SYNCHRONIZE = 0x00100000;
    const uint WAIT_OBJECT_0 = 0x00000000;
    const uint DBG_CONTINUE = 0x00010002;
    const uint CREATE_PROCESS_DEBUG_EVENT = 3;
    const uint EXIT_PROCESS_DEBUG_EVENT = 5;
    const uint LOAD_DLL_DEBUG_EVENT = 6;

    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, System.Text.StringBuilder path, ref uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CheckRemoteDebuggerPresent(IntPtr process, out bool present);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DebugActiveProcess(uint processId);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DebugActiveProcessStop(uint processId);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool DebugSetProcessKillOnExit(bool killOnExit);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool WaitForDebugEvent(IntPtr debugEvent, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ContinueDebugEvent(uint processId, uint threadId, uint continueStatus);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    static Win32Exception Failure(string operation) { return new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed"); }
    static void RequireDebuggerThread(ChatGPTRemoteCoordinatorFreeze frozen)
    {
        if (frozen.DebuggerThreadId != GetCurrentThreadId()) throw new InvalidOperationException("The coordinator debugger must remain on its attaching thread.");
    }
    static bool ExactProcess(IntPtr handle, long expectedCreationTime, string expectedImagePath)
    {
        long creation, exit, kernel, user;
        if (handle == IntPtr.Zero || !GetProcessTimes(handle, out creation, out exit, out kernel, out user) || creation != expectedCreationTime) return false;
        var path = new System.Text.StringBuilder(32768);
        uint size = (uint)path.Capacity;
        if (!QueryFullProcessImageName(handle, 0, path, ref size)) return false;
        return string.Equals(System.IO.Path.GetFullPath(path.ToString()), System.IO.Path.GetFullPath(expectedImagePath), StringComparison.OrdinalIgnoreCase);
    }
    static int UnionOffset { get { return IntPtr.Size == 8 ? 16 : 12; } }
    static void CloseDebuggerOwnedFileHandle(IntPtr buffer, uint eventCode)
    {
        // WaitForDebugEvent transfers ownership only of the CREATE_PROCESS and LOAD_DLL
        // file handles. The system closes the event's process/thread handles after the
        // corresponding EXIT event is continued, so closing those here can double-close a
        // subsequently reused handle value.
        if (eventCode == CREATE_PROCESS_DEBUG_EVENT || eventCode == LOAD_DLL_DEBUG_EVENT) {
            IntPtr handle = Marshal.ReadIntPtr(buffer, UnionOffset);
            if (handle != IntPtr.Zero) CloseHandle(handle);
        }
    }

    public static ChatGPTRemoteCoordinatorFreeze Freeze(uint processId, long expectedCreationTime, string expectedImagePath)
    {
        IntPtr handle = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_INFORMATION | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, processId);
        if (handle == IntPtr.Zero) throw Failure("OpenProcess(coordinator)");
        var result = new ChatGPTRemoteCoordinatorFreeze(handle, processId, GetCurrentThreadId());
        try {
            if (!ExactProcess(handle, expectedCreationTime, expectedImagePath)) throw new InvalidOperationException("The coordinator handle identity changed before debugger attachment.");
            bool present;
            if (!CheckRemoteDebuggerPresent(handle, out present)) throw Failure("CheckRemoteDebuggerPresent");
            if (present) throw new InvalidOperationException("The coordinator already has a native debugger attached.");
            if (!DebugActiveProcess(processId)) throw Failure("DebugActiveProcess");
            result.MarkAttached(0, 0);
            if (!DebugSetProcessKillOnExit(false)) throw Failure("DebugSetProcessKillOnExit");
            IntPtr buffer = Marshal.AllocHGlobal(1024);
            try {
                if (!WaitForDebugEvent(buffer, 5000)) throw Failure("WaitForDebugEvent");
                uint eventCode = unchecked((uint)Marshal.ReadInt32(buffer, 0));
                uint eventProcessId = unchecked((uint)Marshal.ReadInt32(buffer, 4));
                uint eventThreadId = unchecked((uint)Marshal.ReadInt32(buffer, 8));
                try {
                    if (eventCode != CREATE_PROCESS_DEBUG_EVENT || eventProcessId != processId) throw new InvalidOperationException("The debugger stopped an unexpected process or event.");
                    IntPtr eventProcess = Marshal.ReadIntPtr(buffer, UnionOffset + IntPtr.Size);
                    if (!ExactProcess(eventProcess, expectedCreationTime, expectedImagePath)) throw new InvalidOperationException("The debugger event is not bound to the captured coordinator handle identity.");
                    result.MarkAttached(eventProcessId, eventThreadId);
                } finally { CloseDebuggerOwnedFileHandle(buffer, eventCode); }
            } finally { Marshal.FreeHGlobal(buffer); }
            return result;
        } catch {
            if (result.Attached) { DebugActiveProcessStop(processId); result.MarkDetached(); }
            result.Dispose();
            throw;
        }
    }

    public static void Resume(ChatGPTRemoteCoordinatorFreeze frozen)
    {
        if (frozen == null || !frozen.Attached) return;
        RequireDebuggerThread(frozen);
        if (!DebugActiveProcessStop(frozen.ProcessId)) throw Failure("DebugActiveProcessStop");
        frozen.MarkDetached();
    }

    public static void TerminateAndWait(ChatGPTRemoteCoordinatorFreeze frozen, uint milliseconds)
    {
        if (frozen == null || frozen.ProcessHandle == IntPtr.Zero || !frozen.Attached) throw new InvalidOperationException("The exact coordinator is not frozen.");
        RequireDebuggerThread(frozen);
        try {
            if (!TerminateProcess(frozen.ProcessHandle, 0xC0D30001)) throw Failure("TerminateProcess(coordinator)");
            if (!ContinueDebugEvent(frozen.PendingEventProcessId, frozen.PendingEventThreadId, DBG_CONTINUE)) throw Failure("ContinueDebugEvent(initial)");
            var timer = System.Diagnostics.Stopwatch.StartNew();
            IntPtr buffer = Marshal.AllocHGlobal(1024);
            try {
                bool sawExit = false;
                while (!sawExit && timer.ElapsedMilliseconds < milliseconds) {
                    uint remaining = (uint)Math.Max(1L, (long)milliseconds - timer.ElapsedMilliseconds);
                    if (!WaitForDebugEvent(buffer, remaining)) throw Failure("WaitForDebugEvent(termination)");
                    uint eventCode = unchecked((uint)Marshal.ReadInt32(buffer, 0));
                    uint eventProcessId = unchecked((uint)Marshal.ReadInt32(buffer, 4));
                    uint eventThreadId = unchecked((uint)Marshal.ReadInt32(buffer, 8));
                    if (eventProcessId != frozen.ProcessId) throw new InvalidOperationException("The debugger received an event for another process.");
                    CloseDebuggerOwnedFileHandle(buffer, eventCode);
                    if (!ContinueDebugEvent(eventProcessId, eventThreadId, DBG_CONTINUE)) throw Failure("ContinueDebugEvent(termination)");
                    sawExit = eventCode == EXIT_PROCESS_DEBUG_EVENT;
                }
                if (!sawExit || WaitForSingleObject(frozen.ProcessHandle, 1000) != WAIT_OBJECT_0) throw new TimeoutException("The exact coordinator did not finish its debug exit sequence.");
                frozen.MarkDetached();
                frozen.ExitProven = true;
            } finally { Marshal.FreeHGlobal(buffer); }
        } catch {
            if (frozen.Attached && DebugActiveProcessStop(frozen.ProcessId)) frozen.MarkDetached();
            throw;
        }
    }
}
'@
}

function Invoke-RepairBridgeProof {
    param([Parameter(Mandatory)]$Context)
    $probe = @'
"use strict";
const cdp = require(process.argv[2]);
const port = Number(process.argv[3]);
const appPid = Number(process.argv[4]);
const coordinatorPid = Number(process.argv[5]);
const timeoutMs = 5000;
const targetUrl = "app://-/index.html";
async function getJson(pathname) {
  const response = await fetch(`http://127.0.0.1:${port}${pathname}`, {
    headers: { Accept: "application/json", Connection: "close" },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Debugger discovery returned HTTP ${response.status}`);
  return response.json();
}
async function proveOwner(target) {
  if (target?.codexElectronAttach === true) {
    if (target.expectedPid !== appPid || target.expectedUrl !== targetUrl || !Number.isInteger(target.webContentsId)) {
      throw new Error("The attached renderer is not bound to the exact ChatGPT process.");
    }
    return;
  }
  const version = await getJson("/json/version");
  const browser = new cdp.JsonRpcWebSocket(cdp.forceLoopbackWebSocketUrl(version.webSocketDebuggerUrl, port), { timeoutMs });
  await browser.connect();
  try {
    const system = await browser.call("SystemInfo.getProcessInfo", {}, timeoutMs);
    const owners = (system.processInfo || []).filter((entry) => entry.type === "browser");
    if (owners.length !== 1 || owners[0].id !== appPid) throw new Error("The debugger listener is not owned by the exact ChatGPT process.");
  } finally { browser.close(); }
}
(async () => {
  const targets = await cdp.discoverTargets(port, timeoutMs);
  const exact = targets.filter((target) => (target?.type === "page" || target?.type === "webview") && target.url === targetUrl);
  if (exact.length !== 1) throw new Error(`Expected one exact renderer target; found ${exact.length}.`);
  await proveOwner(exact[0]);
  const client = await cdp.connectTarget(exact[0], port, timeoutMs);
  try {
    const tree = await client.call("Page.getFrameTree", {}, timeoutMs);
    if (tree?.frameTree?.frame?.url !== targetUrl) throw new Error("The renderer main frame changed during bridge proof.");
    const proof = await cdp.evaluate(client, `(async () => {
      const bridgeHealthy = await (async () => {
        const api = globalThis.__CHATGPT_REMOTE_UPDATE__;
        const internal = globalThis.__CHATGPT_REMOTE_UPDATE_INTERNAL__;
        if (typeof api?.getStatus !== "function" || typeof api?.request !== "function" ||
            typeof internal?.nonce !== "string" || internal.nonce.length < 16 ||
            typeof internal?.setStatus !== "function" ||
            typeof internal?.receive !== "function" || typeof internal?.dispose !== "function") return false;
        const hasBindingName = Object.prototype.hasOwnProperty.call(internal, "bindingName");
        if (hasBindingName && (typeof internal.bindingName !== "string" || internal.bindingName.length === 0)) return false;
        const bindingName = hasBindingName ? internal.bindingName : "__chatgptRemoteUpdateRequest";
        const binding = globalThis[bindingName];
        if (typeof binding !== "function") return false;
        const hasOwnerToken = Object.prototype.hasOwnProperty.call(internal, "bindingOwnerToken");
        if (hasOwnerToken && (typeof internal.bindingOwnerToken !== "string" || internal.bindingOwnerToken.length === 0 ||
            binding.__chatgptRemoteUpdateOwnerV1 !== internal.bindingOwnerToken)) return false;
        try {
          if (typeof api.getStatus()?.state !== "string") return false;
          const response = await Promise.race([
            api.request("history"),
            new Promise((_, reject) => setTimeout(() => reject(new Error("Legacy bridge request timed out.")), 4000)),
          ]);
          return typeof response?.state === "string";
        } catch { return false; }
      })();
      return {
        topFrame: globalThis.top === globalThis,
        targetUrl: globalThis.location?.href,
        publicBridgeMissing: globalThis.__CHATGPT_REMOTE_UPDATE__ === undefined,
        internalBridgeMissing: globalThis.__CHATGPT_REMOTE_UPDATE_INTERNAL__ === undefined,
        bridgeHealthy,
      };
    })()`, timeoutMs);
    if (proof?.topFrame !== true || proof?.targetUrl !== targetUrl) throw new Error("The bridge proof did not execute in the exact top frame.");
    console.log(JSON.stringify({
      publicBridgeMissing: proof.publicBridgeMissing === true,
      internalBridgeMissing: proof.internalBridgeMissing === true,
      bridgeHealthy: proof.bridgeHealthy === true,
      appProcessId: appPid,
      rendererPort: port,
      coordinatorProcessId: coordinatorPid,
      sampledAtUnixMs: Date.now(),
    }));
  } finally { client.close(); }
})().catch((error) => {
  console.error(String(error?.message || error).replace(/[\r\n\0]+/gu, " ").slice(0, 320));
  process.exitCode = 1;
});
'@
    $output = @($probe | & $Context.CoordinatorExecutablePath '--no-warnings' '-' $Context.CdpPath `
        ([string]$Context.RendererPort) ([string]$Context.AppProcessId) ([string]$Context.CoordinatorProcessId) 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Renderer bridge proof failed: $($output -join ' ')" }
    $line = @($output | ForEach-Object { [string]$_ } | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($line)) { throw 'Renderer bridge proof returned no JSON result.' }
    return $line | ConvertFrom-Json -ErrorAction Stop
}

function Enter-RepairGuards {
    param([Parameter(Mandatory)]$Context)
    $mutex = [Threading.Mutex]::new($false, 'Local\ChatGPTCustomInjectionLauncher')
    $mutexOwned = $false
    $stream = $null
    try {
        try { $mutexOwned = $mutex.WaitOne([TimeSpan]::FromSeconds($Context.GuardTimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $mutexOwned = $true }
        if (-not $mutexOwned) { throw 'UPDATE_BUSY: the launcher guard is owned by another process.' }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Context.UpdateLockPath) -Force | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds($Context.GuardTimeoutSeconds)
        do {
            try {
                $stream = [IO.FileStream]::new($Context.UpdateLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                break
            } catch [IO.IOException] {
                if ([DateTime]::UtcNow -ge $deadline) { throw 'UPDATE_BUSY: the updater lock is owned by another process.' }
                Start-Sleep -Milliseconds 50
            }
        } while ($true)
        return [pscustomobject]@{ Mutex = $mutex; MutexOwned = $mutexOwned; Stream = $stream }
    } catch {
        if ($stream) { $stream.Dispose() }
        if ($mutexOwned) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
        throw
    }
}

function Exit-RepairGuards {
    param($Guards)
    if ($Guards.Stream) { $Guards.Stream.Dispose() }
    if ($Guards.MutexOwned) { try { $Guards.Mutex.ReleaseMutex() } finally { $Guards.Mutex.Dispose() } }
    else { $Guards.Mutex.Dispose() }
}

function New-RepairContext {
    $resolvedConfig = Get-RepairNormalizedPath $ConfigPath
    $resolvedExecutable = Get-RepairNormalizedPath $CoordinatorExecutablePath
    foreach ($file in @($resolvedConfig, $resolvedExecutable)) {
        if (-not (Test-RepairPlainFile $file)) { throw "A required coordinator-repair file is missing or linked: $file" }
    }
    $config = Get-RepairJson $resolvedConfig
    $sessionDirectory = Get-RepairNormalizedPath ([string]$config.sessionDirectory)
    $sessionStateRoot = Get-RepairNormalizedPath ([string]$config.stateRoot)
    if (-not [string]::Equals((Split-Path -Parent $sessionDirectory), (Join-Path $sessionStateRoot 'sessions'), [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($sessionDirectory) -notmatch '^[0-9a-f]{32}$') { throw 'The coordinator session path is outside the owned state root.' }
    $coordinatorScript = Get-RepairNormalizedPath (Join-Path (Split-Path -Parent ([string]$config.updaterPath)) 'update-session.js')
    if (-not (Test-RepairPlainFile $coordinatorScript)) { throw 'The immutable coordinator script is unavailable.' }
    $cdpPath = Get-RepairNormalizedPath (Join-Path $PSScriptRoot 'cdp.js')
    if (-not (Test-RepairPlainFile $cdpPath)) { throw 'The immutable coordinator-repair debugger client is unavailable.' }
    $appPid = 0
    $appStart = 0L
    $rendererPort = 0
    if (-not [int]::TryParse([string]$config.app.pid, [ref]$appPid) -or $appPid -le 0 -or $appPid -eq $CoordinatorProcessId -or
        -not [long]::TryParse([string]$config.app.startTimeFileTimeUtc, [ref]$appStart) -or $appStart -le 0 -or
        -not [int]::TryParse([string]$config.rendererPort, [ref]$rendererPort) -or $rendererPort -lt 1024 -or $rendererPort -gt 65535) {
        throw 'The coordinator configuration has an invalid ChatGPT identity.'
    }
    $appExecutable = Get-RepairNormalizedPath ([string]$config.app.executablePath)
    $statePath = Join-Path $sessionDirectory 'coordinator-state.json'
    $historyPath = Join-Path $sessionDirectory 'update-history-v1.json'
    $identity = "win32`0$appPid`0$([string]$appStart)"
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($identity)))).Replace('-', '').ToLowerInvariant().Substring(0, 24)
    } finally { $algorithm.Dispose() }
    $lockPath = Join-Path (Join-Path $sessionStateRoot 'active') "$hash.lock"
    $updaterStateRoot = Join-Path (Split-Path -Parent $sessionStateRoot) 'update'
    return [pscustomobject][ordered]@{
        ConfigPath = $resolvedConfig
        SessionDirectory = $sessionDirectory
        SessionStateRoot = $sessionStateRoot
        StatePath = $statePath
        HistoryPath = $historyPath
        LockPath = $lockPath
        CoordinatorProcessId = $CoordinatorProcessId
        CoordinatorStartTimeFileTimeUtc = $CoordinatorStartTimeFileTimeUtc
        CoordinatorExecutablePath = $resolvedExecutable
        CoordinatorScriptPath = $coordinatorScript
        AppProcessId = $appPid
        AppStartTimeFileTimeUtc = $appStart
        AppExecutablePath = $appExecutable
        RendererPort = $rendererPort
        CdpPath = $cdpPath
        CdpText = Get-RepairFileText $cdpPath
        UpdateLockPath = Join-Path $updaterStateRoot 'update.lock'
        TransactionJournalPath = Join-Path $updaterStateRoot 'transaction.json'
        GitTransactionJournalPath = Join-Path $updaterStateRoot 'git-transaction.json'
        GuardTimeoutSeconds = $GuardTimeoutSeconds
    }
}

if (-not $ImportOnly) {
    if ($env:OS -ne 'Windows_NT') { throw 'Coordinator repair is supported only on Windows.' }
    Initialize-RepairNativeMethods
    $context = New-RepairContext
    $captureSnapshot = { param($value) Get-RepairSnapshot $value }
    $captureBridgeProof = {
        param($value)
        if ((Get-RepairFileText $value.CdpPath) -cne $value.CdpText) { throw 'The renderer bridge proof dependency changed during repair.' }
        $proof = Invoke-RepairBridgeProof $value
        $proof | Add-Member -NotePropertyName appStartTimeFileTimeUtc -NotePropertyValue ([string]$value.AppStartTimeFileTimeUtc)
        return $proof
    }
    $initialSnapshot = & $captureSnapshot $context
    [void](Assert-RepairSnapshot -Context $context -Snapshot $initialSnapshot)
    $initialBridgeProof = & $captureBridgeProof $context
    if ($initialBridgeProof.bridgeHealthy -eq $true) {
        [pscustomobject][ordered]@{
            repaired = $false
            reason = 'legacy-coordinator-bridge-healthy'
            coordinatorProcessId = $context.CoordinatorProcessId
            appProcessId = $context.AppProcessId
        } | ConvertTo-Json -Compress
        return
    }
    if ($initialBridgeProof.publicBridgeMissing -ne $true -or $initialBridgeProof.internalBridgeMissing -ne $true) {
        [pscustomobject][ordered]@{
            repaired = $false
            reason = 'legacy-coordinator-bridge-present-unverified'
            coordinatorProcessId = $context.CoordinatorProcessId
            appProcessId = $context.AppProcessId
        } | ConvertTo-Json -Compress
        return
    }
    [void](Assert-RepairBridgeProof -Context $context -Proof $initialBridgeProof)
    $acquire = { param($value) Enter-RepairGuards $value }
    $freeze = { param($value) [ChatGPTRemoteCoordinatorRepairNative]::Freeze([uint32]$value.CoordinatorProcessId, [long]$value.CoordinatorStartTimeFileTimeUtc, [string]$value.CoordinatorExecutablePath) }
    $resume = { param($value, $token) [ChatGPTRemoteCoordinatorRepairNative]::Resume($token) }
    $terminate = { param($value, $token) [ChatGPTRemoteCoordinatorRepairNative]::TerminateAndWait($token, 10000) }
    $wait = { param($value, $token) return [bool]$token.ExitProven }
    $release = { param($value, $guards) Exit-RepairGuards $guards }
    $result = Invoke-RepairCore -Context $context -CaptureSnapshot $captureSnapshot -CaptureBridgeProof $captureBridgeProof `
        -AcquireGuards $acquire -FreezeCoordinator $freeze -ResumeCoordinator $resume -TerminateCoordinator $terminate `
        -WaitCoordinatorExit $wait -ReleaseGuards $release -ProofIntervalMilliseconds $ProofIntervalMilliseconds
    $result | ConvertTo-Json -Compress
}
