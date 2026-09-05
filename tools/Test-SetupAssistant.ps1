[CmdletBinding()]
param([string]$ScreenshotPath, [string]$PackageRoot)
$ErrorActionPreference = 'Stop'
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
if (-not (Test-Path -LiteralPath (Join-Path $DesktopPath 'ChatGPT Custom.lnk'))) { throw 'Setup removed a legacy shortcut.' }
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
    New-Item -ItemType Directory -Path $fixtureDesktop,$fixtureMenu,$fixtureStartup | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $legacy = $shell.CreateShortcut((Join-Path $fixtureDesktop 'ChatGPT Custom.lnk'))
    $legacy.TargetPath = Join-Path $fixturePackage 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    $legacy.Arguments = '--proxy'; $legacy.Save()
    $source = $source.Replace('$packageRoot = $PSScriptRoot', ('$packageRoot = ' + "'" + $fixturePackage.Replace("'","''") + "'"))
    # Exercise real form actions against an isolated package and shortcut directories.
    & ([scriptblock]::Create($source)) -Action Show -DesktopPath $fixtureDesktop -StartMenuPath $fixtureMenu -StartupPath $fixtureStartup
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'remote-setup-ui-*') { throw 'Unsafe setup fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
[pscustomobject]@{ NativeFormConstruction = $true; OptionsInitiallyUnchecked = $true; DpiScaling = $true; RequiredActions = $true; SelectedOptionsApplied = $true; ProxyPreferencePreserved = $true; LegacyShortcutPreserved = $true } | ConvertTo-Json -Compress
