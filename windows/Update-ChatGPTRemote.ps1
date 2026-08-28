[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Check', 'Update', 'EnableAutoUpdate', 'DisableAutoUpdate', 'Probe')]
    [string]$Action = 'Check',
    [string]$Repository = $(if ($env:CHATGPT_REMOTE_UPDATE_REPOSITORY) { $env:CHATGPT_REMOTE_UPDATE_REPOSITORY } else { 'Belgian-Coder/ChatGPT-Remote-Enabler' }),
    [string]$ApiBaseUrl = $(if ($env:CHATGPT_REMOTE_UPDATE_API_BASE) { $env:CHATGPT_REMOTE_UPDATE_API_BASE } else { 'https://api.github.com' }),
    [string]$LatestReleaseUrl = $env:CHATGPT_REMOTE_UPDATE_LATEST_URL,
    [string]$InstallRoot,
    [ValidateRange(0, 720)]
    [int]$CheckIntervalHours = $(if ($env:CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS) { [int]$env:CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS } else { 24 }),
    [switch]$AllowInsecureTransport
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = $PSScriptRoot }
$platformName = 'Windows-x64'
$stateRoot = Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update'
$disabledMarker = Join-Path $stateRoot 'auto-update-disabled'
$lastCheckPath = Join-Path $stateRoot 'last-check.json'
$rollbackRoot = Join-Path $stateRoot 'rollback'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)

function Assert-SafeHttpsUrl {
    param([string]$Url)
    $uri = [Uri]$Url
    if (-not $uri.IsAbsoluteUri) { throw "Update URL must be absolute: $Url" }
    if ($uri.Scheme -ne 'https' -and -not ($AllowInsecureTransport -and $uri.Scheme -eq 'http' -and $uri.IsLoopback)) {
        throw "Update URL must use HTTPS: $Url"
    }
}

function Get-ReleaseUrl {
    if ($LatestReleaseUrl) {
        Assert-SafeHttpsUrl $LatestReleaseUrl
        return $LatestReleaseUrl
    }
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Repository must use owner/name form.' }
    $base = $ApiBaseUrl.TrimEnd('/')
    Assert-SafeHttpsUrl $base
    return "$base/repos/$Repository/releases/latest"
}

function Get-LocalVersion {
    $versionPath = Join-Path $InstallRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { return 'v0.0.0' }
    $value = (Get-Content -LiteralPath $versionPath -Raw).Trim()
    return $(if ($value) { $value } else { 'v0.0.0' })
}

function ConvertTo-Version {
    param([string]$Value)
    $numeric = ($Value -replace '^v', '') -replace '[-+].*$', ''
    try { return [version]$numeric } catch { throw "Unsupported release version: $Value" }
}

function Test-AutoUpdateDisabled {
    if ($env:CHATGPT_REMOTE_AUTO_UPDATE -match '^(?:0|false|off|no)$') { return $true }
    return Test-Path -LiteralPath $disabledMarker -PathType Leaf
}

function Test-CheckDue {
    if ($CheckIntervalHours -eq 0 -or -not (Test-Path -LiteralPath $lastCheckPath -PathType Leaf)) { return $true }
    return (Get-Item -LiteralPath $lastCheckPath).LastWriteTimeUtc -lt [DateTime]::UtcNow.AddHours(-$CheckIntervalHours)
}

function Write-LastCheck {
    param([string]$Tag)
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    [ordered]@{ checkedAt = [DateTime]::UtcNow.ToString('o'); repository = $Repository; tag = $Tag } |
        ConvertTo-Json | Set-Content -LiteralPath $lastCheckPath -Encoding UTF8
}

function Get-LatestRelease {
    $url = Get-ReleaseUrl
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'ChatGPT-Remote-Enabler-Updater' }
    $release = Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 20
    if ($release.draft -eq $true -or $release.prerelease -eq $true) { throw 'The latest endpoint returned a draft or prerelease.' }
    $tag = [string]$release.tag_name
    if ($tag -notmatch '^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') { throw "Invalid release tag: $tag" }
    $archiveName = "ChatGPT-Remote-Enabler-$platformName-$tag.zip"
    $checksumsName = "SHA256SUMS-$tag.txt"
    $archive = @($release.assets | Where-Object { $_.name -eq $archiveName }) | Select-Object -First 1
    $checksums = @($release.assets | Where-Object { $_.name -eq $checksumsName }) | Select-Object -First 1
    if (-not $archive -or -not $checksums) { throw "Release $tag is missing $archiveName or $checksumsName." }
    Assert-SafeHttpsUrl ([string]$archive.browser_download_url)
    Assert-SafeHttpsUrl ([string]$checksums.browser_download_url)
    return [pscustomobject]@{
        tag = $tag
        archiveName = $archiveName
        archiveUrl = [string]$archive.browser_download_url
        checksumsName = $checksumsName
        checksumsUrl = [string]$checksums.browser_download_url
    }
}

