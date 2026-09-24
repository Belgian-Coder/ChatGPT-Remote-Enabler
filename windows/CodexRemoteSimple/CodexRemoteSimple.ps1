[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Enable', 'Rollback')]
    [string]$Action = 'Check',

    [string]$NodePath,

    [switch]$UseProxy,

    [string]$ProxyServer,

    [switch]$RefuseExistingApp,

    [switch]$AttachOnly,

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
    if ($result.schemaVersion -ne 3 -or $result.artifactReadable -isnot [bool] -or -not $result.artifactReadable -or
        $result.recommendedBridgeMode -cnotin @('legacy-main-shim', 'native-renderer') -or
        $result.classification -cne 'CapabilityCompatible' -or
        $result.nativeModulePresent -isnot [bool] -or
        ($result.recommendedBridgeMode -ceq 'native-renderer' -and
            (-not $result.nativeModulePresent -or $result.nativeModuleFormat -cne 'windows-pe'))) {
        throw 'The installed ChatGPT runtime did not return valid capability evidence. It was left unchanged.'
    }
    $result | Add-Member -NotePropertyName bridgeMode -NotePropertyValue ([string]$result.recommendedBridgeMode) -Force
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
        # same capability-tested package runtime.
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
        Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                [string]::Equals([string]$_.ExecutablePath, $ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
                [string]$_.CommandLine -notmatch '(?:^|\s)--type='
            } | ForEach-Object {
                try { Get-Process -Id ([int]$_.ProcessId) -ErrorAction Stop } catch {
                    # A process that changes or becomes inaccessible is not
                    # accepted as lifecycle ownership evidence.
                }
            }
    )
}

function Get-CrsProcessIdentity {
    param(
        [int]$ProcessId,
        [string]$ExecutablePath
    )

    if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($ExecutablePath)) { return $null }
    try {
        $expectedPath = [IO.Path]::GetFullPath($ExecutablePath)
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        try {
            $actualPath = [IO.Path]::GetFullPath([string]$process.MainModule.FileName)
            $startTimeFileTimeUtc = [long]$process.StartTime.ToUniversalTime().ToFileTimeUtc()
        } finally {
            $process.Dispose()
        }
        if ($startTimeFileTimeUtc -le 0 -or
            -not [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return [pscustomobject][ordered]@{
            ProcessId = [int]$ProcessId
            ExecutablePath = $actualPath
            StartTimeFileTimeUtc = $startTimeFileTimeUtc
            StartToken = $startTimeFileTimeUtc
            ProcessOwned = $true
            ProcessOwnership = 'helper-owned'
        }
    } catch {
        return $null
    }
}

function Test-CrsExpectedDebugProcess {
    param(
        [int]$ProcessId,
        [string]$ExecutablePath,
        [int]$ExpectedPort,
        [scriptblock]$ProcessReader
    )

    if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($ExecutablePath) -or $ExpectedPort -le 0) { return $false }
    if ($null -eq $ProcessReader) {
        $ProcessReader = {
            param([int]$Id)
            @(Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue)
        }
    }
    $processes = @(& $ProcessReader $ProcessId)
    if ($processes.Count -ne 1) { return $false }
    $process = $processes[0]
    $commandLine = [string]$process.CommandLine
    return [int]$process.ProcessId -eq $ProcessId -and
        [string]::Equals([string]$process.ExecutablePath, $ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
        $commandLine -notmatch '(?:^|\s)--type=' -and
        $commandLine -match '(?:^|\s)--remote-debugging-address(?:=|\s+)127\.0\.0\.1(?:\s|$)' -and
        $commandLine -match "(?:^|\s)--remote-debugging-port(?:=|\s+)$ExpectedPort(?:\s|$)"
}

function Test-CrsOwnedRendererEndpoint {
    param([int]$ProcessId, [int]$Port)

    if ($ProcessId -le 0 -or $Port -lt 1 -or $Port -gt 65535) { return $false }
    try {
        $listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $Port -State Listen -ErrorAction Stop)
        return @($listeners | Where-Object { [int]$_.OwningProcess -eq $ProcessId }).Count -eq 1
    } catch {
        # A port that cannot be tied to this exact process is never accepted as
        # repair evidence, including on systems where the TCP cmdlet is absent.
        return $false
    }
}

