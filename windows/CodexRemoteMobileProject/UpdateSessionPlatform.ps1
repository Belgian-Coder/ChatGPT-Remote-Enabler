[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Probe', 'Close', 'Notify')]
    [string]$Action,
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [string]$Message,
    [string]$NodePath
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

function Get-SafeErrorText {
    param([object]$ErrorValue)

    $text = ([string]$ErrorValue -replace '[\r\n\0]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return 'unknown error' }
    return $text.Substring(0, [Math]::Min(240, $text.Length))
}

function Get-VerifiedCoordinatorNode {
    if ([string]::IsNullOrWhiteSpace($NodePath) -or -not [IO.Path]::IsPathRooted($NodePath) -or
        $null -eq $config.PSObject.Properties['launchReceipt'] -or
        $null -eq $config.launchReceipt.PSObject.Properties['nodeSha256']) {
        throw 'The update-session coordinator identity is unavailable.'
    }
    $verifiedNodePath = [IO.Path]::GetFullPath($NodePath)
    if (-not (Test-Path -LiteralPath $verifiedNodePath -PathType Leaf) -or
        [string]$config.launchReceipt.nodeSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'The update-session coordinator executable is invalid.'
    }
    $actualNodeHash = (Get-FileHash -LiteralPath $verifiedNodePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualNodeHash -cne ([string]$config.launchReceipt.nodeSha256).ToLowerInvariant()) {
        throw 'The update-session coordinator executable identity changed.'
    }
    return $verifiedNodePath
}

function Assert-ExactRendererListener {
    param([int]$RendererPort)

    $listeners = @(
        Get-NetTCPConnection -State Listen -LocalPort $RendererPort -ErrorAction Stop |
            Where-Object { [string]$_.LocalAddress -ceq '127.0.0.1' }
    )
    if ($listeners.Count -ne 1 -or [int]$listeners[0].OwningProcess -ne $pidValue) {
        throw 'The exact ChatGPT process does not own the loopback debugger listener.'
    }
}

function Request-NativeRendererQuit {
    if ([IO.Path]::GetFileName($expectedPath) -cne 'ChatGPT.exe') {
        throw 'The exact application is not the packaged ChatGPT executable.'
    }
    $rendererPort = 0
    if ($null -eq $config.PSObject.Properties['rendererPort'] -or
        -not [int]::TryParse([string]$config.rendererPort, [ref]$rendererPort) -or
        $rendererPort -lt 1 -or $rendererPort -gt 65535) {
        throw 'The exact ChatGPT debugger port is unavailable.'
    }
    Assert-ExactRendererListener -RendererPort $rendererPort
    $nodePath = Get-VerifiedCoordinatorNode
    $cdpPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSCommandPath) 'cdp.js'))
    if (-not (Test-Path -LiteralPath $cdpPath -PathType Leaf)) {
        throw 'The immutable debugger client is unavailable.'
    }
    $nativeQuitScript = @'
