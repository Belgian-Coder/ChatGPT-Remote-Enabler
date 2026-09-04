[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$preparer = Join-Path $root 'windows\CodexRemoteSimple\runtime\prepare-proxy-runtime.js'
$preparerSource = Get-Content -LiteralPath $preparer -Raw
if (-not $preparerSource.Contains('function renameWithRetry(source, destination)') -or
    -not $preparerSource.Contains('new Set(["EACCES", "EBUSY", "EPERM"])')) {
    throw 'The proxy runtime preparer does not retry transient antivirus rename locks.'
}
$node = (Get-Command node.exe -ErrorAction Stop).Source
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-proxy-runtime-test-' + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA

try {
    $source = Join-Path $temporaryRoot 'installed-app'
    $resources = Join-Path $source 'resources'
    $profile = Join-Path $temporaryRoot 'profile'
    New-Item -ItemType Directory -Path $resources,$profile | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'ChatGPT.exe'), 'synthetic executable', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $resources 'extra-resource.txt'), 'preserved', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $resources 'codex.exe'), 'synthetic cli', [Text.UTF8Encoding]::new($false))

    $sentinel = [Text.Encoding]::ASCII.GetBytes('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX')
    $chrome = [Collections.Generic.List[byte]]::new()
    $chrome.AddRange([Text.Encoding]::ASCII.GetBytes('prefix'))
    $chrome.AddRange($sentinel)
    $chrome.Add(1)
    $chrome.Add(9)
    $chrome.AddRange([Text.Encoding]::ASCII.GetBytes('010011001'))
    $chrome.AddRange([Text.Encoding]::ASCII.GetBytes('suffix'))
    [IO.File]::WriteAllBytes((Join-Path $source 'chrome.dll'), $chrome.ToArray())

    $originalController = 'Tle=class extends n.$t{constructor(e){let t=wC(e.desktopApiOptions),i=e.globalState,a=e.deviceKeyClient;super({envId:e.hostConfig.env_id,connectionGroup:e.appServerClient,connectionKey:t,websocketUrl:n.en(r.H(e.desktopApiOptions,`/codex/remote/control/client`)),getAuthHeaders:({headers:t}={})=>EC({appServerClient:e.appServerClient,desktopApiOptions:e.desktopApiOptions,headers:t}),enrollClient:({headers:n})=>DC({appServerClient:e.appServerClient,deviceKeyClient:a,desktopApiOptions:e.desktopApiOptions,enrollmentKey:t,globalState:i,headers:n,onEnrollmentAuthorizationRequired:e.onEnrollmentAuthorizationRequired,requestRemoteControlEnrollmentStepUpToken:e.requestRemoteControlEnrollmentStepUpToken}),authorizeDeviceKeyChallenge:e=>Yle({challenge:e,deviceKeyClient:a,enrollmentKey:t,globalState:i})})}}'
    $originalChallengeValidator = 'function vQ(e,t){let n=new URL(t),r=n.protocol===`wss:`?`https:`:n.protocol===`ws:`?`http:`:null;return r!=null&&e.targetOrigin===`${r}//${n.host}`&&e.targetPath===n.pathname}'
    [IO.File]::WriteAllText((Join-Path $resources 'app.asar'), "header${originalController};async function Ele;${originalChallengeValidator};trailer", [Text.UTF8Encoding]::new($false))
    $sourceAsarHash = (Get-FileHash -LiteralPath (Join-Path $resources 'app.asar') -Algorithm SHA256).Hash
    $sourceChromeHash = (Get-FileHash -LiteralPath (Join-Path $source 'chrome.dll') -Algorithm SHA256).Hash

    $env:LOCALAPPDATA = $profile
    $output = @(& $node $preparer '--source-app' $source '--package-version' '1.2.3.4' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { throw "Proxy runtime preparer failed: $($output -join ' ')" }
    $result = [string]$output[0] | ConvertFrom-Json -ErrorAction Stop
    if ($result.reused -isnot [bool] -or $result.reused -or
        -not (Test-Path -LiteralPath ([string]$result.executablePath) -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path ([string]$result.runtimeRoot) 'resources\extra-resource.txt') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path ([string]$result.runtimeRoot) 'resources\codex.exe') -PathType Leaf)) {
        throw 'The proxy runtime preparer did not create a complete private runtime.'
    }
    if ((Get-FileHash -LiteralPath (Join-Path $resources 'app.asar') -Algorithm SHA256).Hash -ne $sourceAsarHash -or
        (Get-FileHash -LiteralPath (Join-Path $source 'chrome.dll') -Algorithm SHA256).Hash -ne $sourceChromeHash) {
        throw 'The proxy runtime preparer modified the installed source app.'
    }
    $patchedAsar = Get-Content -LiteralPath ([string]$result.appAsarPath) -Raw
    if ($patchedAsar.Contains($originalController) -or $patchedAsar.Contains($originalChallengeValidator) -or
        -not $patchedAsar.Contains('process.env.CHATGPT_REMOTE_WS_URL??') -or
        -not $patchedAsar.Contains('process.env.CRWU||t')) {
        throw 'The private ASAR does not contain the scoped Remote-control URL and challenge-target overrides.'
    }
    if ((Get-Item -LiteralPath ([string]$result.appAsarPath)).Length -ne (Get-Item -LiteralPath (Join-Path $resources 'app.asar')).Length) {
        throw 'The in-place private ASAR patch changed the archive length.'
    }
    $patchedChrome = [IO.File]::ReadAllBytes((Join-Path ([string]$result.runtimeRoot) 'chrome.dll'))
    $sentinelOffset = [Text.Encoding]::ASCII.GetString($patchedChrome).IndexOf('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX', [StringComparison]::Ordinal)
    if ($sentinelOffset -lt 0 -or $patchedChrome[$sentinelOffset + $sentinel.Length + 2 + 4] -ne [byte][char]'0') {
        throw 'The private Electron runtime did not disable only the ASAR-integrity fuse.'
    }

    $secondOutput = @(& $node $preparer '--source-app' $source '--package-version' '1.2.3.4' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $secondOutput.Count -ne 1 -or -not ([bool](([string]$secondOutput[0] | ConvertFrom-Json).reused))) {
        throw 'The verified private proxy runtime was not reused.'
    }

    [pscustomobject]@{
        SourceAppPreserved = $true
        ScopedControllerPatched = $true
        ScopedChallengeTargetPatched = $true
        AsarLengthPreserved = $true
        PrivateFusePatched = $true
        PrivateCliPreserved = $true
        TransientRenameRetried = $true
        VerifiedRuntimeReused = $true
    } | ConvertTo-Json
} finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolved) -and
        [IO.Path]::GetFullPath((Split-Path -Parent $resolved)) -eq $temporary -and
        [IO.Path]::GetFileName($resolved) -match '^chatgpt-proxy-runtime-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
