[CmdletBinding()]
param(
    [string]$ArchivePath = (Join-Path (Get-Location) ("outputs\ChatGPT-Remote-Enabler-Windows-x64-$((Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\windows\VERSION') -Raw).Trim()).zip")),
    [string]$NodePath,
    [ValidateRange(30, 600)]
    [int]$WorkerTimeoutSeconds = 180,
    [switch]$Worker,
    [string]$JobPath,
    [string]$ResultPath,
    [string]$FixtureRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ArchivePathWasExplicit = $PSBoundParameters.ContainsKey('ArchivePath')

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-TokenEvidence {
    if (-not ('UserInstallTokenInspector' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class UserInstallTokenInspector
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SID_AND_ATTRIBUTES
    {
        public IntPtr Sid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_MANDATORY_LABEL
    {
        public SID_AND_ATTRIBUTES Label;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern IntPtr GetSidSubAuthority(IntPtr sid, uint subAuthority);

    public static int GetIntegrityRid(IntPtr tokenHandle)
    {
        int length;
        GetTokenInformation(tokenHandle, 25, IntPtr.Zero, 0, out length);
        if (length <= 0)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr buffer = Marshal.AllocHGlobal(length);
        try
        {
            if (!GetTokenInformation(tokenHandle, 25, buffer, length, out length))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            TOKEN_MANDATORY_LABEL label = (TOKEN_MANDATORY_LABEL)Marshal.PtrToStructure(
                buffer, typeof(TOKEN_MANDATORY_LABEL));
            byte count = Marshal.ReadByte(GetSidSubAuthorityCount(label.Label.Sid));
            if (count == 0) throw new InvalidOperationException("The token integrity SID is empty.");
            return Marshal.ReadInt32(GetSidSubAuthority(label.Label.Sid, (uint)(count - 1)));
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static int GetElevationType(IntPtr tokenHandle)
    {
        IntPtr buffer = Marshal.AllocHGlobal(sizeof(int));
        try
        {
            int length;
            if (!GetTokenInformation(tokenHandle, 18, buffer, sizeof(int), out length))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return Marshal.ReadInt32(buffer);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $administrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $integrityRid = [UserInstallTokenInspector]::GetIntegrityRid($identity.Token)
        $elevationValue = [UserInstallTokenInspector]::GetElevationType($identity.Token)
        $integrity = switch ($integrityRid) {
            { $_ -ge 0x00003000 } { 'High'; break }
            { $_ -ge 0x00002100 } { 'MediumPlus'; break }
            { $_ -ge 0x00002000 } { 'Medium'; break }
            { $_ -ge 0x00001000 } { 'Low'; break }
            default { 'Untrusted' }
        }
        $elevationType = switch ($elevationValue) {
            1 { 'Default' }
            2 { 'Full' }
            3 { 'Limited' }
            default { "Unknown:$elevationValue" }
        }
        [pscustomobject][ordered]@{
            User = $identity.Name
            UserSid = $identity.User.Value
            Administrator = $administrator
            Integrity = $integrity
            IntegrityRid = $integrityRid
            ElevationType = $elevationType
            SessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        }
    } finally {
        $identity.Dispose()
    }
}

function Resolve-NodePath {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = [IO.Path]::GetFullPath($RequestedPath)
    } else {
        $command = Get-Command node.exe -ErrorAction Stop
        $resolved = [IO.Path]::GetFullPath([string]$command.Source)
    }
    Assert-Condition (Test-Path -LiteralPath $resolved -PathType Leaf) "Node.js is missing: $resolved"
    $version = (& $resolved --version 2>$null | Select-Object -First 1)
    Assert-Condition ($version -match '^v(?<major>\d+)\.\d+\.\d+$' -and [int]$Matches.major -ge 22) 'Node.js 22 or newer is required.'
    return $resolved
}

function Resolve-ArchivePath {
    param([string]$RequestedPath)
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $resolved = [IO.Path]::GetFullPath($RequestedPath)
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
        if ($script:ArchivePathWasExplicit) { throw "Release archive is missing: $resolved" }
    }

    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'windows\VERSION') -Raw).Trim()
    $archiveName = "ChatGPT-Remote-Enabler-Windows-x64-$version.zip"
    $candidates = [Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path (Get-Location) "outputs\$archiveName"))
    $candidates.Add((Join-Path $repositoryRoot "outputs\$archiveName"))
    $candidates.Add((Join-Path $repositoryRoot "dist\$archiveName"))
    $taskRoot = Split-Path -Parent (Split-Path -Parent $repositoryRoot)
    $dateRoot = Split-Path -Parent $taskRoot
    if (Test-Path -LiteralPath $dateRoot -PathType Container) {
        foreach ($candidate in Get-ChildItem -LiteralPath $dateRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "outputs\$archiveName" }) {
            $candidates.Add($candidate)
        }
    }
    $matches = @($candidates | ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
    Assert-Condition ($matches.Count -gt 0) "No current $archiveName was found in an outputs or dist directory. Pass -ArchivePath."
    return [string]($matches | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending | Select-Object -First 1)
}

function Expand-SafeArchive {
    param([string]$Path, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $destinationFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $prefix = $destinationFull + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $topLevels = @($archive.Entries | ForEach-Object {
            $name = $_.FullName.Replace('\', '/')
            if ($name) { ($name -split '/')[0] }
        } | Where-Object { $_ } | Select-Object -Unique)
        Assert-Condition ($topLevels.Count -eq 1) 'The release archive must contain exactly one top-level directory.'
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
            Assert-Condition (-not [IO.Path]::IsPathRooted($entryName)) "Archive entry is rooted: $entryName"
            Assert-Condition ($entryName -notmatch '(^|/)\.\.(/|$)' -and $entryName -notmatch ':') "Archive entry escapes its root: $entryName"
            $target = [IO.Path]::GetFullPath((Join-Path $destinationFull ($entryName.Replace('/', '\'))))
            Assert-Condition ($target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) "Archive entry escapes its root: $entryName"
            if ($entryName.EndsWith('/')) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                continue
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
        return [IO.Path]::GetFullPath((Join-Path $destinationFull $topLevels[0]))
    } finally {
        $archive.Dispose()
    }
}

function Test-ReleaseManifest {
    param([string]$ReleaseRoot)
    $manifestPath = Join-Path $ReleaseRoot 'RELEASE-MANIFEST.sha256'
    Assert-Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'The extracted release manifest is missing.'
    $entries = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        Assert-Condition ($line -match '^(?<hash>[0-9a-fA-F]{64}) \*(?<path>.+)$') "Malformed release manifest line: $line"
        $relative = [string]$Matches.path
        Assert-Condition (-not [IO.Path]::IsPathRooted($relative) -and $relative -notmatch '(^|[\\/])\.\.([\\/]|$)' -and $relative -notmatch ':') "Manifest path escapes its root: $relative"
        $destination = [IO.Path]::GetFullPath((Join-Path $ReleaseRoot ($relative.Replace('/', '\'))))
        $rootPrefix = [IO.Path]::GetFullPath($ReleaseRoot).TrimEnd('\') + '\'
        Assert-Condition ($destination.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) "Manifest path escapes its root: $relative"
        Assert-Condition (-not $seen.ContainsKey($relative)) "Duplicate manifest entry: $relative"
        Assert-Condition (Test-Path -LiteralPath $destination -PathType Leaf) "Manifest file is missing: $relative"
        $actualHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        Assert-Condition ($actualHash -ieq $Matches.hash) "Manifest hash mismatch: $relative"
        $seen[$relative] = $true
        $entries.Add([pscustomobject]@{ Relative = $relative; Path = $destination })
    }
    $payloadFiles = @(Get-ChildItem -LiteralPath $ReleaseRoot -File -Recurse |
        Where-Object { $_.FullName -ine $manifestPath })
    Assert-Condition ($payloadFiles.Count -eq $entries.Count) "Manifest covers $($entries.Count) files, but the archive contains $($payloadFiles.Count) payload files."
    return @($entries)
}

function Get-PackageMainProcessIdentity {
    param([string]$ExecutablePath)
    $items = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction Stop | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        [string]::Equals([IO.Path]::GetFullPath([string]$_.ExecutablePath), $ExecutablePath, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$_.CommandLine -notmatch '(?:^|\s)--type=')
    } | Sort-Object ProcessId | ForEach-Object {
        "{0}:{1}" -f [uint32]$_.ProcessId,[string]$_.CreationDate
    })
    return @($items)
}

function Test-PortableNodeResolvers {
    param([string]$ReleaseRoot, [string]$SourceNodePath, [string]$IsolationRoot)

    $portableNode = Join-Path $IsolationRoot 'localappdata\Programs\nodejs\node.exe'
    $emptyPath = Join-Path $IsolationRoot 'empty-path'
    $emptyProfile = Join-Path $IsolationRoot 'empty-profile'
    $emptyProgramFiles = Join-Path $IsolationRoot 'empty-program-files'
    New-Item -ItemType Directory -Path (Split-Path -Parent $portableNode),$emptyPath,$emptyProfile,$emptyProgramFiles -Force | Out-Null
    Copy-Item -LiteralPath $SourceNodePath -Destination $portableNode

    $specifications = @(
        [pscustomobject]@{ Relative = 'CodexRemoteMobileProject\MobileProjectStartup.ps1'; Function = 'Resolve-NodePath' },
        [pscustomobject]@{ Relative = 'CodexRemoteMobileProject\MobileProjectView.ps1'; Function = 'Resolve-MobileNode' },
        [pscustomobject]@{ Relative = 'CodexRemoteMobileProject\UpdateSessionLauncher.ps1'; Function = 'Resolve-UpdateSessionNode' }
    )
    $savedEnvironment = [ordered]@{
        Path = $env:Path
        UserProfile = $env:USERPROFILE
        LocalAppData = $env:LOCALAPPDATA
        ProgramFiles = $env:ProgramFiles
    }
    try {
        $env:Path = $emptyPath
        $env:USERPROFILE = $emptyProfile
        $env:LOCALAPPDATA = Join-Path $IsolationRoot 'localappdata'
        $env:ProgramFiles = $emptyProgramFiles
        Assert-Condition ($null -eq (Get-Command node.exe -ErrorAction SilentlyContinue)) 'The portable resolver isolation still exposes Node through PATH.'

        $results = foreach ($specification in $specifications) {
            $sourcePath = Join-Path $ReleaseRoot $specification.Relative
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
            Assert-Condition ($parseErrors.Count -eq 0) "Portable resolver source does not parse: $($specification.Relative)"
            $functionName = [string]$specification.Function
            $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
            }, $true))
            Assert-Condition ($definitions.Count -eq 1) "Expected one $functionName definition in $($specification.Relative)."
            $resolved = & {
                param([string]$Definition, [string]$Name)
                $NodePath = $null
                . ([scriptblock]::Create($Definition))
                switch ($Name) {
                    'Resolve-NodePath' { Resolve-NodePath }
                    'Resolve-MobileNode' { Resolve-MobileNode -RequestedPath $null }
                    'Resolve-UpdateSessionNode' { Resolve-UpdateSessionNode }
                    default { throw "Unsupported resolver function: $Name" }
                }
            } ([string]$definitions[0].Extent.Text) $functionName
            $resolvedFull = [IO.Path]::GetFullPath([string]$resolved)
            Assert-Condition ([string]::Equals($resolvedFull, $portableNode, [StringComparison]::OrdinalIgnoreCase)) "$functionName did not select the per-user portable Node runtime."
            [pscustomobject][ordered]@{
                Source = $specification.Relative
                Function = $functionName
                ResolvedPath = $resolvedFull
            }
        }
        return @($results)
    } finally {
        $env:Path = $savedEnvironment.Path
        $env:USERPROFILE = $savedEnvironment.UserProfile
        $env:LOCALAPPDATA = $savedEnvironment.LocalAppData
        $env:ProgramFiles = $savedEnvironment.ProgramFiles
    }
}

function Invoke-UserWorker {
    $failure = $null
    $summary = $null
    $cleanupError = $null
    try {
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($ResultPath)) 'Worker result path is required.'
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) 'Worker fixture root is required.'
        $token = Get-TokenEvidence
        Assert-Condition (-not $token.Administrator) 'The install worker unexpectedly has Administrator membership enabled.'
        Assert-Condition ($token.IntegrityRid -ge 0x00002000 -and $token.IntegrityRid -lt 0x00003000) "The install worker is not medium integrity: $($token.Integrity) ($($token.IntegrityRid))."

        $localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
        $fixtureFull = [IO.Path]::GetFullPath($FixtureRoot)
        Assert-Condition ($fixtureFull.StartsWith(($localAppData + '\'), [StringComparison]::OrdinalIgnoreCase)) 'The fixture root is outside current-user LOCALAPPDATA.'
        Assert-Condition (-not (Test-Path -LiteralPath $fixtureFull)) 'The worker fixture root already exists.'
        New-Item -ItemType Directory -Path $fixtureFull -Force | Out-Null

        $archive = Resolve-ArchivePath -RequestedPath $ArchivePath
        $resolvedNode = Resolve-NodePath -RequestedPath $NodePath
        $extractRoot = Join-Path $fixtureFull 'extracted'
        $releaseRoot = Expand-SafeArchive -Path $archive -Destination $extractRoot
        $manifestEntries = @(Test-ReleaseManifest -ReleaseRoot $releaseRoot)

        $writableFiles = 0
        $manifestWritable = $false
        $releaseManifestPath = [IO.Path]::GetFullPath((Join-Path $releaseRoot 'RELEASE-MANIFEST.sha256'))
        $writeProbeRoot = Join-Path $fixtureFull 'rw'
        New-Item -ItemType Directory -Path $writeProbeRoot -Force | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath $releaseRoot -File -Recurse)) {
            $original = [string]$file.FullName
            $renamed = Join-Path $writeProbeRoot ($([guid]::NewGuid().ToString('N')) + '.tmp')
            try {
                Move-Item -LiteralPath $original -Destination $renamed
                Move-Item -LiteralPath $renamed -Destination $original
                $writableFiles++
                if ([string]::Equals($original, $releaseManifestPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $manifestWritable = $true
                }
            } catch {
                if ((Test-Path -LiteralPath $renamed -PathType Leaf) -and -not (Test-Path -LiteralPath $original)) {
                    Move-Item -LiteralPath $renamed -Destination $original -Force
                }
                throw
            }
        }
        Assert-Condition $manifestWritable 'The release manifest was not covered by the current-user rename probe.'
        $directoryMarker = Join-Path $releaseRoot ".nonadmin-write-test-$([guid]::NewGuid().ToString('N'))"
        [IO.File]::WriteAllText($directoryMarker, 'current-user write probe', [Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $directoryMarker -Force
        [void](Test-ReleaseManifest -ReleaseRoot $releaseRoot)

        $desktopPath = Join-Path $fixtureFull 'shortcuts\Desktop'
        $startMenuPath = Join-Path $fixtureFull 'shortcuts\StartMenu'
        $startupPath = Join-Path $fixtureFull 'shortcuts\Startup'
        New-Item -ItemType Directory -Path $desktopPath,$startMenuPath,$startupPath -Force | Out-Null
        $mobileRoot = Join-Path $releaseRoot 'CodexRemoteMobileProject'
        $desktopScript = Join-Path $mobileRoot 'DesktopShortcut.ps1'
        $startupScript = Join-Path $mobileRoot 'StartupShortcut.ps1'
        $launcherPath = [IO.Path]::GetFullPath((Join-Path $mobileRoot 'ChatGPT Custom.exe'))

        $legacyShortcut = Join-Path $desktopPath 'ChatGPT Custom.lnk'
        [IO.File]::WriteAllText($legacyShortcut, 'legacy-fixture-preserve')
        $desktopInstall = (& $desktopScript -Action Install -DesktopPath $desktopPath -StartMenuPath $startMenuPath -Confirm:$false | ConvertFrom-Json)
        Assert-Condition ([IO.File]::ReadAllText($legacyShortcut) -eq 'legacy-fixture-preserve') 'Installing the new shortcut changed a legacy shortcut.'
        Assert-Condition ($desktopInstall.launcherPresent -and @($desktopInstall.shortcuts).Count -eq 2) 'Desktop/Start-menu install did not report the expected launcher and two shortcuts.'
        foreach ($shortcut in @($desktopInstall.shortcuts)) {
            Assert-Condition ($shortcut.installed) "$($shortcut.kind) shortcut was not installed."
            Assert-Condition ([string]::Equals([IO.Path]::GetFullPath([string]$shortcut.targetPath), $launcherPath, [StringComparison]::OrdinalIgnoreCase)) "$($shortcut.kind) shortcut target is incorrect."
            Assert-Condition ([string]::IsNullOrWhiteSpace([string]$shortcut.arguments)) "$($shortcut.kind) shortcut has unexpected arguments."
        }
        $desktopProbe = (& $desktopScript -Action Probe -DesktopPath $desktopPath -StartMenuPath $startMenuPath | ConvertFrom-Json)
        Assert-Condition ((@($desktopProbe.shortcuts | Where-Object installed)).Count -eq 2) 'Desktop/Start-menu probe did not find both shortcuts.'

        $startupInstall = (& $startupScript -Action Install -StartupPath $startupPath -Confirm:$false | ConvertFrom-Json)
        Assert-Condition ($startupInstall.installed -and $startupInstall.startupMode -and -not $startupInstall.proxyMode) 'Startup install did not create the expected non-proxy startup shortcut.'
        Assert-Condition ([string]::Equals([IO.Path]::GetFullPath([string]$startupInstall.targetPath), $launcherPath, [StringComparison]::OrdinalIgnoreCase)) 'Startup shortcut target is incorrect.'
        $startupProbe = (& $startupScript -Action Probe -StartupPath $startupPath | ConvertFrom-Json)
        Assert-Condition ($startupProbe.installed -and $startupProbe.startupMode) 'Startup probe did not find the installed startup shortcut.'

        $package = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
        Assert-Condition ($package.Count -eq 1) "Expected one current-user OpenAI.Codex package; found $($package.Count)."
        $packageExecutable = [IO.Path]::GetFullPath((Join-Path ([string]$package[0].InstallLocation) 'app\ChatGPT.exe'))
        Assert-Condition (Test-Path -LiteralPath $packageExecutable -PathType Leaf) "Packaged ChatGPT executable is missing: $packageExecutable"
        $mainBefore = @(Get-PackageMainProcessIdentity -ExecutablePath $packageExecutable)

        $copiedNode = Join-Path $fixtureFull 'runtime\node.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $copiedNode) -Force | Out-Null
        Copy-Item -LiteralPath $resolvedNode -Destination $copiedNode
        $copiedNodeVersion = (& $copiedNode --version 2>$null | Select-Object -First 1)
        Assert-Condition ($copiedNodeVersion -match '^v(?<major>\d+)\.\d+\.\d+$' -and [int]$Matches.major -ge 22) 'The current-user copied Node runtime did not execute.'
        $portableResolverResults = @(Test-PortableNodeResolvers -ReleaseRoot $releaseRoot -SourceNodePath $resolvedNode -IsolationRoot (Join-Path $fixtureFull 'resolver-isolation'))
        Assert-Condition ($portableResolverResults.Count -eq 3) 'Not all three production portable Node resolvers were exercised.'

        $setupActions = (& (Join-Path $PSScriptRoot 'Test-SetupAssistant.ps1') -PackageRoot $releaseRoot | ConvertFrom-Json)
        Assert-Condition ($setupActions.SelectedOptionsApplied -and $setupActions.ProxyPreferencePreserved -and $setupActions.LegacyShortcutPreserved) 'Medium-token setup actions failed.'
        $setupProbe = (& (Join-Path $releaseRoot 'Setup-ChatGPTRemote.ps1') -Action Probe | ConvertFrom-Json)
        Assert-Condition ($setupProbe.Folder -eq 'Writable for this user') 'Setup assistant failed its medium-token write/rename check.'
        Assert-Condition ($setupProbe.Node -like 'Compatible*') 'Setup assistant did not detect the compatible runtime.'
        Assert-Condition ($setupProbe.Integration -like 'Package files present*') 'Setup assistant did not recognize the extracted package.'
        $stableProbe = Join-Path $releaseRoot 'CodexRemoteSimple\CodexRemoteSimple.ps1'
        $isolatedLocalAppData = Join-Path $fixtureFull 'probe-localappdata'
        New-Item -ItemType Directory -Path $isolatedLocalAppData -Force | Out-Null
        $savedLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $isolatedLocalAppData
            $probeOutput = @(& $stableProbe -Action Check -NodePath $copiedNode)
        } finally {
            $env:LOCALAPPDATA = $savedLocalAppData
        }
        $probe = @($probeOutput | Where-Object { $_ -is [psobject] -and $null -ne $_.PSObject.Properties['Ready'] } | Select-Object -Last 1)
        Assert-Condition ($probe.Count -eq 1 -and $probe[0].Ready) 'The stable source runtime readiness check did not return Ready=true.'
        Assert-Condition ($probe[0].Classification -cin @('CandidateCompatible','NativeWindowsCompatible')) "Unexpected compatibility classification: $($probe[0].Classification)"
        Assert-Condition ($probe[0].AppAsarSha256 -cmatch '^[0-9a-f]{64}$') 'The stable source runtime readiness check did not hash app.asar.'
        $mainAfter = @(Get-PackageMainProcessIdentity -ExecutablePath $packageExecutable)
        Assert-Condition (($mainBefore -join "`n") -ceq ($mainAfter -join "`n")) 'The packaged ChatGPT main-process identity changed during the read-only readiness check.'

        $startupRemove = (& $startupScript -Action Remove -StartupPath $startupPath -Confirm:$false | ConvertFrom-Json)
        Assert-Condition (-not $startupRemove.installed -and -not $startupRemove.legacyDisabledPresent) 'Startup shortcut removal was incomplete.'
        $desktopRemove = (& $desktopScript -Action Remove -DesktopPath $desktopPath -StartMenuPath $startMenuPath -Confirm:$false | ConvertFrom-Json)
        Assert-Condition ((@($desktopRemove.shortcuts | Where-Object installed)).Count -eq 0) 'Desktop/Start-menu shortcut removal was incomplete.'
        Assert-Condition ((@(Get-ChildItem -LiteralPath $desktopPath,$startMenuPath,$startupPath -File -Force)).Count -eq 0) 'Shortcut fixture files remain after removal.'

        $summary = [pscustomobject][ordered]@{
            Ok = $true
            Token = $token
            ArchivePath = $archive
            ArchiveSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
            ExtractedRoot = $releaseRoot
            ManifestEntries = $manifestEntries.Count
            WritableFilesRenamed = $writableFiles
            ReleaseManifestRenamed = $manifestWritable
            PortableNodeResolvers = @($portableResolverResults)
            LegacyShortcutPreserved = $true
            SetupAssistantActions = $setupActions
            SetupAssistantProbe = $setupProbe
            DesktopStartMenuInstallProbeRemove = $true
            StartupInstallProbeRemove = $true
            StableReadOnlyProbe = [pscustomobject][ordered]@{
                Ready = [bool]$probe[0].Ready
                PackageVersion = [string]$probe[0].PackageVersion
                PackageFullName = [string]$probe[0].PackageFullName
                NodeVersion = [string]$probe[0].NodeVersion
                CopiedNodeVersion = [string]$copiedNodeVersion
                Classification = [string]$probe[0].Classification
                BridgeMode = [string]$probe[0].BridgeMode
                AppAsarSha256 = [string]$probe[0].AppAsarSha256
                MainProcessesBefore = @($mainBefore)
                MainProcessesAfter = @($mainAfter)
                ProcessIdentityUnchanged = $true
            }
        }
    } catch {
        $failure = $_
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        try {
            if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
                $fixtureFull = [IO.Path]::GetFullPath($FixtureRoot)
                $localPrefix = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
                if ((Test-Path -LiteralPath $fixtureFull) -and $fixtureFull.StartsWith($localPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item -LiteralPath $fixtureFull -Recurse -Force
                }
            }
        } catch {
            $cleanupError = $_
        }
    }

    $residual = -not [string]::IsNullOrWhiteSpace($FixtureRoot) -and (Test-Path -LiteralPath $FixtureRoot)
    if ($null -ne $cleanupError -or $residual) {
        $message = if ($null -ne $cleanupError) { $cleanupError.Exception.Message } else { 'The fixture root remains after cleanup.' }
        if ($null -eq $failure) { $failure = [Management.Automation.ErrorRecord]::new([Exception]::new($message), 'WorkerCleanupFailed', [Management.Automation.ErrorCategory]::WriteError, $FixtureRoot) }
    }
    if ($null -eq $summary) { $summary = [pscustomobject][ordered]@{ Ok = $false } }
    $summary | Add-Member -NotePropertyName CleanupResiduals -NotePropertyValue $(if ($residual) { 1 } else { 0 }) -Force
    if ($null -ne $failure) {
        $summary.Ok = $false
        $summary | Add-Member -NotePropertyName Error -NotePropertyValue $failure.Exception.Message -Force
        $summary | Add-Member -NotePropertyName ErrorId -NotePropertyValue $failure.FullyQualifiedErrorId -Force
        $summary | Add-Member -NotePropertyName ErrorPosition -NotePropertyValue ([string]$failure.InvocationInfo.PositionMessage) -Force
        $summary | Add-Member -NotePropertyName ErrorStack -NotePropertyValue ([string]$failure.ScriptStackTrace) -Force
    }
    $resultParent = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
    Assert-Condition (Test-Path -LiteralPath $resultParent -PathType Container) 'The worker result directory is missing.'
    [IO.File]::WriteAllText($ResultPath, ($summary | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    if ($null -ne $failure) { exit 1 }
    exit 0
}

function Invoke-WithExplorerToken {
    param([string]$CommandLine, [string]$WorkingDirectory, [int]$TimeoutMilliseconds)
    if (-not ('MediumTokenProcessLauncher' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class MediumTokenLaunchResult
{
    public int ShellProcessId { get; set; }
    public int ProcessId { get; set; }
    public int ExitCode { get; set; }
}

public static class MediumTokenProcessLauncher
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute;
        public int dwFlags; public short wShowWindow; public short cbReserved2;
        public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess; public IntPtr hThread; public uint dwProcessId; public uint dwThreadId;
    }

    [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool DuplicateTokenEx(IntPtr existing, uint access, IntPtr attributes, int level, int type, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessWithTokenW(IntPtr token, uint logonFlags, string applicationName,
        StringBuilder commandLine, uint creationFlags, IntPtr environment, string currentDirectory,
        ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    public static MediumTokenLaunchResult Run(string applicationName, string commandLine, string currentDirectory, int timeoutMilliseconds)
    {
        IntPtr shell = GetShellWindow();
        if (shell == IntPtr.Zero) throw new InvalidOperationException("The interactive Explorer shell window was not found.");
        uint shellPid; GetWindowThreadProcessId(shell, out shellPid);
        if (shellPid == 0) throw new InvalidOperationException("The interactive Explorer process ID was not found.");
        IntPtr process = IntPtr.Zero, token = IntPtr.Zero, primary = IntPtr.Zero;
        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
        try
        {
            process = OpenProcess(0x1000, false, shellPid);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess(Explorer) failed.");
            if (!OpenProcessToken(process, 0x0001 | 0x0002 | 0x0008, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken(Explorer) failed.");
            if (!DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out primary))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "DuplicateTokenEx(Explorer) failed.");
            STARTUPINFO si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO)); si.dwFlags = 0x00000001; si.wShowWindow = 0;
            if (!CreateProcessWithTokenW(primary, 0, null, new StringBuilder(commandLine),
                0x08000000, IntPtr.Zero, currentDirectory, ref si, out pi))
            {
                int error = Marshal.GetLastWin32Error();
                throw new InvalidOperationException("CreateProcessWithTokenW(Explorer) failed with Win32 error " + error + ": " + new Win32Exception(error).Message);
            }
            uint wait = WaitForSingleObject(pi.hProcess, (uint)timeoutMilliseconds);
            if (wait == 0x00000102)
            {
                TerminateProcess(pi.hProcess, 1460);
                WaitForSingleObject(pi.hProcess, 5000);
                throw new TimeoutException("The medium-token install worker exceeded its timeout.");
            }
            if (wait != 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Waiting for the medium-token worker failed.");
            uint exitCode;
            if (!GetExitCodeProcess(pi.hProcess, out exitCode))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Reading the medium-token worker exit code failed.");
            return new MediumTokenLaunchResult { ShellProcessId = (int)shellPid, ProcessId = (int)pi.dwProcessId, ExitCode = (int)exitCode };
        }
        finally
        {
            if (pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            if (primary != IntPtr.Zero) CloseHandle(primary);
            if (token != IntPtr.Zero) CloseHandle(token);
            if (process != IntPtr.Zero) CloseHandle(process);
        }
    }
}
'@
    }
    return [MediumTokenProcessLauncher]::Run($CommandLine.Split('"')[1], $CommandLine, $WorkingDirectory, $TimeoutMilliseconds)
}

if ($Worker) {
    if (-not [string]::IsNullOrWhiteSpace($JobPath)) {
        $job = Get-Content -LiteralPath $JobPath -Raw | ConvertFrom-Json
        $ArchivePath = [string]$job.ArchivePath
        $NodePath = [string]$job.NodePath
        $ResultPath = [string]$job.ResultPath
        $FixtureRoot = [string]$job.FixtureRoot
    }
    $currentUserTemp = Join-Path $env:LOCALAPPDATA 'Temp'
    New-Item -ItemType Directory -Path $currentUserTemp -Force | Out-Null
    $env:TEMP = $currentUserTemp
    $env:TMP = $currentUserTemp
    Invoke-UserWorker
}

$resolvedArchive = Resolve-ArchivePath -RequestedPath $ArchivePath
$resolvedNode = Resolve-NodePath -RequestedPath $NodePath
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-Condition (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) 'Windows PowerShell 5.1 is required for the medium-token worker.'
$testId = [guid]::NewGuid().ToString('N')
$fixtureRootPath = Join-Path $env:LOCALAPPDATA "Temp\chatgpt-remote-user-install-$testId"
$resultFile = Join-Path $env:LOCALAPPDATA "Temp\chatgpt-remote-user-install-$testId-result.json"
$jobFile = Join-Path $env:LOCALAPPDATA "Temp\chatgpt-remote-user-install-$testId-job.json"

function ConvertTo-SingleQuotedLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

$job = [pscustomobject][ordered]@{
    ArchivePath = $resolvedArchive
    NodePath = $resolvedNode
    ResultPath = $resultFile
    FixtureRoot = $fixtureRootPath
}
[IO.File]::WriteAllText($jobFile, ($job | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
$invocation = "& $(ConvertTo-SingleQuotedLiteral $PSCommandPath) -Worker -JobPath $(ConvertTo-SingleQuotedLiteral $jobFile)"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
$commandLine = '"' + $windowsPowerShell + '" -NoLogo -NoProfile -NonInteractive -Sta -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
$parentToken = Get-TokenEvidence
$launch = $null
$workerResult = $null
try {
    $launch = Invoke-WithExplorerToken -CommandLine $commandLine -WorkingDirectory (Split-Path -Parent $PSCommandPath) -TimeoutMilliseconds ($WorkerTimeoutSeconds * 1000)
    Assert-Condition (Test-Path -LiteralPath $resultFile -PathType Leaf) "The medium-token worker returned exit code $($launch.ExitCode) without a result file."
    $workerResult = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
    if ($launch.ExitCode -ne 0 -or -not $workerResult.Ok) {
        throw "The medium-token worker failed: $($workerResult.Error) $($workerResult.ErrorPosition) $($workerResult.ErrorStack)"
    }
    Assert-Condition ($workerResult.CleanupResiduals -eq 0 -and -not (Test-Path -LiteralPath $fixtureRootPath)) 'The medium-token worker left fixture state behind.'
    Assert-Condition ($workerResult.Token.SessionId -eq $parentToken.SessionId) 'The medium-token worker did not run in the interactive shell session.'
} finally {
    if (Test-Path -LiteralPath $resultFile -PathType Leaf) { Remove-Item -LiteralPath $resultFile -Force }
    if (Test-Path -LiteralPath $jobFile -PathType Leaf) { Remove-Item -LiteralPath $jobFile -Force }
    if (Test-Path -LiteralPath $fixtureRootPath) { Remove-Item -LiteralPath $fixtureRootPath -Recurse -Force }
}

[pscustomobject][ordered]@{
    RealNonElevatedExecution = $true
    ExplorerProcessId = $launch.ShellProcessId
    WorkerProcessId = $launch.ProcessId
    WorkerExitCode = $launch.ExitCode
    ParentToken = $parentToken
    WorkerToken = $workerResult.Token
    ArchivePath = $workerResult.ArchivePath
    ArchiveSha256 = $workerResult.ArchiveSha256
    ManifestEntries = $workerResult.ManifestEntries
    WritableFilesRenamed = $workerResult.WritableFilesRenamed
    ReleaseManifestRenamed = $workerResult.ReleaseManifestRenamed
    PortableNodeResolvers = @($workerResult.PortableNodeResolvers)
    LegacyShortcutPreserved = $workerResult.LegacyShortcutPreserved
    SetupAssistantActions = $workerResult.SetupAssistantActions
    SetupAssistantProbe = $workerResult.SetupAssistantProbe
    DesktopStartMenuInstallProbeRemove = $workerResult.DesktopStartMenuInstallProbeRemove
    StartupInstallProbeRemove = $workerResult.StartupInstallProbeRemove
    StableReadOnlyProbe = $workerResult.StableReadOnlyProbe
    CleanupResiduals = 0
} | ConvertTo-Json -Depth 8
