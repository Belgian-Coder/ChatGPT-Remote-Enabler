[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Check', 'Update', 'Prepare', 'ApplyPrepared', 'Recover', 'EnableAutoUpdate', 'DisableAutoUpdate', 'Probe')]
    [string]$Action = 'Check',
    [string]$Repository = $(if ($env:CHATGPT_REMOTE_UPDATE_REPOSITORY) { $env:CHATGPT_REMOTE_UPDATE_REPOSITORY } else { 'Belgian-Coder/ChatGPT-Remote-Enabler' }),
    [string]$ApiBaseUrl = $(if ($env:CHATGPT_REMOTE_UPDATE_API_BASE) { $env:CHATGPT_REMOTE_UPDATE_API_BASE } else { 'https://api.github.com' }),
    [string]$LatestReleaseUrl = $env:CHATGPT_REMOTE_UPDATE_LATEST_URL,
    [string]$InstallRoot,
    [ValidateRange(0, 720)]
    [int]$CheckIntervalHours = $(if ($env:CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS) { [int]$env:CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS } else { 0 }),
    [string]$TargetVersion,
    [string]$ExpectedArchiveSha256,
    [string]$PreparedDirectory,
    [ValidateRange(1, 600)]
    [int]$LockTimeoutSeconds = 120,
    [switch]$LaunchLockHeld,
    [switch]$AllowInsecureTransport
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = $PSScriptRoot }
$platformName = 'Windows-x64'
$stateRoot = Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update'
$disabledMarker = Join-Path $stateRoot 'auto-update-disabled'
$lastCheckPath = Join-Path $stateRoot 'last-check.json'
$rollbackRoot = Join-Path $stateRoot 'rollback'
$lockPath = Join-Path $stateRoot 'update.lock'
$journalPath = Join-Path $stateRoot 'transaction.json'
$transactionHelper = Join-Path $PSScriptRoot 'update-transaction.js'
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
    param([string]$Tag)
    if ($LatestReleaseUrl) {
        Assert-SafeHttpsUrl $LatestReleaseUrl
        return $LatestReleaseUrl
    }
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Repository must use owner/name form.' }
    $base = $ApiBaseUrl.TrimEnd('/')
    Assert-SafeHttpsUrl $base
    if ($Tag) {
        if ($Tag -notmatch '^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') { throw "Invalid release tag: $Tag" }
        return "$base/repos/$Repository/releases/tags/$([Uri]::EscapeDataString($Tag))"
    }
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
    $temporary = "$lastCheckPath.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
        [ordered]@{ checkedAt = [DateTime]::UtcNow.ToString('o'); repository = $Repository; tag = $Tag } |
            ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $lastCheckPath -PathType Leaf) {
            $replacedBackup = "$lastCheckPath.replace-old-$PID-$([guid]::NewGuid().ToString('N'))"
            try {
                [IO.File]::Replace($temporary, $lastCheckPath, $replacedBackup, $true)
            } finally {
                if (Test-Path -LiteralPath $replacedBackup -PathType Leaf) { Remove-Item -LiteralPath $replacedBackup -Force }
            }
        } else {
            [IO.File]::Move($temporary, $lastCheckPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-LatestRelease {
    param([string]$RequestedTag)
    $url = Get-ReleaseUrl -Tag $RequestedTag
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'ChatGPT-Remote-Enabler-Updater' }
    $release = Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 20
    if ($release.draft -eq $true -or $release.prerelease -eq $true) { throw 'The latest endpoint returned a draft or prerelease.' }
    $tag = [string]$release.tag_name
    if ($tag -notmatch '^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') { throw "Invalid release tag: $tag" }
    if ($RequestedTag -and $tag -cne $RequestedTag) { throw "Pinned release $RequestedTag resolved to unexpected tag $tag." }
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
        assetDigest = [string]$archive.digest
    }
}

function Assert-PinnedReleaseArguments {
    if ($TargetVersion -notmatch '^v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') {
        throw 'TargetVersion must be an exact vMAJOR.MINOR.PATCH release tag.'
    }
    if ($ExpectedArchiveSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'ExpectedArchiveSha256 must contain exactly 64 hexadecimal characters.'
    }
    if ([string]::IsNullOrWhiteSpace($PreparedDirectory)) { throw 'PreparedDirectory is required.' }
}

