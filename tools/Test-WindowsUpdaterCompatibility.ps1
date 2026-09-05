[CmdletBinding()]
param(
    [string]$PreviousInstallRoot = 'C:\ProgramData\CodexRemoteFeatures\releases\ChatGPT-Remote-Enabler-Windows-x64-v1.4.4',
    [string]$ArtifactsDirectory
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ArtifactsDirectory)) { $ArtifactsDirectory = Join-Path $PSScriptRoot '..\dist' }
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\VERSION') -Raw).Trim()
$archiveName = "ChatGPT-Remote-Enabler-Windows-x64-$version.zip"
$sumsName = "SHA256SUMS-$version.txt"
$archivePath = Join-Path $ArtifactsDirectory $archiveName
$sumsPath = Join-Path $ArtifactsDirectory $sumsName
if (-not (Test-Path -LiteralPath (Join-Path $PreviousInstallRoot 'Update-ChatGPTRemote.ps1') -PathType Leaf)) { throw 'Previous installed updater was not found.' }
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or -not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) { throw 'Build release artifacts first.' }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-remote-updater-test-" + [guid]::NewGuid().ToString('N'))
$server = $null
try {
    $serverRoot = Join-Path $temporaryRoot 'server'
    $fixtureRoot = Join-Path $temporaryRoot 'fixture'
    New-Item -ItemType Directory -Path $serverRoot,$fixtureRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $PreviousInstallRoot '*') -Destination $fixtureRoot -Recurse -Force
    Copy-Item -LiteralPath $archivePath,$sumsPath -Destination $serverRoot -Force

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $baseUrl = "http://127.0.0.1:$port"
    $release = [ordered]@{
        tag_name = $version
        draft = $false
        prerelease = $false
        assets = @(
            [ordered]@{ name = $archiveName; browser_download_url = "$baseUrl/$archiveName" },
            [ordered]@{ name = $sumsName; browser_download_url = "$baseUrl/$sumsName" }
        )
    }
    [IO.File]::WriteAllText((Join-Path $serverRoot 'release.json'), ($release | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

    $python = (Get-Command python.exe -ErrorAction Stop).Source
    $server = Start-Process -FilePath $python -ArgumentList @('-m','http.server',[string]$port,'--bind','127.0.0.1','--directory',$serverRoot) -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        try { Invoke-WebRequest -Uri "$baseUrl/release.json" -UseBasicParsing -TimeoutSec 1 | Out-Null; $ready = $true } catch { Start-Sleep -Milliseconds 100 }
    } until ($ready -or [DateTime]::UtcNow -ge $deadline)
    if (-not $ready) { throw 'Loopback release fixture did not start.' }

    $previousUpdater = Join-Path $PreviousInstallRoot 'Update-ChatGPTRemote.ps1'
    $result = & $previousUpdater -Action Update -LatestReleaseUrl "$baseUrl/release.json" -InstallRoot $fixtureRoot -AllowInsecureTransport | ConvertFrom-Json
    if ($result.updated -ne $true -or $result.version -ne $version) { throw 'Previous updater did not accept the new rooted release contract.' }
    if ((Get-Content -LiteralPath (Join-Path $fixtureRoot 'VERSION') -Raw).Trim() -ne $version) { throw 'Updater fixture did not reach the expected version.' }
    $probe = & (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1') -Action Probe -LatestReleaseUrl "$baseUrl/release.json" -InstallRoot $fixtureRoot -AllowInsecureTransport | ConvertFrom-Json
    if ($probe.localVersion -ne $version) { throw 'Updated updater probe returned the wrong version.' }

    # Exercise the exact Auto action used by v1.5.31 launchers, with isolated
    # preferences and rollback state. No installed app or shortcut is changed.
    $autoFixture = Join-Path $temporaryRoot 'auto-fixture'
    New-Item -ItemType Directory -Path $autoFixture -Force | Out-Null
    Copy-Item -Path (Join-Path $PreviousInstallRoot '*') -Destination $autoFixture -Recurse -Force
    $previousLocalAppData = $env:LOCALAPPDATA
    $previousAutoUpdate = $env:CHATGPT_REMOTE_AUTO_UPDATE
    try {
        $env:LOCALAPPDATA = Join-Path $temporaryRoot 'auto-state'
        $env:CHATGPT_REMOTE_AUTO_UPDATE = '1'
        $autoResult = & $previousUpdater -Action Auto -CheckIntervalHours 0 -LatestReleaseUrl "$baseUrl/release.json" -InstallRoot $autoFixture -AllowInsecureTransport | ConvertFrom-Json
        if ($autoResult.updated -ne $true -or (Get-Content -LiteralPath (Join-Path $autoFixture 'VERSION') -Raw).Trim() -ne $version) {
            throw 'The previous launcher Auto action did not install the normal release.'
        }
    } finally {
        $env:LOCALAPPDATA = $previousLocalAppData
        $env:CHATGPT_REMOTE_AUTO_UPDATE = $previousAutoUpdate
    }

    $flatExtract = Join-Path $temporaryRoot 'flat-extract'
    $flatFixture = Join-Path $temporaryRoot 'flat-fixture'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $flatExtract
    $rootedDirectory = @(Get-ChildItem -LiteralPath $flatExtract -Directory)
    if ($rootedDirectory.Count -ne 1) { throw 'Rooted archive fixture was malformed.' }
    New-Item -ItemType Directory -Path $flatFixture -Force | Out-Null
    Copy-Item -Path (Join-Path $PreviousInstallRoot '*') -Destination $flatFixture -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $serverRoot $archiveName) -Force
    Compress-Archive -Path (Join-Path $rootedDirectory[0].FullName '*') -DestinationPath (Join-Path $serverRoot $archiveName) -CompressionLevel Optimal
    $flatHash = (Get-FileHash -LiteralPath (Join-Path $serverRoot $archiveName) -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $serverRoot $sumsName), "$flatHash *$archiveName$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
    $newUpdater = Join-Path $repositoryRoot 'windows\Update-ChatGPTRemote.ps1'
    $flatResult = & $newUpdater -Action Update -LatestReleaseUrl "$baseUrl/release.json" -InstallRoot $flatFixture -AllowInsecureTransport | ConvertFrom-Json
    if ($flatResult.updated -ne $true -or (Get-Content -LiteralPath (Join-Path $flatFixture 'VERSION') -Raw).Trim() -ne $version) {
        throw 'New updater did not accept the flat archive and star checksum format.'
    }

    $blockedFixture = Join-Path $temporaryRoot 'blocked-fixture'
    New-Item -ItemType Directory -Path $blockedFixture -Force | Out-Null
    Copy-Item -Path (Join-Path $PreviousInstallRoot '*') -Destination $blockedFixture -Recurse -Force
    $realHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $serverRoot $archiveName), '<!doctype html><title>blocked</title>', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $serverRoot $sumsName), "$realHash  $archiveName$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
    $securityBlockDetected = $false
    try {
        & $newUpdater -Action Update -LatestReleaseUrl "$baseUrl/release.json" -InstallRoot $blockedFixture -AllowInsecureTransport | Out-Null
    } catch {
        $securityBlockDetected = $_.Exception.Message -match 'proxy or network security gateway'
    }
    if (-not $securityBlockDetected) { throw 'The updater did not identify an HTML security block page.' }

    [pscustomobject]@{
        PreviousUpdaterAcceptedRelease = $true
        PreviousLauncherAutoInstalledRelease = $true
        NewUpdaterAcceptedFlatStar = $true
        SecurityBlockDetected = $true
        RootedArchive = $archiveName
        UpdatedVersion = $version
        RollbackCreated = Test-Path -LiteralPath $result.rollbackPath -PathType Container
    } | ConvertTo-Json
} finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
