[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$node = (Get-Command node.exe -ErrorAction Stop).Source
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('remote-legacy-bootstrap-' + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA
try {
    $bundle = Join-Path $temporary 'CodexRemoteMobileProject'
    $env:LOCALAPPDATA = Join-Path $temporary 'user-state'
    $stateFolder = Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures'
    New-Item -ItemType Directory -Path $bundle,$stateFolder -Force | Out-Null
    $controller = Join-Path $bundle 'MobileProjectView.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'windows\CodexRemoteMobileProject\MobileProjectView.ps1') -Destination $controller
    [IO.File]::WriteAllText((Join-Path $bundle 'inject.js'), 'process.stdout.write(JSON.stringify({report:{ready:true}}));', [Text.UTF8Encoding]::new($false))
    $launcher = @'
param($InstallRoot,$EntryPointRelative,$NodePath,[switch]$UseProxy)
$call = @{entry=$EntryPointRelative;proxy=[bool]$UseProxy;root=[IO.Path]::GetFileName($InstallRoot)} | ConvertTo-Json -Compress
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'calls.jsonl') -Value $call
'@
    [IO.File]::WriteAllText((Join-Path $bundle 'UpdateSessionLauncher.ps1'), $launcher, [Text.UTF8Encoding]::new($false))
    $statePath = Join-Path $stateFolder 'codexremote-simple-session.json'
    [IO.File]::WriteAllText($statePath, '{"rendererPort":12345,"proxyMode":true}', [Text.UTF8Encoding]::new($false))
    & $controller -Action Enable -NodePath $node -Confirm:$false | Out-Null
    & $controller -Action Probe -NodePath $node | Out-Null
    & $controller -Action Enable -NodePath $node -DeferUpdateSession -Confirm:$false | Out-Null
    $calls = @(Get-Content -LiteralPath (Join-Path $bundle 'calls.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    if ($calls.Count -ne 1 -or $calls[0].proxy -ne $true -or $calls[0].entry -cne 'CodexRemoteMobileProject\MobileProjectStartup.ps1') { throw 'Legacy bootstrap or current-launcher deferral failed.' }
    [IO.File]::WriteAllText($statePath, '{"rendererPort":12345,"proxyMode":false}', [Text.UTF8Encoding]::new($false))
    & $controller -Action Enable -NodePath $node -Confirm:$false | Out-Null
    [IO.File]::WriteAllText($statePath, '{"rendererPort":12345,"proxyMode":"unknown"}', [Text.UTF8Encoding]::new($false))
    & $controller -Action Enable -NodePath $node -Confirm:$false -WarningVariable warning -WarningAction SilentlyContinue | Out-Null
    $calls = @(Get-Content -LiteralPath (Join-Path $bundle 'calls.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    if ($calls.Count -ne 2 -or $calls[1].proxy -ne $false -or -not ([string]$warning -match 'exact proxy mode')) { throw 'Proxy mode must be preserved or fail closed.' }
    [pscustomobject]@{ LegacyEnableStartsUpdateHelper = $true; CurrentCoordinatorDefers = $true; ProbeReadOnly = $true; ProxyModePreserved = $true; UnknownProxyFailsClosed = $true } | ConvertTo-Json -Compress
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $resolved = [IO.Path]::GetFullPath($temporary)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^remote-legacy-bootstrap-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
