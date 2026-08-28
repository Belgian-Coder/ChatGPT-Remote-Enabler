[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$node = (Get-Command node.exe -ErrorAction Stop).Source
$helper = Join-Path $root 'windows\CodexRemoteMobileProject\maintenance.js'
$nodeTemp = (& $node -p 'require("node:os").tmpdir()').Trim()
$testRoot = Join-Path $nodeTemp ('chatgpt-remote-maintenance-test-' + [guid]::NewGuid().ToString('N'))

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
    [pscustomobject]@{
        ExpiredRowsRemoved = [int]$report.logs.removedByAge
        RemainingRows = [int]$remaining.rows
        LogsShrank = $report.logs.fileBytesAfter -lt $logsBefore
        StateShrank = $report.state.fileBytesAfter -lt $stateBefore
        Vacuumed = [bool]($report.logs.vacuumed -and $report.state.vacuumed)
    } | ConvertTo-Json -Compress
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporary = [IO.Path]::GetFullPath($nodeTemp)
    if ((Test-Path -LiteralPath $resolved) -and $resolved.StartsWith($temporary, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
