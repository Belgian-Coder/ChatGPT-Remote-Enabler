[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'The native Windows update-session test requires Windows.' }

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$platformSource = Join-Path $root 'windows\CodexRemoteMobileProject\UpdateSessionPlatform.ps1'
$cdpSource = Join-Path $root 'windows\CodexRemoteSimple\runtime\lib\cdp.js'
if (-not (Test-Path -LiteralPath $platformSource -PathType Leaf) -or
    -not (Test-Path -LiteralPath $cdpSource -PathType Leaf)) {
    throw 'The Windows update-session platform adapter is missing.'
}

$temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$testRoot = Join-Path $temporary ('chatgpt-remote-update-session-test-' + [guid]::NewGuid().ToString('N'))
$platformScript = Join-Path $testRoot 'UpdateSessionPlatform.ps1'
$fixtureRecords = [Collections.Generic.List[object]]::new()
$nativeFixtureRecords = [Collections.Generic.List[object]]::new()
$forcedCleanupCount = 0
$testResult = $null
$testFailure = $null
$cleanupFailure = $null

function Wait-TestFile {
    param([string]$Path, [Diagnostics.Process]$Process, [int]$TimeoutMilliseconds = 10000)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        if ($Process.HasExited) { throw "The fixture process exited before signaling readiness: $($Process.Id)" }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The fixture process did not signal readiness: $($Process.Id)"
}

