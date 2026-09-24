[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helper = Join-Path $root 'windows\CodexRemoteMobileProject\RepairUpdateCoordinator.ps1'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'The update-coordinator repair helper is missing.' }

function Assert-Condition {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

function Assert-Rejected {
    param([scriptblock]$Operation, [string]$Pattern, [string]$Message)
    $rejected = $false
    try { & $Operation } catch { $rejected = [string]$_.Exception.Message -like $Pattern }
    if (-not $rejected) { throw $Message }
}

. $helper -ConfigPath 'C:\fixture\session.json' -CoordinatorProcessId 101 -CoordinatorStartTimeFileTimeUtc 1001 `
    -CoordinatorExecutablePath 'C:\fixture\node.exe' -ImportOnly

$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$sessionId = '0123456789abcdef0123456789abcdef'
$sessionRoot = 'C:\fixture\update-sessions'
$sessionDirectory = Join-Path (Join-Path $sessionRoot 'sessions') $sessionId
$configPath = Join-Path $sessionDirectory 'session.json'
$nodePath = 'C:\fixture\node.exe'
$scriptPath = 'C:\fixture\update-sessions\bundles\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\update-session.js'
$appPath = 'C:\fixture\ChatGPT.exe'
$trustedConsoleHostPath = 'C:\WINDOWS\System32\conhost.exe'

$context = [pscustomobject][ordered]@{
    ConfigPath = $configPath
    SessionDirectory = $sessionDirectory
    SessionStateRoot = $sessionRoot
    StatePath = Join-Path $sessionDirectory 'coordinator-state.json'
    HistoryPath = Join-Path $sessionDirectory 'update-history-v1.json'
    LockPath = Join-Path (Join-Path $sessionRoot 'active') 'owned.lock'
    CoordinatorProcessId = 101
    CoordinatorStartTimeFileTimeUtc = 1001L
    CoordinatorExecutablePath = $nodePath
    CoordinatorScriptPath = $scriptPath
    AppProcessId = 202
    AppStartTimeFileTimeUtc = 2002L
    AppExecutablePath = $appPath
    TrustedConsoleHostPath = $trustedConsoleHostPath
    RendererPort = 9222
    TransactionJournalPath = 'C:\fixture\update\transaction.json'
    GitTransactionJournalPath = 'C:\fixture\update\git-transaction.json'
    ExactProcessTest = { param($ProcessId, $StartTime, $Executable) return $ProcessId -in @(101, 202) -and $StartTime -in @(1001L, 2002L) -and -not [string]::IsNullOrWhiteSpace($Executable) }
}

$historyFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-repair-history-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $historyFixtureRoot -Force | Out-Null
try {
    $historyFixture = Join-Path $historyFixtureRoot 'update-history-v1.json'
    $missingHistory = Get-RepairHistoryEvidence $historyFixture
    Assert-Condition (-not $missingHistory.Exists -and @($missingHistory.Entries | ForEach-Object { $_ }).Count -eq 0) 'A missing first-publish history was not represented safely.'
    [IO.File]::WriteAllText($historyFixture, '[]', [Text.UTF8Encoding]::new($false))
    $emptyHistory = Get-RepairHistoryEvidence $historyFixture
    Assert-Condition ($emptyHistory.Exists -and @($emptyHistory.Entries | ForEach-Object { $_ }).Count -eq 0) 'An empty history array was not parsed safely.'
    [IO.File]::WriteAllText($historyFixture, '[{"at":1,"state":"available"}]', [Text.UTF8Encoding]::new($false))
    $singleHistory = Get-RepairHistoryEvidence $historyFixture
    $singleEntries = @($singleHistory.Entries | ForEach-Object { $_ })
    Assert-Condition ($singleHistory.Exists -and $singleEntries.Count -eq 1 -and $singleEntries[0].state -ceq 'available') `
        'A single-entry history array was unrolled or rejected.'
    [IO.File]::WriteAllText($historyFixture, '{"at":1,"state":"available"}', [Text.UTF8Encoding]::new($false))
    Assert-Rejected { Get-RepairHistoryEvidence $historyFixture } '*not a JSON array*' 'A non-array history document was accepted.'
} finally {
    Remove-Item -LiteralPath $historyFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function New-Snapshot {
    param(
        [string[]]$HistoryStates = @('checked', 'current'),
        [switch]$WithRendererHealth,
        [string]$ConfigText = 'config-text',
        [string]$LockText = 'lock-text',
        [string]$HistoryText = 'history-text',
        [switch]$HistoryMissing,
        [object[]]$DescendantProcesses = @()
    )
    $state = [pscustomobject][ordered]@{
        schemaVersion = 1
        sessionId = $sessionId
        bundleHash = ('a' * 64)
        coordinatorPid = 101
        coordinatorIdentity = [pscustomobject]@{ pid = 101; startToken = '1001'; executablePath = $nodePath }
        phase = 'active'
        heartbeatAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    if ($WithRendererHealth) {
        $state | Add-Member -NotePropertyName rendererConnected -NotePropertyValue $false
        $state | Add-Member -NotePropertyName rendererProofAtUnixMs -NotePropertyValue $null
    }
    $history = @()
    $at = 1L
    foreach ($value in $HistoryStates) {
        $history += [pscustomobject]@{ at = $at; state = $value; version = 'v1.0.0' }
        $at += 1
    }
    return [pscustomobject][ordered]@{
        CapturedAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Config = [pscustomobject][ordered]@{
            sessionDirectory = $sessionDirectory
            stateRoot = $sessionRoot
            rendererPort = 9222
            app = [pscustomobject]@{ pid = 202; startTimeFileTimeUtc = '2002'; executablePath = $appPath }
        }
        ConfigText = $ConfigText
        State = $state
        LockOwner = [pscustomobject]@{ pid = 101; startToken = '1001'; executablePath = $nodePath }
        LockText = $LockText
        History = if ($HistoryMissing) { @() } else { $history }
        HistoryExists = -not $HistoryMissing
        HistoryText = if ($HistoryMissing) { $null } else { $HistoryText }
        CommandLine = '"C:\fixture\node.exe" --no-warnings "{0}" --config "{1}" --best-effort' -f $scriptPath,$configPath
        DescendantProcesses = @($DescendantProcesses | ForEach-Object { $_ })
        DescendantProcessEvidenceText = ConvertTo-Json -InputObject @($DescendantProcesses | ForEach-Object { $_ }) -Depth 4 -Compress
    }
}

function New-ConsoleHostEvidence {
    param(
        [int]$ProcessId = 303,
        [long]$StartTimeFileTimeUtc = 50001L,
        [string]$ExecutablePath = $trustedConsoleHostPath,
        [string]$CommandLine = '\??\C:\WINDOWS\System32\conhost.exe 0x4',
        [int]$ParentProcessId = 101,
        [long]$ParentStartTimeFileTimeUtc = 1001L,
        [int]$SessionId = 1,
        [int]$ParentSessionId = 1,
        [long]$MainWindowHandle = 0L,
        [int]$DirectChildCount = 0
    )
    return [pscustomobject][ordered]@{
        ProcessId = $ProcessId
        StartTimeFileTimeUtc = $StartTimeFileTimeUtc
        ExecutablePath = $ExecutablePath
        CommandLine = $CommandLine
        ParentProcessId = $ParentProcessId
        ParentStartTimeFileTimeUtc = $ParentStartTimeFileTimeUtc
        SessionId = $SessionId
        ParentSessionId = $ParentSessionId
        MainWindowHandle = $MainWindowHandle
        DirectChildCount = $DirectChildCount
    }
}

function New-BridgeProof {
    param([bool]$PublicMissing = $true, [bool]$InternalMissing = $true, [long]$SampledAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    return [pscustomobject][ordered]@{
        publicBridgeMissing = $PublicMissing
        internalBridgeMissing = $InternalMissing
        appProcessId = 202
        appStartTimeFileTimeUtc = '2002'
        rendererPort = 9222
        coordinatorProcessId = 101
        sampledAtUnixMs = $SampledAt
    }
}

$baseline = New-Snapshot
Assert-Condition (Assert-RepairSnapshot -Context $context -Snapshot $baseline) 'A complete inert legacy snapshot was rejected.'
Assert-Condition (Assert-RepairBridgeProof -Context $context -Proof (New-BridgeProof)) 'A complete renderer-failure proof was rejected.'
Assert-Condition (Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryStates @())) 'An empty idle history was rejected.'
Assert-Condition (Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryMissing)) 'A missing first-publish history was rejected.'
foreach ($idleState in @('checked', 'current', 'available', 'unavailable', 'error', 'cancelled', 'hot-reload-confirmed', 'restart-confirmed')) {
    Assert-Condition (Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryStates @($idleState))) `
        "A known idle or terminal history state was rejected: $idleState"
}
$completedHistories = [Collections.Generic.List[object]]::new()
[void]$completedHistories.Add([string[]]@('preparing', 'queued', 'cancelled', 'available'))
[void]$completedHistories.Add([string[]]@('preparing', 'queued', 'unavailable'))
[void]$completedHistories.Add([string[]]@('preparing', 'updating', 'error'))
[void]$completedHistories.Add([string[]]@('preparing', 'updating', 'hot-reload-confirmed', 'current'))
[void]$completedHistories.Add([string[]]@('closing', 'restarting', 'restart-confirmed'))
foreach ($completedHistory in $completedHistories) {
    Assert-Condition (Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryStates $completedHistory)) `
        "A chronologically completed mutation history was rejected: $($completedHistory -join ',')"
}

Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryStates @('checked', 'preparing')) } `
    '*unfinished mutation*' 'A preparing update was accepted as idle.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryStates @('checked', 'closing')) } `
    '*unfinished mutation*' 'A closing update was accepted as idle.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryStates @('preparing', 'available')) } `
    '*unfinished mutation*' 'An observational state incorrectly completed a prior mutation.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryStates @('preparing', 'updating', 'unavailable')) } `
    '*unfinished mutation*' 'Unavailable incorrectly completed an applying mutation.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryStates @('checked', 'future-state')) } `
    '*unknown, malformed*' 'An unknown history state was accepted as idle.'