function Resolve-UpdateNode {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    foreach ($candidate in @(
        $(if ($command) { $command.Source }),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe')
    ) | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $version = @(& $candidate --version 2>$null | Select-Object -First 1)
        if ($version.Count -eq 1 -and [string]$version[0] -match '^v(?<major>\d+)\.' -and [int]$Matches.major -ge 22) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Node.js 22 or newer was not found for the transactional updater.'
}

function Invoke-TransactionHelper {
    param([string]$Operation, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $transactionHelper -PathType Leaf)) {
        throw "Transactional update helper is missing: $transactionHelper"
    }
    $node = Resolve-UpdateNode
    $previousPowerShellHost = $env:CHATGPT_REMOTE_POWERSHELL_HOST
    try {
        $env:CHATGPT_REMOTE_POWERSHELL_HOST = (Get-Process -Id $PID).Path
        $output = @(& $node $transactionHelper $Operation @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $previousPowerShellHost) { Remove-Item Env:\CHATGPT_REMOTE_POWERSHELL_HOST -ErrorAction SilentlyContinue }
        else { $env:CHATGPT_REMOTE_POWERSHELL_HOST = $previousPowerShellHost }
    }
    if ($exitCode -ne 0 -or $output.Count -ne 1) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join ' '
        if ($detail -match 'UNSAFE_MIXED_INSTALL|UPDATE_BUSY') { throw $detail }
        throw "Transactional update helper failed during ${Operation}: $detail"
    }
    return ([string]$output[0] | ConvertFrom-Json -ErrorAction Stop)
}

function Get-PublishedArchiveHash {
    param($Release, [string]$TemporaryRoot)
    if ([string]$Release.assetDigest -match '^sha256:(?<hash>[0-9a-fA-F]{64})$') {
        return $Matches.hash.ToLowerInvariant()
    }
    $checksumsPath = Join-Path $TemporaryRoot $Release.checksumsName
    Invoke-WebRequest -Uri $Release.checksumsUrl -OutFile $checksumsPath -UseBasicParsing -TimeoutSec 20
    $escapedName = [regex]::Escape($Release.archiveName)
    $checksumLine = Get-Content -LiteralPath $checksumsPath | Where-Object { $_ -match "^([0-9a-fA-F]{64})\s+(?:\*)?$escapedName$" } | Select-Object -First 1
    if (-not $checksumLine) { throw "Published checksum for $($Release.archiveName) is missing." }
    return ([regex]::Match($checksumLine, '^[0-9a-fA-F]{64}')).Value.ToLowerInvariant()
}

