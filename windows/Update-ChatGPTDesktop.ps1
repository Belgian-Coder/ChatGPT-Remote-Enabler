[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateSet('Probe', 'Check', 'Update')]
    [string]$Action = 'Probe',
    [string]$PackageUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix',
    [string]$PackagePath,
    [switch]$UseProxy,
    [switch]$NoExecute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
if (-not ('ChatGPTRemoteProgressStreamCopier' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class ChatGPTRemoteProgressStreamCopier
{
    public static CancellationTokenRegistration Register(CancellationToken token, Stream stream)
    {
        return token.Register(state => ((Stream)state).Dispose(), stream);
    }

    public static void CopyToWithInactivityTimeout(Stream source, Stream destination, int bufferSize, int inactivityTimeoutMilliseconds)
    {
        byte[] buffer = new byte[bufferSize];
        while (true)
        {
            CancellationTokenSource cancellation = new CancellationTokenSource();
            cancellation.CancelAfter(inactivityTimeoutMilliseconds);
            CancellationTokenRegistration registration = Register(cancellation.Token, source);
            try
            {
                int read;
                try
                {
                    read = source.ReadAsync(buffer, 0, buffer.Length, cancellation.Token).GetAwaiter().GetResult();
                }
                catch (System.Exception exception)
                {
                    if (cancellation.IsCancellationRequested)
                        throw new TimeoutException("The package download stopped making progress.", exception);
                    throw;
                }
                if (read == 0) return;
                destination.Write(buffer, 0, read);
            }
            finally
            {
                registration.Dispose();
                cancellation.Dispose();
            }
        }
    }
}
'@
}

# These are package identities, not file extensions. The direct OpenAI package
# currently uses OpenAI.Codex; older Store/AppX installations used the legacy
# OpenAI.ChatGPT-Desktop identity. A package may only be updated in-place when
# the downloaded identity matches the installed identity.
$script:ChatGptPackageNames = @('OpenAI.Codex', 'OpenAI.ChatGPT-Desktop')
$script:ExpectedPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$script:ExpectedArchitecture = 'X64'
$script:DefaultPackageUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'
$script:DesktopUpdateProxyServer = $null

if ($UseProxy) {
    $proxyModule = Join-Path $PSScriptRoot 'CodexRemoteMobileProject\ProxyConfiguration.psm1'
    if (-not (Test-Path -LiteralPath $proxyModule -PathType Leaf)) {
        throw 'Proxy mode was requested, but the proxy configuration helper is missing.'
    }
    Import-Module $proxyModule -Force
    $script:DesktopUpdateProxyServer = Get-ChatGPTRemoteProxy -AllowEnvironmentFallback
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-Version {
    param([object]$Value, [string]$Label)
    $text = [string]$Value
    if ($text -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "$Label is not a valid four-part package version." }
    try {
        return [version]$text
    } catch {
        throw "$Label is not a valid four-part package version."
    }
}

function Assert-OfficialPackageUri {
    param([string]$Uri)
    $parsed = $null
    try { $parsed = [Uri]$Uri } catch { throw 'The package URI is not a valid HTTPS URI.' }
    Assert-Condition ($parsed.Scheme -ceq 'https') 'The package URI must use HTTPS.'
    Assert-Condition ($parsed.Host -ieq 'persistent.oaistatic.com') 'Only the official persistent.oaistatic.com package host is accepted.'
    Assert-Condition ($parsed.AbsolutePath -ceq '/codex-app-prod/ChatGPT-x64.msix') 'The package URI must be the official stable x64 ChatGPT MSIX path.'
    Assert-Condition ([string]::IsNullOrEmpty($parsed.Query) -and [string]::IsNullOrEmpty($parsed.Fragment)) 'The package URI must not contain query or fragment data.'
    return $parsed.AbsoluteUri
}

function Test-CurrentUserAppxInstallBlocked {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)

    for ($exception = $ErrorRecord.Exception; $null -ne $exception; $exception = $exception.InnerException) {
        $unsignedHResult = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$exception.HResult), 0)
        # Windows can still hold package resources after ChatGPT.exe exits.
        # Defer that update just like a current-user deployment restriction;
        # never force application shutdown to release the package.
        if ($unsignedHResult -in @([uint32]2147958018, [uint32]2147958056)) { return $true }
    }
    # PowerShell may wrap the deployment exception and expose the native code
    # only in the fully formatted error text.
    return [string]$ErrorRecord -match '(?i)(?<![0-9A-F])0x80073D(?:02|28)(?![0-9A-F])'
}

function Read-CurlResponseHeaders {
    param([Parameter(Mandatory)][string]$Path)
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    $statusIndex = -1
    $statusCode = 0
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ([string]$lines[$index] -match '^HTTP/\S+\s+(\d{3})\b') { $statusIndex = $index; $statusCode = [int]$matches[1] }
    }
    if ($statusIndex -lt 0) { throw 'curl did not return a parseable HTTP status.' }
    $headers = @{}
    for ($index = $statusIndex + 1; $index -lt $lines.Count -and -not [string]::IsNullOrWhiteSpace([string]$lines[$index]); $index++) {
        $separator = ([string]$lines[$index]).IndexOf(':')
        if ($separator -le 0) { continue }
        $name = ([string]$lines[$index]).Substring(0, $separator).Trim()
        $value = ([string]$lines[$index]).Substring($separator + 1).Trim()
        if ($headers.ContainsKey($name)) { $headers[$name] = @($headers[$name]) + $value } else { $headers[$name] = @($value) }
    }
    return [pscustomobject]@{ StatusCode = $statusCode; Headers = $headers }
}