$malformedHistory = New-Snapshot
$malformedHistory.History = @([pscustomobject]@{ at = 0L; state = 'current' })
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot $malformedHistory } `
    '*unknown, malformed*' 'A malformed history entry was accepted as idle.'
$futureHistory = New-Snapshot
$futureHistory.History = @([pscustomobject]@{ at = [DateTimeOffset]::UtcNow.AddMinutes(1).ToUnixTimeMilliseconds(); state = 'current' })
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot $futureHistory } `
    '*future*' 'A future-dated history entry was accepted.'
$outOfOrderHistory = New-Snapshot
$outOfOrderHistory.History = @([pscustomobject]@{ at = 2L; state = 'checked' }, [pscustomobject]@{ at = 1L; state = 'current' })
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot $outOfOrderHistory } `
    '*out-of-order*' 'An out-of-order history was accepted.'
$stableConsoleHost = New-ConsoleHostEvidence
$consoleBaseline = New-Snapshot -DescendantProcesses @($stableConsoleHost)
Assert-Condition (Assert-RepairSnapshot -Context $context -Snapshot $consoleBaseline) 'A stable exact Windows console host was rejected.'
Assert-Condition (Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @($stableConsoleHost)) -Baseline $consoleBaseline) `
    'An unchanged exact Windows console host failed the frozen-snapshot proof.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -ExecutablePath 'C:\fixture\conhost.exe' -CommandLine '\??\C:\fixture\conhost.exe 0x4')
)) } '*blocking child process*' 'A same-name console host outside System32 was accepted.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -ExecutablePath 'C:\WINDOWS\System32\conhost-malicious.exe' -CommandLine '\??\C:\WINDOWS\System32\conhost-malicious.exe 0x4')
)) } '*blocking child process*' 'A maliciously named executable inside System32 was accepted as the console host.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -CommandLine '\??\C:\fixture\conhost.exe 0x4')
)) } '*blocking child process*' 'A trusted-image console host with a spoofed command path was accepted.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -DirectChildCount 1)
)) } '*blocking child process*' 'A console host with a descendant was accepted.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -StartTimeFileTimeUtc ([TimeSpan]::FromSeconds(6).Ticks + 1001L))
)) } '*blocking child process*' 'A late unrelated console host was accepted as startup infrastructure.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -ParentProcessId 999)
)) } '*blocking child process*' 'A console host owned by another parent PID was accepted.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -ParentStartTimeFileTimeUtc 1002)
)) } '*blocking child process*' 'A console host with a reused parent identity was accepted.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -StartTimeFileTimeUtc 1000)
)) } '*blocking child process*' 'A console host created before the coordinator was accepted.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -MainWindowHandle 1)
)) } '*blocking child process*' 'A window-owning console host was accepted as hidden startup infrastructure.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    (New-ConsoleHostEvidence -SessionId 2)
)) } '*blocking child process*' 'A console host from another session was accepted.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @(
    $stableConsoleHost,
    (New-ConsoleHostEvidence -ProcessId 304 -StartTimeFileTimeUtc 50002 -ExecutablePath 'C:\fixture\worker.exe' -CommandLine 'C:\fixture\worker.exe')
)) } '*blocking child process*' 'An additional unknown child was accepted beside the console host.'
$changedConsoleHost = New-ConsoleHostEvidence -ProcessId 304 -StartTimeFileTimeUtc 50002
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -DescendantProcesses @($changedConsoleHost)) -Baseline $consoleBaseline } `
    '*child identity changed*' 'A changed console-host identity survived the frozen-snapshot proof.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -WithRendererHealth) } `
    '*renderer-health proof*' 'A health-aware coordinator was accepted as legacy.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryText 'changed') -Baseline $baseline } `
    '*durable history*changed*' 'A history change across the freeze boundary was accepted.'