function Assert-SafePreparedDirectory {
    param([string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $installPrefix = $InstallRoot.TrimEnd('\') + '\'
    $preparedPrefix = $resolved + '\'
    if ($resolved -eq $InstallRoot -or $resolved.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $InstallRoot.StartsWith($preparedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'PreparedDirectory must be separate from the install root.'
    }
    if ([string]::IsNullOrWhiteSpace((Split-Path -Leaf $resolved))) { throw 'PreparedDirectory cannot be a filesystem root.' }
    $parent = Split-Path -Parent $resolved
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $current = [IO.Path]::GetPathRoot($parent)
    foreach ($component in $parent.Substring($current.Length).Split('\') | Where-Object { $_ }) {
        $current = Join-Path $current $component
        if ((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "PreparedDirectory must not traverse a reparse point: $resolved"
        }
    }
    if ((Test-Path -LiteralPath $resolved) -and -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw 'PreparedDirectory exists and is not a directory.'
    }
    return $resolved
}

function Test-ZipHeader {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 4) { return $false }
        return $stream.ReadByte() -eq 0x50 -and $stream.ReadByte() -eq 0x4b
    } finally {
        $stream.Dispose()
    }
}

function New-PreparedRelease {
    param([string]$RequestedVersion, [string]$ExpectedHash, [string]$Destination)
    $Destination = Assert-SafePreparedDirectory $Destination
    $ExpectedHash = $ExpectedHash.ToLowerInvariant()
    $helperArguments = @('--prepared-root', $Destination, '--platform', $platformName, '--version', $RequestedVersion, '--archive-sha256', $ExpectedHash)
    if (Test-Path -LiteralPath $Destination -PathType Container) {
        return Invoke-TransactionHelper -Operation 'validate-prepared' -Arguments $helperArguments
    }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-remote-prepare-" + [guid]::NewGuid().ToString('N'))
    $staging = "$Destination.prepare-$PID-$([guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
        $release = Get-LatestRelease -RequestedTag $RequestedVersion
        $publishedHash = Get-PublishedArchiveHash -Release $release -TemporaryRoot $temporaryRoot
        if ($publishedHash -ne $ExpectedHash) { throw "Pinned archive hash $ExpectedHash does not match the published hash $publishedHash." }
        $archivePath = Join-Path $temporaryRoot $release.archiveName
        Invoke-WebRequest -Uri $release.archiveUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 120
        if (-not (Test-ZipHeader $archivePath)) {
            throw 'The release download is not a ZIP archive. A proxy or network security gateway may have replaced it with a block page.'
        }
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $ExpectedHash) { throw 'Downloaded release archive failed its pinned SHA-256 verification.' }
        $extractRoot = Join-Path $temporaryRoot 'extract'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
        $releaseRoot = if (Test-Path -LiteralPath (Join-Path $extractRoot 'VERSION') -PathType Leaf) {
            $extractRoot
        } else {
            $releaseRoots = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
            if ($releaseRoots.Count -ne 1) { throw 'Release archive must be flat or contain exactly one top-level directory.' }
            $releaseRoots[0].FullName
        }
        if ((Get-Content -LiteralPath (Join-Path $releaseRoot 'VERSION') -Raw).Trim() -cne $RequestedVersion) {
            throw 'Prepared archive VERSION does not match the pinned release.'
        }
        New-Item -ItemType Directory -Path $staging | Out-Null
        Get-ChildItem -LiteralPath $releaseRoot -Force | Copy-Item -Destination $staging -Recurse -Force
        Copy-Item -LiteralPath $archivePath -Destination (Join-Path $staging '.chatgpt-remote-release.zip')
        $stagingArguments = @('--prepared-root', $staging, '--platform', $platformName, '--version', $RequestedVersion, '--archive-sha256', $ExpectedHash)
        [void](Invoke-TransactionHelper -Operation 'seal-prepared' -Arguments $stagingArguments)
        try {
            [IO.Directory]::Move($staging, $Destination)
        } catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { throw }
        }
        return Invoke-TransactionHelper -Operation 'validate-prepared' -Arguments $helperArguments
    } catch {
        if ($_.Exception.Message -match 'UNSAFE_MIXED_INSTALL|UPDATE_BUSY') { throw }
        throw "UPDATE_PREPARE_FAILED: $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}

function Invoke-PreparedRelease {
    param([string]$RequestedVersion, [string]$ExpectedHash, [string]$Source)
    $Source = Assert-SafePreparedDirectory $Source
    $safeVersion = $RequestedVersion -replace '[^A-Za-z0-9._-]', '_'
    $backupRoot = Join-Path $rollbackRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $safeVersion)
    $arguments = @(
        '--install-root', $InstallRoot, '--prepared-root', $Source,
        '--journal-path', $journalPath, '--backup-root', $backupRoot,
        '--platform', $platformName, '--version', $RequestedVersion,
        '--archive-sha256', $ExpectedHash.ToLowerInvariant()
    )
    return Invoke-TransactionHelper -Operation 'apply' -Arguments $arguments
}

function Invoke-PendingRecovery {
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        $sourceCheckout = Get-SourceCheckout
        if ($sourceCheckout) {
            return [pscustomobject][ordered]@{
                recovered = $false
                integrityValid = $true
                version = Get-LocalVersion
                installKind = 'git-checkout'
            }
        }
    }
    $arguments = @('--journal-path', $journalPath, '--install-root', $InstallRoot)
    try {
        return Invoke-TransactionHelper -Operation 'recover' -Arguments $arguments
    } catch {
        if ($_.Exception.Message -match 'UNSAFE_MIXED_INSTALL|UPDATE_BUSY') { throw }
        throw "UNSAFE_MIXED_INSTALL: installed integrity or transaction recovery failed: $($_.Exception.Message)"
    }
}

function Get-ReleaseArchiveHash {
    param($Release)
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-remote-check-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
        return Get-PublishedArchiveHash -Release $Release -TemporaryRoot $temporaryRoot
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
    }
}

