param(
    [switch]$Worker,
    [switch]$Execute,
    [string]$JobPath
)

$script:UnvirtualizedShortcutBrokerActive = $false

# Function-only when dot-sourced. The worker entry point is used by the
# Explorer shell broker and is intentionally limited to the existing
# shortcut/migration entry points below.

function Initialize-UnvirtualizedShortcutPathNative {
    if ('BelgianCoder.UnvirtualizedShortcutPathNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class UnvirtualizedShortcutPathResult
{
    public string FinalPath { get; set; }
}

namespace BelgianCoder
{
public static class UnvirtualizedShortcutPathNative
{
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string fileName, uint desiredAccess, uint shareMode,
        IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(IntPtr file, StringBuilder path, uint pathLength, uint flags);

    public static UnvirtualizedShortcutPathResult ReadFinalPath(string path)
    {
        IntPtr handle = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (handle == new IntPtr(-1))
        {
            int error = Marshal.GetLastWin32Error();
            throw new Win32Exception(error, "CreateFileW failed for " + path + " with Win32 error " + error + ".");
        }
        try
        {
            StringBuilder buffer = new StringBuilder(512);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "GetFinalPathNameByHandleW failed with Win32 error " + error + ".");
            }
            if (length >= buffer.Capacity)
            {
                buffer = new StringBuilder((int)length + 1);
                length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0 || length >= buffer.Capacity)
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error, "GetFinalPathNameByHandleW retry failed with Win32 error " + error + ".");
                }
            }
            return new UnvirtualizedShortcutPathResult { FinalPath = buffer.ToString() };
        }
        finally { CloseHandle(handle); }
    }
}
}
'@
}

function Get-UnvirtualizedShortcutPathIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    Initialize-UnvirtualizedShortcutPathNative
    $requested = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $requested)) { throw "The path does not exist: $requested" }
    $native = [BelgianCoder.UnvirtualizedShortcutPathNative]::ReadFinalPath($requested)
    [pscustomobject][ordered]@{
        RequestedPath = $requested
        FinalPath = [string]$native.FinalPath
        RedirectedToPackageCache = ([string]$native.FinalPath -match '(?i)\\AppData\\Local\\Packages\\[^\\]+\\LocalCache\\')
    }
}

function ConvertTo-UnvirtualizedShortcutPath {
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-UnvirtualizedShortcutWorkerPath {
    if ([string]::IsNullOrWhiteSpace($script:UnvirtualizedShortcutWorkerPath)) {
        $script:UnvirtualizedShortcutWorkerPath = [IO.Path]::GetFullPath($PSCommandPath)
    }
    if (-not (Test-Path -LiteralPath $script:UnvirtualizedShortcutWorkerPath -PathType Leaf)) {
        throw "The unvirtualized shortcut worker script is missing: $script:UnvirtualizedShortcutWorkerPath"
    }
    return $script:UnvirtualizedShortcutWorkerPath
}

function Assert-UnvirtualizedShortcutTempPath {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Worker artifact escaped the temporary directory: $resolved"
    }
}

function ConvertTo-UnvirtualizedShortcutInvocationArguments {
    param([object]$Arguments)
    $named = @{}
    if ($null -eq $Arguments) { return $named }
    foreach ($property in @($Arguments.PSObject.Properties)) {
        $value = $property.Value
        if ($null -eq $value) { continue }
        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $named[$property.Name] = @($value)
        } else {
            $named[$property.Name] = $value
        }
    }
    return $named
}

function Test-UnvirtualizedShortcutScriptPath {
    param([Parameter(Mandatory)][ValidateSet('MigrateShortcuts','TestEntryPoints','DesktopShortcutOperation','StartupShortcutOperation')][string]$Operation,
        [Parameter(Mandatory)][string]$ScriptPath)
    $leaf = [IO.Path]::GetFileName($ScriptPath)
    if ($Operation -in @('MigrateShortcuts','TestEntryPoints') -and $leaf -cne 'StableInstall.ps1') {
        throw "The $Operation worker requires StableInstall.ps1."
    }
    if ($Operation -eq 'DesktopShortcutOperation' -and $leaf -cne 'DesktopShortcut.ps1') {
        throw 'The DesktopShortcutOperation worker requires DesktopShortcut.ps1.'
    }
    if ($Operation -eq 'StartupShortcutOperation' -and $leaf -cne 'StartupShortcut.ps1') { throw 'StartupShortcutOperation requires StartupShortcut.ps1.' }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "The worker script is missing: $ScriptPath" }
}

