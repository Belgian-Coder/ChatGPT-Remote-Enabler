[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$controller = Join-Path $root 'windows\CodexRemoteSimple\CodexRemoteSimple.ps1'
$script:RuntimeRoot = Join-Path $root 'windows\CodexRemoteSimple\runtime'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($controller, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Controller parse failed: $($parseErrors[0].Message)" }
foreach ($name in @('Test-CrsLegacyDeviceKeyCompatibilityNeeded', 'Test-CrsLegacyDeviceKeyModeProof', 'Start-CrsPackagedCodex')) {
    $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Missing startup function: $name" }
    Invoke-Expression $definition.Extent.Text
}
# This suite never executes an application or package activation helper.
$script:packageLaunches = @()
function Invoke-CommandInDesktopPackage {
    param($PackageFamilyName, $AppId, $Command, $Args, $ErrorAction)
    $script:packageLaunches += [pscustomobject]@{ Command = $Command; Arguments = $Args }
}
function Write-CrsLaunchDiagnostic { param($Method, $Succeeded, $PrimaryError, $FallbackError) }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('remote-key-startup-test-' + [guid]::NewGuid().ToString('N'))
$previousCodexHome = $env:CODEX_HOME
try {
    $resources = Join-Path $temporary 'private\resources'
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    $privateExecutable = Join-Path $temporary 'private\ChatGPT.exe'
    $package = [pscustomobject]@{
        OriginalExecutablePath = 'C:\fixture-installed\ChatGPT.exe'
        ExecutablePath = $privateExecutable
        FamilyName = 'fixture-package'
        ApplicationId = 'fixture-app'
    }
    $launch = Start-CrsPackagedCodex -Package $package -ArgumentList @('--remote-debugging-address=127.0.0.1', '--remote-debugging-port=34567')
    if ($launch.Method -ne 'Invoke-CommandInDesktopPackage' -or $script:packageLaunches.Count -ne 1 -or
        $script:packageLaunches[0].Command -ne $privateExecutable) { throw 'Private compatibility startup attempted ordinary app activation instead of the selected executable.' }
    if ($script:packageLaunches[0].Arguments -notlike '*--remote-debugging-port=34567*') { throw 'Private startup lost its renderer arguments.' }

    if (-not (Test-CrsLegacyDeviceKeyModeProof -State $null -Required $false)) { throw 'A native-only session must not require a compatibility record.' }
    if (Test-CrsLegacyDeviceKeyModeProof -State ([pscustomobject]@{ legacyDeviceKeyCompatibility = $false }) -Required $true) { throw 'An old renderer-only session was accepted for an existing legacy key.' }
    Copy-Item -LiteralPath (Join-Path $script:RuntimeRoot 'legacy-device-key-compat.cjs') -Destination (Join-Path $resources 'crk.cjs')
    Copy-Item -LiteralPath (Join-Path $script:RuntimeRoot 'main-payload.js') -Destination (Join-Path $resources 'crks.cjs')
    $state = [pscustomobject]@{ executablePath = $privateExecutable; legacyDeviceKeyCompatibility = $true }
    if (-not (Test-CrsLegacyDeviceKeyModeProof -State $state -Required $true)) { throw 'Matching durable compatibility proof was rejected.' }
    Add-Content -LiteralPath (Join-Path $resources 'crk.cjs') -Value '// modified fixture'
    if (Test-CrsLegacyDeviceKeyModeProof -State $state -Required $true) { throw 'A modified installed compatibility helper was accepted.' }

    $env:CODEX_HOME = Join-Path $temporary 'fixture-home'
    New-Item -ItemType Directory -Path $env:CODEX_HOME | Out-Null
    $node = [pscustomobject]@{ Path = (Get-Command node.exe -ErrorAction Stop).Source }
    if (Test-CrsLegacyDeviceKeyCompatibilityNeeded -Node $node) { throw 'An empty profile selected legacy compatibility.' }
    $key = @{ algorithm = 'fixture'; protectionClass = 'os_protected_nonextractable'; publicKeySpkiDerBase64 = 'fixture-public'; encryptedPrivateKeyBase64 = 'fixture-protected' }
    $stored = @{ schemaVersion = 1; keys = @{ 'fixture-key' = $key } }
    $enrollment = @{ keyId = 'fixture-key'; algorithm = 'fixture'; protectionClass = 'os_protected_nonextractable'; publicKeySpkiDerBase64 = 'fixture-public' }
    $globalState = @{ 'electron-remote-control-client-enrollments' = @{ fixture = $enrollment } }
    [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'remote-control-device-keys.windows.json'), ($stored | ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME '.codex-global-state.json'), ($globalState | ConvertTo-Json -Depth 5))
    if (-not (Test-CrsLegacyDeviceKeyCompatibilityNeeded -Node $node)) { throw 'Normal startup failed to select compatibility for a matching enrollment.' }
    [pscustomobject]@{
        ApplicationLaunchesMocked = $true
        PrivateExecutableSelected = $true
        RendererArgumentsPreserved = $true
        OldRendererOnlySessionRejected = $true
        DurableHelperHashesVerified = $true
        ModifiedHelperRejected = $true
        EmptyProfileUsesNative = $true
        ExistingEnrollmentSelectsCompatibility = $true
    } | ConvertTo-Json
} finally {
    $env:CODEX_HOME = $previousCodexHome
    $resolved = [IO.Path]::GetFullPath($temporary)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notmatch '^remote-key-startup-test-[0-9a-f]{32}$') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