Assert-Rejected { Assert-RepairSnapshot -Context $context -Snapshot (New-Snapshot -HistoryMissing) -Baseline $baseline } `
    '*durable history*changed*' 'A history disappearance across the freeze boundary was accepted.'
Assert-Rejected { Assert-RepairBridgeProof -Context $context -Proof (New-BridgeProof -PublicMissing $false) } `
    '*failure proof is incomplete*' 'A present public bridge was accepted as failed.'
Assert-Rejected { Assert-RepairBridgeProof -Context $context -Proof (New-BridgeProof -SampledAt ($now - 20000)) } `
    '*failure proof is stale*' 'A stale renderer proof was accepted.'

$events = [Collections.Generic.List[string]]::new()
$snapshotCount = 0
$proofCount = 0
$captureSnapshot = {
    param($value)
    $script:snapshotCount += 1
    [void]$events.Add("snapshot-$script:snapshotCount")
    return New-Snapshot
}
$captureProof = {
    param($value)
    $script:proofCount += 1
    [void]$events.Add("proof-$script:proofCount")
    return New-BridgeProof
}
$acquire = { param($value) [void]$events.Add('guards-acquired'); return [pscustomobject]@{ owned = $true } }
$freeze = { param($value) [void]$events.Add('frozen'); return [pscustomobject]@{ frozen = $true } }
$resume = { param($value, $token) [void]$events.Add('resumed') }
$terminate = { param($value, $token) [void]$events.Add('terminated') }
$wait = { param($value, $token) [void]$events.Add('exit-proven'); return $true }
$release = { param($value, $guards) [void]$events.Add('guards-released') }

$result = Invoke-RepairCore -Context $context -CaptureSnapshot $captureSnapshot -CaptureBridgeProof $captureProof `
    -AcquireGuards $acquire -FreezeCoordinator $freeze -ResumeCoordinator $resume -TerminateCoordinator $terminate `
    -WaitCoordinatorExit $wait -ReleaseGuards $release -ProofIntervalMilliseconds 1
Assert-Condition ($result.repaired -and $result.coordinatorProcessId -eq 101 -and $result.appProcessId -eq 202) 'The successful repair core returned an invalid result.'
Assert-Condition (($events -join ',') -eq 'snapshot-1,proof-1,proof-2,guards-acquired,snapshot-2,proof-3,frozen,snapshot-3,proof-4,terminated,exit-proven,guards-released') `
    "The repair core ordering changed: $($events -join ',')"
