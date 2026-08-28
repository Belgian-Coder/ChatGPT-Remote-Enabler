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

[pscustomobject]@{
    WindowsPowerShell = $true
    NodeCapabilityProbe = $true
} | ConvertTo-Json
