[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Enable', 'Rollback')]
    [string]$Action = 'Check',

    [string]$NodePath,

    [switch]$UseProxy,

    [string]$ProxyServer,

    [switch]$RefuseExistingApp,

    [ValidateRange(5, 60)]
    [int]$TimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BundleRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$script:RuntimeRoot = Join-Path $script:BundleRoot 'runtime'
$script:StateRoot = Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures'
$script:StatePath = Join-Path $script:StateRoot 'codexremote-simple-session.json'
$script:LegacyStatePath = Join-Path $script:BundleRoot '.codexremote-simple-session.json'
$script:PackageActivationLauncher = Join-Path $script:RuntimeRoot 'PackageActivationLauncher.exe'
$script:PackageProcessLauncher = Join-Path $script:RuntimeRoot 'PackageProcessLauncher.exe'
$script:PackageProcessWorker = Join-Path $script:RuntimeRoot 'PackageProcessLauncher.ps1'
$script:ApiProxyBridge = Join-Path $script:RuntimeRoot 'api-proxy-bridge.js'
$script:ProxyRuntimePreparer = Join-Path $script:RuntimeRoot 'prepare-proxy-runtime.js'
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
    $cliPath = [IO.Path]::GetFullPath((Join-Path $installRoot 'app\resources\codex.exe'))
    foreach ($path in @($executable, $appAsar, $nativeRoot, $cliPath)) {
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
        AppRoot = [IO.Path]::GetFullPath((Join-Path $installRoot 'app'))
        ExecutablePath = $executable
        AppAsarPath = $appAsar
        NativeRoot = $nativeRoot
        CliPath = $cliPath
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
    if ($result.schemaVersion -ne 2 -or $result.bridgeMode -cnotin @('legacy-main-shim', 'native-renderer') -or
        $result.classification -cnotin @('CandidateCompatible', 'NativeWindowsCompatible') -or
        $result.affected -isnot [bool] -or -not $result.affected -or
        $result.appAsarSha256 -isnot [string] -or $result.appAsarSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'This Codex build does not match the audited Windows compatibility signature. Refusing to inject.'
    }
    return $result
}

function Test-CrsLegacyDeviceKeyCompatibilityNeeded {
    param($Node)
    $checker = Join-Path $script:RuntimeRoot 'legacy-device-key-compat.cjs'
    $output = @(& $Node.Path $checker '--check' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { throw 'The existing device-key compatibility check failed.' }
    $result = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
    if ($result.legacyDeviceKeyCompatibilityNeeded -isnot [bool]) { throw 'The device-key compatibility check returned an invalid result.' }
    return [bool]$result.legacyDeviceKeyCompatibilityNeeded
}

function Test-CrsLegacyDeviceKeyModeProof {
    param($State, [bool]$Required)
    if (-not $Required) { return $true }
    if ($null -eq $State -or $null -eq $State.PSObject.Properties['legacyDeviceKeyCompatibility'] -or
        $State.legacyDeviceKeyCompatibility -isnot [bool] -or -not $State.legacyDeviceKeyCompatibility) { return $false }
    try {
        $resources = Join-Path (Split-Path -Parent ([string]$State.executablePath)) 'resources'
        return (Get-FileHash -LiteralPath (Join-Path $resources 'crk.cjs') -Algorithm SHA256).Hash -ceq
            (Get-FileHash -LiteralPath (Join-Path $script:RuntimeRoot 'legacy-device-key-compat.cjs') -Algorithm SHA256).Hash -and
            (Get-FileHash -LiteralPath (Join-Path $resources 'crks.cjs') -Algorithm SHA256).Hash -ceq
            (Get-FileHash -LiteralPath (Join-Path $script:RuntimeRoot 'main-payload.js') -Algorithm SHA256).Hash
    } catch { return $false }
}

function New-CrsProxyRuntimePackage {
    param($Package, $Node, [bool]$ProxyEnabled = $true, [bool]$LegacyDeviceKeys = $false)

    if (-not (Test-Path -LiteralPath $script:ProxyRuntimePreparer -PathType Leaf)) {
        throw "The private proxy-runtime preparer is missing: $script:ProxyRuntimePreparer"
    }
    $output = @(& $Node.Path $script:ProxyRuntimePreparer '--source-app' $Package.AppRoot '--package-version' $Package.Version '--proxy-enabled' $ProxyEnabled.ToString().ToLowerInvariant() '--legacy-device-keys' $LegacyDeviceKeys.ToString().ToLowerInvariant() 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        throw "Preparing the private ChatGPT proxy runtime failed: $($output -join ' ')"
    }
    $runtime = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
    $managedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\patched-chatgpt'))
    $runtimeRoot = [IO.Path]::GetFullPath([string]$runtime.runtimeRoot)
    $runtimeCliPath = [IO.Path]::GetFullPath((Join-Path $runtimeRoot 'resources\codex.exe'))
    $expectedPrefix = $managedRoot.TrimEnd('\') + '\'
    if (-not $runtimeRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath ([string]$runtime.executablePath) -PathType Leaf) -or
        -not (Test-Path -LiteralPath ([string]$runtime.appAsarPath) -PathType Leaf) -or
        -not (Test-Path -LiteralPath $runtimeCliPath -PathType Leaf)) {
        throw 'The private ChatGPT proxy runtime returned an invalid managed path.'
    }

    [pscustomobject][ordered]@{
        FullName = $Package.FullName
        FamilyName = $Package.FamilyName
        ApplicationId = $Package.ApplicationId
        AppUserModelId = $Package.AppUserModelId
        Version = $Package.Version
        InstallRoot = $Package.InstallRoot
        AppRoot = $runtimeRoot
        ExecutablePath = [IO.Path]::GetFullPath([string]$runtime.executablePath)
        AppAsarPath = [IO.Path]::GetFullPath([string]$runtime.appAsarPath)
        NativeRoot = [IO.Path]::GetFullPath((Join-Path $runtimeRoot 'resources\native'))
        # A process launched from the private runtime cannot execute the CLI
        # directly from WindowsApps on managed Windows installations (spawn
        # EPERM). The copied CLI has ordinary per-user ACLs and belongs to the
        # same audited package runtime.
        CliPath = $runtimeCliPath
        OriginalExecutablePath = $Package.ExecutablePath
        ProxyRuntimeReused = [bool]$runtime.reused
    }
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

function Assert-CrsNoExistingAppForReplacement {
    param($Package, $LaunchPackage, [switch]$Enabled)

    if (-not $Enabled) { return }
    $executablePaths = @([string]$Package.ExecutablePath)
    if ($null -ne $LaunchPackage -and
        -not [string]::Equals([string]$LaunchPackage.ExecutablePath, [string]$Package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
        $executablePaths += [string]$LaunchPackage.ExecutablePath
    }
    foreach ($executablePath in @($executablePaths | Select-Object -Unique)) {
        if (@(Get-CrsCodexProcesses -ExecutablePath $executablePath).Count -ne 0) {
            throw 'ChatGPT/Codex appeared while update resume was preparing the replacement session. It was left running and the resumed update was aborted.'
        }
    }
}

function Get-CrsDiscoverableSession {
    param(
        $Package,
        [ValidateSet('legacy-main-shim', 'native-renderer')]
        [string]$BridgeMode = 'legacy-main-shim',
        [object[]]$Processes,
        [scriptblock]$PortTester
    )

    if ($null -eq $Processes) {
        $Processes = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue)
    }
    if ($null -eq $PortTester) {
        $PortTester = { param([int]$Port) Test-CrsPortOpen -Port $Port }
    }
    $candidates = foreach ($process in @($Processes)) {
        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine) -or $commandLine -match '(?:^|\s)--type=') { continue }
        if (-not [string]::Equals([string]$process.ExecutablePath, [string]$Package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($commandLine -notmatch '(?:^|\s)--remote-debugging-address(?:=|\s+)127\.0\.0\.1(?:\s|$)') { continue }
        $rendererMatch = [regex]::Match($commandLine, '(?:^|\s)--remote-debugging-port(?:=|\s+)(?<port>\d+)(?:\s|$)')
        $mainMatch = [regex]::Match($commandLine, '(?:^|\s)--inspect(?:=|\s+)127\.0\.0\.1:(?<port>\d+)(?:\s|$)')
        if (-not $rendererMatch.Success -or ($BridgeMode -ceq 'legacy-main-shim' -and -not $mainMatch.Success)) { continue }
        $rendererPort = [int]$rendererMatch.Groups['port'].Value
        $mainPort = if ($BridgeMode -ceq 'legacy-main-shim' -and $mainMatch.Success) { [int]$mainMatch.Groups['port'].Value } else { $null }
        if ($rendererPort -lt 1 -or $rendererPort -gt 65535) { continue }
        if ($BridgeMode -ceq 'legacy-main-shim' -and
            ($mainPort -lt 1 -or $mainPort -gt 65535 -or $rendererPort -eq $mainPort)) { continue }
        if (-not (& $PortTester $rendererPort) -or
            ($BridgeMode -ceq 'legacy-main-shim' -and -not (& $PortTester $mainPort))) { continue }
        [pscustomobject][ordered]@{
            schemaVersion = 2
            bridgeMode = $BridgeMode
            packageFullName = $Package.FullName
            packageVersion = $Package.Version
            executablePath = $Package.ExecutablePath
            rendererPort = $rendererPort
            mainPort = $mainPort
            launchMethod = 'adopted-existing-session'
            launchProcessId = $process.ProcessId
            # Renderer-only native sessions cannot contain the legacy scoped
            # proxy shim. Legacy command lines cannot prove whether it ran.
            proxyMode = if ($BridgeMode -ceq 'native-renderer') { $false } else { $null }
            proxyTransport = $null
            appAsarSha256 = $null
            startedAtUtc = $null
        }
    }
    $candidates = @($candidates)
    if ($candidates.Count -ne 1) { return $null }
    return $candidates[0]
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
        [string]$EnvironmentProxyServer,
        [string]$NodePath,
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

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentProxyServer)) {
        $proxyWorker = $null
        try {
            if (-not (Test-Path -LiteralPath $script:PackageProcessLauncher -PathType Leaf)) {
                throw "The package-context process launcher is missing: $script:PackageProcessLauncher"
            }
            if (-not (Test-Path -LiteralPath $script:PackageProcessWorker -PathType Leaf)) {
                throw "The package-context process worker is missing: $script:PackageProcessWorker"
            }
            if ([string]::IsNullOrWhiteSpace($NodePath) -or -not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
                throw 'The Node.js runtime for the API proxy bridge is missing.'
            }
            if (-not (Test-Path -LiteralPath $script:ApiProxyBridge -PathType Leaf)) {
                throw "The API proxy bridge is missing: $script:ApiProxyBridge"
            }
            $payload = [ordered]@{
                packageFamilyName = [string]$Package.FamilyName
                applicationId = [string]$Package.ApplicationId
                helperPath = $script:PackageProcessLauncher
                executablePath = [string]$Package.ExecutablePath
                proxyServer = $EnvironmentProxyServer
                nodePath = [IO.Path]::GetFullPath($NodePath)
                bridgePath = $script:ApiProxyBridge
                targetBaseUrl = 'https://chatgpt.com'
                originalCliPath = [string]$Package.CliPath
                arguments = @($ArgumentList)
            }
            $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)))
            $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) { throw 'Windows PowerShell was not found.' }
            $workerArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -PayloadBase64 "{1}"' -f $script:PackageProcessWorker,$payloadBase64
            $proxyWorker = Start-Process -FilePath $powerShell -ArgumentList $workerArguments -WindowStyle Hidden -PassThru

            $deadline = [DateTime]::UtcNow.AddMilliseconds($PortTimeoutMilliseconds)
            $portReady = $ExpectedPort -le 0
            while (-not $portReady -and [DateTime]::UtcNow -lt $deadline) {
                # Invoke-CommandInDesktopPackage returns after it dispatches the
                # full-trust helper. The short-lived PowerShell worker can therefore
                # exit normally while the helper and ChatGPT continue starting.
                $portReady = Test-CrsPortOpen -Port $ExpectedPort
                if (-not $portReady) { Start-Sleep -Milliseconds 100 }
            }
            if (-not $portReady) { throw "The package-context proxy launch completed, but loopback port $ExpectedPort did not open." }
            $launchProcessId = [uint32]$proxyWorker.Id
            if ($ExpectedPort -gt 0) {
                $launchedProcesses = @(
                    Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
                        Where-Object {
                            [string]::Equals([string]$_.ExecutablePath, [string]$Package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
                            [string]$_.CommandLine -match "(?:^|\s)--remote-debugging-port(?:=|\s+)$ExpectedPort(?:\s|$)"
                        }
                )
                if ($launchedProcesses.Count -eq 1) { $launchProcessId = [uint32]$launchedProcesses[0].ProcessId }
            }
            Write-CrsLaunchDiagnostic -Method 'PackageContextEnvironmentProxy' -Succeeded $true -PrimaryError '' -FallbackError ''
            return [pscustomobject][ordered]@{
                Method = 'PackageContextEnvironmentProxy'
                ProcessId = $launchProcessId
            }
        } catch {
            Stop-CrsCodex -ExecutablePath $Package.ExecutablePath
            if ($null -ne $proxyWorker -and -not $proxyWorker.HasExited) {
                Stop-Process -Id $proxyWorker.Id -Force -ErrorAction SilentlyContinue
            }
            Write-CrsLaunchDiagnostic -Method 'None' -Succeeded $false -PrimaryError $_.Exception.Message -FallbackError ''
            throw "The package-context environment-proxy launch failed: $($_.Exception.Message)"
        } finally {
            if ($null -ne $proxyWorker) { $proxyWorker.Dispose() }
        }
    }

    try {
        if ($null -ne $Package.PSObject.Properties['OriginalExecutablePath'] -and
            -not [string]::Equals([string]$Package.OriginalExecutablePath, [string]$Package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
            # Activation by application id would reopen the installed executable
            # and silently omit the private runtime's startup compatibility.
            throw 'The private compatibility runtime requires explicit package-context execution.'
        }
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

function Move-CrsDamagedState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }

    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')
    $quarantineName = 'codexremote-simple-session.damaged-{0}-{1}.json' -f $timestamp,[guid]::NewGuid().ToString('N')
    $quarantinePath = Join-Path $script:StateRoot $quarantineName
    try {
        Move-Item -LiteralPath $script:StatePath -Destination $quarantinePath -ErrorAction Stop
    } catch {
        throw "The local session record is damaged and could not be quarantined. No existing session was adopted: $script:StatePath"
    }
    return $quarantinePath
}

