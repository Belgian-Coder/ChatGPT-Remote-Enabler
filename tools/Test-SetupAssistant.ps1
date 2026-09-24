[CmdletBinding()]
param([string]$ScreenshotPath, [string]$PackageRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $PackageRoot) { $PackageRoot = Join-Path $root 'windows' }
$source = Get-Content -LiteralPath (Join-Path $PackageRoot 'Setup-ChatGPTRemote.ps1') -Raw
$suffix = @'
if ($desktop.Checked -or $startup.Checked) { throw 'Setup must require explicit option selection.' }
if ($form.AutoScaleMode -ne 'Dpi') { throw 'Setup must support display scaling.' }
foreach ($label in @('Recheck','Open installation guide','Copy diagnostic summary','Apply selected options','Close')) {
    if (-not @($form.Controls | Where-Object Text -eq $label).Count) { throw "Missing setup action: $label" }
}
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.Location = New-Object Drawing.Point(-32000,-32000)
$form.Show()
[Windows.Forms.Application]::DoEvents()
$form.CreateControl()
foreach ($control in $form.Controls) { $control.CreateControl() }
if ($ScreenshotPath) {
    $bitmap = New-Object Drawing.Bitmap($form.Width,$form.Height)
    try { $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $bitmap.Save($ScreenshotPath) }
    finally { $bitmap.Dispose() }
}
$script:StableShortcutBrokerFailure = 'fixture previous broker failure'
$recheck.PerformClick()
if (Get-Variable -Name StableShortcutBrokerFailure -Scope Script -ErrorAction SilentlyContinue) { throw 'Recheck retained a previous broker failure.' }
$script:StableShortcutBrokerFailure = 'fixture previous broker failure'
$apply.PerformClick()
if (Get-Variable -Name StableShortcutBrokerFailure -Scope Script -ErrorAction SilentlyContinue) { throw 'Apply retained a previous broker failure.' }
if ($report.Text -notlike 'The canonical stable installation is ready*') { throw $report.Text }
$requiredMenu = Join-Path $StartMenuPath 'ChatGPT Remote Enabler.lnk'
if (-not (Test-Path -LiteralPath $requiredMenu -PathType Leaf)) { throw 'Setup without optional choices did not repair the Start menu entry.' }
Remove-Item -LiteralPath $requiredMenu -Force
New-Item -ItemType Directory -Path $requiredMenu | Out-Null
try {
    $apply.PerformClick()
    if ($report.Text -notlike 'Setup did not complete*' -or $report.Text -notlike '*Start menu shortcut*') { throw 'Setup falsely reported success after the required Start menu repair failed.' }
} finally { Remove-Item -LiteralPath $requiredMenu -Force }
$originalSetupProbe = ${function:Test-StableEntryPointsMigrated}
try {
    function Test-StableEntryPointsMigrated {
        $script:StableShortcutBrokerFailure = 'fixture Explorer desktop unavailable'
        return $false
    }
    foreach ($withDesktop in @($false, $true)) {
        $desktop.Checked = $withDesktop
        $apply.PerformClick()
        if ($report.Text -notlike 'Setup did not complete*' -or
            $report.Text -notlike '*fixture Explorer desktop unavailable*' -or
            $report.Text -like '*Check that the current user can write*') { throw 'Setup discarded the actual broker error.' }
    }
} finally {
    Set-Item -LiteralPath Function:\Test-StableEntryPointsMigrated -Value $originalSetupProbe
    Remove-Variable -Name StableShortcutBrokerFailure -Scope Script -ErrorAction SilentlyContinue
}
$desktop.Checked = $true
$startup.Checked = $true
$apply.PerformClick()
if ($report.Text -notlike 'Selected options applied*') { throw $report.Text }
$expectedShortcut = Join-Path $DesktopPath 'ChatGPT Remote Enabler.lnk'
$expectedStartup = Join-Path $StartupPath 'ChatGPT Remote Enabler Startup.lnk'
if (-not (Test-Path -LiteralPath $expectedShortcut) -or -not (Test-Path -LiteralPath $expectedStartup)) { throw 'Setup did not create the selected fixture shortcuts.' }
$shell = New-Object -ComObject WScript.Shell
if ($shell.CreateShortcut($expectedShortcut).Arguments -notmatch '--proxy') { throw 'Setup lost the existing proxy preference.' }
if ($shell.CreateShortcut($expectedStartup).Arguments -notmatch '--proxy') { throw 'Startup did not inherit the proxy preference.' }
if (Test-Path -LiteralPath (Join-Path $DesktopPath 'ChatGPT Custom.lnk')) { throw 'Setup retained an owned legacy desktop shortcut.' }
$consolidatedManual = $shell.CreateShortcut($expectedShortcut)
if ($consolidatedManual.TargetPath -notlike '*stable-root*\ChatGPT Remote Enabler.exe') { throw 'Setup did not consolidate the owned desktop shortcut to the stable root.' }
$form.Dispose()
'@
if (-not $source.Contains('[void]$form.ShowDialog()')) { throw 'Setup entry point changed; update the form construction test.' }
$source = $source.Replace('[void]$form.ShowDialog()', $suffix)
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('remote-setup-ui-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $fixturePackage = Join-Path $fixture 'package'
    Copy-Item -LiteralPath $PackageRoot -Destination $fixturePackage -Recurse
    $fixtureDesktop = Join-Path $fixture 'desktop'
    $fixtureMenu = Join-Path $fixture 'menu'
    $fixtureStartup = Join-Path $fixture 'startup'
    $fixtureStableRoot = Join-Path $fixture 'stable-root'
    $fixtureRollbackRoot = Join-Path $fixture 'shortcut-rollback'
    New-Item -ItemType Directory -Path $fixtureDesktop,$fixtureMenu,$fixtureStartup | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $legacy = $shell.CreateShortcut((Join-Path $fixtureDesktop 'ChatGPT Custom.lnk'))
    $legacy.TargetPath = Join-Path $fixturePackage 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    $legacy.Arguments = '--proxy'; $legacy.Save()
    $source = $source.Replace('$packageRoot = $PSScriptRoot', ('$packageRoot = ' + "'" + $fixturePackage.Replace("'","''") + "'"))
    # Exercise real form actions against an isolated package and shortcut directories.
    & ([scriptblock]::Create($source)) -Action Show -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $fixtureStartup -StableRoot $fixtureStableRoot -RollbackRoot $fixtureRollbackRoot
    if (Test-Path -LiteralPath $fixtureRollbackRoot) { throw 'Successful setup retained auxiliary shortcut rollback.' }

    # Task-primary migration removes the Startup shortcut. Exercise the real
    # status function with an in-memory scheduler so only one enabled,
    # canonical stable launcher action is reported as installed.
    $setupPath = Join-Path $fixturePackage 'Setup-ChatGPTRemote.ps1'
    $tokens = $null
    $parseErrors = $null
    $setupAst = [Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Setup status fixture parse failed: $($parseErrors[0].Message)" }
    $statusDefinition = $setupAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SetupStatus'
    }, $true)
    if (-not $statusDefinition) { throw 'Get-SetupStatus is missing.' }
    $taskStatusStartup = Join-Path $fixture 'task-status-startup'
    New-Item -ItemType Directory -Path $taskStatusStartup | Out-Null
    $taskStatuses = & {
        param($DefinitionText, $FixturePackage, $FixtureStableRoot, $FixtureDesktop, $FixtureStartup)
        $StableRoot = $FixtureStableRoot
        $DesktopPath = $FixtureDesktop
        $StartupPath = $FixtureStartup
        $probeTask = $null
        function Get-AppxPackage { return @() }
        function Test-StablePackage { param([string]$Root) return $true }
        function Get-ScheduledTask { param($TaskName, $ErrorAction) return $probeTask }
        function New-StatusTask {
            param([string]$Execute, [string]$Arguments, [bool]$Enabled = $true, [string]$WorkingDirectory = (Join-Path $FixtureStableRoot 'CodexRemoteMobileProject'))
            [pscustomobject]@{
                State = $(if ($Enabled) { 'Ready' } else { 'Disabled' })
                Settings = [pscustomobject]@{ Enabled = $Enabled }
                Actions = @([pscustomobject]@{ Execute = $Execute; Arguments = $Arguments; WorkingDirectory = $WorkingDirectory })
            }
        }
        . ([scriptblock]::Create($DefinitionText))
        $canonicalLauncher = Join-Path $FixtureStableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        $probeTask = New-StatusTask -Execute $canonicalLauncher -Arguments '--startup'
        $direct = (Get-SetupStatus -Root $FixturePackage -CanonicalRoot $FixtureStableRoot).Startup
        $probeTask = New-StatusTask -Execute $canonicalLauncher -Arguments '--proxy --startup'
        $proxy = (Get-SetupStatus -Root $FixturePackage -CanonicalRoot $FixtureStableRoot).Startup
        $probeTask = New-StatusTask -Execute $canonicalLauncher -Arguments '--startup' -Enabled:$false
        $disabled = (Get-SetupStatus -Root $FixturePackage -CanonicalRoot $FixtureStableRoot).Startup
        $probeTask = New-StatusTask -Execute (Join-Path $FixturePackage 'CodexRemoteMobileProject\ChatGPT Custom.exe') -Arguments '--startup'
        $foreign = (Get-SetupStatus -Root $FixturePackage -CanonicalRoot $FixtureStableRoot).Startup
        $probeTask = New-StatusTask -Execute $canonicalLauncher -Arguments '--startup --extra'
        $unexpectedArguments = (Get-SetupStatus -Root $FixturePackage -CanonicalRoot $FixtureStableRoot).Startup
        [pscustomobject]@{ Direct = $direct; Proxy = $proxy; Disabled = $disabled; Foreign = $foreign; UnexpectedArguments = $unexpectedArguments }
    } $statusDefinition.Extent.Text $fixturePackage $fixtureStableRoot $fixtureDesktop $taskStatusStartup
    if ($taskStatuses.Direct -notlike 'Installed via enabled logon task*' -or
        $taskStatuses.Proxy -notlike '*proxy mode*' -or
        $taskStatuses.Disabled -cne 'Not installed' -or $taskStatuses.Foreign -cne 'Not installed' -or
        $taskStatuses.UnexpectedArguments -cne 'Not installed') {
        throw "Setup task-primary status classification failed: $($taskStatuses | ConvertTo-Json -Compress)"
    }
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'remote-setup-ui-*') { throw 'Unsafe setup fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
[pscustomobject]@{ NativeFormConstruction = $true; OptionsInitiallyUnchecked = $true; DpiScaling = $true; RequiredActions = $true; SelectedOptionsApplied = $true; ProxyPreferencePreserved = $true; LegacyShortcutConsolidated = $true; TaskPrimaryStatus = $true } | ConvertTo-Json -Compress
