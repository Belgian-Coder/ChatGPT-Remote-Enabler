[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stablePath = Join-Path $root 'windows\CodexRemoteSimple\CodexRemoteSimple.ps1'
$launcherSource = Join-Path $root 'windows\CodexRemoteMobileProject\ChatGPTCustomLauncher.cs'
$rootLauncherSource = Join-Path $root 'windows\ChatGPTRemoteLauncher.cs'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($stablePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Stable controller parse failed: $($errors[0].Message)" }
$controllerFunctions = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @('Get-CrsDiscoverableSession', 'Test-CrsProxyModeProof')
}, $true)
foreach ($functionName in @('Get-CrsDiscoverableSession', 'Test-CrsProxyModeProof')) {
    $definition = $controllerFunctions | Where-Object Name -eq $functionName | Select-Object -First 1
    if (-not $definition) { throw "Stable controller function is missing: $functionName" }
    Invoke-Expression $definition.Extent.Text
}

$package = [pscustomobject]@{
    FullName = 'OpenAI.Codex_test'
    Version = '1.0.0.0'
    ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe'
}
$validProcess = [pscustomobject]@{
    ProcessId = 4242
    ExecutablePath = $package.ExecutablePath
    CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=24547 --inspect=127.0.0.1:24548'
}
$openPorts = { param([int]$Port) return $Port -in @(24547, 24548) }
$discovered = Get-CrsDiscoverableSession -Package $package -Processes @($validProcess) -PortTester $openPorts
if (-not $discovered -or $discovered.rendererPort -ne 24547 -or $discovered.mainPort -ne 24548 -or
    $discovered.launchMethod -ne 'adopted-existing-session') {
    throw 'A unique audited loopback session was not discovered.'
}
$nativeProcess = $validProcess.PSObject.Copy()
$nativeProcess.ProcessId = 4343
$nativeProcess.CommandLine = '"C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe" --remote-debugging-address=127.0.0.1 --remote-debugging-port=24547'
$nativeDiscovered = Get-CrsDiscoverableSession -Package $package -BridgeMode 'native-renderer' -Processes @($nativeProcess) -PortTester $openPorts
if (-not $nativeDiscovered -or $nativeDiscovered.schemaVersion -ne 2 -or
    $nativeDiscovered.bridgeMode -ne 'native-renderer' -or $nativeDiscovered.rendererPort -ne 24547 -or
    $null -ne $nativeDiscovered.mainPort -or $nativeDiscovered.proxyMode -ne $false) {
    throw 'A renderer-only native Windows session was not safely discovered.'
}
if ($null -ne $discovered.proxyMode -or (Test-CrsProxyModeProof -State $discovered -RequestedProxyMode $false)) {
    throw 'A discovered session with no durable state was incorrectly treated as proof of direct mode.'
}
$directState = [pscustomobject]@{ proxyMode = $false }
$proxyState = [pscustomobject]@{ proxyMode = $true }
if (-not (Test-CrsProxyModeProof -State $directState -RequestedProxyMode $false) -or
    -not (Test-CrsProxyModeProof -State $proxyState -RequestedProxyMode $true) -or
    (Test-CrsProxyModeProof -State $directState -RequestedProxyMode $true) -or
    (Test-CrsProxyModeProof -State ([pscustomobject]@{ proxyMode = 'false' }) -RequestedProxyMode $false)) {
    throw 'Durable proxy-mode proof was not matched strictly.'
}
$remoteAddress = $validProcess.PSObject.Copy()
$remoteAddress.CommandLine = $remoteAddress.CommandLine.Replace('127.0.0.1 --remote', '0.0.0.0 --remote')
if (Get-CrsDiscoverableSession -Package $package -Processes @($remoteAddress) -PortTester $openPorts) {
    throw 'A non-loopback debug session was accepted for adoption.'
}
if (Get-CrsDiscoverableSession -Package $package -Processes @($validProcess, $validProcess.PSObject.Copy()) -PortTester $openPorts) {
    throw 'Ambiguous debug sessions were accepted for adoption.'
}

function Wait-ForLineCount {
    param([string]$Path, [int]$Count, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $actual = if (Test-Path -LiteralPath $Path -PathType Leaf) { @([IO.File]::ReadAllLines($Path)).Count } else { 0 }
        } catch [IO.IOException] {
            $actual = -1
        } catch [UnauthorizedAccessException] {
            $actual = -1
        }
        if ($actual -ge $Count) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Count lines in $Path; found $actual."
}