function Invoke-OfficialPackageCurlRequest {
    param([Parameter(Mandatory)][Uri]$Uri, [ValidateSet('Head','Get')][string]$Method, [int]$TimeoutSec, [string]$OutFile)
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl -PathType Leaf)) { throw "The Windows HTTPS-proxy transport is unavailable: $curl" }
    $headerPath = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-msix-headers-' + [guid]::NewGuid().ToString('N') + '.txt')
    $discardPath = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-msix-discard-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $outputPath = if ($Method -eq 'Get') { $OutFile } else { $discardPath }
        $arguments = @('--disable','--silent','--show-error','--ssl-revoke-best-effort','--max-redirs','0','--connect-timeout',[string]([Math]::Min(20, $TimeoutSec)),'--proto','=https','--proto-redir','=https','--proxy',$script:DesktopUpdateProxyServer,'--noproxy','localhost,127.0.0.1,::1','--dump-header',$headerPath,'--output',$outputPath)
        if ($Method -eq 'Get') {
            $arguments += @('--speed-limit','1','--speed-time',[string]$TimeoutSec)
        } else {
            $arguments += @('--max-time',[string]$TimeoutSec)
        }
        if ($Method -eq 'Head') { $arguments += '--head' }
        $arguments += $Uri.AbsoluteUri
        $curlEnvironmentNames = @('CURL_CA_BUNDLE','SSL_CERT_FILE','SSL_CERT_DIR')
        $savedCurlEnvironment = @{}
        try {
            foreach ($name in $curlEnvironmentNames) {
                $savedCurlEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, $null, 'Process')
            }
            & $curl @arguments | Out-Null
            $curlExitCode = $LASTEXITCODE
        } finally {
            foreach ($name in $curlEnvironmentNames) { [Environment]::SetEnvironmentVariable($name, $savedCurlEnvironment[$name], 'Process') }
        }
        if ($curlExitCode -ne 0) {
            $status = switch ($curlExitCode) {
                5 { [Net.WebExceptionStatus]::ProxyNameResolutionFailure }
                6 { [Net.WebExceptionStatus]::NameResolutionFailure }
                7 { [Net.WebExceptionStatus]::ConnectFailure }
                18 { [Net.WebExceptionStatus]::ReceiveFailure }
                28 { [Net.WebExceptionStatus]::Timeout }
                52 { [Net.WebExceptionStatus]::ReceiveFailure }
                55 { [Net.WebExceptionStatus]::SendFailure }
                56 { [Net.WebExceptionStatus]::ReceiveFailure }
                default { $null }
            }
            if ($null -ne $status) { throw [Net.WebException]::new("curl package request failed with exit code $curlExitCode.", $status) }
            throw "curl package request failed with exit code $curlExitCode."
        }
        return Read-CurlResponseHeaders -Path $headerPath
    } finally {
        Remove-Item -LiteralPath $headerPath,$discardPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OfficialPackageRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Head','Get')][string]$Method,
        [int]$TimeoutSec,
        [string]$OutFile
    )
    $current = [Uri](Assert-OfficialPackageUri $Uri)
    for ($redirect = 0; $redirect -le 3; $redirect++) {
        if ($script:DesktopUpdateProxyServer -and $PSVersionTable.PSEdition -eq 'Desktop' -and ([Uri]$script:DesktopUpdateProxyServer).Scheme -eq 'https') {
            $curlResponse = Invoke-OfficialPackageCurlRequest -Uri $current -Method $Method -TimeoutSec $TimeoutSec -OutFile $OutFile
            if ($curlResponse.StatusCode -in 301,302,303,307,308) {
                $locations = @($curlResponse.Headers['Location'])
                if ($redirect -ge 3 -or $locations.Count -ne 1) { throw 'The package endpoint exceeded the safe redirect limit.' }
                $next = [Uri]::new($current, [string]$locations[0])
                $current = [Uri](Assert-OfficialPackageUri $next.AbsoluteUri)
                continue
            }
            if ($curlResponse.StatusCode -lt 200 -or $curlResponse.StatusCode -ge 300) { throw "The package endpoint returned HTTP $($curlResponse.StatusCode)." }
            return [pscustomobject]@{ Headers = $curlResponse.Headers; FinalUri = $current.AbsoluteUri }
        }
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        if ($script:DesktopUpdateProxyServer) {
            $handler.UseProxy = $true
            $handler.Proxy = [Net.WebProxy]::new($script:DesktopUpdateProxyServer, $true)
        }
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        $response = $null
        $headerCancellation = [Threading.CancellationTokenSource]::new()
        $headerCancellation.CancelAfter([TimeSpan]::FromSeconds([Math]::Min(60, $TimeoutSec)))
        try {
            $httpMethod = if ($Method -eq 'Head') { [Net.Http.HttpMethod]::Head } else { [Net.Http.HttpMethod]::Get }
            $request = [Net.Http.HttpRequestMessage]::new($httpMethod, $current)
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $headerCancellation.Token).GetAwaiter().GetResult()
                if ([int]$response.StatusCode -in 301,302,303,307,308) {
                    if ($redirect -ge 3 -or $null -eq $response.Headers.Location) { throw 'The package endpoint exceeded the safe redirect limit.' }
                    $next = if ($response.Headers.Location.IsAbsoluteUri) { $response.Headers.Location } else { [Uri]::new($current, $response.Headers.Location) }
                    $current = [Uri](Assert-OfficialPackageUri $next.AbsoluteUri)
                    continue
                }
                $response.EnsureSuccessStatusCode() | Out-Null
                $headers = @{}
                foreach ($header in $response.Headers) { $headers[$header.Key] = @($header.Value) }
                foreach ($header in $response.Content.Headers) { $headers[$header.Key] = @($header.Value) }
                if ($Method -eq 'Get') {
                    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    $output = [IO.File]::Open($OutFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try { [ChatGPTRemoteProgressStreamCopier]::CopyToWithInactivityTimeout($stream, $output, 81920, ($TimeoutSec * 1000)) } finally { $output.Dispose(); $stream.Dispose() }
                }
                return [pscustomobject]@{ Headers = $headers; FinalUri = $current.AbsoluteUri }
            } finally { $request.Dispose(); if ($response) { $response.Dispose() } }
        } finally { $headerCancellation.Dispose(); $client.Dispose(); $handler.Dispose() }
    }
    throw 'The package endpoint exceeded the safe redirect limit.'
}

