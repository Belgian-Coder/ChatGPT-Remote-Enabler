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
    $provider = '782640499 Control other devices from this PC var Xke=(0,F.createRequire)(__filename),Zke=`remote-control-device-key.node`,Qke=`codex-device-key-sign-payload/v1`;$ke=class{resourcesPath;addon=null;constructor(e){this.resourcesPath=e}createDeviceKey(e){return this.getAddon().createDeviceKey(e??`hardware_only`)}deleteDeviceKey(e){return this.getAddon().deleteDeviceKey(e)}getDeviceKeyPublic(e){return this.getAddon().getDeviceKeyPublic(e)}async signDeviceKey(e,t){let n=eAe(t);return{...await this.getAddon().signDeviceKey(e,n),signedPayloadBase64:n.toString(`base64`)}}getAddon(){if(this.resourcesPath==null)throw Error(`Remote control device keys require resourcesPath`);return this.addon??=Xke((0,p.join)(this.resourcesPath,`native`,Zke)),this.addon}}'
    $compatibleAsar = Join-Path $temporary 'compatible.asar'
    [IO.File]::WriteAllText($compatibleAsar, $provider, [Text.UTF8Encoding]::new($false))
    $node = [pscustomobject]@{ Path = [IO.Path]::GetFullPath($NodePath) }
    $package = [pscustomobject]@{ AppAsarPath = $compatibleAsar; NativeRoot = $nativeRoot }
    $result = Test-CrsCompatibility -Package $package -Node $node
    if ($result.classification -cne 'NativeWindowsCompatible' -or
        $result.bridgeMode -cne 'native-renderer' -or
        $result.providerContract -isnot [bool] -or -not $result.providerContract) {
        throw 'The platform-neutral Windows fixture was not accepted with its complete provider contract.'
    }

    $incompleteAsar = Join-Path $temporary 'incomplete.asar'
    [IO.File]::WriteAllText($incompleteAsar, $provider.Replace('Remote control device keys require resourcesPath', 'unrelated error'), [Text.UTF8Encoding]::new($false))
    $package.AppAsarPath = $incompleteAsar
    $rejected = $false
    try { Test-CrsCompatibility -Package $package -Node $node | Out-Null } catch {
        $rejected = $_.Exception.Message -match 'audited Windows compatibility signature'
    }
    if (-not $rejected) { throw 'The incomplete platform-neutral Windows fixture did not fail closed.' }

    [pscustomobject]@{
        Edition = $PSVersionTable.PSEdition
        PowerShellVersion = [string]$PSVersionTable.PSVersion
        PlatformNeutralAccepted = $true
        IncompleteRejected = $true
    } | ConvertTo-Json -Compress
} finally {
    Remove-Item -LiteralPath $temporary -Force -Recurse -ErrorAction SilentlyContinue
}