function New-ReplacementLauncher {
    param([string]$Source, [string]$Destination, [string]$Compiler, [string]$TemporaryRoot)
    $text = Get-Content -LiteralPath $Source -Raw
    $match = [regex]::Match($text, 'AssemblyFileVersion\("([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"\)')
    if (-not $match.Success) { throw "Launcher source has no assembly file version: $Source" }
    $version = [version]$match.Groups[1].Value
    $replacementVersion = '{0}.{1}.{2}.{3}' -f $version.Major,$version.Minor,$version.Build,($version.Revision + 1)
    $replacementSource = Join-Path $TemporaryRoot (([IO.Path]::GetFileNameWithoutExtension($Destination)) + '-replacement.cs')
    $replacementExe = Join-Path $TemporaryRoot (([IO.Path]::GetFileNameWithoutExtension($Destination)) + '-replacement.exe')
    [IO.File]::WriteAllText($replacementSource, $text.Replace($match.Groups[1].Value, $replacementVersion), [Text.UTF8Encoding]::new($false))
    & $Compiler /nologo /target:winexe "/out:$replacementExe" $replacementSource
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $replacementExe -PathType Leaf)) { throw "Replacement launcher compilation failed: $Destination" }
    Move-Item -LiteralPath $replacementExe -Destination $Destination -Force
    if ((Get-Item -LiteralPath $Destination).VersionInfo.FileVersion -ne $replacementVersion) { throw "Running launcher replacement failed: $Destination" }
    return $replacementVersion
}

