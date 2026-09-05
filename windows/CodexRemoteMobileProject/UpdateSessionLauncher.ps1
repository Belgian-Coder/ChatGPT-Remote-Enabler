[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallRoot,
    [Parameter(Mandatory)]
    [ValidateSet('Enable-ChatGPTRemote.ps1', 'CodexRemoteMobileProject\MobileProjectStartup.ps1')]
    [string]$EntryPointRelative,
    [string]$NodePath,
    [switch]$UseProxy,
    [switch]$ReplaceRunningApp,
    [switch]$SkipInitialCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$stateRoot = Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update-sessions'
$stableStatePath = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexRemoteFeatures') 'codexremote-simple-session.json'

function Resolve-UpdateSessionNode {
    if ($NodePath -and (Test-Path -LiteralPath $NodePath -PathType Leaf)) { return [IO.Path]::GetFullPath($NodePath) }
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    foreach ($candidate in @(
        $(if ($command) { $command.Source }),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        'C:\Program Files\nodejs\node.exe'
    ) | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        & $candidate -e 'process.exit(parseInt(process.versions.node) >= 22 && globalThis.WebSocket ? 0 : 1)' 2>$null
        if ($LASTEXITCODE -eq 0) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw 'Node.js 22 or newer with built-in WebSocket support was not found for the update session.'
}

function Get-ExactAppIdentity {
    if (-not (Test-Path -LiteralPath $stableStatePath -PathType Leaf)) {
        throw 'The stable special-session record is missing after launch.'
    }
    $state = Get-Content -LiteralPath $stableStatePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $port = 0
    if (-not [int]::TryParse([string]$state.rendererPort, [ref]$port) -or $port -lt 1024 -or $port -gt 65535 -or
        [string]::IsNullOrWhiteSpace([string]$state.executablePath)) {
        throw 'The stable special-session record does not identify a renderer and executable.'
    }
    $expectedPath = [IO.Path]::GetFullPath([string]$state.executablePath)
    $candidates = @(
        Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction Stop |
            Where-Object {
                [string]::Equals([string]$_.ExecutablePath, $expectedPath, [StringComparison]::OrdinalIgnoreCase) -and
                [string]$_.CommandLine -notmatch '(?:^|\s)--type=' -and
                [string]$_.CommandLine -match "(?:^|\s)--remote-debugging-port(?:=|\s+)$port(?:\s|$)"
            }
    )
    if ($candidates.Count -ne 1) { throw "Expected one exact ChatGPT application process for renderer port $port; found $($candidates.Count)." }
    $process = [Diagnostics.Process]::GetProcessById([int]$candidates[0].ProcessId)
    try {
        $actualPath = [IO.Path]::GetFullPath($process.MainModule.FileName)
        if (-not [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The exact ChatGPT process path changed during update-session capture.'
        }
        return [pscustomobject][ordered]@{
            pid = $process.Id
            startTimeFileTimeUtc = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
            executablePath = $actualPath
            rendererPort = $port
        }
    } finally {
        $process.Dispose()
    }
}

function Copy-ImmutableUpdateSessionBundle {
    param([string]$Node)
    $sources = [ordered]@{
        'update-session.js' = Join-Path $sourceRoot 'update-session.js'
        'update-session-cdp.js' = Join-Path $sourceRoot 'update-session-cdp.js'
        'UpdateSessionPlatform.ps1' = Join-Path $sourceRoot 'UpdateSessionPlatform.ps1'
        'cdp.js' = Join-Path $InstallRoot 'CodexRemoteSimple\runtime\lib\cdp.js'
        'Update-ChatGPTRemote.ps1' = Join-Path $InstallRoot 'Update-ChatGPTRemote.ps1'
        'update-transaction.js' = Join-Path $InstallRoot 'update-transaction.js'
    }
    foreach ($source in $sources.Values) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Update-session dependency is missing: $source" }
    }
    $fingerprint = foreach ($entry in $sources.GetEnumerator()) {
        "$($entry.Key):$((Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash.ToLowerInvariant())"
    }
    $fingerprintPath = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-session-fingerprint-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($fingerprintPath, ($fingerprint -join "`n"), [Text.UTF8Encoding]::new($false))
        $bundleHash = (Get-FileHash -LiteralPath $fingerprintPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally {
        Remove-Item -LiteralPath $fingerprintPath -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $destination = Join-Path (Join-Path $stateRoot 'bundles') $bundleHash
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        $temporary = Join-Path (Join-Path $stateRoot 'bundles') ('.pending-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporary -Force | Out-Null
        try {
            foreach ($entry in $sources.GetEnumerator()) {
                Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $temporary $entry.Key)
                $actual = (Get-FileHash -LiteralPath (Join-Path $temporary $entry.Key) -Algorithm SHA256).Hash
                $expected = (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash
                if ($actual -ne $expected) { throw "Detached update-session copy verification failed: $($entry.Key)" }
            }
            try { Move-Item -LiteralPath $temporary -Destination $destination -ErrorAction Stop }
            catch {
                if (-not (Test-Path -LiteralPath $destination -PathType Container)) { throw }
            }
        } finally {
            if ((Test-Path -LiteralPath $temporary -PathType Container) -and
                [IO.Path]::GetFullPath((Split-Path -Parent $temporary)) -eq [IO.Path]::GetFullPath((Join-Path $stateRoot 'bundles')) -and
                [IO.Path]::GetFileName($temporary) -match '^\.pending-[0-9a-f]{32}$') {
                Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    foreach ($entry in $sources.GetEnumerator()) {
        $copied = Join-Path $destination $entry.Key
        if (-not (Test-Path -LiteralPath $copied -PathType Leaf) -or
            (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash) {
            throw "Detached update-session bundle is incomplete: $($entry.Key)"
        }
    }
    return $destination
}

$node = Resolve-UpdateSessionNode
$identity = Get-ExactAppIdentity
$bundle = Copy-ImmutableUpdateSessionBundle -Node $node
$sessionDirectory = Join-Path (Join-Path $stateRoot 'sessions') ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null
$configPath = Join-Path $sessionDirectory 'session.json'
$autoDisabled = $env:CHATGPT_REMOTE_AUTO_UPDATE -match '^(?:0|false|off|no)$' -or
    (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $stateRoot) 'update\auto-update-disabled') -PathType Leaf)
$config = [ordered]@{
    schemaVersion = 1
    platform = 'win32'
    installRoot = $InstallRoot
    stateRoot = $stateRoot
    sessionDirectory = $sessionDirectory
    updaterPath = Join-Path $bundle 'Update-ChatGPTRemote.ps1'
    platformHelperPath = Join-Path $bundle 'UpdateSessionPlatform.ps1'
    rendererPort = $identity.rendererPort
    autoCheckEnabled = -not $autoDisabled
    skipInitialCheck = [bool]$SkipInitialCheck
    logPath = Join-Path $sessionDirectory 'update-session.log'
    app = [ordered]@{
        pid = $identity.pid
        startTimeFileTimeUtc = [string]$identity.startTimeFileTimeUtc
        executablePath = $identity.executablePath
    }
    relaunch = [ordered]@{
        entryPointRelative = $EntryPointRelative
        useProxy = [bool]$UseProxy
        replaceRunningApp = [bool]$ReplaceRunningApp
    }
}
$temporaryConfig = "$configPath.tmp"
[IO.File]::WriteAllText($temporaryConfig, (($config | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force

$helperPath = Join-Path $bundle 'update-session.js'
foreach ($value in @($node, $helperPath, $configPath)) {
    if ($value -match '[\x00\r\n"]') { throw 'An update-session launch path contains unsupported characters.' }
}
$arguments = '--no-warnings "{0}" --config "{1}" --best-effort' -f $helperPath,$configPath
$process = Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $bundle -WindowStyle Hidden -PassThru
[pscustomobject][ordered]@{
    started = $true
    processId = $process.Id
    appProcessId = $identity.pid
    rendererPort = $identity.rendererPort
    bundleHash = [IO.Path]::GetFileName($bundle)
    configPath = $configPath
} | ConvertTo-Json -Compress
$process.Dispose()
