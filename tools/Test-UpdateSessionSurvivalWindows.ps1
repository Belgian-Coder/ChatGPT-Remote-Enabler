[CmdletBinding()]
param(
    [switch]$MediumWorker,
    [string]$MediumResultPath,
    [string]$MediumErrorPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
trap {
    if ($MediumWorker -and -not [string]::IsNullOrWhiteSpace($MediumErrorPath)) {
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($MediumErrorPath), $_.Exception.ToString(), [Text.UTF8Encoding]::new($false))
        exit 1
    }
    throw $_.Exception
}
if ($env:OS -ne 'Windows_NT') { throw 'The update-session survival test requires Windows.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\UpdateSessionSurvivorLauncher.ps1'
$node = (Get-Command node.exe -ErrorAction Stop).Source
& $node -e 'process.exit(parseInt(process.versions.node) >= 22 ? 0 : 1)'
if ($LASTEXITCODE -ne 0) { throw 'The update-session survival test requires Node.js 22 or newer.' }

if (-not ('UpdateSessionSurvivalNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class UpdateSessionSurvivalNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool DuplicateTokenEx(IntPtr existing, uint access, IntPtr attributes, int level, int type, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessWithTokenW(IntPtr token, uint logonFlags, string applicationName, StringBuilder commandLine,
        uint creationFlags, IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr handle);

    public static int RunMedium(string application, string commandLine, string currentDirectory, int timeoutMilliseconds)
    {
        IntPtr shell = GetShellWindow(); uint shellPid;
        if (shell == IntPtr.Zero || GetWindowThreadProcessId(shell, out shellPid) == 0 || shellPid == 0) throw new InvalidOperationException("Explorer identity unavailable.");
        IntPtr source = IntPtr.Zero, token = IntPtr.Zero, primary = IntPtr.Zero;
        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
        try
        {
            source = OpenProcess(0x1000, false, shellPid);
            if (source == IntPtr.Zero || !OpenProcessToken(source, 0x0001 | 0x0002 | 0x0008, out token) ||
                !DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out primary))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not duplicate the interactive Explorer token.");
            STARTUPINFO si = new STARTUPINFO(); si.cb = Marshal.SizeOf(typeof(STARTUPINFO)); si.dwFlags = 1; si.wShowWindow = 0;
            if (!CreateProcessWithTokenW(primary, 0, application, new StringBuilder(commandLine), 0x08000000, IntPtr.Zero, currentDirectory, ref si, out pi))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the medium-token test worker.");
            uint wait = WaitForSingleObject(pi.hProcess, (uint)timeoutMilliseconds);
            if (wait == 0x102) { TerminateProcess(pi.hProcess, 1460); WaitForSingleObject(pi.hProcess, 5000); throw new TimeoutException(); }
            if (wait != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint exitCode; if (!GetExitCodeProcess(pi.hProcess, out exitCode)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return (int)exitCode;
        }
        finally
        {
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread); if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            if (primary != IntPtr.Zero) CloseHandle(primary); if (token != IntPtr.Zero) CloseHandle(token); if (source != IntPtr.Zero) CloseHandle(source);
        }
    }
}

public static class UpdateSessionVisibleConsoleMonitor
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int maximum);
    private static readonly object Gate = new object();
    private static HashSet<int> baseline;
    private static HashSet<int> observed;
    private static Thread thread;
    private static volatile bool stopping;

    private static HashSet<int> Snapshot()
    {
        var values = new HashSet<int>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            if (!IsWindowVisible(window)) return true;
            var name = new StringBuilder(128);
            if (GetClassName(window, name, name.Capacity) > 0 &&
                (name.ToString() == "ConsoleWindowClass" || name.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS")) {
                uint processId; GetWindowThreadProcessId(window, out processId);
                if (processId > 0) values.Add((int)processId);
            }
            return true;
        }, IntPtr.Zero);
        return values;
    }

    public static void Start()
    {
        baseline = Snapshot(); observed = new HashSet<int>(); stopping = false;
        thread = new Thread(delegate() {
            while (!stopping) {
                foreach (int processId in Snapshot()) if (!baseline.Contains(processId)) lock (Gate) observed.Add(processId);
                Thread.Sleep(10);
            }
        });
        thread.IsBackground = true;
        thread.Start();
    }

    public static int[] Stop()
    {
        stopping = true;
        if (thread != null) thread.Join(2000);
        lock (Gate) { var values = new int[observed.Count]; observed.CopyTo(values); return values; }
    }
}
'@
}

