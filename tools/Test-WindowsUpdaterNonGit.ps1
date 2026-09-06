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
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # A deliberately failing child is test data. Windows PowerShell emits
        # its redirected stderr as NativeCommandError records in this host.
        $ErrorActionPreference = 'Continue'
        $output = @(& $windowsPowerShell -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
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
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'windows\update-transaction.js') -Destination (Join-Path $fixtureRoot 'update-transaction.js')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'VERSION'), "v9.8.7$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
    $manifestLines = foreach ($relative in @('Update-ChatGPTRemote.ps1', 'update-transaction.js', 'VERSION')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $fixtureRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$relative"
    }
    [IO.File]::WriteAllText(
        (Join-Path $fixtureRoot 'RELEASE-MANIFEST.sha256'),
        ([string]::Join([Environment]::NewLine, $manifestLines) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    $prepareArchivePath = Join-Path $temporaryRoot 'prepare-release.zip'
    Compress-Archive -Path (Join-Path $fixtureRoot '*') -DestinationPath $prepareArchivePath -CompressionLevel Optimal
    $prepareArchiveHash = (Get-FileHash -LiteralPath $prepareArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $prepareArchiveBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($prepareArchivePath))

    $env:LOCALAPPDATA = $fixtureLocalAppData
    $quotedUpdater = Quote-PowerShellLiteral (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1')
    $quotedFixture = Quote-PowerShellLiteral $fixtureRoot
    $probeCapture = Invoke-WindowsPowerShellCapture "& $quotedUpdater -Action Probe -InstallRoot $quotedFixture 2>&1"
    if ($probeCapture.exitCode -ne 0) { throw "Packaged Probe failed: $($probeCapture.text)" }
    if ($probeCapture.text -match 'fatal: not a git repository|NativeCommandError') {
        throw "Packaged Probe leaked Git discovery diagnostics: $($probeCapture.text)"
    }
    $probe = $probeCapture.text | ConvertFrom-Json
    if ($probe.installKind -ne 'release' -or $probe.localVersion -ne 'v9.8.7' -or $probe.checkIntervalHours -ne 0) {
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
    $prepareReleaseJson = [ordered]@{
        tag_name = 'v9.8.7'
        draft = $false
        prerelease = $false
        assets = @(
            [ordered]@{ name = 'ChatGPT-Remote-Enabler-Windows-x64-v9.8.7.zip'; browser_download_url = "$baseUrl/prepare-release.zip"; digest = "sha256:$prepareArchiveHash" },
            [ordered]@{ name = 'SHA256SUMS-v9.8.7.txt'; browser_download_url = "$baseUrl/prepare-SHA256SUMS.txt" }
        )
    } | ConvertTo-Json -Depth 5 -Compress
    $serverJob = Start-Job -ArgumentList $port,$releaseJson,$prepareReleaseJson,$prepareArchiveBase64,$prepareArchiveHash -ScriptBlock {
        param($Port, $Body, $PrepareBody, $PrepareArchiveBase64, $PrepareHash)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        try {
            for ($request = 0; $request -lt 20; $request++) {
                $requestDeadline = [DateTime]::UtcNow.AddSeconds(30)
                while (-not $listener.Pending()) {
                    if ([DateTime]::UtcNow -ge $requestDeadline) { return }
                    Start-Sleep -Milliseconds 25
                }
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 500
                    $buffer = [byte[]]::new(4096)
                    $readCount = 0
                    try { $readCount = $stream.Read($buffer, 0, $buffer.Length) } catch [IO.IOException] {}
                    $requestText = [Text.Encoding]::ASCII.GetString($buffer, 0, $readCount)
                    try {
                        $contentType = 'application/json'
                        $bodyBytes = if ($requestText -match '^GET /prepare-release\.zip ') {
                            $contentType = 'application/zip'
                            [Convert]::FromBase64String($PrepareArchiveBase64)
                        } elseif ($requestText -match '^GET /prepare-SHA256SUMS\.txt ') {
                            $contentType = 'text/plain'
                            [Text.Encoding]::UTF8.GetBytes("$PrepareHash *ChatGPT-Remote-Enabler-Windows-x64-v9.8.7.zip`n")
                        } elseif ($requestText -match '^GET /prepare-release\.json ') {
                            [Text.Encoding]::UTF8.GetBytes($PrepareBody)
                        } elseif ($requestText -match '^GET /SHA256SUMS\.txt ') {
                            $contentType = 'text/plain'
                            [Text.Encoding]::UTF8.GetBytes((('a' * 64) + ' *ChatGPT-Remote-Enabler-Windows-x64-v9.8.7.zip' + "`n"))
                        } else {
                            [Text.Encoding]::UTF8.GetBytes($Body)
                        }
                        $header = "HTTP/1.1 200 OK`r`nContent-Type: $contentType`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
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

    $temporaryCheckRootsBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'chatgpt-remote-check-*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $guardedCheckCommand = @'
function Remove-Item {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Path')]
        [string[]]$Path,
        [Parameter(Mandatory, ParameterSetName = 'LiteralPath')]
        [string[]]$LiteralPath,
        [switch]$Recurse,
        [switch]$Force
    )
    $targets = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') { @($LiteralPath) } else { @($Path) }
    if (@($targets | Where-Object { $_ -like '*chatgpt-remote-check-*' }).Count -gt 0) {
        throw 'The PowerShell provider must not clean up the exact-owned archive-hash directory.'
    }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
& __UPDATER__ -Action Check -InstallRoot __INSTALL__ -LatestReleaseUrl __RELEASE__ -AllowInsecureTransport 2>&1
'@
    $guardedCheckCommand = $guardedCheckCommand.Replace('__UPDATER__', $quotedUpdater).Replace('__INSTALL__', $quotedFixture).Replace('__RELEASE__', $quotedReleaseUrl)
    $guardedCheckCapture = Invoke-WindowsPowerShellCapture $guardedCheckCommand
    if ($guardedCheckCapture.exitCode -ne 0) { throw "Packaged Check cleanup regression failed: $($guardedCheckCapture.text)" }
    $guardedCheck = $guardedCheckCapture.text | ConvertFrom-Json
    if ($guardedCheck.method -ne 'verified-release' -or $guardedCheck.archiveSha256 -ne ('a' * 64)) {
        throw 'Packaged Check did not return the published archive hash after exact-owned cleanup.'
    }
    $temporaryCheckRootsAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'chatgpt-remote-check-*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $leakedCheckRoots = @($temporaryCheckRootsAfter | Where-Object { $_ -notin $temporaryCheckRootsBefore })
    if ($leakedCheckRoots.Count -gt 0) {
        throw "Packaged Check left an archive-hash temporary directory: $($leakedCheckRoots -join ', ')"
    }

    $preparedDirectory = Join-Path $temporaryRoot 'prepared-release'
    $temporaryPrepareRootsBefore = @([IO.Directory]::GetDirectories([IO.Path]::GetTempPath(), 'chatgpt-remote-prepare-*'))
    $quotedPreparedDirectory = Quote-PowerShellLiteral $preparedDirectory
    $quotedPrepareReleaseUrl = Quote-PowerShellLiteral "$baseUrl/prepare-release.json"
    $guardedPrepareCommand = @'
function Remove-Item {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Path')]
        [string[]]$Path,
        [Parameter(Mandatory, ParameterSetName = 'LiteralPath')]
        [string[]]$LiteralPath,
        [switch]$Recurse,
        [switch]$Force
    )
    $targets = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') { @($LiteralPath) } else { @($Path) }
    if ($Recurse -and @($targets | Where-Object { $_ -like '*chatgpt-remote-prepare-*' -or $_ -like '*.prepare-*' }).Count -gt 0) {
        throw 'The PowerShell provider must not clean up updater-owned preparation directories.'
    }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
& __UPDATER__ -Action Prepare -InstallRoot __INSTALL__ -LatestReleaseUrl __RELEASE__ -AllowInsecureTransport -TargetVersion 'v9.8.7' -ExpectedArchiveSha256 '__HASH__' -PreparedDirectory __PREPARED__ 2>&1
'@
    $guardedPrepareCommand = $guardedPrepareCommand.Replace('__UPDATER__', $quotedUpdater).Replace('__INSTALL__', $quotedFixture).Replace('__RELEASE__', $quotedPrepareReleaseUrl).Replace('__HASH__', $prepareArchiveHash).Replace('__PREPARED__', $quotedPreparedDirectory)
    $guardedPrepareCapture = Invoke-WindowsPowerShellCapture $guardedPrepareCommand
    if ($guardedPrepareCapture.exitCode -ne 0) { throw "Packaged Prepare cleanup regression failed: $($guardedPrepareCapture.text)" }
    $guardedPrepare = $guardedPrepareCapture.text | ConvertFrom-Json
    if ($guardedPrepare.prepared -ne $true -or $guardedPrepare.version -ne 'v9.8.7' -or $guardedPrepare.archiveSha256 -ne $prepareArchiveHash) {
        throw 'Packaged Prepare did not return the pinned prepared-release result.'
    }
    $temporaryPrepareRootsAfter = @([IO.Directory]::GetDirectories([IO.Path]::GetTempPath(), 'chatgpt-remote-prepare-*'))
    $leakedPrepareRoots = @($temporaryPrepareRootsAfter | Where-Object { $_ -notin $temporaryPrepareRootsBefore })
    if ($leakedPrepareRoots.Count -gt 0) {
        throw "Packaged Prepare left an updater-owned temporary directory: $($leakedPrepareRoots -join ', ')"
    }

    $helperFixtureRoot = Join-Path $temporaryRoot 'owned-cleanup-helper'
    $quotedHelperFixtureRoot = Quote-PowerShellLiteral $helperFixtureRoot
    $helperSafetyCommand = @'
. __UPDATER__ -Action Probe -InstallRoot __INSTALL__ | Out-Null
$fixtureRoot = __FIXTURE__
$allowedParent = Join-Path $fixtureRoot 'allowed'
[IO.Directory]::CreateDirectory($allowedParent) | Out-Null

$readOnlyRoot = Join-Path $allowedParent 'readonly-owned'
[IO.Directory]::CreateDirectory($readOnlyRoot) | Out-Null
$readOnlyFile = Join-Path $readOnlyRoot 'readonly.txt'
[IO.File]::WriteAllText($readOnlyFile, 'owned')
[IO.File]::SetAttributes($readOnlyFile, [IO.FileAttributes]::ReadOnly)
Remove-UpdaterOwnedDirectory -Path $readOnlyRoot -ExpectedParent $allowedParent -ExpectedLeafPattern ([regex]::Escape('readonly-owned'))
$readOnlyDeleted = -not [IO.Directory]::Exists($readOnlyRoot)

$outsideRoot = Join-Path $fixtureRoot 'outside-target'
[IO.Directory]::CreateDirectory($outsideRoot) | Out-Null
$outsideSentinel = Join-Path $outsideRoot 'sentinel.txt'
[IO.File]::WriteAllText($outsideSentinel, 'outside-must-survive')
$junctionRoot = Join-Path $allowedParent 'junction-owned'
[IO.Directory]::CreateDirectory($junctionRoot) | Out-Null
$junctionPath = Join-Path $junctionRoot 'outside-link'
New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot | Out-Null
Remove-UpdaterOwnedDirectory -Path $junctionRoot -ExpectedParent $allowedParent -ExpectedLeafPattern ([regex]::Escape('junction-owned'))
$junctionUnlinked = -not [IO.Directory]::Exists($junctionRoot)
$outsidePreserved = [IO.Directory]::Exists($outsideRoot) -and
    [IO.File]::Exists($outsideSentinel) -and
    [IO.File]::ReadAllText($outsideSentinel) -ceq 'outside-must-survive'

$refusalRoot = Join-Path $allowedParent 'refusal-owned'
[IO.Directory]::CreateDirectory($refusalRoot) | Out-Null
$refusalSentinel = Join-Path $refusalRoot 'sentinel.txt'
[IO.File]::WriteAllText($refusalSentinel, 'refusal-must-survive')
$wrongParentRefused = $false
try {
    Remove-UpdaterOwnedDirectory -Path $refusalRoot -ExpectedParent (Join-Path $fixtureRoot 'wrong-parent') -ExpectedLeafPattern ([regex]::Escape('refusal-owned'))
} catch {
    $wrongParentRefused = $_.Exception.Message -match 'Refusing to remove a directory outside the updater-owned scope'
}
$wrongParentPreserved = [IO.File]::Exists($refusalSentinel) -and [IO.File]::ReadAllText($refusalSentinel) -ceq 'refusal-must-survive'
$wrongLeafRefused = $false
try {
    Remove-UpdaterOwnedDirectory -Path $refusalRoot -ExpectedParent $allowedParent -ExpectedLeafPattern ([regex]::Escape('different-leaf'))
} catch {
    $wrongLeafRefused = $_.Exception.Message -match 'Refusing to remove a directory outside the updater-owned scope'
}
$wrongLeafPreserved = [IO.File]::Exists($refusalSentinel) -and [IO.File]::ReadAllText($refusalSentinel) -ceq 'refusal-must-survive'

[pscustomobject]@{
    ReadOnlyDeleted = $readOnlyDeleted
    JunctionUnlinked = $junctionUnlinked
    OutsidePreserved = $outsidePreserved
    WrongParentRefused = $wrongParentRefused
    WrongParentPreserved = $wrongParentPreserved
    WrongLeafRefused = $wrongLeafRefused
    WrongLeafPreserved = $wrongLeafPreserved
} | ConvertTo-Json -Compress
'@
    $helperSafetyCommand = $helperSafetyCommand.Replace('__UPDATER__', $quotedUpdater).Replace('__INSTALL__', $quotedFixture).Replace('__FIXTURE__', $quotedHelperFixtureRoot)
    $helperSafetyCapture = Invoke-WindowsPowerShellCapture $helperSafetyCommand
    if ($helperSafetyCapture.exitCode -ne 0) { throw "Updater-owned cleanup safety fixtures failed: $($helperSafetyCapture.text)" }
    $helperSafety = $helperSafetyCapture.text | ConvertFrom-Json
    foreach ($property in @('ReadOnlyDeleted', 'JunctionUnlinked', 'OutsidePreserved', 'WrongParentRefused', 'WrongParentPreserved', 'WrongLeafRefused', 'WrongLeafPreserved')) {
        if ($helperSafety.$property -ne $true) { throw "Updater-owned cleanup safety fixture did not prove ${property}." }
    }

    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'windows\update-transaction.js') -Destination (Join-Path $fixtureRoot 'update-transaction.js')
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'VERSION'), "v9.8.6$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
    $lastCheckPath = Join-Path $fixtureLocalAppData 'ChatGPTRemoteEnabler\update\last-check.json'
    if (Test-Path -LiteralPath $lastCheckPath -PathType Leaf) { Remove-Item -LiteralPath $lastCheckPath -Force }
    $failureCapture = Invoke-WindowsPowerShellCapture $autoCommand
    if ($failureCapture.exitCode -eq 0) { throw 'The invalid update fixture did not fail.' }
    if (Test-Path -LiteralPath $lastCheckPath -PathType Leaf) {
        throw 'A failed packaged update was stamped as successfully checked.'
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
        DefaultCheckIntervalHours = [int]$probe.checkIntervalHours
        AutoMethod = $auto.method
        ExactOwnedCheckCleanup = $true
        ExactOwnedPrepareCleanup = $true
        ReadOnlyCleanup = [bool]$helperSafety.ReadOnlyDeleted
        JunctionCleanupSafe = [bool]($helperSafety.JunctionUnlinked -and $helperSafety.OutsidePreserved)
        CleanupScopeRefusal = [bool]($helperSafety.WrongParentRefused -and $helperSafety.WrongParentPreserved -and $helperSafety.WrongLeafRefused -and $helperSafety.WrongLeafPreserved)
        FailedUpdateNotStamped = $true
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
