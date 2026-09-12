[CmdletBinding()]
param(
    [string]$TaskHostPath,
    [switch]$RunFullFakeAppQualification
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'The update-session task-host temp test requires Windows.' }

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskHostSource = Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\UpdateSessionTaskHost.cs'
$node = (Get-Command node.exe -ErrorAction Stop).Source
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$compiler = $null
if ([string]::IsNullOrWhiteSpace($TaskHostPath)) {
    $compiler = @(
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) { throw 'The .NET Framework C# compiler was not found.' }
} else {
    $TaskHostPath = [IO.Path]::GetFullPath($TaskHostPath)
    if (-not (Test-Path -LiteralPath $TaskHostPath -PathType Leaf)) { throw 'The candidate update-session task host was not found.' }
}

function Quote-NativeArgument {
    param([string]$Value)
    if ($Value.IndexOfAny([char[]]@([char]0, [char]10, [char]13, [char]34)) -ge 0) {
        throw 'A task-host test argument contains an unsupported character.'
    }
    return '"' + $Value + '"'
}

function Start-AdverseTempProcess {
    param(
        [string]$Executable,
        [string]$Arguments,
        [string]$BlockedTemp,
        [string]$ExpectedTemp,
        [string]$ResultPath,
        [Collections.IDictionary]$AdditionalEnvironment
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = $Arguments
    $start.WorkingDirectory = Split-Path -Parent $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.EnvironmentVariables['TEMP'] = $BlockedTemp
    $start.EnvironmentVariables['TMP'] = $BlockedTemp
    $start.EnvironmentVariables['CHATGPT_REMOTE_TEMP_EXPECTED'] = $ExpectedTemp
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $start.EnvironmentVariables['CHATGPT_REMOTE_TEMP_RESULT'] = $ResultPath
    }
    if ($AdditionalEnvironment) {
        foreach ($entry in $AdditionalEnvironment.GetEnumerator()) {
            $start.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
        }
    }
    return [Diagnostics.Process]::Start($start)
}

function Wait-TestFile {
    param([string]$Path, [int]$Seconds = 15)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for task-host temp evidence: $Path"
}

function Assert-CompilerEvidence {
    param($Evidence, [string]$ExpectedTemp, [string]$Label)
    if ($Evidence.addTypeReady -ne $true -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$Evidence.temp), $ExpectedTemp, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$Evidence.tmp), $ExpectedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label did not inherit the stable per-user temporary directory."
    }
}

$fixtureId = [guid]::NewGuid().ToString('N')
$inheritedTemp = [string]$env:TEMP
$inheritedTmp = [string]$env:TMP
$localApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($localApplicationData)) { throw 'The per-user local application-data directory is unavailable.' }
$temporaryParent = [IO.Path]::GetFullPath((Join-Path $localApplicationData 'Temp'))
[IO.Directory]::CreateDirectory($temporaryParent) | Out-Null
$testRoot = Join-Path $temporaryParent "chatgpt-remote-task-host-temp-$fixtureId"
$stateRoot = Join-Path $localApplicationData 'ChatGPTRemoteEnabler\update-sessions'
$bundleRoot = Join-Path (Join-Path $stateRoot 'bundles') ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
$sessionRoot = Join-Path (Join-Path $stateRoot 'sessions') ([guid]::NewGuid().ToString('N'))
$coordinatorProcess = $null
$identityPath = $null
$primaryError = $null
$cleanupFailures = [Collections.Generic.List[string]]::new()
$testResult = $null
try {
    New-Item -ItemType Directory -Path $testRoot,$bundleRoot,$sessionRoot -Force | Out-Null
    $taskHost = Join-Path $testRoot 'UpdateSessionTaskHost.exe'
    if ($TaskHostPath) {
        Copy-Item -LiteralPath $TaskHostPath -Destination $taskHost
    } else {
        & $compiler /nologo /target:winexe "/out:$taskHost" $taskHostSource
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskHost -PathType Leaf)) {
            throw 'The candidate update-session task host did not compile.'
        }
    }

    $blockedTemp = Join-Path $testRoot 'blocked-temp-is-a-file'
    [IO.File]::WriteAllText($blockedTemp, 'TEMP and TMP must be replaced before any child starts.', [Text.UTF8Encoding]::new($false))
    $expectedTemp = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Temp'))

    $entryPointResults = [Collections.Generic.List[object]]::new()
    foreach ($entryPoint in @(
        (Join-Path $repositoryRoot 'windows\Enable-ChatGPTRemote.ps1'),
        (Join-Path $repositoryRoot 'windows\CodexRemoteMobileProject\MobileProjectStartup.ps1')
    )) {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($entryPoint, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Entry-point parsing failed: $entryPoint - $($parseErrors[0].Message)" }
        $definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Set-ProcessUserTemporaryDirectory'
        }, $true))
        $entryPointSource = Get-Content -LiteralPath $entryPoint -Raw
        if ($definitions.Count -ne 1 -or
            $entryPointSource.IndexOf('Set-ProcessUserTemporaryDirectory', $definitions[0].Extent.EndOffset, [StringComparison]::Ordinal) -lt 0) {
            throw "The Windows entry point does not invoke its process-temp normalizer: $entryPoint"
        }
        $entryResult = Join-Path $testRoot (([IO.Path]::GetFileNameWithoutExtension($entryPoint)) + '-entry-add-type.json')
        $entryHarness = Join-Path $testRoot (([IO.Path]::GetFileNameWithoutExtension($entryPoint)) + '-entry-add-type.ps1')
        $entryHarnessSource = @"
