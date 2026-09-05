[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$node = (Get-Command node.exe -ErrorAction Stop).Source
$pwsh = (Get-Process -Id $PID).Path
$helper = Join-Path $root 'windows\update-transaction.js'
$updater = Join-Path $root 'windows\Update-ChatGPTRemote.ps1'
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-transaction-test-' + [guid]::NewGuid().ToString('N'))

function Write-Utf8File {
    param([string]$Path, [string]$Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Read-JsonSnapshotShared {
    param([string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
    return ($text | ConvertFrom-Json -ErrorAction Stop)
}

function Write-Manifest {
    param([string]$Directory)
    $lines = foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse | Sort-Object FullName) {
        if ($file.Name -in @('RELEASE-MANIFEST.sha256', '.chatgpt-remote-release.zip', '.chatgpt-remote-prepared.json')) { continue }
        $relative = $file.FullName.Substring($Directory.TrimEnd('\').Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash *$relative"
    }
    Write-Utf8File -Path (Join-Path $Directory 'RELEASE-MANIFEST.sha256') -Value (($lines -join "`n") + "`n")
}

function New-InstalledFixture {
    param([string]$Directory)
    if (Test-Path -LiteralPath $Directory) { Remove-Item -LiteralPath $Directory -Recurse -Force }
    New-Item -ItemType Directory -Path $Directory | Out-Null
    Write-Utf8File (Join-Path $Directory 'VERSION') "v1.0.0`n"
    Write-Utf8File (Join-Path $Directory 'payload.txt') 'old payload'
    Write-Utf8File (Join-Path $Directory 'removed.txt') 'removed after update'
    Write-Manifest $Directory
}

function New-PreparedFixture {
    param([string]$Directory)
    if (Test-Path -LiteralPath $Directory) { Remove-Item -LiteralPath $Directory -Recurse -Force }
    New-Item -ItemType Directory -Path $Directory | Out-Null
    Write-Utf8File (Join-Path $Directory 'VERSION') "v2.0.0`n"
    Write-Utf8File (Join-Path $Directory 'payload.txt') 'new payload'
    Write-Utf8File (Join-Path $Directory 'added.txt') 'added by update'
    Copy-Item -LiteralPath $updater -Destination (Join-Path $Directory 'Update-ChatGPTRemote.ps1')
    Copy-Item -LiteralPath $helper -Destination (Join-Path $Directory 'update-transaction.js')
    Write-Manifest $Directory
    $archive = Join-Path $Directory '.chatgpt-remote-release.zip'
    [IO.File]::WriteAllBytes($archive, [Text.Encoding]::UTF8.GetBytes('fixture release archive bytes'))
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $result = Invoke-Helper @('seal-prepared', '--prepared-root', $Directory, '--platform', 'Windows-x64', '--version', 'v2.0.0', '--archive-sha256', $archiveHash)
    if ($result.prepared -ne $true) { throw 'Prepared fixture was not sealed.' }
    return $archiveHash
}

function Invoke-Helper {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $output = @(& $node $helper @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Transaction helper failed: $($output -join ' ')" }
    return (($output -join "`n") | ConvertFrom-Json)
}

function Get-ApplyArguments {
    param([string]$Install, [string]$Prepared, [string]$Journal, [string]$Backup, [string]$ArchiveHash)
    return @(
        'apply', '--install-root', $Install, '--prepared-root', $Prepared,
        '--journal-path', $Journal, '--backup-root', $Backup,
        '--platform', 'Windows-x64', '--version', 'v2.0.0', '--archive-sha256', $ArchiveHash
    )
}

function Start-PausedApply {
    param([string[]]$Arguments, [string]$Journal, [string]$Hook, [int]$TargetCount)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $node
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['NODE_OPTIONS'] = "--require=$Hook"
    $start.Environment['CHATGPT_REMOTE_TEST_JOURNAL'] = $Journal
    $start.Environment['CHATGPT_REMOTE_TEST_PAUSE_COUNT'] = [string]$TargetCount
    $start.ArgumentList.Add($helper)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (Test-Path -LiteralPath $Journal -PathType Leaf) {
            try {
                $journalState = Read-JsonSnapshotShared -Path $Journal
                if ([int]$journalState.completedOperations -eq $TargetCount) {
                    $process.Kill($true)
                    $process.WaitForExit()
                    return $journalState
                }
            } catch [Management.Automation.RuntimeException] {}
        }
        if ($process.HasExited) {
            throw "Apply exited before the hard-kill boundary: $($process.StandardError.ReadToEnd())"
        }
        Start-Sleep -Milliseconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    try { $process.Kill($true) } catch {}
    throw "Timed out waiting for durable completedOperations=$TargetCount."
}

function Invoke-PowerShellChild {
    param([string[]]$Arguments, [hashtable]$Environment = @{})
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwsh
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['PATH'] = $env:PATH
    $start.Environment['USERPROFILE'] = $env:USERPROFILE
    foreach ($entry in $Environment.GetEnumerator()) { $start.Environment[$entry.Key] = [string]$entry.Value }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Start-CapturedProcess {
    param([string]$FilePath, [string[]]$Arguments, [hashtable]$Environment = @{})
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['PATH'] = $env:PATH
    $start.Environment['USERPROFILE'] = $env:USERPROFILE
    foreach ($entry in $Environment.GetEnumerator()) { $start.Environment[$entry.Key] = [string]$entry.Value }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    return $process
}

function Start-ReleaseServer {
    param([string]$ServerScript, [string]$Metadata, [string]$Archive, [string]$Checksums, [string]$ReadyFile, [int]$Port)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $node
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CHATGPT_REMOTE_TEST_METADATA'] = $Metadata
    $start.Environment['CHATGPT_REMOTE_TEST_ARCHIVE'] = $Archive
    $start.Environment['CHATGPT_REMOTE_TEST_CHECKSUMS'] = $Checksums
    $start.Environment['CHATGPT_REMOTE_TEST_READY'] = $ReadyFile
    $start.Environment['CHATGPT_REMOTE_TEST_PORT'] = [string]$Port
    $start.ArgumentList.Add($ServerScript)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ReadyFile -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { throw "Release fixture server exited early: $($process.StandardError.ReadToEnd())" }
        Start-Sleep -Milliseconds 20
    }
    if (-not (Test-Path -LiteralPath $ReadyFile -PathType Leaf)) {
        try { $process.Kill($true) } catch {}
        throw 'Release fixture server did not become ready.'
    }
    return $process
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $install = Join-Path $temporaryRoot 'install'
    $prepared = Join-Path $temporaryRoot 'prepared'
    $state = Join-Path $temporaryRoot 'state'
    New-Item -ItemType Directory -Path $state | Out-Null
    $journal = Join-Path $state 'transaction.json'
    $archiveHash = New-PreparedFixture $prepared

    # A prepared tree is bound to the retained archive bytes, not only mutable metadata.
    $archivePath = Join-Path $prepared '.chatgpt-remote-release.zip'
    $archiveBytes = [IO.File]::ReadAllBytes($archivePath)
    [IO.File]::WriteAllBytes($archivePath, [Text.Encoding]::UTF8.GetBytes('tampered archive'))
    $tamperOutput = @(& $node $helper validate-prepared --prepared-root $prepared --platform Windows-x64 --version v2.0.0 --archive-sha256 $archiveHash 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($tamperOutput -join ' ') -notmatch 'Retained prepared archive changed') {
        throw 'Prepared archive tampering was not rejected.'
    }
    [IO.File]::WriteAllBytes($archivePath, $archiveBytes)

    # Normal apply replaces tracked files, removes obsolete tracked files, and preserves integrity.
    New-InstalledFixture $install
    $normal = Invoke-Helper @(Get-ApplyArguments $install $prepared $journal (Join-Path $state 'rollback-normal') $archiveHash)
    if ($normal.updated -ne $true -or $normal.version -ne 'v2.0.0' -or (Test-Path -LiteralPath (Join-Path $install 'removed.txt'))) {
        throw 'Normal transactional apply produced the wrong installed state.'
    }
    $integrity = Invoke-Helper @('integrity', '--install-root', $install)
    if ($integrity.integrityValid -ne $true -or $integrity.version -ne 'v2.0.0') { throw 'Installed integrity validation failed.' }

    # Preload instrumentation blocks immediately after the first journal count is durably renamed.
    $hook = Join-Path $temporaryRoot 'pause-after-journal.js'
    Write-Utf8File $hook @'
const fs = require("node:fs");
const childProcess = require("node:child_process");
function pauseAfterDurableCount(destination) {
  if (destination === process.env.CHATGPT_REMOTE_TEST_JOURNAL) {
    try {
      const journal = JSON.parse(fs.readFileSync(destination, "utf8"));
      if (journal.completedOperations === Number(process.env.CHATGPT_REMOTE_TEST_PAUSE_COUNT)) {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
      }
    } catch {}
  }
}
const originalRename = fs.renameSync;
fs.renameSync = function patchedRename(source, destination) {
  const result = originalRename.apply(this, arguments);
  pauseAfterDurableCount(destination);
  return result;
};
const originalSpawnSync = childProcess.spawnSync;
childProcess.spawnSync = function patchedSpawnSync() {
  const result = originalSpawnSync.apply(this, arguments);
  pauseAfterDurableCount(arguments[2]?.env?.CHATGPT_REMOTE_REPLACE_DESTINATION);
  return result;
};
const originalMkdir = fs.mkdirSync;
fs.mkdirSync = function patchedMkdir(directory) {
  const result = originalMkdir.apply(this, arguments);
  if (process.env.CHATGPT_REMOTE_TEST_RECLAIM_READY && String(directory).endsWith(".writer.lock.reclaim")) {
    fs.writeFileSync(process.env.CHATGPT_REMOTE_TEST_RECLAIM_READY, "ready");
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1500);
  }
  return result;
};
'@

    $operationCount = $null
    $targetCount = 0
    do {
        New-InstalledFixture $install
        Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
        $crashBackup = Join-Path $state "rollback-crash-$targetCount"
        $crashState = Start-PausedApply (Get-ApplyArguments $install $prepared $journal $crashBackup $archiveHash) $journal $hook $targetCount
        if ([int]$crashState.completedOperations -ne $targetCount) {
            throw "Hard kill observed count $($crashState.completedOperations) instead of $targetCount."
        }
        if ($null -eq $operationCount) { $operationCount = @($crashState.operations).Count }
        $recovered = Invoke-Helper @('recover', '--journal-path', $journal, '--install-root', $install)
        if ($recovered.recovered -ne $true -or $recovered.recoveryMode -ne 'complete-forward' -or $recovered.integrityValid -ne $true) {
            throw "Hard-killed apply did not complete forward from completedOperations=$targetCount."
        }
        $targetCount++
    } while ($targetCount -le $operationCount)

    # Killing only the PowerShell parent must not expose the orphan Node writer.
    New-InstalledFixture $install
    $orphanAppData = Join-Path $temporaryRoot 'orphan-appdata'
    $orphanJournal = Join-Path $orphanAppData 'ChatGPTRemoteEnabler\update\transaction.json'
    $orphanArguments = @(
        '-NoProfile', '-File', $updater, '-Action', 'ApplyPrepared', '-LaunchLockHeld', '-InstallRoot', $install,
        '-TargetVersion', 'v2.0.0', '-ExpectedArchiveSha256', $archiveHash, '-PreparedDirectory', $prepared,
        '-LockTimeoutSeconds', '3'
    )
    $orphanEnvironment = @{
        LOCALAPPDATA = $orphanAppData
        CHATGPT_REMOTE_LAUNCH_GUARD_HELD = '1'
        NODE_OPTIONS = "--require=$hook"
        CHATGPT_REMOTE_TEST_JOURNAL = $orphanJournal
        CHATGPT_REMOTE_TEST_PAUSE_COUNT = '1'
    }
    $updaterParent = Start-CapturedProcess $pwsh $orphanArguments $orphanEnvironment
    $writerOwnerPath = "$orphanJournal.writer.lock\owner.json"
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ($updaterParent.HasExited) { throw "Updater parent exited before orphan boundary: $($updaterParent.StandardError.ReadToEnd())" }
        if ((Test-Path -LiteralPath $orphanJournal -PathType Leaf) -and (Test-Path -LiteralPath $writerOwnerPath -PathType Leaf)) {
            try {
                $orphanJournalState = Read-JsonSnapshotShared -Path $orphanJournal
                if ([int]$orphanJournalState.completedOperations -eq 1) { break }
            } catch [Management.Automation.RuntimeException] {}
        }
        Start-Sleep -Milliseconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    if ([int]$orphanJournalState.completedOperations -ne 1) { throw 'Orphan writer did not reach its durable pause boundary.' }
    $writerOwner = Get-Content -LiteralPath $writerOwnerPath -Raw | ConvertFrom-Json
    $updaterParent.Kill()
    $updaterParent.WaitForExit()
    $updaterParent.Dispose()
    if (-not (Get-Process -Id ([int]$writerOwner.pid) -ErrorAction SilentlyContinue)) { throw 'Killing the updater parent unexpectedly killed its Node writer.' }
    $busyOrphan = Invoke-PowerShellChild @('-NoProfile', '-File', $updater, '-Action', 'Recover', '-LaunchLockHeld', '-InstallRoot', $install, '-LockTimeoutSeconds', '2') @{
        LOCALAPPDATA = $orphanAppData
        CHATGPT_REMOTE_LAUNCH_GUARD_HELD = '1'
    }
    if ($busyOrphan.ExitCode -eq 0 -or ($busyOrphan.StdOut + $busyOrphan.StdErr) -notmatch 'UPDATE_BUSY') {
        throw 'A second Recover was not blocked by the live orphan transaction writer.'
    }
    Stop-Process -Id ([int]$writerOwner.pid) -Force
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do { Start-Sleep -Milliseconds 10 } while ((Get-Process -Id ([int]$writerOwner.pid) -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline)

    # Two stale-lock contenders serialize reclamation and only one enters recovery.
    $reclaimReady = Join-Path $temporaryRoot 'reclaim.ready'
    $recoverArguments = @($helper, 'recover', '--journal-path', $orphanJournal, '--install-root', $install)
    $firstReclaimer = Start-CapturedProcess $node $recoverArguments @{ NODE_OPTIONS = "--require=$hook"; CHATGPT_REMOTE_TEST_RECLAIM_READY = $reclaimReady }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $reclaimReady -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        if ($firstReclaimer.HasExited) { throw "First stale-lock reclaimer exited early: $($firstReclaimer.StandardError.ReadToEnd())" }
        Start-Sleep -Milliseconds 10
    }
    if (-not (Test-Path -LiteralPath $reclaimReady -PathType Leaf)) { throw 'First stale-lock reclaimer did not acquire its serialized guard.' }
    $secondReclaimerOutput = @(& $node $helper recover --journal-path $orphanJournal --install-root $install 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($secondReclaimerOutput -join ' ') -notmatch 'UPDATE_BUSY.*reclaimed') {
        throw 'A concurrent stale-lock reclaimer was not rejected.'
    }
    $firstReclaimer.WaitForExit()
    $firstReclaimerOutput = $firstReclaimer.StandardOutput.ReadToEnd()
    $firstReclaimerError = $firstReclaimer.StandardError.ReadToEnd()
    if ($firstReclaimer.ExitCode -ne 0 -or ($firstReclaimerOutput | ConvertFrom-Json).integrityValid -ne $true) {
        throw "Serialized stale-lock recovery failed: $firstReclaimerError"
    }
    $firstReclaimer.Dispose()

    # If prepared content disappears after a hard kill, recovery uses verified backups.
    New-InstalledFixture $install
    Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
    [void](Start-PausedApply (Get-ApplyArguments $install $prepared $journal (Join-Path $state 'rollback-damaged') $archiveHash) $journal $hook $operationCount)
    Remove-Item -LiteralPath $prepared -Recurse -Force
    $rolledBack = Invoke-Helper @('recover', '--journal-path', $journal, '--install-root', $install)
    if ($rolledBack.recoveryMode -ne 'rollback' -or $rolledBack.version -ne 'v1.0.0' -or -not (Test-Path -LiteralPath (Join-Path $install 'removed.txt'))) {
        throw 'Recovery did not roll back after prepared content was removed.'
    }

    # Altered destinations fail closed before touching an external sentinel.
    $archiveHash = New-PreparedFixture $prepared
    New-InstalledFixture $install
    Remove-Item -LiteralPath $journal -Force -ErrorAction SilentlyContinue
    [void](Start-PausedApply (Get-ApplyArguments $install $prepared $journal (Join-Path $state 'rollback-ambiguous') $archiveHash) $journal $hook ([Math]::Min(1, $operationCount)))
    $sentinel = Join-Path $temporaryRoot 'outside.txt'
    Write-Utf8File $sentinel 'outside remains unchanged'
    $journalObject = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
    $journalObject.operations[0].destination = $sentinel
    Write-Utf8File $journal (($journalObject | ConvertTo-Json -Depth 8) + "`n")
    $unsafeOutput = @(& $node $helper recover --journal-path $journal --install-root $install 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($unsafeOutput -join ' ') -notmatch 'UNSAFE_MIXED_INSTALL' -or (Get-Content -LiteralPath $sentinel -Raw) -ne 'outside remains unchanged') {
        throw 'Ambiguous journal confinement did not fail closed.'
    }
    New-InstalledFixture $install

    # Real updater actions bind Check -> Prepare -> ApplyPrepared to one exact tag and archive digest.
    $releaseContent = Join-Path $temporaryRoot 'release-content'
    New-Item -ItemType Directory -Path $releaseContent | Out-Null
    Write-Utf8File (Join-Path $releaseContent 'VERSION') "v2.0.0`n"
    Write-Utf8File (Join-Path $releaseContent 'payload.txt') 'adapter payload'
    Write-Utf8File (Join-Path $releaseContent 'added.txt') 'adapter added file'
    Copy-Item -LiteralPath $updater -Destination (Join-Path $releaseContent 'Update-ChatGPTRemote.ps1')
    Copy-Item -LiteralPath $helper -Destination (Join-Path $releaseContent 'update-transaction.js')
    Write-Manifest $releaseContent
    $releaseArchiveName = 'ChatGPT-Remote-Enabler-Windows-x64-v2.0.0.zip'
    $releaseArchive = Join-Path $temporaryRoot $releaseArchiveName
    Compress-Archive -Path (Join-Path $releaseContent '*') -DestinationPath $releaseArchive -CompressionLevel NoCompression
    $releaseHash = (Get-FileHash -LiteralPath $releaseArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumsName = 'SHA256SUMS-v2.0.0.txt'
    $checksumsFile = Join-Path $temporaryRoot $checksumsName
    Write-Utf8File $checksumsFile "$releaseHash *$releaseArchiveName`n"
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $serverPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $metadataFile = Join-Path $temporaryRoot 'release.json'
    $baseUrl = "http://127.0.0.1:$serverPort"
    [ordered]@{
        tag_name = 'v2.0.0'
        draft = $false
        prerelease = $false
        assets = @(
            [ordered]@{ name = $releaseArchiveName; browser_download_url = "$baseUrl/archive"; digest = "sha256:$releaseHash" },
            [ordered]@{ name = $checksumsName; browser_download_url = "$baseUrl/checksums" }
        )
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataFile -Encoding UTF8
    $serverScript = Join-Path $temporaryRoot 'release-server.js'
    Write-Utf8File $serverScript @'
const fs = require("node:fs");
const http = require("node:http");
const metadata = fs.readFileSync(process.env.CHATGPT_REMOTE_TEST_METADATA);
const archive = fs.readFileSync(process.env.CHATGPT_REMOTE_TEST_ARCHIVE);
const checksums = fs.readFileSync(process.env.CHATGPT_REMOTE_TEST_CHECKSUMS);
const server = http.createServer((request, response) => {
  if (request.url === "/archive") {
    response.writeHead(200, { "content-type": "application/zip" });
    response.end(archive);
  } else if (request.url === "/checksums") {
    response.writeHead(200, { "content-type": "text/plain" });
    response.end(checksums);
  } else {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(metadata);
  }
});
server.listen(Number(process.env.CHATGPT_REMOTE_TEST_PORT), "127.0.0.1", () => {
  fs.writeFileSync(process.env.CHATGPT_REMOTE_TEST_READY, "ready");
});
'@
    $readyFile = Join-Path $temporaryRoot 'release-server.ready'
    $server = Start-ReleaseServer $serverScript $metadataFile $releaseArchive $checksumsFile $readyFile $serverPort
    try {
        $adapterAppData = Join-Path $temporaryRoot 'adapter-appdata'
        $adapterEnvironment = @{ LOCALAPPDATA = $adapterAppData }
        $commonUpdaterArguments = @('-NoProfile', '-File', $updater, '-InstallRoot', $install, '-LatestReleaseUrl', "$baseUrl/latest", '-AllowInsecureTransport', '-LockTimeoutSeconds', '3')
        $checkChild = Invoke-PowerShellChild ($commonUpdaterArguments + @('-Action', 'Check')) $adapterEnvironment
        if ($checkChild.ExitCode -ne 0) { throw "Updater Check fixture failed: $($checkChild.StdErr)" }
        $checkResult = $checkChild.StdOut | ConvertFrom-Json
        if ($checkResult.archiveSha256 -ne $releaseHash -or $checkResult.latestVersion -ne 'v2.0.0' -or $checkResult.available -ne $true) {
            throw 'Updater Check did not return the published archive digest for the exact release.'
        }
        $adapterPrepared = Join-Path $temporaryRoot 'adapter-prepared'
        $pinnedArguments = @('-TargetVersion', 'v2.0.0', '-ExpectedArchiveSha256', $releaseHash, '-PreparedDirectory', $adapterPrepared)
        $prepareChild = Invoke-PowerShellChild ($commonUpdaterArguments + @('-Action', 'Prepare') + $pinnedArguments) $adapterEnvironment
        if ($prepareChild.ExitCode -ne 0) { throw "Updater Prepare fixture failed: $($prepareChild.StdErr)" }
        $prepareResult = $prepareChild.StdOut | ConvertFrom-Json
        if ($prepareResult.prepared -ne $true -or $prepareResult.archiveSha256 -ne $releaseHash) { throw 'Updater Prepare returned the wrong pinned result.' }
        $applyChild = Invoke-PowerShellChild ($commonUpdaterArguments + @('-Action', 'ApplyPrepared') + $pinnedArguments) $adapterEnvironment
        if ($applyChild.ExitCode -ne 0) { throw "Updater ApplyPrepared fixture failed: $($applyChild.StdErr)" }
        $applyResult = $applyChild.StdOut | ConvertFrom-Json
        if ($applyResult.updated -ne $true -or $applyResult.archiveSha256 -ne $releaseHash -or (Get-Content -LiteralPath (Join-Path $install 'payload.txt') -Raw) -ne 'adapter payload') {
            throw 'Updater ApplyPrepared did not install the exact prepared archive.'
        }
    } finally {
        if (-not $server.HasExited) { $server.Kill($true); $server.WaitForExit() }
        $server.Dispose()
    }

    # Updater lock contention is bounded and reports UPDATE_BUSY.
    $appData = Join-Path $temporaryRoot 'appdata'
    $updateState = Join-Path $appData 'ChatGPTRemoteEnabler\update'
    New-Item -ItemType Directory -Path $updateState -Force | Out-Null
    $lockPath = Join-Path $updateState 'update.lock'
    $heldLock = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $busy = Invoke-PowerShellChild @('-NoProfile', '-File', $updater, '-Action', 'Recover', '-InstallRoot', $install, '-LockTimeoutSeconds', '1') @{ LOCALAPPDATA = $appData }
        if ($busy.ExitCode -eq 0 -or ($busy.StdErr + $busy.StdOut) -notmatch 'UPDATE_BUSY') { throw 'Updater lock contention was not bounded.' }
    } finally {
        $heldLock.Dispose()
    }

    # Launcher-owned Recover can run, but a new ApplyPrepared waits for the launch guard.
    $launcherMutex = [Threading.Mutex]::new($false, 'Local\ChatGPTCustomInjectionLauncher')
    [void]$launcherMutex.WaitOne()
    try {
        $recoverChild = Invoke-PowerShellChild @('-NoProfile', '-File', $updater, '-Action', 'Recover', '-LaunchLockHeld', '-InstallRoot', $install, '-LockTimeoutSeconds', '1') @{ LOCALAPPDATA = $appData; CHATGPT_REMOTE_LAUNCH_GUARD_HELD = '1' }
        if ($recoverChild.ExitCode -ne 0 -or (($recoverChild.StdOut -join '') | ConvertFrom-Json).integrityValid -ne $true) {
            throw "Launcher-owned recovery failed: $($recoverChild.StdErr)"
        }
        $blockedApply = Invoke-PowerShellChild @(
            '-NoProfile', '-File', $updater, '-Action', 'ApplyPrepared', '-InstallRoot', $install,
            '-TargetVersion', 'v2.0.0', '-ExpectedArchiveSha256', $archiveHash,
            '-PreparedDirectory', $prepared, '-LockTimeoutSeconds', '1'
        ) @{ LOCALAPPDATA = $appData }
        if ($blockedApply.ExitCode -eq 0 -or ($blockedApply.StdErr + $blockedApply.StdOut) -notmatch 'UPDATE_BUSY') {
            throw 'ApplyPrepared entered the launcher read/injection window.'
        }
    } finally {
        $launcherMutex.ReleaseMutex()
        $launcherMutex.Dispose()
    }

    $global:LASTEXITCODE = 0
    [pscustomobject]@{
        PreparedArchiveTamperRejected = $true
        NormalApplyIntegrity = $true
        HardKillCompleteForwardBoundaries = $operationCount + 1
        ParentOnlyKillWriterGuard = $true
        ConcurrentStaleReclaimSerialized = $true
        DamagedPreparedRollback = $true
        AmbiguousJournalFailsClosed = $true
        PinnedUpdaterAdapterFlow = $true
        BoundedUpdateLock = $true
        LaunchGuardCoversInjectionWindow = $true
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
