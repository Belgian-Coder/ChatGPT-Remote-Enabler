[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$modulePath = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\ProxyConfiguration.psm1'
$controllerPath = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\ProxyConfiguration.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-proxy-test-' + [guid]::NewGuid().ToString('N'))
$configPath = Join-Path $temporaryRoot 'remote-proxy.dpapi'
try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $controllerSource = Get-Content -LiteralPath $controllerPath -Raw
    if ($controllerSource -match 'RemoveUserEnvironment') {
        throw 'The proxy controller must not offer removal of shared User-scope proxy variables.'
    }
    if ($controllerSource -match 'SetEnvironmentVariable\s*\([^\)]*[''"]User[''"]') {
        throw 'The proxy controller must not mutate shared User-scope environment variables.'
    }
    $proxyModule = Import-Module $modulePath -Force -PassThru
    $example = 'http://proxy.example.test:8080'
    Set-ChatGPTRemoteProxy -ProxyUrl $example -ConfigPath $configPath -Confirm:$false
    $cipherText = Get-Content -LiteralPath $configPath -Raw
    if ($cipherText.Contains('proxy.example.test')) { throw 'The protected proxy file contains plaintext proxy data.' }
    $resolved = Get-ChatGPTRemoteProxy -ConfigPath $configPath
    if ($resolved -ne $example) { throw 'The protected proxy configuration did not round-trip.' }
    $fixedFlags = [byte[]]::new(9); $fixedFlags[8] = 3
    $automaticFlags = [byte[]]::new(9); $automaticFlags[8] = 9
    $manualAndAutomaticFlags = [byte[]]::new(9); $manualAndAutomaticFlags[8] = 11
    $fixedSystem = & $proxyModule { param($settings) Get-ChatGPTRemoteFixedSystemProxy -InternetSettings $settings } ([pscustomobject]@{ ProxyEnable = 1; ProxyServer = 'http=proxy-http.example.test:8080;https=proxy-https.example.test:8443'; AutoDetect = 0; AutoConfigURL = ''; DefaultConnectionSettings = $fixedFlags })
    if ($fixedSystem -ne 'http://proxy-https.example.test:8443') { throw 'The fixed Windows HTTPS proxy was not resolved.' }
    $pacSystem = & $proxyModule { param($settings) Get-ChatGPTRemoteFixedSystemProxy -InternetSettings $settings } ([pscustomobject]@{ ProxyEnable = 1; ProxyServer = 'proxy.example.test:8080'; AutoDetect = 0; AutoConfigURL = 'https://proxy.example.test/proxy.pac'; DefaultConnectionSettings = $fixedFlags })
    if ($null -ne $pacSystem) { throw 'A PAC-based Windows proxy was accepted as one fixed endpoint.' }
    $wpadSystem = & $proxyModule { param($settings) Get-ChatGPTRemoteFixedSystemProxy -InternetSettings $settings } ([pscustomobject]@{ ProxyEnable = 1; ProxyServer = 'proxy.example.test:8080'; AutoDetect = 0; AutoConfigURL = ''; DefaultConnectionSettings = $automaticFlags })
    if ($null -ne $wpadSystem) { throw 'A WPAD-based Windows proxy was accepted as one fixed endpoint.' }
    $manualWithWpad = & $proxyModule { param($settings) Get-ChatGPTRemoteFixedSystemProxy -InternetSettings $settings } ([pscustomobject]@{ ProxyEnable = 1; ProxyServer = 'proxy.example.test:8080'; AutoDetect = 1; AutoConfigURL = ''; DefaultConnectionSettings = $manualAndAutomaticFlags })
    if ($manualWithWpad -ne 'http://proxy.example.test:8080') { throw 'A fixed manual proxy was rejected merely because Windows auto-detect is also enabled.' }
    $credentialRejected = $false
    try { [void](Test-ChatGPTRemoteProxyUrl 'http://user:password@proxy.example.test:8080') }
    catch { $credentialRejected = $true }
    if (-not $credentialRejected) { throw 'A proxy URL containing credentials was accepted.' }
    Remove-ChatGPTRemoteProxy -ConfigPath $configPath -Confirm:$false
    if (Test-Path -LiteralPath $configPath) { throw 'The protected proxy configuration was not removed.' }
    [pscustomobject]@{ ProtectedRoundTrip = $true; PlaintextAbsent = $true; CredentialsRejected = $true; SharedUserEnvironmentPreserved = $true } | ConvertTo-Json
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
