[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updaterPath = Join-Path $repositoryRoot 'windows\Update-ChatGPTRemote.ps1'
$windowsPowerShell = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { $null }
if (-not $windowsPowerShell -or -not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    [pscustomobject]@{ WindowsPowerShell51 = $false; Skipped = $true } | ConvertTo-Json
    return
}

function Invoke-WindowsPowerShellCapture {
    param([string]$Command)

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $output = @(& $windowsPowerShell -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>&1)
    $exitCode = $LASTEXITCODE
    $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    return [pscustomobject]@{ exitCode = $exitCode; text = $text }
}

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'$($Value.Replace("'", "''"))'"
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-remote-nongit-test-" + [guid]::NewGuid().ToString('N'))
$serverJob = $null
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $fixtureRoot = Join-Path $temporaryRoot 'packaged-install'
    $fixtureLocalAppData = Join-Path $temporaryRoot 'local-app-data'
    New-Item -ItemType Directory -Path $fixtureRoot,$fixtureLocalAppData -Force | Out-Null
    Copy-Item -LiteralPath $updaterPath -Destination (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'VERSION'), "v9.8.7$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
    $manifestLines = foreach ($relative in @('Update-ChatGPTRemote.ps1', 'VERSION')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $fixtureRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$relative"
    }
    [IO.File]::WriteAllText(
        (Join-Path $fixtureRoot 'RELEASE-MANIFEST.sha256'),
        ([string]::Join([Environment]::NewLine, $manifestLines) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    $env:LOCALAPPDATA = $fixtureLocalAppData
    $quotedUpdater = Quote-PowerShellLiteral (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1')
    $quotedFixture = Quote-PowerShellLiteral $fixtureRoot
    $probeCapture = Invoke-WindowsPowerShellCapture "& $quotedUpdater -Action Probe -InstallRoot $quotedFixture 2>&1"
    if ($probeCapture.exitCode -ne 0) { throw "Packaged Probe failed: $($probeCapture.text)" }
    if ($probeCapture.text -match 'fatal: not a git repository|NativeCommandError') {
        throw "Packaged Probe leaked Git discovery diagnostics: $($probeCapture.text)"
    }
    $probe = $probeCapture.text | ConvertFrom-Json
    if ($probe.installKind -ne 'release' -or $probe.localVersion -ne 'v9.8.7') {
        throw 'Packaged Probe did not retain release-mode detection.'
    }

    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    $baseUrl = "http://127.0.0.1:$port"
    $releaseJson = [ordered]@{
        tag_name = 'v9.8.7'
        draft = $false
        prerelease = $false
        assets = @(
            [ordered]@{ name = 'ChatGPT-Remote-Enabler-Windows-x64-v9.8.7.zip'; browser_download_url = "$baseUrl/release.zip" },
            [ordered]@{ name = 'SHA256SUMS-v9.8.7.txt'; browser_download_url = "$baseUrl/SHA256SUMS.txt" }
        )
    } | ConvertTo-Json -Depth 5 -Compress
    $serverJob = Start-Job -ArgumentList $port,$releaseJson -ScriptBlock {
        param($Port, $Body)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        try {
            for ($request = 0; $request -lt 2; $request++) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 500
                    $buffer = [byte[]]::new(4096)
                    try { [void]$stream.Read($buffer, 0, $buffer.Length) } catch [IO.IOException] {}
                    try {
                        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                        $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                        $stream.Flush()
                    } catch [IO.IOException] {}
                } finally {
                    $client.Dispose()
                }
            }
        } finally {
            $listener.Stop()
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $readyClient = [Net.Sockets.TcpClient]::new()
        try {
            $readyClient.Connect([Net.IPAddress]::Loopback, $port)
            $serverReady = $true
        } catch {
            Start-Sleep -Milliseconds 100
        } finally {
            $readyClient.Dispose()
        }
    } until ($serverReady -or [DateTime]::UtcNow -ge $deadline)
    if (-not $serverReady) { throw 'Loopback release fixture did not start.' }

    $quotedReleaseUrl = Quote-PowerShellLiteral "$baseUrl/release.json"
    $autoCommand = "& $quotedUpdater -Action Auto -InstallRoot $quotedFixture -LatestReleaseUrl $quotedReleaseUrl -CheckIntervalHours 0 -AllowInsecureTransport 2>&1"
    $autoCapture = Invoke-WindowsPowerShellCapture $autoCommand
    if ($autoCapture.exitCode -ne 0) { throw "Packaged Auto failed: $($autoCapture.text)" }
    if ($autoCapture.text -match 'fatal: not a git repository|NativeCommandError') {
        throw "Packaged Auto leaked Git discovery diagnostics: $($autoCapture.text)"
    }
    $auto = $autoCapture.text | ConvertFrom-Json
    if ($auto.method -ne 'verified-release' -or $auto.updated -ne $false -or $auto.localVersion -ne 'v9.8.7') {
        throw 'Packaged Auto did not retain verified-release behavior.'
    }

    $sourceUpdater = Quote-PowerShellLiteral $updaterPath
    $sourceInstallRoot = Quote-PowerShellLiteral (Join-Path $repositoryRoot 'windows')
    $sourceCapture = Invoke-WindowsPowerShellCapture "& $sourceUpdater -Action Probe -InstallRoot $sourceInstallRoot 2>&1"
    if ($sourceCapture.exitCode -ne 0) { throw "Source checkout Probe failed: $($sourceCapture.text)" }
    $sourceProbe = $sourceCapture.text | ConvertFrom-Json
    if ($sourceProbe.installKind -ne 'git-checkout') { throw 'Genuine source checkout detection was weakened.' }

    [pscustomobject]@{
        WindowsPowerShell51 = $true
        PackagedProbeQuiet = $true
        PackagedAutoQuiet = $true
        PackagedInstallKind = $probe.installKind
        AutoMethod = $auto.method
        SourceInstallKind = $sourceProbe.installKind
    } | ConvertTo-Json
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    if ($serverJob) {
        Stop-Job -Job $serverJob -ErrorAction SilentlyContinue
        Remove-Job -Job $serverJob -Force -ErrorAction SilentlyContinue
    }
    $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
