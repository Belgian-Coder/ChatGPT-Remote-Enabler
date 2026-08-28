Set-StrictMode -Version Latest

$script:DefaultProxyConfigPath = Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures\remote-proxy.dpapi'

function Test-ChatGPTRemoteProxyUrl {
    param([Parameter(Mandatory)][string]$ProxyUrl)

    $uri = $null
    if (-not [Uri]::TryCreate($ProxyUrl.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or
        [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw 'The proxy must be an absolute http:// or https:// URL.'
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw 'Proxy URLs containing credentials are not supported.'
    }
    if ($uri.AbsolutePath -notin @('', '/') -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw 'The proxy URL may contain only a scheme, host, and optional port.'
    }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

function Get-ChatGPTRemoteProxy {
    [CmdletBinding()]
    param(
        [string]$ConfigPath = $script:DefaultProxyConfigPath,
        [switch]$AllowEnvironmentFallback
    )

    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        $cipherText = (Get-Content -LiteralPath $ConfigPath -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($cipherText)) { throw 'The protected Remote proxy configuration is empty.' }
        $secure = ConvertTo-SecureString $cipherText
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            return Test-ChatGPTRemoteProxyUrl -ProxyUrl $plainText
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            if ($plainText) { $plainText = $null }
        }
    }

    if ($AllowEnvironmentFallback) {
        foreach ($scope in @('Process', 'User')) {
            foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
                $candidate = [Environment]::GetEnvironmentVariable($name, $scope)
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    return Test-ChatGPTRemoteProxyUrl -ProxyUrl $candidate
                }
            }
        }
    }

    throw 'Proxy mode was requested, but no protected Remote proxy configuration exists.'
}

function Set-ChatGPTRemoteProxy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ProxyUrl,
        [string]$ConfigPath = $script:DefaultProxyConfigPath
    )

    $normalized = Test-ChatGPTRemoteProxyUrl -ProxyUrl $ProxyUrl
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'store a DPAPI-protected Remote proxy configuration')) { return }
    $parent = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $secure = ConvertTo-SecureString $normalized -AsPlainText -Force
    $cipherText = ConvertFrom-SecureString $secure
    [IO.File]::WriteAllText($ConfigPath, "$cipherText$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
}

function Remove-ChatGPTRemoteProxy {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ConfigPath = $script:DefaultProxyConfigPath)

    if ((Test-Path -LiteralPath $ConfigPath -PathType Leaf) -and
        $PSCmdlet.ShouldProcess($ConfigPath, 'remove the protected Remote proxy configuration')) {
        Remove-Item -LiteralPath $ConfigPath -Force
    }
}

function Get-ChatGPTRemoteProxyConfigPath {
    return $script:DefaultProxyConfigPath
}

Export-ModuleMember -Function Get-ChatGPTRemoteProxy,Set-ChatGPTRemoteProxy,Remove-ChatGPTRemoteProxy,Get-ChatGPTRemoteProxyConfigPath,Test-ChatGPTRemoteProxyUrl
