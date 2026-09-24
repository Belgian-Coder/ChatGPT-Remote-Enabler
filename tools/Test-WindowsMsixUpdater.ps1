[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updater = Join-Path $root 'windows\Update-ChatGPTDesktop.ps1'
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($updater, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw "MSIX updater does not parse: $($parseErrors[0].Message)" }
$updaterSource = Get-Content -LiteralPath $updater -Raw
foreach ($contract in @('Invoke-OfficialPackageCurlRequest', "`$PSVersionTable.PSEdition -eq 'Desktop'", "`$curl = Join-Path `$env:SystemRoot 'System32\curl.exe'", "@('--disable','--silent','--show-error','--ssl-revoke-best-effort'", "@('CURL_CA_BUNDLE','SSL_CERT_FILE','SSL_CERT_DIR')", "'--speed-limit','1','--speed-time'", "`$client.Timeout = [Threading.Timeout]::InfiniteTimeSpan", '[ChatGPTRemoteProgressStreamCopier]::CopyToWithInactivityTimeout($stream, $output, 81920, ($TimeoutSec * 1000))')) {
    if (-not $updaterSource.Contains($contract)) { throw "MSIX updater cross-PowerShell proxy/deadline contract is missing: $contract" }
}

# Load only the helper functions. No network request or AppX mutation is made
# by this test; the package, signature, AppX reader and installer are fixtures.
. $updater -NoExecute

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $thrown = $false
    try { & $Action } catch {
        $thrown = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
    }
    if (-not $thrown) { throw "Expected failure matching '$Pattern'." }
}

$previousDesktopProxy = $script:DesktopUpdateProxyServer
try {
    $script:DesktopUpdateProxyServer = 'https://192.0.2.1:81'
    $curlFailure = $null
    try { [void](Invoke-OfficialPackageCurlRequest -Uri ([Uri]'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix') -Method Head -TimeoutSec 1) }
    catch { $curlFailure = $_ }
    Assert-Condition ($null -ne $curlFailure -and (Test-TransientPackageMetadataFailure -ErrorRecord $curlFailure)) 'The Windows PowerShell HTTPS-proxy curl failure was not classified as transient.'
} finally { $script:DesktopUpdateProxyServer = $previousDesktopProxy }

function New-FixturePackage {
    param(
        [string]$Name = 'OpenAI.Codex',
        [string]$Version = '26.903.9999.0',
        [string]$Architecture = 'X64',
        [string]$Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B',
        [string]$SignatureKind = 'Store',
        [string]$Status = 'Ok',
        [string]$PackageFullName = "${Name}_${Version}_x64__fixture",
        [string]$InstallLocation = 'C:\Program Files\WindowsApps\fixture'
    )
    [pscustomobject][ordered]@{
        Name = $Name
        Version = [version]$Version
        Architecture = $Architecture
        Publisher = $Publisher
        SignatureKind = $SignatureKind
        Status = $Status
        PackageFullName = $PackageFullName
        InstallLocation = $InstallLocation
    }
}