function Get-CurrentUserChatGptPackages {
    [CmdletBinding()]
    param([scriptblock]$PackageEnumerator)

    $packages = if ($null -ne $PackageEnumerator) {
        @(& $PackageEnumerator)
    } else {
        Assert-Condition ($null -ne (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) 'Windows AppX package discovery is unavailable in this PowerShell session.'
        $found = [Collections.Generic.List[object]]::new()
        foreach ($name in $script:ChatGptPackageNames) {
            # Omitting -AllUsers is intentional: this is the signed-in user's
            # package state, never provisioning or machine-wide state.
            foreach ($package in @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)) {
                [void]$found.Add($package)
            }
        }
        @($found)
    }

    return @($packages | Where-Object {
        $name = [string](Get-PropertyValue $_ 'Name')
        $name -in $script:ChatGptPackageNames
    })
}

function ConvertTo-PackageSummary {
    param([object]$Package)
    if ($null -eq $Package) { return $null }
    [pscustomobject][ordered]@{
        Name = [string](Get-PropertyValue $Package 'Name')
        Version = [string](Get-PropertyValue $Package 'Version')
        Architecture = [string](Get-PropertyValue $Package 'Architecture')
        Publisher = [string](Get-PropertyValue $Package 'Publisher')
        SignatureKind = [string](Get-PropertyValue $Package 'SignatureKind')
        Status = [string](Get-PropertyValue $Package 'Status')
        PackageFullName = [string](Get-PropertyValue $Package 'PackageFullName')
        InstallLocation = [string](Get-PropertyValue $Package 'InstallLocation')
    }
}

function Get-InstalledChatGptPackageState {
    [CmdletBinding()]
    param([scriptblock]$PackageEnumerator)

    $packages = @(Get-CurrentUserChatGptPackages -PackageEnumerator $PackageEnumerator)
    if ($packages.Count -eq 0) {
        return [pscustomobject][ordered]@{
            State = 'NotInstalled'
            Package = $null
            Summary = $null
            Identity = $null
            Version = $null
        }
    }
    if ($packages.Count -ne 1) {
        $identities = @($packages | ForEach-Object { [string](Get-PropertyValue $_ 'Name') } | Sort-Object -Unique) -join ', '
        throw "Ambiguous current-user ChatGPT package state: found $($packages.Count) packages ($identities). Refusing to choose an update target."
    }

    $package = $packages[0]
    $identity = [string](Get-PropertyValue $package 'Name')
    $publisher = [string](Get-PropertyValue $package 'Publisher')
    $architecture = [string](Get-PropertyValue $package 'Architecture')
    Assert-Condition ($identity -in $script:ChatGptPackageNames) "Unexpected ChatGPT package identity: $identity"
    Assert-Condition ($publisher -ceq $script:ExpectedPublisher) "Installed ChatGPT package publisher is not the expected OpenAI publisher: $identity"
    Assert-Condition ($architecture -ieq $script:ExpectedArchitecture) "Installed ChatGPT package architecture is not x64: $architecture"
    $signatureKind = [string](Get-PropertyValue $package 'SignatureKind')
    if ($signatureKind) {
        Assert-Condition ($signatureKind -ieq 'Store') "Installed ChatGPT package is not Store-signed: $signatureKind"
    }
    $status = [string](Get-PropertyValue $package 'Status')
    if ($status) {
        Assert-Condition ($status -ieq 'Ok') "Installed ChatGPT package is not healthy: $status"
    }
    $version = ConvertTo-Version (Get-PropertyValue $package 'Version') 'Installed package version'
    return [pscustomobject][ordered]@{
        State = 'Installed'
        Package = $package
        Summary = ConvertTo-PackageSummary $package
        Identity = $identity
        Version = $version
    }
}

function Get-DesktopUpdateDeferredStatePath {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($localAppData)) 'LocalApplicationData is unavailable for deferred desktop-update state.'
    return Join-Path $localAppData 'ChatGPTRemoteEnabler\desktop-update-deferred.json'
}