Assert-Condition (-not $events.Contains('resumed')) 'A successful repair resumed the terminated predecessor.'

$events.Clear()
$snapshotCount = 0
$proofCount = 0
$captureChangingSnapshot = {
    param($value)
    $script:snapshotCount += 1
    [void]$events.Add("snapshot-$script:snapshotCount")
    if ($script:snapshotCount -eq 3) { return New-Snapshot -HistoryText 'changed-while-frozen' }
    return New-Snapshot
}
Assert-Rejected {
    Invoke-RepairCore -Context $context -CaptureSnapshot $captureChangingSnapshot -CaptureBridgeProof $captureProof `
        -AcquireGuards $acquire -FreezeCoordinator $freeze -ResumeCoordinator $resume -TerminateCoordinator $terminate `
        -WaitCoordinatorExit $wait -ReleaseGuards $release -ProofIntervalMilliseconds 1
} '*durable history*changed*' 'A changed frozen proof did not abort repair.'
Assert-Condition ($events.Contains('frozen') -and $events.Contains('resumed') -and $events.Contains('guards-released')) 'A frozen abort did not resume the coordinator and release both guards.'
Assert-Condition (-not $events.Contains('terminated')) 'A failed frozen proof terminated the coordinator.'

$events.Clear()
$snapshotCount = 0
$proofCount = 0
$captureChangingChildSnapshot = {
    param($value)
    $script:snapshotCount += 1
    [void]$events.Add("snapshot-$script:snapshotCount")
    if ($script:snapshotCount -eq 3) {
        return New-Snapshot -DescendantProcesses @((New-ConsoleHostEvidence -ProcessId 304 -StartTimeFileTimeUtc 50002))
    }
    return New-Snapshot -DescendantProcesses @($stableConsoleHost)
}
Assert-Rejected {
    Invoke-RepairCore -Context $context -CaptureSnapshot $captureChangingChildSnapshot -CaptureBridgeProof $captureProof `
        -AcquireGuards $acquire -FreezeCoordinator $freeze -ResumeCoordinator $resume -TerminateCoordinator $terminate `
        -WaitCoordinatorExit $wait -ReleaseGuards $release -ProofIntervalMilliseconds 1
} '*child identity changed*' 'A child identity change while frozen did not abort repair.'
Assert-Condition ($events.Contains('frozen') -and $events.Contains('resumed') -and $events.Contains('guards-released')) `
    'A frozen child-identity abort did not resume the coordinator and release both guards.'
Assert-Condition (-not $events.Contains('terminated')) 'A frozen child-identity change terminated the coordinator.'

function Resolve-TestNode {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    foreach ($candidate in @(
        $(if ($command) { $command.Source }),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        'C:\Program Files\nodejs\node.exe'
    ) | Where-Object { $_ } | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw 'Node.js is unavailable for the disposable native debugger fixture.'
}

function Start-DisposableNode {
    param([string]$NodePath)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $NodePath
    $start.Arguments = '-e "setInterval(() => {}, 1000)"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    Start-Sleep -Milliseconds 150
    $process.Refresh()
    if ($process.HasExited) { $process.Dispose(); throw 'The disposable Node fixture exited before native debugger validation.' }
    return $process
}

Initialize-RepairNativeMethods
$testNode = Resolve-TestNode
$nativeFixtures = [Collections.Generic.List[Diagnostics.Process]]::new()
try {
    $resumeFixture = Start-DisposableNode -NodePath $testNode
    $nativeFixtures.Add($resumeFixture)
    $resumeStart = $resumeFixture.StartTime.ToUniversalTime().ToFileTimeUtc()
    $resumeToken = [ChatGPTRemoteCoordinatorRepairNative]::Freeze([uint32]$resumeFixture.Id, $resumeStart, $testNode)
    try {
        Assert-Condition ($resumeToken.Attached -and -not $resumeFixture.HasExited) 'The disposable abort fixture was not frozen alive.'
        [ChatGPTRemoteCoordinatorRepairNative]::Resume($resumeToken)
        Assert-Condition (-not $resumeToken.Attached -and -not $resumeFixture.HasExited) 'The disposable abort fixture did not detach and resume safely.'
    } finally { $resumeToken.Dispose() }

    $terminateFixture = Start-DisposableNode -NodePath $testNode
    $nativeFixtures.Add($terminateFixture)
    $terminateStart = $terminateFixture.StartTime.ToUniversalTime().ToFileTimeUtc()
    $terminateToken = [ChatGPTRemoteCoordinatorRepairNative]::Freeze([uint32]$terminateFixture.Id, $terminateStart, $testNode)
    try {
        [ChatGPTRemoteCoordinatorRepairNative]::TerminateAndWait($terminateToken, 10000)
        $terminateFixture.Refresh()
        Assert-Condition ($terminateToken.ExitProven -and -not $terminateToken.Attached -and $terminateFixture.HasExited) `
            'The disposable termination fixture did not drain its debug exit and signal the exact process handle.'
    } finally { $terminateToken.Dispose() }
} finally {
    foreach ($fixture in $nativeFixtures) {
        try { if (-not $fixture.HasExited) { $fixture.Kill(); [void]$fixture.WaitForExit(5000) } } catch {}
        $fixture.Dispose()
    }
}

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw "PowerShell parse failed for the repair helper: $($parseErrors[0].Message)" }

