[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$buildScript = Join-Path $PSScriptRoot 'Build-Release.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($buildScript, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Build-Release.ps1 has a parse error: $($errors[0].Message)" }
$functionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ReleasePrivacy'
}, $true)
if (-not $functionAst) { throw 'Assert-ReleasePrivacy was not found in Build-Release.ps1.' }
. ([scriptblock]::Create($functionAst.Extent.Text))

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-remote-privacy-test-" + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    $fixture = Join-Path $temporaryRoot 'fixture.txt'
    $forbiddenValues = @(
        @('PC','MARC'),
        @('WINDOWS11','VM'),
        @('MacBook','Pro')
    ) | ForEach-Object {
        $label = $_ -join '-'
        $label
        $label.ToLowerInvariant()
    }
    foreach ($value in $forbiddenValues) {
        [IO.File]::WriteAllText($fixture, "Fixture host: $value", [Text.UTF8Encoding]::new($false))
        $failed = $false
        try {
            Assert-ReleasePrivacy -StageRoot $temporaryRoot
        } catch {
            if ($_.Exception.Message -ne 'Privacy scan failed for fixture.txt.') { throw }
            $failed = $true
        }
        if (-not $failed) { throw "Privacy scan accepted forbidden fixture value: $value" }
    }

    [IO.File]::WriteAllText(
        $fixture,
        '(?i)\bPC[-]MARC\b (?i)\bWINDOWS11[-]VM\b (?i)\bMacBook[-]Pro\b',
        [Text.UTF8Encoding]::new($false)
    )
    Assert-ReleasePrivacy -StageRoot $temporaryRoot

    [pscustomobject]@{
        ForbiddenValuesRejected = $forbiddenValues.Count
        ScannerRegexLiteralsAccepted = $true
    } | ConvertTo-Json
} finally {
    $resolvedTemp = [IO.Path]::GetFullPath($temporaryRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemp) -and $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
