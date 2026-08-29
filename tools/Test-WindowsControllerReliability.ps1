[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stablePath = Join-Path $root 'windows\CodexRemoteSimple\CodexRemoteSimple.ps1'
$launcherSource = Join-Path $root 'windows\CodexRemoteMobileProject\ChatGPTCustomLauncher.cs'

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

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-custom-launcher-test-' + [guid]::NewGuid().ToString('N'))
$first = $null
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $compilerCandidates = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) { throw 'The .NET Framework C# compiler was not found.' }
    $launcher = Join-Path $temporaryRoot 'ChatGPT Custom.exe'
    & $compiler /nologo /target:winexe "/out:$launcher" $launcherSource
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Temporary launcher compilation failed.' }
    $marker = Join-Path $temporaryRoot 'child-started.txt'
    $startupScript = @"
param([string]`$Action)
[IO.File]::WriteAllText('$($marker.Replace("'", "''"))', 'started')
Start-Sleep -Seconds 4
"@
    [IO.File]::WriteAllText((Join-Path $temporaryRoot 'MobileProjectStartup.ps1'), $startupScript, [Text.UTF8Encoding]::new($false))
    $first = Start-Process -FilePath $launcher -ArgumentList '--startup' -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $marker)) { throw 'First launcher did not acquire the mutex and start its controller.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $second = Start-Process -FilePath $launcher -ArgumentList '--startup' -PassThru -Wait
    $watch.Stop()
    if ($second.ExitCode -ne 15 -or $watch.Elapsed.TotalSeconds -ge 2) {
        throw "Concurrent launcher did not fail promptly and explicitly: exit=$($second.ExitCode), seconds=$($watch.Elapsed.TotalSeconds)"
    }
    if (-not $first.WaitForExit(7000) -or $first.ExitCode -ne 0) { throw 'First launcher did not finish successfully.' }

    [pscustomobject]@{
        ExistingSessionDiscovered = $true
        UnknownProxyModeRejected = $true
        DurableProxyModeMatchedStrictly = $true
        NonLoopbackRejected = $true
        AmbiguousSessionRejected = $true
        ConcurrentLauncherExitCode = $second.ExitCode
        ConcurrentLauncherPromptlyReleased = $true
    } | ConvertTo-Json
} finally {
    if ($first -and -not $first.HasExited) { Stop-Process -Id $first.Id -Force }
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolved) -and
        [IO.Path]::GetFullPath((Split-Path -Parent $resolved)) -eq $temporary -and
        [IO.Path]::GetFileName($resolved) -match '^chatgpt-custom-launcher-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
