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

function Get-ChatGPTRemoteProxySettingValue {
    param([Parameter(Mandatory)][object]$Settings, [Parameter(Mandatory)][string]$Name)
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ChatGPTRemoteFixedSystemProxy {
    [CmdletBinding()]
    param([object]$InternetSettings)

    if ($null -eq $InternetSettings) {
        $settingsHive = 'HKCU:'
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxySettingsPerUser -ErrorAction SilentlyContinue
        if ($null -ne $policy -and [int]$policy.ProxySettingsPerUser -eq 0) { $settingsHive = 'HKLM:' }
        $settingsPath = "$settingsHive\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $InternetSettings = Get-ItemProperty -LiteralPath $settingsPath -ErrorAction Stop
        $connections = Get-ItemProperty -LiteralPath "$settingsPath\Connections" -Name DefaultConnectionSettings -ErrorAction Stop
        $InternetSettings | Add-Member -NotePropertyName DefaultConnectionSettings -NotePropertyValue ([byte[]]$connections.DefaultConnectionSettings) -Force
    }
    $autoConfigUrl = [string](Get-ChatGPTRemoteProxySettingValue -Settings $InternetSettings -Name 'AutoConfigURL')
    $autoDetect = Get-ChatGPTRemoteProxySettingValue -Settings $InternetSettings -Name 'AutoDetect'
    $defaultConnectionSettingsValue = @(Get-ChatGPTRemoteProxySettingValue -Settings $InternetSettings -Name 'DefaultConnectionSettings')
    if ($defaultConnectionSettingsValue.Count -le 8) { return $null }
    $defaultConnectionSettings = [byte[]]$defaultConnectionSettingsValue
    $connectionFlags = [int]$defaultConnectionSettings[8]
    if (-not [string]::IsNullOrWhiteSpace($autoConfigUrl) -or ($connectionFlags -band 0x04) -ne 0) { return $null }
    $proxyEnabled = Get-ChatGPTRemoteProxySettingValue -Settings $InternetSettings -Name 'ProxyEnable'
    if ($null -eq $proxyEnabled -or [int]$proxyEnabled -ne 1 -or ($connectionFlags -band 0x02) -eq 0) { return $null }
    $proxyServer = [string](Get-ChatGPTRemoteProxySettingValue -Settings $InternetSettings -Name 'ProxyServer')
    if ([string]::IsNullOrWhiteSpace($proxyServer)) { return $null }

    $endpoints = @{}
    foreach ($segment in $proxyServer.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $segment.Split('=', 2)
        if ($parts.Count -eq 2) { $endpoints[$parts[0].Trim().ToLowerInvariant()] = $parts[1].Trim() }
        elseif (-not $endpoints.ContainsKey('default')) { $endpoints.default = $segment.Trim() }
    }
    $endpoint = if ($endpoints.ContainsKey('https')) { $endpoints.https } elseif ($endpoints.ContainsKey('http')) { $endpoints.http } else { $endpoints.default }
    if ([string]::IsNullOrWhiteSpace([string]$endpoint)) { return $null }
    if ([string]$endpoint -notmatch '^[a-z][a-z0-9+.-]*://') { $endpoint = 'http://' + [string]$endpoint }
    return Test-ChatGPTRemoteProxyUrl -ProxyUrl ([string]$endpoint)
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
        try {
            $systemProxy = Get-ChatGPTRemoteFixedSystemProxy
            if (-not [string]::IsNullOrWhiteSpace($systemProxy)) { return $systemProxy }
        } catch {
            # A PAC or unavailable system proxy is not a fixed endpoint that the
            # protected CONNECT bridge can safely reuse for every destination.
        }
    }

    throw 'Proxy mode was requested, but no protected, environment, or fixed Windows system proxy exists.'
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
