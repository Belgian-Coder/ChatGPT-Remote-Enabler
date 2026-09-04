[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'windows\CodexRemoteSimple\runtime\PackageProcessLauncher.cs'
$compilerCandidates = @(
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw 'The .NET Framework C# compiler was not found.' }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-package-process-launcher-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $launcher = Join-Path $temporaryRoot 'PackageProcessLauncher.exe'
    $probeSource = Join-Path $temporaryRoot 'EnvironmentProbe.cs'
    $probe = Join-Path $temporaryRoot 'Environment Probe.exe'
    $output = Join-Path $temporaryRoot 'environment result.txt'
    $probeText = @'
using System;
using System.IO;

internal static class EnvironmentProbe
{
    public static int Main(string[] args)
    {
        File.WriteAllLines(args[0], new [] {
            Environment.GetEnvironmentVariable("HTTP_PROXY") ?? "",
            Environment.GetEnvironmentVariable("HTTPS_PROXY") ?? "",
            Environment.GetEnvironmentVariable("http_proxy") ?? "",
            Environment.GetEnvironmentVariable("https_proxy") ?? "",
            Environment.GetEnvironmentVariable("NODE_USE_ENV_PROXY") ?? "",
            Environment.GetEnvironmentVariable("NO_PROXY") ?? "",
            Environment.GetEnvironmentVariable("no_proxy") ?? ""
        });
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($probeSource, $probeText, [Text.UTF8Encoding]::new($false))
    & $compiler /nologo /target:exe "/out:$launcher" $source
    if ($LASTEXITCODE -ne 0) { throw 'Package process launcher compilation failed.' }
    & $compiler /nologo /target:exe "/out:$probe" $probeSource
    if ($LASTEXITCODE -ne 0) { throw 'Environment probe compilation failed.' }

    $proxy = 'http://proxy.example.invalid:8080'
    & $launcher $probe $proxy $output | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The package process launcher rejected a valid proxy.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $output -PathType Leaf) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw 'The scoped child process did not produce its environment report.'
    }
    $values = @([IO.File]::ReadAllLines($output))
    if ($values.Count -ne 7 -or ($values[0..3] | Where-Object { $_ -cne $proxy }).Count -ne 0 -or
        $values[4] -cne '1' -or $values[5] -notmatch '(^|,)127\.0\.0\.1(,|$)' -or
        $values[6] -notmatch '(^|,)localhost(,|$)') {
        throw 'The child process did not receive the scoped proxy and loopback-bypass environment.'
    }

    & $launcher $probe 'http://user:password@proxy.example.invalid:8080' $output 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'A credential-bearing proxy URL was accepted.' }
    $global:LASTEXITCODE = 0

    [pscustomobject]@{
        ChildEnvironmentScoped = $true
        CredentialProxyRejected = $true
        LoopbackBypassPresent = $true
    } | ConvertTo-Json
} finally {
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $temporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolved) -and
        [IO.Path]::GetFullPath((Split-Path -Parent $resolved)) -eq $temporary -and
        [IO.Path]::GetFileName($resolved) -match '^chatgpt-package-process-launcher-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
