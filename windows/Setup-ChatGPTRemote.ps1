[CmdletBinding()]
param(
    [ValidateSet('Show','Probe')][string]$Action = 'Show',
    [string]$DesktopPath = [Environment]::GetFolderPath('Desktop'),
    [string]$StartMenuPath = [Environment]::GetFolderPath('Programs'),
    [string]$StartupPath = [Environment]::GetFolderPath('Startup')
)

$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot

function Get-SetupStatus {
    param([string]$Root)
    $result = [ordered]@{ App = 'Not found'; Node = 'Not found'; Folder = 'Not writable'; Integration = 'Not checked'; DesktopShortcut = 'Not installed'; Startup = 'Not installed' }
    try {
        $apps = @(Get-AppxPackage | Where-Object { $_.Name -match '^(OpenAI\.ChatGPT-Desktop|OpenAI\.Codex)$' })
        if ($apps.Count) { $result.App = 'Installed for this user' }
    } catch { $result.App = 'Discovery unavailable' }
    try {
        # Reuse the production resolver without executing the controller.
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'CodexRemoteSimple\CodexRemoteSimple.ps1'), [ref]$tokens, [ref]$errors)
        $resolver = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Resolve-CrsNode' }, $true)
        if (-not $resolver -or $errors.Count) { throw 'Resolver unavailable' }
        . ([scriptblock]::Create($resolver.Extent.Text))
        $runtime = Resolve-CrsNode
        $result.Node = "Compatible ($($runtime.Version))"
    } catch { $result.Node = 'Missing or incompatible; Node.js 22+ is required' }
    $temporary = Join-Path $Root ('.setup-write-' + [guid]::NewGuid().ToString('N'))
    $renamed = "$temporary.renamed"
    try {
        [IO.File]::WriteAllText($temporary, 'setup write probe')
        [IO.File]::Move($temporary, $renamed)
        $result.Folder = 'Writable for this user'
    } catch { $result.Folder = 'Not writable; move the package to your user folder' }
    finally {
        foreach ($file in @($temporary,$renamed)) { if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
    }
    $required = @('Enable-ChatGPTRemote.ps1','CodexRemoteMobileProject\ChatGPT Custom.exe','CodexRemoteMobileProject\inject.js','CodexRemoteMobileProject\renderer-mobile-project-view.js')
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf) })
    $result.Integration = if ($missing.Count) { 'Package incomplete; extract the complete release' } else { 'Package files present; live readiness is checked at launch' }
    if (Test-Path -LiteralPath (Join-Path $DesktopPath 'ChatGPT Remote Enabler.lnk')) { $result.DesktopShortcut = 'Installed' }
    elseif (Test-Path -LiteralPath (Join-Path $DesktopPath 'ChatGPT Custom.lnk')) { $result.DesktopShortcut = 'Legacy shortcut retained' }
    if (Test-Path -LiteralPath (Join-Path $StartupPath 'ChatGPT Remote Enabler Startup.lnk')) { $result.Startup = 'Installed; sign-in execution not verified by this check' }
    [pscustomobject]$result
}

