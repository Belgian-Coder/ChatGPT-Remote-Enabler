[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NodePath,
    [Parameter(Mandatory)]
    [string]$ScriptPath,
    [Parameter(Mandatory)]
    [string]$ConfigPath,
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedConfigSha256,
    [ValidateRange(1, 30)]
    [int]$ReadyTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Assert-PlainLaunchPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if ($Path -match '[\x00\r\n"]') { throw "$Label contains unsupported characters." }
}

function Get-Sha256File {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Assert-NoReparsePoint {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$StopAt)
    $current = Get-NormalizedPath $Path
    $stop = (Get-NormalizedPath $StopAt).TrimEnd('\')
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The update-session launch path must not traverse a reparse point: $current"
        }
        if ([string]::Equals($current.TrimEnd('\'), $stop, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The update-session launch path escaped its trusted root.'
        }
        $current = $parent
    }
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Test-ExactCoordinator {
    param([int]$ProcessId, [long]$StartTimeFileTimeUtc, [string]$ExecutablePath)
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        try {
            return $process.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $StartTimeFileTimeUtc -and
                [string]::Equals((Get-NormalizedPath $process.MainModule.FileName), $ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
        } finally { $process.Dispose() }
    } catch { return $false }
}

$NodePath = Get-NormalizedPath $NodePath
$ScriptPath = Get-NormalizedPath $ScriptPath
$ConfigPath = Get-NormalizedPath $ConfigPath
foreach ($value in @($NodePath, $ScriptPath, $ConfigPath)) { Assert-PlainLaunchPath -Path $value -Label 'An update-session launch path' }
foreach ($file in @($NodePath, $ScriptPath, $ConfigPath)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "The update-session launch file is missing: $file" }
}

$stateRoot = Get-NormalizedPath (Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update-sessions')
$bundlesRoot = Get-NormalizedPath (Join-Path $stateRoot 'bundles')
$sessionsRoot = Get-NormalizedPath (Join-Path $stateRoot 'sessions')
$bundleRoot = Get-NormalizedPath (Split-Path -Parent $ScriptPath)
$sessionRoot = Get-NormalizedPath (Split-Path -Parent $ConfigPath)
if ([IO.Path]::GetFileName($ScriptPath) -cne 'update-session.js' -or
    [IO.Path]::GetFileName($ConfigPath) -cne 'session.json' -or
    [IO.Path]::GetFileName($bundleRoot) -notmatch '^[0-9a-f]{64}$' -or
    [IO.Path]::GetFileName($sessionRoot) -notmatch '^[0-9a-f]{32}$' -or
    -not [string]::Equals((Split-Path -Parent $bundleRoot), $bundlesRoot, [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals((Split-Path -Parent $sessionRoot), $sessionsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The update-session launch files are outside the owned bundle and session roots.'
}
Assert-NoReparsePoint -Path $ScriptPath -StopAt $stateRoot
Assert-NoReparsePoint -Path $ConfigPath -StopAt $stateRoot

$configHash = Get-Sha256File $ConfigPath
if ($configHash -cne $ExpectedConfigSha256.ToLowerInvariant()) { throw 'The update-session configuration changed before detached launch.' }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
$nodeHash = Get-Sha256File $NodePath
$scriptHash = Get-Sha256File $ScriptPath
if ($config.launchReceipt.nonce -notmatch '^[0-9a-f]{64}$' -or
    -not [string]::Equals((Get-NormalizedPath ([string]$config.launchReceipt.path)), (Join-Path $sessionRoot 'coordinator-ready.json'), [StringComparison]::OrdinalIgnoreCase) -or
    -not [string]::Equals((Get-NormalizedPath ([string]$config.launchReceipt.identityPath)), (Join-Path $sessionRoot 'coordinator-identity.json'), [StringComparison]::OrdinalIgnoreCase) -or
    [string]$config.launchReceipt.nodeSha256 -cne $nodeHash -or
    [string]$config.launchReceipt.scriptSha256 -cne $scriptHash) {
    throw 'The update-session launch receipt binding is invalid.'
}
$receiptPath = Get-NormalizedPath ([string]$config.launchReceipt.path)
$identityPath = Get-NormalizedPath ([string]$config.launchReceipt.identityPath)
Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue

$taskHostPath = Get-NormalizedPath (Join-Path $PSScriptRoot 'UpdateSessionTaskHost.exe')
if (-not (Test-Path -LiteralPath $taskHostPath -PathType Leaf)) { throw "The GUI update-session task host is missing: $taskHostPath" }
$taskArguments = '"{0}" "{1}" "{2}" {3} {4} {5} "{6}" {7}' -f $NodePath,$ScriptPath,$ConfigPath,$configHash,$nodeHash,$scriptHash,$identityPath,[string]$config.launchReceipt.nonce
$service = $null
$rootFolder = $null
$definition = $null
$registered = $null
$running = $null
$taskName = 'ChatGPTRemoteEnabler-UpdateSession-' + [guid]::NewGuid().ToString('N')
$coordinatorPid = 0
$coordinatorStart = 0L
$hostPid = 0
try {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $rootFolder = $service.GetFolder('\')
    $definition = $service.NewTask(0)
    $definition.RegistrationInfo.Description = 'Transient ChatGPT Remote update coordinator launch.'
    $definition.Principal.UserId = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $definition.Principal.LogonType = 3 # TASK_LOGON_INTERACTIVE_TOKEN
    $definition.Principal.RunLevel = 0 # TASK_RUNLEVEL_LUA
    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Settings.MultipleInstances = 2 # TASK_INSTANCES_IGNORE_NEW
    $action = $definition.Actions.Create(0)
    $action.Path = $taskHostPath
    $action.Arguments = $taskArguments
    $action.WorkingDirectory = $bundleRoot
    $registered = $rootFolder.RegisterTaskDefinition($taskName, $definition, 6, $null, $null, 3, $null)
    $running = $registered.Run($null)
    $pidDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $hostPid = [int]$running.EnginePID
        if ($hostPid -gt 0) {
            try {
                $hostProcess = [Diagnostics.Process]::GetProcessById($hostPid)
                try {
                    if (-not [string]::Equals((Get-NormalizedPath $hostProcess.MainModule.FileName), $taskHostPath, [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'Task Scheduler started an unexpected update-session task host.'
                    }
                    break
                } finally { $hostProcess.Dispose() }
            } catch [ArgumentException] { $hostPid = 0 }
        }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $pidDeadline)
    if ($hostPid -le 0) { throw 'Task Scheduler did not report the verified GUI task-host identity.' }
    $identityDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $identityPath -PathType Leaf) -and [DateTime]::UtcNow -lt $identityDeadline) { Start-Sleep -Milliseconds 25 }
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        try { $registered.Refresh() } catch {}
        $lastTaskResult = try { [int]$registered.LastTaskResult } catch { -1 }
        throw "The GUI task host did not report the hidden coordinator process identity (task result $lastTaskResult)."
    }
    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $coordinatorPid = [int]$identity.pid
    if ([string]$identity.nonce -cne [string]$config.launchReceipt.nonce -or $coordinatorPid -le 0 -or
        -not [long]::TryParse([string]$identity.startTimeFileTimeUtc, [ref]$coordinatorStart)) {
        throw 'The hidden coordinator process identity was invalid.'
    }
    $coordinator = [Diagnostics.Process]::GetProcessById($coordinatorPid)
    try {
        $actualNode = Get-NormalizedPath $coordinator.MainModule.FileName
        if (-not [string]::Equals($actualNode, $NodePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Task Scheduler started an unexpected update-session executable.'
        }
        if ($coordinator.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $coordinatorStart) {
            throw 'The hidden coordinator process start identity changed at launch.'
        }
    } finally { $coordinator.Dispose() }
} catch {
    if ($coordinatorPid -le 0 -and (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        try {
            $failedIdentity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ([string]$failedIdentity.nonce -ceq [string]$config.launchReceipt.nonce) {
                $failedStart = 0L
                if ([long]::TryParse([string]$failedIdentity.startTimeFileTimeUtc, [ref]$failedStart)) {
                    $coordinatorPid = [int]$failedIdentity.pid
                    $coordinatorStart = $failedStart
                }
            }
        } catch {}
    }
    if ($coordinatorPid -gt 0 -and (Test-ExactCoordinator -ProcessId $coordinatorPid -StartTimeFileTimeUtc $coordinatorStart -ExecutablePath $NodePath)) {
        Stop-Process -Id $coordinatorPid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $receiptPath,$identityPath -Force -ErrorAction SilentlyContinue
    throw
} finally {
    if ($rootFolder) { try { $rootFolder.DeleteTask($taskName, 0) } catch {} }
    foreach ($comObject in @($running, $registered, $definition, $rootFolder, $service)) {
        if ($comObject) { try { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) | Out-Null } catch {} }
    }
}

$deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
do {
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        try {
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($receipt.ready -eq $true -and [string]$receipt.nonce -ceq [string]$config.launchReceipt.nonce -and
                [string]$receipt.configSha256 -ceq $configHash -and [string]$receipt.nodeSha256 -ceq $nodeHash -and
                [string]$receipt.scriptSha256 -ceq $scriptHash -and [int]$receipt.pid -eq $coordinatorPid -and
                [string]$receipt.startTimeFileTimeUtc -ceq $coordinatorStart.ToString([Globalization.CultureInfo]::InvariantCulture)) {
                $coordinator = Get-Process -Id ([int]$receipt.pid) -ErrorAction Stop
                try {
                    $actualNode = Get-NormalizedPath $coordinator.MainModule.FileName
                    if (-not [string]::Equals($actualNode, $NodePath, [StringComparison]::OrdinalIgnoreCase) -or
                        $coordinator.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $coordinatorStart) {
                        throw 'The update-session coordinator executable did not match the verified Node path.'
                    }
                    Remove-Item -LiteralPath $receiptPath,$identityPath -Force -ErrorAction SilentlyContinue
                    [pscustomobject][ordered]@{
                        started = $true
                        processId = $coordinator.Id
                        processStartTimeFileTimeUtc = $coordinator.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
                        taskHostProcessId = $hostPid
                        configSha256 = $configHash
                    } | ConvertTo-Json -Compress
                    return
                } finally { $coordinator.Dispose() }
            }
        } catch [Management.Automation.RuntimeException] {}
    }
    Start-Sleep -Milliseconds 50
} while ([DateTime]::UtcNow -lt $deadline)

Remove-Item -LiteralPath $receiptPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $identityPath -Force -ErrorAction SilentlyContinue
if ($coordinatorPid -gt 0 -and (Test-ExactCoordinator -ProcessId $coordinatorPid -StartTimeFileTimeUtc $coordinatorStart -ExecutablePath $NodePath)) {
    Stop-Process -Id $coordinatorPid -Force -ErrorAction SilentlyContinue
}
throw "The detached update-session coordinator did not provide a verified readiness receipt within $ReadyTimeoutSeconds seconds."
