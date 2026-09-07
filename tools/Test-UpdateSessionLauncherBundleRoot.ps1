[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$launcherSource = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\UpdateSessionLauncher.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-bundle-root-test-' + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA

function Write-FixtureFile {
    param([string]$Path, [string]$Value)

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

try {
    $installRoot = Join-Path $temporaryRoot 'installed-old'
    $candidateRoot = Join-Path $temporaryRoot 'candidate-new'
    $candidateMobileRoot = Join-Path $candidateRoot 'CodexRemoteMobileProject'
    $env:LOCALAPPDATA = Join-Path $temporaryRoot 'user-state'
    New-Item -ItemType Directory -Path $installRoot,$candidateMobileRoot,$env:LOCALAPPDATA -Force | Out-Null

    $mobileSources = [ordered]@{
        'update-session.js' = 'candidate:update-session.js'
        'update-session-cdp.js' = 'candidate:update-session-cdp.js'
        'UpdateSessionPlatform.ps1' = 'candidate:UpdateSessionPlatform.ps1'
    }
    $dependencyPaths = [ordered]@{
        'cdp.js' = 'CodexRemoteSimple\runtime\lib\cdp.js'
        'Update-ChatGPTRemote.ps1' = 'Update-ChatGPTRemote.ps1'
        'update-transaction.js' = 'update-transaction.js'
        'git-release.js' = 'git-release.js'
        'git-checkout-update.js' = 'git-checkout-update.js'
    }
    foreach ($entry in $mobileSources.GetEnumerator()) {
        Write-FixtureFile -Path (Join-Path $candidateMobileRoot $entry.Key) -Value $entry.Value
    }
    foreach ($entry in $dependencyPaths.GetEnumerator()) {
        Write-FixtureFile -Path (Join-Path $installRoot $entry.Value) -Value ("installed:" + $entry.Key)
        Write-FixtureFile -Path (Join-Path $candidateRoot $entry.Value) -Value ("candidate:" + $entry.Key)
    }

    $launcherText = Get-Content -LiteralPath $launcherSource -Raw
    $tailMarker = '$node = Resolve-UpdateSessionNode'
    $tailIndex = $launcherText.IndexOf($tailMarker, [StringComparison]::Ordinal)
    if ($tailIndex -lt 1 -or $launcherText.IndexOf($tailMarker, $tailIndex + 1, [StringComparison]::Ordinal) -ge 0) {
        throw 'The update-session launcher execution boundary changed.'
    }
    $fixtureLauncher = Join-Path $candidateMobileRoot 'UpdateSessionLauncher.ps1'
    $fixtureTail = @'
$bundle = Copy-ImmutableUpdateSessionBundle -Node 'unused'
[pscustomobject][ordered]@{
    bundlePath = $bundle
    bundleRoot = $BundleRoot
    installRoot = $InstallRoot
} | ConvertTo-Json -Compress
'@
    Write-FixtureFile -Path $fixtureLauncher -Value ($launcherText.Substring(0, $tailIndex) + $fixtureTail)

    $defaultResult = & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$defaultResult.installRoot), [IO.Path]::GetFullPath($installRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$defaultResult.bundleRoot), [IO.Path]::GetFullPath($installRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The default bundle root no longer preserves the installed-root behavior.'
    }
    foreach ($entry in $mobileSources.GetEnumerator()) {
        if ((Get-Content -LiteralPath (Join-Path $defaultResult.bundlePath $entry.Key) -Raw) -cne $entry.Value) {
            throw "The default snapshot did not use the launcher-owned $($entry.Key)."
        }
    }
    foreach ($entry in $dependencyPaths.GetEnumerator()) {
        if ((Get-Content -LiteralPath (Join-Path $defaultResult.bundlePath $entry.Key) -Raw) -cne ("installed:" + $entry.Key)) {
            throw "The default snapshot did not preserve the installed $($entry.Key)."
        }
    }

    $explicitResult = & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -BundleRoot $candidateRoot | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$explicitResult.installRoot), [IO.Path]::GetFullPath($installRoot), [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$explicitResult.bundleRoot), [IO.Path]::GetFullPath($candidateRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'An explicit bundle root changed the target install root or was not retained.'
    }
    foreach ($entry in $mobileSources.GetEnumerator()) {
        if ((Get-Content -LiteralPath (Join-Path $explicitResult.bundlePath $entry.Key) -Raw) -cne $entry.Value) {
            throw "The explicit snapshot did not use the launcher-owned $($entry.Key)."
        }
    }
    foreach ($entry in $dependencyPaths.GetEnumerator()) {
        if ((Get-Content -LiteralPath (Join-Path $explicitResult.bundlePath $entry.Key) -Raw) -cne ("candidate:" + $entry.Key)) {
            throw "The explicit snapshot did not use the candidate $($entry.Key)."
        }
    }
    if ([string]::Equals([string]$defaultResult.bundlePath, [string]$explicitResult.bundlePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Different dependency engines unexpectedly produced the same immutable bundle.'
    }
    Write-FixtureFile -Path (Join-Path $candidateRoot 'git-release.js') -Value 'candidate:git-release.js:changed'
    $helperChangedResult = & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -BundleRoot $candidateRoot | ConvertFrom-Json
    if ([string]::Equals([string]$explicitResult.bundlePath, [string]$helperChangedResult.bundlePath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A Git helper change did not change the immutable update-session bundle fingerprint.'
    }
    if ((Get-Content -LiteralPath (Join-Path $helperChangedResult.bundlePath 'git-release.js') -Raw) -cne 'candidate:git-release.js:changed') {
        throw 'The Git helper fingerprint selected a snapshot without the changed helper.'
    }

    foreach ($relative in @('Update-ChatGPTRemote.ps1', 'update-transaction.js', 'git-release.js', 'git-checkout-update.js')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot "windows\$relative") -Destination (Join-Path $candidateRoot $relative) -Force
    }
    $actualResult = & $fixtureLauncher -InstallRoot $candidateRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -BundleRoot $candidateRoot | ConvertFrom-Json
    $actualUpdater = Join-Path $actualResult.bundlePath 'Update-ChatGPTRemote.ps1'
    $shell = if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe') -PathType Leaf) {
        Join-Path $PSHOME 'pwsh.exe'
    } elseif ($env:SystemRoot) {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    } else {
        throw 'No PowerShell host is available for the detached Git helper resolution fixture.'
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $actualOutput = @(& $shell -NoProfile -NonInteractive -File $actualUpdater -Action Check -InstallRoot $candidateRoot -Transport Git -Repository invalid 2>&1)
        $actualExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $actualText = [string]::Join([Environment]::NewLine, @($actualOutput | ForEach-Object { [string]$_ }))
    if ($actualExitCode -eq 0 -or $actualText -notmatch 'Repository must use a validated owner/name form') {
        throw "The detached updater did not resolve and execute its real Git release helper: $actualText"
    }
    $mixedRootRejected = $false
    try {
        & $fixtureLauncher -InstallRoot $installRoot -EntryPointRelative 'Enable-ChatGPTRemote.ps1' -BundleRoot $installRoot | Out-Null
    } catch {
        $mixedRootRejected = $_.Exception.Message -match 'does not own this launcher'
    }
    if (-not $mixedRootRejected) { throw 'An explicit root from a different launcher tree was not rejected.' }

    $global:LASTEXITCODE = 0
    [pscustomobject][ordered]@{
        DefaultUsesInstallRootDependencies = $true
        ExplicitUsesCandidateDependencies = $true
        InstallRootRemainsTarget = $true
        LauncherOwnedControllerFiles = $true
        GitUpdaterHelpersBundled = $true
        GitHelperChangesFingerprint = $true
        DetachedUpdaterResolvesRealGitHelper = $true
        DistinctImmutableBundles = $true
        MixedExplicitRootRejected = $true
    } | ConvertTo-Json -Compress
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^chatgpt-remote-bundle-root-test-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath $resolved -PathType Container)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
