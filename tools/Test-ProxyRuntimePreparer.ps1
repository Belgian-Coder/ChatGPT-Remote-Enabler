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
    $nextController = 'ole=class extends n.$t{constructor(e){let t=dC(e.desktopApiOptions),i=e.globalState,a=e.deviceKeyClient;super({envId:e.hostConfig.env_id,connectionGroup:e.appServerClient,connectionKey:t,websocketUrl:n.en(r.X(e.desktopApiOptions,`/codex/remote/control/client`)),getAuthHeaders:({headers:t}={})=>pC({appServerClient:e.appServerClient,desktopApiOptions:e.desktopApiOptions,headers:t}),enrollClient:({headers:n})=>mC({appServerClient:e.appServerClient,deviceKeyClient:a,desktopApiOptions:e.desktopApiOptions,enrollmentKey:t,globalState:i,headers:n,onEnrollmentAuthorizationRequired:e.onEnrollmentAuthorizationRequired,requestRemoteControlEnrollmentStepUpToken:e.requestRemoteControlEnrollmentStepUpToken}),authorizeDeviceKeyChallenge:e=>Ale({challenge:e,deviceKeyClient:a,enrollmentKey:t,globalState:i})})}}'
    $nextChallengeValidator = 'function pQ(e,t){let n=new URL(t),r=n.protocol===`wss:`?`https:`:n.protocol===`ws:`?`http:`:null;return r!=null&&e.targetOrigin===`${r}//${n.host}`&&e.targetPath===n.pathname}'
    $currentKeyLoader = 'return this.addon??=Xke((0,p.join)(this.resourcesPath,`native`,Zke)),this.addon'
    $currentKeyProvider = 'var Xke=(0,F.createRequire)(__filename),Zke=`remote-control-device-key.node`,Qke=`codex-device-key-sign-payload/v1`;$ke=class{resourcesPath;addon=null;constructor(e){this.resourcesPath=e}createDeviceKey(e){return this.getAddon().createDeviceKey(e??`hardware_only`)}deleteDeviceKey(e){return this.getAddon().deleteDeviceKey(e)}getDeviceKeyPublic(e){return this.getAddon().getDeviceKeyPublic(e)}async signDeviceKey(e,t){let n=eAe(t);return{...await this.getAddon().signDeviceKey(e,n),signedPayloadBase64:n.toString(`base64`)}}getAddon(){if(process.platform!==`darwin`&&process.platform!==`win32`)throw Error(`Remote control device keys are only available on macOS and Windows`);if(this.resourcesPath==null)throw Error(`Remote control device keys require resourcesPath`);return this.addon??=Xke((0,p.join)(this.resourcesPath,`native`,Zke)),this.addon}}'
    $legacyKeyLoader = 'return this.addon??=Yke((0,p.join)(this.resourcesPath,`native`,Xke)),this.addon'
    $legacyKeyProvider = 'var Yke=(0,F.createRequire)(__filename),Xke=`remote-control-device-key.node`,Qke=`codex-device-key-sign-payload/v1`;$ke=class{resourcesPath;addon=null;constructor(e){this.resourcesPath=e}createDeviceKey(e){return this.getAddon().createDeviceKey(e??`hardware_only`)}deleteDeviceKey(e){return this.getAddon().deleteDeviceKey(e)}getDeviceKeyPublic(e){return this.getAddon().getDeviceKeyPublic(e)}async signDeviceKey(e,t){let n=eAe(t);return{...await this.getAddon().signDeviceKey(e,n),signedPayloadBase64:n.toString(`base64`)}}getAddon(){if(process.platform!==`darwin`&&process.platform!==`win32`)throw Error(`Remote control device keys are only available on macOS and Windows`);if(this.resourcesPath==null)throw Error(`Remote control device keys require resourcesPath`);return this.addon??=Yke((0,p.join)(this.resourcesPath,`native`,Xke)),this.addon}}'
    [IO.File]::WriteAllText((Join-Path $resources 'app.asar'), "header${originalController};async function Ele;${originalChallengeValidator};${currentKeyProvider};trailer", [Text.UTF8Encoding]::new($false))
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

    $keyOutput = @(& $node $preparer '--source-app' $source '--package-version' '1.2.3.4' '--proxy-enabled' 'false' '--legacy-device-keys' 'true' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $keyOutput.Count -ne 1) { throw "Existing-key runtime preparation failed: $($keyOutput -join ' ')" }
    $keyResult = [string]$keyOutput[0] | ConvertFrom-Json
    $keyAsar = Get-Content -LiteralPath ([string]$keyResult.appAsarPath) -Raw
    if (-not $keyAsar.Contains($originalController) -or -not $keyAsar.Contains($originalChallengeValidator) -or
        $keyAsar.Contains($currentKeyLoader) -or -not $keyAsar.Contains('Xke(this.resourcesPath+`/crk.cjs`)()')) {
        throw 'Direct existing-key compatibility must change only the native key loader, preserving network and challenge validation.'
    }
    if ((Get-Item -LiteralPath ([string]$keyResult.appAsarPath)).Length -ne (Get-Item -LiteralPath (Join-Path $resources 'app.asar')).Length) { throw 'The existing-key patch changed ASAR length.' }
    $keyLoader = Join-Path ([string]$keyResult.runtimeRoot) 'resources\crk.cjs'
    $keyService = Join-Path ([string]$keyResult.runtimeRoot) 'resources\crks.cjs'
    if ((Get-FileHash -LiteralPath $keyLoader).Hash -ne (Get-FileHash -LiteralPath (Join-Path $root 'windows\CodexRemoteSimple\runtime\legacy-device-key-compat.cjs')).Hash -or
        (Get-FileHash -LiteralPath $keyService).Hash -ne (Get-FileHash -LiteralPath (Join-Path $root 'windows\CodexRemoteSimple\runtime\main-payload.js')).Hash) { throw 'The private runtime omitted the exact compatibility helpers.' }
    $keyAgain = @(& $node $preparer '--source-app' $source '--package-version' '1.2.3.4' '--proxy-enabled' 'false' '--legacy-device-keys' 'true' 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not ([bool](([string]$keyAgain[0] | ConvertFrom-Json).reused))) { throw 'The verified existing-key runtime was not reused.' }
    Add-Content -LiteralPath $keyLoader -Value '// fixture modification'
    $keyRepaired = @(& $node $preparer '--source-app' $source '--package-version' '1.2.3.4' '--proxy-enabled' 'false' '--legacy-device-keys' 'true' 2>&1)
    if ($LASTEXITCODE -ne 0 -or ([bool](([string]$keyRepaired[0] | ConvertFrom-Json).reused))) { throw 'A modified compatibility helper was incorrectly reused.' }
    $combined = @(& $node $preparer '--source-app' $source '--package-version' '1.2.3.4' '--proxy-enabled' 'true' '--legacy-device-keys' 'true' 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Combined compatibility preparation failed: $($combined -join ' ')" }
    $combinedResult = [string]$combined[0] | ConvertFrom-Json
    $combinedAsar = Get-Content -LiteralPath ([string]$combinedResult.appAsarPath) -Raw
    if (-not $combinedAsar.Contains('Xke(this.resourcesPath+`/crk.cjs`)()') -or -not $combinedAsar.Contains('process.env.CHATGPT_REMOTE_WS_URL??')) { throw 'Proxy and existing-key compatibility were not composed.' }

    $nextSource = Join-Path $temporaryRoot 'next-installed-app'
    Copy-Item -LiteralPath $source -Destination $nextSource -Recurse
    $nextChromePath = Join-Path $nextSource 'chrome.dll'
    $nextChrome = [IO.File]::ReadAllBytes($nextChromePath)
    $nextSentinelOffset = [Text.Encoding]::ASCII.GetString($nextChrome).IndexOf('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX', [StringComparison]::Ordinal)
    $nextChrome[$nextSentinelOffset + $sentinel.Length + 2 + 4] = [byte][char]'0'
    [IO.File]::WriteAllBytes($nextChromePath, $nextChrome)
    $nextAsarPath = Join-Path $nextSource 'resources\app.asar'
    $nextAsar = (Get-Content -LiteralPath $nextAsarPath -Raw).Replace($originalController, $nextController).Replace($originalChallengeValidator, $nextChallengeValidator)
    [IO.File]::WriteAllText($nextAsarPath, $nextAsar, [Text.UTF8Encoding]::new($false))
    $nextOutput = @(& $node $preparer '--source-app' $nextSource '--package-version' '1.2.3.7' '--proxy-enabled' 'true' '--legacy-device-keys' 'false' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $nextOutput.Count -ne 1) { throw "Next ChatGPT signature preparation failed: $($nextOutput -join ' ')" }
    $nextResult = [string]$nextOutput[0] | ConvertFrom-Json
    $nextPatchedAsar = Get-Content -LiteralPath ([string]$nextResult.appAsarPath) -Raw
    if ($nextPatchedAsar.Contains($nextController) -or $nextPatchedAsar.Contains($nextChallengeValidator) -or
        -not $nextPatchedAsar.Contains('process.env.CHATGPT_REMOTE_WS_URL??') -or
        -not $nextPatchedAsar.Contains('function pQ(e,t){let n=new URL(process.env.CRWU||t)')) {
        throw 'The next audited ChatGPT signatures were not patched.'
    }

    # Current native-renderer builds may already ship with embedded-ASAR
    # integrity disabled. Existing protected enrollments still require the
    # direct, no-proxy compatibility runtime; that exact combination must not
    # regress to the pre-v1.5.57 fuse rejection.
    $nextKeyOutput = @(& $node $preparer '--source-app' $nextSource '--package-version' '1.2.3.8' '--proxy-enabled' 'false' '--legacy-device-keys' 'true' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $nextKeyOutput.Count -ne 1) { throw "Disabled-fuse existing-key runtime preparation failed: $($nextKeyOutput -join ' ')" }
    $nextKeyResult = [string]$nextKeyOutput[0] | ConvertFrom-Json
    $nextKeyAsar = Get-Content -LiteralPath ([string]$nextKeyResult.appAsarPath) -Raw
    if (-not $nextKeyAsar.Contains($nextController) -or -not $nextKeyAsar.Contains($nextChallengeValidator) -or
        $nextKeyAsar.Contains($currentKeyLoader) -or -not $nextKeyAsar.Contains('Xke(this.resourcesPath+`/crk.cjs`)()')) {
        throw 'Disabled-fuse existing-key preparation did not preserve network behavior and patch only the audited key loader.'
    }
    foreach ($helper in @('crk.cjs', 'crks.cjs')) {
        if (-not (Test-Path -LiteralPath (Join-Path ([string]$nextKeyResult.runtimeRoot) "resources\$helper") -PathType Leaf)) {
            throw "Disabled-fuse existing-key preparation omitted $helper."
        }
    }

    $legacySource = Join-Path $temporaryRoot 'legacy-installed-app'
    Copy-Item -LiteralPath $source -Destination $legacySource -Recurse
    $legacyAsarPath = Join-Path $legacySource 'resources\app.asar'
    $legacyAsar = (Get-Content -LiteralPath $legacyAsarPath -Raw).Replace($currentKeyProvider, $legacyKeyProvider)
    [IO.File]::WriteAllText($legacyAsarPath, $legacyAsar, [Text.UTF8Encoding]::new($false))
    $legacyOutput = @(& $node $preparer '--source-app' $legacySource '--package-version' '1.2.3.5' '--proxy-enabled' 'false' '--legacy-device-keys' 'true' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $legacyOutput.Count -ne 1) { throw "Legacy minifier fixture failed: $($legacyOutput -join ' ')" }
    $legacyResult = [string]$legacyOutput[0] | ConvertFrom-Json
    $legacyPatchedAsar = Get-Content -LiteralPath ([string]$legacyResult.appAsarPath) -Raw
    if ($legacyPatchedAsar.Contains($legacyKeyLoader) -or -not $legacyPatchedAsar.Contains('Yke(this.resourcesPath+`/crk.cjs`)()')) {
        throw 'The audited legacy minifier signature was not patched with its own require binding.'
    }

    $mismatchedSource = Join-Path $temporaryRoot 'mismatched-installed-app'
    Copy-Item -LiteralPath $source -Destination $mismatchedSource -Recurse
    $mismatchedAsarPath = Join-Path $mismatchedSource 'resources\app.asar'
    $mismatchedProvider = $currentKeyProvider.Replace($currentKeyLoader, $currentKeyLoader.Replace('=Xke(', '=Rke('))
    [IO.File]::WriteAllText($mismatchedAsarPath, $mismatchedProvider, [Text.UTF8Encoding]::new($false))
    $savedErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $mismatchedOutput = @(& $node $preparer '--source-app' $mismatchedSource '--package-version' '1.2.3.6' '--proxy-enabled' 'false' '--legacy-device-keys' 'true' 2>&1)
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    if ($LASTEXITCODE -eq 0 -or ($mismatchedOutput -join ' ') -notmatch 'does not contain the audited existing protected device-key loader signature') {
        throw 'A loader whose require binding did not match the audited native provider identity was accepted.'
    }
    # The rejected child is the expected result, not this fixture's exit code.
    $global:LASTEXITCODE = 0

    [pscustomobject]@{
        SourceAppPreserved = $true
        ScopedControllerPatched = $true
        ScopedChallengeTargetPatched = $true
        AsarLengthPreserved = $true
        PrivateFusePatched = $true
        PrivateCliPreserved = $true
        TransientRenameRetried = $true
        VerifiedRuntimeReused = $true
        ExistingKeyLoaderPatched = $true
        CurrentMinifierSignaturePatched = $true
        LegacyMinifierSignaturePatched = $true
        MismatchedRequireBindingRejected = $true
        DirectNetworkAndChallengesPreserved = $true
        ExistingKeyHelpersVerified = $true
        ModifiedHelperRebuilt = $true
        ProxyAndKeyCompatibilityComposed = $true
        PreviousAndNextChatGPTSignaturesPatched = $true
        EnabledAndDisabledAsarFusesSupported = $true
        DisabledFuseExistingKeyCompatibility = $true
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
