[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$node = (Get-Command node.exe -ErrorAction Stop).Source
$helper = Join-Path $root 'windows\CodexRemoteMobileProject\maintenance.js'
$nodeTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$testRoot = Join-Path $nodeTemp ('chatgpt-remote-maintenance-test-' + [guid]::NewGuid().ToString('N'))
$strictFailureRoot = Join-Path $nodeTemp ('chatgpt-remote-maintenance-test-' + [guid]::NewGuid().ToString('N'))
$bestEffortFailureRoot = Join-Path $nodeTemp ('chatgpt-remote-maintenance-test-' + [guid]::NewGuid().ToString('N'))
$lookalikeRoot = "$testRoot-sibling"
$linkRoot = Join-Path $nodeTemp ('chatgpt-remote-maintenance-test-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $createFixture = @'
const { DatabaseSync } = require("node:sqlite");
const path = require("node:path");
const root = process.argv[2];
let db = new DatabaseSync(path.join(root, "logs_2.sqlite"));
db.exec("CREATE TABLE logs(id INTEGER PRIMARY KEY, ts INTEGER, estimated_bytes INTEGER, body TEXT); BEGIN");
let insert = db.prepare("INSERT INTO logs(ts, estimated_bytes, body) VALUES(?, ?, ?)");
for (let index = 0; index < 240; index += 1) insert.run(Math.floor(Date.now() / 1000) - 9 * 86400, 50000, "x".repeat(50000));
for (let index = 0; index < 20; index += 1) insert.run(Math.floor(Date.now() / 1000), 50000, "y".repeat(50000));
db.exec("COMMIT");
db.close();
db = new DatabaseSync(path.join(root, "state_5.sqlite"));
db.exec("CREATE TABLE junk(id INTEGER PRIMARY KEY, body TEXT); BEGIN");
insert = db.prepare("INSERT INTO junk(body) VALUES(?)");
for (let index = 0; index < 240; index += 1) insert.run("z".repeat(50000));
db.exec("COMMIT; DELETE FROM junk");
db.close();
'@
    $createFixturePath = Join-Path $testRoot 'create-fixture.js'
    Set-Content -LiteralPath $createFixturePath -Value $createFixture -Encoding UTF8
    & $node --no-warnings $createFixturePath $testRoot
    if ($LASTEXITCODE -ne 0) { throw 'Maintenance fixture creation failed.' }
    $logsBefore = (Get-Item -LiteralPath (Join-Path $testRoot 'logs_2.sqlite')).Length
    $stateBefore = (Get-Item -LiteralPath (Join-Path $testRoot 'state_5.sqlite')).Length
    $report = & $node --no-warnings $helper --test-temp --codex-home $testRoot | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $report.status -ne 'completed') { throw 'Maintenance helper did not complete.' }
    $readResult = @'
const { DatabaseSync } = require("node:sqlite");
const path = require("node:path");
const db = new DatabaseSync(path.join(process.argv[2], "logs_2.sqlite"), { readOnly: true });
console.log(JSON.stringify(db.prepare("SELECT COUNT(*) AS rows, COALESCE(SUM(estimated_bytes), 0) AS estimated FROM logs").get()));
db.close();
'@
    $readResultPath = Join-Path $testRoot 'read-result.js'
    Set-Content -LiteralPath $readResultPath -Value $readResult -Encoding UTF8
    $remaining = & $node --no-warnings $readResultPath $testRoot | ConvertFrom-Json
    if ($remaining.rows -ne 20 -or $remaining.estimated -ne 1000000) { throw 'Expired-log retention result is incorrect.' }
    if ($report.logs.removedByAge -ne 240 -or -not $report.logs.vacuumed) { throw 'Log pruning or vacuum proof failed.' }
    if (-not $report.state.vacuumed) { throw 'State-database vacuum proof failed.' }
    if ($report.logs.fileBytesAfter -ge $logsBefore -or $report.state.fileBytesAfter -ge $stateBefore) { throw 'Database files did not shrink.' }
    if ($report.durationMs -lt 0 -or @($report.phases).Count -ne 4 -or @($report.phases | Where-Object { $_.durationMs -lt 0 }).Count) {
        throw 'Maintenance helper did not report privacy-safe phase timing.'
    }

    $sqliteBlockerPath = Join-Path $testRoot 'block-sqlite.js'
    [IO.File]::WriteAllText($sqliteBlockerPath, @'
const Module = require("node:module");
const originalLoad = Module._load;
Module._load = function(request, parent, isMain) {
  if (request === "node:sqlite") throw new Error("fixture sqlite unavailable");
  return originalLoad.call(this, request, parent, isMain);
};
'@, [Text.UTF8Encoding]::new($false))
    $sqliteUnavailableJson = & $node --no-warnings --require $sqliteBlockerPath $helper --test-temp --codex-home $testRoot
    $sqliteUnavailableExitCode = $LASTEXITCODE
    $sqliteUnavailableReport = $sqliteUnavailableJson | ConvertFrom-Json
    if ($sqliteUnavailableExitCode -ne 0 -or $sqliteUnavailableReport.status -ne 'skipped-node-sqlite-unavailable') {
        throw 'Unavailable Node SQLite did not remain a benign exit-zero skip.'
    }

    foreach ($failureRoot in @($strictFailureRoot, $bestEffortFailureRoot)) {
        New-Item -ItemType Directory -Path $failureRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $testRoot 'logs_2.sqlite') -Destination (Join-Path $failureRoot 'logs_2.sqlite')
        [IO.File]::WriteAllBytes((Join-Path $failureRoot 'state_5.sqlite'), [byte[]](0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x2D, 0x62, 0x72, 0x6F, 0x6B, 0x65, 0x6E))
    }

    $strictJson = & $node --no-warnings $helper --test-temp --codex-home $strictFailureRoot
    $strictExitCode = $LASTEXITCODE
    $strictReport = $strictJson | ConvertFrom-Json
    if ($strictExitCode -eq 0 -or $strictReport.status -ne 'failed' -or
        $strictReport.error.phase -ne 'state-database' -or $strictReport.error.database -ne 'state') {
        throw 'Strict maintenance did not return a structured nonzero second-database failure.'
    }
    if ($strictReport.logs.status -ne 'optimized' -or @($strictReport.phases)[-1].status -ne 'failed' -or
        @($strictReport.phases)[-1].database -ne 'state') {
        throw 'Strict maintenance did not retain successful first-database evidence or stop at the failed phase.'
    }
    if (($strictJson -join '') -like "*$strictFailureRoot*") {
        throw 'Strict maintenance disclosed a private fixture path in its report.'
    }
    $strictState = Join-Path $strictFailureRoot 'state_5.sqlite'
    $strictStateMoved = Join-Path $strictFailureRoot 'state_5.closed-proof'
    Move-Item -LiteralPath $strictState -Destination $strictStateMoved
    Move-Item -LiteralPath $strictStateMoved -Destination $strictState

    $bestEffortJson = & $node --no-warnings $helper --best-effort --test-temp --codex-home $bestEffortFailureRoot
    $bestEffortExitCode = $LASTEXITCODE
    $bestEffortReport = $bestEffortJson | ConvertFrom-Json
    if ($bestEffortExitCode -ne 0 -or $bestEffortReport.status -ne 'completed-with-warning' -or
        $bestEffortReport.warning.phase -ne 'state-database' -or $bestEffortReport.warning.database -ne 'state' -or
        $bestEffortReport.logs.status -ne 'optimized' -or @($bestEffortReport.phases)[-1].status -ne 'failed') {
        throw 'Best-effort maintenance did not return a structured exit-zero second-database warning.'
    }
    if (($bestEffortJson -join '') -like "*$bestEffortFailureRoot*") {
        throw 'Best-effort maintenance disclosed a private fixture path in its report.'
    }
    New-Item -ItemType Directory -Path $lookalikeRoot | Out-Null
    $runningProcessFixturePath = Join-Path $testRoot 'running-process.js'
    [IO.File]::WriteAllText($runningProcessFixturePath, @'
const childProcess = require("node:child_process");
childProcess.spawnSync = function() {
  return { status: 0, stdout: '"ChatGPT.exe","4242","Console","1","100 K"\n' };
};
'@, [Text.UTF8Encoding]::new($false))
    $lookalikeJson = & $node --no-warnings --require $runningProcessFixturePath $helper --test-temp --codex-home $lookalikeRoot
    $lookalikeExitCode = $LASTEXITCODE
    $lookalikeReport = $lookalikeJson | ConvertFrom-Json
    if ($lookalikeExitCode -ne 0 -or $lookalikeReport.processState.testOverride -or
        $lookalikeReport.status -ne 'skipped-app-running-or-process-check-failed') {
        throw 'A sibling prefix lookalike bypassed the maintenance process guard or produced a fatal result.'
    }
    New-Item -ItemType Junction -Path $linkRoot -Target $lookalikeRoot | Out-Null
    $linkJson = & $node --no-warnings $helper --best-effort --test-temp --codex-home $linkRoot
    $linkExitCode = $LASTEXITCODE
    $linkReport = $linkJson | ConvertFrom-Json
    if ($linkExitCode -ne 0 -or $linkReport.processState.testOverride) {
        throw 'A temporary-root junction bypassed the maintenance process guard or produced a fatal result.'
    }
    [pscustomobject]@{
        ExpiredRowsRemoved = [int]$report.logs.removedByAge
        RemainingRows = [int]$remaining.rows
        LogsShrank = $report.logs.fileBytesAfter -lt $logsBefore
        StateShrank = $report.state.fileBytesAfter -lt $stateBefore
        Vacuumed = [bool]($report.logs.vacuumed -and $report.state.vacuumed)
        PrefixLookalikeRejected = $true
        JunctionRejected = $true
        StrictFailureExitCode = $strictExitCode
        StrictSecondDatabaseFailure = $true
        BestEffortExitCode = $bestEffortExitCode
        BestEffortWarning = $true
        PriorPhaseEvidenceRetained = $true
        DatabaseClosedAfterError = $true
        PhaseTimingReported = $true
        ProcessGuardsRemainBenign = $true
        SqliteUnavailableRemainsBenign = $true
    } | ConvertTo-Json -Compress
} finally {
    $temporary = [IO.Path]::GetFullPath($nodeTemp)
    if (Test-Path -LiteralPath $linkRoot) { Remove-Item -LiteralPath $linkRoot -Force }
    foreach ($candidate in @($testRoot, $strictFailureRoot, $bestEffortFailureRoot, $lookalikeRoot)) {
        $resolved = [IO.Path]::GetFullPath($candidate)
        if ((Test-Path -LiteralPath $resolved) -and
            [IO.Path]::GetFullPath((Split-Path -Parent $resolved)) -eq $temporary -and
            [IO.Path]::GetFileName($resolved) -match '^chatgpt-remote-maintenance-test-[0-9a-f]{32}(?:-sibling)?$') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