function Test-UnvirtualizedShortcutArguments {
    param([Parameter(Mandatory)][string]$Operation, [object]$Arguments)
    $allowed = switch ($Operation) {
        'MigrateShortcuts' { @('StableRoot','DesktopPath','StartMenuPath','StartupPath','TaskPrimary') }
        'TestEntryPoints' { @('StableRoot','ShortcutPaths','TaskNames','StartupPath','RequiredStartMenuPath') }
        'DesktopShortcutOperation' { @('Action','DesktopPath','StartMenuPath','StableRoot','RollbackRoot','UseProxy','WhatIf','Confirm') }
        'StartupShortcutOperation' { @('Action','StartupPath','StableRoot','RollbackRoot','UseProxy','WhatIf','Confirm') }
    }
    foreach ($property in @($Arguments.PSObject.Properties)) {
        if ($property.Name -notin $allowed) { throw "Argument '$($property.Name)' is not allowed for $Operation." }
    }
    if ($Operation -in @('DesktopShortcutOperation','StartupShortcutOperation')) {
        if ([string]$Arguments.Action -notin @('Install','Remove','Probe')) { throw 'Shortcut operation requires Action Install, Remove, or Probe.' }
        if ($Arguments.PSObject.Properties['Confirm'] -and [bool]$Arguments.Confirm -and [string]$Arguments.Action -ne 'Probe') {
            throw 'Interactive confirmation is not supported for background shortcut registration. Use -WhatIf to preview, then run with -Confirm:$false.'
        }
    }
}

function New-UnvirtualizedShortcutWorkerJob {
    param([Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][object]$Arguments, [Parameter(Mandatory)][string[]]$ProbePaths,
        [Parameter(Mandatory)][string]$ResultPath, [Parameter(Mandatory)][int]$TimeoutMilliseconds)
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        Hop = 1
        Operation = $Operation
        ScriptPath = [IO.Path]::GetFullPath($ScriptPath)
        Arguments = $Arguments
        ProbePaths = @($ProbePaths | ForEach-Object { [IO.Path]::GetFullPath([string]$_) } | Select-Object -Unique)
        ResultPath = [IO.Path]::GetFullPath($ResultPath)
        DeadlineUtc = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds).ToString('o')
    }
}

function Invoke-UnvirtualizedShortcutWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('MigrateShortcuts','TestEntryPoints','DesktopShortcutOperation','StartupShortcutOperation')][string]$Operation,
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$Arguments = @{},
        [string[]]$ProbePaths = @(),
        [ValidateRange(1,60000)][int]$TimeoutMilliseconds = 15000
    )

    $ErrorActionPreference = 'Stop'
    if ($script:UnvirtualizedShortcutBrokerActive) { throw 'Unvirtualized shortcut broker recursion is forbidden.' }
    $script:UnvirtualizedShortcutBrokerActive = $true
    try {
        Test-UnvirtualizedShortcutScriptPath -Operation $Operation -ScriptPath $ScriptPath
    $argumentObject = [pscustomobject][ordered]@{}
    foreach ($key in $Arguments.Keys) {
        $value = $Arguments[$key]
        if ($value -is [Management.Automation.SwitchParameter]) { $value = [bool]$value }
        $argumentObject | Add-Member -NotePropertyName ([string]$key) -NotePropertyValue $value -Force
    }
    Test-UnvirtualizedShortcutArguments -Operation $Operation -Arguments $argumentObject
    if (@($ProbePaths | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) { throw 'ProbePaths cannot contain empty values.' }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-unvirtualized-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $jobPath = Join-Path $tempRoot 'job.json'
    $resultPath = Join-Path $tempRoot 'result.json'
    try {
        Assert-UnvirtualizedShortcutTempPath -Path $jobPath
        Assert-UnvirtualizedShortcutTempPath -Path $resultPath
        $job = New-UnvirtualizedShortcutWorkerJob -Operation $Operation -ScriptPath $ScriptPath -Arguments $argumentObject -ProbePaths @($ProbePaths) -ResultPath $resultPath -TimeoutMilliseconds $TimeoutMilliseconds
        [IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { throw "Windows PowerShell 5.1 is missing: $powershell" }
        $workerScript = Get-UnvirtualizedShortcutWorkerPath
        $quotedArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
            (ConvertTo-UnvirtualizedShortcutPath -Value $workerScript) +
            ' -Worker -JobPath ' + (ConvertTo-UnvirtualizedShortcutPath -Value $jobPath)

        # This is the existing interactive Explorer desktop shell, not a token
        # borrowed from another process. ShellExecute is asynchronous, so the
        # JSON result is the bounded completion handshake.
        $shell = $null; $windows = $null; $desktop = $null
        try {
            $shell = New-Object -ComObject Shell.Application
            $windows = $shell.Windows()
            $location = 0; $rootLocation = 0; $desktopHwnd = 0
            $desktop = $windows.FindWindowSW([ref]$location, [ref]$rootLocation, 8, [ref]$desktopHwnd, 1)
            if ($null -eq $desktop) { throw 'The interactive Explorer desktop shell was not found.' }
            [void]$desktop.Document.Application.ShellExecute($powershell, $quotedArgs, ([IO.Path]::GetDirectoryName($powershell)), 'open', 0)
        } finally {
            foreach ($comObject in @($desktop,$windows,$shell)) {
                if ($null -ne $comObject) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) } catch { } }
            }
        }

        # The shell worker supervises its own child and stops that exact child
        # at the job deadline. Allow time for its failure response and cleanup.
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds + 5000)
        while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            # Removing the job also prevents a late Explorer launch from
            # starting work. An already-started child has its own supervisor.
            throw "The $Operation worker did not finish within $TimeoutMilliseconds ms."
        }
        $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$result.SchemaVersion -ne 1 -or $null -eq $result.PSObject.Properties['ExitCode']) { throw 'The shortcut worker returned an invalid response.' }
        if ([int]$result.ExitCode -ne 0) { throw "The $Operation worker failed: $($result.Error)" }
        if ([string]$result.Operation -cne $Operation -or $null -eq $result.PSObject.Properties['Output']) { throw 'The shortcut worker response did not match the requested operation.' }
        return $result
    } finally {
        if (Test-Path -LiteralPath $tempRoot -PathType Container) {
            Assert-UnvirtualizedShortcutTempPath -Path $tempRoot
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    }
    finally {
        $script:UnvirtualizedShortcutBrokerActive = $false
    }
}

