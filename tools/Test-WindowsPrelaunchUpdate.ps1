[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-prelaunch-test-' + [guid]::NewGuid().ToString('N'))
$fakeUpdater = Join-Path $temporaryRoot 'fixture updater with spaces.ps1'
$fakeLog = Join-Path $temporaryRoot 'updater-calls.log'
$fakeDesktopUpdater = Join-Path $temporaryRoot 'fixture desktop updater with spaces.ps1'
$fakeDesktopLog = Join-Path $temporaryRoot 'desktop-updater-calls.log'

function Get-FunctionDefinitionText {
    param([Management.Automation.Language.Ast]$Ast, [string]$Name)
    $definition = $Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    if (-not $definition) { throw "Missing function $Name." }
    return $definition.Extent.Text
}

function Assert-Condition {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $fakeUpdaterSource = @"
param([string]`$Action, [string]`$Transport, [string]`$InstallRoot, [switch]`$LaunchLockHeld)
Add-Content -LiteralPath '$($fakeLog.Replace("'", "''"))' -Value ("`$Action|transport=`$Transport|guard=`$LaunchLockHeld")
if (`$Action -eq 'Recover') {
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'fail-recover')) { Write-Output 'recovery failed'; exit 7 }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'recover-missing-version')) { Write-Output '{"integrityValid":true,"recovered":false}'; exit 0 }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'recover-invalid-mode')) { Write-Output '{"integrityValid":true,"recovered":true,"recoveryMode":"unexpected","version":"v9.9.9"}'; exit 0 }
    foreach (`$mode in @('complete-forward','rollback','unchanged')) {
        if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) "recover-`$mode")) {
            [ordered]@{ integrityValid = `$true; recovered = `$true; recoveryMode = `$mode; version = 'v9.9.9' } | ConvertTo-Json -Compress
            exit 0
        }
    }
    Write-Output '{"integrityValid":true,"recovered":false,"version":"v9.9.9"}'
    exit 0
}
if (`$Action -eq 'Update') {
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'fail-update')) { Write-Output 'network unavailable'; exit 9 }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'current-update')) { Write-Output '{"updated":false,"latestVersion":"v9.9.9","localVersion":"v9.9.9","archiveSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","method":"verified-git"}'; exit 0 }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'invalid-method')) { Write-Output '{"updated":false,"latestVersion":"v9.9.9","localVersion":"v9.9.9","archiveSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","method":"verified-release"}'; exit 0 }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'invalid-hash')) { Write-Output '{"updated":true,"version":"v9.9.9","archiveSha256":"not-a-hash","method":"verified-git"}'; exit 0 }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'invalid-version')) { Write-Output '{"updated":true,"version":"9.9.9","archiveSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","method":"verified-git"}'; exit 0 }
    Write-Output '{"updated":true,"version":"v9.9.9","archiveSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","method":"git-fast-forward"}'
    exit 0
}
Write-Output '{"unexpected":true}'
"@
    [IO.File]::WriteAllText($fakeUpdater, $fakeUpdaterSource, [Text.UTF8Encoding]::new($false))
    $fakeDesktopUpdaterSource = @"