function Install-VerifiedRelease {
    param($Release, [string]$ArchiveHash)
    $safeVersion = $Release.tag -replace '[^A-Za-z0-9._-]', '_'
    $preparedRoot = Join-Path $stateRoot ("prepared\$safeVersion-$($ArchiveHash.Substring(0, 16))")
    try {
        [void](New-PreparedRelease -RequestedVersion $Release.tag -ExpectedHash $ArchiveHash -Destination $preparedRoot)
        return Invoke-PreparedRelease -RequestedVersion $Release.tag -ExpectedHash $ArchiveHash -Source $preparedRoot
    } finally {
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf) -and
            (Test-Path -LiteralPath $preparedRoot -PathType Container)) {
            Remove-Item -LiteralPath $preparedRoot -Recurse -Force
        }
    }
}

function Enter-UpdateLock {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
    do {
        try {
            $stream = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.SetLength(0)
            $bytes = [Text.Encoding]::UTF8.GetBytes("pid=$PID checkedAt=$([DateTime]::UtcNow.ToString('o'))`n")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return $stream
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "UPDATE_BUSY: another updater still owns the lock after $LockTimeoutSeconds seconds." }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
}

function Enter-LaunchGuard {
    $mutex = [Threading.Mutex]::new($false, 'Local\ChatGPTCustomInjectionLauncher')
    try {
        $acquired = $false
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($LockTimeoutSeconds))
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "UPDATE_BUSY: launcher injection still owns the launch guard after $LockTimeoutSeconds seconds."
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
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
    $candidateRoot = Split-Path -Parent $InstallRoot
    if (-not (Test-Path -LiteralPath (Join-Path $candidateRoot '.git'))) { return $null }

    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    $gitPath = @(
        $(if ($gitCommand) { $gitCommand.Source }),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe'),
        'C:\Program Files\Git\cmd\git.exe'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $gitPath) { return $null }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $rootOutput = @(& $gitPath -C $InstallRoot rev-parse --show-toplevel 2>$null)
        $rootExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($rootExitCode -ne 0 -or $rootOutput.Count -ne 1) { return $null }
    $root = [IO.Path]::GetFullPath(([string]$rootOutput[0]).Trim())
    $expectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $root 'windows'))
    if ($expectedInstallRoot -ne $InstallRoot) { return $null }
    try {
        $ErrorActionPreference = 'Continue'
        $origin = @(& $gitPath -C $root remote get-url origin 2>$null)
        $originExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($originExitCode -ne 0 -or $origin.Count -ne 1) { return $null }
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
$lockStream = $null
$launchGuard = $null
$callerOwnsLaunchGuard = $LaunchLockHeld -or $env:CHATGPT_REMOTE_LAUNCH_GUARD_HELD -eq '1'
try {
    $readOnlyAction = $Action -in @('Check', 'Prepare')
    if (-not $readOnlyAction -and -not $callerOwnsLaunchGuard) {
        $launchGuard = Enter-LaunchGuard
    }
    $lockStream = Enter-UpdateLock
    if ($readOnlyAction) {
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
            throw 'UPDATE_RECOVERY_REQUIRED: a pending update transaction must be recovered before checking or preparing another release.'
        }
        $recovery = [pscustomobject]@{ recovered = $false; integrityValid = $true }
    } else {
        $recovery = Invoke-PendingRecovery
    }

    if ($Action -eq 'Recover') {
        $recovery | ConvertTo-Json -Depth 4 -Compress
        return
    }

    if ($Action -eq 'Auto' -and (Test-AutoUpdateDisabled)) {
        ([ordered]@{ skipped = $true; reason = 'auto-update-disabled'; localVersion = Get-LocalVersion; recovered = [bool]$recovery.recovered } | ConvertTo-Json)
        return
    }
    if ($Action -eq 'Auto' -and -not (Test-CheckDue)) {
        ([ordered]@{ skipped = $true; reason = 'check-interval'; localVersion = Get-LocalVersion; recovered = [bool]$recovery.recovered } | ConvertTo-Json)
        return
    }

    if ($Action -in @('Prepare', 'ApplyPrepared')) {
        Assert-PinnedReleaseArguments
        if ($Action -eq 'Prepare') {
            $result = New-PreparedRelease -RequestedVersion $TargetVersion -ExpectedHash $ExpectedArchiveSha256 -Destination $PreparedDirectory
            $result | ConvertTo-Json -Depth 4 -Compress
            return
        }
        try {
            $result = Invoke-PreparedRelease -RequestedVersion $TargetVersion -ExpectedHash $ExpectedArchiveSha256 -Source $PreparedDirectory
            Write-LastCheck $TargetVersion
            $result | ConvertTo-Json -Depth 4 -Compress
            return
        } catch {
            if ($_.Exception.Message -match 'UNSAFE_MIXED_INSTALL|UPDATE_BUSY') { throw }
            throw "UPDATE_APPLY_FAILED: $($_.Exception.Message)"
        }
    }

    if ($Action -eq 'Check') {
        try {
            $release = Get-LatestRelease
            $archiveHash = Get-ReleaseArchiveHash -Release $release
            $localVersion = Get-LocalVersion
            $available = (ConvertTo-Version $release.tag) -gt (ConvertTo-Version $localVersion)
            if ($release.tag -eq $localVersion -and -not (Test-InstalledIntegrity)) { $available = $true }
            Write-LastCheck $release.tag
            ([ordered]@{
                available = $available
                latestVersion = $release.tag
                localVersion = $localVersion
                archiveSha256 = $archiveHash
                updated = $false
                method = 'verified-release'
            } | ConvertTo-Json -Compress)
            return
        } catch {
            if ($_.Exception.Message -match 'UNSAFE_MIXED_INSTALL') { throw }
            throw "UPDATE_CHECK_FAILED: $($_.Exception.Message)"
        }
    }

    $sourceCheckout = Get-SourceCheckout
    if ($sourceCheckout) {
        $remoteState = Get-SourceRemoteState -Checkout $sourceCheckout
        $localVersion = Get-LocalVersion
        if (-not $remoteState.available) {
            Write-LastCheck $remoteState.version
            ([ordered]@{ available = $remoteState.available; latestVersion = $remoteState.version; localVersion = $localVersion; updated = $false; method = 'git-fast-forward' } | ConvertTo-Json)
            return
        }
        $result = Install-SourceCheckout -Checkout $sourceCheckout -RemoteState $remoteState
        Write-LastCheck $remoteState.version
        $result | ConvertTo-Json -Depth 4
        return
    }
    $release = Get-LatestRelease
    $archiveHash = Get-ReleaseArchiveHash -Release $release
    $localVersion = Get-LocalVersion
    $available = (ConvertTo-Version $release.tag) -gt (ConvertTo-Version $localVersion)
    if ($release.tag -eq $localVersion -and -not (Test-InstalledIntegrity)) { $available = $true }
    if (-not $available) {
        Write-LastCheck $release.tag
        ([ordered]@{ available = $available; latestVersion = $release.tag; localVersion = $localVersion; archiveSha256 = $archiveHash; updated = $false; method = 'verified-release' } | ConvertTo-Json)
        return
    }
    $result = Install-VerifiedRelease -Release $release -ArchiveHash $archiveHash
    Write-LastCheck $release.tag
    $result | ConvertTo-Json -Depth 4
} finally {
    if ($lockStream) { $lockStream.Dispose() }
    if ($launchGuard) {
        try { $launchGuard.ReleaseMutex() } finally { $launchGuard.Dispose() }
    }
}