function Remove-DesktopUpdateDeferredState {
    param([Parameter(Mandatory)][string]$Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Read-DesktopUpdateDeferredState {
    param([Parameter(Mandatory)][string]$Path, [switch]$PreserveInvalidState)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = $null
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        # A sharing violation or transient profile-storage failure is not
        # evidence that a previously verified deferral record is corrupt.
        return $null
    }
    try {
        $state = $text | ConvertFrom-Json -ErrorAction Stop
        if ([int]$state.schemaVersion -ne 1) { throw 'Unsupported schema.' }
        return $state
    } catch {
        if (-not $PreserveInvalidState) { Remove-DesktopUpdateDeferredState -Path $Path }
        return $null
    }
}

function Test-StrongDesktopUpdateValidator {
    param([AllowEmptyString()][string]$ETag)
    if ([string]::IsNullOrWhiteSpace($ETag)) { return $false }
    return -not $ETag.TrimStart().StartsWith('W/', [StringComparison]::OrdinalIgnoreCase)
}

function Write-DesktopUpdateDeferredState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Installed,
        [Parameter(Mandatory)][object]$Remote,
        [Parameter(Mandatory)][object]$Manifest
    )
    Assert-Condition (Test-StrongDesktopUpdateValidator -ETag ([string]$Remote.ETag)) 'The remote package did not provide a strong ETag, so its automatic update deferral cannot be cached safely.'
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.desktop-update-deferred-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $state = [ordered]@{
        schemaVersion = 1
        recordedAtFileTimeUtc = [DateTime]::UtcNow.ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        installed = [ordered]@{ name = [string]$Installed.Name; version = [string]$Installed.Version; packageFullName = [string]$Installed.PackageFullName; installLocation = [string]$Installed.InstallLocation }
        remote = [ordered]@{ uri = [string]$Remote.Uri; name = [string]$Remote.Name; version = [string]$Remote.VersionText; architecture = [string]$Remote.Architecture; contentLength = [string]$Remote.ContentLength; etag = [string]$Remote.ETag }
        manifest = [ordered]@{ name = [string]$Manifest.Name; version = [string]$Manifest.VersionText; architecture = [string]$Manifest.Architecture; publisher = [string]$Manifest.Publisher }
    }
    try {
        [IO.File]::WriteAllText($temporary, (($state | ConvertTo-Json -Depth 5) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-MatchingDesktopUpdateDeferredState {
    param([string]$Path, [object]$Installed, [object]$Remote, [switch]$PreserveInvalidState)
    $state = Read-DesktopUpdateDeferredState -Path $Path -PreserveInvalidState:$PreserveInvalidState
    if ($null -eq $state) { return $null }
    # A proxy can transiently strip or weaken the live validator. That makes
    # this launch unable to trust the cache, but it is not proof that the
    # previously verified candidate changed, so preserve the record for a
    # later response that can confirm or invalidate it.
    if (-not (Test-StrongDesktopUpdateValidator -ETag ([string]$Remote.ETag))) { return $null }
    try {
        $recordedAt = [DateTime]::FromFileTimeUtc([long]::Parse([string]$state.recordedAtFileTimeUtc, [Globalization.CultureInfo]::InvariantCulture))
        $now = [DateTime]::UtcNow
        $recordAge = $now - $recordedAt
        $isMatch = $recordAge -ge [TimeSpan]::Zero -and
            $recordAge -le [TimeSpan]::FromHours(24) -and
            (Test-StrongDesktopUpdateValidator -ETag ([string]$state.remote.etag)) -and
            $Installed.State -ceq 'Installed' -and
            [string]$state.installed.name -ceq [string]$Installed.Summary.Name -and
            [string]$state.installed.version -ceq [string]$Installed.Summary.Version -and
            -not [string]::IsNullOrWhiteSpace([string]$state.installed.packageFullName) -and
            [string]$state.installed.packageFullName -ceq [string]$Installed.Summary.PackageFullName -and
            -not [string]::IsNullOrWhiteSpace([string]$state.installed.installLocation) -and
            [string]$state.installed.installLocation -ceq [string]$Installed.Summary.InstallLocation -and
            [string]$Installed.Summary.SignatureKind -ieq 'Store' -and
            [string]$Installed.Summary.Status -ieq 'Ok' -and
            [string]$state.remote.uri -ceq [string]$Remote.Uri -and
            [string]$state.remote.name -ceq [string]$Remote.Name -and
            [string]$state.remote.version -ceq [string]$Remote.VersionText -and
            [string]$state.remote.architecture -ieq [string]$Remote.Architecture -and
            [string]$state.remote.contentLength -ceq [string]$Remote.ContentLength -and
            [string]$state.remote.etag -ceq [string]$Remote.ETag -and
            [string]$state.manifest.name -ceq [string]$Remote.Name -and
            [string]$state.manifest.version -ceq [string]$Remote.VersionText -and
            [string]$state.manifest.architecture -ieq [string]$Remote.Architecture -and
            [string]$state.manifest.publisher -ceq $script:ExpectedPublisher
    } catch { $isMatch = $false }
    if (-not $isMatch) {
        if (-not $PreserveInvalidState) { Remove-DesktopUpdateDeferredState -Path $Path }
        return $null
    }
    return [pscustomobject][ordered]@{
        Name = [string]$state.manifest.name
        Publisher = [string]$state.manifest.publisher
        Architecture = [string]$state.manifest.architecture
        Version = [version]([string]$state.manifest.version)
        VersionText = [string]$state.manifest.version
    }
}

function Get-ChatGptProcesses {
    [CmdletBinding()]
    param([scriptblock]$ProcessEnumerator)
    if ($null -ne $ProcessEnumerator) { return @(& $ProcessEnumerator) }
    return @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue)
}

function Assert-ChatGptNotRunning {
    param([scriptblock]$ProcessEnumerator)
    $processes = @(Get-ChatGptProcesses -ProcessEnumerator $ProcessEnumerator)
    if ($processes.Count -gt 0) {
        throw 'ChatGPT.exe is running. Finish active work and close it, then retry. This updater will not stop or kill the app.'
    }
}

function Read-MsixPackageManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) "MSIX package was not found: $Path"
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { throw 'Windows ZIP/MSIX support is unavailable in this PowerShell session.' }
    $archive = $null
    $reader = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
        $entries = @($archive.Entries | Where-Object {
            ([string]$_.FullName).Replace('/', '\') -ieq 'AppxManifest.xml'
        })
        Assert-Condition ($entries.Count -eq 1) 'MSIX package must contain exactly one root AppxManifest.xml.'
        $reader = New-Object IO.StreamReader($entries[0].Open(), [Text.Encoding]::UTF8, $true)
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $xml = New-Object Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load([Xml.XmlReader]::Create($reader, $settings))
        $identityNode = $xml.SelectSingleNode("/*[local-name()='Package']/*[local-name()='Identity']")
        Assert-Condition ($null -ne $identityNode) 'MSIX AppxManifest.xml does not contain a package Identity.'
        $name = [string]$identityNode.GetAttribute('Name')
        $publisher = [string]$identityNode.GetAttribute('Publisher')
        $architecture = [string]$identityNode.GetAttribute('ProcessorArchitecture')
        $version = ConvertTo-Version ([string]$identityNode.GetAttribute('Version')) 'MSIX manifest version'
        Assert-Condition ($name -in $script:ChatGptPackageNames) "MSIX package identity is not an expected OpenAI identity: $name"
        Assert-Condition ($publisher -ceq $script:ExpectedPublisher) "MSIX package publisher is not the expected OpenAI publisher: $name"
        Assert-Condition ($architecture -ieq $script:ExpectedArchitecture) "MSIX package architecture is not x64: $architecture"
        [pscustomobject][ordered]@{
            Name = $name
            Publisher = $publisher
            Architecture = $architecture
            Version = $version
            VersionText = $version.ToString()
        }
    } catch {
        if ($_.Exception.Message -like 'MSIX package identity*' -or $_.Exception.Message -like 'MSIX package publisher*' -or $_.Exception.Message -like 'MSIX package architecture*' -or $_.Exception.Message -like 'MSIX manifest version*') { throw }
        throw "MSIX manifest inspection failed: $($_.Exception.Message)"
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Test-MsixAuthenticodeSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [scriptblock]$SignatureReader)
    $signature = if ($null -ne $SignatureReader) {
        & $SignatureReader $Path
    } else {
        Assert-Condition ($null -ne (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) 'Windows Authenticode verification is unavailable in this PowerShell session.'
        Get-AuthenticodeSignature -LiteralPath $Path
    }
    $status = [string](Get-PropertyValue $signature 'Status')
    Assert-Condition ($status -ieq 'Valid') "MSIX Authenticode signature is not valid (status: $status)."
    Assert-Condition ($null -ne (Get-PropertyValue $signature 'SignerCertificate')) 'MSIX Authenticode signature has no signer certificate.'
    [pscustomobject][ordered]@{ Status = $status; Verified = $true }
}

function Test-MsixPackageSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$SignatureReader
    )
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { throw 'Windows ZIP/MSIX support is unavailable in this PowerShell session.' }
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
        $signatureEntries = @($archive.Entries | Where-Object {
            ([string]$_.FullName).Replace('/', '\') -ieq 'AppxSignature.p7x'
        })
        Assert-Condition ($signatureEntries.Count -eq 1) 'MSIX package must contain exactly one root AppxSignature.p7x package signature.'
        Assert-Condition ($signatureEntries[0].Length -gt 4) 'MSIX package signature envelope is empty.'
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
    # Get-AuthenticodeSignature is the Windows-native certificate-chain check.
    # Add-AppxPackage performs the package block-map/AppxSignature validation
    # again when it installs; no unsigned or bypassed package is accepted here.
    return Test-MsixAuthenticodeSignature -Path $Path -SignatureReader $SignatureReader
}