[CmdletBinding(SupportsShouldProcess)]
param([string]`$Action)
Add-Content -LiteralPath '$($fakeDesktopLog.Replace("'", "''"))' -Value `$Action
`$root = Split-Path -Parent `$PSCommandPath
if (Test-Path -LiteralPath (Join-Path `$root 'desktop-fail')) { Write-Error 'fixture desktop failure'; exit 19 }
if (Test-Path -LiteralPath (Join-Path `$root 'desktop-invalid')) { Write-Output '{"Action":"Update","Decision":"Installed"}'; exit 0 }
`$installedVersion = if (Test-Path -LiteralPath (Join-Path `$root 'desktop-newer')) { '26.904.0.0' } else { '26.903.9999.0' }
`$remoteVersionText = if (Test-Path -LiteralPath (Join-Path `$root 'desktop-newer')) { '26.903.9999.0' } else { '26.903.9999.0' }
`$remoteVersion = [version]`$remoteVersionText
`$decision = if (Test-Path -LiteralPath (Join-Path `$root 'desktop-newer')) { 'DowngradeRefused' } elseif (Test-Path -LiteralPath (Join-Path `$root 'desktop-current')) { 'EqualVersion' } else { 'Installed' }
`$canInstall = `$decision -eq 'Installed'
`$proof = [ordered]@{
  Action='Update'; InstalledState='Installed';
  Installed=[ordered]@{Name='OpenAI.Codex';Version=`$installedVersion;Architecture='X64';Publisher='CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'};
  Remote=[ordered]@{Name='OpenAI.Codex';Version=`$remoteVersion;VersionText=`$remoteVersion.ToString()}; Decision=`$decision; CanInstall=`$canInstall
}
if (`$decision -eq 'Installed') { `$proof.Manifest = [ordered]@{Name='OpenAI.Codex';Version=[version]`$installedVersion;VersionText=`$installedVersion} }
`$proof | ConvertTo-Json -Depth 5
"@
    [IO.File]::WriteAllText($fakeDesktopUpdater, $fakeDesktopUpdaterSource, [Text.UTF8Encoding]::new($false))

    $cases = @(
        [pscustomobject]@{
            Name = 'Enable-ChatGPTRemote'
            Path = 'windows\Enable-ChatGPTRemote.ps1'
            Injection = '& $stable -Action Enable'
            RecoveryCall = '& $UpdaterPath -Action Recover'
        },
        [pscustomobject]@{
            Name = 'MobileProjectStartup'
            Path = 'windows\CodexRemoteMobileProject\MobileProjectStartup.ps1'
            Injection = '& $stableController @stableArguments'
            RecoveryCall = '& $UpdaterPath -Action Recover'
        }
    )

    $computerName = 'PRELAUNCH-TEST'
    function Write-RemoteLauncherLog { param([AllowEmptyString()][string]$Message) }
    function Write-StartupLog { param([AllowEmptyString()][string]$Message) }
    function Write-CommandOutput { param([object[]]$Output) }

    foreach ($case in $cases) {
        $sourcePath = Join-Path $root $case.Path
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        if (Test-Path -LiteralPath $fakeLog) { Remove-Item -LiteralPath $fakeLog -Force }
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "PowerShell parse failed for $($case.Path): $($parseErrors[0].Message)" }

        $flowIndex = $sourceText.IndexOf('$recoverTimer = [Diagnostics.Stopwatch]::StartNew()', [StringComparison]::Ordinal)
        $recoveryIndex = $sourceText.IndexOf('$recovery = Invoke-UpdateRecovery -UpdaterPath', $flowIndex, [StringComparison]::Ordinal)
        $desktopIndex = $sourceText.IndexOf('Invoke-DesktopAppPrelaunchUpdate -UpdaterPath', $recoveryIndex, [StringComparison]::Ordinal)
        $prelaunchIndex = $sourceText.IndexOf('Invoke-PrelaunchUpdate -UpdaterPath', $desktopIndex, [StringComparison]::Ordinal)
        $injectionIndex = $sourceText.IndexOf($case.Injection, $prelaunchIndex, [StringComparison]::Ordinal)
        $reloadIndex = $sourceText.IndexOf('Start-UpdatedEntryPoint -EntryPoint $PSCommandPath', $prelaunchIndex, [StringComparison]::Ordinal)
        $reloadArgumentIndex = $sourceText.IndexOf('$reloadArguments = @(', $prelaunchIndex, [StringComparison]::Ordinal)
        Assert-Condition ($flowIndex -ge 0 -and $recoveryIndex -gt $flowIndex -and $desktopIndex -gt $recoveryIndex -and $prelaunchIndex -gt $desktopIndex -and $injectionIndex -gt $prelaunchIndex -and $reloadIndex -gt $prelaunchIndex) "$($case.Name) does not perform integrity recovery, desktop-app update, then Remote Enabler update before injection/reload."
        Assert-Condition ($sourceText.Contains('-Action Update -Transport Git') -and -not $sourceText.Contains('-Action Auto -Transport Git')) "$($case.Name) does not require a verified Git update."
        Assert-Condition ($sourceText.Contains("if (`$recovery.recovered -and [string]`$recovery.recoveryMode -cne 'rollback')") -and $sourceText.Contains('if ($RecoveryContinuation)') -and $sourceText.Contains('launch aborted to prevent a reload loop')) "$($case.Name) does not safely reload after forward recovery while retaining rollback compatibility."
        Assert-Condition ($sourceText.Contains('ContinuationParentProcessId') -and $sourceText.Contains('Wait-ForContinuationParent')) "$($case.Name) lacks the continuation handoff contract."
        foreach ($argument in @('-RelaunchHandoffPath', '-UpdateResume', '-ContinuationAfterAcceptedHandshake')) {
            Assert-Condition $sourceText.Contains($argument) "$($case.Name) does not preserve $argument during updated-entry-point handoff."
        }
        Assert-Condition ($sourceText.Contains('legacy helper handoff detected; verifying Remote Enabler again after the desktop-app update')) "$($case.Name) does not repair the update order after an older helper hands off."
        $reloadBlock = $sourceText.Substring($reloadArgumentIndex, $reloadIndex - $reloadArgumentIndex)
        Assert-Condition $reloadBlock.Contains('-SkipDesktopAppUpdateOnce') "$($case.Name) repeats the desktop-app update after a Remote Enabler handoff."
        foreach ($consumedHandshakeArgument in @('-ParentProcessId', '-ParentProcessStartTimeFileTimeUtc', '-ReadyEventName', '-RejectedEventName')) {
            Assert-Condition (-not $reloadBlock.Contains($consumedHandshakeArgument)) "$($case.Name) carries consumed handshake argument $consumedHandshakeArgument into its updated continuation."
        }
        if ($case.Name -eq 'MobileProjectStartup') {
            Assert-Condition ($sourceText.Contains('if (-not $SkipUpdateCheckOnce -and -not $UpdateResume -and -not $skipRemotePrelaunch)')) 'Unattended MobileProjectStartup does not run the required prelaunch update.'
        }

        foreach ($name in @('Get-LastJsonResult', 'Get-CompleteJsonResult', 'Assert-DesktopAppNotRunning', 'Invoke-DesktopAppPrelaunchUpdate', 'Invoke-UpdateRecovery', 'Invoke-PrelaunchUpdate', 'ConvertTo-ProcessArgument')) {
            Invoke-Expression (Get-FunctionDefinitionText -Ast $ast -Name $name)
        }

        $singleProof = Get-LastJsonResult -Output @('download progress', '{"updated":false,"method":"verified-git"}')
        Assert-Condition ($singleProof.updated -is [bool] -and -not $singleProof.updated) "$($case.Name) rejected one final JSON proof after human-readable progress."
        $trailingNoiseRejected = $false
        try { [void](Get-LastJsonResult -Output @('{"updated":false,"method":"verified-git"}', 'trailing noise')) } catch { $trailingNoiseRejected = $_.Exception.Message -like '*final output record*' }
        Assert-Condition $trailingNoiseRejected "$($case.Name) accepted trailing noise after updater proof."
        $multipleProofRejected = $false
        try { [void](Get-LastJsonResult -Output @('{"phase":"prepared"}', '{"updated":false,"method":"verified-git"}')) } catch { $multipleProofRejected = $_.Exception.Message -like '*more than one JSON proof*' }
        Assert-Condition $multipleProofRejected "$($case.Name) accepted multiple updater JSON proof records."

        if (Test-Path -LiteralPath $fakeDesktopLog) { Remove-Item -LiteralPath $fakeDesktopLog -Force }
        $desktopInstalled = Invoke-DesktopAppPrelaunchUpdate -UpdaterPath $fakeDesktopUpdater -ProcessEnumerator { @() }
        Assert-Condition ($desktopInstalled.Decision -ceq 'Installed' -and @(Get-Content -LiteralPath $fakeDesktopLog).Count -eq 1) "$($case.Name) did not accept complete signed desktop installation proof."

        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'desktop-current') -Force | Out-Null
        $desktopCurrent = Invoke-DesktopAppPrelaunchUpdate -UpdaterPath $fakeDesktopUpdater -ProcessEnumerator { @() }
        Assert-Condition ($desktopCurrent.Decision -ceq 'EqualVersion') "$($case.Name) did not accept exact current desktop-package proof."
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'desktop-current') -Force

        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'desktop-newer') -Force | Out-Null
        $desktopNewer = Invoke-DesktopAppPrelaunchUpdate -UpdaterPath $fakeDesktopUpdater -ProcessEnumerator { @() }
        Assert-Condition ($desktopNewer.Decision -ceq 'DowngradeRefused') "$($case.Name) did not preserve a newer installed desktop package."
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'desktop-newer') -Force

        $runningRejected = $false
        try { [void](Invoke-DesktopAppPrelaunchUpdate -UpdaterPath $fakeDesktopUpdater -ProcessEnumerator { ,([pscustomobject]@{ Id = 42 }) }) } catch {
            $runningRejected = $_.Exception.Message -like '*will not stop or kill*'
        }
        Assert-Condition $runningRejected "$($case.Name) did not fail closed before desktop update while ChatGPT is running."

        foreach ($failure in @(
            [pscustomobject]@{ Marker='desktop-fail'; Pattern='desktop update failed before launch' },
            [pscustomobject]@{ Marker='desktop-invalid'; Pattern='did not prove one supported installed package' }
        )) {
            New-Item -ItemType File -Path (Join-Path $temporaryRoot $failure.Marker) -Force | Out-Null
            $rejected = $false
            try { [void](Invoke-DesktopAppPrelaunchUpdate -UpdaterPath $fakeDesktopUpdater -ProcessEnumerator { @() }) } catch {
                $rejected = $_.Exception.Message -like "*$($failure.Pattern)*"
            }
            Remove-Item -LiteralPath (Join-Path $temporaryRoot $failure.Marker) -Force
            Assert-Condition $rejected "$($case.Name) accepted desktop updater failure $($failure.Marker)."
        }

        foreach ($mode in @('complete-forward','rollback','unchanged')) {
            $marker = Join-Path $temporaryRoot "recover-$mode"
            New-Item -ItemType File -Path $marker -Force | Out-Null
            $modeResult = Invoke-UpdateRecovery -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot
            Assert-Condition ([bool]$modeResult.recovered -and [string]$modeResult.recoveryMode -ceq $mode) "$($case.Name) rejected supported recovery mode $mode."
            Remove-Item -LiteralPath $marker -Force
        }
        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'recover-invalid-mode') -Force | Out-Null
        $invalidRecoveryRejected = $false
        try { [void](Invoke-UpdateRecovery -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot) } catch { $invalidRecoveryRejected = $_.Exception.Message -like '*unsupported recovery mode*' }
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'recover-invalid-mode') -Force
        Assert-Condition $invalidRecoveryRejected "$($case.Name) accepted an unsupported recovery mode."
        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'recover-missing-version') -Force | Out-Null
        $incompleteRecoveryRejected = $false
        try { [void](Invoke-UpdateRecovery -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot) } catch { $incompleteRecoveryRejected = $_.Exception.Message -like '*did not prove installed-file integrity*' }
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'recover-missing-version') -Force
        Assert-Condition $incompleteRecoveryRejected "$($case.Name) accepted recovery without exact version proof."

        if (Test-Path -LiteralPath $fakeLog) { Remove-Item -LiteralPath $fakeLog -Force }
        $success = Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot
        Assert-Condition ([bool]$success.updated) "$($case.Name) did not accept the verified Git update result."
        $calls = @(Get-Content -LiteralPath $fakeLog)
        Assert-Condition ($calls.Count -eq 2 -and $calls[0] -like 'Update|transport=Git|guard=True' -and $calls[1] -like 'Recover|transport=|guard=True') "$($case.Name) did not recover after a successful prelaunch update."

        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'current-update') -Force | Out-Null
        Remove-Item -LiteralPath $fakeLog -Force
        $current = Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot
        Assert-Condition (-not [bool]$current.updated -and [string]$current.method -ceq 'verified-git') "$($case.Name) did not accept verified current Git proof."
        $calls = @(Get-Content -LiteralPath $fakeLog)
        Assert-Condition ($calls.Count -eq 1 -and $calls[0] -like 'Update|transport=Git|guard=True') "$($case.Name) did not require the current-version Git check."
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'current-update') -Force

        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'invalid-method') -Force | Out-Null
        Remove-Item -LiteralPath $fakeLog -Force
        $invalidMethodRejected = $false
        try { [void](Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot) } catch { $invalidMethodRejected = $_.Exception.Message -like '*required verified Git prelaunch update failed*' }
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'invalid-method') -Force
        Assert-Condition $invalidMethodRejected "$($case.Name) accepted non-Git current-version proof."

        foreach ($invalidProof in @('invalid-hash','invalid-version')) {
            New-Item -ItemType File -Path (Join-Path $temporaryRoot $invalidProof) -Force | Out-Null
            $invalidProofRejected = $false
            try { [void](Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot) } catch { $invalidProofRejected = $_.Exception.Message -like '*required verified Git prelaunch update failed*' }
            Remove-Item -LiteralPath (Join-Path $temporaryRoot $invalidProof) -Force
            Assert-Condition $invalidProofRejected "$($case.Name) accepted $invalidProof update proof."
        }

        Set-Content -LiteralPath (Join-Path $temporaryRoot 'fail-update') -Value 'fail' -NoNewline
        Remove-Item -LiteralPath $fakeLog -Force
        $requiredUpdateRejected = $false
        try { [void](Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot) } catch { $requiredUpdateRejected = $_.Exception.Message -like '*required verified Git prelaunch update failed*' }
        Assert-Condition $requiredUpdateRejected "$($case.Name) continued after the required update failed."
        $calls = @(Get-Content -LiteralPath $fakeLog)
        Assert-Condition ($calls.Count -eq 2 -and $calls[0] -like 'Update|transport=Git|guard=True' -and $calls[1] -like 'Recover|transport=|guard=True') "$($case.Name) did not prove recovery after the required update failure."

        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'fail-recover') -Force | Out-Null
        $unsafeRejected = $false
        try { [void](Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot) } catch {
            $unsafeRejected = $_.Exception.Message -like '*could not prove installed-file integrity*'
        }
        Assert-Condition $unsafeRejected "$($case.Name) continued after recovery failed to prove integrity."
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'fail-update'),(Join-Path $temporaryRoot 'fail-recover') -Force

        $missingRejected = $false
        try { [void](Invoke-PrelaunchUpdate -UpdaterPath (Join-Path $temporaryRoot 'missing.ps1') -InstallRoot $temporaryRoot) } catch { $missingRejected = $_.Exception.Message -like '*Remote Enabler updater is missing*' }
        Assert-Condition $missingRejected "$($case.Name) continued without the required Remote Enabler updater."

        $quoted = ConvertTo-ProcessArgument -Value 'C:\Program Files\Codex Node\node.exe'
        Assert-Condition ($quoted -ceq '"C:\Program Files\Codex Node\node.exe"') "$($case.Name) does not quote a NodePath containing spaces."
    }

    [pscustomobject]@{
        Controllers = $cases.Count
        IntegrityRecoveryBeforeDesktopApp = $true
        DesktopAppUpdateBeforeGit = $true
        DesktopAppProofFailClosed = $true
        RunningAppPreserved = $true
        LegacyHandoffOrderRepaired = $true
        GitUpdateBeforeInjection = $true
        SuccessfulUpdateRecovery = $true
        RequiredUpdateFailureStops = $true
        RecoveryReloadConverges = $true
        StrictFinalJsonProof = $true
        ExactVersionAndHashProof = $true
        RollbackCompatibility = $true
        IntegrityFailureStops = $true
        ContinuationHandoff = $true
        SpacedPathQuoting = $true
    } | ConvertTo-Json -Compress
    $global:LASTEXITCODE = 0 # Expected updater failures must not leak into Test-Source.
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