"use strict";
const cdp = require(process.argv[2]);
const port = Number(process.argv[3]);
const expectedPid = Number(process.argv[4]);
const timeoutMs = 3000;
async function getJson(pathname) {
  const response = await fetch(`http://127.0.0.1:${port}${pathname}`, {
    headers: { Accept: "application/json", Connection: "close" },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!response.ok) throw new Error(`Debugger discovery returned HTTP ${response.status}`);
  return response.json();
}
(async () => {
  const version = await getJson("/json/version");
  const browser = new cdp.JsonRpcWebSocket(cdp.forceLoopbackWebSocketUrl(version.webSocketDebuggerUrl, port), { timeoutMs });
  await browser.connect();
  try {
    const system = await browser.call("SystemInfo.getProcessInfo", {}, timeoutMs);
    const owners = (system.processInfo || []).filter((entry) => entry.type === "browser");
    if (owners.length !== 1 || owners[0].id !== expectedPid) {
      throw new Error("The debugger listener is not owned by the exact ChatGPT process.");
    }
  } finally {
    browser.close();
  }
  const targets = await cdp.discoverTargets(port, timeoutMs);
  const matches = targets.filter((target) => target.type === "page" && target.url === "app://-/index.html");
  if (matches.length !== 1) throw new Error(`Expected one exact ChatGPT renderer target; found ${matches.length}.`);
  const page = await cdp.connectTarget(matches[0], port, timeoutMs);
  let dispatched = false;
  try {
    const tree = await page.call("Page.getFrameTree", {}, timeoutMs);
    if (tree?.frameTree?.frame?.url !== "app://-/index.html") {
      throw new Error("The debugger target main frame is not the exact ChatGPT renderer.");
    }
    dispatched = true;
    const result = await page.call("Runtime.evaluate", {
      awaitPromise: false,
      expression: `(() => {
        const bridge = globalThis.electronBridge;
        if (top !== globalThis || location.href !== "app://-/index.html" ||
            typeof bridge?.sendMessageFromView !== "function") {
          return { requested: false };
        }
        bridge.sendMessageFromView({ type: "quit-app" });
        return { requested: true };
      })()`,
      generatePreview: false,
      returnByValue: true,
      userGesture: false,
    }, timeoutMs);
    if (result.exceptionDetails || result.result?.value?.requested !== true) {
      throw new Error("The exact ChatGPT renderer did not accept its native quit command.");
    }
    console.log(JSON.stringify({ requested: true, connectionClosed: false }));
  } catch (error) {
    if (dispatched && error?.code === "WEBSOCKET_CLOSED") {
      console.log(JSON.stringify({ requested: true, connectionClosed: true }));
      return;
    }
    throw error;
  } finally {
    page.close();
  }
})().catch((error) => {
  console.error(String(error?.message || error).replace(/[\r\n\0]+/gu, " ").slice(0, 240));
  process.exitCode = 1;
});
'@
    $exactBeforeDispatch = Get-ExactProcess
    if (-not $exactBeforeDispatch) { throw 'The exact ChatGPT process changed before its native quit request.' }
    $exactBeforeDispatch.Dispose()
    $output = @($nativeQuitScript | & $nodePath '--no-warnings' '-' $cdpPath ([string]$rendererPort) ([string]$pidValue) 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw (Get-SafeErrorText ($output -join ' '))
    }
    $resultLine = @($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
    $result = $resultLine | ConvertFrom-Json -ErrorAction Stop
    if ($result.requested -ne $true) { throw 'The exact ChatGPT renderer did not accept its native quit command.' }
    return $result
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
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nativeQuit = $null
    $nativeFailure = $null
    try {
        $nativeQuit = Request-NativeRendererQuit
    } catch {
        $nativeFailure = Get-SafeErrorText $_.Exception.Message
    }
    if ($nativeQuit -and $nativeQuit.requested -eq $true) {
        $remaining = [Math]::Max(0, $closeTimeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
        if ($target.HasExited -or ($remaining -gt 0 -and $target.WaitForExit($remaining))) {
            [ordered]@{ closed = $true; pid = $pidValue; method = 'native-renderer-quit' } | ConvertTo-Json -Compress
            return
        }
        throw "ChatGPT did not exit within $closeTimeoutMilliseconds milliseconds after its native renderer quit command; the update was aborted without externally force-closing it."
    }
    if ($target.HasExited) {
        [ordered]@{ closed = $true; pid = $pidValue; method = 'concurrent-graceful-exit' } | ConvertTo-Json -Compress
        return
    }
    $posted = [ChatGPTRemoteUpdateWindows]::PostCloseToProcess([uint32]$pidValue)
    if ($posted -le 0) {
        throw "ChatGPT's native quit command was unavailable ($nativeFailure), and it has no exact-process window that accepted WM_CLOSE."
    }
    $remaining = [Math]::Max(0, $closeTimeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
    if ($remaining -le 0 -or -not $target.WaitForExit($remaining)) {
        throw "ChatGPT did not exit within $closeTimeoutMilliseconds milliseconds after its native quit command was unavailable ($nativeFailure) and WM_CLOSE was requested; the update was aborted without force-closing it."
    }
} finally {
    $target.Dispose()
}
[ordered]@{ closed = $true; pid = $pidValue; method = 'WM_CLOSE' } | ConvertTo-Json -Compress
