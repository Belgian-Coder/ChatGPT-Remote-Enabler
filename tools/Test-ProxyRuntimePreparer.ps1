[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$preparer = Join-Path $root 'windows\CodexRemoteSimple\runtime\prepare-proxy-runtime.js'
$contract = Join-Path $root 'windows\CodexRemoteSimple\runtime\device-key-provider-contract.cjs'
$preparerSource = Get-Content -LiteralPath $preparer -Raw
$contractSource = Get-Content -LiteralPath $contract -Raw
if (-not $preparerSource.Contains('function renameWithRetry(source, destination)') -or
    -not $preparerSource.Contains('new Set(["EACCES", "EBUSY", "EPERM"])')) {
    throw 'The proxy runtime preparer does not retry transient antivirus rename locks.'
}
foreach ($forbidden in @('signatureCounts', 'occurrenceCount', 'appAsarSha256')) {
    if ($preparerSource.Contains($forbidden) -or $contractSource.Contains($forbidden)) {
        throw "A removed version/signature/hash allowlist remains in runtime source: $forbidden"
    }
}
$node = (Get-Command node.exe -ErrorAction Stop).Source
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-proxy-runtime-test-' + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Write-FixtureAsar([string]$Path, [string]$Controller, [string]$Challenge, [string]$Provider) {
    [IO.File]::WriteAllText($Path, "prefix${Controller};${Challenge};${Provider};suffix", [Text.UTF8Encoding]::new($false))
}

function Invoke-Preparer([string]$Node, [string]$Script, [string]$Source, [string]$Version, [bool]$Proxy = $true, [bool]$Keys = $false) {
    $arguments = @('--source-app', $Source, '--package-version', $Version, '--proxy-enabled', $Proxy.ToString().ToLowerInvariant(), '--legacy-device-keys', $Keys.ToString().ToLowerInvariant())
    $output = @(& $Node $Script @arguments 2>&1)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { throw "Proxy runtime preparation failed: $($output -join ' ')" }
    return ([string]$output[0] | ConvertFrom-Json -ErrorAction Stop)
}

function Assert-PreparationFails([string]$Node, [string]$Script, [string]$Source, [string]$ExpectedMessage) {
    $savedErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Node $Script '--source-app' $Source '--package-version' 'failure-case' '--proxy-enabled' 'true' '--legacy-device-keys' 'false' 2>&1)
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    if ($LASTEXITCODE -eq 0 -or ($output -join ' ') -notmatch $ExpectedMessage) {
        throw "Expected proxy runtime preparation failure was not observed: $ExpectedMessage"
    }
    $global:LASTEXITCODE = 0
}

function Assert-FuseDisabled([string]$Path, [byte[]]$Sentinel) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    $offset = $text.IndexOf('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX', [StringComparison]::Ordinal)
    if ($offset -lt 0 -or $bytes[$offset + $Sentinel.Length + 2 + 4] -ne [byte][char]'0') {
        throw 'The private Electron runtime did not disable only the ASAR-integrity fuse.'
    }
}

