[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Install', 'Remove', 'Probe')]
    [string]$Action = 'Probe',
    [string]$ProxyUrl,
    [switch]$ImportUserEnvironment,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'ProxyConfiguration.psm1'
Import-Module $modulePath -Force
if (-not $ConfigPath) { $ConfigPath = Get-ChatGPTRemoteProxyConfigPath }

function Get-UserEnvironmentProxy {
    foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $candidate = [Environment]::GetEnvironmentVariable($name, 'User')
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
    }
    throw 'No User-scope HTTPS_PROXY or HTTP_PROXY value is available to import.'
}

function Get-Probe {
    $configured = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    $usable = $false
    $scheme = $null
    $port = $null
    if ($configured) {
        try {
            $uri = [Uri](Get-ChatGPTRemoteProxy -ConfigPath $ConfigPath)
            $usable = $true
            $scheme = $uri.Scheme
            $port = $uri.Port
        } catch {}
    }
    return [ordered]@{
        configPath = $ConfigPath
        configured = $configured
        usable = $usable
        scheme = $scheme
        port = $port
        userHttpProxyPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User'))
        userHttpsProxyPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User'))
    }
}

switch ($Action) {
    'Install' {
        if ($ImportUserEnvironment) {
            if ($ProxyUrl) { throw 'Specify either -ProxyUrl or -ImportUserEnvironment, not both.' }
            $ProxyUrl = Get-UserEnvironmentProxy
        }
        if ([string]::IsNullOrWhiteSpace($ProxyUrl)) { throw 'Install requires -ProxyUrl or -ImportUserEnvironment.' }
        Set-ChatGPTRemoteProxy -ProxyUrl $ProxyUrl -ConfigPath $ConfigPath -Confirm:$false
        Get-Probe | ConvertTo-Json -Depth 3
    }
    'Remove' {
        Remove-ChatGPTRemoteProxy -ConfigPath $ConfigPath -Confirm:$false
        Get-Probe | ConvertTo-Json -Depth 3
    }
    'Probe' { Get-Probe | ConvertTo-Json -Depth 3 }
}