function Invoke-UnvirtualizedShortcutWorkerBody {
    param([Parameter(Mandatory)][string]$JobPath)
    $ErrorActionPreference = 'Stop'
    $job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$job.SchemaVersion -ne 1 -or [int]$job.Hop -ne 1) { throw 'Unsupported or recursive unvirtualized shortcut worker job.' }
    $deadlineUtc = if ($job.DeadlineUtc -is [DateTime]) {
        $job.DeadlineUtc.ToUniversalTime()
    } else {
        [DateTimeOffset]::Parse([string]$job.DeadlineUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    }
    if ([DateTime]::UtcNow -ge $deadlineUtc) { throw 'The unvirtualized shortcut worker job expired before mutation.' }
    $operation = [string]$job.Operation
    $scriptPath = [IO.Path]::GetFullPath([string]$job.ScriptPath)
    Test-UnvirtualizedShortcutScriptPath -Operation $operation -ScriptPath $scriptPath
    Test-UnvirtualizedShortcutArguments -Operation $operation -Arguments $job.Arguments

    $probeBefore = foreach ($probePath in @($job.ProbePaths)) {
        $identity = Get-UnvirtualizedShortcutPathIdentity -Path ([string]$probePath)
        if ($identity.RedirectedToPackageCache) { throw "The worker path is redirected before mutation: $($identity.RequestedPath) -> $($identity.FinalPath)" }
        $identity
    }

    $namedArguments = ConvertTo-UnvirtualizedShortcutInvocationArguments -Arguments $job.Arguments
    if ([DateTime]::UtcNow -ge $deadlineUtc) { throw 'The unvirtualized shortcut worker job expired before mutation.' }
    $hadBrokerFlag = $false
    $oldBrokerFlag = $null
    $existingBrokerFlag = Get-Variable -Name RemoteEnablerShortcutBrokerWorker -Scope Global -ErrorAction SilentlyContinue
    if ($existingBrokerFlag) { $hadBrokerFlag = $true; $oldBrokerFlag = $existingBrokerFlag.Value }
    $global:RemoteEnablerShortcutBrokerWorker = $true
    try {
        $output = if ($operation -in @('DesktopShortcutOperation','StartupShortcutOperation')) {
            @(& $scriptPath @namedArguments)
        } else {
            . $scriptPath
            $entryPoint = switch ($operation) {
                'MigrateShortcuts' { 'Invoke-StableShortcutMigration' }
                default { 'Test-StableEntryPointsMigrated' }
            }
            @(& $entryPoint @namedArguments)
        }
    } finally {
        if ($hadBrokerFlag) { $global:RemoteEnablerShortcutBrokerWorker = $oldBrokerFlag }
        else { Remove-Variable -Name RemoteEnablerShortcutBrokerWorker -Scope Global -Force -ErrorAction SilentlyContinue }
    }
    $probeAfter = foreach ($probePath in @($job.ProbePaths)) { Get-UnvirtualizedShortcutPathIdentity -Path ([string]$probePath) }
    $result = [ordered]@{
        SchemaVersion = 1
        ExitCode = 0
        Operation = $operation
        Output = @($output)
        ProbeBefore = @($probeBefore)
        ProbeAfter = @($probeAfter)
        WorkerProcessId = [Diagnostics.Process]::GetCurrentProcess().Id
    }
    $resultPath = [IO.Path]::GetFullPath([string]$job.ResultPath)
    Assert-UnvirtualizedShortcutTempPath -Path $resultPath
    $temporaryResultPath = $resultPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporaryResultPath, ($result | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryResultPath, $resultPath)
}