function Read-CrsState {
    param([switch]$AllowInvalid)

    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $script:LegacyStatePath -PathType Leaf)) { return $null }
        New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
        Copy-Item -LiteralPath $script:LegacyStatePath -Destination $script:StatePath -Force
    }
    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $rendererPort = 0
        if (-not [int]::TryParse([string]$state.rendererPort, [ref]$rendererPort) -or
            $rendererPort -lt 1 -or $rendererPort -gt 65535 -or
            $state.schemaVersion -notin @(1, 2)) {
            throw 'invalid state schema'
        }
        $bridgeMode = if ($state.schemaVersion -eq 1) { 'legacy-main-shim' } else { [string]$state.bridgeMode }
        if ($bridgeMode -cnotin @('legacy-main-shim', 'native-renderer')) { throw 'invalid state bridge mode' }
        $mainPort = $null
        if ($bridgeMode -ceq 'legacy-main-shim') {
            $parsedMainPort = 0
            if (-not [int]::TryParse([string]$state.mainPort, [ref]$parsedMainPort) -or
                $parsedMainPort -lt 1 -or $parsedMainPort -gt 65535 -or $rendererPort -eq $parsedMainPort) {
                throw 'invalid state main port'
            }
            $mainPort = $parsedMainPort
        }
        if ($null -eq $state.PSObject.Properties['bridgeMode']) {
            $state | Add-Member -NotePropertyName bridgeMode -NotePropertyValue $bridgeMode
        } else {
            $state.bridgeMode = $bridgeMode
        }
        $state.rendererPort = $rendererPort
        $state.mainPort = $mainPort
        return $state
    } catch {
        $quarantinePath = Move-CrsDamagedState
        if ($AllowInvalid) {
            Write-Warning "Quarantined the damaged local session record before rollback: $quarantinePath"
            return $null
        }
        Write-Warning "Quarantined the damaged local session record. Live-session recovery will require the existing package, process, loopback-port, and proxy-mode checks: $quarantinePath"
        return $null
    }
}

