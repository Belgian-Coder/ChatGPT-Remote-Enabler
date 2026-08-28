[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Enable', 'Rollback')]
    [string]$Action = 'Check',

    [string]$NodePath,

    [switch]$UseProxy,

    [string]$ProxyServer,

    [ValidateRange(5, 60)]
    [int]$TimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$script:RuntimeRoot = Join-Path $script:BundleRoot 'runtime'
$script:StatePath = Join-Path $script:BundleRoot '.codexremote-simple-session.json'
$script:PackageActivationLauncher = Join-Path $script:RuntimeRoot 'PackageActivationLauncher.exe'
$script:LaunchLogPath = Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures\launch.log'

function Resolve-CrsProxyServer {
    param([string]$RequestedProxy)

    $value = $RequestedProxy
    if ([string]::IsNullOrWhiteSpace($value)) {
        foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
            $candidate = [Environment]::GetEnvironmentVariable($name, 'Process')
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                $candidate = [Environment]::GetEnvironmentVariable($name, 'User')
            }
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $value = $candidate.Trim()
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'Proxy mode was requested, but HTTPS_PROXY or HTTP_PROXY is not configured.'
    }

    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or
        [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw 'The configured proxy must be an absolute http:// or https:// URL.'
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw 'Proxy URLs containing credentials are not accepted because launch arguments are visible to other local processes.'
    }
    if ($uri.AbsolutePath -notin @('', '/') -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw 'The configured proxy URL may contain only a scheme, host, and optional port.'
    }

    return $uri.GetLeftPart([UriPartial]::Authority)
}

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

    $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
    $applications = @(
        $manifest.Package.Applications.Application | Where-Object {
            ([string]$_.Executable).Replace('/', '\') -ieq 'app\ChatGPT.exe'
        }
    )
    if ($applications.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$applications[0].Id)) {
        throw "Expected exactly one package application for app\ChatGPT.exe; found $($applications.Count)."
    }
    $applicationId = [string]$applications[0].Id

    [pscustomobject][ordered]@{
        FullName = [string]$package.PackageFullName
        FamilyName = [string]$package.PackageFamilyName
        ApplicationId = $applicationId
        AppUserModelId = "$([string]$package.PackageFamilyName)!$applicationId"
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

function Wait-CrsPortOpen {
    param([int]$Port, [int]$TimeoutMilliseconds = 8000)

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        if (Test-CrsPortOpen -Port $Port) { return $true }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Write-CrsLaunchDiagnostic {
    param(
        [string]$Method,
        [bool]$Succeeded,
        [AllowEmptyString()][string]$PrimaryError,
        [AllowEmptyString()][string]$FallbackError
    )

    try {
        $parent = Split-Path -Parent $script:LaunchLogPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $entry = [ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            method = $Method
            succeeded = $Succeeded
            primaryError = $PrimaryError
            fallbackError = $FallbackError
        }
        Add-Content -LiteralPath $script:LaunchLogPath -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
    } catch {
        Write-Verbose "Launch diagnostic logging failed: $($_.Exception.Message)"
    }
}

function Start-CrsPackagedCodex {
    param(
        $Package,
        [string[]]$ArgumentList = @(),
        [int]$ExpectedPort = 0,
        [ValidateRange(1000, 30000)]
        [int]$PortTimeoutMilliseconds = 8000
    )

    foreach ($argument in @($ArgumentList)) {
        if ($null -eq $argument -or $argument -match '[\x00\r\n"]') {
            throw 'A Codex launch argument contains unsupported characters.'
        }
    }
    $argumentString = @($ArgumentList) -join ' '
    $primaryError = ''

    try {
        if (-not (Test-Path -LiteralPath $script:PackageActivationLauncher -PathType Leaf)) {
            throw "The package activation launcher is missing: $script:PackageActivationLauncher"
        }
        $output = @(& $script:PackageActivationLauncher $Package.AppUserModelId $argumentString 2>&1)
        $exitCode = $LASTEXITCODE
        [uint32]$activatedProcessId = 0
        if ($exitCode -ne 0 -or $output.Count -ne 1 -or
            -not [uint32]::TryParse(([string]$output[0]).Trim(), [ref]$activatedProcessId) -or
            $activatedProcessId -eq 0) {
            throw "Package activation failed with exit code ${exitCode}: $($output -join ' ')"
        }
        if ($ExpectedPort -gt 0 -and -not (Wait-CrsPortOpen -Port $ExpectedPort -TimeoutMilliseconds $PortTimeoutMilliseconds)) {
            Stop-CrsCodex -ExecutablePath $Package.ExecutablePath
            throw "Package activation returned process $activatedProcessId, but loopback port $ExpectedPort did not open."
        }
        Write-CrsLaunchDiagnostic -Method 'ApplicationActivationManager' -Succeeded $true -PrimaryError '' -FallbackError ''
        return [pscustomobject][ordered]@{
            Method = 'ApplicationActivationManager'
            ProcessId = [uint32]$activatedProcessId
        }
    } catch {
        $primaryError = $_.Exception.Message
    }

    try {
        $fallbackParameters = @{
            PackageFamilyName = $Package.FamilyName
            AppId = $Package.ApplicationId
            Command = $Package.ExecutablePath
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrEmpty($argumentString)) {
            $fallbackParameters.Args = $argumentString
        }
        Invoke-CommandInDesktopPackage @fallbackParameters | Out-Null
        if ($ExpectedPort -gt 0 -and -not (Wait-CrsPortOpen -Port $ExpectedPort -TimeoutMilliseconds $PortTimeoutMilliseconds)) {
            Stop-CrsCodex -ExecutablePath $Package.ExecutablePath
            throw "The package-context fallback started, but loopback port $ExpectedPort did not open."
        }
        Write-CrsLaunchDiagnostic -Method 'Invoke-CommandInDesktopPackage' -Succeeded $true -PrimaryError $primaryError -FallbackError ''
        return [pscustomobject][ordered]@{
            Method = 'Invoke-CommandInDesktopPackage'
            ProcessId = $null
        }
    } catch {
        $fallbackError = $_.Exception.Message
        Write-CrsLaunchDiagnostic -Method 'None' -Succeeded $false -PrimaryError $primaryError -FallbackError $fallbackError
        throw "Both packaged Codex launch methods failed. Package activation: $primaryError Fallback: $fallbackError"
    }
}

function Start-CrsOrdinaryCodex {
    param(
        $Package,
        [string[]]$ArgumentList = @()
    )

    try {
        [void](Start-CrsPackagedCodex -Package $Package -ArgumentList $ArgumentList)
        return
    } catch {
        $packagedLaunchError = $_.Exception.Message
    }

    try {
        $explorer = Join-Path $env:SystemRoot 'explorer.exe'
        if (-not (Test-Path -LiteralPath $explorer -PathType Leaf)) {
            throw "Windows Explorer is missing: $explorer"
        }
        Start-Process -FilePath $explorer -ArgumentList "shell:AppsFolder\$($Package.AppUserModelId)" | Out-Null
        Write-CrsLaunchDiagnostic -Method 'ShellAppsFolderRecovery' -Succeeded $true -PrimaryError $packagedLaunchError -FallbackError ''
    } catch {
        $shellLaunchError = $_.Exception.Message
        Write-CrsLaunchDiagnostic -Method 'None' -Succeeded $false -PrimaryError $packagedLaunchError -FallbackError $shellLaunchError
        throw "Packaged launch and normal shell recovery both failed. Packaged launch: $packagedLaunchError Shell recovery: $shellLaunchError"
    }
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
    param($Package, [int]$RendererPort, [int]$MainPort, $Probe, $Launch, [bool]$ProxyMode)

    $state = [pscustomobject][ordered]@{
        schemaVersion = 1
        packageFullName = $Package.FullName
        packageVersion = $Package.Version
        executablePath = $Package.ExecutablePath
        rendererPort = $RendererPort
        mainPort = $MainPort
        launchMethod = [string]$Launch.Method
        launchProcessId = $Launch.ProcessId
        proxyMode = $ProxyMode
        appAsarSha256 = [string]$Probe.appAsarSha256
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $json = $state | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $script:StatePath -Value $json -Encoding UTF8
}

function Invoke-CrsBridge {
    param($Node, [int]$RendererPort, [int]$MainPort, [string]$ProxyServer)

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
    if (-not [string]::IsNullOrWhiteSpace($ProxyServer)) {
        $arguments += @('--proxy-url', $ProxyServer)
    }
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
            $activeProxyMode = $false
            if ($null -ne $state -and $null -ne $state.PSObject.Properties['proxyMode']) {
                $activeProxyMode = [bool]$state.proxyMode
            }
            if ($activeProxyMode -eq [bool]$UseProxy) {
                Write-Host 'The local Control other devices bridge is already active in the requested proxy mode.' -ForegroundColor Green
                break
            }
            Write-Host 'The requested proxy mode differs from the active session; ChatGPT will be relaunched.' -ForegroundColor Yellow
        }
        if (-not $PSCmdlet.ShouldProcess('the current OpenAI Codex session', 'Close it, relaunch with loopback debug ports, and inject the audited compatibility bridge')) {
            break
        }

        $rendererPort = Get-CrsFreePort
        do { $mainPort = Get-CrsFreePort } while ($mainPort -eq $rendererPort)
        Stop-CrsCodex -ExecutablePath $package.ExecutablePath

        try {
            $resolvedProxyServer = $null
            if ($UseProxy) {
                $resolvedProxyServer = Resolve-CrsProxyServer -RequestedProxy $ProxyServer
                Write-Host 'Experimental proxy mode is enabled only for the Remote-control WebSocket.' -ForegroundColor Yellow
            }
            $arguments = @(
                '--remote-debugging-address=127.0.0.1',
                "--remote-debugging-port=$rendererPort",
                "--inspect=127.0.0.1:$mainPort"
            )
            $launch = Start-CrsPackagedCodex -Package $package -ArgumentList $arguments -ExpectedPort $rendererPort
            $bridge = Invoke-CrsBridge -Node $node -RendererPort $rendererPort -MainPort $mainPort -ProxyServer $(if ($UseProxy) { $resolvedProxyServer } else { $null })
            Write-CrsState -Package $package -RendererPort $rendererPort -MainPort $mainPort -Probe $compatibility -Launch $launch -ProxyMode ([bool]$UseProxy)
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
