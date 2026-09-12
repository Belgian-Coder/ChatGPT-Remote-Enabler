# Shared Windows installation-root, migration, and cleanup helpers.
#
# This file deliberately contains functions only.  It is dot-sourced by the
# setup, shortcut, startup, and updater entry points.  The canonical root is
# permanent and version-independent; update journals and rollback material
# live in the per-user updater state instead.

function Get-StableMachineInstallRoot {
    $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonData)) { $commonData = $env:ProgramData }
    if ([string]::IsNullOrWhiteSpace($commonData)) { throw 'The common application-data directory is unavailable.' }
    return [IO.Path]::GetFullPath((Join-Path $commonData 'CodexRemoteFeatures\ChatGPT-Remote-Enabler-Windows-x64')).TrimEnd('\')
}

function Get-StableInstallRoot {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return [IO.Path]::GetFullPath($Override).TrimEnd('\')
    }
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localData)) { $localData = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($localData)) { throw 'The current-user application-data directory is unavailable.' }
    return [IO.Path]::GetFullPath((Join-Path $localData 'CodexRemoteFeatures\ChatGPT-Remote-Enabler-Windows-x64')).TrimEnd('\')
}

function Test-StablePathWithin {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return [string]::Equals($resolvedPath, $resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-StableNoReparsePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$StopAt)
    $current = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $stop = [IO.Path]::GetFullPath($StopAt).TrimEnd('\')
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Stable installation path traverses a reparse point: $current" }
        if ([string]::Equals($current.TrimEnd('\'), $stop, [StringComparison]::OrdinalIgnoreCase)) { return }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) { throw 'Stable installation path escaped its trusted root.' }
        $current = $parent
    }
}

function Get-StableVersion {
    param([Parameter(Mandatory)][string]$Root)
    $versionPath = Join-Path $Root 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { throw "Stable installation VERSION is missing: $Root" }
    $version = (Get-Content -LiteralPath $versionPath -Raw -ErrorAction Stop).Trim()
    if ($version -notmatch '^v\d+\.\d+\.\d+$') { throw "Stable installation VERSION is invalid: $version" }
    return $version
}

function Test-StablePackage {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$RequireManifest
    )
    try {
        $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
        Assert-StableNoReparsePath -Path $Root -StopAt ([IO.Path]::GetPathRoot($Root))
        $version = Get-StableVersion -Root $Root
        $required = @(
            'ChatGPT Remote Enabler.exe',
            'Enable-ChatGPTRemote.ps1',
            'Update-ChatGPTRemote.ps1',
            'StableInstall.ps1',
            'update-transaction.js',
            'CodexRemoteMobileProject\ChatGPT Custom.exe',
            'CodexRemoteMobileProject\MobileProjectStartup.ps1',
            'CodexRemoteMobileProject\UpdateSessionTaskHost.exe',
            'CodexRemoteSimple\CodexRemoteSimple.ps1'
        )
        foreach ($relative in $required) {
            $file = Join-Path $Root $relative
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
            if ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        }
        if ($RequireManifest) {
            $manifest = Join-Path $Root 'RELEASE-MANIFEST.sha256'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
            $entries = @(Get-Content -LiteralPath $manifest -ErrorAction Stop)
            if ($entries.Count -eq 0) { return $false }
            $manifestPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($line in $entries) {
                if ($line -notmatch '^([0-9a-fA-F]{64}) \*(.+)$') { return $false }
                $relative = $matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
                if ([IO.Path]::IsPathRooted($relative) -or $relative.Split([IO.Path]::DirectorySeparatorChar) -contains '..') { return $false }
                if (-not $manifestPaths.Add($relative)) { return $false }
                $file = [IO.Path]::GetFullPath((Join-Path $Root $relative))
                if (-not (Test-StablePathWithin -Path $file -Root $Root) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
                if ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
                if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $matches[1]) { return $false }
            }
            foreach ($relative in @($required + 'VERSION')) {
                if (-not $manifestPaths.Contains($relative)) { return $false }
            }
        }
        $expectedFileVersion = $version.TrimStart('v') + '.0'
        foreach ($relative in @('ChatGPT Remote Enabler.exe', 'CodexRemoteMobileProject\ChatGPT Custom.exe')) {
            $file = Join-Path $Root $relative
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $fileVersion = [string](Get-Item -LiteralPath $file).VersionInfo.FileVersion
                if ($fileVersion -and $fileVersion -ne $expectedFileVersion) { return $false }
            }
        }
        return $true
    } catch { return $false }
}

function Copy-StablePackageContents {
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$DestinationRoot)
    foreach ($item in Get-ChildItem -LiteralPath $SourceRoot -Force) {
        if ($item.Name -in @('rollback', '.git', '.chatgpt-remote-release.zip', '.chatgpt-remote-prepared.json')) { continue }
        $destination = Join-Path $DestinationRoot $item.Name
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
    }
}

function Resolve-StableTransactionNode {
    foreach ($candidate in @(
        $(if (Get-Command node.exe -ErrorAction SilentlyContinue) { (Get-Command node.exe -ErrorAction SilentlyContinue).Source }),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'),
        (Join-Path $env:ProgramFiles 'nodejs\node.exe')
    ) | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $reported = @(& $candidate --version 2>$null | Select-Object -First 1)
        if ($reported.Count -eq 1 -and [string]$reported[0] -match '^v(?<major>\d+)\.' -and [int]$Matches.major -ge 22) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Node.js 22 or newer was not found for the stable installation transaction.'
}

function Invoke-StableTransactionHelper {
    param(
        [Parameter(Mandatory)][string]$NodePath,
        [Parameter(Mandatory)][string]$HelperPath,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) { throw "Stable transaction helper is missing: $HelperPath" }
    $output = @(& $NodePath $HelperPath $Operation @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $output.Count -ne 1) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join ' '
        throw "Stable transaction helper failed during ${Operation}: $detail"
    }
    return ([string]$output[0] | ConvertFrom-Json -ErrorAction Stop)
}

