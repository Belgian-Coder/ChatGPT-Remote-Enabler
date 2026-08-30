[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist'),
    [string[]]$ForbiddenPattern = @()
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-PortableReleaseArchive {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDirectory,
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) { Remove-Item -LiteralPath $DestinationPath -Force }
    $sourceParent = Split-Path -Parent $SourceDirectory
    $archive = [IO.Compression.ZipFile]::Open($DestinationPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse | Sort-Object FullName) {
            $entryName = $file.FullName.Substring($sourceParent.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $file.FullName,
                $entryName,
                [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

function Assert-ReleasePrivacy {
    param(
        [Parameter(Mandatory)]
        [string]$StageRoot,
        [string[]]$AdditionalPattern = @()
    )

    $privacyPatterns = @(
        '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '(?i)\b(?:ghp|github_pat|sk)-[A-Za-z0-9_-]{20,}\b',
        '(?i)\bremote-control:env_[A-Za-z0-9_]+\b',
        '(?i)(?:C:\\Users\\|/Users/)[^\s/\\]+',
        '(?i)\bPC[-]MARC\b',
        '(?i)\bWINDOWS11[-]VM\b',
        '(?i)\bMacBook[-]Pro\b'
    ) + $AdditionalPattern
    foreach ($file in Get-ChildItem -LiteralPath $StageRoot -File -Recurse) {
        if ($file.Extension -in '.exe','.png','.jpg','.jpeg','.zip') { continue }
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        foreach ($pattern in $privacyPatterns) {
            if ($pattern -and $content -match $pattern) { throw "Privacy scan failed for $($file.Name)." }
        }
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$platforms = @(
    [pscustomobject]@{ Name = 'Windows-x64'; Source = 'windows' },
    [pscustomobject]@{ Name = 'macOS-arm64'; Source = 'macos' }
)

if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git') -PathType Container)) {
    throw 'Build-Release.ps1 must run from the ChatGPT-Remote-Enabler Git checkout.'
}

$versions = @($platforms | ForEach-Object {
    (Get-Content -LiteralPath (Join-Path $repositoryRoot "$($_.Source)\VERSION") -Raw).Trim()
} | Select-Object -Unique)
if ($versions.Count -ne 1 -or $versions[0] -notmatch '^v\d+\.\d+\.\d+$') {
    throw 'Windows and macOS must contain one matching semantic VERSION.'
}
$version = $versions[0]
$expectedWindowsFileVersion = $version.TrimStart('v') + '.0'
foreach ($launcher in @(
    (Join-Path $repositoryRoot 'windows\ChatGPT Remote Enabler.exe'),
    (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\ChatGPT Custom.exe')
)) {
    $actualFileVersion = (Get-Item -LiteralPath $launcher).VersionInfo.FileVersion
    if ($actualFileVersion -ne $expectedWindowsFileVersion) {
        throw "Windows launcher $([IO.Path]::GetFileName($launcher)) is version $actualFileVersion; expected $expectedWindowsFileVersion."
    }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-remote-release-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temporaryRoot,$OutputDirectory -Force | Out-Null
    $archives = [Collections.Generic.List[object]]::new()
    foreach ($platform in $platforms) {
        $rootName = "ChatGPT-Remote-Enabler-$($platform.Name)-$version"
        $stageRoot = Join-Path $temporaryRoot $rootName
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        $trackedFiles = @(& git -C $repositoryRoot ls-files -- "$($platform.Source)/*")
        if ($LASTEXITCODE -ne 0 -or -not $trackedFiles.Count) { throw "No tracked $($platform.Source) files were found." }
        foreach ($tracked in $trackedFiles) {
            $relative = $tracked.Substring($platform.Source.Length + 1)
            $source = Join-Path $repositoryRoot ($tracked.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $destination = Join-Path $stageRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }

        $manifestLines = foreach ($file in Get-ChildItem -LiteralPath $stageRoot -File -Recurse | Sort-Object FullName) {
            $relative = $file.FullName.Substring($stageRoot.Length + 1).Replace('\', '/')
            "{0} *{1}" -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),$relative
        }
        [IO.File]::WriteAllText((Join-Path $stageRoot 'RELEASE-MANIFEST.sha256'), (($manifestLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

        Assert-ReleasePrivacy -StageRoot $stageRoot -AdditionalPattern $ForbiddenPattern

        $archivePath = Join-Path $OutputDirectory "$rootName.zip"
        New-PortableReleaseArchive -SourceDirectory $stageRoot -DestinationPath $archivePath
        $archives.Add([pscustomobject]@{
            Name = [IO.Path]::GetFileName($archivePath)
            Path = $archivePath
            Sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }

    $sumsPath = Join-Path $OutputDirectory "SHA256SUMS-$version.txt"
    $sumLines = @($archives | ForEach-Object { "$($_.Sha256)  $($_.Name)" })
    [IO.File]::WriteAllText($sumsPath, (($sumLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    foreach ($archive in $archives) {
        $zip = [IO.Compression.ZipFile]::OpenRead($archive.Path)
        try {
            $topLevels = @($zip.Entries | ForEach-Object { ($_.FullName -split '/')[0] } | Where-Object { $_ } | Select-Object -Unique)
            if ($topLevels.Count -ne 1) { throw "$($archive.Name) does not contain exactly one top-level directory." }
            if (-not @($zip.Entries.FullName | Where-Object { $_ -eq "$($topLevels[0])/VERSION" }).Count) { throw "$($archive.Name) has no root VERSION file." }
            if (-not @($zip.Entries.FullName | Where-Object { $_ -eq "$($topLevels[0])/RELEASE-MANIFEST.sha256" }).Count) { throw "$($archive.Name) has no internal manifest." }
        } finally {
            $zip.Dispose()
        }
    }

    [pscustomobject]@{ Version = $version; Archives = @($archives); Checksums = $sumsPath } | ConvertTo-Json -Depth 5
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
