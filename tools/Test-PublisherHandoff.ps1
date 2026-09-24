[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$startupPath = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\MobileProjectStartup.ps1'
$publisherPath = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\publisher-heartbeat.js'
$functionNames = @(
    'Get-PublisherProcessProof',
    'Get-PublisherOwnerState',
    'Get-PublisherHandoffState',
    'Read-PublisherLock',
    'Test-PublisherLockSession',
    'Open-PublisherLockExclusive',
    'Publish-PublisherHandoffMarkerAtomically',
    'Remove-ExactPublisherHandoffMarker',
    'Wait-ExactPublisherExit',
    'Request-PublisherHandoff',
    'Complete-PublisherHandoff',
    'Resolve-TrustedLegacyPublisherScript',
    'Start-PublisherHeartbeat',
    'Invoke-PublisherRepair'
)
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($startupPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "MobileProjectStartup.ps1 did not parse: $($parseErrors[0])" }
$definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $functionNames -contains $node.Name
}, $true))
Assert-True ($definitions.Count -eq $functionNames.Count) 'The publisher handoff functions could not all be extracted from MobileProjectStartup.ps1.'
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

$nodePath = [IO.Path]::GetFullPath((Get-Command node.exe -ErrorAction Stop).Source)
$publisherPath = [IO.Path]::GetFullPath($publisherPath)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("publisher-handoff-{0}" -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$fixture = $null
$foreignRequester = $null
try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $current = [Diagnostics.Process]::GetCurrentProcess()
    try {
        $parentPid = $current.Id
        $parentStartToken = $current.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
        $parentExecutable = [IO.Path]::GetFullPath($current.MainModule.FileName)
    } finally { $current.Dispose() }
    $lockPath = Join-Path $testRoot "publisher-heartbeat-$port.lock"
    $sourcePublisherPath = $publisherPath
    $stablePublisherRoot = Join-Path $testRoot 'stable-package\CodexRemoteMobileProject'
    [IO.Directory]::CreateDirectory($stablePublisherRoot) | Out-Null
    $stablePublisherPath = Join-Path $stablePublisherRoot 'publisher-heartbeat.js'
    Copy-Item -LiteralPath $publisherPath -Destination $stablePublisherPath
    $stablePublisherPath = [IO.Path]::GetFullPath($stablePublisherPath)
    $arguments = '--no-warnings "{0}" --port {1} --parent-pid {2} --parent-start-token "{3}" --lock-path "{4}" --interval-ms 1000' -f $sourcePublisherPath, $port, $parentPid, $parentStartToken, $lockPath
    $fixtureOutput = Join-Path $testRoot 'publisher.stdout.log'
    $fixtureError = Join-Path $testRoot 'publisher.stderr.log'
    $fixture = Start-Process -FilePath $nodePath -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $fixtureOutput -RedirectStandardError $fixtureError -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $lockPath -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        $exitDetail = if ($fixture.HasExited) { "exitCode=$($fixture.ExitCode)" } else { 'stillRunning=true' }
        $stderr = if (Test-Path -LiteralPath $fixtureError) { (Get-Content -LiteralPath $fixtureError -Raw).Trim() } else { '' }
        throw "The publisher fixture did not create its ownership lock ($exitDetail; stderr=$stderr)."
    }
    $owner = Read-PublisherLock -Path $lockPath
    Assert-True ([int]$owner.protocolVersion -eq 2 -and [string]$owner.state -ceq 'active') 'The publisher did not write current ownership metadata.'
    $proof = Get-PublisherProcessProof -ProcessId ([int]$owner.pid) -ExpectedExecutablePath $nodePath -ExpectedScriptPaths @($stablePublisherPath, $sourcePublisherPath) -ParentProcessId $parentPid -ParentStartToken $parentStartToken -Port $port -LockPath $lockPath
    Assert-True ($null -ne $proof) 'The exact publisher fixture identity could not be proven.'
    Assert-True ([string]::Equals([string]$proof.scriptPath, $sourcePublisherPath, [StringComparison]::OrdinalIgnoreCase)) 'The source-package publisher was not identified as the exact legacy owner.'
    $script:startedPublisher = $null
    $script:logRoot = $testRoot
    $script:publisherHeartbeatHelper = $sourcePublisherPath
    [IO.File]::WriteAllText((Join-Path $testRoot 'codexremote-simple-session.json'), (([ordered]@{
        rendererPort = $port
        launchProcessId = $parentPid
        executablePath = $parentExecutable
    } | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    function Write-StartupLog { param([string]$Message) }
    function Start-StartupBackgroundProcess {
        param([string]$FilePath, [string]$ArgumentList)
        $script:startedPublisher = [pscustomobject]@{ filePath = $FilePath; argumentList = $ArgumentList }
        $result = [pscustomobject]@{}
        $result | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        return $result
    }
    Start-PublisherHeartbeat -NodePath $nodePath -TrustedLegacyPublisherScriptPath $sourcePublisherPath
    Assert-True ($null -eq $script:startedPublisher) 'A current exact publisher was churned instead of reused.'
    Assert-True (-not $fixture.HasExited) 'The reused current publisher was retired unexpectedly.'
    $script:publisherHeartbeatHelper = $stablePublisherPath
    Start-PublisherHeartbeat -NodePath $nodePath -TrustedLegacyPublisherScriptPath $sourcePublisherPath
    Assert-True ($fixture.WaitForExit(1000)) 'The exact publisher fixture did not cooperatively retire after losing its lock token.'
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'The completed handoff marker was not removed.'
    Assert-True ($null -ne $script:startedPublisher) 'The supported repair route did not request a successor after the source publisher retired.'
    Assert-True ([string]::Equals($script:startedPublisher.filePath, $nodePath, [StringComparison]::OrdinalIgnoreCase)) 'The successor did not use the exact proven Node executable.'
    Assert-True ($script:startedPublisher.argumentList.IndexOf(('"' + $stablePublisherPath + '"'), [StringComparison]::OrdinalIgnoreCase) -ge 0) 'The source publisher was not migrated to the stable publisher script.'

    $atomicOriginal = (([ordered]@{
        parentPid = $parentPid; parentStartToken = $parentStartToken; pid = 2147483646; port = $port
        state = 'active'; token = ('b' * 48)
    } | ConvertTo-Json -Compress) + [Environment]::NewLine)
    [IO.File]::WriteAllText($lockPath, $atomicOriginal, [Text.UTF8Encoding]::new($false))
    $atomicMarker = [ordered]@{ state = 'handoff'; token = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')) }
    $replaceFailed = $false
    try {
        Publish-PublisherHandoffMarkerAtomically -Path $lockPath -Marker $atomicMarker -ValidateCurrent {
            param($current)
            if ([string]$current.token -cne ('b' * 48)) { throw 'fixture validation failed' }
        } -ReplaceFile { throw 'fixture replace interrupted' }
    } catch {
        $replaceFailed = $_.Exception.Message -like '*fixture replace interrupted*'
    }
    Assert-True $replaceFailed 'The atomic marker fixture did not inject its pre-replace failure.'
    Assert-True ([IO.File]::ReadAllText($lockPath) -ceq $atomicOriginal) 'A failed atomic marker publication changed the original ownership lock.'
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.handoff-*.tmp').Count -eq 0) 'A failed atomic marker publication left a temporary file.'
    Remove-Item -LiteralPath $lockPath -Force

    $script:startedPublisher = $null
    $deadOwner = [ordered]@{
        parentPid = $parentPid; parentStartToken = $parentStartToken; pid = 2147483646; port = $port
        state = 'active'; token = ('c' * 48)
    }
    [IO.File]::WriteAllText($lockPath, (($deadOwner | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Start-PublisherHeartbeat -NodePath $nodePath -TrustedLegacyPublisherScriptPath $sourcePublisherPath
    Assert-True ($null -ne $script:startedPublisher) 'A definitively dead legacy owner blocked publisher restoration.'
    Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'Startup removed the stale lock instead of leaving final reclamation to the successor.'
    Remove-Item -LiteralPath $lockPath -Force

    $script:startedPublisher = $null
    $priorSessionOwner = [ordered]@{
        parentPid = 2147483645; parentStartToken = '1'; pid = 2147483646; port = $port
        state = 'active'; token = ('f' * 48)
    }
    [IO.File]::WriteAllText($lockPath, (($priorSessionOwner | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Start-PublisherHeartbeat -NodePath $nodePath -TrustedLegacyPublisherScriptPath $sourcePublisherPath
    Assert-True ($null -ne $script:startedPublisher) 'A retired publisher lock from a prior app session blocked startup-level restoration.'
    Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'Startup removed the prior-session stale lock instead of leaving final reclamation to the successor.'
    Remove-Item -LiteralPath $lockPath -Force

    $script:startedPublisher = $null
    $priorHandoff = [ordered]@{
        protocolVersion = 2; state = 'handoff'; token = ('9' * 48)
        parentPid = 2147483645; parentStartToken = '1'; port = $port
        executablePath = $nodePath; scriptPath = $stablePublisherPath
        previousOwner = [ordered]@{ pid = 2147483646; startToken = '1'; token = ('7' * 48) }
        requester = [ordered]@{ pid = 2147483644; startToken = '1' }
        createdAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    [IO.File]::WriteAllText($lockPath, (($priorHandoff | ConvertTo-Json -Depth 4 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Start-PublisherHeartbeat -NodePath $nodePath -TrustedLegacyPublisherScriptPath $sourcePublisherPath
    Assert-True ($null -ne $script:startedPublisher) 'A fully retired prior-session handoff marker blocked publisher restoration.'
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'A fully retired prior-session handoff marker was not cleared before successor launch.'

    $script:startedPublisher = $null
    $liveForeign = [ordered]@{
        parentPid = 2147483645; parentStartToken = '1'; pid = $PID; port = $port
        state = 'active'; token = ('d' * 48)
    }
    [IO.File]::WriteAllText($lockPath, (($liveForeign | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $foreignBlocked = $false
    try { Start-PublisherHeartbeat -NodePath $nodePath -TrustedLegacyPublisherScriptPath $sourcePublisherPath }
    catch { $foreignBlocked = $_.Exception.Message -like '*different renderer session (alive)*' }
    Assert-True $foreignBlocked 'A live foreign prior-session lock owner was not retained fail-closed.'
    Assert-True ($null -eq $script:startedPublisher) 'A successor was requested over a live foreign owner.'
    Remove-Item -LiteralPath $lockPath -Force

    $script:startedPublisher = $null
    $reusedOwner = [ordered]@{
        parentPid = $parentPid; parentStartToken = $parentStartToken; pid = $PID; port = $port
        protocolVersion = 2; publisherStartToken = '1'; state = 'active'; token = ('e' * 48)
    }
    [IO.File]::WriteAllText($lockPath, (($reusedOwner | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Start-PublisherHeartbeat -NodePath $nodePath -TrustedLegacyPublisherScriptPath $sourcePublisherPath
    Assert-True ($null -ne $script:startedPublisher) 'A protocol-v2 reused PID blocked publisher restoration.'
    Remove-Item -LiteralPath $lockPath -Force
    Assert-True ((Get-PublisherOwnerState -Owner $reusedOwner -ProcessLookup { throw [UnauthorizedAccessException]::new('fixture') }) -ceq 'unknown') 'An uncertain owner lookup did not remain fail-closed.'

    $foreignRequester = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -WindowStyle Hidden -PassThru
    $foreignRequesterStart = $foreignRequester.StartTime.ToUniversalTime().ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
    $markerToken = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N'))
    $marker = [ordered]@{
        protocolVersion = 2; state = 'handoff'; token = $markerToken
        parentPid = $parentPid; parentStartToken = $parentStartToken; port = $port
        executablePath = $nodePath; scriptPath = $stablePublisherPath
        previousOwner = [ordered]@{ pid = 2147483646; startToken = '1'; token = ('a' * 48) }
        requester = [ordered]@{ pid = $foreignRequester.Id; startToken = $foreignRequesterStart }
        createdAtUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    [IO.File]::WriteAllText($lockPath, (($marker | ConvertTo-Json -Depth 4 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $blocked = $false
    try {
        Complete-PublisherHandoff -Path $lockPath -Marker $marker -ExpectedExecutablePath $nodePath -ExpectedScriptPath $stablePublisherPath -ParentProcessId $parentPid -ParentStartToken $parentStartToken -Port $port
    } catch {
        $blocked = $_.Exception.Message -like '*still owns the publisher handoff*'
    }
    Assert-True $blocked 'A live exact requester must prevent another startup from taking its handoff marker.'
    Assert-True (Test-Path -LiteralPath $lockPath -PathType Leaf) 'A foreign live requester marker must be retained.'

    Stop-Process -Id $foreignRequester.Id -Force -ErrorAction Stop
    $foreignRequester.WaitForExit()
    Complete-PublisherHandoff -Path $lockPath -Marker $marker -ExpectedExecutablePath $nodePath -ExpectedScriptPath $stablePublisherPath -ParentProcessId $parentPid -ParentStartToken $parentStartToken -Port $port
    Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'A later startup did not recover the exact abandoned handoff marker.'

    $script:launcherMutexName = "Local\PublisherRepairFixture-$([Guid]::NewGuid().ToString('N'))"
    $outerMutex = [Threading.Mutex]::new($false, $script:launcherMutexName)
    try {
        Assert-True ($outerMutex.WaitOne([TimeSpan]::Zero)) 'The publisher repair mutex fixture could not acquire its outer ownership.'
        $script:repairCalls = 0
        function Start-PublisherHeartbeat { param([string]$NodePath, [string]$TrustedLegacyPublisherScriptPath) $script:repairCalls++ }
        Invoke-PublisherRepair -NodePath $nodePath -TrustedLegacyPublisherScriptPath $sourcePublisherPath
        Assert-True ($script:repairCalls -eq 1) 'Nested same-process publisher repair did not use reentrant launch-mutex ownership.'
        $outerMutex.ReleaseMutex()
    } finally { $outerMutex.Dispose() }
    Write-Host 'Publisher handoff self-test passed.'
} finally {
    if ($fixture -and -not $fixture.HasExited) { Stop-Process -Id $fixture.Id -Force -ErrorAction SilentlyContinue }
    if ($foreignRequester -and -not $foreignRequester.HasExited) { Stop-Process -Id $foreignRequester.Id -Force -ErrorAction SilentlyContinue }
    if ($fixture) { $fixture.Dispose() }
    if ($foreignRequester) { $foreignRequester.Dispose() }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