function Invoke-UnvirtualizedShortcutSupervisor {
    param([Parameter(Mandatory)][string]$JobPath)
    $job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $deadline = if ($job.DeadlineUtc -is [DateTime]) { $job.DeadlineUtc.ToUniversalTime() }
        else { [DateTimeOffset]::Parse([string]$job.DeadlineUtc, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
    $remaining = [Math]::Min(60000, [Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds))
    if ($remaining -le 0) { throw 'The unvirtualized shortcut worker job expired before mutation.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        (ConvertTo-UnvirtualizedShortcutPath -Value (Get-UnvirtualizedShortcutWorkerPath)) +
        ' -Worker -Execute -JobPath ' + (ConvertTo-UnvirtualizedShortcutPath -Value $JobPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $child = [Diagnostics.Process]::Start($start)
    try {
        if (-not $child.WaitForExit([int]$remaining)) {
            # This handle belongs to the child created above. It cannot target
            # ChatGPT, Explorer or a process merely reusing a discovered PID.
            $child.Kill()
            if (-not $child.WaitForExit(2000)) { throw 'The owned shortcut worker did not stop after its deadline.' }
            throw 'The shortcut worker exceeded its deadline and was stopped.'
        }
        if ($child.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $job.ResultPath -PathType Leaf)) {
            throw "The shortcut worker exited without a response (exit $($child.ExitCode))."
        }
    } finally { $child.Dispose() }
}

function Remove-UnvirtualizedShortcutJobArtifacts {
    param([Parameter(Mandatory)][string]$JobPath)
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($JobPath))
    Assert-UnvirtualizedShortcutTempPath -Path $directory
    if ([IO.Path]::GetFileName($JobPath) -cne 'job.json' -or
        [IO.Path]::GetFileName($directory) -notmatch '^chatgpt-remote-unvirtualized-[0-9a-f]{32}$') { return }
    # The caller normally consumes the response and removes this directory.
    # Also clean it when the caller timed out or exited before reading it.
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while ((Test-Path -LiteralPath $directory) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($Worker) {
    $workerExit = 0
    try {
        if ([string]::IsNullOrWhiteSpace($JobPath)) { throw 'The worker job path is required.' }
        if ($Execute) { Invoke-UnvirtualizedShortcutWorkerBody -JobPath $JobPath }
        else { Invoke-UnvirtualizedShortcutSupervisor -JobPath $JobPath }
    } catch {
        try {
            $job = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $failure = [ordered]@{ SchemaVersion = 1; ExitCode = 1; Error = $_.Exception.Message; WorkerProcessId = [Diagnostics.Process]::GetCurrentProcess().Id }
            $resultPath = [IO.Path]::GetFullPath([string]$job.ResultPath)
            Assert-UnvirtualizedShortcutTempPath -Path $resultPath
            $temporaryResultPath = $resultPath + '.tmp-' + [guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllText($temporaryResultPath, ($failure | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($temporaryResultPath, $resultPath)
        } catch { }
        $workerExit = 1
    } finally {
        if (-not $Execute -and -not [string]::IsNullOrWhiteSpace($JobPath)) {
            try { Remove-UnvirtualizedShortcutJobArtifacts -JobPath $JobPath } catch { }
        }
    }
    exit $workerExit
}
