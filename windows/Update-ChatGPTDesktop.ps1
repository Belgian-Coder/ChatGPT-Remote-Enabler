[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateSet('Probe', 'Check', 'Update')]
    [string]$Action = 'Probe',
    [string]$PackageUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix',
    [string]$PackagePath,
    [switch]$NoExecute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# These are package identities, not file extensions. The direct OpenAI package
# currently uses OpenAI.Codex; older Store/AppX installations used the legacy
# OpenAI.ChatGPT-Desktop identity. A package may only be updated in-place when
# the downloaded identity matches the installed identity.
$script:ChatGptPackageNames = @('OpenAI.Codex', 'OpenAI.ChatGPT-Desktop')
$script:ExpectedPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$script:ExpectedArchitecture = 'X64'
$script:DefaultPackageUri = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix'

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

function Get-HeadPackageMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [scriptblock]$HeadRequester)
    $officialUri = Assert-OfficialPackageUri $Uri
    $response = if ($null -ne $HeadRequester) {
        & $HeadRequester $officialUri
    } else {
        $originalProtocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $originalProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $officialUri -Method Head -UseBasicParsing -MaximumRedirection 3 -TimeoutSec 60
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $originalProtocol
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
        Invoke-WebRequest -Uri (Assert-OfficialPackageUri $Uri) -OutFile $destination -UseBasicParsing -MaximumRedirection 3 -TimeoutSec 900
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
        [scriptblock]$Installer
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
            AutomaticBaseAppUpdates = $false
        }
    }

    $remote = Get-HeadPackageMetadata -Uri $PackageUri -HeadRequester $HeadRequester
    if ($installed.State -eq 'Installed' -and $installed.Identity -cne $remote.Name) {
        return [pscustomobject][ordered]@{
            Action = $Action; InstalledState = $installed.State; Installed = $installed.Summary; Remote = $remote
            Decision = 'IdentityMismatch'; CanInstall = $false
            Message = "Official endpoint publishes $($remote.Name), but this user has $($installed.Identity). Refusing a side-by-side install or identity migration."
        }
    }
    if ($Action -eq 'Check') {
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
        $decision = if ($remote.Version -eq $installed.Version) { 'EqualVersion' } else { 'DowngradeRefused' }
        return [pscustomobject][ordered]@{ Action = $Action; InstalledState = $installed.State; Installed = $installed.Summary; Remote = $remote; Decision = $decision; CanInstall = $false; Message = "Package $($remote.Version) is not newer than installed $($installed.Version); refusing mutation." }
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
        if ($null -ne $Installer) {
            & $Installer $localPackage
        } else {
            Assert-Condition ($null -ne (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) 'Add-AppxPackage is unavailable. No alternative installer or policy bypass was attempted.'
            try {
                # Current-user install/update only. Do not add -AllUsers,
                # -Register, -ForceApplicationShutdown, or provisioning.
                Add-AppxPackage -Path $localPackage -ErrorAction Stop
            } catch {
                throw "MSIX current-user installation failed; Windows or corporate AppX policy may have blocked it. No policy bypass was attempted. $($_.Exception.Message)"
            }
        }
        $after = Get-InstalledChatGptPackageState -PackageEnumerator $PackageEnumerator
        Assert-Condition ($after.State -eq 'Installed') 'Add-AppxPackage returned without a current-user ChatGPT package being registered.'
        Assert-Condition ($after.Identity -ceq $manifest.Name -and $after.Version -eq $manifest.Version) 'Installed current-user ChatGPT package does not match the verified MSIX identity and version.'
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
