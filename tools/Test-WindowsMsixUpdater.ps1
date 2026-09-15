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
        [string]$Status = 'Ok'
    )
    [pscustomobject][ordered]@{
        Name = $Name
        Version = [version]$Version
        Architecture = $Architecture
        Publisher = $Publisher
        SignatureKind = $SignatureKind
        Status = $Status
        PackageFullName = "${Name}_${Version}_x64__fixture"
        InstallLocation = 'C:\Program Files\WindowsApps\fixture'
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
    } -PackageEnumerator { ,(New-FixturePackage -Version '26.903.9000.0') } -ProcessEnumerator { @() } -MetadataMaximumAttempts 1 -MetadataRetryDelaySeconds 0
    Assert-Condition ($offlineCurrent.Decision -ceq 'RemoteUnavailableCurrentInstalled' -and -not $offlineCurrent.CanInstall -and $offlineCurrent.TransientFailure) 'A transient endpoint outage did not preserve the verified installed package for launch.'
    $check = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,(New-FixturePackage -Version '26.903.9000.0') }
    Assert-Condition ($check.Decision -ceq 'UpdateAvailable' -and $check.CanInstall) 'Check did not identify the newer direct package.'
    $freshCheck = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { @() }
    Assert-Condition ($freshCheck.Decision -ceq 'FreshInstall' -and $freshCheck.CanInstall) 'Check did not report a clear fresh-install state.'

    $legacyCheck = Invoke-ChatGPTDesktopMsixUpdater -Action Check -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -HeadRequester $head -PackageEnumerator { ,$legacy }
    Assert-Condition ($legacyCheck.Decision -ceq 'IdentityMismatch' -and -not $legacyCheck.CanInstall) 'Legacy identity was not kept from a side-by-side migration.'

    $installCalls = 0
    $whatIf = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator { @() } -ProcessEnumerator { @() } -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { param($path) $installCalls++ } -WhatIf
    Assert-Condition ($whatIf.Decision -ceq 'WhatIf' -and $installCalls -eq 0) 'WhatIf did not prevent the installer call.'

    $runningCalls = 0
    Assert-Throws {
        Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator { @() } -ProcessEnumerator { ,([pscustomobject]@{ ProcessName = 'ChatGPT'; Id = 17 }) } -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { param($path) $runningCalls++ }
    } 'ChatGPT\.exe is running'
    Assert-Condition ($runningCalls -eq 0) 'Running ChatGPT fixture still reached the installer.'

    $callState = @{ Count = 0 }
    $installerState = @{ Path = $null }
    $successful = Invoke-ChatGPTDesktopMsixUpdater -Action Update -PackageUri 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' -PackagePath $fixture -HeadRequester $head -PackageEnumerator {
        $callState.Count++
        if ($callState.Count -eq 1) { return @() }
        return ,(New-FixturePackage)
    } -ProcessEnumerator { @() } -SignatureReader { param($path) [pscustomobject]@{ Status = 'Valid'; SignerCertificate = 'fixture' } } -Installer { param($path) $installerState.Path = $path }
    Assert-Condition ($successful.Decision -ceq 'Installed' -and $null -ne $installerState.Path -and -not [IO.File]::Exists($installerState.Path)) 'Successful mocked install did not verify and clean its per-user temp package.'

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
