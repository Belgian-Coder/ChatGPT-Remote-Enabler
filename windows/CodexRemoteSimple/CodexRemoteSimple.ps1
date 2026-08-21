[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Enable', 'Rollback')]
    [string]$Action = 'Check',

    [string]$NodePath,

    [ValidateRange(5, 60)]
    [int]$TimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$script:RuntimeRoot = Join-Path $script:BundleRoot 'runtime'
$script:StatePath = Join-Path $script:BundleRoot '.codexremote-simple-session.json'

function Get-CrsPackage {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
    if ($packages.Count -ne 1) {
        throw "Expected exactly one current-user OpenAI.Codex package; found $($packages.Count)."
    }

    $package = $packages[0]
    $installRoot = [IO.Path]::GetFullPath([string]$package.InstallLocation)
    $executable = [IO.Path]::GetFullPath((Join-Path $installRoot 'app\ChatGPT.exe'))
    $appAsar = [IO.Path]::GetFullPath((Join-Path $installRoot 'app\resources\app.asar'))
    $nativeRoot = [IO.Path]::GetFullPath((Join-Path $installRoot 'app\resources\native'))
    foreach ($path in @($executable, $appAsar, $nativeRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "The installed Codex package is incomplete: $path"
        }
    }

    [pscustomobject][ordered]@{
        FullName = [string]$package.PackageFullName
        FamilyName = [string]$package.PackageFamilyName
        Version = [string]$package.Version
        InstallRoot = $installRoot
        ExecutablePath = $executable
        AppAsarPath = $appAsar
        NativeRoot = $nativeRoot
    }
}

function Resolve-CrsNode {
    param([string]$RequestedPath)

    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates.Add($RequestedPath)
    }
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        $candidates.Add([string]$command.Source)
    }
    foreach ($candidate in @(
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe')
    )) {
        $candidates.Add($candidate)
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            $fullPath = [IO.Path]::GetFullPath($candidate)
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
            $version = (& $fullPath --version 2>$null | Select-Object -First 1).Trim()
            if ($version -notmatch '^v(?<major>\d+)\.\d+\.\d+') { continue }
            if ([int]$Matches.major -lt 22) { continue }
            return [pscustomobject]@{ Path = $fullPath; Version = $version }
        } catch {
            continue
        }
    }
    throw 'Node.js 22 or newer was not found. Pass its absolute path with -NodePath.'
}

function Test-CrsCompatibility {
    param($Package, $Node)

    $checker = Join-Path $script:RuntimeRoot 'check-package.mjs'
    if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
        throw "Compatibility checker is missing: $checker"
    }

    $output = @(& $Node.Path $checker $Package.AppAsarPath $Package.NativeRoot 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        throw 'The Codex package compatibility checker failed.'
    }
    $result = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
    if ($result.schemaVersion -ne 1 -or $result.classification -cne 'CandidateCompatible' -or
        $result.affected -isnot [bool] -or -not $result.affected -or
        $result.appAsarSha256 -isnot [string] -or $result.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'This Codex build does not match the audited Windows compatibility signature. Refusing to inject.'
    }
    return $result
}

function Get-CrsFreePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Test-CrsPortOpen {
    param([int]$Port, [int]$TimeoutMilliseconds = 250)

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) { return $false }
        try { $client.EndConnect($pending); return $client.Connected } catch { return $false }
    } finally {
        $client.Dispose()
    }
}

function Wait-CrsPortClosed {
    param([int]$Port, [int]$TimeoutMilliseconds = 10000)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        if (-not (Test-CrsPortOpen -Port $Port)) { return $true }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Get-CrsCodexProcesses {
    param([string]$ExecutablePath)

    @(
        Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ([string]::Equals($_.Path, $ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) { $_ }
            } catch {
                # An inaccessible process is not accepted as the target.
            }
        }
    )
}