try {
    $source = Join-Path $temporaryRoot 'installed-app'
    $resources = Join-Path $source 'resources'
    $profile = Join-Path $temporaryRoot 'profile'
    New-Item -ItemType Directory -Path $resources, $profile | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'ChatGPT.exe'), 'synthetic executable', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $resources 'codex.exe'), 'synthetic cli', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $resources 'preserved.txt'), 'preserved', [Text.UTF8Encoding]::new($false))

    $sentinel = [Text.Encoding]::ASCII.GetBytes('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX')
    $chrome = [Collections.Generic.List[byte]]::new()
    $chrome.AddRange([Text.Encoding]::ASCII.GetBytes('prefix'))
    $chrome.AddRange($sentinel)
    $chrome.Add(1)
    $chrome.Add(9)
    $chrome.AddRange([Text.Encoding]::ASCII.GetBytes('010011001'))
    $chrome.AddRange([Text.Encoding]::ASCII.GetBytes('suffix'))
    [IO.File]::WriteAllBytes((Join-Path $source 'chrome.dll'), $chrome.ToArray())

    # Every fixture is zero-whitespace around the semantic regions. Names,
    # method order, and unrelated product text are intentionally arbitrary.
    $controller = 'const C={authorizeDeviceKeyChallenge:a,enrollClient:b,getAuthHeaders:c,connectionKey:k,envId:e,connectionGroup:g,websocketUrl:mk(k,`/codex/remote/control/client`)}'
    $challenge = 'function check(t,u){let z=new URL(u),q=z.protocol===`wss:`?`https:`:z.protocol===`ws:`?`http:`:null;return q!=null&&t.targetOrigin===`${q}//${z.host}`&&t.targetPath===z.pathname}'
    $provider = 'const rr=(0,createRequire)(__filename),nativeBinding=`remote-control-device-key.node`;class Device{resourcesPath;addon=null;constructor(e){this.resourcesPath=e}signDeviceKey(e){return this.getAddon().signDeviceKey(e)}getDeviceKeyPublic(e){return this.getAddon().getDeviceKeyPublic(e)}deleteDeviceKey(e){return this.getAddon().deleteDeviceKey(e)}createDeviceKey(e){return this.getAddon().createDeviceKey(e)}getAddon(){return this.addon??=rr((0,join)(this.resourcesPath,`native`,nativeBinding)),this.addon}}'
    $originalLoader = 'rr((0,join)(this.resourcesPath,`native`,nativeBinding))'
    $originalController = $controller
    $originalChallenge = $challenge
    $asarPath = Join-Path $resources 'app.asar'
    Write-FixtureAsar $asarPath $controller $challenge $provider
    $sourceAsarLength = (Get-Item -LiteralPath $asarPath).Length
    $sourceAsarHash = Get-Sha256 $asarPath
    $sourceChromeHash = Get-Sha256 (Join-Path $source 'chrome.dll')

    $env:LOCALAPPDATA = $profile
    $first = Invoke-Preparer $node $preparer $source 'first-build'
    if ($first.reused -ne $false -or -not (Test-Path -LiteralPath ([string]$first.executablePath) -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path ([string]$first.runtimeRoot) 'resources\preserved.txt') -PathType Leaf)) {
        throw 'The semantic proxy fixture did not create a complete private runtime.'
    }
    if ((Get-Sha256 $asarPath) -ne $sourceAsarHash -or (Get-Sha256 (Join-Path $source 'chrome.dll')) -ne $sourceChromeHash) {
        throw 'The proxy runtime preparer modified the installed source app.'
    }
    $patchedAsarPath = [string]$first.appAsarPath
    $patchedAsar = [IO.File]::ReadAllText($patchedAsarPath)
    if ($patchedAsar.Contains($originalController) -or $patchedAsar.Contains($originalChallenge) -or
        -not $patchedAsar.Contains('process.env.CHATGPT_REMOTE_WS_URL') -or
        $patchedAsar.Contains('CHATGPT_REMOTE_WS_URL??') -or $patchedAsar.Contains('process.env.CRWU||')) {
        throw 'The zero-whitespace semantic proxy fixture was not patched with direct environment overrides.'
    }
    if ((Get-Item -LiteralPath $patchedAsarPath).Length -ne $sourceAsarLength) { throw 'The in-place proxy patch changed ASAR length.' }
    Assert-FuseDisabled (Join-Path ([string]$first.runtimeRoot) 'chrome.dll') $sentinel
    if ((Get-Sha256 (Join-Path ([string]$first.runtimeRoot) 'resources\crv.cjs')) -ne
        (Get-Sha256 (Join-Path $root 'windows\CodexRemoteSimple\runtime\remote-control-target.cjs'))) {
        throw 'The proxy runtime omitted the verified challenge target helper.'
    }

    $second = Invoke-Preparer $node $preparer $source 'renamed-build'
    if ($second.reused -ne $true -or [string]$second.runtimeRoot -ne [string]$first.runtimeRoot) {
        throw 'Changing only the diagnostic package version incorrectly changed runtime identity.'
    }
    [IO.File]::WriteAllText((Join-Path ([string]$first.runtimeRoot) 'resources\crv.cjs'), 'tampered fixture', [Text.UTF8Encoding]::new($false))
    $repairedValidator = Invoke-Preparer $node $preparer $source 'validator-repair'
    if ($repairedValidator.reused -ne $false -or
        (Get-Sha256 (Join-Path ([string]$repairedValidator.runtimeRoot) 'resources\crv.cjs')) -ne
        (Get-Sha256 (Join-Path $root 'windows\CodexRemoteSimple\runtime\remote-control-target.cjs'))) {
        throw 'A tampered challenge target helper was reused or not repaired.'
    }

    $keyOnly = Invoke-Preparer $node $preparer $source 'key-build' $false $true
    $keyAsar = [IO.File]::ReadAllText([string]$keyOnly.appAsarPath)
    if (-not $keyAsar.Contains($originalController) -or -not $keyAsar.Contains($originalChallenge) -or
        $keyAsar.Contains($originalLoader) -or -not $keyAsar.Contains('rr(this.resourcesPath+`/crk.cjs`)()')) {
        throw 'The direct existing-key mode changed network/challenge behavior or missed the semantic loader.'
    }
    if ((Get-Item -LiteralPath ([string]$keyOnly.appAsarPath)).Length -ne $sourceAsarLength) { throw 'The existing-key patch changed ASAR length.' }
    $loaderPath = Join-Path ([string]$keyOnly.runtimeRoot) 'resources\crk.cjs'
    $servicePath = Join-Path ([string]$keyOnly.runtimeRoot) 'resources\crks.cjs'
    if ((Get-Sha256 $loaderPath) -ne (Get-Sha256 (Join-Path $root 'windows\CodexRemoteSimple\runtime\legacy-device-key-compat.cjs')) -or
        (Get-Sha256 $servicePath) -ne (Get-Sha256 (Join-Path $root 'windows\CodexRemoteSimple\runtime\main-payload.js'))) {
        throw 'The private runtime omitted the exact compatibility helpers.'
    }
    $keyAgain = Invoke-Preparer $node $preparer $source 'key-build-renamed' $false $true
    if ($keyAgain.reused -ne $true -or [string]$keyAgain.runtimeRoot -ne [string]$keyOnly.runtimeRoot) { throw 'The key runtime was not reused across package-version changes.' }

    $combined = Invoke-Preparer $node $preparer $source 'combined-build' $true $true
    $combinedAsar = [IO.File]::ReadAllText([string]$combined.appAsarPath)
    if (-not $combinedAsar.Contains('process.env.CHATGPT_REMOTE_WS_URL') -or -not $combinedAsar.Contains('rr(this.resourcesPath+`/crk.cjs`)()')) { throw 'Proxy and key compatibility were not composed.' }

    $modernSource = Join-Path $temporaryRoot 'modern-installed-app'
    Copy-Item -LiteralPath $source -Destination $modernSource -Recurse
    $modernController = 'const C={getAuthHeaders:c,authorizeDeviceKeyChallenge:a,enrollClient:b,connectionGroup:g,envId:e,connectionKey:k,getHandshake(){let u=mk(k,`/codex/remote/control/client`);return{url:u}}}'
    $modernAsarPath = Join-Path $modernSource 'resources\app.asar'
    $modernAsar = [IO.File]::ReadAllText($modernAsarPath).Replace($controller, $modernController)
    [IO.File]::WriteAllText($modernAsarPath, $modernAsar, [Text.UTF8Encoding]::new($false))
    $modern = Invoke-Preparer $node $preparer $modernSource 'modern-build'
    $modernPatched = [IO.File]::ReadAllText([string]$modern.appAsarPath)
    if ($modernPatched.Contains($modernController) -or -not $modernPatched.Contains('process.env.CHATGPT_REMOTE_WS_URL') -or
        $modernPatched.Contains($challenge) -or -not $modernPatched.Contains('/crv.cjs')) {
        throw 'The modern getHandshake transport and signed challenge targets were not patched together.'
    }

    $variantSource = Join-Path $temporaryRoot 'variant-installed-app'
    Copy-Item -LiteralPath $source -Destination $variantSource -Recurse
    $variantProvider = 'let qRequire=(0,createRequire)(__filename),moduleRenamed=`remote-control-device-key.node`;class Renamed{addon=null;resourcesPath;constructor(value){this.resourcesPath=value}getDeviceKeyPublic(value){return this.getAddon().getDeviceKeyPublic(value)}createDeviceKey(value){return this.getAddon().createDeviceKey(value)}signDeviceKey(value){return this.getAddon().signDeviceKey(value)}deleteDeviceKey(value){return this.getAddon().deleteDeviceKey(value)}getAddon(){return this.addon??=qRequire((0,join)(this.resourcesPath,`native`,moduleRenamed)),this.addon}}'
    $variantAsarPath = Join-Path $variantSource 'resources\app.asar'
    $variantAsar = [IO.File]::ReadAllText($variantAsarPath).Replace($provider, $variantProvider)
    [IO.File]::WriteAllText($variantAsarPath, $variantAsar, [Text.UTF8Encoding]::new($false))
    $variant = Invoke-Preparer $node $preparer $variantSource 'renamed-minifier-build' $false $true
    $variantPatched = [IO.File]::ReadAllText([string]$variant.appAsarPath)
    if (-not $variantPatched.Contains('qRequire(this.resourcesPath+`/crk.cjs`)()')) { throw 'The renamed/reordered provider capability was not discovered.' }

    $ambiguousControllerSource = Join-Path $temporaryRoot 'ambiguous-controller-app'
    Copy-Item -LiteralPath $source -Destination $ambiguousControllerSource -Recurse
    [IO.File]::WriteAllText((Join-Path $ambiguousControllerSource 'resources\app.asar'), "$controller;$controller;$challenge", [Text.UTF8Encoding]::new($false))
    Assert-PreparationFails $node $preparer $ambiguousControllerSource 'unambiguous Remote-control WebSocket'

    $ambiguousProviderSource = Join-Path $temporaryRoot 'ambiguous-provider-app'
    Copy-Item -LiteralPath $source -Destination $ambiguousProviderSource -Recurse
    [IO.File]::WriteAllText((Join-Path $ambiguousProviderSource 'resources\app.asar'), "$controller;$challenge;$provider;$provider", [Text.UTF8Encoding]::new($false))
    $savedErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $ambiguousProviderOutput = @(& $node $preparer '--source-app' $ambiguousProviderSource '--package-version' 'ambiguous-provider' '--proxy-enabled' 'false' '--legacy-device-keys' 'true' 2>&1)
    } finally { $ErrorActionPreference = $savedErrorPreference }
    if ($LASTEXITCODE -eq 0 -or ($ambiguousProviderOutput -join ' ') -notmatch 'unambiguous device-key provider') { throw 'Ambiguous provider capability was accepted.' }
    $global:LASTEXITCODE = 0

    $malformedChallengeSource = Join-Path $temporaryRoot 'malformed-challenge-app'
    Copy-Item -LiteralPath $source -Destination $malformedChallengeSource -Recurse
    [IO.File]::WriteAllText((Join-Path $malformedChallengeSource 'resources\app.asar'), "$controller;function unrelated(a){return a};$provider", [Text.UTF8Encoding]::new($false))
    Assert-PreparationFails $node $preparer $malformedChallengeSource 'challenge/API target capability'

    [pscustomobject]@{
        SourceAppPreserved = $true
        ZeroWhitespaceSemanticPatch = $true
        ModernHandshakePlan = $true
        LegacyChallengePlan = $true
        RenamedProviderPlan = $true
        AsarLengthPreserved = $true
        PrivateFusePatched = $true
        VersionIndependentReuse = $true
        ExistingKeyLoaderPatched = $true
        ProxyAndKeyCompatibilityComposed = $true
        AmbiguousControllerRejected = $true
        AmbiguousProviderRejected = $true
        MalformedChallengeRejected = $true
        HelpersVerified = $true
        ChallengeHelperTamperRepaired = $true
    } | ConvertTo-Json -Compress
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
