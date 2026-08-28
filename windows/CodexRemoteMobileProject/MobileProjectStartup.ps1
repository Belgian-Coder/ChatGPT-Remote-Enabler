[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Remove', 'Run', 'Probe')]
    [string]$Action = 'Probe',
    [string]$TargetUser,
    [ValidateRange(0, 300)]
    [int]$DelaySeconds = 30,
    [ValidateRange(5, 120)]
    [int]$MobileReadyTimeoutSeconds = 45,
    [string]$NodePath,
    [switch]$UseProxy,
    [switch]$ReplaceRunningApp
)

$ErrorActionPreference = 'Stop'
$taskName = 'Codex Remote Mobile Features at Logon'
$computerName = $env:COMPUTERNAME.ToUpperInvariant()

$bundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$bundleParent = Split-Path -Parent $bundleRoot
$stableController = Join-Path $bundleParent 'CodexRemoteSimple\CodexRemoteSimple.ps1'
$mobileController = Join-Path $bundleRoot 'MobileProjectView.ps1'
$maintenanceHelper = Join-Path $bundleRoot 'maintenance.js'
$updateController = Join-Path $bundleParent 'Update-ChatGPTRemote.ps1'
$proxyModule = Join-Path $bundleRoot 'ProxyConfiguration.psm1'
$logRoot = Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures'
$logPath = Join-Path $logRoot 'startup.log'
$rollbackRoot = Join-Path $bundleRoot 'rollback'

function Assert-Controllers {
    foreach ($path in @($stableController, $mobileController, $maintenanceHelper, $proxyModule)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required controller is missing: $path"
        }
    }
}

function Write-StartupLog {
    param([AllowEmptyString()][string]$Message)
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    [IO.File]::AppendAllText($logPath, "$Message$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
}

function Write-CommandOutput {
    param([object[]]$Output)
    foreach ($item in $Output) { Write-StartupLog ([string]$item) }
}

function Resolve-NodePath {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    $candidates = @(
        $NodePath,
        $(if ($command) { $command.Source }),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        'C:\Program Files\nodejs\node.exe'
    ) | Where-Object { $_ } | Select-Object -Unique
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        & $candidate -e 'process.exit(parseInt(process.versions.node) >= 22 && globalThis.WebSocket ? 0 : 1)' 2>$null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    throw 'Node.js 22 or newer with built-in WebSocket support was not found for the interactive user.'
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Install and Remove require an elevated Administrator PowerShell session.'
    }
}

function Get-TaskSummary {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [ordered]@{ host = $computerName; taskName = $taskName; installed = $false }
    }
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    return [ordered]@{
        host = $computerName
        taskName = $taskName
        installed = $true
        state = [string]$task.State
        user = [string]$task.Principal.UserId
        logonType = [string]$task.Principal.LogonType
        runLevel = [string]$task.Principal.RunLevel
        command = [string]$task.Actions[0].Execute
        arguments = [string]$task.Actions[0].Arguments
        lastRunTime = $info.LastRunTime
        lastTaskResult = $info.LastTaskResult
        nextRunTime = $info.NextRunTime
        logPath = '%LOCALAPPDATA%\CodexRemoteFeatures\startup.log (resolved for the task user at runtime)'
    }
}