$startupSourceText = Get-Content -LiteralPath (Join-Path $root 'windows\CodexRemoteMobileProject\MobileProjectStartup.ps1') -Raw
$rootWorkerSourceText = Get-Content -LiteralPath (Join-Path $root 'windows\Enable-ChatGPTRemote.ps1') -Raw
foreach ($worker in @(
    [pscustomobject]@{ Name = 'MobileProjectStartup'; Text = $startupSourceText; Updater = '& $updateController -Action Auto'; Injection = '& $stableController @stableArguments' },
    [pscustomobject]@{ Name = 'Enable-ChatGPTRemote'; Text = $rootWorkerSourceText; Updater = '& $updater -Action Auto'; Injection = '& $stable -Action Enable' }
)) {
    $capture = $worker.Text.IndexOf('$parentProcess = Capture-ExactParent', [StringComparison]::Ordinal)
    $signal = $worker.Text.IndexOf('Signal-Handshake', $capture, [StringComparison]::Ordinal)
    $wait = $worker.Text.IndexOf('$parentProcess.WaitForExit(30000)', $capture, [StringComparison]::Ordinal)
    $update = $worker.Text.IndexOf($worker.Updater, $wait, [StringComparison]::Ordinal)
    $injection = $worker.Text.IndexOf($worker.Injection, $update, [StringComparison]::Ordinal)
    if ($capture -lt 0 -or $signal -lt $capture -or $wait -lt $signal -or $update -lt $wait -or $injection -lt $update -or
        -not $worker.Text.Contains("Local\ChatGPTCustomInjectionLauncher") -or
        -not $worker.Text.Contains('if ($actual -ne $ParentProcessStartTimeFileTimeUtc)') -or
        $worker.Text.Contains('[Math]::Abs([double]$actual')) {
        throw "$($worker.Name) does not capture, signal, wait, and update under the shared mutex in the required order."
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-custom-launcher-test-' + [guid]::NewGuid().ToString('N'))
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $compilerCandidates = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) { throw 'The .NET Framework C# compiler was not found.' }
    $launcher = Join-Path $temporaryRoot 'ChatGPT Custom.exe'
    $rootLauncher = Join-Path $temporaryRoot 'ChatGPT Remote Enabler.exe'
    & $compiler /nologo /target:winexe "/out:$launcher" $launcherSource
    if ($LASTEXITCODE -ne 0) { throw 'Temporary custom launcher compilation failed.' }
    & $compiler /nologo /target:winexe "/out:$rootLauncher" $rootLauncherSource
    if ($LASTEXITCODE -ne 0) { throw 'Temporary root launcher compilation failed.' }

    $readyLog = Join-Path $temporaryRoot 'worker-ready.log'
    $afterParentLog = Join-Path $temporaryRoot 'worker-after-parent.log'
    $finishedLog = Join-Path $temporaryRoot 'worker-finished.log'
    $workerErrorLog = Join-Path $temporaryRoot 'worker-error.log'
    $workerScript = @"
param(
    [string]`$Action,
    [switch]`$UseProxy,
    [switch]`$ReplaceRunningApp,
    [int]`$ParentProcessId,
    [long]`$ParentProcessStartTimeFileTimeUtc,
    [string]`$ReadyEventName,
    [string]`$RejectedEventName
)
`$mutex = [Threading.Mutex]::new(`$false, 'Local\ChatGPTCustomInjectionLauncher')
`$ready = [Threading.EventWaitHandle]::OpenExisting(`$ReadyEventName)
`$rejected = [Threading.EventWaitHandle]::OpenExisting(`$RejectedEventName)
`$acquired = `$false
`$parent = `$null
`$kind = if ([IO.Path]::GetFileName(`$PSCommandPath) -eq 'Enable-ChatGPTRemote.ps1') { 'root' } else { 'custom' }
try {
    try { `$acquired = `$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { `$acquired = `$true }
    if (-not `$acquired) { [void]`$rejected.Set(); exit 15 }
    `$parent = [Diagnostics.Process]::GetProcessById(`$ParentProcessId)
    `$actual = `$parent.StartTime.ToUniversalTime().ToFileTimeUtc()
    if (`$actual -ne `$ParentProcessStartTimeFileTimeUtc) { throw 'parent start time mismatch' }
    [IO.File]::AppendAllText('$($readyLog.Replace("'", "''"))', "`$kind|`$Action|proxy=`$UseProxy|replace=`$ReplaceRunningApp$([Environment]::NewLine)")
    [void]`$ready.Set()
    if (-not `$parent.WaitForExit(30000)) { throw 'parent did not exit' }
    [IO.File]::AppendAllText('$($afterParentLog.Replace("'", "''"))', "`$kind$([Environment]::NewLine)")
    `$holdMilliseconds = if ((`$kind -eq 'custom' -and `$UseProxy -and -not `$ReplaceRunningApp) -or `$kind -eq 'root') { 5000 } else { 100 }
    Start-Sleep -Milliseconds `$holdMilliseconds
} catch {
    [IO.File]::AppendAllText('$($workerErrorLog.Replace("'", "''"))', "`$kind|`$(`$_.Exception.Message)$([Environment]::NewLine)")
    [void]`$rejected.Set()
    throw
} finally {
    if (`$parent) { `$parent.Dispose() }
    `$ready.Dispose()
    `$rejected.Dispose()
    if (`$acquired) { `$mutex.ReleaseMutex() }
    `$mutex.Dispose()
    if (`$acquired) { [IO.File]::AppendAllText('$($finishedLog.Replace("'", "''"))', "`$kind$([Environment]::NewLine)") }
}
"@
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'MobileProjectStartup.ps1'), $workerScript, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'Enable-ChatGPTRemote.ps1'), $workerScript, [Text.UTF8Encoding]::new($false))

    $first = Start-Process -FilePath $launcher -ArgumentList '--proxy --startup' -PassThru
    $processes.Add($first)
    Wait-ForLineCount -Path $readyLog -Count 1
    if (-not $first.WaitForExit(5000) -or $first.ExitCode -ne 0) { throw 'Custom launcher did not exit successfully after the worker handshake.' }
    $customReplacementVersion = New-ReplacementLauncher -Source $launcherSource -Destination $launcher -Compiler $compiler -TemporaryRoot $temporaryRoot
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $concurrent = Start-Process -FilePath $launcher -ArgumentList '--startup' -PassThru -Wait
    $watch.Stop()
    $processes.Add($concurrent)
    if ($concurrent.ExitCode -ne 15 -or $watch.Elapsed.TotalSeconds -ge 5) { throw "Concurrent custom launcher was not rejected promptly: $($concurrent.ExitCode)." }
    Wait-ForLineCount -Path $finishedLog -Count 1

    foreach ($case in @(
        [pscustomobject]@{ Arguments = '--startup'; ReadyCount = 2; FinishedCount = 2 },
        [pscustomobject]@{ Arguments = ''; ReadyCount = 3; FinishedCount = 3 },
        [pscustomobject]@{ Arguments = '--proxy'; ReadyCount = 4; FinishedCount = 4 }
    )) {
        $startArguments = @{ FilePath = $launcher; PassThru = $true }
        if (-not [string]::IsNullOrEmpty($case.Arguments)) { $startArguments.ArgumentList = $case.Arguments }
        $process = Start-Process @startArguments
        $processes.Add($process)
        try {
            Wait-ForLineCount -Path $readyLog -Count $case.ReadyCount
        } catch {
            [void]$process.WaitForExit(6000)
            $exitDetail = if ($process.HasExited) { [string]$process.ExitCode } else { 'still running' }
            $workerErrors = if (Test-Path -LiteralPath $workerErrorLog) { [IO.File]::ReadAllText($workerErrorLog) } else { '<none>' }
            throw "Custom launcher case did not complete its worker handshake: $($case.Arguments); launcher=$exitDetail; workerErrors=$workerErrors; $($_.Exception.Message)"
        }
        if (-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0) { throw "Custom launcher case failed: $($case.Arguments)" }
        try {
            Wait-ForLineCount -Path $finishedLog -Count $case.FinishedCount
        } catch {
            $workerErrors = if (Test-Path -LiteralPath $workerErrorLog) { [IO.File]::ReadAllText($workerErrorLog) } else { '<none>' }
            throw "Custom worker did not finish: $($case.Arguments); workerErrors=$workerErrors; $($_.Exception.Message)"
        }
    }

    $rootProcess = Start-Process -FilePath $rootLauncher -PassThru
    $processes.Add($rootProcess)
    Wait-ForLineCount -Path $readyLog -Count 5
    if (-not $rootProcess.WaitForExit(5000) -or $rootProcess.ExitCode -ne 0) { throw 'Root launcher did not exit successfully after the worker handshake.' }
    $rootReplacementVersion = New-ReplacementLauncher -Source $rootLauncherSource -Destination $rootLauncher -Compiler $compiler -TemporaryRoot $temporaryRoot
    $crossEntry = Start-Process -FilePath $launcher -ArgumentList '--startup' -PassThru -Wait
    $processes.Add($crossEntry)
    if ($crossEntry.ExitCode -ne 15) { throw 'Root/custom cross-entry collision was not rejected.' }
    Wait-ForLineCount -Path $finishedLog -Count 5

    $invocations = @([IO.File]::ReadAllLines($readyLog))
    $expectedInvocations = @(
        'custom|Run|proxy=True|replace=False',
        'custom|Run|proxy=False|replace=False',
        'custom|Run|proxy=False|replace=True',
        'custom|Run|proxy=True|replace=True',
        'root||proxy=False|replace=False'
    )
    if (($invocations -join "`n") -ne ($expectedInvocations -join "`n")) { throw "Launcher arguments changed across handoff: $($invocations -join '; ')" }
    if (@([IO.File]::ReadAllLines($afterParentLog)).Count -ne 5) { throw 'A worker continued before its exact launcher parent exited.' }

    [pscustomobject]@{
        WorkerOwnsCrossEntryMutex = $true
        LauncherExitsAfterHandshake = $true
        CustomLauncherReplacementVersion = $customReplacementVersion
        RootLauncherReplacementVersion = $rootReplacementVersion
        ExactParentWaitCompleted = $true
        FourArgumentModesPreserved = $true
        ExistingSessionDiscovered = $true
        NativeRendererOnlySessionDiscovered = $true
        UpdaterCompletesBeforeInjection = $true
        UnknownProxyModeRejected = $true
        DurableProxyModeMatchedStrictly = $true
        NonLoopbackRejected = $true
        AmbiguousSessionRejected = $true
        ConcurrentLauncherExitCode = $concurrent.ExitCode
        CrossEntryExitCode = $crossEntry.ExitCode
    } | ConvertTo-Json
} finally {
    foreach ($process in $processes) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        if ($process) { $process.Dispose() }
    }
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolved) -and
        [IO.Path]::GetFullPath((Split-Path -Parent $resolved)) -eq $temporary -and
        [IO.Path]::GetFileName($resolved) -match '^chatgpt-custom-launcher-test-[0-9a-f]{32}$') {
        for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $resolved); $attempt++) {
            try { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 100 }
        }
    }
}
