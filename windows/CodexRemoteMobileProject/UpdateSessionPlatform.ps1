[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Probe', 'Close', 'Notify')]
    [string]$Action,
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [string]$Message
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [IO.Path]::IsPathRooted($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw 'The update-session configuration path is invalid.'
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
$pidValue = 0
$startValue = 0L
if (-not [int]::TryParse([string]$config.app.pid, [ref]$pidValue) -or $pidValue -le 0 -or
    -not [long]::TryParse([string]$config.app.startTimeFileTimeUtc, [ref]$startValue) -or $startValue -le 0 -or
    [string]::IsNullOrWhiteSpace([string]$config.app.executablePath)) {
    throw 'The Windows app identity is incomplete.'
}
$expectedPath = [IO.Path]::GetFullPath([string]$config.app.executablePath)
$closeTimeoutMilliseconds = 30000
if ($null -ne $config.PSObject.Properties['closeTimeoutMs']) {
    $parsedTimeout = 0
    if (-not [int]::TryParse([string]$config.closeTimeoutMs, [ref]$parsedTimeout) -or $parsedTimeout -lt 100 -or $parsedTimeout -gt 30000) {
        throw 'The configured graceful-close timeout is invalid.'
    }
    $closeTimeoutMilliseconds = $parsedTimeout
}

if ($Action -eq 'Notify') {
    if (-not ('ChatGPTRemoteUpdateNotification' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ChatGPTRemoteUpdateNotification
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int MessageBox(IntPtr window, string text, string caption, uint type);
}
'@
    }
    $text = if ([string]::IsNullOrWhiteSpace($Message)) { 'The update could not be completed. Review the update-session log.' } else { $Message }
    [void][ChatGPTRemoteUpdateNotification]::MessageBox([IntPtr]::Zero, $text, 'ChatGPT Remote update', 0x10)
    [ordered]@{ notified = $true } | ConvertTo-Json -Compress
    return
}

function Get-ExactProcess {
    try {
        $process = [Diagnostics.Process]::GetProcessById($pidValue)
        $actualStart = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
        $actualPath = [IO.Path]::GetFullPath($process.MainModule.FileName)
        if ($actualStart -ne $startValue -or
            -not [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            $process.Dispose()
            return $null
        }
        return $process
    } catch {
        return $null
    }
}

if ($Action -eq 'Probe') {
    $process = Get-ExactProcess
    try {
        [ordered]@{ running = [bool]($null -ne $process); pid = $pidValue } | ConvertTo-Json -Compress
    } finally {
        if ($process) { $process.Dispose() }
    }
    return
}

if (-not ('ChatGPTRemoteUpdateWindows' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class ChatGPTRemoteUpdateWindows
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    private const uint WM_CLOSE = 0x0010;

    public static int PostCloseToProcess(uint expectedProcessId)
    {
        var windows = new List<IntPtr>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId == expectedProcessId && IsWindowVisible(window)) windows.Add(window);
            return true;
        }, IntPtr.Zero);
        int posted = 0;
        foreach (IntPtr window in windows) if (PostMessage(window, WM_CLOSE, IntPtr.Zero, IntPtr.Zero)) posted += 1;
        return posted;
    }
}
'@
}

$target = Get-ExactProcess
if (-not $target) { throw 'The exact ChatGPT process changed before the graceful close request.' }
try {
    $posted = [ChatGPTRemoteUpdateWindows]::PostCloseToProcess([uint32]$pidValue)
    if ($posted -le 0) { throw 'ChatGPT has no exact-process window that accepted WM_CLOSE.' }
    if (-not $target.WaitForExit($closeTimeoutMilliseconds)) {
        throw "ChatGPT did not exit within $closeTimeoutMilliseconds milliseconds after WM_CLOSE; the update was aborted without force-closing it."
    }
} finally {
    $target.Dispose()
}
[ordered]@{ closed = $true; pid = $pidValue; method = 'WM_CLOSE' } | ConvertTo-Json -Compress