switch ($Action) {
    'Run' {
        Write-StartupLog "$(Get-Date -Format o) [$computerName] startup run begins"
        try {
            if (Test-Path -LiteralPath $updateController -PathType Leaf) {
                try { Write-CommandOutput @(& $updateController -Action Auto 2>&1) }
                catch { Write-StartupLog "$(Get-Date -Format o) [$computerName] automatic update skipped: $($_.Exception.Message)" }
            }
            Assert-Controllers
            $node = Resolve-NodePath
            $proxyServer = $null
            if ($UseProxy) {
                Import-Module $proxyModule -Force
                $proxyServer = Get-ChatGPTRemoteProxy -AllowEnvironmentFallback
                foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
                    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
                }
                Write-StartupLog "$(Get-Date -Format o) [$computerName] protected Remote-only proxy configuration loaded"
            }
            Write-CommandOutput @(& $node --no-warnings $maintenanceHelper 2>&1)
            $appProcesses = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe' OR Name='Codex.exe'" -ErrorAction SilentlyContinue)
            $debugApp = @($appProcesses | Where-Object { $_.CommandLine -match '--remote-debugging-port(?:=|\s)' })
            if ($appProcesses.Count -gt 0 -and $debugApp.Count -eq 0 -and -not $ReplaceRunningApp) {
                throw 'ChatGPT/Codex is already running without the audited debug endpoint. Close it normally, then use ChatGPT Custom; startup will not terminate an active app.'
            }
            if ($debugApp.Count -eq 0) {
                for ($stableAttempt = 1; $stableAttempt -le 2; $stableAttempt++) {
                    try {
                        $stableArguments = @{
                            Action = 'Enable'
                            UseProxy = [bool]$UseProxy
                            Confirm = $false
                        }
                        if ($UseProxy) { $stableArguments.ProxyServer = $proxyServer }
                        Write-CommandOutput @(& $stableController @stableArguments 2>&1)
                        break
                    } catch {
                        if ($stableAttempt -ge 2) { throw }
                        Write-StartupLog "$(Get-Date -Format o) [$computerName] stable bridge not ready on attempt $stableAttempt; retrying once"
                        Start-Sleep -Seconds 2
                    }
                }
            } else {
                Write-StartupLog "$(Get-Date -Format o) [$computerName] audited debug session already running; preserving it"
            }
            $deadline = (Get-Date).AddSeconds($MobileReadyTimeoutSeconds)
            $attempt = 0
            while ($true) {
                $attempt++
                try {
                    Write-CommandOutput @(& $mobileController -Action Enable -NodePath $node -Confirm:$false 2>&1)
                    Write-CommandOutput @(& $mobileController -Action Probe -NodePath $node 2>&1)
                    break
                } catch {
                    if ((Get-Date) -ge $deadline) { throw }
                    Write-StartupLog "$(Get-Date -Format o) [$computerName] mobile view not ready on attempt $attempt; retrying"
                    Start-Sleep -Seconds 2
                }
            }
            Write-StartupLog "$(Get-Date -Format o) [$computerName] startup run completed"
        } catch {
            Write-StartupLog "$(Get-Date -Format o) [$computerName] startup run failed: $($_.Exception.Message)"
            throw
        }
    }
    'Install' {
        Assert-Administrator
        Assert-Controllers
        if (-not $TargetUser) {
            $TargetUser = (Get-CimInstance Win32_ComputerSystem).UserName
            if (-not $TargetUser) { $TargetUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        }
        if ($TargetUser -notmatch '^[^\\]+\\[^\\]+$') { throw 'TargetUser must use DOMAIN\user form.' }
        New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = Join-Path $rollbackRoot "startup-task-$computerName-$stamp.xml"
            Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath $backupPath -Encoding Unicode
        }
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) {
            throw "Built-in Windows PowerShell was not found: $powerShell"
        }
        $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action Run"
        if ($UseProxy) { $arguments += ' -UseProxy' }
        $taskAction = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $bundleRoot
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser
        if ($DelaySeconds -gt 0) { $trigger.Delay = "PT${DelaySeconds}S" }
        $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        if ($PSCmdlet.ShouldProcess("$computerName scheduled task '$taskName'", "register for $TargetUser")) {
            Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'Starts the audited Codex remote controller and mobile project view after interactive logon.' -Force | Out-Null
        }
        Get-TaskSummary | ConvertTo-Json -Depth 4
    }
    'Remove' {
        Assert-Administrator
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing -and $PSCmdlet.ShouldProcess("$computerName scheduled task '$taskName'", 'unregister')) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        Get-TaskSummary | ConvertTo-Json -Depth 4
    }
    'Probe' {
        Get-TaskSummary | ConvertTo-Json -Depth 4
    }
}