function Get-CrsOwnedProcessIdentity {
    param($Ownership)

    if ($null -eq $Ownership) { return $null }
    $owned = $false
    if ($null -ne $Ownership.PSObject.Properties['ProcessOwned']) {
        $owned = $Ownership.ProcessOwned -is [bool] -and [bool]$Ownership.ProcessOwned
    } elseif ($null -ne $Ownership.PSObject.Properties['launchProcessOwned']) {
        $owned = $Ownership.launchProcessOwned -is [bool] -and [bool]$Ownership.launchProcessOwned
    } elseif ($null -ne $Ownership.PSObject.Properties['processOwnership']) {
        $owned = [string]$Ownership.processOwnership -ceq 'helper-owned'
    } elseif ($null -ne $Ownership.PSObject.Properties['ProcessOwnership']) {
        $owned = [string]$Ownership.ProcessOwnership -ceq 'helper-owned'
    }
    if (-not $owned) { return $null }

    $processId = 0
    if ($null -ne $Ownership.PSObject.Properties['ProcessId']) {
        [void][int]::TryParse([string]$Ownership.ProcessId, [ref]$processId)
    } elseif ($null -ne $Ownership.PSObject.Properties['launchProcessId']) {
        [void][int]::TryParse([string]$Ownership.launchProcessId, [ref]$processId)
    }
    $startTimeFileTimeUtc = 0L
    if ($null -ne $Ownership.PSObject.Properties['StartTimeFileTimeUtc']) {
        [void][long]::TryParse([string]$Ownership.StartTimeFileTimeUtc, [ref]$startTimeFileTimeUtc)
    } elseif ($null -ne $Ownership.PSObject.Properties['ProcessStartTimeFileTimeUtc']) {
        [void][long]::TryParse([string]$Ownership.ProcessStartTimeFileTimeUtc, [ref]$startTimeFileTimeUtc)
    } elseif ($null -ne $Ownership.PSObject.Properties['launchProcessStartTimeFileTimeUtc']) {
        [void][long]::TryParse([string]$Ownership.launchProcessStartTimeFileTimeUtc, [ref]$startTimeFileTimeUtc)
    } elseif ($null -ne $Ownership.PSObject.Properties['ProcessStartToken']) {
        [void][long]::TryParse([string]$Ownership.ProcessStartToken, [ref]$startTimeFileTimeUtc)
    } elseif ($null -ne $Ownership.PSObject.Properties['launchProcessStartToken']) {
        [void][long]::TryParse([string]$Ownership.launchProcessStartToken, [ref]$startTimeFileTimeUtc)
    } elseif ($null -ne $Ownership.PSObject.Properties['startToken']) {
        [void][long]::TryParse([string]$Ownership.startToken, [ref]$startTimeFileTimeUtc)
    }
    $executablePath = $null
    if ($null -ne $Ownership.PSObject.Properties['ExecutablePath']) {
        $executablePath = [string]$Ownership.ExecutablePath
    } elseif ($null -ne $Ownership.PSObject.Properties['executablePath']) {
        $executablePath = [string]$Ownership.executablePath
    }
    if ($processId -le 0 -or $startTimeFileTimeUtc -le 0 -or [string]::IsNullOrWhiteSpace($executablePath)) {
        return $null
    }

    $identity = Get-CrsProcessIdentity -ProcessId $processId -ExecutablePath $executablePath
    $identityStartTimeFileTimeUtc = 0L
    if ($null -ne $identity -and $null -ne $identity.PSObject.Properties['StartTimeFileTimeUtc']) {
        [void][long]::TryParse([string]$identity.StartTimeFileTimeUtc, [ref]$identityStartTimeFileTimeUtc)
    } elseif ($null -ne $identity -and $null -ne $identity.PSObject.Properties['StartToken']) {
        [void][long]::TryParse([string]$identity.StartToken, [ref]$identityStartTimeFileTimeUtc)
    }
    if ($null -eq $identity -or
        [int]$identity.ProcessId -ne $processId -or
        $identityStartTimeFileTimeUtc -ne $startTimeFileTimeUtc -or
        -not [string]::Equals([string]$identity.ExecutablePath, $executablePath, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    return $identity
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
            throw 'ChatGPT/Codex appeared while the replacement session was preparing. It was left running and the launch was aborted.'
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
            launchProcessOwned = $false
            launchProcessStartTimeFileTimeUtc = $null
            processOwnership = 'unowned'
            # Renderer-only native sessions cannot contain the legacy scoped
            # proxy shim. Legacy command lines cannot prove whether it ran.
            proxyMode = if ($BridgeMode -ceq 'native-renderer') { $false } else { $null }
            proxyTransport = $null
            startedAtUtc = $null
        }
    }
    $candidates = @($candidates)
    if ($candidates.Count -ne 1) { return $null }
    return $candidates[0]
}

function Stop-CrsCodex {
    param($Ownership)

    $target = Get-CrsOwnedProcessIdentity -Ownership $Ownership
    if ($null -eq $target) { return $false }

    try {
        # Revalidate immediately before the signal. A reused PID or changed
        # executable must never receive a lifecycle signal from this helper.
        $current = Get-CrsOwnedProcessIdentity -Ownership $Ownership
        if ($null -eq $current) { return $false }
        Stop-Process -Id ([int]$current.ProcessId) -ErrorAction SilentlyContinue

        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 100
            $remaining = Get-CrsOwnedProcessIdentity -Ownership $Ownership
        } while ($null -ne $remaining -and [DateTime]::UtcNow -lt $deadline)

        if ($null -ne $remaining) {
            # Revalidation above still binds the forceful fallback to the same
            # PID, executable, and creation token.
            Stop-Process -Id ([int]$remaining.ProcessId) -Force -ErrorAction Stop
        }
        return $true
    } catch {
        throw
    }
}

