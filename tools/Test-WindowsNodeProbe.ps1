[CmdletBinding()]
param(
    [string]$NodePath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($NodePath)) {
    $NodePath = (Get-Command node.exe -ErrorAction Stop).Source
}
$NodePath = [IO.Path]::GetFullPath($NodePath)
if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
    throw "Node.js is missing: $NodePath"
}

$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw 'Windows PowerShell 5.1 is required for the native Node argument regression test.'
}

$expression = 'process.exit(parseInt(process.versions.node) >= 22 && globalThis.WebSocket ? 0 : 1)'
$escapedNode = $NodePath.Replace("'", "''")
$escapedExpression = $expression.Replace("'", "''")
$command = "& '$escapedNode' -e '$escapedExpression'"
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$output = @(& $windowsPowerShell -NoProfile -NonInteractive -EncodedCommand $encodedCommand 2>&1)
if ($LASTEXITCODE -ne 0) {
    $firstLine = if ($output.Count) { [string]$output[0] } else { 'no diagnostic output' }
    throw "Windows PowerShell 5.1 corrupted the Node capability probe: $firstLine"
}

# Exercise the production resolvers with no PATH or cached runtime available.
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('portable-node-probe-' + [guid]::NewGuid().ToString('N'))
$saved = @{ Path=$env:Path; USERPROFILE=$env:USERPROFILE; LOCALAPPDATA=$env:LOCALAPPDATA }
$root = Split-Path -Parent $PSScriptRoot
$resolverChecks = 0
try {
    $portable = Join-Path $fixture 'local\Programs\nodejs\node.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $portable) -Force | Out-Null
    Copy-Item -LiteralPath $NodePath -Destination $portable
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    $env:USERPROFILE = Join-Path $fixture 'profile'
    $env:LOCALAPPDATA = Join-Path $fixture 'local'
    foreach ($item in @(
        @('windows\CodexRemoteMobileProject\MobileProjectStartup.ps1', 'Resolve-NodePath'),
        @('windows\CodexRemoteMobileProject\MobileProjectView.ps1', 'Resolve-MobileNode'),
        @('windows\CodexRemoteMobileProject\UpdateSessionLauncher.ps1', 'Resolve-UpdateSessionNode')
    )) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $item[0]), [ref]$tokens, [ref]$errors)
        $name = $item[1]
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $fn -or $errors.Count) { throw "Cannot load production Node resolver: $name" }
        $resolved = & {
            param($source, $resolver)
            $NodePath = $null
            . ([scriptblock]::Create($source))
            & $resolver
        } $fn.Extent.Text $name
        if ($resolved -ne $portable) { throw "Portable Node fallback failed: $name" }
        $resolverChecks++
    }
} finally {
    $env:Path=$saved.Path; $env:USERPROFILE=$saved.USERPROFILE; $env:LOCALAPPDATA=$saved.LOCALAPPDATA
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedFixture) -notlike 'portable-node-probe-*') { throw 'Unsafe Node fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
[pscustomobject]@{
    WindowsPowerShell = $true
    NodeCapabilityProbe = $true
    PortableProductionResolvers = $resolverChecks
} | ConvertTo-Json