function Compare-MsixUpdateTarget {
    param([object]$InstalledState, [object]$Manifest)
    if ($InstalledState.State -eq 'NotInstalled') {
        return [pscustomobject][ordered]@{ Decision = 'FreshInstall'; CanInstall = $true; Message = 'No expected ChatGPT package is installed for this user; a fresh current-user install is eligible subject to Windows policy and license requirements.' }
    }
    Assert-Condition ($InstalledState.Identity -ceq [string]$Manifest.Name) "Downloaded package identity $($Manifest.Name) does not match installed package identity $($InstalledState.Identity); refusing side-by-side migration."
    $installedVersion = [version]$InstalledState.Version
    $remoteVersion = [version]$Manifest.Version
    if ($remoteVersion -gt $installedVersion) {
        return [pscustomobject][ordered]@{ Decision = 'UpdateAvailable'; CanInstall = $true; Message = "Downloaded package $remoteVersion is newer than installed $installedVersion." }
    }
    if ($remoteVersion -eq $installedVersion) {
        return [pscustomobject][ordered]@{ Decision = 'EqualVersion'; CanInstall = $false; Message = "Downloaded package $remoteVersion equals installed $installedVersion; refusing a reinstall." }
    }
    return [pscustomobject][ordered]@{ Decision = 'DowngradeRefused'; CanInstall = $false; Message = "Downloaded package $remoteVersion is older than installed $installedVersion; refusing a downgrade." }
}

function Test-TransientPackageMetadataFailure {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [OperationCanceledException] -or $exception -is [TimeoutException]) { return $true }
        $response = Get-PropertyValue $exception 'Response'
        $statusCode = Get-PropertyValue $response 'StatusCode'
        if ($null -ne $statusCode) {
            try {
                if ([int]$statusCode -in @(408, 429, 500, 502, 503, 504)) { return $true }
            } catch {}
        }
        if ($exception -is [Net.WebException]) {
            if ($exception.Status -in @(
                [Net.WebExceptionStatus]::Timeout,
                [Net.WebExceptionStatus]::ConnectFailure,
                [Net.WebExceptionStatus]::ConnectionClosed,
                [Net.WebExceptionStatus]::KeepAliveFailure,
                [Net.WebExceptionStatus]::ReceiveFailure,
                [Net.WebExceptionStatus]::SendFailure,
                [Net.WebExceptionStatus]::NameResolutionFailure,
                [Net.WebExceptionStatus]::ProxyNameResolutionFailure
            )) { return $true }
        }
        $exception = $exception.InnerException
    }
    return ([string]$ErrorRecord -match '(?i)\b(408|429|500|502|503|504)\b|timed?\s*out|connection\s+(?:was\s+)?closed')
}