if (-not $MediumWorker) {
    $mediumResult = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-update-survival-medium-' + [guid]::NewGuid().ToString('N') + '.json')
    $mediumError = "$mediumResult.error"
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $commandLine = '"{0}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -MediumWorker -MediumResultPath "{2}" -MediumErrorPath "{3}"' -f $windowsPowerShell,$PSCommandPath,$mediumResult,$mediumError
    try {
        $exitCode = [UpdateSessionSurvivalNative]::RunMedium($windowsPowerShell, $commandLine, $PSScriptRoot, 60000)
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $mediumResult -PathType Leaf)) {
            $detail = if (Test-Path -LiteralPath $mediumError -PathType Leaf) { Get-Content -LiteralPath $mediumError -Raw } else { 'No worker error record was written.' }
            throw "The medium-token survival worker failed with exit code $exitCode. $detail"
        }
        Get-Content -LiteralPath $mediumResult -Raw
        return
    } finally { Remove-Item -LiteralPath $mediumResult,$mediumError -Force -ErrorAction SilentlyContinue }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Wait-File {
    param([string]$Path, [int]$Seconds = 15, [string]$FailurePath)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        if ($FailurePath -and (Test-Path -LiteralPath $FailurePath -PathType Leaf)) {
            throw (Get-Content -LiteralPath $FailurePath -Raw)
        }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for test evidence: $Path"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-update-survival-' + [guid]::NewGuid().ToString('N'))
$coordinatorProcess = $null
$initiator = $null
$job = [IntPtr]::Zero
$stopPath = $null
$visibleMonitorStarted = $false
$createdBundleRoots = [Collections.Generic.List[string]]::new()
$createdSessionRoots = [Collections.Generic.List[string]]::new()
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $stateRoot = Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update-sessions'
    $bundleRoot = Join-Path (Join-Path $stateRoot 'bundles') ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
    $sessionRoot = Join-Path (Join-Path $stateRoot 'sessions') ([guid]::NewGuid().ToString('N'))
    $createdBundleRoots.Add($bundleRoot)
    $createdSessionRoots.Add($sessionRoot)
    New-Item -ItemType Directory -Path $bundleRoot,$sessionRoot -Force | Out-Null
    $scriptPath = Join-Path $bundleRoot 'update-session.js'
    $configPath = Join-Path $sessionRoot 'session.json'
    $receiptPath = Join-Path $sessionRoot 'coordinator-ready.json'
    $triggerPath = Join-Path $sessionRoot 'initiator-terminated.trigger'
    $survivedPath = Join-Path $sessionRoot 'relaunched-descendant-survived.marker'
    $relaunchResultPath = Join-Path $sessionRoot 'relaunch-result.json'
    $relaunchWorkloadPath = Join-Path $sessionRoot 'relaunch-workload.json'
    $stopPath = Join-Path $sessionRoot 'stop.trigger'
    $initiatorResultPath = Join-Path $sessionRoot 'initiator-result.json'
    $initiatorErrorPath = Join-Path $sessionRoot 'initiator-error.txt'
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\update-session.js') -Destination (Join-Path $bundleRoot 'update-session-runtime.js')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\update-session-cdp.js') -Destination (Join-Path $bundleRoot 'update-session-cdp.js')
    $fixtureDirectory = Join-Path $bundleRoot 'fixture scripts'
    New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
    $descendantScript = Join-Path $fixtureDirectory 'descendant.ps1'
    Write-Utf8File $descendantScript @'