function Stop-CrsCodex {
    param([string]$ExecutablePath)

    $targets = @(Get-CrsCodexProcesses -ExecutablePath $ExecutablePath)
    if ($targets.Count -eq 0) { return }

    $targets | Stop-Process -ErrorAction SilentlyContinue
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $remaining = @(Get-CrsCodexProcesses -ExecutablePath $ExecutablePath)
    } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        $remaining | Stop-Process -Force -ErrorAction Stop
    }
}

function Start-CrsOrdinaryCodex {
    param($Package)

    Start-Process -FilePath $Package.ExecutablePath | Out-Null
}

function Read-CrsState {
    param([switch]$AllowInvalid)

    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $rendererPort = 0
        $mainPort = 0
        if ($state.schemaVersion -ne 1 -or
            -not [int]::TryParse([string]$state.rendererPort, [ref]$rendererPort) -or
            -not [int]::TryParse([string]$state.mainPort, [ref]$mainPort) -or
            $rendererPort -lt 1 -or $rendererPort -gt 65535 -or
            $mainPort -lt 1 -or $mainPort -gt 65535 -or $rendererPort -eq $mainPort) {
            throw 'invalid state schema'
        }
        $state.rendererPort = $rendererPort
        $state.mainPort = $mainPort
        return $state
    } catch {
        if ($AllowInvalid) {
            Write-Warning "Ignoring the damaged local session record during rollback: $script:StatePath"
            return $null
        }
        throw "The local session record is damaged. Inspect or remove it manually: $script:StatePath"
    }
}