$($definitions[0].Extent.Text)
Set-ProcessUserTemporaryDirectory
Add-Type -TypeDefinition 'public static class EntryPointCompilerProbe { public static bool Ready { get { return true; } } }'
`$evidence = [ordered]@{ addTypeReady = [EntryPointCompilerProbe]::Ready; temp = `$env:TEMP; tmp = `$env:TMP }
[IO.File]::WriteAllText(`$env:CHATGPT_REMOTE_TEMP_RESULT, (`$evidence | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new(`$false))
"@
        [IO.File]::WriteAllText($entryHarness, $entryHarnessSource, [Text.UTF8Encoding]::new($false))
        $entryArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (Quote-NativeArgument $entryHarness)
        $entryProcess = Start-AdverseTempProcess -Executable $powerShell -Arguments $entryArguments -BlockedTemp $blockedTemp -ExpectedTemp $expectedTemp -ResultPath $entryResult
        try {
            if (-not $entryProcess.WaitForExit(15000)) { $entryProcess.Kill(); throw "The adverse-temp entry-point fixture timed out: $entryPoint" }
            if ($entryProcess.ExitCode -ne 0) { throw "The adverse-temp entry-point fixture exited with code $($entryProcess.ExitCode): $entryPoint" }
        } finally { $entryProcess.Dispose() }
        Wait-TestFile $entryResult
        $entryEvidence = Get-Content -LiteralPath $entryResult -Raw | ConvertFrom-Json
        Assert-CompilerEvidence -Evidence $entryEvidence -ExpectedTemp $expectedTemp -Label ([IO.Path]::GetFileName($entryPoint))
        $entryPointResults.Add($entryEvidence)
    }

    $workerResult = Join-Path $testRoot 'worker-add-type.json'
    $fullQualificationResult = Join-Path $testRoot 'full-fake-app-qualification.json'
    $fullQualificationError = Join-Path $testRoot 'full-fake-app-qualification-error.json'
    $workerPackageRoot = Join-Path $testRoot 'ChatGPT-Remote-Enabler-Windows-x64'
    $workerBundleRoot = Join-Path $workerPackageRoot 'CodexRemoteMobileProject'
    New-Item -ItemType Directory -Path $workerBundleRoot -Force | Out-Null
    $workerScript = Join-Path $workerBundleRoot 'MobileProjectStartup.ps1'
    [IO.File]::WriteAllText($workerScript, @'
[CmdletBinding()]
param(
    [string]$Action,
    [switch]$UseProxy,
    [switch]$ReplaceRunningApp,
    [int]$ParentProcessId,
    [long]$ParentProcessStartTimeFileTimeUtc,
    [string]$ReadyEventName,
    [string]$RejectedEventName
)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition 'public static class TaskHostWorkerCompilerProbe { public static bool Ready { get { return true; } } }'
$evidence = [ordered]@{ addTypeReady = [TaskHostWorkerCompilerProbe]::Ready; temp = $env:TEMP; tmp = $env:TMP }
[IO.File]::WriteAllText($env:CHATGPT_REMOTE_TEMP_RESULT, ($evidence | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
if (-not [string]::IsNullOrWhiteSpace($env:CHATGPT_REMOTE_FULL_QUALIFICATION_ROOT)) {
    try {
        & (Join-Path $env:CHATGPT_REMOTE_FULL_QUALIFICATION_ROOT 'tools\Test-UpdateSessionWindows.ps1') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'The native Windows close fixture failed.' }
        $survivalFixture = Join-Path $env:CHATGPT_REMOTE_FULL_QUALIFICATION_ROOT 'tools\Test-UpdateSessionSurvivalWindows.ps1'
        $isAdministrator = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdministrator) {
            & $survivalFixture | Out-Null
        } else {
            & $survivalFixture -MediumWorker | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { throw 'The detached update-session survival fixture failed.' }
        [IO.File]::WriteAllText($env:CHATGPT_REMOTE_FULL_QUALIFICATION_RESULT, '{"nativeClose":true,"detachedSurvival":true}', [Text.UTF8Encoding]::new($false))
    } catch {
        $failure = [ordered]@{ message = $_.Exception.Message; exception = $_.Exception.ToString(); scriptStackTrace = $_.ScriptStackTrace }
        [IO.File]::WriteAllText($env:CHATGPT_REMOTE_FULL_QUALIFICATION_ERROR, ($failure | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        throw
    }
}
'@, [Text.UTF8Encoding]::new($false))
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try { $selfStart = $self.StartTime.ToUniversalTime().ToFileTimeUtc() } finally { $self.Dispose() }
    $readyName = 'Local\ChatGPTCustomLauncher-Ready-' + [guid]::NewGuid().ToString('N')
    $rejectedName = 'Local\ChatGPTCustomLauncher-Rejected-' + [guid]::NewGuid().ToString('N')
    $workerArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File {0} -Action Run -ParentProcessId {1} -ParentProcessStartTimeFileTimeUtc {2} -ReadyEventName {3} -RejectedEventName {4}' -f
        (Quote-NativeArgument $workerScript),$PID,$selfStart,(Quote-NativeArgument $readyName),(Quote-NativeArgument $rejectedName)
    $encodedWorkerArguments = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($workerArguments))
    $workerHostArguments = '--worker {0} {1} {2} {3} {4} {5} {6}' -f
        (Quote-NativeArgument $powerShell),(Quote-NativeArgument $workerScript),(Quote-NativeArgument $encodedWorkerArguments),[DateTimeOffset]::UtcNow.AddSeconds(30).ToUnixTimeMilliseconds(),
        (Get-FileHash -LiteralPath $workerScript -Algorithm SHA256).Hash.ToLowerInvariant(),(Get-FileHash -LiteralPath $taskHost -Algorithm SHA256).Hash.ToLowerInvariant(),(Quote-NativeArgument $workerPackageRoot)
    $fullQualificationEnvironment = if ($RunFullFakeAppQualification) {
        @{
            CHATGPT_REMOTE_FULL_QUALIFICATION_ROOT = $repositoryRoot
            CHATGPT_REMOTE_FULL_QUALIFICATION_RESULT = $fullQualificationResult
            CHATGPT_REMOTE_FULL_QUALIFICATION_ERROR = $fullQualificationError
        }
    } else { $null }
    $workerHost = Start-AdverseTempProcess -Executable $taskHost -Arguments $workerHostArguments -BlockedTemp $blockedTemp -ExpectedTemp $expectedTemp -ResultPath $workerResult -AdditionalEnvironment $fullQualificationEnvironment
    try {
        $workerTimeoutMilliseconds = if ($RunFullFakeAppQualification) { 120000 } else { 15000 }
        if (-not $workerHost.WaitForExit($workerTimeoutMilliseconds)) { $workerHost.Kill(); throw 'The adverse-temp worker task host timed out.' }
        if ($workerHost.ExitCode -ne 0) {
            $failureDetail = if (Test-Path -LiteralPath $fullQualificationError -PathType Leaf) {
                Get-Content -LiteralPath $fullQualificationError -Raw
            } else { 'No worker failure record was written.' }
            throw "The adverse-temp worker task host exited with code $($workerHost.ExitCode). $failureDetail"
        }
    } finally { $workerHost.Dispose() }
    Wait-TestFile $workerResult
    Assert-CompilerEvidence -Evidence (Get-Content -LiteralPath $workerResult -Raw | ConvertFrom-Json) -ExpectedTemp $expectedTemp -Label 'The startup worker'
    if ($RunFullFakeAppQualification) {
        Wait-TestFile $fullQualificationResult
        $fullQualificationEvidence = Get-Content -LiteralPath $fullQualificationResult -Raw | ConvertFrom-Json
        if ($fullQualificationEvidence.nativeClose -ne $true -or $fullQualificationEvidence.detachedSurvival -ne $true) {
            throw 'The full fake-app update-session qualification was incomplete.'
        }
    }

    $compilerProbe = Join-Path $bundleRoot 'compiler-probe.ps1'
    [IO.File]::WriteAllText($compilerProbe, @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition 'public static class TaskHostDescendantCompilerProbe { public static bool Ready { get { return true; } } }'
$evidence = [ordered]@{ addTypeReady = [TaskHostDescendantCompilerProbe]::Ready; temp = $env:TEMP; tmp = $env:TMP }
[IO.File]::WriteAllText($env:CHATGPT_REMOTE_TEMP_RESULT, ($evidence | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))
    $platformResult = Join-Path $sessionRoot 'platform-add-type.json'
    $relaunchResult = Join-Path $sessionRoot 'relaunch-add-type.json'
    $coordinatorResult = Join-Path $sessionRoot 'coordinator-temp.json'
    $scriptPath = Join-Path $bundleRoot 'update-session.js'
    [IO.File]::WriteAllText($scriptPath, @'
"use strict";
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const args = process.argv.slice(2);
const value = (name) => { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : null; };
const config = JSON.parse(fs.readFileSync(value("--config"), "utf8"));
Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
for (const resultPath of [config.platformResult, config.relaunchResult]) {
  const env = { ...process.env, CHATGPT_REMOTE_TEMP_RESULT: resultPath };
  const child = spawnSync(config.powerShell, ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", config.compilerProbe],
    { encoding: "utf8", env, windowsHide: true });
  if (child.status !== 0) throw new Error(`PowerShell Add-Type descendant failed: ${child.status}; ${child.stderr || child.stdout}`);
}
fs.writeFileSync(config.coordinatorResult, JSON.stringify({ temp: process.env.TEMP, tmp: process.env.TMP }));
'@, [Text.UTF8Encoding]::new($false))
    $configPath = Join-Path $sessionRoot 'session.json'
    $config = [ordered]@{
        powerShell = $powerShell
        compilerProbe = $compilerProbe
        platformResult = $platformResult
        relaunchResult = $relaunchResult
        coordinatorResult = $coordinatorResult
    }
    [IO.File]::WriteAllText($configPath, (($config | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $identityPath = Join-Path $sessionRoot 'coordinator-identity.json'
    $configHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $nodeHash = (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
    $scriptHash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $nonce = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
    $coordinatorHostArguments = '{0} {1} {2} {3} {4} {5} {6} {7}' -f
        (Quote-NativeArgument $node),(Quote-NativeArgument $scriptPath),(Quote-NativeArgument $configPath),$configHash,$nodeHash,$scriptHash,(Quote-NativeArgument $identityPath),$nonce
    $coordinatorHost = Start-AdverseTempProcess -Executable $taskHost -Arguments $coordinatorHostArguments -BlockedTemp $blockedTemp -ExpectedTemp $expectedTemp
    try {
        if (-not $coordinatorHost.WaitForExit(15000)) { $coordinatorHost.Kill(); throw 'The adverse-temp coordinator task host timed out.' }
        if ($coordinatorHost.ExitCode -ne 0) { throw "The adverse-temp coordinator task host exited with code $($coordinatorHost.ExitCode)." }
    } finally { $coordinatorHost.Dispose() }
    Wait-TestFile $coordinatorResult
    Wait-TestFile $platformResult
    Wait-TestFile $relaunchResult
    $coordinatorEvidence = Get-Content -LiteralPath $coordinatorResult -Raw | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$coordinatorEvidence.temp), $expectedTemp, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath([string]$coordinatorEvidence.tmp), $expectedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The detached Node coordinator did not inherit the stable per-user temporary directory.'
    }
    Assert-CompilerEvidence -Evidence (Get-Content -LiteralPath $platformResult -Raw | ConvertFrom-Json) -ExpectedTemp $expectedTemp -Label 'The platform-helper descendant'
    Assert-CompilerEvidence -Evidence (Get-Content -LiteralPath $relaunchResult -Raw | ConvertFrom-Json) -ExpectedTemp $expectedTemp -Label 'The relaunch descendant'

    if (-not [string]::Equals([string]$env:TEMP, $inheritedTemp, [StringComparison]::Ordinal) -or
        -not [string]::Equals([string]$env:TMP, $inheritedTmp, [StringComparison]::Ordinal)) {
        throw 'The qualification harness changed its parent TEMP or TMP value.'
    }
    $testResult = [pscustomobject]@{
        AdverseTempWasFile = (Test-Path -LiteralPath $blockedTemp -PathType Leaf)
        DirectEntryPointAddType = $entryPointResults.Count -eq 2
        WorkerAddType = $true
        FullFakeAppQualification = [bool]$RunFullFakeAppQualification
        CoordinatorTemp = $true
        PlatformAddType = $true
        RelaunchAddType = $true
        ParentEnvironmentPreserved = $true
        InheritedTemp = $inheritedTemp
        InheritedTmp = $inheritedTmp
        StableUserTemp = $expectedTemp
    }
} catch {
    $primaryError = $_
} finally {
    if (-not [string]::IsNullOrWhiteSpace($identityPath) -and (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        try {
            $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
            $candidate = Get-Process -Id ([int]$identity.pid) -ErrorAction SilentlyContinue
            if ($candidate) {
                try {
                    $candidatePath = $null
                    if (-not $candidate.HasExited) {
                        try { $candidatePath = [string]$candidate.MainModule.FileName }
                        catch [InvalidOperationException] { if (-not $candidate.HasExited) { throw } }
                    }
                    if ($candidate.HasExited) {
                        # The coordinator completed between identity capture and cleanup.
                    } elseif ([string]::IsNullOrWhiteSpace($candidatePath)) {
                        throw 'The coordinator executable path could not be verified; cleanup refused to terminate it.'
                    } elseif ([string]::Equals([IO.Path]::GetFullPath($candidatePath), [IO.Path]::GetFullPath($node), [StringComparison]::OrdinalIgnoreCase)) {
                        if (-not $candidate.WaitForExit(5000)) {
                            Stop-Process -Id $candidate.Id -Force -ErrorAction Stop
                            if (-not $candidate.WaitForExit(5000)) { throw 'The fixture Node coordinator did not exit after forced cleanup.' }
                        }
                    } else {
                        throw 'The coordinator identity PID now belongs to another executable; cleanup refused to terminate it.'
                    }
                } finally { $candidate.Dispose() }
            }
        } catch { $cleanupFailures.Add("Coordinator cleanup failed: $($_.Exception.Message)") }
    }
    foreach ($owned in @(
        [pscustomobject]@{ Path = $sessionRoot; Parent = Join-Path $stateRoot 'sessions'; Pattern = '^[0-9a-f]{32}$' },
        [pscustomobject]@{ Path = $bundleRoot; Parent = Join-Path $stateRoot 'bundles'; Pattern = '^[0-9a-f]{64}$' },
        [pscustomobject]@{ Path = $testRoot; Parent = $temporaryParent; Pattern = '^chatgpt-remote-task-host-temp-[0-9a-f]{32}$' }
    )) {
        $resolved = [IO.Path]::GetFullPath($owned.Path)
        if (-not (Test-Path -LiteralPath $resolved)) { continue }
        if (-not [string]::Equals([IO.Path]::GetFullPath((Split-Path -Parent $resolved)), [IO.Path]::GetFullPath($owned.Parent), [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch $owned.Pattern) {
            $cleanupFailures.Add("Cleanup refused an unexpected fixture path: $resolved")
            continue
        }
        try {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        } catch {
            $cleanupFailures.Add("Fixture cleanup failed for ${resolved}: $($_.Exception.Message)")
        }
        if (Test-Path -LiteralPath $resolved) {
            $cleanupFailures.Add("Fixture cleanup left an owned path behind: $resolved")
        }
    }
}

if ($primaryError) {
    if ($cleanupFailures.Count -gt 0) {
        throw [InvalidOperationException]::new(
            "$($primaryError.Exception.Message) Cleanup failures: $($cleanupFailures -join ' | ')",
            $primaryError.Exception)
    }
    throw $primaryError
}
if ($cleanupFailures.Count -gt 0) { throw "Task-host temp fixture cleanup failed: $($cleanupFailures -join ' | ')" }
$testResult | ConvertTo-Json