function Write-CrsState {
    param($Package, [int]$RendererPort, $MainPort, $Probe, $Launch, [bool]$ProxyMode, [string]$BridgeMode, [bool]$LegacyDeviceKeyCompatibility = $false)

    $state = [pscustomobject][ordered]@{
        schemaVersion = 2
        bridgeMode = $BridgeMode
        packageFullName = $Package.FullName
        packageVersion = $Package.Version
        executablePath = $Package.ExecutablePath
        rendererPort = $RendererPort
        mainPort = $MainPort
        launchMethod = [string]$Launch.Method
        launchProcessId = $Launch.ProcessId
        proxyMode = $ProxyMode
        legacyDeviceKeyCompatibility = $LegacyDeviceKeyCompatibility
        proxyTransport = if ($ProxyMode -and $BridgeMode -ceq 'native-renderer') { 'remote-websocket-bridge-v1' } else { $null }
        appAsarSha256 = [string]$Probe.appAsarSha256
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $json = $state | ConvertTo-Json -Depth 4
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $temporaryPath = Join-Path $script:StateRoot ('.codexremote-simple-session.{0}.{1}.tmp' -f $PID,[guid]::NewGuid().ToString('N'))
    $stream = $null
    try {
        $encoding = [Text.UTF8Encoding]::new($false)
        $bytes = $encoding.GetBytes($json)
        $stream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if (Test-Path -LiteralPath $script:StatePath -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $script:StatePath, $null)
        } else {
            [IO.File]::Move($temporaryPath, $script:StatePath)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-CrsBridge {
    param($Node, [int]$RendererPort, $MainPort, [string]$ProxyServer, [string]$BridgeMode)

    $orchestrator = Join-Path $script:RuntimeRoot 'orchestrator.js'
    if ($BridgeMode -ceq 'native-renderer') {
        $arguments = @($orchestrator, '--mode', 'renderer', '--renderer-port', [string]$RendererPort, '--timeout-ms', [string]($TimeoutSeconds * 1000))
    } else {
        $mainPayload = Join-Path $script:RuntimeRoot 'main-payload.js'
        $arguments = @(
            $orchestrator, '--mode', 'full', '--renderer-port', [string]$RendererPort,
            '--main-port', [string]$MainPort, '--timeout-ms', [string]($TimeoutSeconds * 1000),
            '--main-payload', $mainPayload
        )
        if (-not [string]::IsNullOrWhiteSpace($ProxyServer)) { $arguments += @('--proxy-url', $ProxyServer) }
    }
    $output = @(& $Node.Path @arguments 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        throw "Runtime bridge failed: $($output -join ' ')"
    }
    $result = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
    $mainProof = $BridgeMode -ceq 'native-renderer' -or
        ($result.main.inspectorPortClosed.confirmed -is [bool] -and $result.main.inspectorPortClosed.confirmed)
    if ($result.ok -isnot [bool] -or -not $result.ok -or -not $mainProof -or
        $result.renderer.probe.proof -isnot [bool] -or -not $result.renderer.probe.proof) {
        throw 'Runtime bridge did not return complete proof for the selected bridge mode.'
    }
    return $result
}

function Invoke-CrsProbeExisting {
    param($Node, $State)

    if ($null -eq $State -or -not (Test-CrsPortOpen -Port ([int]$State.rendererPort))) { return $null }
    $orchestrator = Join-Path $script:RuntimeRoot 'orchestrator.js'
    $arguments = @($orchestrator, '--mode', $(if ($State.bridgeMode -ceq 'native-renderer') { 'probe-renderer' } else { 'probe' }), '--renderer-port', ([string]$State.rendererPort))
    if ($State.bridgeMode -ceq 'legacy-main-shim') { $arguments += @('--main-port', ([string]$State.mainPort)) }
    $arguments += @('--timeout-ms', '3000')
    $output = @(& $Node.Path @arguments 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { return $null }
    try { return ([string]$output[0] | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Test-CrsProxyModeProof {
    param($State, [bool]$RequestedProxyMode)

    if ($null -eq $State -or $null -eq $State.PSObject.Properties['proxyMode']) { return $false }
    if ($State.proxyMode -isnot [bool]) { return $false }
    if ([bool]$State.proxyMode -ne $RequestedProxyMode) { return $false }
    $proxyTransport = if ($null -eq $State.PSObject.Properties['proxyTransport']) { '' } else { [string]$State.proxyTransport }
    if (-not [string]::IsNullOrEmpty($proxyTransport) -and $proxyTransport -cne 'remote-websocket-bridge-v1') {
        return $false
    }
    if (-not $RequestedProxyMode) {
        return [string]::IsNullOrEmpty($proxyTransport)
    }
    if ($RequestedProxyMode -and [string]$State.bridgeMode -ceq 'native-renderer') {
        return $proxyTransport -ceq 'remote-websocket-bridge-v1'
    }
    return [string]::IsNullOrEmpty($proxyTransport)
}

function Remove-CrsInactiveProxyRuntimes {
    param([string]$KeepRoot)

    $managedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\patched-chatgpt'))
    if (-not (Test-Path -LiteralPath $managedRoot -PathType Container)) { return }
    $keep = [IO.Path]::GetFullPath($KeepRoot)
    $expectedPrefix = $managedRoot.TrimEnd('\') + '\'
    foreach ($directory in @(Get-ChildItem -LiteralPath $managedRoot -Directory -ErrorAction SilentlyContinue)) {
        $candidate = [IO.Path]::GetFullPath($directory.FullName)
        if ($candidate -ceq $keep -or
            -not $candidate.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $directory.Name -cnotmatch '^proxy-runtime-[a-z0-9._-]+$') { continue }
        $candidateExecutable = Join-Path $candidate 'ChatGPT.exe'
        if (@(Get-CrsCodexProcesses -ExecutablePath $candidateExecutable).Count -ne 0) { continue }
        try {
            Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "The inactive private proxy runtime could not be removed: $candidate"
        }
    }
}

function Invoke-CrsRollback {
    param($Package, $State)

    if (-not $PSCmdlet.ShouldProcess('the current OpenAI Codex session', 'Close it and relaunch Codex without debug ports')) {
        return
    }

    if ($null -ne $State -and -not [string]::IsNullOrWhiteSpace([string]$State.executablePath)) {
        Stop-CrsCodex -ExecutablePath ([string]$State.executablePath)
    }
    Stop-CrsCodex -ExecutablePath $Package.ExecutablePath
    if ($null -ne $State) {
        foreach ($port in @($State.rendererPort, $State.mainPort) | Where-Object { $null -ne $_ }) {
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
$bridgeMode = [string]$compatibility.bridgeMode
$legacyDeviceKeyCompatibilityNeeded = $bridgeMode -ceq 'native-renderer' -and (Test-CrsLegacyDeviceKeyCompatibilityNeeded -Node $node)
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
            BridgeMode = $bridgeMode
            LegacyDeviceKeyCompatibilityNeeded = $legacyDeviceKeyCompatibilityNeeded
            LocalSessionActive = [bool]($null -ne $liveProbe -and $liveProbe.ok -and $liveProbe.renderer.probe.proof)
            SessionRecord = if ($null -eq $state) { $null } else { $script:StatePath }
        }
        break
    }
    'Enable' {
        $existing = Invoke-CrsProbeExisting -Node $node -State $state
        if ($null -eq $existing -or -not $existing.ok -or -not $existing.renderer.probe.proof) {
            $discovered = Get-CrsDiscoverableSession -Package $package -BridgeMode $bridgeMode
            if ($null -ne $discovered) {
                $discoveredProbe = Invoke-CrsProbeExisting -Node $node -State $discovered
                if ($null -ne $discoveredProbe -and $discoveredProbe.ok -and $discoveredProbe.renderer.probe.proof -and
                    (Test-CrsProxyModeProof -State $discovered -RequestedProxyMode ([bool]$UseProxy)) -and
                    (Test-CrsLegacyDeviceKeyModeProof -State $discovered -Required $legacyDeviceKeyCompatibilityNeeded)) {
                    Write-CrsState -Package $package -RendererPort $discovered.rendererPort -MainPort $discovered.mainPort -Probe $compatibility -Launch ([pscustomobject]@{ Method = 'adopted-existing-session'; ProcessId = $discovered.launchProcessId }) -ProxyMode ([bool]$discovered.proxyMode) -BridgeMode $bridgeMode
                    $state = Read-CrsState
                    $existing = $discoveredProbe
                    Write-Host 'Adopted the existing audited loopback session without relaunching ChatGPT.' -ForegroundColor Green
                }
            }
        }
        if ($null -ne $existing -and $existing.ok -and $existing.renderer.probe.proof) {
            if ((Test-CrsProxyModeProof -State $state -RequestedProxyMode ([bool]$UseProxy)) -and
                (Test-CrsLegacyDeviceKeyModeProof -State $state -Required $legacyDeviceKeyCompatibilityNeeded)) {
                Write-Host 'The local Control other devices bridge is already active in the requested proxy mode.' -ForegroundColor Green
                break
            }
            Write-Host 'The requested connection compatibility differs from the active session; ChatGPT will be relaunched.' -ForegroundColor Yellow
        }
        if (-not $PSCmdlet.ShouldProcess('the current OpenAI Codex session', 'Close it, relaunch with loopback debug ports, and inject the audited compatibility bridge')) {
            break
        }

        $rendererPort = Get-CrsFreePort
        $mainPort = $null
        if ($bridgeMode -ceq 'legacy-main-shim') {
            do { $mainPort = Get-CrsFreePort } while ($mainPort -eq $rendererPort)
        }
        $launchPackage = $package
        $sessionStopped = $false
        try {
            $resolvedProxyServer = $null
            if ($UseProxy) {
                $resolvedProxyServer = Resolve-CrsProxyServer -RequestedProxy $ProxyServer
                if ($bridgeMode -cne 'native-renderer') {
                    Write-Host 'Experimental proxy mode is enabled only for the Remote-control WebSocket.' -ForegroundColor Yellow
                }
            }
            if ($bridgeMode -ceq 'native-renderer' -and ($UseProxy -or $legacyDeviceKeyCompatibilityNeeded)) {
                Write-Host 'Preparing the version-matched private ChatGPT compatibility runtime.' -ForegroundColor Yellow
                $launchPackage = New-CrsProxyRuntimePackage -Package $package -Node $node -ProxyEnabled ([bool]$UseProxy) -LegacyDeviceKeys $legacyDeviceKeyCompatibilityNeeded
                if ($UseProxy) { Write-Host 'Proxy mode is scoped to the Remote-control WebSocket; signed enrollment remains on the canonical ChatGPT URL.' -ForegroundColor Yellow }
                if ($legacyDeviceKeyCompatibilityNeeded) { Write-Host 'Existing protected enrollment keys remain available; new keys use the native Windows provider.' -ForegroundColor Yellow }
            }
            Assert-CrsNoExistingAppForReplacement -Package $package -LaunchPackage $launchPackage -Enabled:$RefuseExistingApp
            $sessionStopped = $true
            if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.executablePath)) {
                Stop-CrsCodex -ExecutablePath ([string]$state.executablePath)
            }
            Stop-CrsCodex -ExecutablePath $package.ExecutablePath
            if (-not [string]::Equals([string]$launchPackage.ExecutablePath, [string]$package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-CrsCodex -ExecutablePath $launchPackage.ExecutablePath
                Remove-CrsInactiveProxyRuntimes -KeepRoot $launchPackage.AppRoot
            }
            $arguments = @(
                '--remote-debugging-address=127.0.0.1',
                "--remote-debugging-port=$rendererPort"
            )
            if ($bridgeMode -ceq 'legacy-main-shim') { $arguments += "--inspect=127.0.0.1:$mainPort" }
            $launchArguments = @{
                Package = $launchPackage
                ArgumentList = $arguments
                ExpectedPort = $rendererPort
            }
            if ($UseProxy -and $bridgeMode -ceq 'native-renderer') {
                $launchArguments.EnvironmentProxyServer = $resolvedProxyServer
                $launchArguments.NodePath = $node.Path
            }
            $launch = Start-CrsPackagedCodex @launchArguments
            $bridge = Invoke-CrsBridge -Node $node -RendererPort $rendererPort -MainPort $mainPort -ProxyServer $(if ($UseProxy) { $resolvedProxyServer } else { $null }) -BridgeMode $bridgeMode
            Write-CrsState -Package $launchPackage -RendererPort $rendererPort -MainPort $mainPort -Probe $compatibility -Launch $launch -ProxyMode ([bool]$UseProxy) -BridgeMode $bridgeMode -LegacyDeviceKeyCompatibility $legacyDeviceKeyCompatibilityNeeded
            Write-Host 'Control other devices and macOS-style connection grouping are active for this Codex session.' -ForegroundColor Green
            Write-Host 'Open Settings > Connections > Control other devices.'
            Write-Host 'In the sidebar, open Project sidebar options and choose By connection when desired.'
            Write-Warning 'By connection groups chats by host but does not preserve nested project headings. Use By project to retain project grouping.'
            Write-Warning 'The renderer debug endpoint remains reachable by processes running as your Windows user until Codex exits or rollback is run.'
        } catch {
            if (-not $sessionStopped) { throw }
            Write-Warning 'Enable failed. Restoring an ordinary Codex session.'
            if ($null -ne $launchPackage -and -not [string]::Equals([string]$launchPackage.ExecutablePath, [string]$package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-CrsCodex -ExecutablePath $launchPackage.ExecutablePath
            }
            Stop-CrsCodex -ExecutablePath $package.ExecutablePath
            foreach ($port in @($rendererPort, $mainPort) | Where-Object { $null -ne $_ }) { [void](Wait-CrsPortClosed -Port $port) }
            if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
            Start-CrsOrdinaryCodex -Package $package
            throw
        }
        break
    }
}
