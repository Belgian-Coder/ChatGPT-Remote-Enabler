[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PayloadBase64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64))
$payload = $json | ConvertFrom-Json -ErrorAction Stop
foreach ($name in @('packageFamilyName', 'applicationId', 'helperPath', 'executablePath', 'proxyServer', 'nodePath', 'bridgePath', 'targetBaseUrl')) {
    if ($payload.$name -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$payload.$name)) {
        throw "The package-context launch payload is missing $name."
    }
}
$arguments = @($payload.arguments)
$values = @(
    [string]$payload.executablePath,
    [string]$payload.proxyServer,
    [string]$payload.nodePath,
    [string]$payload.bridgePath,
    [string]$payload.targetBaseUrl
) + @($arguments | ForEach-Object { [string]$_ })
foreach ($value in $values) {
    if ($null -eq $value -or $value -match '[\x00\r\n"]') {
        throw 'A package-context launch value contains unsupported characters.'
    }
}
$helperPath = [IO.Path]::GetFullPath([string]$payload.helperPath)
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw 'The package-context process launcher is missing.'
}
$wrapperArguments = @($values | ForEach-Object { '"' + $_ + '"' }) -join ' '
Invoke-CommandInDesktopPackage `
    -PackageFamilyName ([string]$payload.packageFamilyName) `
    -AppId ([string]$payload.applicationId) `
    -Command $helperPath `
    -Args $wrapperArguments `
    -ErrorAction Stop | Out-Null
