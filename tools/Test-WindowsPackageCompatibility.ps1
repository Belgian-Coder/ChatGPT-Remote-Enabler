[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NodePath
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$controller = Join-Path $root 'windows\CodexRemoteSimple\CodexRemoteSimple.ps1'
$script:RuntimeRoot = Join-Path $root 'windows\CodexRemoteSimple\runtime'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($controller, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Controller parse failed: $($errors[0].Message)" }
$functionAst = $ast.Find({
    param($candidate)
    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $candidate.Name -ceq 'Test-CrsCompatibility'
}, $true)
if ($null -eq $functionAst) { throw 'Test-CrsCompatibility was not found.' }
Invoke-Expression $functionAst.Extent.Text

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('codexremote-package-powershell-' + [guid]::NewGuid().ToString('N'))
try {
    $nativeRoot = Join-Path $temporary 'native'
    New-Item -ItemType Directory -Path $nativeRoot -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $nativeRoot 'remote-control-device-key.node'), [byte[]](0x4d, 0x5a, 0x00, 0x00))
    $asar = Join-Path $temporary 'arbitrary.asar'
    [IO.File]::WriteAllText($asar, 'renamed minified members; reordered capability implementation; no package signature table', [Text.UTF8Encoding]::new($false))
    $node = [pscustomobject]@{ Path = [IO.Path]::GetFullPath($NodePath) }
    $package = [pscustomobject]@{ AppAsarPath = $asar; NativeRoot = $nativeRoot }

    $native = Test-CrsCompatibility -Package $package -Node $node
    if ($native.schemaVersion -ne 3 -or
        $native.artifactReadable -isnot [bool] -or -not $native.artifactReadable -or
        $native.classification -cne 'CapabilityCompatible' -or
        $native.nativeModulePresent -ne $true -or $native.nativeModuleFormat -cne 'windows-pe' -or
        $native.recommendedBridgeMode -cne 'native-renderer' -or
        $native.bridgeMode -cne 'native-renderer' -or
        $null -ne $native.PSObject.Properties['appAsarSha256'] -or
        $null -ne $native.PSObject.Properties['affected'] -or
        $null -ne $native.PSObject.Properties['signatures']) {
        throw 'The Windows native capability schema was not returned exactly.'
    }

    $legacyPackage = [pscustomobject]@{ AppAsarPath = $asar; NativeRoot = (Join-Path $temporary 'missing-native') }
    $legacy = Test-CrsCompatibility -Package $legacyPackage -Node $node
    if ($legacy.schemaVersion -ne 3 -or $legacy.classification -cne 'CapabilityCompatible' -or
        $legacy.nativeModulePresent -ne $false -or $legacy.recommendedBridgeMode -cne 'legacy-main-shim' -or
        $legacy.bridgeMode -cne 'legacy-main-shim') {
        throw 'The artifact-only legacy capability fallback was not returned.'
    }

    $nonWindowsRoot = Join-Path $temporary 'non-windows-native'
    New-Item -ItemType Directory -Path $nonWindowsRoot -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $nonWindowsRoot 'remote-control-device-key.node'), [byte[]](0x7f, 0x45, 0x4c, 0x46))
    $nonWindows = Test-CrsCompatibility -Package ([pscustomobject]@{ AppAsarPath = $asar; NativeRoot = $nonWindowsRoot }) -Node $node
    if ($nonWindows.nativeModulePresent -ne $true -or $nonWindows.nativeModuleFormat -cne 'non-windows' -or
        $nonWindows.bridgeMode -cne 'legacy-main-shim') {
        throw 'A non-Windows native module did not fall back to the legacy runtime capability.'
    }

    [pscustomobject]@{
        Edition = $PSVersionTable.PSEdition
        PowerShellVersion = [string]$PSVersionTable.PSVersion
        SchemaVersion = [int]$native.schemaVersion
        NativeRendererAccepted = $true
        LegacyFallbackAccepted = $true
        NoSupportedVersionHash = $true
        NoSignatureAllowlist = $true
    } | ConvertTo-Json -Compress
} finally {
    Remove-Item -LiteralPath $temporary -Force -Recurse -ErrorAction SilentlyContinue
}
