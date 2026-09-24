[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-pending-recovery-test-' + [guid]::NewGuid().ToString('N'))
$localAppData = Join-Path $temporaryRoot 'local-app-data'
$stableRoot = Join-Path $localAppData 'CodexRemoteFeatures\ChatGPT-Remote-Enabler-Windows-x64'
$stateRoot = Join-Path $localAppData 'ChatGPTRemoteEnabler\update'
$updater = Join-Path $root 'windows\Update-ChatGPTRemote.ps1'
$helper = Join-Path $stableRoot 'update-transaction.js'
$helperLog = Join-Path $temporaryRoot 'helper-calls.log'
$proofPath = Join-Path $temporaryRoot 'caller-proof.json'

function Assert-Condition {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

function Get-FunctionDefinitionText {
    param([Management.Automation.Language.Ast]$Ast, [string]$Name)
    $definition = $Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Missing function $Name." }
    return $definition.Extent.Text
}

function Set-HelperLog {
    if (Test-Path -LiteralPath $helperLog) { Remove-Item -LiteralPath $helperLog -Force }
}

function Set-Journal {
    param([ValidateSet('none', 'transaction', 'git')][string]$Kind)
    foreach ($name in @('transaction.json', 'git-transaction.json')) {
        $path = Join-Path $stateRoot $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if ($Kind -eq 'transaction') { Set-Content -LiteralPath (Join-Path $stateRoot 'transaction.json') -Value '{}' -NoNewline }
    if ($Kind -eq 'git') { Set-Content -LiteralPath (Join-Path $stateRoot 'git-transaction.json') -Value '{}' -NoNewline }
}

try {
    New-Item -ItemType Directory -Path $stableRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $stableRoot 'VERSION') -Value 'v9.9.9' -NoNewline
    foreach ($relative in @(
        'ChatGPT Remote Enabler.exe',
        'Enable-ChatGPTRemote.ps1',
        'Update-ChatGPTRemote.ps1',
        'StableInstall.ps1',
        'CodexRemoteMobileProject\ChatGPT Custom.exe',
        'CodexRemoteMobileProject\MobileProjectStartup.ps1',
        'CodexRemoteMobileProject\UpdateSessionTaskHost.exe',
        'CodexRemoteSimple\CodexRemoteSimple.ps1'
    )) {
        $path = Join-Path $stableRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, '')
    }
    $helperSource = @'
const fs = require("fs");
const log = process.env.CHATGPT_PENDING_RECOVERY_TEST_LOG;
if (log) fs.appendFileSync(log, process.argv.slice(2).join("|") + "\n");
process.stdout.write(JSON.stringify({ recovered: false, integrityValid: true, version: "v9.9.9" }) + "\n");
'@
    [IO.File]::WriteAllText($helper, $helperSource, [Text.UTF8Encoding]::new($false))

    $previousLocalAppData = $env:LOCALAPPDATA
    $previousHelperLog = $env:CHATGPT_PENDING_RECOVERY_TEST_LOG
    $env:LOCALAPPDATA = $localAppData
    $env:CHATGPT_PENDING_RECOVERY_TEST_LOG = $helperLog
    try {
        foreach ($kind in @('none', 'transaction', 'git')) {
            Set-Journal -Kind $kind
            Set-HelperLog
            $arguments = @('-NoProfile', '-NonInteractive', '-File', $updater, '-Action', 'Recover', '-InstallRoot', $stableRoot, '-LaunchLockHeld')
            $arguments += '-RecoverPendingOnly'
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& powershell.exe @arguments 2>&1)
            } finally { $ErrorActionPreference = $previousErrorActionPreference }
            if ($kind -eq 'git') {
                Assert-Condition ($LASTEXITCODE -ne 0 -and (($output -join ' ') -like '*Git source checkout identity changed*')) 'A pending git journal did not enter the full source recovery path.'
                continue
            }
            if ($LASTEXITCODE -ne 0) { throw "Updater fixture failed for ${kind}: $($output -join ' ')" }
            $result = ($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1 | ConvertFrom-Json)
            if ($kind -eq 'none') {
                Assert-Condition ($result.recoveryRequired -is [bool] -and -not $result.recoveryRequired) 'No-journal startup recovery did not return recoveryRequired=false.'
                Assert-Condition ($result.integrityValid -is [bool] -and -not $result.integrityValid) 'No-journal startup recovery pretended to prove integrity.'
                Assert-Condition ($result.cleanupDeferred -is [bool] -and $result.cleanupDeferred) 'No-journal startup recovery did not defer cleanup.'
                Assert-Condition ($null -eq $result.entryPointMigration) 'A noncanonical no-journal fixture attempted installed entry-point migration.'
                Assert-Condition (-not (Test-Path -LiteralPath $helperLog)) 'No-journal startup recovery invoked the hash/recovery helper.'
            } else {
                Assert-Condition ($result.integrityValid -is [bool] -and $result.integrityValid) "$kind journal did not return full recovery proof."
                Assert-Condition ((Test-Path -LiteralPath $helperLog) -and ((Get-Content -LiteralPath $helperLog).Count -eq 1)) "$kind journal did not invoke the recovery helper exactly once."
            }
        }

        $invalidPackagePath = Join-Path $stableRoot 'StableInstall.ps1'
        Remove-Item -LiteralPath $invalidPackagePath -Force
        Set-Journal -Kind none
        Set-HelperLog
        $invalidPackageArguments = @('-NoProfile', '-NonInteractive', '-File', $updater, '-Action', 'Recover', '-InstallRoot', $stableRoot, '-LaunchLockHeld', '-RecoverPendingOnly')
        $invalidPackageOutput = @(& powershell.exe @invalidPackageArguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Structurally invalid pending-only fixture failed: $($invalidPackageOutput -join ' ')" }
        $invalidPackageResult = ($invalidPackageOutput | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1 | ConvertFrom-Json)
        Assert-Condition ($invalidPackageResult.integrityValid -is [bool] -and $invalidPackageResult.integrityValid) 'Structurally invalid no-journal package did not take full recovery.'
        Assert-Condition ((Test-Path -LiteralPath $helperLog) -and ((Get-Content -LiteralPath $helperLog).Count -eq 1)) 'Structurally invalid no-journal package skipped the recovery helper.'

        $invalidPackagePath = Join-Path $stableRoot 'StableInstall.ps1'
        [IO.File]::WriteAllText($invalidPackagePath, '')
        Set-Journal -Kind none
        Set-HelperLog
        $normalArguments = @('-NoProfile', '-NonInteractive', '-File', $updater, '-Action', 'Recover', '-InstallRoot', $stableRoot, '-LaunchLockHeld')
        $normalOutput = @(& powershell.exe @normalArguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Normal Recover fixture failed: $($normalOutput -join ' ')" }
        $normalResult = ($normalOutput | Where-Object { ([string]$_).TrimStart().StartsWith('{') } | Select-Object -Last 1 | ConvertFrom-Json)
        Assert-Condition ($normalResult.integrityValid -is [bool] -and $normalResult.integrityValid) 'Normal Recover no-journal path stopped proving installed integrity.'
        Assert-Condition ((Test-Path -LiteralPath $helperLog) -and ((Get-Content -LiteralPath $helperLog).Count -eq 1)) 'Normal Recover no-journal path did not invoke the integrity helper.'

        $invalidModeArguments = @('-NoProfile', '-NonInteractive', '-File', $updater, '-Action', 'Update', '-InstallRoot', $stableRoot, '-LaunchLockHeld', '-RecoverPendingOnly')
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $invalidModeOutput = @(& powershell.exe @invalidModeArguments 2>&1)
        } finally { $ErrorActionPreference = $previousErrorActionPreference }
        Assert-Condition ($LASTEXITCODE -ne 0 -and (($invalidModeOutput -join ' ') -like '*valid only with -Action Recover*')) 'RecoverPendingOnly was accepted for a non-Recover action.'

        foreach ($callerPath in @(
            (Join-Path $root 'windows\Enable-ChatGPTRemote.ps1'),
            (Join-Path $root 'windows\CodexRemoteMobileProject\MobileProjectStartup.ps1')
        )) {
            $sourceText = Get-Content -LiteralPath $callerPath -Raw
            Assert-Condition ($sourceText.Contains('Invoke-UpdateRecovery -UpdaterPath') -and $sourceText.Contains('-RecoverPendingOnly')) "$callerPath does not opt initial startup into pending-only recovery."
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($callerPath, [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "PowerShell parse failed for ${callerPath}: $($parseErrors[0].Message)" }
            Invoke-Expression (Get-FunctionDefinitionText -Ast $ast -Name 'Get-LastJsonResult')
            Invoke-Expression (Get-FunctionDefinitionText -Ast $ast -Name 'Test-RemoteScriptSupportsParameter')
            Invoke-Expression (Get-FunctionDefinitionText -Ast $ast -Name 'Invoke-UpdateRecovery')
            if ($callerPath -like '*Enable-ChatGPTRemote.ps1') {
                function Write-RemoteLauncherLog { param([AllowEmptyString()][string]$Message) }
            } else {
                function Write-CommandOutput { param([object[]]$Output) }
                function Write-StartupLog { param([AllowEmptyString()][string]$Message) }
            }

            $fakeUpdater = Join-Path $temporaryRoot 'caller-fixture.ps1'
            $fakeUpdaterSource = @'
param([switch]$RecoverPendingOnly)
$proof = Get-Content -LiteralPath $env:CHATGPT_PENDING_RECOVERY_TEST_PROOF -Raw
Write-Output $proof
'@
            [IO.File]::WriteAllText($fakeUpdater, $fakeUpdaterSource, [Text.UTF8Encoding]::new($false))
            $legacyUpdater = Join-Path $temporaryRoot 'legacy-caller-fixture.ps1'
            $legacyUpdaterSource = @'
param([string]$Action, [string]$InstallRoot, [switch]$LaunchLockHeld)
Write-Output '{"recovered":false,"integrityValid":true,"version":"v9.9.9"}'
'@
            [IO.File]::WriteAllText($legacyUpdater, $legacyUpdaterSource, [Text.UTF8Encoding]::new($false))
            $previousProof = $env:CHATGPT_PENDING_RECOVERY_TEST_PROOF
            $env:CHATGPT_PENDING_RECOVERY_TEST_PROOF = $proofPath
            try {
                $validNoJournal = [ordered]@{ recovered = $false; recoveryRequired = $false; integrityValid = $false; cleanupDeferred = $true; version = 'v9.9.9' } | ConvertTo-Json -Compress
                [IO.File]::WriteAllText($proofPath, $validNoJournal, [Text.UTF8Encoding]::new($false))
                $valid = Invoke-UpdateRecovery -UpdaterPath $fakeUpdater -InstallRoot $stableRoot -RecoverPendingOnly
                Assert-Condition ($valid.recoveryRequired -eq $false) "$callerPath rejected a valid no-journal proof."

                $failedMigration = $validNoJournal | ConvertFrom-Json
                $failedMigration | Add-Member -NotePropertyName entryPointMigration -NotePropertyValue ([pscustomobject]@{ valid = $false; reason = 'migration-incomplete' })
                [IO.File]::WriteAllText($proofPath, ($failedMigration | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
                $migrationOutput = @(& { Invoke-UpdateRecovery -UpdaterPath $fakeUpdater -InstallRoot $stableRoot -RecoverPendingOnly } 3>&1)
                $migrationWarnings = @($migrationOutput | Where-Object { $_ -is [Management.Automation.WarningRecord] })
                $continued = $migrationOutput | Where-Object { $_ -isnot [Management.Automation.WarningRecord] }
                Assert-Condition ($continued.entryPointMigration.valid -eq $false -and $migrationWarnings.Count -eq 1 -and [string]$migrationWarnings[0] -like '*Automatic repair will retry*') "$callerPath silently accepted a failed startup migration."
                $failedMigration.entryPointMigration.valid = $true
                [IO.File]::WriteAllText($proofPath, ($failedMigration | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
                $migrationOutput = @(& { Invoke-UpdateRecovery -UpdaterPath $fakeUpdater -InstallRoot $stableRoot -RecoverPendingOnly } 3>&1)
                $migrationWarnings = @($migrationOutput | Where-Object { $_ -is [Management.Automation.WarningRecord] })
                Assert-Condition ($migrationWarnings.Count -eq 0) "$callerPath warned after a successful migration retry."

                $incomplete = [ordered]@{ recovered = $false; recoveryRequired = $false; integrityValid = $true; version = 'v9.9.9' } | ConvertTo-Json -Compress
                [IO.File]::WriteAllText($proofPath, $incomplete, [Text.UTF8Encoding]::new($false))
                $rejected = $false
                try { [void](Invoke-UpdateRecovery -UpdaterPath $fakeUpdater -InstallRoot $stableRoot -RecoverPendingOnly) } catch { $rejected = $_.Exception.Message -like '*incomplete no-journal proof*' }
                Assert-Condition $rejected "$callerPath accepted an incomplete no-journal proof."

                $missingMarker = [ordered]@{ recovered = $false; integrityValid = $false; version = 'v9.9.9' } | ConvertTo-Json -Compress
                [IO.File]::WriteAllText($proofPath, $missingMarker, [Text.UTF8Encoding]::new($false))
                $missingRejected = $false
                try { [void](Invoke-UpdateRecovery -UpdaterPath $fakeUpdater -InstallRoot $stableRoot -RecoverPendingOnly) } catch { $missingRejected = $_.Exception.Message -like '*did not prove installed-file integrity*' }
                Assert-Condition $missingRejected "$callerPath accepted a proof without recoveryRequired."

                # Ask for the pending-only fast path even though this fixture
                # deliberately omits that switch. The caller must feature-detect
                # the older updater and fall back to full Recover proof instead
                # of passing an unknown parameter.
                $legacy = Invoke-UpdateRecovery -UpdaterPath $legacyUpdater -InstallRoot $stableRoot -RecoverPendingOnly
                Assert-Condition ($legacy.integrityValid -and -not $legacy.recovered) "$callerPath did not preserve full Recover compatibility with an older updater."
            } finally {
                if ($null -eq $previousProof) { Remove-Item Env:CHATGPT_PENDING_RECOVERY_TEST_PROOF -ErrorAction SilentlyContinue } else { $env:CHATGPT_PENDING_RECOVERY_TEST_PROOF = $previousProof }
            }
        }

        $updaterText = Get-Content -LiteralPath $updater -Raw
        $lockIndex = $updaterText.IndexOf('$lockStream = Enter-UpdateLock', [StringComparison]::Ordinal)
        $shortcutIndex = $updaterText.IndexOf('if ($RecoverPendingOnly -and', $lockIndex, [StringComparison]::Ordinal)
        $migrationIndex = $updaterText.IndexOf('Invoke-StableEntryPointMigration -StableRoot $InstallRoot', $shortcutIndex, [StringComparison]::Ordinal)
        Assert-Condition ($lockIndex -ge 0 -and $shortcutIndex -gt $lockIndex) 'No-journal shortcut is not checked after the update lock is acquired.'
        Assert-Condition ($migrationIndex -gt $shortcutIndex) 'No-journal startup recovery does not perform entry-point migration under the updater locks.'
        Assert-Condition ($updaterText.Contains('if (-not $recoveryCleanupDeferred)') -and $updaterText.IndexOf('if (-not $recoveryCleanupDeferred)', [StringComparison]::Ordinal) -gt $shortcutIndex) 'No-journal startup recovery still performs cleanup before returning.'
        Write-Output 'Pending startup recovery tests passed.'
    } finally {
        if ($null -eq $previousHelperLog) { Remove-Item Env:CHATGPT_PENDING_RECOVERY_TEST_LOG -ErrorAction SilentlyContinue } else { $env:CHATGPT_PENDING_RECOVERY_TEST_LOG = $previousHelperLog }
        if ($null -eq $previousLocalAppData) { Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue } else { $env:LOCALAPPDATA = $previousLocalAppData }
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\')
        $resolvedTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($resolvedTemporaryRoot) -ne $resolvedTempParent -or
            [IO.Path]::GetFileName($resolvedTemporaryRoot) -notmatch '^chatgpt-pending-recovery-test-[0-9a-f]{32}$') {
            throw 'Unsafe pending-recovery fixture cleanup root.'
        }
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