function Write-CrsState {
    param($Package, [int]$RendererPort, [int]$MainPort, $Probe)

    $state = [pscustomobject][ordered]@{
        schemaVersion = 1
        packageFullName = $Package.FullName
        packageVersion = $Package.Version
        executablePath = $Package.ExecutablePath
        rendererPort = $RendererPort
        mainPort = $MainPort
        appAsarSha256 = [string]$Probe.appAsarSha256
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $json = $state | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $script:StatePath -Value $json -Encoding UTF8
}

function Invoke-CrsBridge {
    param($Node, [int]$RendererPort, [int]$MainPort)

    $orchestrator = Join-Path $script:RuntimeRoot 'orchestrator.js'
    $mainPayload = Join-Path $script:RuntimeRoot 'main-payload.js'
    $arguments = @(
        $orchestrator,
        '--mode', 'full',
        '--renderer-port', [string]$RendererPort,
        '--main-port', [string]$MainPort,
        '--timeout-ms', [string]($TimeoutSeconds * 1000),
        '--main-payload', $mainPayload
    )
    $output = @(& $Node.Path @arguments 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        throw "Runtime bridge failed: $($output -join ' ')"
    }
    $result = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
    if ($result.ok -isnot [bool] -or -not $result.ok -or
        $result.main.inspectorPortClosed.confirmed -isnot [bool] -or -not $result.main.inspectorPortClosed.confirmed -or
        $result.renderer.probe.proof -isnot [bool] -or -not $result.renderer.probe.proof) {
        throw 'Runtime bridge did not return complete main-process closure and renderer proof.'
    }
    return $result
}

function Invoke-CrsProbeExisting {
    param($Node, $State)

    if ($null -eq $State -or -not (Test-CrsPortOpen -Port ([int]$State.rendererPort))) { return $null }
    $orchestrator = Join-Path $script:RuntimeRoot 'orchestrator.js'
    $output = @(& $Node.Path $orchestrator '--mode' 'probe' '--renderer-port' ([string]$State.rendererPort) '--main-port' ([string]$State.mainPort) '--timeout-ms' '3000' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { return $null }
    try { return ([string]$output[0] | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Invoke-CrsRollback {
    param($Package, $State)

    if (-not $PSCmdlet.ShouldProcess('the current OpenAI Codex session', 'Close it and relaunch Codex without debug ports')) {
        return
    }

    Stop-CrsCodex -ExecutablePath $Package.ExecutablePath
    if ($null -ne $State) {
        foreach ($port in @([int]$State.rendererPort, [int]$State.mainPort)) {
            if (-not (Wait-CrsPortClosed -Port $port)) {
                throw "Rollback stopped Codex, but loopback port $port did not close. Codex was not relaunched."
            }
        }
    }
    if (Test-Path -LiteralPath $script:StatePath -PathType Leaf) {
        Remove-Item -LiteralPath $script:StatePath -Force
    }
    Start-CrsOrdinaryCodex -Package $Package
    Write-Host 'Rollback complete: Codex was relaunched normally.' -ForegroundColor Green
    Write-Host 'The DPAPI device-key store was preserved. Revoke the device in Codex before deleting that store.'
}

$package = Get-CrsPackage

if ($Action -ceq 'Rollback') {
    $rollbackState = Read-CrsState -AllowInvalid
    Invoke-CrsRollback -Package $package -State $rollbackState
    return
}

$node = Resolve-CrsNode -RequestedPath $NodePath
$compatibility = Test-CrsCompatibility -Package $package -Node $node
$state = Read-CrsState

switch ($Action) {
    'Check' {
        $liveProbe = Invoke-CrsProbeExisting -Node $node -State $state
        [pscustomobject][ordered]@{
            Ready = $true
            PackageVersion = $package.Version
            PackageFullName = $package.FullName
            NodeVersion = $node.Version
            AppAsarSha256 = $compatibility.appAsarSha256
            Classification = $compatibility.classification
            LocalSessionActive = [bool]($null -ne $liveProbe -and $liveProbe.ok -and $liveProbe.renderer.probe.proof)
            SessionRecord = if ($null -eq $state) { $null } else { $script:StatePath }
        }
        break
    }
    'Enable' {
        $existing = Invoke-CrsProbeExisting -Node $node -State $state
        if ($null -ne $existing -and $existing.ok -and $existing.renderer.probe.proof) {
            Write-Host 'The local Control other devices bridge is already active.' -ForegroundColor Green
            break
        }
        if (-not $PSCmdlet.ShouldProcess('the current OpenAI Codex session', 'Close it, relaunch with loopback debug ports, and inject the audited compatibility bridge')) {
            break
        }

        $rendererPort = Get-CrsFreePort
        do { $mainPort = Get-CrsFreePort } while ($mainPort -eq $rendererPort)
        Stop-CrsCodex -ExecutablePath $package.ExecutablePath

        try {
            $arguments = @(
                '--remote-debugging-address=127.0.0.1',
                "--remote-debugging-port=$rendererPort",
                "--inspect=127.0.0.1:$mainPort"
            )
            Start-Process -FilePath $package.ExecutablePath -ArgumentList $arguments | Out-Null
            $bridge = Invoke-CrsBridge -Node $node -RendererPort $rendererPort -MainPort $mainPort
            Write-CrsState -Package $package -RendererPort $rendererPort -MainPort $mainPort -Probe $compatibility
            Write-Host 'Control other devices and macOS-style connection grouping are active for this Codex session.' -ForegroundColor Green
            Write-Host 'Open Settings > Connections > Control other devices.'
            Write-Host 'In the sidebar, open Project sidebar options and choose By connection when desired.'
            Write-Warning 'By connection groups chats by host but does not preserve nested project headings. Use By project to retain project grouping.'
            Write-Warning 'The renderer debug endpoint remains reachable by processes running as your Windows user until Codex exits or rollback is run.'
        } catch {
            Write-Warning 'Enable failed. Restoring an ordinary Codex session.'
            Stop-CrsCodex -ExecutablePath $package.ExecutablePath
            foreach ($port in @($rendererPort, $mainPort)) { [void](Wait-CrsPortClosed -Port $port) }
            if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
            Start-CrsOrdinaryCodex -Package $package
            throw
        }
        break
    }
}
