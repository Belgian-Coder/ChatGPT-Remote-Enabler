[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-remote-prelaunch-test-' + [guid]::NewGuid().ToString('N'))
$fakeUpdater = Join-Path $temporaryRoot 'fixture updater with spaces.ps1'
$fakeLog = Join-Path $temporaryRoot 'updater-calls.log'

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
    Write-Output '{"integrityValid":true,"recovered":false}'
    exit 0
}
if (`$Action -eq 'Auto' -and (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'skip-auto'))) {
    Write-Output '{"skipped":true,"reason":"auto-update-disabled"}'
    exit 0
}
if (`$Action -eq 'Auto') {
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent `$PSCommandPath) 'fail-update')) { Write-Output 'network unavailable'; exit 9 }
    Write-Output '{"updated":true,"version":"v9.9.9","method":"git-fast-forward"}'
    exit 0
}
Write-Output '{"updated":false}'
"@
    [IO.File]::WriteAllText($fakeUpdater, $fakeUpdaterSource, [Text.UTF8Encoding]::new($false))

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

        $recoveryIndex = $sourceText.IndexOf('Invoke-UpdateRecovery -UpdaterPath', [StringComparison]::Ordinal)
        $prelaunchIndex = $sourceText.IndexOf('Invoke-PrelaunchUpdate -UpdaterPath', $recoveryIndex, [StringComparison]::Ordinal)
        $injectionIndex = $sourceText.IndexOf($case.Injection, $prelaunchIndex, [StringComparison]::Ordinal)
        $reloadIndex = $sourceText.IndexOf('Start-UpdatedEntryPoint -EntryPoint $PSCommandPath', $prelaunchIndex, [StringComparison]::Ordinal)
        Assert-Condition ($recoveryIndex -ge 0 -and $prelaunchIndex -gt $recoveryIndex -and $injectionIndex -gt $prelaunchIndex -and $reloadIndex -gt $prelaunchIndex) "$($case.Name) does not perform prelaunch update before injection/reload."
        Assert-Condition ($sourceText.Contains('-Action Auto -Transport Git') -and $sourceText.Contains('Invoke-UpdateRecovery -UpdaterPath $UpdaterPath -InstallRoot $InstallRoot')) "$($case.Name) does not use verified Git auto-update and recovery."
        Assert-Condition ($sourceText.Contains('ContinuationParentProcessId') -and $sourceText.Contains('Wait-ForContinuationParent')) "$($case.Name) lacks the continuation handoff contract."
        foreach ($argument in @('-RelaunchHandoffPath', '-UpdateResume', '-ContinuationAfterAcceptedHandshake')) {
            Assert-Condition $sourceText.Contains($argument) "$($case.Name) does not preserve $argument during updated-entry-point handoff."
        }
        $reloadBlock = $sourceText.Substring($reloadIndex, $sourceText.IndexOf('return', $reloadIndex, [StringComparison]::Ordinal) - $reloadIndex)
        foreach ($consumedHandshakeArgument in @('-ParentProcessId', '-ParentProcessStartTimeFileTimeUtc', '-ReadyEventName', '-RejectedEventName')) {
            Assert-Condition (-not $reloadBlock.Contains($consumedHandshakeArgument)) "$($case.Name) carries consumed handshake argument $consumedHandshakeArgument into its updated continuation."
        }
        if ($case.Name -eq 'MobileProjectStartup') {
            Assert-Condition ($sourceText.Contains('if (-not $SkipUpdateCheckOnce -and -not $UpdateResume -and -not $SkipPrelaunchUpdateOnce)')) 'Unattended MobileProjectStartup does not run the prelaunch update.'
        }

        foreach ($name in @('Get-LastJsonResult', 'Invoke-UpdateRecovery', 'Invoke-PrelaunchUpdate', 'ConvertTo-ProcessArgument')) {
            Invoke-Expression (Get-FunctionDefinitionText -Ast $ast -Name $name)
        }

        $success = Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot
        Assert-Condition ([bool]$success.updated) "$($case.Name) did not accept the verified Git update result."
        $calls = @(Get-Content -LiteralPath $fakeLog)
        Assert-Condition ($calls.Count -eq 2 -and $calls[0] -like 'Auto|transport=Git|guard=True' -and $calls[1] -like 'Recover|transport=|guard=True') "$($case.Name) did not recover after a successful prelaunch update."

        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'skip-auto') -Force | Out-Null
        Remove-Item -LiteralPath $fakeLog -Force
        $skipped = Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot
        Assert-Condition ([bool]$skipped.skipped -and -not [bool]$skipped.updated) "$($case.Name) did not honor the automatic-update opt-out."
        $calls = @(Get-Content -LiteralPath $fakeLog)
        Assert-Condition ($calls.Count -eq 1 -and $calls[0] -like 'Auto|transport=Git|guard=True') "$($case.Name) did not record the automatic-update opt-out."
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'skip-auto') -Force

        Set-Content -LiteralPath (Join-Path $temporaryRoot 'fail-update') -Value 'fail' -NoNewline
        Remove-Item -LiteralPath $fakeLog -Force
        $bestEffort = Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot
        Assert-Condition ([bool]$bestEffort.failed -and -not [bool]$bestEffort.updated) "$($case.Name) did not continue safely after a recoverable update failure."
        $calls = @(Get-Content -LiteralPath $fakeLog)
        Assert-Condition ($calls.Count -eq 2 -and $calls[0] -like 'Auto|transport=Git|guard=True' -and $calls[1] -like 'Recover|transport=|guard=True') "$($case.Name) did not prove recovery after the best-effort failure."

        New-Item -ItemType File -Path (Join-Path $temporaryRoot 'fail-recover') -Force | Out-Null
        $unsafeRejected = $false
        try { [void](Invoke-PrelaunchUpdate -UpdaterPath $fakeUpdater -InstallRoot $temporaryRoot) } catch {
            $unsafeRejected = $_.Exception.Message -like '*could not prove installed-file integrity*'
        }
        Assert-Condition $unsafeRejected "$($case.Name) continued after recovery failed to prove integrity."
        Remove-Item -LiteralPath (Join-Path $temporaryRoot 'fail-update'),(Join-Path $temporaryRoot 'fail-recover') -Force

        $quoted = ConvertTo-ProcessArgument -Value 'C:\Program Files\Codex Node\node.exe'
        Assert-Condition ($quoted -ceq '"C:\Program Files\Codex Node\node.exe"') "$($case.Name) does not quote a NodePath containing spaces."
    }

    [pscustomobject]@{
        Controllers = $cases.Count
        GitUpdateBeforeInjection = $true
        SuccessfulUpdateRecovery = $true
        RecoverableFailureContinues = $true
        IntegrityFailureStops = $true
        ContinuationHandoff = $true
        SpacedPathQuoting = $true
    } | ConvertTo-Json -Compress
    $global:LASTEXITCODE = 0 # Expected updater failures must not leak into Test-Source.
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