function Start-TestFixture {
    param(
        [ValidateSet('cooperative', 'refuse', 'no-window')]
        [string]$Mode,
        [string]$ExecutablePath,
        [string]$Name,
        [Collections.Generic.List[object]]$FixtureRecords
    )

    $readyPath = Join-Path $testRoot "$Name.ready"
    $stopPath = Join-Path $testRoot "$Name.stop"
    $process = Start-Process -FilePath $ExecutablePath -ArgumentList @($Mode, $readyPath, $stopPath) -WindowStyle Hidden -PassThru
    $startTime = 0L
    $actualPath = $null
    try {
        Wait-TestFile -Path $readyPath -Process $process
        $actual = [Diagnostics.Process]::GetProcessById($process.Id)
        try {
            $startTime = $actual.StartTime.ToUniversalTime().ToFileTimeUtc()
            $actualPath = [IO.Path]::GetFullPath($actual.MainModule.FileName)
        } finally {
            $actual.Dispose()
        }
        if (-not [string]::Equals($actualPath, [IO.Path]::GetFullPath($ExecutablePath), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The fixture executable identity changed during startup.'
        }
        $record = [pscustomobject]@{
            ExecutablePath = $actualPath
            Name = $Name
            Pid = [int]$process.Id
            Process = $process
            ReadyPath = $readyPath
            StartTimeFileTimeUtc = [long]$startTime
            StopPath = $stopPath
        }
        $FixtureRecords.Add($record)
        return $record
    } catch {
        $process.Dispose()
        throw
    }
}

function New-AdapterConfig {
    param(
        [string]$Name,
        [int]$ProcessId,
        [string]$StartTimeFileTimeUtc,
        [string]$ExecutablePath,
        [int]$CloseTimeoutMilliseconds = 2000
    )

    $sessionDirectory = Join-Path $testRoot "session-$Name"
    New-Item -ItemType Directory -Path $sessionDirectory | Out-Null
    $configPath = Join-Path $sessionDirectory 'session.json'
    $config = [ordered]@{
        schemaVersion = 1
        platform = 'win32'
        installRoot = $testRoot
        stateRoot = $testRoot
        sessionDirectory = $sessionDirectory
        updaterPath = Join-Path $testRoot 'fixture-updater.ps1'
        platformHelperPath = $platformScript
        rendererPort = 24547
        autoCheckEnabled = $false
        skipInitialCheck = $true
        logPath = Join-Path $sessionDirectory 'update-session.log'
        closeTimeoutMs = $CloseTimeoutMilliseconds
        app = [ordered]@{
            pid = $ProcessId
            startTimeFileTimeUtc = $StartTimeFileTimeUtc
            executablePath = $ExecutablePath
        }
        relaunch = [ordered]@{
            entryPointRelative = 'CodexRemoteMobileProject\MobileProjectStartup.ps1'
            useProxy = $false
            replaceRunningApp = $false
        }
    }
    $json = ($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine
    [IO.File]::WriteAllText($configPath, $json, [Text.UTF8Encoding]::new($false))
    return $configPath
}

function Invoke-PlatformAdapter {
    param(
        [ValidateSet('Probe', 'Close')]
        [string]$Action,
        [string]$ConfigPath,
        [string]$NodePath
    )

    try {
        $adapterParameters = @{ Action = $Action; ConfigPath = $ConfigPath }
        if (-not [string]::IsNullOrWhiteSpace($NodePath)) { $adapterParameters.NodePath = $NodePath }
        $output = @(& $platformScript @adapterParameters)
        if ($output.Count -ne 1) { throw "The platform adapter returned $($output.Count) output records." }
        return [pscustomobject]@{
            Error = $null
            Json = [string]$output[0]
            Result = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
            Succeeded = $true
        }
    } catch {
        return [pscustomobject]@{
            Error = [string]$_.Exception.Message
            Json = $null
            Result = $null
            Succeeded = $false
        }
    }
}

function Test-TrackedFixtureAlive {
    param($Record)

    try {
        $actual = [Diagnostics.Process]::GetProcessById([int]$Record.Pid)
        try {
            $actualStart = $actual.StartTime.ToUniversalTime().ToFileTimeUtc()
            $actualPath = [IO.Path]::GetFullPath($actual.MainModule.FileName)
            return $actualStart -eq [long]$Record.StartTimeFileTimeUtc -and
                [string]::Equals($actualPath, [string]$Record.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
        } finally {
            $actual.Dispose()
        }
    } catch {
        return $false
    }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Start-NativeQuitFixture {
    param(
        [ValidateSet('quit', 'close-before-response', 'pid-mismatch', 'target-mismatch')]
        [string]$Mode,
        [string]$ExecutablePath,
        [string]$ScriptPath,
        [Collections.Generic.List[object]]$FixtureRecords
    )

    $port = Get-FreeTcpPort
    $readyPath = Join-Path $testRoot "native-$Mode.ready"
    $quitPath = Join-Path $testRoot "native-$Mode.quit"
    $stopPath = Join-Path $testRoot "native-$Mode.stop"
    $process = Start-Process -FilePath $ExecutablePath -ArgumentList @($ScriptPath, $Mode, $port, $readyPath, $quitPath, $stopPath) -WindowStyle Hidden -PassThru
    $record = $null
    try {
        $actualStart = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
        $actualPath = [IO.Path]::GetFullPath($ExecutablePath)
        $record = [pscustomobject]@{
            ExecutablePath = $actualPath
            Mode = $Mode
            Pid = [int]$process.Id
            Port = [int]$port
            Process = $process
            QuitPath = $quitPath
            ReadyPath = $readyPath
            StartTimeFileTimeUtc = [long]$actualStart
            StopPath = $stopPath
        }
        $FixtureRecords.Add($record)
        Wait-TestFile -Path $readyPath -Process $process
        $actual = [Diagnostics.Process]::GetProcessById($process.Id)
        try {
            if ($actual.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $actualStart -or
                -not [string]::Equals([IO.Path]::GetFullPath($actual.MainModule.FileName), $actualPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The native-quit fixture executable identity changed during startup.'
            }
        } finally {
            $actual.Dispose()
        }
        return $record
    } catch {
        if ($null -eq $record) { $process.Dispose() }
        throw
    }
}

function New-NativeAdapterConfig {
    param($Record, [string]$CoordinatorNodePath, [int]$CloseTimeoutMilliseconds = 5000, [string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "native-$($Record.Mode)" }
    $configPath = New-AdapterConfig -Name $Name -ProcessId $Record.Pid `
        -StartTimeFileTimeUtc $Record.StartTimeFileTimeUtc.ToString([Globalization.CultureInfo]::InvariantCulture) `
        -ExecutablePath $Record.ExecutablePath -CloseTimeoutMilliseconds $CloseTimeoutMilliseconds
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $config.rendererPort = $Record.Port
    $nodeHash = (Get-FileHash -LiteralPath $CoordinatorNodePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $receiptPath = Join-Path (Split-Path -Parent $configPath) 'coordinator-ready.json'
    $config | Add-Member -NotePropertyName launchReceipt -NotePropertyValue ([pscustomobject][ordered]@{
        path = $receiptPath
        nodeSha256 = $nodeHash
    })
    [IO.File]::WriteAllText($configPath, (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    return $configPath
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Copy-Item -LiteralPath $platformSource -Destination $platformScript
    Copy-Item -LiteralPath $cdpSource -Destination (Join-Path $testRoot 'cdp.js')
    $fixtureSourcePath = Join-Path $testRoot 'InvisibleWindowFixture.cs'
    $fixtureExecutable = Join-Path $testRoot 'InvisibleWindowFixture.exe'
    $fixtureSource = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Threading;
using System.Windows.Forms;

internal sealed class FixtureForm : Form
{
    private bool allowClose;
    private readonly bool refuseClose;
    private readonly string stopPath;
    private readonly System.Windows.Forms.Timer stopTimer;

    internal FixtureForm(bool refuseClose, string readyPath, string stopPath)
    {
        this.refuseClose = refuseClose;
        this.stopPath = stopPath;
        ShowInTaskbar = false;
        Opacity = 0D;
        WindowState = FormWindowState.Minimized;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-32000, -32000);
        Size = new Size(1, 1);
        Shown += delegate {
            File.WriteAllText(readyPath, Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
        };
        stopTimer = new System.Windows.Forms.Timer { Interval = 25 };
        stopTimer.Tick += delegate {
            if (!File.Exists(this.stopPath)) return;
            allowClose = true;
            stopTimer.Stop();
            Close();
        };
        stopTimer.Start();
    }

    protected override void OnFormClosing(FormClosingEventArgs eventArgs)
    {
        if (refuseClose && !allowClose) {
            eventArgs.Cancel = true;
            return;
        }
        base.OnFormClosing(eventArgs);
    }
}

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 3) return 2;
        string mode = args[0];
        string readyPath = args[1];
        string stopPath = args[2];
        if (mode == "no-window") {
            File.WriteAllText(readyPath, Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
            while (!File.Exists(stopPath)) Thread.Sleep(25);
            return 0;
        }
        if (mode != "cooperative" && mode != "refuse") return 3;
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
        Application.Run(new FixtureForm(mode == "refuse", readyPath, stopPath));
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($fixtureSourcePath, $fixtureSource, [Text.UTF8Encoding]::new($false))
    $compilerCandidates = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) { throw 'The .NET Framework C# compiler was not found.' }
    & $compiler /nologo /target:winexe "/out:$fixtureExecutable" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $fixtureSourcePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fixtureExecutable -PathType Leaf)) {
        throw 'The invisible Windows fixture did not compile.'
    }
    $alternateExecutable = Join-Path $testRoot 'AlternateInvisibleWindowFixture.exe'
    Copy-Item -LiteralPath $fixtureExecutable -Destination $alternateExecutable

    $nodeSource = (Get-Command node.exe -ErrorAction Stop).Source
    $nativeFixtureExecutable = Join-Path $testRoot 'ChatGPT.exe'
    Copy-Item -LiteralPath $nodeSource -Destination $nativeFixtureExecutable
    $nativeFixtureScript = Join-Path $testRoot 'NativeQuitCdpFixture.js'
    [IO.File]::WriteAllText($nativeFixtureScript, @'
"use strict";
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const [mode, portText, readyPath, quitPath, stopPath] = process.argv.slice(2);
const port = Number(portText);

function sendFrame(socket, value) {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function consumeFrames(socket, initial, endpoint) {
  let buffered = initial;
  const consume = () => {
    while (buffered.length >= 2) {
      const opcode = buffered[0] & 0x0f;
      const masked = (buffered[1] & 0x80) !== 0;
      let length = buffered[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffered.length < 4) return;
        length = buffered.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffered.length < 10) return;
        const large = buffered.readBigUInt64BE(2);
        if (large > BigInt(Number.MAX_SAFE_INTEGER)) process.exit(71);
        length = Number(large);
        offset = 10;
      }
      const maskLength = masked ? 4 : 0;
      if (buffered.length < offset + maskLength + length) return;
      const mask = masked ? buffered.subarray(offset, offset + 4) : null;
      offset += maskLength;
      const payload = Buffer.from(buffered.subarray(offset, offset + length));
      buffered = buffered.subarray(offset + length);
      if (mask) for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4];
      if (opcode === 8) { socket.end(); continue; }
      if (opcode !== 1) continue;
      const message = JSON.parse(payload.toString("utf8"));
      if (endpoint === "browser" && message.method === "SystemInfo.getProcessInfo") {
        const id = mode === "pid-mismatch" ? process.pid + 10000 : process.pid;
        sendFrame(socket, { id: message.id, result: { processInfo: [{ type: "browser", id, cpuTime: 0 }] } });
      } else if (endpoint === "page" && message.method === "Page.getFrameTree") {
        sendFrame(socket, { id: message.id, result: { frameTree: { frame: { id: "main", url: "app://-/index.html" } } } });
      } else if (endpoint === "page" && message.method === "Runtime.evaluate") {
        fs.writeFileSync(quitPath, "quit-app");
        if (mode === "close-before-response") {
          socket.destroy();
          server.close();
          setTimeout(() => process.exit(0), 25);
        } else {
          sendFrame(socket, { id: message.id, result: { result: { type: "object", value: { requested: true } } } });
          server.close();
          setTimeout(() => process.exit(0), 100);
        }
      } else {
        sendFrame(socket, { id: message.id, error: { code: -32601, message: "Unexpected fixture method" } });
      }
    }
  };
  socket.on("data", (chunk) => { buffered = Buffer.concat([buffered, chunk]); consume(); });
  consume();
}

const server = http.createServer((request, response) => {
  const host = `127.0.0.1:${port}`;
  response.setHeader("Content-Type", "application/json");
  response.setHeader("Connection", "close");
  if (request.url === "/json/version") {
    response.end(JSON.stringify({ webSocketDebuggerUrl: `ws://${host}/devtools/browser/fixture` }));
    return;
  }
  if (request.url === "/json/list" || request.url === "/json") {
    const url = mode === "target-mismatch" ? "app://-/other.html" : "app://-/index.html";
    response.end(JSON.stringify([{ id: "fixture", type: "page", url, webSocketDebuggerUrl: `ws://${host}/devtools/page/fixture` }]));
    return;
  }
  response.statusCode = 404;
  response.end("{}");
});
server.on("upgrade", (request, socket, head) => {
  const key = request.headers["sec-websocket-key"];
  const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  consumeFrames(socket, head, request.url.includes("/browser/") ? "browser" : "page");
});
server.listen(port, "127.0.0.1", () => fs.writeFileSync(readyPath, String(process.pid)));
setInterval(() => { if (fs.existsSync(stopPath)) process.exit(0); }, 25).unref();
'@, [Text.UTF8Encoding]::new($false))

    $cooperative = Start-TestFixture -Mode cooperative -ExecutablePath $fixtureExecutable -Name cooperative -FixtureRecords $fixtureRecords
    if ($fixtureRecords.Count -ne 1) { throw 'The cooperative fixture identity was not tracked for cleanup.' }
    if ($cooperative.StartTimeFileTimeUtc -le 9007199254740992L) {
        throw 'The real Windows FILETIME fixture did not exceed the JSON safe-integer boundary.'
    }
    $startTimeString = $cooperative.StartTimeFileTimeUtc.ToString([Globalization.CultureInfo]::InvariantCulture)
    $exactConfig = New-AdapterConfig -Name exact -ProcessId $cooperative.Pid -StartTimeFileTimeUtc $startTimeString -ExecutablePath $cooperative.ExecutablePath
    $exactConfigJson = [IO.File]::ReadAllText($exactConfig)
    if ($exactConfigJson -notmatch '"startTimeFileTimeUtc"\s*:\s*"[0-9]{16,20}"') {
        throw 'The Windows FILETIME identity was not serialized as a decimal JSON string.'
    }
    $exactProbe = Invoke-PlatformAdapter -Action Probe -ConfigPath $exactConfig
    if (-not $exactProbe.Succeeded -or $exactProbe.Result.running -ne $true -or $exactProbe.Result.pid -ne $cooperative.Pid) {
        throw 'The platform adapter rejected an exact PID, path, and FILETIME identity.'
    }

    $wrongStart = ([long]$cooperative.StartTimeFileTimeUtc + 1L).ToString([Globalization.CultureInfo]::InvariantCulture)
    $wrongStartConfig = New-AdapterConfig -Name wrong-start -ProcessId $cooperative.Pid -StartTimeFileTimeUtc $wrongStart -ExecutablePath $cooperative.ExecutablePath
    $wrongStartProbe = Invoke-PlatformAdapter -Action Probe -ConfigPath $wrongStartConfig
    if (-not $wrongStartProbe.Succeeded -or $wrongStartProbe.Result.running -ne $false) {
        throw 'The platform adapter accepted a mismatched process start time.'
    }
    $wrongStartClose = Invoke-PlatformAdapter -Action Close -ConfigPath $wrongStartConfig
    if ($wrongStartClose.Succeeded -or -not (Test-TrackedFixtureAlive -Record $cooperative)) {
        throw 'A mismatched start time reached or terminated the fixture process.'
    }

    $wrongPathConfig = New-AdapterConfig -Name wrong-path -ProcessId $cooperative.Pid -StartTimeFileTimeUtc $startTimeString -ExecutablePath $alternateExecutable
    $wrongPathProbe = Invoke-PlatformAdapter -Action Probe -ConfigPath $wrongPathConfig
    if (-not $wrongPathProbe.Succeeded -or $wrongPathProbe.Result.running -ne $false) {
        throw 'The platform adapter accepted a mismatched executable path.'
    }

    $wrongPidConfig = New-AdapterConfig -Name wrong-pid -ProcessId $PID -StartTimeFileTimeUtc $startTimeString -ExecutablePath $cooperative.ExecutablePath
    $wrongPidProbe = Invoke-PlatformAdapter -Action Probe -ConfigPath $wrongPidConfig
    if (-not $wrongPidProbe.Succeeded -or $wrongPidProbe.Result.running -ne $false) {
        throw 'The platform adapter accepted a mismatched process ID.'
    }

    $cooperativeClose = Invoke-PlatformAdapter -Action Close -ConfigPath $exactConfig
    if (-not $cooperativeClose.Succeeded -or $cooperativeClose.Result.closed -ne $true -or
        $cooperativeClose.Result.method -cne 'WM_CLOSE' -or $cooperativeClose.Result.pid -ne $cooperative.Pid -or
        -not $cooperative.Process.WaitForExit(5000)) {
        throw 'WM_CLOSE did not gracefully close the cooperative exact-process fixture.'
    }

    $refusing = Start-TestFixture -Mode refuse -ExecutablePath $fixtureExecutable -Name refusing -FixtureRecords $fixtureRecords
    if ($fixtureRecords.Count -ne 2) { throw 'The refusing fixture identity was not tracked for cleanup.' }
    $refusingStart = $refusing.StartTimeFileTimeUtc.ToString([Globalization.CultureInfo]::InvariantCulture)
    $refusingConfig = New-AdapterConfig -Name refusing -ProcessId $refusing.Pid -StartTimeFileTimeUtc $refusingStart -ExecutablePath $refusing.ExecutablePath -CloseTimeoutMilliseconds 200
    $refusalTimer = [Diagnostics.Stopwatch]::StartNew()
    $refusingClose = Invoke-PlatformAdapter -Action Close -ConfigPath $refusingConfig
    $refusalTimer.Stop()
    $refusingAlive = Test-TrackedFixtureAlive -Record $refusing
    if ($refusingClose.Succeeded -or $refusalTimer.ElapsedMilliseconds -gt 5000 -or -not $refusingAlive) {
        throw "A refused WM_CLOSE was not bounded or the adapter force-terminated the fixture: succeeded=$($refusingClose.Succeeded) durationMs=$($refusalTimer.ElapsedMilliseconds) alive=$refusingAlive error=$($refusingClose.Error)"
    }

    $noWindow = Start-TestFixture -Mode no-window -ExecutablePath $fixtureExecutable -Name no-window -FixtureRecords $fixtureRecords
    if ($fixtureRecords.Count -ne 3) { throw 'The no-window fixture identity was not tracked for cleanup.' }
    $noWindowStart = $noWindow.StartTimeFileTimeUtc.ToString([Globalization.CultureInfo]::InvariantCulture)
    $noWindowConfig = New-AdapterConfig -Name no-window -ProcessId $noWindow.Pid -StartTimeFileTimeUtc $noWindowStart -ExecutablePath $noWindow.ExecutablePath -CloseTimeoutMilliseconds 200
    $noWindowTimer = [Diagnostics.Stopwatch]::StartNew()
    $noWindowClose = Invoke-PlatformAdapter -Action Close -ConfigPath $noWindowConfig
    $noWindowTimer.Stop()
    if ($noWindowClose.Succeeded -or $noWindowTimer.ElapsedMilliseconds -gt 5000 -or
        -not (Test-TrackedFixtureAlive -Record $noWindow)) {
        throw 'A fixture with no top-level window did not fail safely and remain running.'
    }

    $nativeQuit = Start-NativeQuitFixture -Mode quit -ExecutablePath $nativeFixtureExecutable -ScriptPath $nativeFixtureScript -FixtureRecords $nativeFixtureRecords
    $nativeQuitConfig = New-NativeAdapterConfig -Record $nativeQuit -CoordinatorNodePath $nodeSource
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $nativeQuitConfig) 'coordinator-ready.json')) {
        throw 'The native-quit fixture unexpectedly retained a transient coordinator receipt.'
    }
    $nativeQuitResult = Invoke-PlatformAdapter -Action Close -ConfigPath $nativeQuitConfig -NodePath $nodeSource
    if (-not $nativeQuitResult.Succeeded -or $nativeQuitResult.Result.closed -ne $true -or
        $nativeQuitResult.Result.method -cne 'native-renderer-quit' -or
        -not (Test-Path -LiteralPath $nativeQuit.QuitPath -PathType Leaf) -or
        -not $nativeQuit.Process.WaitForExit(5000)) {
        throw "The exact renderer bridge did not request the native ChatGPT quit path: $($nativeQuitResult.Error)"
    }

    $closedSocket = Start-NativeQuitFixture -Mode close-before-response -ExecutablePath $nativeFixtureExecutable -ScriptPath $nativeFixtureScript -FixtureRecords $nativeFixtureRecords
    $closedSocketConfig = New-NativeAdapterConfig -Record $closedSocket -CoordinatorNodePath $nodeSource
    $closedSocketResult = Invoke-PlatformAdapter -Action Close -ConfigPath $closedSocketConfig -NodePath $nodeSource
    if (-not $closedSocketResult.Succeeded -or $closedSocketResult.Result.closed -ne $true -or
        $closedSocketResult.Result.method -cne 'native-renderer-quit' -or
        -not (Test-Path -LiteralPath $closedSocket.QuitPath -PathType Leaf) -or
        -not $closedSocket.Process.WaitForExit(5000)) {
        throw "An expected debugger disconnect was not accepted only after exact-process exit: $($closedSocketResult.Error)"
    }

    $pidMismatch = Start-NativeQuitFixture -Mode pid-mismatch -ExecutablePath $nativeFixtureExecutable -ScriptPath $nativeFixtureScript -FixtureRecords $nativeFixtureRecords
    $pidMismatchConfig = New-NativeAdapterConfig -Record $pidMismatch -CoordinatorNodePath $nodeSource -CloseTimeoutMilliseconds 1000
    $pidMismatchResult = Invoke-PlatformAdapter -Action Close -ConfigPath $pidMismatchConfig -NodePath $nodeSource
    if ($pidMismatchResult.Succeeded -or -not (Test-TrackedFixtureAlive -Record $pidMismatch) -or
        (Test-Path -LiteralPath $pidMismatch.QuitPath -PathType Leaf)) {
        throw 'A debugger listener with the wrong browser PID reached the native quit command or terminated the exact process.'
    }

    $targetMismatch = Start-NativeQuitFixture -Mode target-mismatch -ExecutablePath $nativeFixtureExecutable -ScriptPath $nativeFixtureScript -FixtureRecords $nativeFixtureRecords
    $targetMismatchConfig = New-NativeAdapterConfig -Record $targetMismatch -CoordinatorNodePath $nodeSource -CloseTimeoutMilliseconds 1000
    $targetMismatchResult = Invoke-PlatformAdapter -Action Close -ConfigPath $targetMismatchConfig -NodePath $nodeSource
    if ($targetMismatchResult.Succeeded -or -not (Test-TrackedFixtureAlive -Record $targetMismatch) -or
        (Test-Path -LiteralPath $targetMismatch.QuitPath -PathType Leaf)) {
        throw 'A mismatched renderer target reached the native quit command or terminated the exact process.'
    }

    $ownerMismatchConfig = New-NativeAdapterConfig -Record $targetMismatch -CoordinatorNodePath $nodeSource -CloseTimeoutMilliseconds 1000 -Name 'native-socket-owner-mismatch'
    $ownerMismatchValue = Get-Content -LiteralPath $ownerMismatchConfig -Raw | ConvertFrom-Json
    $ownerMismatchValue.rendererPort = $pidMismatch.Port
    [IO.File]::WriteAllText($ownerMismatchConfig, (($ownerMismatchValue | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $ownerMismatchResult = Invoke-PlatformAdapter -Action Close -ConfigPath $ownerMismatchConfig -NodePath $nodeSource
    if ($ownerMismatchResult.Succeeded -or $ownerMismatchResult.Error -notmatch 'does not own the loopback debugger listener' -or
        -not (Test-TrackedFixtureAlive -Record $pidMismatch) -or -not (Test-TrackedFixtureAlive -Record $targetMismatch) -or
        (Test-Path -LiteralPath $pidMismatch.QuitPath -PathType Leaf) -or
        (Test-Path -LiteralPath $targetMismatch.QuitPath -PathType Leaf)) {
        throw 'A debugger listener owned by a different exact-path process was trusted or changed either fixture.'
    }

    $testResult = [ordered]@{
        ExactIdentityAccepted = $true
        FileTimeSerializedAsString = $true
        FileTimeExceedsJsonSafeInteger = $true
        MismatchedPidRejected = $true
        MismatchedStartTimeRejected = $true
        MismatchedPathRejected = $true
        CooperativeWindowClosedByWmClose = $true
        RefusedCloseStayedRunning = $true
        RefusalDurationMs = [long]$refusalTimer.ElapsedMilliseconds
        NoWindowFailedSafely = $true
        NoWindowDurationMs = [long]$noWindowTimer.ElapsedMilliseconds
        InvisibleFixture = $true
        NativeRendererQuit = $true
        NativeRendererSocketCloseAcceptedAfterExit = $true
        DebuggerOwnerPidMismatchStayedRunning = $true
        DebuggerSocketOwnerMismatchStayedRunning = $true
        RendererTargetMismatchStayedRunning = $true
    }
} catch {
    $testFailure = $_
} finally {
    try {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $parent = [IO.Path]::GetFullPath((Split-Path -Parent $resolved))
        $name = [IO.Path]::GetFileName($resolved)
        if ($parent -ne $temporary -or $name -notmatch '^chatgpt-remote-update-session-test-[0-9a-f]{32}$') {
            throw 'The fixture cleanup root failed validation.'
        }

        if (Test-Path -LiteralPath $resolved -PathType Container) {
            $allowedNames = @('cooperative', 'refusing', 'no-window')
            $allowedNativeModes = @('quit', 'close-before-response', 'pid-mismatch', 'target-mismatch')
            foreach ($record in $fixtureRecords) {
                if ([string]$record.Name -cnotin $allowedNames) { throw 'A tracked fixture name is invalid.' }
                $expectedStopPath = [IO.Path]::GetFullPath((Join-Path $resolved "$([string]$record.Name).stop"))
                if (-not [string]::Equals([IO.Path]::GetFullPath([string]$record.StopPath), $expectedStopPath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'A fixture stop path escaped the validated test root.'
                }
            }
            # Write every bounded fixture signal even if an earlier assertion
            # interrupted record construction. This never addresses a process;
            # process termination below still requires exact identity proof.
            foreach ($fixtureName in $allowedNames) {
                [IO.File]::WriteAllText((Join-Path $resolved "$fixtureName.stop"), 'stop', [Text.UTF8Encoding]::new($false))
            }
            foreach ($record in $nativeFixtureRecords) {
                if ([string]$record.Mode -cnotin $allowedNativeModes) { throw 'A tracked native fixture mode is invalid.' }
                $expectedExecutablePath = [IO.Path]::GetFullPath((Join-Path $resolved 'ChatGPT.exe'))
                $expectedStopPath = [IO.Path]::GetFullPath((Join-Path $resolved "native-$([string]$record.Mode).stop"))
                if (-not [string]::Equals([IO.Path]::GetFullPath([string]$record.ExecutablePath), $expectedExecutablePath, [StringComparison]::OrdinalIgnoreCase) -or
                    -not [string]::Equals([IO.Path]::GetFullPath([string]$record.StopPath), $expectedStopPath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'A native fixture identity escaped the validated test root.'
                }
            }
            foreach ($fixtureMode in $allowedNativeModes) {
                [IO.File]::WriteAllText((Join-Path $resolved "native-$fixtureMode.stop"), 'stop', [Text.UTF8Encoding]::new($false))
            }
        }

        foreach ($record in $fixtureRecords) {
            try {
                if (-not $record.Process.HasExited) { [void]$record.Process.WaitForExit(5000) }
            } catch {}
        }
        foreach ($record in $nativeFixtureRecords) {
            try {
                if (-not $record.Process.HasExited) { [void]$record.Process.WaitForExit(5000) }
            } catch {}
        }

        $fixtureExecutablePath = [IO.Path]::GetFullPath((Join-Path $resolved 'InvisibleWindowFixture.exe'))
        $allowedCommandLines = @(
            ('"{0}" cooperative {1} {2}' -f $fixtureExecutablePath,(Join-Path $resolved 'cooperative.ready'),(Join-Path $resolved 'cooperative.stop')),
            ('"{0}" refuse {1} {2}' -f $fixtureExecutablePath,(Join-Path $resolved 'refusing.ready'),(Join-Path $resolved 'refusing.stop')),
            ('"{0}" no-window {1} {2}' -f $fixtureExecutablePath,(Join-Path $resolved 'no-window.ready'),(Join-Path $resolved 'no-window.stop'))
        )
        $residualFixtures = @(
            Get-CimInstance Win32_Process -Filter "Name='InvisibleWindowFixture.exe'" -ErrorAction Stop |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
                    [string]::Equals([IO.Path]::GetFullPath([string]$_.ExecutablePath), $fixtureExecutablePath, [StringComparison]::OrdinalIgnoreCase)
                }
        )
        foreach ($candidate in $residualFixtures) {
            if (-not @($allowedCommandLines | Where-Object {
                [string]::Equals($_, [string]$candidate.CommandLine, [StringComparison]::OrdinalIgnoreCase)
            }).Count) {
                throw "Refusing to terminate unverified fixture PID $([int]$candidate.ProcessId)."
            }
            $actual = [Diagnostics.Process]::GetProcessById([int]$candidate.ProcessId)
            try {
                $actualPath = [IO.Path]::GetFullPath($actual.MainModule.FileName)
                if (-not [string]::Equals($actualPath, $fixtureExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Fixture PID $([int]$candidate.ProcessId) changed identity before cleanup."
                }
                if (-not $actual.WaitForExit(5000)) {
                    $actual.Refresh()
                    $actualPath = [IO.Path]::GetFullPath($actual.MainModule.FileName)
                    if (-not [string]::Equals($actualPath, $fixtureExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Fixture PID $([int]$candidate.ProcessId) changed identity before termination."
                    }
                    $actual.Kill()
                    [void]$actual.WaitForExit(5000)
                    $forcedCleanupCount += 1
                }
            } finally {
                $actual.Dispose()
            }
        }

        foreach ($record in $nativeFixtureRecords) {
            if ($record.Process.HasExited) { continue }
            $actual = [Diagnostics.Process]::GetProcessById([int]$record.Pid)
            try {
                $actualPath = [IO.Path]::GetFullPath($actual.MainModule.FileName)
                $actualStart = $actual.StartTime.ToUniversalTime().ToFileTimeUtc()
                if (-not [string]::Equals($actualPath, [string]$record.ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -or
                    $actualStart -ne [long]$record.StartTimeFileTimeUtc) {
                    throw "Native fixture PID $([int]$record.Pid) changed identity before cleanup."
                }
                $actual.Kill()
                [void]$actual.WaitForExit(5000)
                $forcedCleanupCount += 1
            } finally {
                $actual.Dispose()
            }
        }

        if (Test-Path -LiteralPath $resolved) {
            for ($attempt = 1; $attempt -le 50 -and (Test-Path -LiteralPath $resolved); $attempt += 1) {
                try {
                    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
                } catch {
                    if ($attempt -eq 50) { throw }
                    Start-Sleep -Milliseconds 100
                }
            }
        }
    } catch {
        $cleanupFailure = $_
    } finally {
        foreach ($record in $fixtureRecords) {
            try { $record.Process.Dispose() } catch {}
        }
        foreach ($record in $nativeFixtureRecords) {
            try { $record.Process.Dispose() } catch {}
        }
    }
}

if ($null -ne $testFailure) {
    if ($null -ne $cleanupFailure) {
        throw "Native Windows fixture test failed: $($testFailure.Exception.Message) Cleanup also failed: $($cleanupFailure.Exception.Message)"
    }
    throw $testFailure
}
if ($null -ne $cleanupFailure) { throw $cleanupFailure }
if ($forcedCleanupCount -ne 0) {
    throw "Fixture shutdown required $forcedCleanupCount forced cleanup operation(s)."
}
$testResult.CleanupForcedProcesses = $forcedCleanupCount
$global:LASTEXITCODE = 0
$testResult | ConvertTo-Json -Compress