function New-FixtureMsix {
    param([string]$Path, [string]$Name = 'OpenAI.Codex', [string]$Version = '26.903.9999.0', [string]$Architecture = 'x64', [string]$Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B')
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="$Name" Publisher="$Publisher" ProcessorArchitecture="$Architecture" Version="$Version" />
  <Properties><DisplayName>ChatGPT</DisplayName><PublisherDisplayName>OpenAI</PublisherDisplayName><Logo>assets/icon.png</Logo></Properties>
</Package>
"@
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('AppxManifest.xml')
        $writer = New-Object IO.StreamWriter($entry.Open(), [Text.Encoding]::UTF8)
        try { $writer.Write($manifest) } finally { $writer.Dispose() }
        $signatureEntry = $archive.CreateEntry('AppxSignature.p7x')
        $signatureWriter = New-Object IO.StreamWriter($signatureEntry.Open(), [Text.Encoding]::ASCII)
        try { $signatureWriter.Write('fixture-signature') } finally { $signatureWriter.Dispose() }
    } finally { $archive.Dispose() }
    return $Path
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-msix-updater-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
$fixtureDeferredStatePath = Join-Path $fixtureRoot 'default-deferred.json'
$productionDeferredStatePath = Get-DesktopUpdateDeferredStatePath
$expectedDeferredStateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ChatGPTRemoteEnabler'
Assert-Condition ([IO.Path]::IsPathRooted($productionDeferredStatePath) -and [string]::Equals((Split-Path -Parent $productionDeferredStatePath), $expectedDeferredStateRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $productionDeferredStatePath) -ceq 'desktop-update-deferred.json') 'The production deferral-state path is not rooted in the current user LocalApplicationData profile.'
function Get-DesktopUpdateDeferredStatePath { return $fixtureDeferredStatePath }
try {
    $fixture = New-FixtureMsix -Path (Join-Path $fixtureRoot 'valid.msix')
    $manifest = Read-MsixPackageManifest -Path $fixture
    Assert-Condition ($manifest.Name -ceq 'OpenAI.Codex' -and $manifest.Architecture -ceq 'x64' -and $manifest.Version -eq [version]'26.903.9999.0') 'Valid fixture manifest was not inspected correctly.'

    foreach ($bad in @(
        @{ Name = 'Contoso.ChatGPT'; Version = '26.903.9999.0'; Architecture = 'x64'; Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'; Pattern = 'identity' },
        @{ Name = 'OpenAI.Codex'; Version = '26.903.9999.0'; Architecture = 'x64'; Publisher = 'CN=Contoso'; Pattern = 'publisher' },
        @{ Name = 'OpenAI.Codex'; Version = '26.903.9999.0'; Architecture = 'arm64'; Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'; Pattern = 'architecture' }
    )) {
        $badPath = Join-Path $fixtureRoot ($bad.Pattern + '.msix')
        New-FixtureMsix -Path $badPath -Name $bad.Name -Version $bad.Version -Architecture $bad.Architecture -Publisher $bad.Publisher | Out-Null
        Assert-Throws { Read-MsixPackageManifest -Path $badPath } $bad.Pattern
    }

    $current = New-FixturePackage
    $legacy = New-FixturePackage -Name 'OpenAI.ChatGPT-Desktop' -Version '1.2026.1.0'
    $state = Get-InstalledChatGptPackageState -PackageEnumerator { ,$current }
    Assert-Condition ($state.State -ceq 'Installed' -and $state.Identity -ceq 'OpenAI.Codex') 'MSIX/current identity discovery failed.'
    $state = Get-InstalledChatGptPackageState -PackageEnumerator { ,$legacy }
    Assert-Condition ($state.State -ceq 'Installed' -and $state.Identity -ceq 'OpenAI.ChatGPT-Desktop') 'AppX/legacy identity discovery failed.'
    $state = Get-InstalledChatGptPackageState -PackageEnumerator { @() }
    Assert-Condition ($state.State -ceq 'NotInstalled') 'Neither-package discovery failed.'
    Assert-Throws { Get-InstalledChatGptPackageState -PackageEnumerator { ,$current; ,$legacy } } 'Ambiguous current-user ChatGPT package state'

    $fixtureDeferredResolver = (Get-Item Function:\Get-DesktopUpdateDeferredStatePath).ScriptBlock
    try {
        Set-Item Function:\Get-DesktopUpdateDeferredStatePath -Value { throw 'Probe must not resolve an unused per-user deferral path.' }
        $probeWithoutProfilePath = Invoke-ChatGPTDesktopMsixUpdater -Action Probe -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackageEnumerator { ,$current } -ProcessEnumerator { @() }
    } finally {
        Set-Item Function:\Get-DesktopUpdateDeferredStatePath -Value $fixtureDeferredResolver
    }
    Assert-Condition ($probeWithoutProfilePath.Action -ceq 'Probe' -and $probeWithoutProfilePath.InstalledState -ceq 'Installed') 'Probe unnecessarily depended on a writable current-user deferral path.'

    $unrelatedPrivilegeError = $null
    try { throw 'Administrator privileges are required to install this package.' } catch { $unrelatedPrivilegeError = $_ }
    Assert-Condition (-not (Test-CurrentUserAppxInstallBlocked -ErrorRecord $unrelatedPrivilegeError)) 'A message-only privilege failure was misclassified as HRESULT 0x80073D28.'
    foreach ($longCode in @('0x80073D280', '0x80073D28A')) {
        $longCodeError = $null
        try { throw "Unrelated deployment code $longCode" } catch { $longCodeError = $_ }
        Assert-Condition (-not (Test-CurrentUserAppxInstallBlocked -ErrorRecord $longCodeError)) "A longer hexadecimal token $longCode was misclassified as exact HRESULT 0x80073D28."
    }

    $fixtureDeferredResolver = (Get-Item Function:\Get-DesktopUpdateDeferredStatePath).ScriptBlock
    try {
        Set-Item Function:\Get-DesktopUpdateDeferredStatePath -Value { throw 'Check must tolerate an unavailable per-user deferral path.' }
        $checkWithoutProfilePath = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester { [pscustomobject]@{ Headers = @{ 'x-ms-meta-package_identity' = 'OpenAI.Codex'; 'x-ms-meta-package_version' = '26.903.9999.0'; 'x-ms-meta-architecture' = 'x64'; 'Content-Length' = '123'; 'ETag' = 'fixture' } } } -PackageEnumerator { ,(New-FixturePackage -Version '26.903.9000.0') }
    } finally {
        Set-Item Function:\Get-DesktopUpdateDeferredStatePath -Value $fixtureDeferredResolver
    }
    Assert-Condition ($checkWithoutProfilePath.Decision -ceq 'UpdateAvailable' -and $checkWithoutProfilePath.CanInstall) 'Read-only Check failed when the optional per-user deferral path was unavailable.'

    $signature = Test-MsixAuthenticodeSignature -Path $fixture -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } }
    Assert-Condition ($signature.Verified) 'Valid Authenticode fixture was not accepted.'
    Assert-Throws { Test-MsixAuthenticodeSignature -Path $fixture -SignatureReader { param($path) [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } } } 'not valid'
    $native = Test-MsixPackageSignature -Path $fixture -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } }
    Assert-Condition $native.Verified 'Valid Windows package signature fixture was not accepted.'
    $signatureOnlyFixture = Join-Path $fixtureRoot 'no-signature.msix'
    New-FixtureMsix -Path $signatureOnlyFixture | Out-Null
    $archive = [IO.Compression.ZipFile]::Open($signatureOnlyFixture, [IO.Compression.ZipArchiveMode]::Update)
    try { [void]$archive.Entries[1].Delete() } finally { $archive.Dispose() }
    Assert-Throws { Test-MsixPackageSignature -Path $signatureOnlyFixture -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } } 'AppxSignature\.p7x'

    $metadata = [pscustomobject]@{ Headers = @{ 'x-ms-meta-package_identity' = 'OpenAI.Codex'; 'x-ms-meta-package_version' = '26.903.9999.0'; 'x-ms-meta-architecture' = 'x64'; 'Content-Length' = '123'; 'ETag' = 'fixture' } }
    $head = { param($uri) $metadata }
    $retryState = @{ Count = 0; Delays = @() }
    $retriedMetadata = Get-HeadPackageMetadata -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester {
        param($uri)
        $retryState.Count++
        if ($retryState.Count -lt 3) { throw [Net.WebException]::new('The remote server returned an error: (504) Gateway Timeout.') }
        return $metadata
    } -RetryDelaySeconds 1 -Sleeper { param($seconds) $retryState.Delays += $seconds }
    Assert-Condition ($retryState.Count -eq 3 -and ($retryState.Delays -join ',') -ceq '1,2') 'Transient metadata failures were not retried with bounded backoff.'
    Assert-Condition ($retriedMetadata.VersionText -ceq '26.903.9999.0') 'The metadata retry did not return the eventual verified response.'
    $proxyDnsFailure = $null
    try { throw [Net.WebException]::new('curl package request failed with exit code 5.', [Net.WebExceptionStatus]::ProxyNameResolutionFailure) }
    catch { $proxyDnsFailure = $_ }
    Assert-Condition (Test-TransientPackageMetadataFailure -ErrorRecord $proxyDnsFailure) 'A temporary HTTPS proxy DNS failure was not classified as transient.'
    $proxyDnsRetry = @{ Count = 0 }
    $proxyDnsMetadata = Get-HeadPackageMetadata -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester {
        param($uri)
        $proxyDnsRetry.Count++
        if ($proxyDnsRetry.Count -eq 1) { throw [Net.WebException]::new('curl package request failed with exit code 5.', [Net.WebExceptionStatus]::ProxyNameResolutionFailure) }
        return $metadata
    } -RetryDelaySeconds 0
    Assert-Condition ($proxyDnsRetry.Count -eq 2 -and $proxyDnsMetadata.VersionText -ceq '26.903.9999.0') 'A temporary HTTPS proxy DNS failure did not retry and recover.'
    $canceledState = @{ Count = 0 }
    $canceledMetadata = Get-HeadPackageMetadata -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester {
        param($uri)
        $canceledState.Count++
        if ($canceledState.Count -eq 1) { throw [Threading.Tasks.TaskCanceledException]::new('A task was canceled.') }
        return $metadata
    } -RetryDelaySeconds 0
    Assert-Condition ($canceledState.Count -eq 2 -and $canceledMetadata.VersionText -ceq '26.903.9999.0') 'HttpClient timeout cancellation was not retried.'
    $permanentState = @{ Count = 0 }
    Assert-Throws {
        Get-HeadPackageMetadata -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester {
            param($uri)
            $permanentState.Count++
            throw [Net.WebException]::new('The remote server returned an error: (401) Unauthorized.')
        } -RetryDelaySeconds 0
    } '401'
    Assert-Condition ($permanentState.Count -eq 1) 'A permanent metadata failure was retried.'
    $offlineCurrent = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester {
        param($uri)
        throw [Net.WebException]::new('The remote server returned an error: (504) Gateway Timeout.')
    } -PackageEnumerator { ,(New-FixturePackage -Version '26.903.9000.0') } -ProcessEnumerator { @() } -DeferredStatePath $fixtureDeferredStatePath -MetadataMaximumAttempts 1 -MetadataRetryDelaySeconds 0
    Assert-Condition ($offlineCurrent.Decision -ceq 'RemoteUnavailableCurrentInstalled' -and -not $offlineCurrent.CanInstall -and $offlineCurrent.TransientFailure) 'A transient endpoint outage did not preserve the verified installed package for launch.'
    $check = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,(New-FixturePackage -Version '26.903.9000.0') } -DeferredStatePath $fixtureDeferredStatePath
    Assert-Condition ($check.Decision -ceq 'UpdateAvailable' -and $check.CanInstall) 'Check did not identify the newer direct package.'
    $freshCheck = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { @() } -DeferredStatePath $fixtureDeferredStatePath
    Assert-Condition ($freshCheck.Decision -ceq 'FreshInstall' -and $freshCheck.CanInstall) 'Check did not report a clear fresh-install state.'

    $legacyCheck = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$legacy } -DeferredStatePath $fixtureDeferredStatePath
    Assert-Condition ($legacyCheck.Decision -ceq 'IdentityMismatch' -and -not $legacyCheck.CanInstall) 'Legacy identity was not kept from a side-by-side migration.'

    $installCalls = 0
    $whatIf = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator { @() } -ProcessEnumerator { @() } -DeferredStatePath $fixtureDeferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { param($path) $installCalls++ } -WhatIf
    Assert-Condition ($whatIf.Decision -ceq 'WhatIf' -and $installCalls -eq 0) 'WhatIf did not prevent the installer call.'

    $runningCalls = 0
    Assert-Throws {
        Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator { @() } -ProcessEnumerator { ,([pscustomobject]@{ ProcessName = 'ChatGPT'; Id = 17 }) } -DeferredStatePath $fixtureDeferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { param($path) $runningCalls++ }
    } 'ChatGPT\.exe is running'
    Assert-Condition ($runningCalls -eq 0) 'Running ChatGPT fixture still reached the installer.'

    $blockedPackage = New-FixturePackage -Version '26.903.9000.0'
    $blockedEnumerations = @{ Count = 0 }
    $deferredStatePath = Join-Path $fixtureRoot 'desktop-update-deferred.json'
    $blockedInstallerCalls = @{ Count = 0 }
    $originalSaveMsix = (Get-Item Function:\Save-MsixToPerUserTemp).ScriptBlock
    try {
        Set-Item Function:\Save-MsixToPerUserTemp -Value { param($Uri, $PackagePath, $DestinationRoot) return $fixture }
        $deferred = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator {
            $blockedEnumerations.Count++
            return ,$blockedPackage
        } -ProcessEnumerator { @() } -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -DeferredStatePath $deferredStatePath -Installer {
            param($path)
            $blockedInstallerCalls.Count++
            throw [Runtime.InteropServices.COMException]::new('Administrator privileges are required to install this package.', -2147009240)
        }
    } finally {
        Set-Item Function:\Save-MsixToPerUserTemp -Value $originalSaveMsix
    }
    Assert-Condition ($deferred.Decision -ceq 'UpdateDeferredCurrentInstalled' -and -not $deferred.CanInstall -and $deferred.InstallDeferred -and $deferred.DeferralCached -and $null -eq $deferred.DeferralCacheReason -and $blockedEnumerations.Count -eq 2 -and $blockedInstallerCalls.Count -eq 1) 'A policy-blocked current-user update did not preserve the unchanged healthy installed package.'
    Assert-Condition ([string]$deferred.Installed.Version -ceq '26.903.9000.0' -and [string]$deferred.Manifest.VersionText -ceq '26.903.9999.0') 'Deferred update proof did not retain exact installed and verified candidate versions.'
    Assert-Condition (Test-Path -LiteralPath $deferredStatePath -PathType Leaf) 'A policy-blocked verified candidate was not recorded for bounded subsequent startup.'

    foreach ($inUseInstaller in @(
        { param($path) throw [Runtime.InteropServices.COMException]::new('Package resources are in use.', -2147009278) },
        { param($path) throw [InvalidOperationException]::new('Wrapped deployment failure', [Runtime.InteropServices.COMException]::new('Package resources are in use.', -2147009278)) },
        { param($path) throw 'Deployment failed with HRESULT: 0x80073D02, resources are currently in use.' }
    )) {
        $inUseResult = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -DeferredStatePath $fixtureDeferredStatePath -Installer $inUseInstaller
        Assert-Condition ($inUseResult.Decision -ceq 'UpdateDeferredCurrentInstalled' -and $inUseResult.InstallDeferred -and [string]$inUseResult.Installed.Version -ceq '26.903.9000.0') 'Package-in-use failure blocked launch of the unchanged installation.'
    }
    foreach ($longCode in @('0x80073D020', '0x80073D02A')) {
        $inUseError = [Management.Automation.ErrorRecord]::new([Exception]::new($longCode), 'fixture', [Management.Automation.ErrorCategory]::NotSpecified, $null)
        Assert-Condition (-not (Test-CurrentUserAppxInstallBlocked -ErrorRecord $inUseError)) 'A longer hexadecimal token was mistaken for package-in-use.'
    }

    foreach ($registrationChange in @(
        @{ Label = 'package-full-name'; Package = (New-FixturePackage -Version '26.903.9000.0' -PackageFullName 'OpenAI.Codex_26.903.9000.0_x64__changed') },
        @{ Label = 'install-location'; Package = (New-FixturePackage -Version '26.903.9000.0' -InstallLocation 'C:\Program Files\WindowsApps\fixture-moved') }
    )) {
        $registrationEnumerations = @{ Count = 0 }
        $registrationStatePath = Join-Path $fixtureRoot ("desktop-update-registration-$($registrationChange.Label).json")
        $changedRegistration = $registrationChange.Package
        Assert-Throws {
            Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator {
                $registrationEnumerations.Count++
                if ($registrationEnumerations.Count -eq 1) { return ,$blockedPackage }
                return ,$changedRegistration
            } -ProcessEnumerator { @() } -DeferredStatePath $registrationStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer {
                throw [Runtime.InteropServices.COMException]::new('0x80073D28', -2147009240)
            }
        } 'MSIX current-user installation failed'
        Assert-Condition ($registrationEnumerations.Count -eq 2 -and -not (Test-Path -LiteralPath $registrationStatePath)) "A changed $($registrationChange.Label) was accepted as an unchanged installed registration."
    }

    $lockedDeferredStatePath = Join-Path $fixtureRoot 'desktop-update-locked-read.json'
    Copy-Item -LiteralPath $deferredStatePath -Destination $lockedDeferredStatePath
    $lockedDeferredStream = [IO.File]::Open($lockedDeferredStatePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-Condition ($null -eq (Read-DesktopUpdateDeferredState -Path $lockedDeferredStatePath) -and (Test-Path -LiteralPath $lockedDeferredStatePath)) 'A transient deferral-state read failure deleted the verified record.'
    } finally {
        $lockedDeferredStream.Dispose()
    }
    Remove-Item -LiteralPath $lockedDeferredStatePath -Force

    $verifiedRemoteMetadata = Get-HeadPackageMetadata -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head
    foreach ($cachedRegistrationChange in @(
        @{ Label = 'package-full-name'; Package = (New-FixturePackage -Version '26.903.9000.0' -PackageFullName 'OpenAI.Codex_26.903.9000.0_x64__changed') },
        @{ Label = 'install-location'; Package = (New-FixturePackage -Version '26.903.9000.0' -InstallLocation 'C:\Program Files\WindowsApps\fixture-moved') }
    )) {
        $changedCachePath = Join-Path $fixtureRoot ("desktop-update-cache-$($cachedRegistrationChange.Label).json")
        Copy-Item -LiteralPath $deferredStatePath -Destination $changedCachePath
        $changedInstalledState = Get-InstalledChatGptPackageState -PackageEnumerator { ,$cachedRegistrationChange.Package }
        Assert-Condition ($null -eq (Get-MatchingDesktopUpdateDeferredState -Path $changedCachePath -Installed $changedInstalledState -Remote $verifiedRemoteMetadata) -and -not (Test-Path -LiteralPath $changedCachePath)) "A cached deferral survived a changed installed $($cachedRegistrationChange.Label)."
    }
    foreach ($invalidValidator in @(
        @{ Label = 'missing'; Metadata = [pscustomobject]@{ Headers = @{ 'x-ms-meta-package_identity' = 'OpenAI.Codex'; 'x-ms-meta-package_version' = '26.903.9999.0'; 'x-ms-meta-architecture' = 'x64'; 'Content-Length' = '123' } } },
        @{ Label = 'weak'; Metadata = [pscustomobject]@{ Headers = @{ 'x-ms-meta-package_identity' = 'OpenAI.Codex'; 'x-ms-meta-package_version' = '26.903.9999.0'; 'x-ms-meta-architecture' = 'x64'; 'Content-Length' = '123'; 'ETag' = 'W/"fixture"' } } }
    )) {
        $invalidValidatorStatePath = Join-Path $fixtureRoot ("desktop-update-$($invalidValidator.Label)-validator.json")
        $currentInvalidValidatorMetadata = $invalidValidator.Metadata
        $originalSaveMsix = (Get-Item Function:\Save-MsixToPerUserTemp).ScriptBlock
        try {
            Set-Item Function:\Save-MsixToPerUserTemp -Value { param($Uri, $PackagePath, $DestinationRoot) return $fixture }
            $invalidValidatorDeferred = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester { param($uri) $currentInvalidValidatorMetadata } -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -DeferredStatePath $invalidValidatorStatePath -Installer {
                throw [Runtime.InteropServices.COMException]::new('0x80073D28', -2147009240)
            }
        } finally {
            Set-Item Function:\Save-MsixToPerUserTemp -Value $originalSaveMsix
        }
        Assert-Condition ($invalidValidatorDeferred.InstallDeferred -and -not $invalidValidatorDeferred.DeferralCached -and $invalidValidatorDeferred.DeferralCacheReason -like '*strong ETag*' -and -not (Test-Path -LiteralPath $invalidValidatorStatePath)) "A $($invalidValidator.Label) strong validator was cached or did not explain why caching was disabled."
    }
    foreach ($corruptDeferredState in @(
        @{ Label = 'invalid-json'; Content = 'not json' },
        @{ Label = 'wrong-schema'; Content = '{"schemaVersion":2}' },
        @{ Label = 'missing-shape'; Content = '{"schemaVersion":1}' }
    )) {
        $corruptDeferredStatePath = Join-Path $fixtureRoot ("desktop-update-$($corruptDeferredState.Label).json")
        [IO.File]::WriteAllText($corruptDeferredStatePath, $corruptDeferredState.Content, [Text.UTF8Encoding]::new($false))
        $originalSaveMsix = (Get-Item Function:\Save-MsixToPerUserTemp).ScriptBlock
        try {
            Set-Item Function:\Save-MsixToPerUserTemp -Value { param($Uri, $PackagePath, $DestinationRoot) return $fixture }
            $recoveredFromCorruptState = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -DeferredStatePath $corruptDeferredStatePath -Installer {
                throw [Runtime.InteropServices.COMException]::new('0x80073D28', -2147009240)
            }
        } finally {
            Set-Item Function:\Save-MsixToPerUserTemp -Value $originalSaveMsix
        }
        Assert-Condition ($recoveredFromCorruptState.InstallDeferred -and (Test-Path -LiteralPath $corruptDeferredStatePath -PathType Leaf)) "A $($corruptDeferredState.Label) deferral record escaped recovery on the automatic launch path."
        $rewrittenState = Get-Content -LiteralPath $corruptDeferredStatePath -Raw | ConvertFrom-Json
        Assert-Condition ([int]$rewrittenState.schemaVersion -eq 1 -and [string]$rewrittenState.remote.etag -ceq 'fixture') "A $($corruptDeferredState.Label) deferral record was not replaced with verified state."
        Remove-Item -LiteralPath $corruptDeferredStatePath -Force
    }
    $textDeferredStatePath = Join-Path $fixtureRoot 'desktop-update-text-deferred.json'
    $textDeferred = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $textDeferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer {
        throw 'Deployment failed with HRESULT: 0x80073D28, administrator privileges are required to install this package.'
    }
    Assert-Condition ($textDeferred.Decision -ceq 'UpdateDeferredCurrentInstalled' -and $textDeferred.InstallDeferred) 'A wrapped text-only 0x80073D28 deployment error was not recognized.'
    $originalSaveMsix = (Get-Item Function:\Save-MsixToPerUserTemp).ScriptBlock
    try {
        Set-Item Function:\Save-MsixToPerUserTemp -Value { throw 'cached deferral must not download the 774 MB candidate' }
        $cachedDeferred = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $deferredStatePath -SignatureReader { throw 'cached deferral must not redownload or reverify the 774 MB candidate' } -Installer { $blockedInstallerCalls.Count++ }
    } finally {
        Set-Item Function:\Save-MsixToPerUserTemp -Value $originalSaveMsix
    }
    Assert-Condition ($cachedDeferred.Decision -ceq 'UpdateDeferredCurrentInstalled' -and $cachedDeferred.DeferredFromCache -and $blockedInstallerCalls.Count -eq 1) 'The exact deferred candidate was downloaded or installed again on the next launch.'
    $cachedCheck = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -DeferredStatePath $deferredStatePath
    Assert-Condition ($cachedCheck.Decision -ceq 'UpdateDeferredCurrentInstalled' -and -not $cachedCheck.CanInstall -and $cachedCheck.DeferredFromCache -and (Test-Path -LiteralPath $deferredStatePath)) 'The read-only Check result disagreed with the matching automatic update deferral.'
    $corruptCheckStatePath = Join-Path $fixtureRoot 'desktop-update-corrupt-check.json'
    [IO.File]::WriteAllText($corruptCheckStatePath, 'not json', [Text.UTF8Encoding]::new($false))
    $corruptCheck = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -DeferredStatePath $corruptCheckStatePath
    Assert-Condition ($corruptCheck.Decision -ceq 'UpdateAvailable' -and (Get-Content -LiteralPath $corruptCheckStatePath -Raw) -ceq 'not json') 'The read-only Check path mutated a corrupt deferral record.'
    $weakLiveStatePath = Join-Path $fixtureRoot 'desktop-update-weak-live-validator.json'
    Copy-Item -LiteralPath $deferredStatePath -Destination $weakLiveStatePath
    $weakLiveMetadata = Get-HeadPackageMetadata -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester { [pscustomobject]@{ Headers = @{ 'x-ms-meta-package_identity' = 'OpenAI.Codex'; 'x-ms-meta-package_version' = '26.903.9999.0'; 'x-ms-meta-architecture' = 'x64'; 'Content-Length' = '123'; 'ETag' = 'W/"fixture"' } } }
    Assert-Condition ($null -eq (Get-MatchingDesktopUpdateDeferredState -Path $weakLiveStatePath -Installed (Get-InstalledChatGptPackageState -PackageEnumerator { ,$blockedPackage }) -Remote $weakLiveMetadata) -and (Test-Path -LiteralPath $weakLiveStatePath)) 'A transient weak live ETag destroyed a previously verified deferral record.'
    $expiredDeferredStatePath = Join-Path $fixtureRoot 'desktop-update-expired-deferred.json'
    $expiredState = Get-Content -LiteralPath $deferredStatePath -Raw | ConvertFrom-Json
    $expiredState.recordedAtFileTimeUtc = [DateTime]::UtcNow.AddHours(-25).ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
    [IO.File]::WriteAllText($expiredDeferredStatePath, (($expiredState | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $expiredInstallerCalls = @{ Count = 0 }
    $originalSaveMsix = (Get-Item Function:\Save-MsixToPerUserTemp).ScriptBlock
    try {
        Set-Item Function:\Save-MsixToPerUserTemp -Value { param($Uri, $PackagePath, $DestinationRoot) return $fixture }
        $expiredRetry = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $expiredDeferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer {
            $expiredInstallerCalls.Count++
            throw [Runtime.InteropServices.COMException]::new('0x80073D28', -2147009240)
        }
    } finally {
        Set-Item Function:\Save-MsixToPerUserTemp -Value $originalSaveMsix
    }
    Assert-Condition ($expiredRetry.InstallDeferred -and -not $expiredRetry.DeferredFromCache -and $expiredRetry.DeferralCached -and $expiredInstallerCalls.Count -eq 1) 'An expired deferral did not force one fresh verified retry and renew the bounded cache.'
    $originalSaveMsix = (Get-Item Function:\Save-MsixToPerUserTemp).ScriptBlock
    try {
        Set-Item Function:\Save-MsixToPerUserTemp -Value { param($Uri, $PackagePath, $DestinationRoot) return $fixture }
        $cachedWhatIf = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $deferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { throw 'WhatIf must not install' } -WhatIf
    } finally {
        Set-Item Function:\Save-MsixToPerUserTemp -Value $originalSaveMsix
    }
    Assert-Condition ($cachedWhatIf.Decision -ceq 'WhatIf' -and $cachedWhatIf.CanInstall) 'A cached deferral suppressed the verified WhatIf preview.'
    Assert-Condition (Test-Path -LiteralPath $deferredStatePath -PathType Leaf) 'A WhatIf preview mutated the existing automatic deferral record.'
    $equalDeferredStatePath = Join-Path $fixtureRoot 'desktop-update-equal-deferred.json'
    Copy-Item -LiteralPath $deferredStatePath -Destination $equalDeferredStatePath
    $equalMetadata = [pscustomobject]@{ Headers = @{ 'x-ms-meta-package_identity' = 'OpenAI.Codex'; 'x-ms-meta-package_version' = '26.903.9000.0'; 'x-ms-meta-architecture' = 'x64'; 'Content-Length' = '123'; 'ETag' = 'fixture-equal' } }
    $equalWhatIfStatePath = Join-Path $fixtureRoot 'desktop-update-equal-whatif-deferred.json'
    Copy-Item -LiteralPath $deferredStatePath -Destination $equalWhatIfStatePath
    $equalWhatIfResult = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester { param($uri) $equalMetadata } -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $equalWhatIfStatePath -WhatIf
    Assert-Condition ($equalWhatIfResult.Decision -ceq 'EqualVersion' -and (Test-Path -LiteralPath $equalWhatIfStatePath -PathType Leaf)) 'An equal-version WhatIf preview deleted the existing automatic deferral record.'
    $equalResult = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester { param($uri) $equalMetadata } -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $equalDeferredStatePath
    Assert-Condition ($equalResult.Decision -ceq 'EqualVersion' -and -not (Test-Path -LiteralPath $equalDeferredStatePath)) 'An equal installed version did not clear the obsolete automatic deferral record.'
    $healthDeferredStatePath = Join-Path $fixtureRoot 'desktop-update-health-deferred.json'
    Copy-Item -LiteralPath $deferredStatePath -Destination $healthDeferredStatePath
    $unhealthyInstalled = Get-InstalledChatGptPackageState -PackageEnumerator { ,(New-FixturePackage -Version '26.903.9000.0' -SignatureKind '' -Status '') }
    $remoteMetadata = Get-HeadPackageMetadata -Uri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head
    Assert-Condition ($null -eq (Get-MatchingDesktopUpdateDeferredState -Path $healthDeferredStatePath -Installed $unhealthyInstalled -Remote $remoteMetadata) -and -not (Test-Path -LiteralPath $healthDeferredStatePath)) 'The cached path accepted an installation without explicit Store and healthy status proof.'
    $explicitMissingPackage = Join-Path $fixtureRoot 'explicit-new-candidate.msix'
    Assert-Throws {
        Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $explicitMissingPackage -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $deferredStatePath -SignatureReader { throw 'a missing explicit candidate must fail before signature verification' } -Installer { throw 'a missing explicit candidate must not install' }
    } 'supplied MSIX package was not found'
    $explicitDeferredStatePath = Join-Path $fixtureRoot 'desktop-update-explicit-deferred.json'
    $explicitDeferred = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $explicitDeferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { throw [Runtime.InteropServices.COMException]::new('0x80073D28', -2147009240) }
    Assert-Condition ($explicitDeferred.InstallDeferred -eq $true -and -not (Test-Path -LiteralPath $explicitDeferredStatePath)) 'An explicitly supplied package wrote the automatic endpoint deferral cache.'
    $changedMetadata = [pscustomobject]@{ Headers = @{ 'x-ms-meta-package_identity' = 'OpenAI.Codex'; 'x-ms-meta-package_version' = '26.904.0.0'; 'x-ms-meta-architecture' = 'x64'; 'Content-Length' = '124'; 'ETag' = 'changed-fixture' } }
    $originalSaveMsix = (Get-Item Function:\Save-MsixToPerUserTemp).ScriptBlock
    try {
        Set-Item Function:\Save-MsixToPerUserTemp -Value { param($Uri, $PackagePath, $DestinationRoot) return $fixture }
        Assert-Throws {
            Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester { param($uri) $changedMetadata } -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $deferredStatePath -SignatureReader { throw 'manifest mismatch must fail before signature verification' } -Installer { throw 'must not install' }
        } 'manifest version disagrees'
    } finally {
        Set-Item Function:\Save-MsixToPerUserTemp -Value $originalSaveMsix
    }
    Assert-Condition (-not (Test-Path -LiteralPath $deferredStatePath -PathType Leaf)) 'A changed official candidate did not invalidate the previous deferral record.'
    Assert-Throws {
        Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $deferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { param($path) throw 'unrelated installer failure' }
    } 'unrelated installer failure'
    $unrelatedComStatePath = Join-Path $fixtureRoot 'desktop-update-unrelated-com.json'
    $originalSaveMsix = (Get-Item Function:\Save-MsixToPerUserTemp).ScriptBlock
    try {
        Set-Item Function:\Save-MsixToPerUserTemp -Value { param($Uri, $PackagePath, $DestinationRoot) return $fixture }
        Assert-Throws {
            Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $unrelatedComStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { throw [Runtime.InteropServices.COMException]::new('Deployment failed', -2147009223) }
        } 'MSIX current-user installation failed'
    } finally {
        Set-Item Function:\Save-MsixToPerUserTemp -Value $originalSaveMsix
    }
    Assert-Condition (-not (Test-Path -LiteralPath $unrelatedComStatePath)) 'An unrelated AppX COM failure was misclassified and cached as a current-user policy deferral.'
    $identityMismatchStatePath = Join-Path $fixtureRoot 'desktop-update-identity-mismatch.json'
    Copy-Item -LiteralPath $expiredDeferredStatePath -Destination $identityMismatchStatePath
    $legacyIdentityMetadata = [pscustomobject]@{ Headers = @{ 'x-ms-meta-package_identity' = 'OpenAI.ChatGPT-Desktop'; 'x-ms-meta-package_version' = '26.903.9999.0'; 'x-ms-meta-architecture' = 'x64'; 'Content-Length' = '123'; 'ETag' = 'fixture-legacy' } }
    $identityMismatchResult = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester { $legacyIdentityMetadata } -PackageEnumerator { ,$blockedPackage } -ProcessEnumerator { @() } -DeferredStatePath $identityMismatchStatePath
    Assert-Condition ($identityMismatchResult.Decision -ceq 'IdentityMismatch' -and -not (Test-Path -LiteralPath $identityMismatchStatePath)) 'A real update identity mismatch retained an obsolete deferral record.'
    $changedState = @{ Count = 0 }
    Assert-Throws {
        Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator {
            $changedState.Count++
            if ($changedState.Count -eq 1) { return ,$blockedPackage }
            return ,(New-FixturePackage -Version '26.903.9001.0')
        } -ProcessEnumerator { @() } -DeferredStatePath $deferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { param($path) throw [Runtime.InteropServices.COMException]::new('0x80073D28', -2147009240) }
    } 'MSIX current-user installation failed'

    $callState = @{ Count = 0 }
    $installerState = @{ Path = $null }
    Set-Content -LiteralPath $fixtureDeferredStatePath -Value '{}' -Encoding UTF8
    $successful = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator {
        $callState.Count++
        if ($callState.Count -eq 1) { return @() }
        return ,(New-FixturePackage)
    } -ProcessEnumerator { @() } -DeferredStatePath $fixtureDeferredStatePath -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { param($path) $installerState.Path = $path }
    Assert-Condition ($successful.Decision -ceq 'Installed' -and $null -ne $installerState.Path -and -not [IO.File]::Exists($installerState.Path)) 'Successful mocked install did not verify and clean its per-user temp package.'
    Assert-Condition (-not (Test-Path -LiteralPath $fixtureDeferredStatePath)) 'A successful install did not clear the obsolete automatic deferral record.'

    $source = Get-Content -LiteralPath $updater -Raw
    foreach ($required in @('Tls12', 'LocalApplicationData', 'Get-AppxPackage', 'Add-AppxPackage', 'Get-AuthenticodeSignature', 'OpenAI.Codex', 'OpenAI.ChatGPT-Desktop', 'WhatIf', 'CurrentUser')) {
        Assert-Condition ($source.Contains($required)) "Updater safety contract is missing: $required"
    }
    $astTokens = $null
    $astErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($updater, [ref]$astTokens, [ref]$astErrors)
    Assert-Condition ($astErrors.Count -eq 0) 'Updater AST could not be parsed for safety assertions.'
    $addCommands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Add-AppxPackage' }, $true))
    Assert-Condition ($addCommands.Count -eq 1) 'Updater must contain exactly one Add-AppxPackage call.'
    $commandText = [string]$addCommands[0].Extent.Text
    foreach ($forbidden in @('-AllUsers', '-Register', '-ForceApplicationShutdown', '-ForceTargetApplicationShutdown', '-ForceUpdateFromAnyVersion')) {
        Assert-Condition (-not $commandText.Contains($forbidden)) "Updater contains a forbidden machine-wide or force-shutdown parameter: $forbidden"
    }
    Assert-Condition (-not $source.Contains('Get-AppxProvisionedPackage')) 'Updater must not use provisioning APIs.'
    Assert-Condition (-not $source.Contains('Stop-Process') -and -not $source.Contains('taskkill')) 'Updater must not stop or kill ChatGPT.'
    Write-Output 'Windows MSIX updater self-test passed.'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
$global:LASTEXITCODE = 0
