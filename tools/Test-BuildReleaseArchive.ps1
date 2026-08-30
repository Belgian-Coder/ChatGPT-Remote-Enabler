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
    foreach ($archiveFile in $archives) {
        $archive = [IO.Compression.ZipFile]::OpenRead($archiveFile.FullName)
        try {
            $names = @($archive.Entries | ForEach-Object FullName)
            if ($names | Where-Object { $_ -match '\\' }) {
                throw "$($archiveFile.Name) contains non-portable backslash entry names."
            }
            $topLevels = @($names | ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ } | Select-Object -Unique)
            if ($topLevels.Count -ne 1) { throw "$($archiveFile.Name) does not have one top-level directory." }
        } finally {
            $archive.Dispose()
        }
    }

    [pscustomobject]@{
        Archives = $archives.Count
        ForwardSlashEntries = $true
        SingleTopLevelDirectory = $true
    } | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolved) -and $resolved.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