if ($Action -eq 'Probe') { Get-SetupStatus -Root $packageRoot | ConvertTo-Json; return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = 'ChatGPT Remote Enabler - Setup'
$form.Size = New-Object Drawing.Size(700,590)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$form.AutoScaleMode = 'Dpi'
$heading = New-Object Windows.Forms.Label
$heading.Text = 'Set up Remote Enabler for your Windows user'
$heading.Location = New-Object Drawing.Point(20,18)
$heading.Size = New-Object Drawing.Size(640,32)
$form.Controls.Add($heading)
$report = New-Object Windows.Forms.TextBox
$report.Multiline = $true; $report.ReadOnly = $true; $report.ScrollBars = 'Vertical'
$report.Location = New-Object Drawing.Point(20,55); $report.Size = New-Object Drawing.Size(640,220)
$report.AccessibleName = 'Setup checks and diagnostic preview'
$report.Text = 'Choose Recheck to inspect this installation. No app will be restarted.'
$form.Controls.Add($report)
$desktop = New-Object Windows.Forms.CheckBox
$desktop.Text = 'Create Desktop and Start menu shortcuts'
$desktop.Location = New-Object Drawing.Point(20,290); $desktop.Size = New-Object Drawing.Size(640,30)
$form.Controls.Add($desktop)
$startup = New-Object Windows.Forms.CheckBox
$startup.Text = 'Start at sign-in (60-second delay)'
$startup.Location = New-Object Drawing.Point(20,325); $startup.Size = New-Object Drawing.Size(640,30)
$form.Controls.Add($startup)
$notice = New-Object Windows.Forms.Label
$notice.Text = 'Existing shortcuts and startup settings are preserved. Unchecked choices make no changes.'
$notice.Location = New-Object Drawing.Point(20,362); $notice.Size = New-Object Drawing.Size(640,48)
$form.Controls.Add($notice)
function Add-SetupButton {
    param([string]$Text,[int]$X,[int]$Y,[int]$Width,[scriptblock]$Click)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.Location = New-Object Drawing.Point($X,$Y); $button.Size = New-Object Drawing.Size($Width,36)
    $button.Add_Click($Click); $form.Controls.Add($button)
    return $button
}
$recheck = Add-SetupButton 'Recheck' 20 415 120 {
    $form.UseWaitCursor = $true
    try { $report.Text = ((Get-SetupStatus -Root $packageRoot).PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }) -join "`r`n`r`n" }
    catch { $report.Text = 'The setup check failed. Open the installation guide and verify the complete package.' }
    finally { $form.UseWaitCursor = $false }
}
$guide = Add-SetupButton 'Open installation guide' 150 415 220 { Start-Process 'https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler/blob/main/windows/README.md' }
$copy = Add-SetupButton 'Copy diagnostic summary' 380 415 280 { [Windows.Forms.Clipboard]::SetText($report.Text) }
$apply = Add-SetupButton 'Apply selected options' 20 462 250 {
    $form.UseWaitCursor = $true
    try {
        $checks = Get-SetupStatus -Root $packageRoot
        if ($checks.Folder -notlike 'Writable*' -or $checks.Integration -notlike 'Package files present*') { throw 'The package is incomplete or is not writable. Recheck and follow the installation guide.' }
        if (-not $desktop.Checked -and -not $startup.Checked) { $report.Text = 'No changes selected. Existing shortcuts and startup settings are preserved.'; return }
        $desktopProxy = $false
        $shortcutShell = New-Object -ComObject WScript.Shell
        foreach ($name in @('ChatGPT Remote Enabler.lnk','ChatGPT Custom.lnk')) {
            $existingPath = Join-Path $DesktopPath $name
            if (Test-Path -LiteralPath $existingPath -PathType Leaf) {
                $desktopProxy = $shortcutShell.CreateShortcut($existingPath).Arguments -match '(^|\s)--proxy(\s|$)'
                break
            }
        }
        if ($desktop.Checked) { & (Join-Path $packageRoot 'CodexRemoteMobileProject\DesktopShortcut.ps1') -Action Install -UseProxy:$desktopProxy -DesktopPath $DesktopPath -StartMenuPath $StartMenuPath | Out-Null }
        if ($startup.Checked) {
            $existingStartup = & (Join-Path $packageRoot 'CodexRemoteMobileProject\StartupShortcut.ps1') -Action Probe -StartupPath $StartupPath | ConvertFrom-Json
            $startupProxy = if ($existingStartup.installed) { [bool]$existingStartup.proxyMode } else { $desktopProxy }
            & (Join-Path $packageRoot 'CodexRemoteMobileProject\StartupShortcut.ps1') -Action Install -UseProxy:$startupProxy -StartupPath $StartupPath | Out-Null
        }
        $report.Text = "Selected options applied. Existing legacy shortcuts were retained.`r`n`r`nFinish active tasks and quit the ordinary app, then open ChatGPT Remote Enabler. Live integration readiness is checked during launch."
        $desktop.Checked = $false; $startup.Checked = $false
    } catch { $report.Text = "Setup did not complete. Some selected options may have succeeded; choose Recheck.`r`n`r`n" + $_.Exception.Message }
    finally { $form.UseWaitCursor = $false }
}
$close = Add-SetupButton 'Close' 540 462 120 { $form.Close() }
$form.CancelButton = $close
[void]$form.ShowDialog()
