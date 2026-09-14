[CmdletBinding()]
param(
    [switch]$ProgressWorker,
    [string]$ProgressStatePath,
    [int]$ProgressOwnerProcessId = 0
)

# The UI runs in a separate STA PowerShell process so it remains responsive
# while the launch worker performs blocking network and package operations.
$script:StartupProgressProcess = $null
$script:StartupProgressStatePath = $null
$script:StartupProgressHelperPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)

function Get-StartupProgressRoot {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localData)) { throw 'Local application data is unavailable.' }
    return [IO.Path]::GetFullPath((Join-Path $localData 'Temp\ChatGPTRemoteEnabler\startup-progress')).TrimEnd('\')
}

function Assert-StartupProgressStatePath {
    param([Parameter(Mandatory)][string]$Path)
    $root = Get-StartupProgressRoot
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($full) -cne '.status') {
        throw 'The startup progress state path is outside the private per-user progress directory.'
    }
    return $full
}

function Write-StartupProgressState {
    param([Parameter(Mandatory)][string]$Message)
    if ([string]::IsNullOrWhiteSpace($script:StartupProgressStatePath)) { return }
    [IO.File]::WriteAllText($script:StartupProgressStatePath, $Message, [Text.UTF8Encoding]::new($false))
}

function Invoke-StartupProgressWorker {
    param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][int]$OwnerProcessId)
    $StatePath = Assert-StartupProgressStatePath -Path $StatePath
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $form = [Windows.Forms.Form]::new()
    $form.Text = 'ChatGPT Remote Enabler'
    $form.ClientSize = [Drawing.Size]::new(430, 105)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ControlBox = $false
    $form.ShowInTaskbar = $true
    $form.TopMost = $true
    $form.Font = [Drawing.Font]::new('Segoe UI', 10)
    $form.AccessibleName = 'ChatGPT Remote Enabler startup progress'

    $label = [Windows.Forms.Label]::new()
    $label.Location = [Drawing.Point]::new(18, 15)
    $label.Size = [Drawing.Size]::new(394, 40)
    $label.Text = 'Preparing ChatGPT Remote Enabler...'
    $label.AccessibleName = 'Current startup phase'
    $form.Controls.Add($label)

    $bar = [Windows.Forms.ProgressBar]::new()
    $bar.Location = [Drawing.Point]::new(18, 66)
    $bar.Size = [Drawing.Size]::new(394, 18)
    $bar.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $bar.MarqueeAnimationSpeed = 24
    $bar.AccessibleName = 'Startup is in progress'
    $form.Controls.Add($bar)

    $started = [DateTime]::UtcNow
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 200
    $timer.Add_Tick({
        try {
            $ownerAlive = $null -ne (Get-Process -Id $OwnerProcessId -ErrorAction SilentlyContinue)
            if (-not $ownerAlive -or [DateTime]::UtcNow.Subtract($started).TotalMinutes -ge 10) { $form.Close(); return }
            if (-not [IO.File]::Exists($StatePath)) { return }
            $message = [IO.File]::ReadAllText($StatePath)
            if ($message -ceq '__STOP__') { $form.Close(); return }
            if (-not [string]::IsNullOrWhiteSpace($message) -and $label.Text -cne $message) { $label.Text = $message }
        } catch {}
    })
    try {
        $timer.Start()
        [Windows.Forms.Application]::Run($form)
    } finally {
        $timer.Stop()
        $timer.Dispose()
        $form.Dispose()
        if ([IO.File]::Exists($StatePath)) { [IO.File]::Delete($StatePath) }
    }
}

function Start-StartupProgress {
    param([string]$Message = 'Preparing ChatGPT Remote Enabler...')
    if ($env:CHATGPT_REMOTE_STARTUP_PROGRESS -ceq '0' -or $null -ne $script:StartupProgressProcess) { return }
    try {
        $root = Get-StartupProgressRoot
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $script:StartupProgressStatePath = Join-Path $root (([guid]::NewGuid().ToString('N')) + '.status')
        Write-StartupProgressState -Message $Message
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ProgressWorker -ProgressStatePath "{1}" -ProgressOwnerProcessId {2}' -f $script:StartupProgressHelperPath,$script:StartupProgressStatePath,$PID
        $script:StartupProgressProcess = Start-Process -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    } catch {
        $script:StartupProgressProcess = $null
        if ($script:StartupProgressStatePath -and [IO.File]::Exists($script:StartupProgressStatePath)) { [IO.File]::Delete($script:StartupProgressStatePath) }
        $script:StartupProgressStatePath = $null
    }
}

function Set-StartupProgress {
    param([Parameter(Mandatory)][string]$Message)
    try { Write-StartupProgressState -Message $Message } catch {}
}

function Stop-StartupProgress {
    if ($null -eq $script:StartupProgressProcess) { return }
    try {
        Write-StartupProgressState -Message '__STOP__'
        if (-not $script:StartupProgressProcess.WaitForExit(3000)) {
            Stop-Process -Id $script:StartupProgressProcess.Id -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    try { $script:StartupProgressProcess.Dispose() } catch {}
    if ($script:StartupProgressStatePath -and [IO.File]::Exists($script:StartupProgressStatePath)) {
        try { [IO.File]::Delete($script:StartupProgressStatePath) } catch {}
    }
    $script:StartupProgressProcess = $null
    $script:StartupProgressStatePath = $null
}

if ($ProgressWorker) {
    if ($ProgressOwnerProcessId -le 0) { throw 'The startup progress worker requires an owner process id.' }
    Invoke-StartupProgressWorker -StatePath $ProgressStatePath -OwnerProcessId $ProgressOwnerProcessId
}
