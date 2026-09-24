[CmdletBinding()]
param([switch]$LiveBroker)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $repoRoot 'windows\UnvirtualizedShortcuts.ps1'
. $helper

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Expected)
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    if (-not $failure -or $failure -notlike "*$Expected*") { throw "Expected rejection '$Expected'; received '$failure'." }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('shortcut-broker-test-' + [char]0x00e9 + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $stableScript = Join-Path $repoRoot 'windows\StableInstall.ps1'
    $directoryProbe = Get-UnvirtualizedShortcutPathIdentity -Path $fixture
    if ($directoryProbe.RedirectedToPackageCache) { throw 'The isolated fixture unexpectedly resolves into package storage.' }
    $sentinel = Join-Path $fixture 'untouched.txt'
    [IO.File]::WriteAllText($sentinel, 'unchanged')
    $named = ConvertTo-UnvirtualizedShortcutInvocationArguments -Arguments ('{"TaskPrimary":false,"ShortcutPaths":["C:\\first","C:\\with space"],"StableRoot":"C:\\fixture"}' | ConvertFrom-Json)
    if ($named.TaskPrimary -isnot [bool] -or $named.TaskPrimary -or $named.ShortcutPaths.Count -ne 2 -or $named.ShortcutPaths[1] -cne 'C:\with space') { throw 'JSON arguments changed types or values.' }
    Assert-Rejected { Test-UnvirtualizedShortcutArguments -Operation MigrateShortcuts -Arguments ([pscustomobject]@{ Command = 'unexpected' }) } 'not allowed'
    Assert-Rejected { Test-UnvirtualizedShortcutScriptPath -Operation DesktopShortcutOperation -ScriptPath $stableScript } 'requires DesktopShortcut.ps1'
    Assert-Rejected { Test-UnvirtualizedShortcutArguments -Operation DesktopShortcutOperation -Arguments ([pscustomobject]@{Action='Install';Confirm=$true}) } 'Interactive confirmation is not supported'
    Assert-Rejected { Test-UnvirtualizedShortcutScriptPath -Operation StartupShortcutOperation -ScriptPath $stableScript } 'requires StartupShortcut.ps1'
    $job = New-UnvirtualizedShortcutWorkerJob -Operation MigrateShortcuts -ScriptPath $stableScript -Arguments ([pscustomobject]@{StableRoot=$fixture}) -ProbePaths @($fixture) -ResultPath (Join-Path $fixture 'result.json') -TimeoutMilliseconds 10000
    $jobPath = Join-Path $fixture 'job.json'
    $job.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o')
    $job | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jobPath -Encoding utf8
    Assert-Rejected { Invoke-UnvirtualizedShortcutWorkerBody -JobPath $jobPath } 'expired before mutation'
    $job.DeadlineUtc = [DateTime]::UtcNow.AddMinutes(1).ToString('o')
    $job.Hop = 2
    $job | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jobPath -Encoding utf8
    Assert-Rejected { Invoke-UnvirtualizedShortcutWorkerBody -JobPath $jobPath } 'recursive'
    if ([IO.File]::ReadAllText($sentinel) -cne 'unchanged' -or (Test-Path -LiteralPath (Join-Path $fixture 'result.json'))) { throw 'Rejected jobs changed fixture state.' }
    $script:UnvirtualizedShortcutBrokerActive = $true
    try {
        Assert-Rejected { Invoke-UnvirtualizedShortcutWorker -Operation TestEntryPoints -ScriptPath $stableScript -Arguments @{} -ProbePaths @($fixture) } 'recursion'
    } finally { $script:UnvirtualizedShortcutBrokerActive = $false }

    # A blocked shortcut implementation must be stopped by the supervisor's
    # exact child handle, and abandoned protocol files must be reclaimed.
    $blockedJobRoot = Join-Path $fixture ('chatgpt-remote-unvirtualized-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $blockedJobRoot | Out-Null
    $blockedScript = Join-Path $blockedJobRoot 'StableInstall.ps1'
    [IO.File]::WriteAllText($blockedScript, @'
function Invoke-StableShortcutMigration {
    param([string]$StableRoot)
    [IO.File]::WriteAllText((Join-Path $StableRoot 'worker-pid.txt'), [string]$PID)
    Start-Sleep -Seconds 30
}
'@)
    $blockedJob = New-UnvirtualizedShortcutWorkerJob -Operation MigrateShortcuts -ScriptPath $blockedScript -Arguments ([pscustomobject]@{StableRoot=$blockedJobRoot}) -ProbePaths @($blockedJobRoot) -ResultPath (Join-Path $blockedJobRoot 'result.json') -TimeoutMilliseconds 5000
    $blockedJobPath = Join-Path $blockedJobRoot 'job.json'
    [IO.File]::WriteAllText($blockedJobPath, ($blockedJob | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Assert-Rejected { Invoke-UnvirtualizedShortcutSupervisor -JobPath $blockedJobPath } 'exceeded its deadline and was stopped'
    $blockedPid = [int][IO.File]::ReadAllText((Join-Path $blockedJobRoot 'worker-pid.txt'))
    if (Get-Process -Id $blockedPid -ErrorAction SilentlyContinue) { throw 'The owned blocked shortcut worker is still running.' }
    Remove-UnvirtualizedShortcutJobArtifacts -JobPath $blockedJobPath
    if (Test-Path -LiteralPath $blockedJobRoot) { throw 'Abandoned shortcut protocol artifacts were retained.' }

    & {
        . $stableScript
        function Invoke-StableShortcutBroker { throw 'fixture Explorer is unavailable' }
        New-Item -ItemType Directory -Path (Join-Path $fixture 'CodexRemoteMobileProject') | Out-Null
        [IO.File]::WriteAllText((Join-Path $fixture 'ChatGPT Remote Enabler.exe'), 'fixture')
        [IO.File]::WriteAllText((Join-Path $fixture 'CodexRemoteMobileProject\ChatGPT Custom.exe'), 'fixture')
        $failure = @(Invoke-StableShortcutMigration -StableRoot $fixture -DesktopPath $fixture -StartMenuPath $fixture -StartupPath $fixture)
        if ($failure.Count -ne 1 -or $failure[0].migrated -or $failure[0].reason -cne 'shortcut-broker-failed') { throw 'A broker failure escaped the nonfatal migration result.' }
    }

    & {
        . $stableScript
        $fakeHelperRoot = Join-Path $fixture 'fast-probe'
        New-Item -ItemType Directory -Path $fakeHelperRoot | Out-Null
        [IO.File]::WriteAllText((Join-Path $fakeHelperRoot 'UnvirtualizedShortcuts.ps1'), @'
function Get-UnvirtualizedShortcutPathIdentity { param($Path) [pscustomobject]@{ RedirectedToPackageCache = $script:fakeRedirected } }
function Invoke-UnvirtualizedShortcutWorker { $script:fakeBrokerCalls++; [pscustomobject]@{ Output = @($true) } }
'@)
        # Redirect only the known-folder lookup and helper dependency to the
        # fixture; exercise the actual dispatch decision without a live shell.
        $body = (Get-Command Invoke-StableShortcutBroker).Definition.Replace("[Environment]::GetFolderPath('Programs')", '$fixture')
        $body = $body.Replace('$PSScriptRoot', ("'" + $fakeHelperRoot.Replace("'", "''") + "'"))
        $dispatch = [scriptblock]::Create($body)
        $canonical = Join-Path $fixture 'ChatGPT Remote Enabler.lnk'
        [IO.File]::WriteAllText($canonical, 'fixture')
        $arguments = @{ RequiredStartMenuPath = $fixture; ShortcutPaths = @($canonical) }
        $script:fakeBrokerCalls = 0; $script:fakeRedirected = $false
        $local = & $dispatch -Operation TestEntryPoints -Arguments $arguments -Paths @($fixture)
        if ($local.handled -or $script:fakeBrokerCalls -ne 0) { throw 'A native read-only shortcut probe used the broker.' }
        $script:fakeRedirected = $true
        $redirected = & $dispatch -Operation TestEntryPoints -Arguments $arguments -Paths @($fixture)
        if (-not $redirected.handled -or $script:fakeBrokerCalls -ne 1) { throw 'A redirected shortcut probe skipped the broker.' }
        $script:fakeRedirected = $false
        Remove-Item -LiteralPath $canonical -Force
        $missing = & $dispatch -Operation TestEntryPoints -Arguments $arguments -Paths @($fixture)
        if (-not $missing.handled -or $script:fakeBrokerCalls -ne 2) { throw 'A missing shortcut probe skipped the broker.' }
    }

    if ($LiveBroker) {
        # Explicit opt-in: only the program's read-only Probe action touches
        # real shell folders. No Explorer desktop is required by default tests.
        $programs = [Environment]::GetFolderPath('Programs')
        $desktop = [Environment]::GetFolderPath('Desktop')
        $result = Invoke-UnvirtualizedShortcutWorker -Operation DesktopShortcutOperation -ScriptPath (Join-Path $repoRoot 'windows\CodexRemoteMobileProject\DesktopShortcut.ps1') -Arguments @{
            Action='Probe'; StableRoot=$fixture; StartMenuPath=$programs; DesktopPath=$desktop
        } -ProbePaths @($programs, $desktop) -TimeoutMilliseconds 30000
        if (@($result.ProbeBefore).Count -ne 2 -or @($result.ProbeAfter).Count -ne 2 -or @($result.Output).Count -ne 1) { throw 'Live broker response is incomplete.' }
        if (@(@($result.ProbeBefore) + @($result.ProbeAfter) | Where-Object RedirectedToPackageCache).Count) { throw 'Live worker remained redirected into package storage.' }
        $probe = $result.Output[0] | ConvertFrom-Json
        if ($probe.shortcuts.Count -ne 2 -or $probe.stableRoot -cne $fixture) { throw 'Live worker did not preserve the Unicode DesktopShortcut Probe arguments.' }
        $startup = [Environment]::GetFolderPath('Startup')
        $startupResult = Invoke-UnvirtualizedShortcutWorker -Operation StartupShortcutOperation -ScriptPath (Join-Path $repoRoot 'windows\CodexRemoteMobileProject\StartupShortcut.ps1') -Arguments @{
            Action='Probe'; StableRoot=$fixture; StartupPath=$startup
        } -ProbePaths @($startup) -TimeoutMilliseconds 30000
        $startupProbe = $startupResult.Output[0] | ConvertFrom-Json
        if ($startupProbe.shortcutPath -cne (Join-Path $startup 'ChatGPT Remote Enabler Startup.lnk') -or @($startupResult.ProbeAfter | Where-Object RedirectedToPackageCache).Count) { throw 'Startup shortcut probe did not use the real user folder.' }
    }
    Write-Output "Shortcut broker regressions passed (PowerShell $($PSVersionTable.PSVersion); live=$LiveBroker)."
} finally {
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    if (-not $resolvedFixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped Temp.' }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