$helperText = Get-Content -LiteralPath $helper -Raw
$launcherText = Get-Content -LiteralPath (Join-Path $root 'windows\CodexRemoteMobileProject\UpdateSessionLauncher.ps1') -Raw
$healthMatch = [regex]::Match($helperText, '(?s)const bridgeHealthy = await \(async \(\) => \{\r?\n(?<body>.*?)\r?\n      \}\)\(\);')
Assert-Condition $healthMatch.Success 'The production legacy bridge-health predicate could not be extracted for regression testing.'
$legacyShapeProbe = @'
let actionSeen = null;
let requests = 0;
globalThis.__chatgptRemoteUpdateRequest = () => {};
globalThis.__CHATGPT_REMOTE_UPDATE_INTERNAL__ = {
  nonce: "0123456789abcdef0123456789abcdef",
  setStatus() { return true; }, receive() { return true; }, dispose() { return true; },
};
globalThis.__CHATGPT_REMOTE_UPDATE__ = {
  getStatus() { return { state: "current" }; },
  async request(action) { actionSeen = action; requests += 1; return { state: "current" }; },
};
(async () => {
  const bridgeHealthy = await (async () => {
'@ + $healthMatch.Groups['body'].Value + @'
  })();
  process.stdout.write(`${bridgeHealthy}:${actionSeen}:${requests}`);
})().catch((error) => { console.error(error); process.exitCode = 1; });
'@
$legacyShapeResult = @($legacyShapeProbe | & $testNode '-' 2>&1)
Assert-Condition ($LASTEXITCODE -eq 0 -and ($legacyShapeResult -join '').Trim() -ceq 'true:history:1') `
    "The actual pre-change bridge shape did not pass the production read-only health round trip: $($legacyShapeResult -join ' ')"
Assert-Condition ($helperText.Contains("'Local\ChatGPTCustomInjectionLauncher'")) 'The repair helper does not acquire the canonical launch guard.'
Assert-Condition ($helperText.Contains('[IO.FileShare]::None')) 'The repair helper does not acquire the exclusive updater lock.'
Assert-Condition ($helperText.Contains('DebugActiveProcess') -and $helperText.Contains('DebugSetProcessKillOnExit(false)') -and $helperText.Contains('WaitForDebugEvent')) `
    'The repair helper does not use a fail-safe native debugger freeze.'
