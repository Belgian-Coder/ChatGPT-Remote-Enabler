[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modulePath = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\ProxyConfiguration.psm1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-proxy-test-' + [guid]::NewGuid().ToString('N'))
$configPath = Join-Path $temporaryRoot 'remote-proxy.dpapi'
try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    Import-Module $modulePath -Force
    $example = 'http://proxy.example.test:8080'
    Set-ChatGPTRemoteProxy -ProxyUrl $example -ConfigPath $configPath -Confirm:$false
    $cipherText = Get-Content -LiteralPath $configPath -Raw
    if ($cipherText.Contains('proxy.example.test')) { throw 'The protected proxy file contains plaintext proxy data.' }
    $resolved = Get-ChatGPTRemoteProxy -ConfigPath $configPath
    if ($resolved -ne $example) { throw 'The protected proxy configuration did not round-trip.' }
    $credentialRejected = $false
    try { [void](Test-ChatGPTRemoteProxyUrl 'http://user:password@proxy.example.test:8080') }
    catch { $credentialRejected = $true }
    if (-not $credentialRejected) { throw 'A proxy URL containing credentials was accepted.' }
    Remove-ChatGPTRemoteProxy -ConfigPath $configPath -Confirm:$false
    if (Test-Path -LiteralPath $configPath) { throw 'The protected proxy configuration was not removed.' }
    [pscustomobject]@{ ProtectedRoundTrip = $true; PlaintextAbsent = $true; CredentialsRejected = $true } | ConvertTo-Json
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