function Enter-StableUpdateLock {
    param([Parameter(Mandatory)][string]$StateRoot, [ValidateRange(1, 600)][int]$TimeoutSeconds = 120)
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $path = Join-Path $StateRoot 'update.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.SetLength(0)
            $bytes = [Text.Encoding]::UTF8.GetBytes("pid=$PID checkedAt=$([DateTime]::UtcNow.ToString('o'))`n")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            return $stream
        } catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw "UPDATE_BUSY: another updater still owns the lock after $TimeoutSeconds seconds." }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
}

function Enter-StableLaunchGuard {
    param([ValidateRange(1, 600)][int]$TimeoutSeconds = 120)
    $mutex = [Threading.Mutex]::new($false, 'Local\ChatGPTCustomInjectionLauncher')
    try {
        $acquired = $false
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw "UPDATE_BUSY: launcher injection still owns the launch guard after $TimeoutSeconds seconds." }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Ensure-StableInstallRoot {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [string]$StableRoot,
        [string]$UpdaterStateRoot = (Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update'),
        [ValidateRange(1, 600)][int]$LockTimeoutSeconds = 120,
        [switch]$UpdateLockHeld,
        [switch]$LaunchGuardHeld
    )
    $SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($StableRoot)) { $StableRoot = Get-StableInstallRoot }
    $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
    $UpdaterStateRoot = [IO.Path]::GetFullPath($UpdaterStateRoot).TrimEnd('\')
    $sourceIsPackaged = Test-Path -LiteralPath (Join-Path $SourceRoot 'RELEASE-MANIFEST.sha256') -PathType Leaf
    $sourceValid = Test-StablePackage -Root $SourceRoot -RequireManifest:$sourceIsPackaged
    if (-not $sourceValid) { throw "The source installation failed VERSION, launcher, or controller validation: $SourceRoot" }
    $lockStream = $null
    $launchGuard = $null
    try {
        if (-not $LaunchGuardHeld) { $launchGuard = Enter-StableLaunchGuard -TimeoutSeconds $LockTimeoutSeconds }
        if (-not $UpdateLockHeld) { $lockStream = Enter-StableUpdateLock -StateRoot $UpdaterStateRoot -TimeoutSeconds $LockTimeoutSeconds }

        $journalPath = Join-Path $UpdaterStateRoot 'transaction.json'
        $sourceHelper = Join-Path $SourceRoot 'update-transaction.js'
        $nodePath = $null
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
            $nodePath = Resolve-StableTransactionNode
            [void](Invoke-StableTransactionHelper -NodePath $nodePath -HelperPath $sourceHelper -Operation 'recover' -Arguments @('--journal-path', $journalPath, '--install-root', $StableRoot))
        }

        $stableBasicValid = Test-StablePackage -Root $StableRoot
        $stableValid = $stableBasicValid -and (Test-StablePackage -Root $StableRoot -RequireManifest:$sourceIsPackaged)
        $sourceVersion = ConvertTo-StableSemanticVersion (Get-StableVersion -Root $SourceRoot)
        $stableVersion = $null
        if ($stableBasicValid) {
            $stableVersion = ConvertTo-StableSemanticVersion (Get-StableVersion -Root $StableRoot)
            if ($sourceVersion -le $stableVersion -and $stableValid) { return $StableRoot }
            if ($sourceVersion -lt $stableVersion) { throw "A package at $((Get-StableVersion -Root $SourceRoot)) cannot repair or replace newer stable installation $((Get-StableVersion -Root $StableRoot))." }
        }

        if (Test-Path -LiteralPath $StableRoot) {
            if (-not $stableBasicValid) { throw "The canonical stable installation is present but failed validation: $StableRoot" }
            if (-not $sourceIsPackaged) { throw 'Updating an existing stable installation requires a packaged source with RELEASE-MANIFEST.sha256.' }
            if (-not $nodePath) { $nodePath = Resolve-StableTransactionNode }
            $safeVersion = (Get-StableVersion -Root $SourceRoot) -replace '[^A-Za-z0-9._-]', '_'
            $preparedParent = Join-Path $UpdaterStateRoot 'prepared'
            $temporary = Join-Path $preparedParent ("setup-$safeVersion-" + [guid]::NewGuid().ToString('N'))
            $backup = Join-Path (Join-Path $UpdaterStateRoot 'rollback') ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$safeVersion-setup")
            try {
                New-Item -ItemType Directory -Path $temporary -Force | Out-Null
                Copy-StablePackageContents -SourceRoot $SourceRoot -DestinationRoot $temporary
                if (-not (Test-StablePackage -Root $temporary -RequireManifest)) { throw 'The staged stable update failed verification.' }
                $retainedArchive = Join-Path $temporary '.chatgpt-remote-release.zip'
                Copy-Item -LiteralPath (Join-Path $temporary 'RELEASE-MANIFEST.sha256') -Destination $retainedArchive -Force
                $archiveHash = (Get-FileHash -LiteralPath $retainedArchive -Algorithm SHA256).Hash.ToLowerInvariant()
                $helper = Join-Path $temporary 'update-transaction.js'
                [void](Invoke-StableTransactionHelper -NodePath $nodePath -HelperPath $helper -Operation 'seal-prepared' -Arguments @('--prepared-root', $temporary, '--platform', 'Windows-x64', '--version', (Get-StableVersion -Root $SourceRoot), '--archive-sha256', $archiveHash))
                [void](Invoke-StableTransactionHelper -NodePath $nodePath -HelperPath $helper -Operation 'apply' -Arguments @('--install-root', $StableRoot, '--prepared-root', $temporary, '--journal-path', $journalPath, '--backup-root', $backup, '--platform', 'Windows-x64', '--version', (Get-StableVersion -Root $SourceRoot), '--archive-sha256', $archiveHash))
                if (-not (Test-StablePackage -Root $StableRoot -RequireManifest)) { throw 'The stable update failed post-transaction verification.' }
                return $StableRoot
            } finally {
                if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf) -and (Test-Path -LiteralPath $temporary -PathType Container)) {
                    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $parent = Split-Path -Parent $StableRoot
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $temporary = Join-Path $parent ('.ChatGPT-Remote-Enabler-Windows-x64.migrate-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $temporary -Force | Out-Null
            Copy-StablePackageContents -SourceRoot $SourceRoot -DestinationRoot $temporary
            if (-not (Test-StablePackage -Root $temporary -RequireManifest:$sourceIsPackaged)) { throw 'The migrated stable installation failed post-copy validation.' }
            [IO.Directory]::Move($temporary, $StableRoot)
        } catch {
            if (Test-Path -LiteralPath $StableRoot -PathType Container) {
                if (-not (Test-StablePackage -Root $StableRoot -RequireManifest:$sourceIsPackaged)) { throw }
            } else { throw }
        } finally {
            if (Test-Path -LiteralPath $temporary -PathType Container) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if (-not (Test-StablePackage -Root $StableRoot -RequireManifest:$sourceIsPackaged)) { throw 'The canonical stable installation failed validation after migration.' }
        return $StableRoot
    } finally {
        if ($lockStream) { $lockStream.Dispose() }
        if ($launchGuard) { try { $launchGuard.ReleaseMutex() } finally { $launchGuard.Dispose() } }
    }
}

function Get-StableLegacyRoots {
    param([string]$StableRoot)
    if ([string]::IsNullOrWhiteSpace($StableRoot)) { $StableRoot = Get-StableInstallRoot }
    $stable = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
    $candidates = [Collections.Generic.List[string]]::new()
    $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonData)) { $commonData = $env:ProgramData }
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localData)) { $localData = $env:LOCALAPPDATA }
    $localPrograms = Join-Path $localData 'Programs'
    $parents = @(
        (Join-Path $commonData 'CodexRemoteFeatures\releases'),
        $commonData,
        (Join-Path $localData 'CodexRemoteFeatures'),
        $localPrograms
    )
    foreach ($parent in $parents | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }) {
        foreach ($directory in Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue) {
            if ($directory.FullName -eq $stable) { continue }
            if ($directory.Name -match '^(?:ChatGPT-Remote-Enabler-Windows-x64|ChatGPTRemoteEnabler)(?:[-_]?v\d+\.\d+\.\d+)?$' -and
                $directory.Name -match 'v\d+\.\d+\.\d+$') {
                $candidates.Add([IO.Path]::GetFullPath($directory.FullName).TrimEnd('\'))
            }
        }
    }
    $defaultStable = Get-StableInstallRoot
    if ([string]::Equals($stable, $defaultStable, [StringComparison]::OrdinalIgnoreCase)) {
        $machineStable = Get-StableMachineInstallRoot
        if (-not [string]::Equals($machineStable, $stable, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $machineStable -PathType Container)) {
            $candidates.Add($machineStable)
        }
    }
    return @($candidates | Select-Object -Unique)
}

function Test-StableLegacyRoot {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ([string]::Equals($resolved, (Get-StableMachineInstallRoot), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $leaf = [IO.Path]::GetFileName($resolved)
    return $leaf -match '^(?:ChatGPT-Remote-Enabler-Windows-x64|ChatGPTRemoteEnabler)(?:[-_]?v\d+\.\d+\.\d+)$'
}

function Test-StableTextReferencesRoot {
    param([string]$Path, [string]$Root)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ($text.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        try {
            $state = $text | ConvertFrom-Json -ErrorAction Stop
            return Test-StableValueReferencesRoot -Value $state -Root $Root
        } catch { return $false }
    } catch { return $true }
}

function Test-StableValueReferencesRoot {
    param([object]$Value, [Parameter(Mandatory)][string]$Root, [int]$Depth = 0)
    if ($Depth -gt 32) { return $true }
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) {
        return $Value.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($entryValue in $Value.Values) {
            if (Test-StableValueReferencesRoot -Value $entryValue -Root $Root -Depth ($Depth + 1)) { return $true }
        }
        return $false
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($item in $Value) {
            if (Test-StableValueReferencesRoot -Value $item -Root $Root -Depth ($Depth + 1)) { return $true }
        }
        return $false
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if (Test-StableValueReferencesRoot -Value $property.Value -Root $Root -Depth ($Depth + 1)) { return $true }
        }
    }
    return $false
}

function Test-StableNoLiveRootReference {
    param([Parameter(Mandatory)][string]$Root, [scriptblock]$ProcessEnumerator)
    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    try {
        $processes = if ($ProcessEnumerator) { @(& $ProcessEnumerator) } else { @(Get-CimInstance Win32_Process -ErrorAction Stop) }
    } catch { return $false }
    foreach ($process in $processes) {
        foreach ($value in @([string]$process.ExecutablePath, [string]$process.CommandLine)) {
            if ($value -and $value.IndexOf($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
        }
        $commandLine = [string]$process.CommandLine
        if ($commandLine -and $commandLine -match '(?i)(?:^|[\\/])update-session\.js(?:"|\s)' ) {
            $configMatch = [regex]::Match($commandLine, '(?i)(?:^|\s)--config(?:=|\s+)(?:"(?<quoted>[^"]+)"|(?<bare>\S+))')
            if (-not $configMatch.Success) { return $false }
            $configPath = if ($configMatch.Groups['quoted'].Success) { $configMatch.Groups['quoted'].Value } else { $configMatch.Groups['bare'].Value.Trim('"') }
            try {
                $configState = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if (Test-StableValueReferencesRoot -Value $configState -Root $rootPrefix.TrimEnd('\')) { return $false }
            } catch { return $false }
        }
    }
    return $true
}

function Test-StableLegacyPackageIdentity {
    param([Parameter(Mandatory)][string]$Root)
    try {
        $version = Get-StableVersion -Root $Root
        $required = @(
            'ChatGPT Remote Enabler.exe',
            'Enable-ChatGPTRemote.ps1',
            'CodexRemoteMobileProject\ChatGPT Custom.exe',
            'CodexRemoteMobileProject\MobileProjectStartup.ps1',
            'CodexRemoteSimple\CodexRemoteSimple.ps1'
        )
        foreach ($relative in $required) {
            $file = Join-Path $Root $relative
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Test-StableExternalReferences {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$ShortcutPaths = @(),
        [string[]]$TaskNames = @(),
        [scriptblock]$ProcessEnumerator
    )
    if (-not (Test-StableNoLiveRootReference -Root $Root -ProcessEnumerator $ProcessEnumerator)) { return $false }
    foreach ($shortcutPath in @($ShortcutPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })) {
        try {
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
            if (([string]$shortcut.TargetPath).IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                ([string]$shortcut.WorkingDirectory).IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                ([string]$shortcut.Arguments).IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                ([string]$shortcut.IconLocation).IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
        } catch { return $false }
    }
    foreach ($taskName in @($TaskNames | Where-Object { $_ })) {
        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $task) { continue }
            foreach ($action in @($task.Actions)) {
                foreach ($value in @([string]$action.Execute, [string]$action.Arguments, [string]$action.WorkingDirectory)) {
                    if ($value -and $value.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
                }
            }
        } catch { return $false }
    }
    return $true
}

function Get-StableKnownEntryPoints {
    param([string[]]$ShortcutPaths = @(), [string[]]$TaskNames = @())
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    $startMenu = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    $startup = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    $knownShortcuts = @(
        (Join-Path $desktop 'ChatGPT Remote Enabler.lnk'),
        (Join-Path $startMenu 'ChatGPT Remote Enabler.lnk'),
        (Join-Path $desktop 'ChatGPT Custom.lnk'),
        (Join-Path $startMenu 'ChatGPT Custom.lnk'),
        (Join-Path $startMenu 'ChatGPT Custom (Proxy Test).lnk'),
        (Join-Path $startMenu 'ChatGPT Custom (Proxy).lnk'),
        (Join-Path $startup 'ChatGPT Remote Enabler Startup.lnk'),
        (Join-Path $startup 'ChatGPT Custom Startup.lnk'),
        (Join-Path $startup 'ChatGPT Custom.lnk'),
        (Join-Path $startup 'ChatGPT Remote Enabler.lnk')
    )
    return [pscustomobject]@{
        ShortcutPaths = @($ShortcutPaths + $knownShortcuts | Where-Object { $_ } | Select-Object -Unique)
        TaskNames = @($TaskNames + 'Codex Remote Mobile Features at Logon' | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Test-StableEntryPointsMigrated {
    param([Parameter(Mandatory)][string]$StableRoot, [string[]]$ShortcutPaths = @(), [string[]]$TaskNames = @())
    try {
        $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
        $rootLauncher = Join-Path $StableRoot 'ChatGPT Remote Enabler.exe'
        $customLauncher = Join-Path $StableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        foreach ($shortcutPath in @($ShortcutPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })) {
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
            $name = [IO.Path]::GetFileName($shortcutPath)
            $startup = (Split-Path -Parent $shortcutPath).EndsWith('\Startup', [StringComparison]::OrdinalIgnoreCase) -or $name -match '(?i)Startup'
            $expectedTarget = if ($startup -or $name -match '(?i)^ChatGPT Custom') { $customLauncher } else { $rootLauncher }
            $target = [IO.Path]::GetFullPath([string]$shortcut.TargetPath)
            $workingDirectory = [IO.Path]::GetFullPath([string]$shortcut.WorkingDirectory).TrimEnd('\')
            if (-not [string]::Equals($target, $expectedTarget, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($workingDirectory, $StableRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $expectedTarget -PathType Leaf)) { return $false }
            $arguments = ([string]$shortcut.Arguments).Trim()
            if ($startup) {
                if ($arguments -notin @('--startup', '--proxy --startup')) { return $false }
            } elseif ($arguments -notin @('', '--proxy')) { return $false }
            $icon = ([string]$shortcut.IconLocation).Split(',')[0].Trim('"')
            if ($icon -and -not [string]::Equals([IO.Path]::GetFullPath($icon), $expectedTarget, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        foreach ($taskName in @($TaskNames | Where-Object { $_ })) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $task) { continue }
            $actions = @($task.Actions)
            if ($actions.Count -ne 1) { return $false }
            $expectedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $expectedScript = Join-Path $StableRoot 'CodexRemoteMobileProject\MobileProjectStartup.ps1'
            $action = $actions[0]
            if (-not [string]::Equals([IO.Path]::GetFullPath([string]$action.Execute), $expectedPowerShell, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\'), (Join-Path $StableRoot 'CodexRemoteMobileProject'), [StringComparison]::OrdinalIgnoreCase) -or
                ([string]$action.Arguments).IndexOf('"' + $expectedScript + '"', [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
                [string]$action.Arguments -notmatch '(?i)(?:^|\s)-Action\s+Run(?:\s|$)') { return $false }
        }
        return $true
    } catch { return $false }
}

function ConvertTo-StableSemanticVersion {
    param([Parameter(Mandatory)][string]$Value)
    return [version]$Value.Trim().TrimStart('v')
}

function Get-StableTreeDigest {
    param([Parameter(Mandatory)][string]$Root)
    $records = foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Root.Length + 1).Replace('\', '/')
        '{0} {1}' -f $relative, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($records -join "`n"))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Assert-StableNoReparseTree {
    param([Parameter(Mandatory)][string]$Root)
    Assert-StableNoReparsePath -Path $Root -StopAt ([IO.Path]::GetPathRoot($Root))
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Stable cleanup tree contains a reparse point: $($item.FullName)"
        }
    }
}

function Copy-StableRecoveryTree {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw "Recovery destination already exists: $Destination" }
    Assert-StableNoReparseTree -Root $Source
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    if ((Get-StableTreeDigest -Root $Source) -cne (Get-StableTreeDigest -Root $Destination)) {
        throw "Recovery material failed verification: $Source"
    }
}

function Invoke-StableShortcutMigration {
    param(
        [Parameter(Mandatory)][string]$StableRoot,
        [string]$DesktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
        [string]$StartMenuPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs),
        [string]$StartupPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    )
    $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
    $rootLauncher = Join-Path $StableRoot 'ChatGPT Remote Enabler.exe'
    $customLauncher = Join-Path $StableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    if (-not (Test-Path -LiteralPath $rootLauncher -PathType Leaf) -or -not (Test-Path -LiteralPath $customLauncher -PathType Leaf)) {
        return @([pscustomobject][ordered]@{ migrated = $false; reason = 'stable-launcher-missing' })
    }
    $paths = [Collections.Generic.List[object]]::new()
    foreach ($entry in @(
        [ordered]@{ path = Join-Path $DesktopPath 'ChatGPT Remote Enabler.lnk'; target = $rootLauncher; startup = $false },
        [ordered]@{ path = Join-Path $StartMenuPath 'ChatGPT Remote Enabler.lnk'; target = $rootLauncher; startup = $false },
        [ordered]@{ path = Join-Path $DesktopPath 'ChatGPT Custom.lnk'; target = $customLauncher; startup = $false },
        [ordered]@{ path = Join-Path $StartMenuPath 'ChatGPT Custom.lnk'; target = $customLauncher; startup = $false },
        [ordered]@{ path = Join-Path $StartMenuPath 'ChatGPT Custom (Proxy Test).lnk'; target = $customLauncher; startup = $false },
        [ordered]@{ path = Join-Path $StartMenuPath 'ChatGPT Custom (Proxy).lnk'; target = $customLauncher; startup = $false },
        [ordered]@{ path = Join-Path $StartupPath 'ChatGPT Remote Enabler Startup.lnk'; target = $customLauncher; startup = $true },
        [ordered]@{ path = Join-Path $StartupPath 'ChatGPT Custom Startup.lnk'; target = $customLauncher; startup = $true },
        [ordered]@{ path = Join-Path $StartupPath 'ChatGPT Custom.lnk'; target = $customLauncher; startup = $true },
        [ordered]@{ path = Join-Path $StartupPath 'ChatGPT Remote Enabler.lnk'; target = $customLauncher; startup = $true }
    )) { $paths.Add([pscustomobject]$entry) }
    $results = [Collections.Generic.List[object]]::new()
    try { $shell = New-Object -ComObject WScript.Shell } catch { return @([pscustomobject][ordered]@{ migrated = $false; reason = 'shortcut-shell-unavailable' }) }
    foreach ($entry in $paths) {
        if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) { continue }
        try {
            $existing = $shell.CreateShortcut($entry.path)
            $oldArguments = [string]$existing.Arguments
            $proxy = $oldArguments -match '(?:^|\s)--proxy(?:\s|$)'
            $shortcut = $shell.CreateShortcut($entry.path)
            $shortcut.TargetPath = $entry.target
            $shortcut.Arguments = if ($entry.startup) { if ($proxy) { '--proxy --startup' } else { '--startup' } } elseif ($proxy) { '--proxy' } else { '' }
            $shortcut.WorkingDirectory = $StableRoot
            $shortcut.IconLocation = "$($entry.target),0"
            $shortcut.WindowStyle = 1
            $shortcut.Save()
            $results.Add([pscustomobject][ordered]@{ path = $entry.path; migrated = $true; targetPath = $entry.target; arguments = $shortcut.Arguments })
        } catch { $results.Add([pscustomobject][ordered]@{ path = $entry.path; migrated = $false; reason = 'shortcut-migration-failed' }) }
    }
    return @($results)
}

function Invoke-StableTaskMigration {
    param([Parameter(Mandatory)][string]$StableRoot)
    $results = [Collections.Generic.List[object]]::new()
    $service = $folder = $definition = $registered = $restore = $null
    $originalXml = $null
    $beforeEnabled = $false
    $beforeRunLevel = 0
    $beforeLogonType = 0
    $beforeUserId = $null
    $taskName = 'Codex Remote Mobile Features at Logon'
    $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
    $canonicalStableRoot = Get-StableInstallRoot
    if (-not [string]::Equals($StableRoot, $canonicalStableRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return @([pscustomobject][ordered]@{ taskName = $taskName; migrated = $false; reason = 'noncanonical-stable-root' })
    }
    try {
        $tasks = @(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
        if ($tasks.Count -eq 0) { return @() }
        if ($tasks.Count -ne 1) { throw 'The Remote Enabler logon task name is ambiguous.' }
        $task = $tasks[0]
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $folder = $service.GetFolder([string]$task.TaskPath)
        $definition = $folder.GetTask([string]$task.TaskName).Definition
        $originalXml = [string]$definition.XmlText
        $beforeEnabled = [bool]$definition.Settings.Enabled
        $beforeRunLevel = [int]$definition.Principal.RunLevel
        $beforeLogonType = [int]$definition.Principal.LogonType
        $beforeUserId = [string]$definition.Principal.UserId
        $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $matchedAction = $false
        foreach ($action in @($definition.Actions)) {
            if ([string]$action.Arguments -match '(?i)(?:MobileProjectStartup\.ps1|Enable-ChatGPTRemote\.ps1)') {
                $matchedAction = $true
                $proxy = [string]$action.Arguments -match '(?:^|\s)-UseProxy(?:\s|$)|(?:^|\s)--proxy(?:\s|$)'
                $action.Path = $powerShell
                $action.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $StableRoot 'CodexRemoteMobileProject\MobileProjectStartup.ps1') + '" -Action Run' + $(if ($proxy) { ' -UseProxy' } else { '' })
                $action.WorkingDirectory = Join-Path $StableRoot 'CodexRemoteMobileProject'
            }
        }
        if (-not $matchedAction) { throw 'The existing logon task has no recognized Remote Enabler action.' }
        [void]$folder.RegisterTaskDefinition([string]$task.TaskName, $definition, 6, $(if ($beforeUserId) { $beforeUserId } else { $null }), $null, $beforeLogonType, $null)
        $registered = $folder.GetTask([string]$task.TaskName).Definition
        if ([bool]$registered.Settings.Enabled -ne $beforeEnabled -or [int]$registered.Principal.RunLevel -ne $beforeRunLevel -or
            [int]$registered.Principal.LogonType -ne $beforeLogonType -or
            -not [string]::Equals([string]$registered.Principal.UserId, $beforeUserId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The logon task principal or enabled state changed during stable-root migration.'
        }
        $results.Add([pscustomobject][ordered]@{ taskName = [string]$task.TaskName; migrated = $true })
    } catch {
        $reason = 'task-migration-failed'
        if ($folder -and $service -and $originalXml) {
            try {
                $restore = $service.NewTask(0)
                $restore.XmlText = $originalXml
                [void]$folder.RegisterTaskDefinition($taskName, $restore, 6, $(if ($beforeUserId) { $beforeUserId } else { $null }), $null, $beforeLogonType, $null)
            } catch { $reason = 'task-migration-and-rollback-failed' }
        }
        $results.Add([pscustomobject][ordered]@{ taskName = $taskName; migrated = $false; reason = $reason })
    } finally {
        foreach ($value in @($restore, $registered, $definition, $folder, $service)) {
            if ($value -and [Runtime.InteropServices.Marshal]::IsComObject($value)) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($value) } catch {} }
        }
    }
    return @($results)
}

function Invoke-StableLegacyCleanup {
    param(
        [Parameter(Mandatory)][string]$StableRoot,
        [string]$UpdaterStateRoot = (Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\update'),
        [string[]]$ShortcutPaths = @(),
        [string[]]$TaskNames = @(),
        [scriptblock]$ProcessEnumerator,
        [switch]$MigrateEntryPoints,
        [string[]]$LegacyRoots = @(),
        [string[]]$ApprovedLegacyParents = @()
    )
    $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
    $results = [Collections.Generic.List[object]]::new()
    if (-not (Test-StablePackage -Root $StableRoot -RequireManifest)) {
        return @([pscustomobject][ordered]@{ cleaned = $false; reason = 'stable-root-validation-failed' })
    }
    $canonicalStableRoot = Get-StableInstallRoot
    $isCanonicalStableRoot = [string]::Equals($StableRoot, $canonicalStableRoot, [StringComparison]::OrdinalIgnoreCase)
    if (-not $isCanonicalStableRoot -and $LegacyRoots.Count -eq 0) {
        return @([pscustomobject][ordered]@{ cleaned = $false; reason = 'noncanonical-stable-root' })
    }
    if ($MigrateEntryPoints -and $isCanonicalStableRoot) {
        [void](Invoke-StableShortcutMigration -StableRoot $StableRoot)
        [void](Invoke-StableTaskMigration -StableRoot $StableRoot)
        $known = Get-StableKnownEntryPoints -ShortcutPaths $ShortcutPaths -TaskNames $TaskNames
        $ShortcutPaths = $known.ShortcutPaths
        $TaskNames = $known.TaskNames
    }
    $entryPointsMigrated = -not $MigrateEntryPoints -or (Test-StableEntryPointsMigrated -StableRoot $StableRoot -ShortcutPaths $ShortcutPaths -TaskNames $TaskNames)
    New-Item -ItemType Directory -Path $UpdaterStateRoot -Force | Out-Null
    if ($ApprovedLegacyParents.Count -eq 0) {
        $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        if ([string]::IsNullOrWhiteSpace($commonData)) { $commonData = $env:ProgramData }
        $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localData)) { $localData = $env:LOCALAPPDATA }
        $ApprovedLegacyParents = @(
            (Join-Path $commonData 'CodexRemoteFeatures\releases'),
            (Join-Path $commonData 'CodexRemoteFeatures'),
            $commonData,
            (Join-Path $localData 'CodexRemoteFeatures'),
            (Join-Path $localData 'Programs')
        )
    }
    $approvedParents = @($ApprovedLegacyParents | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    $legacyCandidates = if ($LegacyRoots.Count -gt 0) { @($LegacyRoots) } else { @(Get-StableLegacyRoots -StableRoot $StableRoot) }
    foreach ($legacy in $legacyCandidates) {
        $entry = [ordered]@{ root = $legacy; cleaned = $false; reason = $null }
        try {
            $legacy = [IO.Path]::GetFullPath($legacy).TrimEnd('\')
            $entry.root = $legacy
        } catch {
            $entry.reason = 'legacy-root-path-invalid'
            $results.Add([pscustomobject]$entry)
            continue
        }
        $legacyParent = [IO.Path]::GetFullPath((Split-Path -Parent $legacy)).TrimEnd('\')
        $matchedApprovedParent = @($approvedParents | Where-Object { [string]::Equals($legacyParent, $_, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
        if (-not (Test-StableLegacyRoot -Path $legacy) -or [string]::Equals($legacy, $StableRoot, [StringComparison]::OrdinalIgnoreCase) -or -not $matchedApprovedParent) {
            $entry.reason = 'legacy-root-name-not-approved'
            $results.Add([pscustomobject]$entry)
            continue
        }
        try {
            Assert-StableNoReparsePath -Path $legacy -StopAt $matchedApprovedParent
            Assert-StableNoReparseTree -Root $legacy
        } catch {
            $entry.reason = 'legacy-root-reparse-or-path-failure'
            $results.Add([pscustomobject]$entry)
            continue
        }
        if (-not (Test-StableLegacyPackageIdentity -Root $legacy)) {
            $entry.reason = 'legacy-root-identity-invalid'
            $results.Add([pscustomobject]$entry)
            continue
        }
        try {
            $activeJournal = @(Get-ChildItem -LiteralPath $legacy -File -Recurse -Force -ErrorAction Stop | Where-Object {
                $_.Name -in @('transaction.json', 'git-transaction.json') -and $_.FullName -notmatch '(?i)\\rollback\\'
            })
            if ($activeJournal.Count -gt 0) {
                $entry.reason = 'active-journal-in-legacy-root'
                $results.Add([pscustomobject]$entry)
                continue
            }
        } catch {
            $entry.reason = 'legacy-journal-inventory-failed'
            $results.Add([pscustomobject]$entry)
            continue
        }
        try {
            $stableVersion = ConvertTo-StableSemanticVersion (Get-StableVersion -Root $StableRoot)
            $legacyVersion = ConvertTo-StableSemanticVersion (Get-StableVersion -Root $legacy)
            if ($legacyVersion -gt $stableVersion) {
                $entry.reason = 'newer-legacy-version-retained'
                $results.Add([pscustomobject]$entry)
                continue
            }
        } catch {
            $entry.reason = 'legacy-version-invalid'
            $results.Add([pscustomobject]$entry)
            continue
        }
        if (-not (Test-StableExternalReferences -Root $legacy -ShortcutPaths $ShortcutPaths -TaskNames $TaskNames -ProcessEnumerator $ProcessEnumerator)) {
            $entry.reason = 'live-or-entrypoint-reference'
            $results.Add([pscustomobject]$entry)
            continue
        }
        $journalPaths = @(
            (Join-Path $UpdaterStateRoot 'transaction.json'),
            (Join-Path $UpdaterStateRoot 'git-transaction.json')
        )
        $journalReference = $false
        foreach ($journal in $journalPaths) {
            if (Test-StableTextReferencesRoot -Path $journal -Root $legacy) { $journalReference = $true; break }
        }
        if ($journalReference) {
            $entry.reason = 'recovery-material-references-root'
            $results.Add([pscustomobject]$entry)
            continue
        }
        $recoverySources = @(
            [pscustomobject]@{ Name = 'root-rollback'; Path = Join-Path $legacy 'rollback' },
            [pscustomobject]@{ Name = 'mobile-rollback'; Path = Join-Path $legacy 'CodexRemoteMobileProject\rollback' }
        ) | Where-Object { Test-Path -LiteralPath $_.Path -PathType Container }
        $recoveryDestination = $null
        try {
            if (@($recoverySources).Count -gt 0) {
                $digest = Get-StableTreeDigest -Root $legacy
                $recoveryDestination = Join-Path (Join-Path $UpdaterStateRoot 'legacy-recovery') (([IO.Path]::GetFileName($legacy)) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $digest.Substring(0, 16))
                New-Item -ItemType Directory -Path $recoveryDestination -Force | Out-Null
                foreach ($recoverySource in $recoverySources) {
                    Copy-StableRecoveryTree -Source $recoverySource.Path -Destination (Join-Path $recoveryDestination $recoverySource.Name)
                }
                foreach ($recoverySource in $recoverySources) {
                    if (-not (Test-Path -LiteralPath (Join-Path $recoveryDestination $recoverySource.Name) -PathType Container)) { throw 'Recovery destination verification failed.' }
                }
            }
        } catch {
            if ($recoveryDestination -and (Test-Path -LiteralPath $recoveryDestination)) { Remove-Item -LiteralPath $recoveryDestination -Recurse -Force -ErrorAction SilentlyContinue }
            $entry.reason = 'rollback-material-not-durable'
            $results.Add([pscustomobject]$entry)
            continue
        }
        if (-not $entryPointsMigrated) {
            $entry.reason = 'entrypoint-migration-failed'
            $results.Add([pscustomobject]$entry)
            continue
        }
        try {
            Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction Stop
            $entry.cleaned = $true
            $entry.reason = if ($recoveryDestination) { "removed-after-validation; recovery=$recoveryDestination" } else { 'removed-after-validation' }
        } catch { $entry.reason = 'remove-failed' }
        $results.Add([pscustomobject]$entry)
    }
    return @($results)
}

function Invoke-StableUpdaterArtifactCleanup {
    param(
        [Parameter(Mandatory)][string]$UpdaterStateRoot,
        [string[]]$CandidatePaths = @(),
        [scriptblock]$ProcessEnumerator
    )
    $UpdaterStateRoot = [IO.Path]::GetFullPath($UpdaterStateRoot).TrimEnd('\')
    $results = [Collections.Generic.List[object]]::new()
    $paths = @($CandidatePaths)
    foreach ($name in @('prepared', 'staging')) {
        $parent = Join-Path $UpdaterStateRoot $name
        if (Test-Path -LiteralPath $parent -PathType Container) {
            $paths += @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
    }
    foreach ($path in @($paths | Where-Object { $_ } | Select-Object -Unique)) {
        $entry = [ordered]@{ path = $path; removed = $false; reason = $null }
        try {
            $resolved = [IO.Path]::GetFullPath($path).TrimEnd('\')
            $parent = [IO.Path]::GetFullPath((Split-Path -Parent $resolved)).TrimEnd('\')
            $leaf = [IO.Path]::GetFileName($resolved)
            $ownedParents = @((Join-Path $UpdaterStateRoot 'prepared'), (Join-Path $UpdaterStateRoot 'staging'))
            $underOwnedParent = @($ownedParents | Where-Object { [string]::Equals([IO.Path]::GetFullPath($_).TrimEnd('\'), $parent, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            $allowedLeaf = $leaf -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'
            if (-not $underOwnedParent -or -not $allowedLeaf -or -not (Test-Path -LiteralPath $resolved -PathType Container)) {
                $entry.reason = 'artifact-path-not-owned'
                $results.Add([pscustomobject]$entry)
                continue
            }
            Assert-StableNoReparseTree -Root $resolved
            foreach ($journal in @((Join-Path $UpdaterStateRoot 'transaction.json'), (Join-Path $UpdaterStateRoot 'git-transaction.json'))) {
                if (Test-StableTextReferencesRoot -Path $journal -Root $resolved) { throw 'artifact-referenced-by-recovery-journal' }
            }
            if (-not (Test-StableNoLiveRootReference -Root $resolved -ProcessEnumerator $ProcessEnumerator)) { throw 'artifact-referenced-by-live-process' }
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
            $entry.removed = $true
            $entry.reason = 'removed-after-success'
        } catch {
            if (-not $entry.reason) { $entry.reason = 'retained-' + $_.Exception.Message }
        }
        $results.Add([pscustomobject]$entry)
    }
    return @($results)
}

function Invoke-StableRollbackRetention {
    param(
        [Parameter(Mandatory)][string]$UpdaterStateRoot,
        [ValidateRange(1, 50)][int]$RollbackRetainCount = 5,
        [ValidateRange(1, 50)][int]$LegacyRecoveryRetainCount = 2,
        [scriptblock]$ProcessEnumerator
    )
    $UpdaterStateRoot = [IO.Path]::GetFullPath($UpdaterStateRoot).TrimEnd('\\')
    $results = [Collections.Generic.List[object]]::new()
    foreach ($policy in @(
        [pscustomobject]@{ Name = 'rollback'; RetainCount = $RollbackRetainCount },
        [pscustomobject]@{ Name = 'legacy-recovery'; RetainCount = $LegacyRecoveryRetainCount }
    )) {
        $parent = Join-Path $UpdaterStateRoot $policy.Name
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        try {
            Assert-StableNoReparsePath -Path $parent -StopAt $UpdaterStateRoot
            $directories = @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop |
                Sort-Object @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $true })
        } catch {
            $results.Add([pscustomobject][ordered]@{ category = $policy.Name; path = $parent; removed = $false; reason = 'retained-inventory-or-parent-safety-failure' })
            continue
        }
        $safeRank = 0
        foreach ($directory in $directories) {
            $entry = [ordered]@{ category = $policy.Name; path = $directory.FullName; removed = $false; reason = $null }
            try {
                $resolved = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\\')
                $resolvedParent = [IO.Path]::GetFullPath((Split-Path -Parent $resolved)).TrimEnd('\\')
                $leaf = [IO.Path]::GetFileName($resolved)
                if (-not [string]::Equals($resolvedParent, $parent, [StringComparison]::OrdinalIgnoreCase) -or $leaf -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                    throw 'retention-path-not-owned'
                }
                Assert-StableNoReparsePath -Path $resolved -StopAt $UpdaterStateRoot
                Assert-StableNoReparseTree -Root $resolved
                $safeRank++
                if ($safeRank -le $policy.RetainCount) {
                    $entry.reason = 'retained-by-policy'
                    $results.Add([pscustomobject]$entry)
                    continue
                }
                $journalReferenced = $false
                foreach ($journal in @((Join-Path $UpdaterStateRoot 'transaction.json'), (Join-Path $UpdaterStateRoot 'git-transaction.json'))) {
                    if (Test-StableTextReferencesRoot -Path $journal -Root $resolved) { $journalReferenced = $true; break }
                }
                if ($journalReferenced) {
                    $entry.reason = 'retained-active-journal-reference'
                    $results.Add([pscustomobject]$entry)
                    continue
                }
                if (-not (Test-StableNoLiveRootReference -Root $resolved -ProcessEnumerator $ProcessEnumerator)) {
                    $entry.reason = 'retained-live-process-reference'
                    $results.Add([pscustomobject]$entry)
                    continue
                }
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
                $entry.removed = $true
                $entry.reason = 'removed-by-retention-policy'
            } catch {
                if (-not $entry.reason) { $entry.reason = 'retained-' + $_.Exception.Message }
            }
            $results.Add([pscustomobject]$entry)
        }
    }
    return @($results)
}