function Get-HeadPackageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [scriptblock]$HeadRequester,
        [ValidateRange(1, 5)][int]$MaximumAttempts = 3,
        [ValidateRange(0, 30)][int]$RetryDelaySeconds = 2,
        [scriptblock]$Sleeper
    )
    $officialUri = Assert-OfficialPackageUri $Uri
    $response = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $response = if ($null -ne $HeadRequester) {
                & $HeadRequester $officialUri
            } else {
                $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
                try {
                    [Net.ServicePointManager]::SecurityProtocol = $originalProtocol -bor [Net.SecurityProtocolType]::Tls12
                    Invoke-OfficialPackageRequest -Uri $officialUri -Method Head -TimeoutSec 60
                } finally {
                    [Net.ServicePointManager]::SecurityProtocol = $originalProtocol
                }
            }
            break
        } catch {
            if ($attempt -ge $MaximumAttempts -or -not (Test-TransientPackageMetadataFailure -ErrorRecord $_)) { throw }
            $delay = $RetryDelaySeconds * $attempt
            if ($null -ne $Sleeper) { & $Sleeper $delay } elseif ($delay -gt 0) { Start-Sleep -Seconds $delay }
        }
    }
    $headers = Get-PropertyValue $response 'Headers'
    $getHeader = {
        param([string]$Name)
        if ($null -eq $headers) { return $null }
        $value = $headers[$Name]
        if ($value -is [Array]) { return [string]($value -join ',') }
        return [string]$value
    }
    $identity = & $getHeader 'x-ms-meta-package_identity'
    $versionText = & $getHeader 'x-ms-meta-package_version'
    $architecture = & $getHeader 'x-ms-meta-architecture'
    Assert-Condition ($identity -in $script:ChatGptPackageNames) "Official endpoint metadata has an unexpected package identity: $identity"
    $version = ConvertTo-Version $versionText 'Official endpoint package version'
    Assert-Condition ($architecture -ieq $script:ExpectedArchitecture) "Official endpoint metadata is not x64: $architecture"
    [pscustomobject][ordered]@{
        Uri = $officialUri
        Name = $identity
        Version = $version
        VersionText = $version.ToString()
        Architecture = $architecture
        ContentLength = [string](& $getHeader 'Content-Length')
        ETag = [string](& $getHeader 'ETag')
    }
}

function Get-PerUserMsixTempRoot {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($localAppData)) 'The current user LocalAppData folder is unavailable.'
    $root = Join-Path $localAppData 'Temp\ChatGPTRemoteEnabler\msix-updater'
    $directory = Join-Path $root ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    return [IO.Path]::GetFullPath($directory)
}

function Save-MsixToPerUserTemp {
    param([string]$Uri, [string]$PackagePath, [string]$DestinationRoot)
    $destination = Join-Path $DestinationRoot 'ChatGPT-x64.msix'
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $source = [IO.Path]::GetFullPath($PackagePath)
        Assert-Condition (Test-Path -LiteralPath $source -PathType Leaf) "The supplied MSIX package was not found: $source"
        [IO.File]::Copy($source, $destination, $true)
        return $destination
    }
    $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $originalProtocol -bor [Net.SecurityProtocolType]::Tls12
        [void](Invoke-OfficialPackageRequest -Uri $Uri -Method Get -TimeoutSec 900 -OutFile $destination)
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalProtocol
    }
    Assert-Condition (Test-Path -LiteralPath $destination -PathType Leaf) 'The MSIX download did not produce a package file.'
    return $destination
}