$coordinatorId = [int]$env:TEST_RELAUNCH_COORDINATOR_PID
$deadline = [DateTime]::UtcNow.AddSeconds(15)
while ((Get-Process -Id $coordinatorId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 25
}
if (Get-Process -Id $coordinatorId -ErrorAction SilentlyContinue) { exit 71 }
[IO.File]::WriteAllText($env:TEST_RELAUNCH_SURVIVED_PATH, [string]$PID, [Text.UTF8Encoding]::new($false))
'@
    $relaunchFixture = @'
[CmdletBinding()]
param(
    [ValidateSet('Run')][string]$Action,
    [switch]$UseProxy,
    [switch]$UpdateResume,
    [switch]$SkipUpdateCheckOnce,
    [string]$RelaunchHandoffPath
)
$ErrorActionPreference = 'Stop'
if ($MyInvocation.MyCommand.Name -like 'Failure*') { exit 0 }
if ($Action -cne 'Run' -or -not $UseProxy -or -not $UpdateResume -or -not $SkipUpdateCheckOnce) { exit 72 }
if ([IO.Path]::GetFullPath($RelaunchHandoffPath) -cne [IO.Path]::GetFullPath($env:TEST_RELAUNCH_HANDOFF_PATH)) { exit 73 }
$evidence = [ordered]@{ action = $Action; useProxy = [bool]$UseProxy; updateResume = [bool]$UpdateResume; skipUpdateCheckOnce = [bool]$SkipUpdateCheckOnce; hidden = $true }
[IO.File]::WriteAllText($env:TEST_RELAUNCH_WORKLOAD_PATH, ($evidence | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$descendantArgument = '"' + $env:TEST_RELAUNCH_DESCENDANT_SCRIPT + '"'
Start-Process -FilePath $shell -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$descendantArgument) -WindowStyle Hidden | Out-Null
$handoff = [ordered]@{ ready = $true; entryPointRelative = $env:TEST_RELAUNCH_ENTRY_POINT }
[IO.File]::WriteAllText($RelaunchHandoffPath, ($handoff | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
'@
    Write-Utf8File (Join-Path $fixtureDirectory 'MobileProjectStartup.ps1') $relaunchFixture
    Write-Utf8File (Join-Path $fixtureDirectory 'FailureStartup.ps1') $relaunchFixture
    $fixtureSource = @'
"use strict";
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { PlatformAdapter } = require("./update-session-runtime.js");
const args = process.argv.slice(2);
const value = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const configPath = path.resolve(value("--config"));
const expectedConfig = value("--expected-config-sha256");
const configBytes = fs.readFileSync(configPath);
const configHash = crypto.createHash("sha256").update(configBytes).digest("hex");
if (configHash !== expectedConfig) process.exit(41);
const config = JSON.parse(configBytes);
const digest = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
let identity;
for (let i = 0; i < 200 && !identity; i += 1) {
  try { identity = JSON.parse(fs.readFileSync(config.launchReceipt.identityPath)); } catch {}
  if (!identity) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
}
if (!identity || identity.pid !== process.pid || identity.nonce !== config.launchReceipt.nonce) process.exit(42);
const receipt = {
  ready: true, nonce: config.launchReceipt.nonce, pid: process.pid,
  startTimeFileTimeUtc: identity.startTimeFileTimeUtc,
  configSha256: configHash, nodeSha256: digest(process.execPath), scriptSha256: digest(__filename),
};
fs.writeFileSync(config.launchReceipt.path, JSON.stringify(receipt));
while (!fs.existsSync(config.test.triggerPath)) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
(async () => {
  process.env.TEST_RELAUNCH_COORDINATOR_PID = String(process.pid);
  process.env.TEST_RELAUNCH_SURVIVED_PATH = config.test.survivedPath;
  process.env.TEST_RELAUNCH_WORKLOAD_PATH = config.test.workloadPath;
  process.env.TEST_RELAUNCH_DESCENDANT_SCRIPT = config.test.descendantScript;
  process.env.TEST_RELAUNCH_ENTRY_POINT = config.test.successEntry;
  const base = {
    platform: "win32", installRoot: config.test.installRoot, sessionDirectory: config.test.sessionDirectory,
    rendererPort: 9222, relaunch: { entryPointRelative: config.test.successEntry, useProxy: true },
  };
  process.env.TEST_RELAUNCH_HANDOFF_PATH = path.join(base.sessionDirectory, "relaunch-handoff.json");
  const success = await new PlatformAdapter(base).relaunch();
  let failureMessage = null;
  try {
    await new PlatformAdapter({ ...base, relaunch: { entryPointRelative: config.test.failureEntry } }).relaunch();
  } catch (error) { failureMessage = error.message; }
  const expected = "The updated launcher exited before readiness handoff (exit 0).";
  if (failureMessage !== expected) throw new Error(`Unexpected no-handoff failure: ${failureMessage}`);
  fs.writeFileSync(config.test.resultPath, JSON.stringify({ successEntry: success.entry, failureMessage }));
})().catch((error) => { fs.writeFileSync(config.test.errorPath, error.stack || error.message); process.exitCode = 1; });
'@
    Write-Utf8File $scriptPath $fixtureSource
    $config = [ordered]@{
        launchReceipt = [ordered]@{
            path = $receiptPath
            identityPath = Join-Path $sessionRoot 'coordinator-identity.json'
            nonce = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
            nodeSha256 = (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
            scriptSha256 = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
            expiresAtUnixMs = [DateTimeOffset]::UtcNow.AddSeconds(30).ToUnixTimeMilliseconds()
        }
        test = [ordered]@{
            triggerPath = $triggerPath
            survivedPath = $survivedPath
            stopPath = $stopPath
            workloadPath = $relaunchWorkloadPath
            resultPath = $relaunchResultPath
            errorPath = $initiatorErrorPath
            descendantScript = $descendantScript
            installRoot = $bundleRoot
            sessionDirectory = $sessionRoot
            successEntry = 'fixture scripts\MobileProjectStartup.ps1'
            failureEntry = 'fixture scripts\FailureStartup.ps1'
        }
    }
    Write-Utf8File $configPath (($config | ConvertTo-Json -Depth 6) + "`n")
    $configHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()

    # The initiating PowerShell is assigned to a real Windows Job. It asks the
    # verified Explorer broker to launch the coordinator and records the receipt.
    $initiatorScript = Join-Path $testRoot 'initiator.ps1'
    Write-Utf8File $initiatorScript @"
`$ErrorActionPreference = 'Stop'
try {
  `$result = & '$($launcher.Replace("'", "''"))' -NodePath '$($node.Replace("'", "''"))' -ScriptPath '$($scriptPath.Replace("'", "''"))' -ConfigPath '$($configPath.Replace("'", "''"))' -ExpectedConfigSha256 '$configHash'
  [IO.File]::WriteAllText('$($initiatorResultPath.Replace("'", "''"))', [string]`$result, [Text.UTF8Encoding]::new(`$false))
  while (`$true) { Start-Sleep -Seconds 1 }
} catch {
  [IO.File]::WriteAllText('$($initiatorErrorPath.Replace("'", "''"))', `$_.Exception.ToString(), [Text.UTF8Encoding]::new(`$false))
  exit 1
}
"@
    [UpdateSessionVisibleConsoleMonitor]::Start()
    $visibleMonitorStarted = $true
    $initiator = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$initiatorScript) -WindowStyle Hidden -PassThru
    $job = [UpdateSessionSurvivalNative]::CreateJobObject([IntPtr]::Zero, $null)
    if ($job -eq [IntPtr]::Zero) { throw "CreateJobObject failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    if (-not [UpdateSessionSurvivalNative]::AssignProcessToJobObject($job, $initiator.Handle)) {
        throw "AssignProcessToJobObject failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $inJob = $false
    if (-not [UpdateSessionSurvivalNative]::IsProcessInJob($initiator.Handle, $job, [ref]$inJob) -or -not $inJob) {
        throw 'The initiating fixture was not proven inside its assigned Windows Job.'
    }
    Wait-File $initiatorResultPath -FailurePath $initiatorErrorPath
    if (Test-Path -LiteralPath $initiatorErrorPath) { throw (Get-Content -LiteralPath $initiatorErrorPath -Raw) }
    $launch = Get-Content -LiteralPath $initiatorResultPath -Raw | ConvertFrom-Json
    $hostDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ((Get-Process -Id ([int]$launch.taskHostProcessId) -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $hostDeadline) {
        Start-Sleep -Milliseconds 25
    }
    if (Get-Process -Id ([int]$launch.taskHostProcessId) -ErrorAction SilentlyContinue) {
        throw 'The transient GUI task host did not exit after handing off the coordinator.'
    }
    $coordinatorProcess = Get-Process -Id ([int]$launch.processId) -ErrorAction Stop
    $coordinatorInJob = $true
    if (-not [UpdateSessionSurvivalNative]::IsProcessInJob($coordinatorProcess.Handle, $job, [ref]$coordinatorInJob)) {
        throw "IsProcessInJob failed for the coordinator: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    if ($coordinatorInJob) { throw 'The Explorer-launched coordinator remained in the initiating Windows Job.' }

    if (-not [UpdateSessionSurvivalNative]::TerminateJobObject($job, 93)) {
        throw "TerminateJobObject failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $initiator.WaitForExit(5000) | Out-Null
    Write-Utf8File $triggerPath 'terminated'
    Wait-File $relaunchResultPath -FailurePath $initiatorErrorPath
    if (-not $coordinatorProcess.WaitForExit(5000)) { throw 'The coordinator did not exit after the relaunch handoff test.' }
    if ($coordinatorProcess.ExitCode -ne 0) { throw "The coordinator relaunch test exited with code $($coordinatorProcess.ExitCode)." }
    Wait-File $survivedPath -FailurePath $initiatorErrorPath
    Wait-File $relaunchWorkloadPath -FailurePath $initiatorErrorPath
    $relaunchEvidence = Get-Content -LiteralPath $relaunchWorkloadPath -Raw | ConvertFrom-Json
    if ($relaunchEvidence.action -cne 'Run' -or -not $relaunchEvidence.useProxy -or -not $relaunchEvidence.updateResume -or -not $relaunchEvidence.skipUpdateCheckOnce) {
        throw 'The real Windows relaunch fixture did not receive the exact protected update-resume arguments.'
    }
    $relaunchEvidence = Get-Content -LiteralPath $relaunchResultPath -Raw | ConvertFrom-Json
    if ($relaunchEvidence.failureMessage -cne 'The updated launcher exited before readiness handoff (exit 0).') {
        throw 'A Windows launcher exit without a handoff was not rejected with the expected error.'
    }
    $residualTasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.TaskName -like 'ChatGPTRemoteEnabler-LaunchWorker-*' -or $_.TaskName -like 'ChatGPTRemoteEnabler-UpdateSession-*'
    })
    if ($residualTasks.Count -ne 0) { throw 'A transient ChatGPT Remote broker task remained registered after launch.' }

    # Altering the verified entrypoint after binding must fail before ShellExecute.
    $tamperedScript = Join-Path (Join-Path $stateRoot 'bundles') ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
    $createdBundleRoots.Add($tamperedScript)
    New-Item -ItemType Directory -Path $tamperedScript | Out-Null
    $tamperedScript = Join-Path $tamperedScript 'update-session.js'
    Copy-Item -LiteralPath $scriptPath -Destination $tamperedScript
    $tamperedSession = Join-Path (Join-Path $stateRoot 'sessions') ([guid]::NewGuid().ToString('N'))
    $createdSessionRoots.Add($tamperedSession)
    New-Item -ItemType Directory -Path $tamperedSession | Out-Null
    $tamperedConfigPath = Join-Path $tamperedSession 'session.json'
    $tamperedReceipt = Join-Path $tamperedSession 'coordinator-ready.json'
    $tamperedConfig = [ordered]@{
        launchReceipt = [ordered]@{
            path = $tamperedReceipt
            identityPath = Join-Path $tamperedSession 'coordinator-identity.json'
            nonce = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
            nodeSha256 = (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
            scriptSha256 = (Get-FileHash -LiteralPath $tamperedScript -Algorithm SHA256).Hash.ToLowerInvariant()
            expiresAtUnixMs = [DateTimeOffset]::UtcNow.AddSeconds(30).ToUnixTimeMilliseconds()
        }
    }
    Write-Utf8File $tamperedConfigPath (($tamperedConfig | ConvertTo-Json -Depth 5) + "`n")
    $tamperedConfigHash = (Get-FileHash -LiteralPath $tamperedConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Content -LiteralPath $tamperedScript -Value '// changed after verification'
    $tamperRejected = $false
    $tamperError = $null
    try {
        & $launcher -NodePath $node -ScriptPath $tamperedScript -ConfigPath $tamperedConfigPath -ExpectedConfigSha256 $tamperedConfigHash | Out-Null
    } catch { $tamperError = $_.Exception.Message; $tamperRejected = $true }
    if (-not $tamperRejected -or (Test-Path -LiteralPath $tamperedReceipt)) {
        throw "A coordinator entrypoint changed after hash binding was not rejected before launch. error=$tamperError"
    }
    $newVisibleConsoles = @([UpdateSessionVisibleConsoleMonitor]::Stop())
    $visibleMonitorStarted = $false
    if ($newVisibleConsoles.Count -ne 0) { throw "The hidden broker opened a visible console window (window-owner PIDs: $($newVisibleConsoles -join ','))." }

    $isAdministrator = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdministrator) { throw 'The survival fixture did not run with the required medium user token.' }
    $summary = [pscustomobject][ordered]@{
        MediumTokenWorker = $true
        InitiatorAssignedToJob = $true
        CoordinatorOutsideInitiatorJob = $true
        CoordinatorSurvivedTaskHostExit = $true
        CoordinatorSurvivedTerminateJobObject = $true
        RealWindowsRelaunchExecuted = $true
        RelaunchedDescendantSurvivedCoordinatorExit = $true
        MissingRelaunchHandoffRejected = $true
        VerifiedEntrypointTamperRejected = $true
        NoTransientTaskResidual = $true
        NoVisibleConsoleWindowObserved = $true
        CoordinatorProcessId = [int]$launch.processId
    } | ConvertTo-Json -Compress
    if ([string]::IsNullOrWhiteSpace($MediumResultPath)) { $summary }
    else { [IO.File]::WriteAllText([IO.Path]::GetFullPath($MediumResultPath), $summary, [Text.UTF8Encoding]::new($false)) }
} finally {
    if ($visibleMonitorStarted) { [void][UpdateSessionVisibleConsoleMonitor]::Stop() }
    if ($stopPath) { Write-Utf8File $stopPath 'stop' }
    if ($coordinatorProcess) {
        try { if (-not $coordinatorProcess.WaitForExit(5000)) { $coordinatorProcess.Kill() } } catch {}
        $coordinatorProcess.Dispose()
    }
    if ($initiator) {
        try { if (-not $initiator.HasExited) { $initiator.Kill() } } catch {}
        $initiator.Dispose()
    }
    if ($job -ne [IntPtr]::Zero) { [void][UpdateSessionSurvivalNative]::CloseHandle($job) }
    foreach ($ownedSession in $createdSessionRoots) {
        if ($ownedSession -and [IO.Path]::GetFileName($ownedSession) -match '^[0-9a-f]{32}$' -and (Test-Path -LiteralPath $ownedSession)) {
            Remove-Item -LiteralPath $ownedSession -Recurse -Force
        }
    }
    foreach ($ownedBundle in $createdBundleRoots) {
        if ($ownedBundle -and [IO.Path]::GetFileName($ownedBundle) -match '^[0-9a-f]{64}$' -and (Test-Path -LiteralPath $ownedBundle)) {
            Remove-Item -LiteralPath $ownedBundle -Recurse -Force
        }
    }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