function Get-ManifestEntries {
    param([string]$Root)
    $manifestPath = Join-Path $Root 'RELEASE-MANIFEST.sha256'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The extracted release has no RELEASE-MANIFEST.sha256.' }
    $entries = foreach ($line in Get-Content -LiteralPath $manifestPath) {
        if ($line -notmatch '^([0-9a-fA-F]{64}) \*(.+)$') { throw "Malformed release manifest line: $line" }
        $relative = $matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Split([IO.Path]::DirectorySeparatorChar) -contains '..') {
            throw "Unsafe release manifest path: $relative"
        }
        $source = [IO.Path]::GetFullPath((Join-Path $Root $relative))
        $rootPrefix = $Root.TrimEnd('\') + '\'
        if (-not $source.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Release path escapes its root: $relative" }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Release file is missing: $relative" }
        if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Release file must not be a reparse point: $relative" }
        $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        if ($actual -ne $matches[1]) { throw "Release manifest hash mismatch: $relative" }
        [pscustomobject]@{ relative = $relative; source = $source }
    }
    $entries = @($entries)
    if ($entries.Count -eq 0) { throw 'Release manifest is empty.' }
    return $entries
}

function Test-InstalledIntegrity {
    try {
        [void](Get-ManifestEntries $InstallRoot)
        return $true
    } catch {
        return $false
    }
}

function Get-SourceCheckout {
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    $gitPath = @(
        $(if ($gitCommand) { $gitCommand.Source }),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe'),
        'C:\Program Files\Git\cmd\git.exe'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $gitPath) { return $null }
    $rootOutput = @(& $gitPath -C $InstallRoot rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $rootOutput.Count -ne 1) { return $null }
    $root = [IO.Path]::GetFullPath(([string]$rootOutput[0]).Trim())
    $expectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $root 'windows'))
    if ($expectedInstallRoot -ne $InstallRoot) { return $null }
    $origin = @(& $gitPath -C $root remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or $origin.Count -ne 1) { return $null }
    $normalizedOrigin = ([string]$origin[0]).Trim().TrimEnd('/').ToLowerInvariant() -replace '\.git$', ''
    $expectedRepository = $Repository.ToLowerInvariant()
    if (-not ($normalizedOrigin.EndsWith("/$expectedRepository") -or $normalizedOrigin.EndsWith(":$expectedRepository"))) { return $null }
    return [pscustomobject]@{ git = $gitPath; root = $root }
}

function Get-SourceRemoteState {
    param($Checkout)

    & $Checkout.git -C $Checkout.root fetch --quiet origin 'refs/heads/main:refs/remotes/origin/main'
    if ($LASTEXITCODE -ne 0) { throw 'Git could not fetch origin/main.' }
    $head = (@(& $Checkout.git -C $Checkout.root rev-parse HEAD 2>$null)[0]).Trim()
    $target = (@(& $Checkout.git -C $Checkout.root rev-parse refs/remotes/origin/main 2>$null)[0]).Trim()
    $version = (@(& $Checkout.git -C $Checkout.root show 'refs/remotes/origin/main:windows/VERSION' 2>$null)[0]).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v\d+\.\d+\.\d+$') { throw 'origin/main does not contain a valid Windows VERSION.' }
    $available = $false
    if ($head -ne $target) {
        & $Checkout.git -C $Checkout.root merge-base --is-ancestor HEAD $target
        if ($LASTEXITCODE -eq 0) {
            $available = $true
        } else {
            & $Checkout.git -C $Checkout.root merge-base --is-ancestor $target HEAD
            if ($LASTEXITCODE -ne 0) { throw 'The source checkout has diverged from origin/main.' }
        }
    }
    return [pscustomobject]@{ available = $available; target = $target; version = $version }
}

function Install-SourceCheckout {
    param($Checkout, $RemoteState)

    $branch = @(& $Checkout.git -C $Checkout.root branch --show-current 2>$null)
    if ($LASTEXITCODE -ne 0 -or ([string]$branch[0]).Trim() -ne 'main') {
        throw 'The source checkout is not on main; automatic update was skipped.'
    }
    $changes = @(& $Checkout.git -C $Checkout.root status --porcelain=v1 2>$null)
    if ($LASTEXITCODE -ne 0 -or $changes.Count -gt 0) {
        throw 'The source checkout has local changes; automatic update was skipped.'
    }
    & $Checkout.git -C $Checkout.root merge --ff-only --quiet $RemoteState.target
    if ($LASTEXITCODE -ne 0) { throw 'Git could not fast-forward the source checkout to origin/main.' }
    $installedVersion = Get-LocalVersion
    if ($installedVersion -ne $RemoteState.version) { throw "The updated source checkout reports $installedVersion instead of $($RemoteState.version)." }
    return [ordered]@{ updated = $true; version = $RemoteState.version; method = 'git-fast-forward'; files = $null }
}