function Remove-MsixTempRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return }
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $localAppData = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')
    $ownedPrefix = $localAppData + '\Temp\ChatGPTRemoteEnabler\msix-updater\'
    if (-not $fullRoot.StartsWith($ownedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to clean a package path outside the updater-owned per-user temp directory.' }
    if ([IO.Directory]::Exists($fullRoot)) {
        try { [IO.Directory]::Delete($fullRoot, $true) } catch { Remove-Item -LiteralPath $fullRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-ChatGPTDesktopMsixUpdater {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [ValidateSet('Probe', 'Check', 'Update')][string]$Action,
        [string]$PackageUri,
        [string]$PackagePath,
        [scriptblock]$PackageEnumerator,
        [scriptblock]$ProcessEnumerator,
        [scriptblock]$HeadRequester,
        [scriptblock]$SignatureReader,
        [scriptblock]$Installer,
        [string]$DeferredStatePath,
        [ValidateRange(1, 5)][int]$MetadataMaximumAttempts = 3,
        [ValidateRange(0, 30)][int]$MetadataRetryDelaySeconds = 2,
        [scriptblock]$MetadataSleeper
    )

    Assert-Condition ($Action -in @('Probe', 'Check', 'Update')) "Unsupported action: $Action"
    $installed = Get-InstalledChatGptPackageState -PackageEnumerator $PackageEnumerator
    if ($Action -eq 'Probe') {
        $running = @(Get-ChatGptProcesses -ProcessEnumerator $ProcessEnumerator).Count -gt 0
        return [pscustomobject][ordered]@{
            Action = $Action
            InstalledState = $installed.State
            Installed = $installed.Summary
            ChatGPTRunning = $running
            PackageUri = (Assert-OfficialPackageUri $PackageUri)
            PackageIdentities = $script:ChatGptPackageNames
            ExpectedPublisher = $script:ExpectedPublisher
            ExpectedArchitecture = $script:ExpectedArchitecture
            InstallScope = 'CurrentUser'
            Installer = 'Add-AppxPackage -Path (no -AllUsers, no provisioning, no force shutdown)'
            AutomaticBaseAppUpdates = $true
            AutomaticUpdateEntryPoints = @('ChatGPT Remote Enabler shortcut', 'Device Projects sign-in startup')
        }
    }
    if ([string]::IsNullOrWhiteSpace($DeferredStatePath)) {
        if ($Action -eq 'Update') {
            $DeferredStatePath = Get-DesktopUpdateDeferredStatePath
        } else {
            try { $DeferredStatePath = Get-DesktopUpdateDeferredStatePath } catch { $DeferredStatePath = $null }
        }
    }

    try {
        $remote = Get-HeadPackageMetadata -Uri $PackageUri -HeadRequester $HeadRequester -MaximumAttempts $MetadataMaximumAttempts -RetryDelaySeconds $MetadataRetryDelaySeconds -Sleeper $MetadataSleeper
    } catch {
        if ($Action -eq 'Update' -and $installed.State -eq 'Installed' -and
            [string]$installed.Summary.SignatureKind -ieq 'Store' -and [string]$installed.Summary.Status -ieq 'Ok' -and
            (Test-TransientPackageMetadataFailure -ErrorRecord $_)) {
            return [pscustomobject][ordered]@{
                Action = $Action
                InstalledState = $installed.State
                Installed = $installed.Summary
                Remote = $null
                Decision = 'RemoteUnavailableCurrentInstalled'
                CanInstall = $false
                TransientFailure = $true
                Message = 'The official update endpoint is temporarily unavailable. Launching the verified current-user installation without changing it.'
            }
        }
        throw
    }
    if ($installed.State -eq 'Installed' -and $installed.Identity -cne $remote.Name) {
        if ($Action -eq 'Update' -and -not $WhatIfPreference) { Remove-DesktopUpdateDeferredState -Path $DeferredStatePath }
        return [pscustomobject][ordered]@{
            Action = $Action; InstalledState = $installed.State; Installed = $installed.Summary; Remote = $remote
            Decision = 'IdentityMismatch'; CanInstall = $false
            Message = "Official endpoint publishes $($remote.Name), but this user has $($installed.Identity). Refusing a side-by-side install or identity migration."
        }
    }
    if ($Action -eq 'Check') {
        $deferredManifest = if ([string]::IsNullOrWhiteSpace($PackagePath) -and -not [string]::IsNullOrWhiteSpace($DeferredStatePath)) {
            Get-MatchingDesktopUpdateDeferredState -Path $DeferredStatePath -Installed $installed -Remote $remote -PreserveInvalidState
        } else { $null }
        if ($null -ne $deferredManifest) {
            return [pscustomobject][ordered]@{
                Action = $Action; InstalledState = $installed.State; Installed = $installed.Summary; Remote = $remote; Manifest = $deferredManifest
                Decision = 'UpdateDeferredCurrentInstalled'; CanInstall = $false; InstallDeferred = $true; DeferredFromCache = $true
                Message = 'Windows previously rejected this exact verified desktop update in the current-user context. The automatic updater will retry after the bounded deferral expires.'
            }
        }
        $decision = if ($installed.State -eq 'NotInstalled') {
            [pscustomobject][ordered]@{ Decision = 'FreshInstall'; CanInstall = $true; Message = 'No expected ChatGPT package is installed for this user; the official package can be installed if policy and licensing allow it.' }
        } elseif ($remote.Version -gt $installed.Version) {
            [pscustomobject][ordered]@{ Decision = 'UpdateAvailable'; CanInstall = $true; Message = "Official package $($remote.Version) is newer than installed $($installed.Version)." }
        } elseif ($remote.Version -eq $installed.Version) {
            [pscustomobject][ordered]@{ Decision = 'Current'; CanInstall = $false; Message = "Installed package $($installed.Version) matches the official endpoint." }
        } else {
            [pscustomobject][ordered]@{ Decision = 'DowngradeRefused'; CanInstall = $false; Message = "Official package $($remote.Version) is older than installed $($installed.Version); no mutation will be attempted." }
        }
        return [pscustomobject][ordered]@{ Action = $Action; InstalledState = $installed.State; Installed = $installed.Summary; Remote = $remote; Decision = $decision.Decision; CanInstall = $decision.CanInstall; Message = $decision.Message }
    }

    Assert-Condition (-not [string]::IsNullOrWhiteSpace($PackagePath) -or $remote.Name -in $script:ChatGptPackageNames) 'The official package metadata is not an expected OpenAI identity.'
    if ($installed.State -eq 'Installed' -and $remote.Version -le $installed.Version) {
        if (-not $WhatIfPreference) { Remove-DesktopUpdateDeferredState -Path $DeferredStatePath }
        $decision = if ($remote.Version -eq $installed.Version) { 'EqualVersion' } else { 'DowngradeRefused' }
        return [pscustomobject][ordered]@{ Action = $Action; InstalledState = $installed.State; Installed = $installed.Summary; Remote = $remote; Decision = $decision; CanInstall = $false; Message = "Package $($remote.Version) is not newer than installed $($installed.Version); refusing mutation." }
    }

    # The deferral cache only applies to the automatic endpoint candidate. An
    # explicit package path is a caller-selected candidate and must always be
    # opened, verified, and attempted (or rejected) on its own merits.
    $deferredManifest = if ([string]::IsNullOrWhiteSpace($PackagePath) -and -not $WhatIfPreference) {
        Get-MatchingDesktopUpdateDeferredState -Path $DeferredStatePath -Installed $installed -Remote $remote
    } else { $null }
    if ($null -ne $deferredManifest) {
        return [pscustomobject][ordered]@{
            Action = $Action
            InstalledState = $installed.State
            Installed = $installed.Summary
            Remote = $remote
            Manifest = $deferredManifest
            Decision = 'UpdateDeferredCurrentInstalled'
            CanInstall = $false
            InstallDeferred = $true
            DeferredFromCache = $true
            Message = 'Windows previously rejected this exact verified desktop update in the current-user context. Launching the unchanged healthy Store installation without downloading the same package again.'
        }
    }

    # Do not spend time downloading a candidate while the base app is open.
    # Repeat the check immediately before Add-AppxPackage to close the race.
    Assert-ChatGptNotRunning -ProcessEnumerator $ProcessEnumerator

    $tempRoot = $null
    try {
        $tempRoot = Get-PerUserMsixTempRoot
        $localPackage = Save-MsixToPerUserTemp -Uri $PackageUri -PackagePath $PackagePath -DestinationRoot $tempRoot
        $manifest = Read-MsixPackageManifest -Path $localPackage
        Assert-Condition ($manifest.Name -ceq $remote.Name) 'Downloaded MSIX manifest identity disagrees with official endpoint metadata.'
        Assert-Condition ($manifest.Version -eq $remote.Version) 'Downloaded MSIX manifest version disagrees with official endpoint metadata.'
        Assert-Condition ($manifest.Architecture -ieq $remote.Architecture) 'Downloaded MSIX manifest architecture disagrees with official endpoint metadata.'
        [void](Test-MsixPackageSignature -Path $localPackage -SignatureReader $SignatureReader)
        $decision = Compare-MsixUpdateTarget -InstalledState $installed -Manifest $manifest
        if (-not $decision.CanInstall) {
            return [pscustomobject][ordered]@{ Action = $Action; InstalledState = $installed.State; Installed = $installed.Summary; Remote = $remote; Manifest = $manifest; Decision = $decision.Decision; CanInstall = $false; Message = $decision.Message }
        }
        Assert-ChatGptNotRunning -ProcessEnumerator $ProcessEnumerator
        $targetDescription = "$($manifest.Name) $($manifest.Version) for current user"
        $shouldInstall = $PSCmdlet.ShouldProcess($targetDescription, 'Install verified MSIX with Add-AppxPackage')
        if (-not $shouldInstall) {
            return [pscustomobject][ordered]@{ Action = $Action; InstalledState = $installed.State; Installed = $installed.Summary; Remote = $remote; Manifest = $manifest; Decision = 'WhatIf'; CanInstall = $true; Message = 'WhatIf: verified package would be installed for the current user; no Add-AppxPackage call was made.' }
        }
        if ($null -eq $Installer) {
            Assert-Condition ($null -ne (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) 'Add-AppxPackage is unavailable. No alternative installer or policy bypass was attempted.'
        }
        try {
            if ($null -ne $Installer) {
                & $Installer $localPackage
            } else {
                # Current-user install/update only. Do not add -AllUsers,
                # -Register, -ForceApplicationShutdown, or provisioning.
                Add-AppxPackage -Path $localPackage -ErrorAction Stop
            }
        } catch {
            $installError = $_
            if (-not (Test-CurrentUserAppxInstallBlocked -ErrorRecord $installError)) {
                throw "MSIX current-user installation failed; Windows or corporate AppX policy may have blocked it. No policy bypass was attempted. $($installError.Exception.Message)"
            }
            $afterFailure = $null
            try { $afterFailure = Get-InstalledChatGptPackageState -PackageEnumerator $PackageEnumerator } catch {}
            $unchangedHealthyInstall = $installed.State -ceq 'Installed' -and $null -ne $afterFailure -and $afterFailure.State -ceq 'Installed' -and
                $afterFailure.Identity -ceq $installed.Identity -and $afterFailure.Version -eq $installed.Version -and
                -not [string]::IsNullOrWhiteSpace([string]$installed.Summary.PackageFullName) -and
                [string]$afterFailure.Summary.PackageFullName -ceq [string]$installed.Summary.PackageFullName -and
                -not [string]::IsNullOrWhiteSpace([string]$installed.Summary.InstallLocation) -and
                [string]$afterFailure.Summary.InstallLocation -ceq [string]$installed.Summary.InstallLocation -and
                [string]$afterFailure.Summary.Publisher -ceq $script:ExpectedPublisher -and
                [string]$afterFailure.Summary.Architecture -ieq $script:ExpectedArchitecture -and
                [string]$afterFailure.Summary.SignatureKind -ieq 'Store' -and
                [string]$afterFailure.Summary.Status -ieq 'Ok'
            if ($unchangedHealthyInstall) {
                $deferralCached = $false
                $deferralCacheReason = $null
                if ([string]::IsNullOrWhiteSpace($PackagePath)) {
                    try {
                        Write-DesktopUpdateDeferredState -Path $DeferredStatePath -Installed $afterFailure.Summary -Remote $remote -Manifest $manifest
                        $deferralCached = $true
                    } catch {
                        $deferralCacheReason = $_.Exception.Message
                    }
                }
                return [pscustomobject][ordered]@{
                    Action = $Action
                    InstalledState = $afterFailure.State
                    Installed = $afterFailure.Summary
                    Remote = $remote
                    Manifest = $manifest
                    Decision = 'UpdateDeferredCurrentInstalled'
                    CanInstall = $false
                    InstallDeferred = $true
                    DeferredFromCache = $false
                    DeferralCached = $deferralCached
                    DeferralCacheReason = $deferralCacheReason
                    Message = 'Windows did not allow the verified desktop update in the current-user context. Launching the unchanged healthy Store installation; Windows or the Store can apply the desktop update later.'
                }
            }
            throw "MSIX current-user installation failed; Windows or corporate AppX policy may have blocked it. No policy bypass was attempted. $($installError.Exception.Message)"
        }
        $after = Get-InstalledChatGptPackageState -PackageEnumerator $PackageEnumerator
        Assert-Condition ($after.State -eq 'Installed') 'Add-AppxPackage returned without a current-user ChatGPT package being registered.'
        Assert-Condition ($after.Identity -ceq $manifest.Name -and $after.Version -eq $manifest.Version) 'Installed current-user ChatGPT package does not match the verified MSIX identity and version.'
        Remove-DesktopUpdateDeferredState -Path $DeferredStatePath
        return [pscustomobject][ordered]@{ Action = $Action; InstalledState = $after.State; Installed = $after.Summary; Remote = $remote; Manifest = $manifest; Decision = 'Installed'; CanInstall = $true; Message = 'Verified package installed for the current user.' }
    } finally {
        if ($null -ne $tempRoot) { Remove-MsixTempRoot -Root $tempRoot }
    }
}

if ($NoExecute) { return }

try {
    $result = Invoke-ChatGPTDesktopMsixUpdater -Action $Action -PackageUri $PackageUri -PackagePath $PackagePath -WhatIf:$WhatIfPreference
    $result | ConvertTo-Json -Depth 8
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
