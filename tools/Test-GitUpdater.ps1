[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updaterSource = Join-Path $repositoryRoot 'windows\Update-ChatGPTRemote.ps1'
$stableInstallSource = Join-Path $repositoryRoot 'windows\StableInstall.ps1'
$transactionSource = Join-Path $repositoryRoot 'windows\update-transaction.js'
$canonicalHelper = Join-Path $repositoryRoot 'windows\git-release.js'
if (-not (Test-Path -LiteralPath $updaterSource -PathType Leaf) -or
    -not (Test-Path -LiteralPath $stableInstallSource -PathType Leaf) -or
    -not (Test-Path -LiteralPath $transactionSource -PathType Leaf) -or
    -not (Test-Path -LiteralPath $canonicalHelper -PathType Leaf)) {
    throw 'Git updater integration fixture sources are missing.'
}

function Invoke-GitFixtureSimple {
    param([string]$WorkingDirectory, [string[]]$Arguments)
    $result = & git -C $WorkingDirectory @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git fixture command failed: git -C $WorkingDirectory $($Arguments -join ' ')`n$($result -join [Environment]::NewLine)" }
    return [string]::Join([Environment]::NewLine, @($result | ForEach-Object { [string]$_ })).Trim()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Value)
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'$($Value.Replace("'", "''"))'"
}

function Invoke-Updater {
    param([string]$Shell, [string]$Updater, [string[]]$Arguments)
    $output = @(& $Shell -NoProfile -NonInteractive -File $Updater @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    $json = $null
    if ($exitCode -eq 0) {
        $jsonLine = @($text -split '\r?\n' | Where-Object { $_.Trim().StartsWith('{') -and $_.Trim().EndsWith('}') } | Select-Object -Last 1)
        if ($jsonLine.Count -ne 1) { throw "Updater returned no JSON result: $text" }
        $json = $jsonLine[0] | ConvertFrom-Json
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; Json = $json }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-remote-git-updater-" + [guid]::NewGuid().ToString('N'))
$savedLocalAppData = $env:LOCALAPPDATA
$savedTestRemote = $env:CHATGPT_REMOTE_GIT_RELEASE_TEST_REMOTE
$savedTransport = $env:CHATGPT_REMOTE_UPDATE_TRANSPORT
try {
    $fixtureRoot = Join-Path $temporaryRoot 'packaged-install'
    $fixtureLocalAppData = Join-Path $temporaryRoot 'local-app-data'
    $fixtureRepo = Join-Path $temporaryRoot 'git-remote'
    $cacheRoot = Join-Path $fixtureLocalAppData 'ChatGPTRemoteEnabler\update\git-cache'
    $preparedRoot = Join-Path $fixtureLocalAppData 'ChatGPTRemoteEnabler\update\prepared\v2.0.0'
    New-Item -ItemType Directory -Path $fixtureRoot,$fixtureLocalAppData,$fixtureRepo -Force | Out-Null

    Invoke-GitFixtureSimple $fixtureRepo @('init', '--quiet') | Out-Null
    Invoke-GitFixtureSimple $fixtureRepo @('config', 'user.email', 'git-updater-selftest@example.invalid') | Out-Null
    Invoke-GitFixtureSimple $fixtureRepo @('config', 'user.name', 'Git updater self-test') | Out-Null
    $fixturePlatformRoot = Join-Path $fixtureRepo 'windows'
    New-Item -ItemType Directory -Path $fixturePlatformRoot -Force | Out-Null
    Copy-Item -LiteralPath $updaterSource -Destination (Join-Path $fixturePlatformRoot 'Update-ChatGPTRemote.ps1')
    Copy-Item -LiteralPath $stableInstallSource -Destination (Join-Path $fixturePlatformRoot 'StableInstall.ps1')
    Copy-Item -LiteralPath $transactionSource -Destination (Join-Path $fixturePlatformRoot 'update-transaction.js')
    Write-Utf8NoBom (Join-Path $fixturePlatformRoot 'VERSION') "v2.0.0`n"
    Write-Utf8NoBom (Join-Path $fixturePlatformRoot 'payload.txt') "Git transport fixture payload`n"
    Invoke-GitFixtureSimple $fixtureRepo @('add', '--all', '--force') | Out-Null
    Invoke-GitFixtureSimple $fixtureRepo @('commit', '--quiet', '-m', 'v2.0.0') | Out-Null
    Invoke-GitFixtureSimple $fixtureRepo @('tag', '-a', 'v2.0.0', '-m', 'v2.0.0') | Out-Null

    Copy-Item -LiteralPath $updaterSource -Destination (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1')
    Copy-Item -LiteralPath $stableInstallSource -Destination (Join-Path $fixtureRoot 'StableInstall.ps1')
    Copy-Item -LiteralPath $transactionSource -Destination (Join-Path $fixtureRoot 'update-transaction.js')
    $canonicalLiteral = $canonicalHelper.Replace('\', '\\').Replace('"', '\"')
    $wrapper = @'
"use strict";
const helper = require("__CANONICAL_HELPER__");
function parse(argv) {
  if (argv.shift() !== "resolve") throw new Error("resolve is required");
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]; const value = argv[index + 1];
    if (!key || !key.startsWith("--") || value === undefined) throw new Error("invalid helper arguments");
    values[key.slice(2)] = value;
  }
  return {
    repository: values.repository,
    platform: values.platform,
    cacheRoot: values["cache-root"],
    ...(values.tag === undefined ? {} : { tag: values.tag }),
    ...(values["expected-sha256"] === undefined ? {} : { expectedSha256: values["expected-sha256"] }),
  };
}
const remote = process.env.CHATGPT_REMOTE_GIT_RELEASE_TEST_REMOTE;
if (!remote) throw new Error("test remote is missing");
process.stdout.write(`${JSON.stringify(helper.resolveRelease(parse(process.argv.slice(2)), { testRemotePath: remote }))}\n`);
'@.Replace('__CANONICAL_HELPER__', $canonicalLiteral)
    Write-Utf8NoBom (Join-Path $fixtureRoot 'git-release.js') $wrapper

    $installFiles = @('Update-ChatGPTRemote.ps1', 'StableInstall.ps1', 'update-transaction.js', 'VERSION')
    Copy-Item -LiteralPath (Join-Path $fixturePlatformRoot 'Update-ChatGPTRemote.ps1') -Destination (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $fixturePlatformRoot 'StableInstall.ps1') -Destination (Join-Path $fixtureRoot 'StableInstall.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $fixturePlatformRoot 'update-transaction.js') -Destination (Join-Path $fixtureRoot 'update-transaction.js') -Force
    Write-Utf8NoBom (Join-Path $fixtureRoot 'VERSION') "v1.0.0`n"
    $manifestLines = foreach ($relative in $installFiles) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $fixtureRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$relative"
    }
    Write-Utf8NoBom (Join-Path $fixtureRoot 'RELEASE-MANIFEST.sha256') (([string]::Join("`n", $manifestLines)) + "`n")

    $nodeCommand = Get-Command node.exe -ErrorAction Stop
    $node = $nodeCommand.Source
    $wrapperPath = Join-Path $fixtureRoot 'git-release.js'
    $env:LOCALAPPDATA = $fixtureLocalAppData
    $env:CHATGPT_REMOTE_GIT_RELEASE_TEST_REMOTE = $fixtureRepo
    $env:CHATGPT_REMOTE_UPDATE_TRANSPORT = 'Git'
    $probeResult = & $node $wrapperPath resolve --repository fixture/project --platform Windows-x64 --cache-root $cacheRoot 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git helper failed: $($probeResult -join [Environment]::NewLine)" }
    $release = ([string]::Join([Environment]::NewLine, @($probeResult | ForEach-Object { [string]$_ })) | ConvertFrom-Json)
    if ($release.tag -ne 'v2.0.0' -or $release.method -ne 'verified-git') { throw 'Fixture Git helper did not resolve the stable release.' }
    $expectedHash = [string]$release.archiveSha256

    $shell = if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -PathType Leaf) {
        Join-Path $PSHOME 'pwsh.exe'
    } elseif ($env:SystemRoot) {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        throw 'No PowerShell host is available for the updater fixture.'
    }
    $quotedInvalidApi = 'https://127.0.0.1:1/api.github.com'
    $quotedInvalidLatest = 'https://127.0.0.1:1/releases/latest'
    $common = @('-Repository', 'fixture/project', '-ApiBaseUrl', $quotedInvalidApi, '-LatestReleaseUrl', $quotedInvalidLatest, '-InstallRoot', $fixtureRoot)

    $check = Invoke-Updater $shell (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1') (@('-Action', 'Check') + $common)
    if ($check.ExitCode -ne 0 -or -not $check.Json -or $check.Json.method -ne 'verified-git' -or $check.Json.latestVersion -ne 'v2.0.0' -or $check.Json.available -ne $true -or $check.Json.archiveSha256 -ne $expectedHash) {
        throw "Git updater Check failed: $($check.Text)"
    }

    $badPrepared = Join-Path $fixtureLocalAppData 'ChatGPTRemoteEnabler\update\prepared\bad-hash'
    $badPrepare = Invoke-Updater $shell (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1') (@('-Action', 'Prepare', '-TargetVersion', 'v2.0.0', '-ExpectedArchiveSha256', ('0' * 64), '-PreparedDirectory', $badPrepared) + $common)
    if ($badPrepare.ExitCode -eq 0 -or $badPrepare.Text -notmatch 'does not match generated archive|Expected archive SHA-256') { throw "Git updater accepted a mismatched archive hash: $($badPrepare.Text)" }
    if (Test-Path -LiteralPath $badPrepared) { throw 'Hash-mismatched Git prepare left a prepared directory.' }

    $prepare = Invoke-Updater $shell (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1') (@('-Action', 'Prepare', '-TargetVersion', 'v2.0.0', '-ExpectedArchiveSha256', $expectedHash, '-PreparedDirectory', $preparedRoot) + $common)
    if ($prepare.ExitCode -ne 0 -or -not $prepare.Json -or $prepare.Json.prepared -ne $true -or $prepare.Json.archiveSha256 -ne $expectedHash) { throw "Git updater Prepare failed: $($prepare.Text)" }
    $apply = Invoke-Updater $shell (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1') (@('-Action', 'ApplyPrepared', '-TargetVersion', 'v2.0.0', '-ExpectedArchiveSha256', $expectedHash, '-PreparedDirectory', $preparedRoot) + $common)
    if ($apply.ExitCode -ne 0 -or -not $apply.Json -or $apply.Json.updated -ne $true -or $apply.Json.method -cne 'verified-git' -or $apply.Json.archiveSha256 -ne $expectedHash) { throw "Git updater ApplyPrepared failed without verified Git method proof: $($apply.Text)" }
    if ((Get-Content -LiteralPath (Join-Path $fixtureRoot 'VERSION') -Raw).Trim() -cne 'v2.0.0' -or -not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'payload.txt') -PathType Leaf)) { throw 'Git updater did not install the prepared Git archive.' }

    $recover = Invoke-Updater $shell (Join-Path $fixtureRoot 'Update-ChatGPTRemote.ps1') (@('-Action', 'Recover') + $common)
    if ($recover.ExitCode -ne 0 -or -not $recover.Json -or $recover.Json.integrityValid -ne $true -or $recover.Json.recovered -ne $false) { throw "Git updater Recover failed: $($recover.Text)" }
    if ($check.Text -match 'Invoke-WebRequest|curl|browser_download_url|release\.zip|api\.github\.com') { throw 'Git Check used an HTTP release or archive transport.' }
    if ($prepare.Text -match 'Invoke-WebRequest|curl|browser_download_url|release\.zip|api\.github\.com' -or $apply.Text -match 'Invoke-WebRequest|curl|browser_download_url|release\.zip|api\.github\.com') { throw 'Git Prepare or Apply used an HTTP release or archive transport.' }

    [pscustomobject]@{
        ok = $true
        defaultTransport = 'Git'
        check = $true
        prepare = $true
        applyPrepared = $true
        recover = $true
        hashMismatchRejected = $true
        httpArchiveTransport = $false
        archiveSha256 = $expectedHash
    } | ConvertTo-Json -Compress
} finally {
    if ($null -eq $savedLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $savedLocalAppData }
    if ($null -eq $savedTestRemote) { Remove-Item Env:CHATGPT_REMOTE_GIT_RELEASE_TEST_REMOTE -ErrorAction SilentlyContinue } else { $env:CHATGPT_REMOTE_GIT_RELEASE_TEST_REMOTE = $savedTestRemote }
    if ($null -eq $savedTransport) { Remove-Item Env:CHATGPT_REMOTE_UPDATE_TRANSPORT -ErrorAction SilentlyContinue } else { $env:CHATGPT_REMOTE_UPDATE_TRANSPORT = $savedTransport }
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