function Assert-CrsNoUnownedCodexProcess {
    param(
        [string[]]$ExecutablePaths,
        $OwnedProcess
    )

    $ownedIdentity = if ($null -eq $OwnedProcess) { $null } else { Get-CrsOwnedProcessIdentity -Ownership $OwnedProcess }
    foreach ($executablePath in @($ExecutablePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        foreach ($process in @(Get-CrsCodexProcesses -ExecutablePath $executablePath)) {
            $processId = if ($null -ne $process.PSObject.Properties['Id']) { [int]$process.Id } else { [int]$process.ProcessId }
            $identity = Get-CrsProcessIdentity -ProcessId $processId -ExecutablePath $executablePath
            if ($null -eq $identity -or $null -eq $ownedIdentity -or
                [int]$identity.ProcessId -ne [int]$ownedIdentity.ProcessId -or
                [long]$identity.StartTimeFileTimeUtc -ne [long]$ownedIdentity.StartTimeFileTimeUtc -or
                -not [string]::Equals([string]$identity.ExecutablePath, [string]$ownedIdentity.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "A ChatGPT process at $executablePath is not helper-owned by this controller. It was left running and automatic lifecycle recovery was aborted."
            }
        }
    }
    return $ownedIdentity
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
    $launchOwnership = $null

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
            $workerStart = [Diagnostics.ProcessStartInfo]::new()
            $workerStart.FileName = $powerShell
            $workerStart.Arguments = $workerArguments
            $workerStart.UseShellExecute = $false
            $workerStart.CreateNoWindow = $true
            $workerStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $proxyWorker = [Diagnostics.Process]::Start($workerStart)

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
            $launchProcessId = 0
            if ($ExpectedPort -gt 0) {
                $identityDeadline = $null
                $identityAttempts = 0
                do {
                    $identityAttempts += 1
                    $launchedProcesses = @(
                        Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
                            Where-Object {
                                [string]::Equals([string]$_.ExecutablePath, [string]$Package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
                                [string]$_.CommandLine -notmatch '(?:^|\s)--type=' -and
                                [string]$_.CommandLine -match "(?:^|\s)--remote-debugging-port(?:=|\s+)$ExpectedPort(?:\s|$)"
                            }
                    )
                    if ($null -eq $identityDeadline) { $identityDeadline = [DateTime]::UtcNow.AddSeconds(5) }
                    if ($launchedProcesses.Count -eq 1) { break }
                    if ($launchedProcesses.Count -gt 1) { throw 'The package-context proxy launch produced multiple matching ChatGPT processes.' }
                    Start-Sleep -Milliseconds 100
                } while ($identityAttempts -lt 3 -or [DateTime]::UtcNow -lt $identityDeadline)
                if ($launchedProcesses.Count -ne 1) { throw 'The package-context proxy launch could not resolve the exact ChatGPT process identity.' }
                $launchOwnership = Get-CrsProcessIdentity -ProcessId ([int]$launchedProcesses[0].ProcessId) -ExecutablePath ([string]$Package.ExecutablePath)
                if ($null -eq $launchOwnership) { throw 'The package-context proxy launch could not prove the exact ChatGPT process identity.' }
                $launchProcessId = [uint32]$launchOwnership.ProcessId
            }
            Write-CrsLaunchDiagnostic -Method 'PackageContextEnvironmentProxy' -Succeeded $true -PrimaryError '' -FallbackError ''
            return [pscustomobject][ordered]@{
                Method = 'PackageContextEnvironmentProxy'
                ProcessId = $launchProcessId
                ExecutablePath = [string]$Package.ExecutablePath
                ProcessOwned = [bool]($null -ne $launchOwnership)
                ProcessStartTimeFileTimeUtc = if ($null -ne $launchOwnership) { [long]$launchOwnership.StartTimeFileTimeUtc } else { $null }
                ProcessOwnership = if ($null -ne $launchOwnership) { 'helper-owned' } else { 'unowned' }
            }
        } catch {
            if ($null -ne $launchOwnership) { [void](Stop-CrsCodex -Ownership $launchOwnership) }
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
        $preActivationProcesses = @(Get-CrsCodexProcesses -ExecutablePath ([string]$Package.ExecutablePath))
        if ($preActivationProcesses.Count -ne 0) {
            throw 'A ChatGPT main process appeared before package activation. It was left running and launch was aborted.'
        }
        $activationBoundaryFileTimeUtc = [DateTime]::UtcNow.ToFileTimeUtc()
        $output = @(& $script:PackageActivationLauncher $Package.AppUserModelId $argumentString 2>&1)
        $exitCode = $LASTEXITCODE
        [uint32]$activatedProcessId = 0
        if ($exitCode -ne 0 -or $output.Count -ne 1 -or
            -not [uint32]::TryParse(([string]$output[0]).Trim(), [ref]$activatedProcessId) -or
            $activatedProcessId -eq 0) {
            throw "Package activation failed with exit code ${exitCode}: $($output -join ' ')"
        }
        $launchOwnership = Get-CrsProcessIdentity -ProcessId ([int]$activatedProcessId) -ExecutablePath ([string]$Package.ExecutablePath)
        if ($null -ne $launchOwnership -and
            ([long]$launchOwnership.StartTimeFileTimeUtc -lt $activationBoundaryFileTimeUtc -or
                -not (Test-CrsExpectedDebugProcess -ProcessId ([int]$activatedProcessId) -ExecutablePath ([string]$Package.ExecutablePath) -ExpectedPort $ExpectedPort))) {
            $launchOwnership = $null
        }
        if ($ExpectedPort -gt 0 -and $null -eq $launchOwnership) {
            throw "Package activation returned process $activatedProcessId, but its exact executable and creation token could not be proved."
        }
        if ($ExpectedPort -gt 0 -and -not (Wait-CrsPortOpen -Port $ExpectedPort -TimeoutMilliseconds $PortTimeoutMilliseconds)) {
            if ($null -ne $launchOwnership) { [void](Stop-CrsCodex -Ownership $launchOwnership) }
            throw "Package activation returned process $activatedProcessId, but loopback port $ExpectedPort did not open."
        }
        Write-CrsLaunchDiagnostic -Method 'ApplicationActivationManager' -Succeeded $true -PrimaryError '' -FallbackError ''
        return [pscustomobject][ordered]@{
            Method = 'ApplicationActivationManager'
            ProcessId = [uint32]$activatedProcessId
            ExecutablePath = [string]$Package.ExecutablePath
            ProcessOwned = [bool]($null -ne $launchOwnership)
            ProcessStartTimeFileTimeUtc = if ($null -ne $launchOwnership) { [long]$launchOwnership.StartTimeFileTimeUtc } else { $null }
            ProcessOwnership = if ($null -ne $launchOwnership) { 'helper-owned' } else { 'unowned' }
        }
    } catch {
        if ($null -ne $launchOwnership) {
            [void](Stop-CrsCodex -Ownership $launchOwnership)
            $launchOwnership = $null
        }
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
            throw "The package-context fallback started, but loopback port $ExpectedPort did not open."
        }
        if ($ExpectedPort -gt 0) {
            $identityDeadline = [DateTime]::UtcNow.AddSeconds(5)
            $identityAttempts = 0
            do {
                $identityAttempts += 1
                $launchedProcesses = @(
                    Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
                        Where-Object {
                            [string]::Equals([string]$_.ExecutablePath, [string]$Package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
                            [string]$_.CommandLine -notmatch '(?:^|\s)--type=' -and
                            [string]$_.CommandLine -match "(?:^|\s)--remote-debugging-port(?:=|\s+)$ExpectedPort(?:\s|$)"
                        }
                )
                if ($launchedProcesses.Count -gt 1) { throw 'The package-context fallback produced multiple matching ChatGPT processes.' }
                if ($launchedProcesses.Count -eq 1) {
                    $launchOwnership = Get-CrsProcessIdentity -ProcessId ([int]$launchedProcesses[0].ProcessId) -ExecutablePath ([string]$Package.ExecutablePath)
                    if ($null -ne $launchOwnership) { break }
                }
                Start-Sleep -Milliseconds 100
            } while ($identityAttempts -lt 3 -or [DateTime]::UtcNow -lt $identityDeadline)
            if ($null -eq $launchOwnership) {
                throw 'The package-context fallback started, but the exact ChatGPT process identity could not be proved.'
            }
        }
        Write-CrsLaunchDiagnostic -Method 'Invoke-CommandInDesktopPackage' -Succeeded $true -PrimaryError $primaryError -FallbackError ''
        return [pscustomobject][ordered]@{
            Method = 'Invoke-CommandInDesktopPackage'
            ProcessId = if ($null -ne $launchOwnership) { [uint32]$launchOwnership.ProcessId } else { $null }
            ExecutablePath = [string]$Package.ExecutablePath
            ProcessOwned = [bool]($null -ne $launchOwnership)
            ProcessStartTimeFileTimeUtc = if ($null -ne $launchOwnership) { [long]$launchOwnership.StartTimeFileTimeUtc } else { $null }
            ProcessOwnership = if ($null -ne $launchOwnership) { 'helper-owned' } else { 'unowned' }
        }
    } catch {
        if ($null -ne $launchOwnership) {
            [void](Stop-CrsCodex -Ownership $launchOwnership)
            $launchOwnership = $null
        }
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
    param($Package, [int]$RendererPort, $MainPort, $Probe, $Launch, [bool]$ProxyMode, [string]$BridgeMode, [string]$ProxyFingerprint, [bool]$LegacyDeviceKeyCompatibility = $false)

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
        launchProcessOwned = if ($null -ne $Launch.PSObject.Properties['ProcessOwned']) { [bool]$Launch.ProcessOwned } else { $false }
        launchProcessStartTimeFileTimeUtc = if ($null -ne $Launch.PSObject.Properties['ProcessStartTimeFileTimeUtc'] -and $null -ne $Launch.ProcessStartTimeFileTimeUtc) { [long]$Launch.ProcessStartTimeFileTimeUtc } else { $null }
        processOwnership = if ($null -ne $Launch.PSObject.Properties['ProcessOwned'] -and [bool]$Launch.ProcessOwned) { 'helper-owned' } else { 'unowned' }
        proxyMode = $ProxyMode
        proxyFingerprint = if ($ProxyMode) { $ProxyFingerprint } else { $null }
        legacyDeviceKeyCompatibility = $LegacyDeviceKeyCompatibility
        proxyTransport = if ($ProxyMode) { 'all-connections-proxy-v1' } else { $null }
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $json = $state | ConvertTo-Json -Depth 4
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $temporaryPath = Join-Path $script:StateRoot ('.codexremote-simple-session.{0}.{1}.tmp' -f $PID,[guid]::NewGuid().ToString('N'))
    $replacementBackupPath = Join-Path $script:StateRoot ('.codexremote-simple-session.{0}.{1}.replace-backup' -f $PID,[guid]::NewGuid().ToString('N'))
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
            # Windows PowerShell binds the null third argument to an empty path,
            # which makes File.Replace fail whenever a prior session record exists.
            # A unique same-volume backup keeps the replacement atomic; the old
            # state remains untouched if the replace cannot complete.
            [IO.File]::Replace($temporaryPath, $script:StatePath, $replacementBackupPath)
        } else {
            [IO.File]::Move($temporaryPath, $script:StatePath)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $replacementBackupPath -PathType Leaf) {
            Remove-Item -LiteralPath $replacementBackupPath -Force -ErrorAction SilentlyContinue
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

function Open-CrsInspectorHook {
    param([Diagnostics.Process]$Process, [ValidateRange(0, 5000)][int]$WaitMilliseconds = 3000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WaitMilliseconds)
    do {
        if ($Process.HasExited) { throw 'ChatGPT exited while its attachment hook was being prepared. No replacement was started.' }
        try {
            return [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting("node-debug-handler-$($Process.Id)", [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
        } catch [IO.FileNotFoundException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Runtime inspector hook unavailable: this ChatGPT process does not expose the attachment hook. It was left running.'
            }
            Start-Sleep -Milliseconds 100
        } catch [UnauthorizedAccessException] {
            throw 'Runtime inspector hook unavailable: access to this ChatGPT process was denied. It was left running.'
        }
    } while ($true)
}

function Invoke-CrsManagedNativeSessionRepair {
    param(
        $Package,
        $Node,
        $State,
        $Compatibility,
        [bool]$ProxyMode,
        [string]$ProxyFingerprint,
        [bool]$LegacyDeviceKeysRequired
    )

    $result = [ordered]@{
        Attempted = $false
        Repaired = $false
        Probe = $null
        Reason = $null
    }
    # Only a state record for a helper-owned packaged session is eligible. An
    # ordinary process remains on the existing attachment path, and an
    # attached-existing-process record has no helper-owned renderer endpoint.
    if ($null -eq $State -or
        $null -eq $State.PSObject.Properties['launchProcessOwned'] -or
        $State.launchProcessOwned -isnot [bool] -or -not [bool]$State.launchProcessOwned -or
        $null -eq $State.PSObject.Properties['launchMethod'] -or
        [string]$State.launchMethod -notin @('PackageContextEnvironmentProxy', 'ApplicationActivationManager', 'Invoke-CommandInDesktopPackage')) {
        return [pscustomobject]$result
    }
    # A retained record from an exited or replaced app is not authoritative
    # for the current instance. Let ordinary attachment identify that instance.
    if ($null -eq (Get-CrsOwnedProcessIdentity -Ownership $State)) {
        return [pscustomobject]$result
    }
    $result.Attempted = $true

    if ($null -eq $Compatibility -or [string]$Compatibility.bridgeMode -cne 'native-renderer' -or
        $null -eq $State.PSObject.Properties['bridgeMode'] -or [string]$State.bridgeMode -cne 'native-renderer') {
        $result.Reason = 'The saved session is not a native-renderer session.'
        return [pscustomobject]$result
    }
    if (-not (Test-CrsProxyModeProof -State $State -RequestedProxyMode $ProxyMode -RequestedProxyFingerprint $ProxyFingerprint)) {
        $result.Reason = 'The saved session connection mode does not match the requested proxy mode.'
        return [pscustomobject]$result
    }
    if (-not (Test-CrsLegacyDeviceKeyModeProof -State $State -Required $LegacyDeviceKeysRequired)) {
        $result.Reason = 'The saved session legacy device-key mode could not be proved.'
        return [pscustomobject]$result
    }
    $savedLegacyMode = $false
    if ($null -ne $State.PSObject.Properties['legacyDeviceKeyCompatibility']) {
        if ($State.legacyDeviceKeyCompatibility -isnot [bool]) {
            $result.Reason = 'The saved session legacy device-key mode is invalid.'
            return [pscustomobject]$result
        }
        $savedLegacyMode = [bool]$State.legacyDeviceKeyCompatibility
    }
    if ($savedLegacyMode -ne $LegacyDeviceKeysRequired) {
        $result.Reason = 'The saved session legacy device-key mode does not match the requested mode.'
        return [pscustomobject]$result
    }

    $expectedExecutablePath = $null
    $savedExecutablePath = $null
    try {
        $expectedExecutablePath = [IO.Path]::GetFullPath([string]$Package.ExecutablePath)
        $savedExecutablePath = [IO.Path]::GetFullPath([string]$State.executablePath)
    } catch {
        $result.Reason = 'The saved session executable identity is invalid.'
        return [pscustomobject]$result
    }
    $privateRuntimeSession = $ProxyMode -or $savedLegacyMode
    if ($privateRuntimeSession) {
        $privateRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\patched-chatgpt')).TrimEnd('\') + '\'
        if (-not $savedExecutablePath.StartsWith($privateRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($savedExecutablePath) -ine 'ChatGPT.exe') {
            $result.Reason = 'The saved proxy session executable is outside the managed private runtime.'
            return [pscustomobject]$result
        }
    } elseif (-not [string]::Equals($savedExecutablePath, $expectedExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
        $result.Reason = 'The saved session executable does not match the installed package.'
        return [pscustomobject]$result
    }

    $processId = 0
    $savedStartTime = 0L
    $rendererPort = 0
    if ($null -eq $State.PSObject.Properties['launchProcessId'] -or
        -not [int]::TryParse([string]$State.launchProcessId, [ref]$processId) -or $processId -le 0 -or
        $null -eq $State.PSObject.Properties['launchProcessStartTimeFileTimeUtc'] -or
        -not [long]::TryParse([string]$State.launchProcessStartTimeFileTimeUtc, [ref]$savedStartTime) -or $savedStartTime -le 0 -or
        $null -eq $State.PSObject.Properties['rendererPort'] -or
        -not [int]::TryParse([string]$State.rendererPort, [ref]$rendererPort) -or $rendererPort -lt 1024 -or $rendererPort -gt 65535) {
        $result.Reason = 'The saved session does not contain a complete process or renderer endpoint identity.'
        return [pscustomobject]$result
    }

    $identity = Get-CrsProcessIdentity -ProcessId $processId -ExecutablePath $savedExecutablePath
    if ($null -eq $identity -or [int]$identity.ProcessId -ne $processId -or
        [long]$identity.StartTimeFileTimeUtc -ne $savedStartTime -or
        -not [string]::Equals([string]$identity.ExecutablePath, $savedExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
        $result.Reason = 'The saved process identity no longer matches; no app was launched or stopped.'
        return [pscustomobject]$result
    }

    # Listening on a port is not ownership evidence. Require both the exact
    # ChatGPT command line and the kernel listener owner for this endpoint.
    if (-not (Test-CrsExpectedDebugProcess -ProcessId $processId -ExecutablePath $savedExecutablePath -ExpectedPort $rendererPort) -or
        -not (Test-CrsOwnedRendererEndpoint -ProcessId $processId -Port $rendererPort)) {
        $result.Reason = 'The saved renderer endpoint is not owned by the exact ChatGPT process.'
        return [pscustomobject]$result
    }

    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($processId)
        [void]$process.Handle
        if ($process.HasExited) { throw 'The saved ChatGPT process exited before repair.' }
        $identityAfterAttach = Get-CrsProcessIdentity -ProcessId $processId -ExecutablePath $savedExecutablePath
        if ($null -eq $identityAfterAttach -or [long]$identityAfterAttach.StartTimeFileTimeUtc -ne $savedStartTime -or
            -not [string]::Equals([string]$identityAfterAttach.ExecutablePath, $savedExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The ChatGPT process identity changed during repair.'
        }
        $bridge = Invoke-CrsBridge -Node $Node -RendererPort $rendererPort -MainPort $null -BridgeMode 'native-renderer'
        if ($null -eq $bridge -or $bridge.ok -isnot [bool] -or -not $bridge.ok -or
            $bridge.renderer.probe.proof -isnot [bool] -or -not $bridge.renderer.probe.proof) {
            throw 'The native-renderer bridge did not return complete repair proof.'
        }
        if ($process.HasExited) { throw 'ChatGPT exited during repair; no replacement was started.' }

        # Preserve the existing launch method and lifecycle ownership. Repair
        # only re-injects the bridge into the verified live process.
        $launch = [pscustomobject]@{
            Method = [string]$State.launchMethod
            ProcessId = $processId
            ProcessOwned = $true
            ProcessStartTimeFileTimeUtc = $savedStartTime
        }
        $statePackage = $Package
        if (-not [string]::Equals($savedExecutablePath, $expectedExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
            # Proxy and legacy-compatible sessions run from a retained private
            # runtime. Keep that exact executable and its recorded package
            # metadata when refreshing the state record.
            $statePackage = [pscustomobject]@{
                FullName = if ($null -ne $State.PSObject.Properties['packageFullName']) { [string]$State.packageFullName } else { [string]$Package.FullName }
                Version = if ($null -ne $State.PSObject.Properties['packageVersion']) { [string]$State.packageVersion } else { [string]$Package.Version }
                ExecutablePath = $savedExecutablePath
            }
        }
        Write-CrsState -Package $statePackage -RendererPort $rendererPort -MainPort $null -Probe $Compatibility -Launch $launch -ProxyMode $ProxyMode -BridgeMode 'native-renderer' -ProxyFingerprint $ProxyFingerprint -LegacyDeviceKeyCompatibility $LegacyDeviceKeysRequired
        $result.Repaired = $true
        $result.Probe = $bridge
        return [pscustomobject]$result
    } catch {
        $result.Reason = $_.Exception.Message
        return [pscustomobject]$result
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Connect-CrsExistingApp {
    param($Package, $Node, $Compatibility, [bool]$ProxyMode, [bool]$LegacyDeviceKeysRequired)

    # Activating an existing process never grants lifecycle ownership. The
    # process handle remains open until injection completes, preventing PID reuse.
    if ($Compatibility.bridgeMode -cne 'native-renderer') {
        throw 'This running app does not expose the native renderer capability needed for live attachment. It was left running.'
    }
    if ($ProxyMode -or $LegacyDeviceKeysRequired) {
        throw 'The running ordinary app cannot acquire startup-only proxy or legacy-key settings through attachment. It was left running; no connection settings were changed.'
    }
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction Stop | Where-Object {
        [string]::Equals([string]$_.ExecutablePath, [string]$Package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
        [string]$_.CommandLine -notmatch '(?:^|\s)--type='
    })
    if ($candidates.Count -ne 1) { throw 'Live attachment requires exactly one matching ChatGPT main process. No app was launched or stopped.' }
    $candidate = $candidates[0]
    if ([string]$candidate.CommandLine -match '--remote-debugging-port(?:=|\s)') { return $false }
    $inspectorPort = 9229
    $portMatch = [regex]::Match([string]$candidate.CommandLine, '(?:^|\s)--inspect(?:-port)?=(?<value>\S+)')
    if ($portMatch.Success) {
        if ($portMatch.Groups['value'].Value -notmatch '^(?:127\.0\.0\.1:)?(?<port>\d+)$') {
            throw 'The running app has a non-loopback or unsupported inspector address. No activation was attempted.'
        }
        $inspectorPort = [int]$Matches.port
    }
    if ($inspectorPort -lt 1024 -or $inspectorPort -gt 65535) { throw 'The running app has an unsupported inspector port.' }
    $process = [Diagnostics.Process]::GetProcessById([int]$candidate.ProcessId)
    $mapping = $null
    try {
        [void]$process.Handle
        $started = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
        if ($process.HasExited -or -not [string]::Equals($process.MainModule.FileName, [string]$Package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'ChatGPT changed during attachment discovery. It was left untouched.'
        }
        # A loopback listener that merely answers is not evidence that this
        # process owns the Node inspector. Refuse a foreign listener before
        # sending any inspector command or activation request.
        if ((Test-CrsPortOpen -Port $inspectorPort) -and
            -not (Test-CrsOwnedRendererEndpoint -ProcessId $process.Id -Port $inspectorPort)) {
            throw 'The running app inspector port is owned by a different local process. No activation was attempted.'
        }
        # This is the runtime's registered Windows activation hook, not a
        # version/signature allowlist or a patched executable.
        $mapping = Open-CrsInspectorHook -Process $process
        $attachmentScript = Join-Path $script:RuntimeRoot 'attach-existing.cjs'
        $previousErrorPreference = $ErrorActionPreference
        try {
            # Windows PowerShell 5.1 turns redirected native stderr into error
            # records. Inspect the exit code before applying our own failure policy.
            $ErrorActionPreference = 'Continue'
            $output = @(& $Node.Path $attachmentScript ([string]$process.Id) ([string]$Package.ExecutablePath) ([string]$inspectorPort) '--attach' ([string]($TimeoutSeconds * 1000)) 2>&1)
            $attachmentExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorPreference }
        if ($attachmentExitCode -ne 0 -or $output.Count -ne 1) { throw "Live attachment failed: $($output -join ' ')" }
        $attached = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
        if ($attached.pid -ne $process.Id -or $attached.rendererPort -ne $inspectorPort -or $attached.transport -cne 'electron-main-inspector-v1' -or $process.HasExited) {
            throw 'Live attachment did not prove the expected running app.'
        }
        if (-not (Test-CrsOwnedRendererEndpoint -ProcessId $process.Id -Port $inspectorPort)) {
            throw 'The running app inspector endpoint changed ownership during attachment. No bridge or state was written.'
        }
        [void](Invoke-CrsBridge -Node $Node -RendererPort $inspectorPort -MainPort $null -BridgeMode 'native-renderer')
        if ($process.HasExited) { throw 'ChatGPT exited during attachment; no replacement was started.' }
        $launch = [pscustomobject]@{ Method = 'attached-existing-process'; ProcessId = $process.Id; ProcessOwned = $false; ProcessStartTimeFileTimeUtc = $started }
        Write-CrsState -Package $Package -RendererPort $inspectorPort -MainPort $null -Probe $Compatibility -Launch $launch -ProxyMode $false -BridgeMode 'native-renderer'
        Write-Host 'Attached and injected into the already-running ChatGPT window without restarting it.' -ForegroundColor Green
        return $true
    } finally {
        if ($mapping) { $mapping.Dispose() }
        $process.Dispose()
    }
}

function Invoke-CrsProbeExisting {
    param($Node, $State)

    if ($null -eq $State -or -not (Test-CrsPortOpen -Port ([int]$State.rendererPort))) { return $null }
    if ($null -ne $State.PSObject.Properties['launchMethod'] -and $State.launchMethod -ceq 'attached-existing-process') {
        # Bind the saved inspector endpoint to the local process before
        # trusting any PID/path values returned by the Node service.
        if (-not (Test-CrsOwnedRendererEndpoint -ProcessId ([int]$State.launchProcessId) -Port ([int]$State.rendererPort))) { return $null }
        $identity = Get-CrsProcessIdentity -ProcessId ([int]$State.launchProcessId) -ExecutablePath ([string]$State.executablePath)
        if ($null -eq $identity -or $null -eq $State.PSObject.Properties['launchProcessStartTimeFileTimeUtc'] -or
            $identity.StartTimeFileTimeUtc -ne $State.launchProcessStartTimeFileTimeUtc) { return $null }
        # A surviving app process alone does not prove this port still belongs
        # to it. Verify the inspector identity before reusing the saved endpoint.
        $previousErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $identityProbe = @(& $Node.Path (Join-Path $script:RuntimeRoot 'attach-existing.cjs') ([string]$State.launchProcessId) ([string]$State.executablePath) ([string]$State.rendererPort) '--verify-only' 2>&1)
            $probeExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousErrorPreference }
        if ($probeExitCode -ne 0) { return $null }
        if (-not (Test-CrsOwnedRendererEndpoint -ProcessId ([int]$State.launchProcessId) -Port ([int]$State.rendererPort))) { return $null }
    }
    $orchestrator = Join-Path $script:RuntimeRoot 'orchestrator.js'
    $arguments = @($orchestrator, '--mode', $(if ($State.bridgeMode -ceq 'native-renderer') { 'probe-renderer' } else { 'probe' }), '--renderer-port', ([string]$State.rendererPort))
    if ($State.bridgeMode -ceq 'legacy-main-shim') { $arguments += @('--main-port', ([string]$State.mainPort)) }
    $arguments += @('--timeout-ms', '3000')
    $previousErrorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 promotes redirected native stderr to an
        # exception under Stop. Capture the exit code and restore the caller's
        # policy so a failed probe remains an unknown session instead.
        $ErrorActionPreference = 'Continue'
        $output = @(& $Node.Path @arguments 2>&1)
        $probeExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousErrorPreference }
    if ($probeExitCode -ne 0 -or $output.Count -ne 1) { return $null }
    try { return ([string]$output[0] | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Test-CrsProxyModeProof {
    param($State, [bool]$RequestedProxyMode, [string]$RequestedProxyFingerprint)

    if ($null -eq $State -or $null -eq $State.PSObject.Properties['proxyMode']) { return $false }
    if ($State.proxyMode -isnot [bool]) { return $false }
    if ([bool]$State.proxyMode -ne $RequestedProxyMode) { return $false }
    $proxyTransport = if ($null -eq $State.PSObject.Properties['proxyTransport']) { '' } else { [string]$State.proxyTransport }
    if (-not [string]::IsNullOrEmpty($proxyTransport) -and $proxyTransport -cne 'all-connections-proxy-v1') {
        return $false
    }
    if (-not $RequestedProxyMode) {
        return [string]::IsNullOrEmpty($proxyTransport) -and
            ($null -eq $State.PSObject.Properties['proxyFingerprint'] -or [string]::IsNullOrEmpty([string]$State.proxyFingerprint))
    }
    if ($RequestedProxyFingerprint -notmatch '^[a-f0-9]{64}$' -or
        $null -eq $State.PSObject.Properties['proxyFingerprint']) { return $false }
    return $proxyTransport -ceq 'all-connections-proxy-v1' -and
        [string]$State.proxyFingerprint -ceq $RequestedProxyFingerprint
}

function Get-CrsProxyFingerprint {
    param([Parameter(Mandatory)][string]$ProxyServer)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($ProxyServer)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
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

    $rollbackOwnership = if ($null -eq $State) { $null } else { Get-CrsOwnedProcessIdentity -Ownership $State }
    $rollbackPaths = @($Package.ExecutablePath)
    if ($null -ne $State -and -not [string]::IsNullOrWhiteSpace([string]$State.executablePath)) {
        $rollbackPaths += [string]$State.executablePath
    }
    [void](Assert-CrsNoUnownedCodexProcess -ExecutablePaths $rollbackPaths -OwnedProcess $rollbackOwnership)
    if ($null -ne $rollbackOwnership -and -not (Stop-CrsCodex -Ownership $rollbackOwnership)) {
        if (@(Get-CrsCodexProcesses -ExecutablePath ([string]$rollbackOwnership.ExecutablePath)).Count -ne 0) {
            throw 'Rollback could not prove the helper-owned ChatGPT process identity at the stop boundary. The process was left running and Codex was not relaunched.'
        }
    }
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
            Classification = $compatibility.classification
            BridgeMode = $bridgeMode
            LegacyDeviceKeyCompatibilityNeeded = $legacyDeviceKeyCompatibilityNeeded
            LocalSessionActive = [bool]($null -ne $liveProbe -and $liveProbe.ok -and $liveProbe.renderer.probe.proof)
            SessionRecord = if ($null -eq $state) { $null } else { $script:StatePath }
        }
        break
    }
    'Enable' {
        $resolvedProxyServer = if ($UseProxy) { Resolve-CrsProxyServer -RequestedProxy $ProxyServer } else { $null }
        $requestedProxyFingerprint = if ($UseProxy) { Get-CrsProxyFingerprint -ProxyServer $resolvedProxyServer } else { $null }
        $existing = Invoke-CrsProbeExisting -Node $node -State $state
        if ($null -eq $existing -or -not $existing.ok -or -not $existing.renderer.probe.proof) {
            $discovered = Get-CrsDiscoverableSession -Package $package -BridgeMode $bridgeMode
            if ($null -ne $discovered) {
                $discoveredProbe = Invoke-CrsProbeExisting -Node $node -State $discovered
                if ($null -ne $discoveredProbe -and $discoveredProbe.ok -and $discoveredProbe.renderer.probe.proof -and
                    (Test-CrsProxyModeProof -State $discovered -RequestedProxyMode ([bool]$UseProxy) -RequestedProxyFingerprint $requestedProxyFingerprint) -and
                    (Test-CrsLegacyDeviceKeyModeProof -State $discovered -Required $legacyDeviceKeyCompatibilityNeeded)) {
                    Write-CrsState -Package $package -RendererPort $discovered.rendererPort -MainPort $discovered.mainPort -Probe $compatibility -Launch ([pscustomobject]@{ Method = 'adopted-existing-session'; ProcessId = $discovered.launchProcessId }) -ProxyMode ([bool]$discovered.proxyMode) -BridgeMode $bridgeMode -ProxyFingerprint $requestedProxyFingerprint
                    $state = Read-CrsState
                    $existing = $discoveredProbe
                    Write-Host 'Adopted the existing capability-proven loopback session without relaunching ChatGPT.' -ForegroundColor Green
                }
            }
        }
        if ($null -ne $existing -and $existing.ok -and $existing.renderer.probe.proof) {
            if ((Test-CrsProxyModeProof -State $state -RequestedProxyMode ([bool]$UseProxy) -RequestedProxyFingerprint $requestedProxyFingerprint) -and
                (Test-CrsLegacyDeviceKeyModeProof -State $state -Required $legacyDeviceKeyCompatibilityNeeded)) {
                Write-Host 'The local Control other devices bridge is already active in the requested proxy mode.' -ForegroundColor Green
                break
            }
            if (-not $AttachOnly) { Write-Host 'The requested connection compatibility differs from the active session; ChatGPT will be relaunched.' -ForegroundColor Yellow }
        }
        if ($AttachOnly) {
            if ($null -eq $existing -or -not $existing.ok -or -not $existing.renderer.probe.proof) {
                $repair = Invoke-CrsManagedNativeSessionRepair -Package $package -Node $node -State $state -Compatibility $compatibility -ProxyMode ([bool]$UseProxy) -ProxyFingerprint $requestedProxyFingerprint -LegacyDeviceKeysRequired $legacyDeviceKeyCompatibilityNeeded
                if ($repair.Attempted) {
                    if ($repair.Repaired) {
                        Write-Host 'Re-injected the native-renderer bridge into the already-running managed ChatGPT session without restarting it.' -ForegroundColor Green
                        break
                    }
                    throw "The managed ChatGPT session could not be repaired without restarting it: $($repair.Reason)"
                }
            }
            if (($null -eq $existing -or -not $existing.ok -or -not $existing.renderer.probe.proof) -and
                (Connect-CrsExistingApp -Package $package -Node $node -Compatibility $compatibility -ProxyMode ([bool]$UseProxy) -LegacyDeviceKeysRequired $legacyDeviceKeyCompatibilityNeeded)) {
                break
            }
            throw 'ChatGPT is already open, but a matching Remote Enabler session is not available for attachment. The running app was left untouched. Remote Enabler can attach to sessions launched with its local endpoint and matching connection settings.'
        }
        if (-not $PSCmdlet.ShouldProcess('the current OpenAI Codex session', 'Close it, relaunch with loopback debug ports, and enable the capability-tested bridge')) {
            break
        }

        $rendererPort = Get-CrsFreePort
        $mainPort = $null
        if ($bridgeMode -ceq 'legacy-main-shim') {
            do { $mainPort = Get-CrsFreePort } while ($mainPort -eq $rendererPort)
        }
        $launchPackage = $package
        $sessionStopped = $false
        $previousOwnership = $null
        $launch = $null
        try {
            if ($UseProxy) {
                Write-Host 'Protected proxy mode is enabled for all external ChatGPT and helper connections.' -ForegroundColor Yellow
            }
            if ($bridgeMode -ceq 'native-renderer' -and ($UseProxy -or $legacyDeviceKeyCompatibilityNeeded)) {
                Write-Host 'Preparing a private ChatGPT runtime from the installed capability-compatible files.' -ForegroundColor Yellow
                $launchPackage = New-CrsProxyRuntimePackage -Package $package -Node $node -ProxyEnabled ([bool]$UseProxy) -LegacyDeviceKeys $legacyDeviceKeyCompatibilityNeeded
                if ($UseProxy) { Write-Host 'Signed enrollment retains the canonical ChatGPT URL while all external traffic uses the protected proxy.' -ForegroundColor Yellow }
                if ($legacyDeviceKeyCompatibilityNeeded) { Write-Host 'Existing protected enrollment keys remain available; new keys use the native Windows provider.' -ForegroundColor Yellow }
            }
            Assert-CrsNoExistingAppForReplacement -Package $package -LaunchPackage $launchPackage -Enabled:$RefuseExistingApp
            $sessionStopped = $true
            $replacementPaths = @([string]$package.ExecutablePath, [string]$launchPackage.ExecutablePath)
            $previousOwnership = if ($null -eq $state) { $null } else { Get-CrsOwnedProcessIdentity -Ownership $state }
            [void](Assert-CrsNoUnownedCodexProcess -ExecutablePaths $replacementPaths -OwnedProcess $previousOwnership)
            if ($null -ne $previousOwnership) {
                if (-not (Stop-CrsCodex -Ownership $previousOwnership)) {
                    throw 'The helper-owned ChatGPT process changed before replacement. It was left running and the replacement was aborted.'
                }
            }
            if (-not [string]::Equals([string]$launchPackage.ExecutablePath, [string]$package.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)) {
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
            if ($UseProxy) {
                $launchArguments.EnvironmentProxyServer = $resolvedProxyServer
                $launchArguments.NodePath = $node.Path
            }
            $launch = Start-CrsPackagedCodex @launchArguments
            $bridge = Invoke-CrsBridge -Node $node -RendererPort $rendererPort -MainPort $mainPort -ProxyServer $(if ($UseProxy) { $resolvedProxyServer } else { $null }) -BridgeMode $bridgeMode
            Write-CrsState -Package $launchPackage -RendererPort $rendererPort -MainPort $mainPort -Probe $compatibility -Launch $launch -ProxyMode ([bool]$UseProxy) -BridgeMode $bridgeMode -ProxyFingerprint $requestedProxyFingerprint -LegacyDeviceKeyCompatibility $legacyDeviceKeyCompatibilityNeeded
            Write-Host 'Control other devices and macOS-style connection grouping are active for this Codex session.' -ForegroundColor Green
            Write-Host 'Open Settings > Connections > Control other devices.'
            Write-Host 'In the sidebar, open Project sidebar options and choose By connection when desired.'
            Write-Warning 'By connection groups chats by host but does not preserve nested project headings. Use By project to retain project grouping.'
            Write-Warning 'The renderer debug endpoint remains reachable by processes running as your Windows user until Codex exits or rollback is run.'
        } catch {
            if (-not $sessionStopped) { throw }
            Write-Warning 'Enable failed. Restoring an ordinary Codex session.'
            $launchOwnership = if ($null -eq $launch) { $null } else { Get-CrsOwnedProcessIdentity -Ownership $launch }
            if ($null -ne $launchOwnership) {
                if (-not (Stop-CrsCodex -Ownership $launchOwnership)) {
                    throw 'Enable failed and the replacement ChatGPT process changed before rollback. It was left running and the ordinary session was not started.'
                }
            } else {
                $remainingPaths = @([string]$package.ExecutablePath, [string]$launchPackage.ExecutablePath)
                [void](Assert-CrsNoUnownedCodexProcess -ExecutablePaths $remainingPaths -OwnedProcess $null)
            }
            foreach ($port in @($rendererPort, $mainPort) | Where-Object { $null -ne $_ }) { [void](Wait-CrsPortClosed -Port $port) }
            if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
            Start-CrsOrdinaryCodex -Package $package
            throw
        }
        break
    }
}