Assert-Condition ($helperText.Contains('TerminateProcess(frozen.ProcessHandle') -and -not $helperText.Contains('TerminateProcess(App')) `
    'The repair helper is not structurally limited to the frozen coordinator handle.'
Assert-Condition ($helperText.Contains('globalThis.__CHATGPT_REMOTE_UPDATE__ === undefined') -and
    $helperText.Contains('globalThis.__CHATGPT_REMOTE_UPDATE_INTERNAL__ === undefined')) `
    'The repair helper does not independently prove both renderer bridge globals absent.'
Assert-Condition ($helperText.Contains('api.request("history")') -and
    $helperText.Contains("reason = 'legacy-coordinator-bridge-present-unverified'")) `
    'The repair helper can classify a stale bridge as healthy or terminate while a bridge remains present.'
Assert-Condition ($launcherText.Contains("'RepairUpdateCoordinator.ps1' = Join-Path `$sourceRoot 'RepairUpdateCoordinator.ps1'")) `
    'The repair helper is not retained in the immutable coordinator bundle.'
Assert-Condition ($launcherText.Contains('if ($null -ne $reusable -and -not $reusable.Compatible -and $reusable.LegacyRepairEligible)') -and
    $launcherText.Contains('if ($reusable.ContextMatches)')) `
    'Legacy repair remains tied to relaunch context or a healthy mismatch can claim compatible reuse.'
$repairEligibilityIndex = $launcherText.IndexOf("`$reusable.LegacyRepairEligible", [StringComparison]::Ordinal)
$repairInvocationIndex = $launcherText.IndexOf('& $repairHelper', [StringComparison]::Ordinal)
$newSessionIndex = $launcherText.IndexOf('$sessionDirectory = Join-Path', $repairInvocationIndex, [StringComparison]::Ordinal)
Assert-Condition ($repairEligibilityIndex -ge 0 -and $repairInvocationIndex -gt $repairEligibilityIndex -and $newSessionIndex -gt $repairInvocationIndex) `
    'The launcher does not repair an exact eligible predecessor before creating the replacement session.'
Assert-Condition ($launcherText.Contains('if ($null -ne $reusable) { throw ''The retired legacy coordinator still owns the exact update session.'' }')) `
    'The launcher can start a duplicate after incomplete coordinator retirement.'

Write-Output 'Update coordinator repair tests passed.'