function Assert-SafeInstallDestination {
    param([string]$RelativePath)
    if ((Get-Item -LiteralPath $InstallRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Install root must not be a reparse point.'
    }
    $current = $InstallRoot
    foreach ($component in $RelativePath.Split([IO.Path]::DirectorySeparatorChar)) {
        $current = Join-Path $current $component
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Install destination must not traverse a reparse point: $RelativePath"
        }
    }
}

function Install-Release {
    param($Release)
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-remote-update-" + [guid]::NewGuid().ToString('N'))
    $safeLocalVersion = ((Get-LocalVersion) -replace '[^A-Za-z0-9._-]', '_')
    if ($safeLocalVersion.Length -gt 48) { $safeLocalVersion = $safeLocalVersion.Substring(0, 48) }
    $backupRoot = Join-Path $rollbackRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $safeLocalVersion)
    $copied = [Collections.Generic.List[object]]::new()
    try {
        New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
        $archivePath = Join-Path $temporaryRoot $Release.archiveName
        $checksumsPath = Join-Path $temporaryRoot $Release.checksumsName
        Invoke-WebRequest -Uri $Release.archiveUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 120
        Invoke-WebRequest -Uri $Release.checksumsUrl -OutFile $checksumsPath -UseBasicParsing -TimeoutSec 20
        $archiveBytes = [IO.File]::ReadAllBytes($archivePath)
        if ($archiveBytes.Length -lt 4 -or $archiveBytes[0] -ne 0x50 -or $archiveBytes[1] -ne 0x4b) {
            throw 'The release download is not a ZIP archive. A proxy or network security gateway may have replaced it with a block page.'
        }
        $escapedName = [regex]::Escape($Release.archiveName)
        $checksumLine = Get-Content -LiteralPath $checksumsPath | Where-Object { $_ -match "^([0-9a-fA-F]{64})\s+(?:\*)?$escapedName$" } | Select-Object -First 1
        if (-not $checksumLine) { throw "Published checksum for $($Release.archiveName) is missing." }
        $expectedArchiveHash = ([regex]::Match($checksumLine, '^[0-9a-fA-F]{64}')).Value
        $actualArchiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($actualArchiveHash -ne $expectedArchiveHash) { throw 'Downloaded release archive failed SHA-256 verification.' }
        $extractRoot = Join-Path $temporaryRoot 'extract'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
        $releaseRoot = if (Test-Path -LiteralPath (Join-Path $extractRoot 'VERSION') -PathType Leaf) {
            $extractRoot
        } else {
            $releaseRoots = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
            if ($releaseRoots.Count -ne 1) { throw 'Release archive must be flat or contain exactly one top-level directory.' }
            $releaseRoots[0].FullName
        }
        $archiveVersion = (Get-Content -LiteralPath (Join-Path $releaseRoot 'VERSION') -Raw).Trim()
        if ($archiveVersion -ne $Release.tag) { throw "Archive version $archiveVersion does not match release $($Release.tag)." }
        $entries = Get-ManifestEntries $releaseRoot
        $previousEntries = try { @(Get-ManifestEntries $InstallRoot) } catch { @() }
        $newRelativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $entries) { [void]$newRelativePaths.Add($entry.relative) }
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $ordered = @($entries | Sort-Object @{ Expression = { if ($_.relative -ieq 'Update-ChatGPTRemote.ps1') { 1 } else { 0 } } }, relative)
        foreach ($entry in $ordered) {
            Assert-SafeInstallDestination $entry.relative
            $destination = [IO.Path]::GetFullPath((Join-Path $InstallRoot $entry.relative))
            $installPrefix = $InstallRoot.TrimEnd('\') + '\'
            if (-not $destination.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Install path escapes its root: $($entry.relative)" }
            $backup = Join-Path $backupRoot $entry.relative
            $existed = Test-Path -LiteralPath $destination -PathType Leaf
            if ($existed) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                Copy-Item -LiteralPath $destination -Destination $backup -Force
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $entry.source -Destination $destination -Force
            $copied.Add([pscustomobject]@{ destination = $destination; backup = $backup; existed = $existed })
        }
        foreach ($entry in $previousEntries) {
            if ($newRelativePaths.Contains($entry.relative)) { continue }
            Assert-SafeInstallDestination $entry.relative
            $destination = [IO.Path]::GetFullPath((Join-Path $InstallRoot $entry.relative))
            $backup = Join-Path $backupRoot $entry.relative
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
            Remove-Item -LiteralPath $destination -Force
            $copied.Add([pscustomobject]@{ destination = $destination; backup = $backup; existed = $true })
        }
        $manifestDestination = Join-Path $InstallRoot 'RELEASE-MANIFEST.sha256'
        Assert-SafeInstallDestination 'RELEASE-MANIFEST.sha256'
        $manifestBackup = Join-Path $backupRoot 'RELEASE-MANIFEST.sha256'
        $manifestExisted = Test-Path -LiteralPath $manifestDestination -PathType Leaf
        if ($manifestExisted) { Copy-Item -LiteralPath $manifestDestination -Destination $manifestBackup -Force }
        Copy-Item -LiteralPath (Join-Path $releaseRoot 'RELEASE-MANIFEST.sha256') -Destination $manifestDestination -Force
        $copied.Add([pscustomobject]@{ destination = $manifestDestination; backup = $manifestBackup; existed = $manifestExisted })
        return [ordered]@{ updated = $true; version = $Release.tag; rollbackPath = $backupRoot; files = $entries.Count }
    } catch {
        $restoreEntries = @($copied)
        [array]::Reverse($restoreEntries)
        foreach ($entry in $restoreEntries) {
            if ($entry.existed) { Copy-Item -LiteralPath $entry.backup -Destination $entry.destination -Force }
            elseif (Test-Path -LiteralPath $entry.destination -PathType Leaf) { Remove-Item -LiteralPath $entry.destination -Force }
        }
        throw
    } finally {
        $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
        $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}

function Get-Probe {
    $sourceCheckout = Get-SourceCheckout
    return [ordered]@{
        autoUpdateEnabled = -not (Test-AutoUpdateDisabled)
        checkIntervalHours = $CheckIntervalHours
        installRoot = $InstallRoot
        latestReleaseUrl = Get-ReleaseUrl
        localVersion = Get-LocalVersion
        repository = $Repository
        lastCheckPath = $lastCheckPath
        installKind = if ($sourceCheckout) { 'git-checkout' } else { 'release' }
    }
}

if ($Action -eq 'EnableAutoUpdate') {
    if (Test-Path -LiteralPath $disabledMarker -PathType Leaf) { Remove-Item -LiteralPath $disabledMarker -Force }
    Get-Probe | ConvertTo-Json -Depth 4
    return
}
if ($Action -eq 'DisableAutoUpdate') {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    [IO.File]::WriteAllText($disabledMarker, "disabled$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
    Get-Probe | ConvertTo-Json -Depth 4
    return
}
if ($Action -eq 'Probe') {
    Get-Probe | ConvertTo-Json -Depth 4
    return
}
if ($Action -eq 'Auto' -and (Test-AutoUpdateDisabled)) {
    ([ordered]@{ skipped = $true; reason = 'auto-update-disabled'; localVersion = Get-LocalVersion } | ConvertTo-Json)
    return
}
if ($Action -eq 'Auto' -and -not (Test-CheckDue)) {
    ([ordered]@{ skipped = $true; reason = 'check-interval'; localVersion = Get-LocalVersion } | ConvertTo-Json)
    return
}

$mutex = [Threading.Mutex]::new($false, 'Local\ChatGPTRemoteEnablerUpdate')
$acquired = $false
try {
    $acquired = $mutex.WaitOne($(if ($Action -eq 'Auto') { 0 } else { 30000 }))
    if (-not $acquired) {
        ([ordered]@{ skipped = $true; reason = 'update-already-running'; localVersion = Get-LocalVersion } | ConvertTo-Json)
        return
    }
    $sourceCheckout = Get-SourceCheckout
    if ($sourceCheckout) {
        $remoteState = Get-SourceRemoteState -Checkout $sourceCheckout
        Write-LastCheck $remoteState.version
        $localVersion = Get-LocalVersion
        if ($Action -eq 'Check' -or -not $remoteState.available) {
            ([ordered]@{ available = $remoteState.available; latestVersion = $remoteState.version; localVersion = $localVersion; updated = $false; method = 'git-fast-forward' } | ConvertTo-Json)
            return
        }
        (Install-SourceCheckout -Checkout $sourceCheckout -RemoteState $remoteState) | ConvertTo-Json -Depth 4
        return
    }
    $release = Get-LatestRelease
    Write-LastCheck $release.tag
    $localVersion = Get-LocalVersion
    $available = (ConvertTo-Version $release.tag) -gt (ConvertTo-Version $localVersion)
    if ($release.tag -eq $localVersion -and -not (Test-InstalledIntegrity)) { $available = $true }
    if ($Action -eq 'Check' -or -not $available) {
        ([ordered]@{ available = $available; latestVersion = $release.tag; localVersion = $localVersion; updated = $false; method = 'verified-release' } | ConvertTo-Json)
        return
    }
    (Install-Release $release) | ConvertTo-Json -Depth 4
} finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
