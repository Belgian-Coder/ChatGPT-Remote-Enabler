[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-archive-test-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    & (Join-Path $PSScriptRoot 'Build-Release.ps1') -OutputDirectory $temporaryRoot | Out-Null
    $archives = @(Get-ChildItem -LiteralPath $temporaryRoot -Filter '*.zip' -File)
    if ($archives.Count -ne 2) { throw 'Release builder did not produce both platform archives.' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $macExecutableNames = @(
        'MacOSShortcut.sh',
        'MobileProjectView-macOS-arm64.sh',
        'Setup.command',
        'Update-ChatGPTRemote.sh',
        'UpdateSessionPlatform.sh'
    )
    foreach ($archiveFile in $archives) {
        $archive = [IO.Compression.ZipFile]::OpenRead($archiveFile.FullName)
        try {
            $names = @($archive.Entries | ForEach-Object FullName)
            if ($names | Where-Object { $_ -match '\\' }) {
                throw "$($archiveFile.Name) contains non-portable backslash entry names."
            }
            $topLevels = @($names | ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ } | Select-Object -Unique)
            if ($topLevels.Count -ne 1) { throw "$($archiveFile.Name) does not have one top-level directory." }
            if ($archiveFile.Name -like '*-macOS-arm64-*') {
                foreach ($name in $macExecutableNames) {
                    $entry = $archive.GetEntry("$($topLevels[0])/$name")
                    if (-not $entry) { throw "$($archiveFile.Name) is missing executable entry $name." }
                    $externalAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
                    $mode = ($externalAttributes -shr 16) -band 0xffff
                    if ($mode -ne 0x81ed) { throw "$($archiveFile.Name) stores $name with Unix mode 0x$($mode.ToString('x4')); expected 0x81ed." }
                }
                $ordinaryEntry = $archive.GetEntry("$($topLevels[0])/VERSION")
                $ordinaryAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ordinaryEntry.ExternalAttributes), 0)
                $ordinaryMode = ($ordinaryAttributes -shr 16) -band 0xffff
                if ($ordinaryMode -ne 0x81a4) { throw "$($archiveFile.Name) stores VERSION with Unix mode 0x$($ordinaryMode.ToString('x4')); expected 0x81a4." }
            }
        } finally {
            $archive.Dispose()
        }
        if ($archiveFile.Name -like '*-macOS-arm64-*') {
            $bytes = [IO.File]::ReadAllBytes($archiveFile.FullName)
            $eocdOffset = -1
            for ($offset = $bytes.Length - 22; $offset -ge [Math]::Max(0, $bytes.Length - 22 - 65535); $offset--) {
                if ($bytes[$offset] -eq 0x50 -and $bytes[$offset + 1] -eq 0x4b -and $bytes[$offset + 2] -eq 0x05 -and $bytes[$offset + 3] -eq 0x06) {
                    $eocdOffset = $offset
                    break
                }
            }
            if ($eocdOffset -lt 0) { throw "$($archiveFile.Name) has no ZIP end-of-central-directory record." }
            $entryCount = [BitConverter]::ToUInt16($bytes, $eocdOffset + 10)
            $centralOffset = [int][BitConverter]::ToUInt32($bytes, $eocdOffset + 16)
            for ($index = 0; $index -lt $entryCount; $index++) {
                if ([BitConverter]::ToUInt32($bytes, $centralOffset) -ne 0x02014b50 -or $bytes[$centralOffset + 5] -ne 3) {
                    throw "$($archiveFile.Name) contains a central-directory entry without Unix creator metadata."
                }
                $centralOffset += 46 + [BitConverter]::ToUInt16($bytes, $centralOffset + 28) +
                    [BitConverter]::ToUInt16($bytes, $centralOffset + 30) + [BitConverter]::ToUInt16($bytes, $centralOffset + 32)
            }
        }
    }

    [pscustomobject]@{
        Archives = $archives.Count
        ForwardSlashEntries = $true
        SingleTopLevelDirectory = $true
        MacOSUnixExecutableModes = $true
        MacOSUnixRegularFileModes = $true
        MacOSUnixCreatorMetadata = $true
    } | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolved) -and $resolved.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
