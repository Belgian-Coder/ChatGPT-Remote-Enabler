# Shared Windows installation-root, migration, and cleanup helpers.
#
# This file deliberately contains functions only.  It is dot-sourced by the
# setup, shortcut, startup, and updater entry points.  The canonical root is
# permanent and version-independent; update journals and rollback material
# live in the per-user updater state instead.

function Invoke-StableShortcutBroker {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [string[]]$Paths = @(),
        [string]$ScriptPath
    )
    $workerContext = Get-Variable -Name RemoteEnablerShortcutBrokerWorker -Scope Global -ErrorAction SilentlyContinue
    if ($workerContext -and $workerContext.Value) { return [pscustomobject]@{ handled = $false } }
    $programs = [IO.Path]::GetFullPath([Environment]::GetFolderPath('Programs')).TrimEnd('\')
    $usesPrograms = @($Paths | Where-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) {
            $path = [IO.Path]::GetFullPath($_).TrimEnd('\')
            [string]::Equals($path, $programs, [StringComparison]::OrdinalIgnoreCase) -or
                $path.StartsWith($programs + '\', [StringComparison]::OrdinalIgnoreCase)
        }
    }).Count -gt 0
    if (-not $usesPrograms) { return [pscustomobject]@{ handled = $false } }
    $previousFailure = Get-Variable -Name StableShortcutBrokerFailure -Scope Script -ErrorAction SilentlyContinue
    if ($previousFailure -and $previousFailure.Value) { throw $previousFailure.Value }

    # Package identity APIs can report NO_PACKAGE while descendants still have
    # redirected file writes. Use the interactive shell for actual user shell
    # folders, including the first install before a redirected copy exists.
    try {
        . (Join-Path $PSScriptRoot 'UnvirtualizedShortcuts.ps1')
        # A read-only preflight can stay local when the canonical entry and
        # every visible requested shortcut resolve outside the private cache.
        # Writes and missing/redirected entries still require the shell broker.
        if ($Operation -eq 'TestEntryPoints' -and $Arguments.RequiredStartMenuPath) {
            $canonical = Join-Path $Arguments.RequiredStartMenuPath 'ChatGPT Remote Enabler.lnk'
            if (Test-Path -LiteralPath $canonical -PathType Leaf) {
                try {
                    $probePaths = @(@($Arguments.ShortcutPaths) + @($canonical) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)
                    $redirected = @($probePaths | ForEach-Object { Get-UnvirtualizedShortcutPathIdentity -Path $_ } | Where-Object RedirectedToPackageCache)
                    if ($redirected.Count -eq 0) { return [pscustomobject]@{ handled = $false } }
                } catch { } # A failed native probe must use the verified worker.
            }
        }
        if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot 'StableInstall.ps1' }
        $result = Invoke-UnvirtualizedShortcutWorker -Operation $Operation -ScriptPath $ScriptPath -Arguments $Arguments -ProbePaths @($programs) -TimeoutMilliseconds 60000
        return [pscustomobject]@{ handled = $true; output = @($result.Output) }
    } catch {
        # Avoid repeating a full timeout across recovery and cleanup in one run.
        $script:StableShortcutBrokerFailure = $_.Exception.Message
        throw
    }
}

# Read-only launch preflight. Lifecycle ownership remains in the controller.
function Get-StartupChatGPTMainProcesses {
    param(
        [scriptblock]$ProcessEnumerator = { Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction Stop },
        [scriptblock]$PackageEnumerator = { Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop },
        [string]$PrivateRuntimeRoot = (Join-Path $env:LOCALAPPDATA 'ChatGPTRemoteEnabler\patched-chatgpt')
    )
    $mainProcesses = @(& $ProcessEnumerator | Where-Object {
        [string]$_.CommandLine -notmatch '(?:^|\s)--type=' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath)
    })
    if ($mainProcesses.Count -eq 0) { return @() }
    $packagePaths = @(& $PackageEnumerator | Where-Object { $_.InstallLocation } | ForEach-Object {
        [IO.Path]::GetFullPath((Join-Path $_.InstallLocation 'app\ChatGPT.exe'))
    })
    $privatePrefix = [IO.Path]::GetFullPath($PrivateRuntimeRoot).TrimEnd('\') + '\'
    @($mainProcesses | Where-Object {
        $path = [IO.Path]::GetFullPath([string]$_.ExecutablePath)
        $path -in $packagePaths -or
            ($path.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase) -and
             [IO.Path]::GetFileName($path) -ieq 'ChatGPT.exe')
    })
}

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
        [switch]$RequireManifest,
        [switch]$RequireExactInventory
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
            $allowedMetadata = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($relative in @('RELEASE-MANIFEST.sha256')) {
                [void]$allowedMetadata.Add($relative)
            }
            foreach ($item in Get-ChildItem -LiteralPath $Root -Force -Recurse -ErrorAction Stop) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
                if ($item.PSIsContainer) { continue }
                $relative = $item.FullName.Substring($Root.Length + 1)
                $normalized = $relative.Replace('/', '\')
                $runtimeMetadata = -not $RequireExactInventory -and $normalized -match '^CodexRemoteMobileProject\\rollback\\(?:startup-task-[^\\]+-\d{8}-\d{6}\.xml|(?:desktop|startmenu|legacydesktop|legacystartmenu|legacystartmenuproxytest|legacystartmenuproxy)-shortcut-[^\\]+-\d{8}-\d{6}-\d{3}\.lnk|(?:startup-shortcut|legacy-startup-shortcut)-[^\\]+-\d{8}-\d{6}-\d{3}\.lnk|legacy-disabled-startup-shortcut-[^\\]+-\d{8}-\d{6}-\d{3}\.(?:lnk|disabled))$'
                if (-not $manifestPaths.Contains($relative) -and -not $allowedMetadata.Contains($relative) -and -not $runtimeMetadata) { return $false }
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
    $manifestPath = Join-Path $SourceRoot 'RELEASE-MANIFEST.sha256'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $manifestPath -ErrorAction Stop) {
            if ($line -notmatch '^[0-9a-fA-F]{64} \*(.+)$') { throw "Malformed release manifest line: $line" }
            $relative = $matches[1].Replace('/', [IO.Path]::DirectorySeparatorChar)
            $source = Join-Path $SourceRoot $relative
            $destination = Join-Path $DestinationRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $DestinationRoot 'RELEASE-MANIFEST.sha256') -Force
        return
    }
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
    # Installed and legacy roots may contain runtime rollback metadata. Validate
    # their signed files here; every copied payload is checked for an exact
    # inventory in the isolated staging directory before it can be activated.
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
        if (Test-Path -LiteralPath $StableRoot) {
            # Missing helper files must not prevent a packaged setup repair.
            # Read VERSION independently so damage cannot bypass downgrade
            # protection; an unknown version still requires explicit recovery.
            $stableVersion = ConvertTo-StableSemanticVersion (Get-StableVersion -Root $StableRoot)
            if ($sourceVersion -le $stableVersion -and $stableValid) { return $StableRoot }
            if ($sourceVersion -lt $stableVersion) { throw "A package at $((Get-StableVersion -Root $SourceRoot)) cannot repair or replace newer stable installation $((Get-StableVersion -Root $StableRoot))." }
        }

        if (Test-Path -LiteralPath $StableRoot) {
            if (-not $sourceIsPackaged) { throw 'Updating an existing stable installation requires a packaged source with RELEASE-MANIFEST.sha256.' }
            Assert-StableNoReparsePath -Path $StableRoot -StopAt ([IO.Path]::GetPathRoot($StableRoot))
            if (-not $stableBasicValid -and -not (Test-Path -LiteralPath (Join-Path $StableRoot 'RELEASE-MANIFEST.sha256') -PathType Leaf)) {
                throw 'The incomplete stable installation has no release manifest; refusing to overwrite an unrecognized directory.'
            }
            if (-not $nodePath) { $nodePath = Resolve-StableTransactionNode }
            $safeVersion = (Get-StableVersion -Root $SourceRoot) -replace '[^A-Za-z0-9._-]', '_'
            $preparedParent = Join-Path $UpdaterStateRoot 'prepared'
            $temporary = Join-Path $preparedParent ("setup-$safeVersion-" + [guid]::NewGuid().ToString('N'))
            $backup = Join-Path (Join-Path $UpdaterStateRoot 'rollback') ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$safeVersion-setup")
            try {
                New-Item -ItemType Directory -Path $temporary -Force | Out-Null
                Copy-StablePackageContents -SourceRoot $SourceRoot -DestinationRoot $temporary
                if (-not (Test-StablePackage -Root $temporary -RequireManifest -RequireExactInventory)) { throw 'The staged stable update failed verification.' }
                $retainedArchive = Join-Path $temporary '.chatgpt-remote-release.zip'
                Copy-Item -LiteralPath (Join-Path $temporary 'RELEASE-MANIFEST.sha256') -Destination $retainedArchive -Force
                $archiveHash = (Get-FileHash -LiteralPath $retainedArchive -Algorithm SHA256).Hash.ToLowerInvariant()
                $helper = Join-Path $temporary 'update-transaction.js'
                [void](Invoke-StableTransactionHelper -NodePath $nodePath -HelperPath $helper -Operation 'seal-prepared' -Arguments @('--prepared-root', $temporary, '--platform', 'Windows-x64', '--version', (Get-StableVersion -Root $SourceRoot), '--archive-sha256', $archiveHash))
                [void](Invoke-StableTransactionHelper -NodePath $nodePath -HelperPath $helper -Operation 'apply' -Arguments @('--install-root', $StableRoot, '--prepared-root', $temporary, '--journal-path', $journalPath, '--backup-root', $backup, '--platform', 'Windows-x64', '--version', (Get-StableVersion -Root $SourceRoot), '--archive-sha256', $archiveHash))
                if (-not (Test-StablePackage -Root $StableRoot -RequireManifest)) { throw 'The stable update failed post-transaction verification.' }
                [void](Invoke-StableRollbackRetention -UpdaterStateRoot $UpdaterStateRoot -RollbackRetainCount 1 -LegacyRecoveryRetainCount 0)
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
            if (-not (Test-StablePackage -Root $temporary -RequireManifest:$sourceIsPackaged -RequireExactInventory:$sourceIsPackaged)) { throw 'The migrated stable installation failed post-copy validation.' }
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
        (Join-Path $localData 'CodexRemoteFeatures\releases'),
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
    param(
        [string[]]$ShortcutPaths = @(),
        [string[]]$TaskNames = @(),
        [string]$DesktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
        [string]$StartMenuPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs),
        [string]$StartupPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    )
    $desktop = $DesktopPath
    $startMenu = $StartMenuPath
    $startup = $StartupPath
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
    param(
        [Parameter(Mandatory)][string]$StableRoot,
        [string[]]$ShortcutPaths = @(),
        [string[]]$TaskNames = @(),
        [string]$StartupPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup),
        [string]$RequiredStartMenuPath
    )
    try {
        $broker = Invoke-StableShortcutBroker -Operation TestEntryPoints -Arguments @{
            StableRoot = $StableRoot; ShortcutPaths = $ShortcutPaths; TaskNames = $TaskNames
            StartupPath = $StartupPath; RequiredStartMenuPath = $RequiredStartMenuPath
        } -Paths @($ShortcutPaths + @($RequiredStartMenuPath))
        if ($broker.handled) {
            if (@($broker.output).Count -ne 1 -or $broker.output[0] -isnot [bool]) { return $false }
            return [bool]$broker.output[0]
        }
        if ($RequiredStartMenuPath -and -not (Test-Path -LiteralPath (Join-Path $RequiredStartMenuPath 'ChatGPT Remote Enabler.lnk') -PathType Leaf)) { return $false }
        $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
        $resolvedStartupPath = if ([string]::IsNullOrWhiteSpace($StartupPath)) { $null } else { [IO.Path]::GetFullPath($StartupPath).TrimEnd('\') }
        $rootLauncher = Join-Path $StableRoot 'ChatGPT Remote Enabler.exe'
        $customLauncher = Join-Path $StableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        $ownedStartupShortcutCount = 0
        $enabledStartupTaskCount = 0
        $manualShortcutRecords = [Collections.Generic.List[object]]::new()
        foreach ($shortcutPath in @($ShortcutPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique)) {
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
            $name = [IO.Path]::GetFileName($shortcutPath)
            $shortcutParent = [IO.Path]::GetFullPath((Split-Path -Parent $shortcutPath)).TrimEnd('\')
            $startup = ($resolvedStartupPath -and [string]::Equals($shortcutParent, $resolvedStartupPath, [StringComparison]::OrdinalIgnoreCase)) -or
                $shortcutParent.EndsWith('\Startup', [StringComparison]::OrdinalIgnoreCase) -or $name -match '(?i)Startup'
            $owned = Test-StableOwnedLauncherPath -TargetPath ([string]$shortcut.TargetPath) -StableRoot $StableRoot
            # Same-named shortcuts owned by another application or user are
            # outside this migration. They must not block cleanup unless their
            # target still references the legacy root (checked separately by
            # Test-StableExternalReferences).
            if (-not $owned) {
                if (-not $startup -and $name -ieq 'ChatGPT Remote Enabler.lnk') {
                    $manualShortcutRecords.Add([pscustomobject]@{ parent = $shortcutParent; name = $name; owned = $false; proxyMode = $false })
                }
                continue
            }
            $expectedTarget = if ($startup -or $name -match '(?i)^ChatGPT Custom') { $customLauncher } else { $rootLauncher }
            $target = [IO.Path]::GetFullPath([string]$shortcut.TargetPath)
            $workingDirectory = [IO.Path]::GetFullPath([string]$shortcut.WorkingDirectory).TrimEnd('\')
            if (-not [string]::Equals($target, $expectedTarget, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals($workingDirectory, $StableRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $expectedTarget -PathType Leaf)) { return $false }
            $arguments = ([string]$shortcut.Arguments).Trim()
            if ($startup) {
                if ($arguments -notin @('--startup', '--proxy --startup')) { return $false }
                $ownedStartupShortcutCount++
            } else {
                if ($arguments -notin @('', '--proxy')) { return $false }
                if ($name -in @('ChatGPT Remote Enabler.lnk', 'ChatGPT Custom.lnk', 'ChatGPT Custom (Proxy Test).lnk', 'ChatGPT Custom (Proxy).lnk')) {
                    $manualShortcutRecords.Add([pscustomobject]@{ parent = $shortcutParent; name = $name; owned = $true; proxyMode = $arguments -eq '--proxy' })
                }
            }
            $icon = ([string]$shortcut.IconLocation).Split(',')[0].Trim('"')
            if ($icon -and -not [string]::Equals([IO.Path]::GetFullPath($icon), $expectedTarget, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        foreach ($folder in @($manualShortcutRecords | Group-Object parent)) {
            $canonical = @($folder.Group | Where-Object { $_.owned -and $_.name -ieq 'ChatGPT Remote Enabler.lnk' })
            $foreignCanonical = @($folder.Group | Where-Object { -not $_.owned -and $_.name -ieq 'ChatGPT Remote Enabler.lnk' })
            $ownedAliases = @($folder.Group | Where-Object { $_.owned -and $_.name -ine 'ChatGPT Remote Enabler.lnk' })
            # A foreign canonical entry makes this folder intentionally
            # immutable. Otherwise the canonical entry must exist, same-mode
            # aliases must be gone, and at most one opposite-mode alias may
            # remain for the user's direct/proxy choice.
            if ($foreignCanonical.Count -gt 0) { continue }
            if ($ownedAliases.Count -gt 0 -and $canonical.Count -ne 1) { return $false }
            if ($canonical.Count -eq 1) {
                if (@($ownedAliases | Where-Object { [bool]$_.proxyMode -eq [bool]$canonical[0].proxyMode }).Count -gt 0) { return $false }
                if (@($ownedAliases | Where-Object { [bool]$_.proxyMode -ne [bool]$canonical[0].proxyMode }).Count -gt 1) { return $false }
            }
        }
        foreach ($taskName in @($TaskNames | Where-Object { $_ })) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $task) { continue }
            $actions = @($task.Actions)
            if ($actions.Count -ne 1) { return $false }
            $action = $actions[0]
            $actionExecute = [string]$action.Execute
            if ([string]::IsNullOrWhiteSpace($actionExecute)) { $actionExecute = [string]$action.Path }
            $recognized = [string]$action.Arguments -match '(?i)(?:MobileProjectStartup\.ps1|Enable-ChatGPTRemote\.ps1)' -or
                [string]::Equals($actionExecute, $customLauncher, [StringComparison]::OrdinalIgnoreCase)
            if (-not $recognized) { continue }
            if (-not [string]::Equals([IO.Path]::GetFullPath([string]$action.Execute), $customLauncher, [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\'), (Join-Path $StableRoot 'CodexRemoteMobileProject'), [StringComparison]::OrdinalIgnoreCase) -or
                ([string]$action.Arguments).Trim() -notin @('--startup', '--proxy --startup') -or
                -not (Test-Path -LiteralPath $customLauncher -PathType Leaf)) { return $false }
            $taskEnabled = $true
            if ($task.PSObject.Properties['Settings'] -and $task.Settings -and $task.Settings.PSObject.Properties['Enabled']) {
                $taskEnabled = [bool]$task.Settings.Enabled
            } elseif ($task.PSObject.Properties['State']) {
                $taskEnabled = [string]$task.State -ne 'Disabled'
            }
            if ($taskEnabled) { $enabledStartupTaskCount++ }
        }
        # A canonical task is not enough when an owned Startup shortcut still
        # launches the same app at sign-in. The fast migration may skip only
        # after at most one enabled owned startup entry remains.
        if (($ownedStartupShortcutCount + $enabledStartupTaskCount) -gt 1) { return $false }
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

function Test-StableTrustedLauncherRoot {
    param([Parameter(Mandatory)][string]$Root)
    try {
        $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $leaf = [IO.Path]::GetFileName($resolved)
        if ($leaf -notmatch '^(?:ChatGPT-Remote-Enabler-Windows-x64|ChatGPTRemoteEnabler)(?:[-_]?v\d+\.\d+\.\d+)?$') {
            return $false
        }
        $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        if ([string]::IsNullOrWhiteSpace($commonData)) { $commonData = $env:ProgramData }
        $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localData)) { $localData = $env:LOCALAPPDATA }
        # Keep this parent set aligned with Get-StableLegacyRoots. A missing
        # executable can only prove ownership through an exact historical
        # parent and an approved package leaf; prefix or sibling matches are
        # deliberately rejected.
        $knownParents = @(
            (Join-Path $commonData 'CodexRemoteFeatures\releases'),
            (Join-Path $commonData 'CodexRemoteFeatures'),
            $commonData,
            (Join-Path $localData 'CodexRemoteFeatures'),
            (Join-Path $localData 'CodexRemoteFeatures\releases'),
            (Join-Path $localData 'Programs')
        ) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
        foreach ($parent in $knownParents) {
            $candidate = [IO.Path]::GetFullPath((Join-Path $parent $leaf)).TrimEnd('\')
            if ([string]::Equals($resolved, $candidate, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    } catch {
        return $false
    }
}

function Test-StableOwnedLauncherPath {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$StableRoot
    )
    try {
        if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $false }
        $resolvedTarget = [IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
        $leaf = [IO.Path]::GetFileName($resolvedTarget)
        if ($leaf -notin @('ChatGPT Remote Enabler.exe', 'ChatGPT Custom.exe')) { return $false }
        $candidateRoot = if ($leaf -eq 'ChatGPT Custom.exe') {
            Split-Path -Parent (Split-Path -Parent $resolvedTarget)
        } else {
            Split-Path -Parent $resolvedTarget
        }
        $candidateRoot = [IO.Path]::GetFullPath($candidateRoot).TrimEnd('\')
        $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
        $expectedTarget = if ($leaf -eq 'ChatGPT Custom.exe') {
            Join-Path $candidateRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        } else {
            Join-Path $candidateRoot 'ChatGPT Remote Enabler.exe'
        }
        if (-not [string]::Equals($resolvedTarget, [IO.Path]::GetFullPath($expectedTarget).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        if ([string]::Equals($candidateRoot, $StableRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        # A dangling launcher from a retired release is still an owned entry
        # only when its exact executable path is beneath a trusted
        # CodexRemoteFeatures install/release root. Do not infer ownership from
        # a description, an arbitrary same-name executable, or a user folder.
        if (-not (Test-Path -LiteralPath $resolvedTarget -PathType Leaf)) {
            return Test-StableTrustedLauncherRoot -Root $candidateRoot
        }
        # A package extracted into a user folder may not use one of the
        # historical versioned directory names. Its complete package identity
        # still proves that this is an owned Remote Enabler launcher, while an
        # arbitrary user file named ChatGPT Custom.exe does not pass this gate.
        return Test-StableLegacyPackageIdentity -Root $candidateRoot
    } catch {
        return $false
    }
}

function Get-StableShortcutRecord {
    param(
        [Parameter(Mandatory)][object]$Shell,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StableRoot
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $shortcut = $Shell.CreateShortcut($Path)
        return [pscustomobject][ordered]@{
            path = $Path
            targetPath = [string]$shortcut.TargetPath
            arguments = [string]$shortcut.Arguments
            workingDirectory = [string]$shortcut.WorkingDirectory
            iconLocation = [string]$shortcut.IconLocation
            owned = Test-StableOwnedLauncherPath -TargetPath ([string]$shortcut.TargetPath) -StableRoot $StableRoot
            proxyMode = ([string]$shortcut.Arguments) -match '(?:^|\s)--proxy(?:\s|$)'
        }
    } catch {
        return [pscustomobject][ordered]@{
            path = $Path
            targetPath = $null
            arguments = $null
            workingDirectory = $null
            iconLocation = $null
            owned = $false
            proxyMode = $false
        }
    }
}

function Invoke-StableShortcutMigration {
    param(
        [Parameter(Mandatory)][string]$StableRoot,
        [string]$DesktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
        [string]$StartMenuPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs),
        [string]$StartupPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup),
        [switch]$TaskPrimary
    )
    $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
    if (-not [string]::Equals($StableRoot, (Get-StableInstallRoot), [StringComparison]::OrdinalIgnoreCase)) {
        foreach ($folderParameter in @('DesktopPath', 'StartMenuPath', 'StartupPath')) {
            if (-not $PSBoundParameters.ContainsKey($folderParameter)) {
                return @([pscustomobject][ordered]@{ migrated = $false; reason = 'noncanonical-root-requires-explicit-shortcut-folders' })
            }
        }
    }
    $rootLauncher = Join-Path $StableRoot 'ChatGPT Remote Enabler.exe'
    $customLauncher = Join-Path $StableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
    if (-not (Test-Path -LiteralPath $rootLauncher -PathType Leaf) -or -not (Test-Path -LiteralPath $customLauncher -PathType Leaf)) {
        return @([pscustomobject][ordered]@{ migrated = $false; reason = 'stable-launcher-missing' })
    }
    try {
        $broker = Invoke-StableShortcutBroker -Operation MigrateShortcuts -Arguments @{
            StableRoot = $StableRoot; DesktopPath = $DesktopPath; StartMenuPath = $StartMenuPath
            StartupPath = $StartupPath; TaskPrimary = [bool]$TaskPrimary
        } -Paths @($StartMenuPath, $StartupPath)
    } catch {
        return @([pscustomobject][ordered]@{ migrated = $false; reason = 'shortcut-broker-failed'; error = $_.Exception.Message })
    }
    if ($broker.handled) { return @($broker.output) }
    $results = [Collections.Generic.List[object]]::new()
    try { $shell = New-Object -ComObject WScript.Shell } catch { return @([pscustomobject][ordered]@{ migrated = $false; reason = 'shortcut-shell-unavailable' }) }

    # Manual Desktop and Start-menu aliases are consolidated into one stable,
    # version-independent Remote Enabler entry per folder. A same-named foreign
    # shortcut is never overwritten or removed.
    foreach ($folder in @(
        [pscustomobject]@{
            canonical = Join-Path $DesktopPath 'ChatGPT Remote Enabler.lnk'
            aliases = @((Join-Path $DesktopPath 'ChatGPT Custom.lnk'))
        },
        [pscustomobject]@{
            canonical = Join-Path $StartMenuPath 'ChatGPT Remote Enabler.lnk'
            aliases = @(
                (Join-Path $StartMenuPath 'ChatGPT Custom.lnk'),
                (Join-Path $StartMenuPath 'ChatGPT Custom (Proxy Test).lnk'),
                (Join-Path $StartMenuPath 'ChatGPT Custom (Proxy).lnk')
            )
        }
    )) {
        $canonicalRecord = Get-StableShortcutRecord -Shell $shell -Path $folder.canonical -StableRoot $StableRoot
        $ownedAliases = @($folder.aliases | ForEach-Object {
            $record = Get-StableShortcutRecord -Shell $shell -Path $_ -StableRoot $StableRoot
            if ($record -and $record.owned) { $record }
        })
        if ($canonicalRecord -and -not $canonicalRecord.owned) {
            $results.Add([pscustomobject][ordered]@{ path = $folder.canonical; migrated = $false; reason = 'foreign-canonical-shortcut-retained' })
            # The foreign canonical entry owns its name and remains byte-for-byte
            # untouched. Retain every owned compatibility alias, but detach it
            # from retired installs by updating only the launch fields required
            # for the stable custom launcher.
            foreach ($alias in $ownedAliases) {
                try {
                    $shortcut = $shell.CreateShortcut($alias.path)
                    $shortcut.TargetPath = $customLauncher
                    $shortcut.Arguments = if ($alias.proxyMode) { '--proxy' } else { '' }
                    $shortcut.WorkingDirectory = $StableRoot
                    $shortcut.IconLocation = "$customLauncher,0"
                    $shortcut.Save()
                    $written = Get-StableShortcutRecord -Shell $shell -Path $alias.path -StableRoot $StableRoot
                    if (-not $written -or -not $written.owned -or
                        -not [string]::Equals([IO.Path]::GetFullPath($written.targetPath), [IO.Path]::GetFullPath($customLauncher), [StringComparison]::OrdinalIgnoreCase) -or
                        [string]$written.arguments -cne $(if ($alias.proxyMode) { '--proxy' } else { '' }) -or
                        -not [string]::Equals([IO.Path]::GetFullPath($written.workingDirectory).TrimEnd('\'), $StableRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw 'foreign-canonical alias commit probe failed'
                    }
                    $results.Add([pscustomobject][ordered]@{ path = $alias.path; migrated = $true; retained = $true; reason = 'foreign-canonical-alias-retargeted'; targetPath = $customLauncher; arguments = $written.arguments })
                } catch {
                    $results.Add([pscustomobject][ordered]@{ path = $alias.path; migrated = $false; retained = $true; reason = 'foreign-canonical-alias-retarget-failed' })
                }
            }
            continue
        }
        $missingStartMenu = -not $canonicalRecord -and $ownedAliases.Count -eq 0 -and
            [string]::Equals([IO.Path]::GetDirectoryName($folder.canonical), $StartMenuPath.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
        if (-not $canonicalRecord -and $ownedAliases.Count -eq 0 -and -not $missingStartMenu) { continue }
        # The canonical entry keeps its existing mode. Preserve one legacy
        # alias only when it supplies the other mode; deleting that alias would
        # remove the user's only direct/proxy launch choice. Duplicate aliases
        # in the same mode are safe to consolidate.
        $proxy = if ($canonicalRecord) { [bool]$canonicalRecord.proxyMode } elseif ($ownedAliases.Count) { [bool]$ownedAliases[0].proxyMode } else {
            $desktopRecord = Get-StableShortcutRecord -Shell $shell -Path (Join-Path $DesktopPath 'ChatGPT Remote Enabler.lnk') -StableRoot $StableRoot
            [bool]($desktopRecord -and $desktopRecord.owned -and $desktopRecord.proxyMode)
        }
        $alternateAlias = @($ownedAliases | Where-Object { [bool]$_.proxyMode -ne $proxy } | Select-Object -First 1)
        try {
            if ($missingStartMenu) { New-Item -ItemType Directory -Path $StartMenuPath -Force | Out-Null }
            $shortcut = $shell.CreateShortcut($folder.canonical)
            $shortcut.TargetPath = $rootLauncher
            $shortcut.Arguments = if ($proxy) { '--proxy' } else { '' }
            $shortcut.WorkingDirectory = $StableRoot
            $shortcut.Description = if ($proxy) {
                'Open ChatGPT with Remote Enabler and proxy mode, or attach to a compatible running session.'
            } else {
                'Open ChatGPT with Remote Enabler, or attach to a compatible running session.'
            }
            $shortcut.IconLocation = "$rootLauncher,0"
            $shortcut.WindowStyle = 1
            $shortcut.Save()
            $written = Get-StableShortcutRecord -Shell $shell -Path $folder.canonical -StableRoot $StableRoot
            if (-not $written.owned -or -not [string]::Equals([IO.Path]::GetFullPath($written.targetPath), [IO.Path]::GetFullPath($rootLauncher), [StringComparison]::OrdinalIgnoreCase) -or
                [string]$written.arguments -cne $(if ($proxy) { '--proxy' } else { '' })) {
                throw 'canonical shortcut commit probe failed'
            }
            $results.Add([pscustomobject][ordered]@{ path = $folder.canonical; migrated = $true; targetPath = $rootLauncher; arguments = $written.arguments; consolidated = $true })
            foreach ($alias in $ownedAliases) {
                $keepAlternate = $alternateAlias -and [string]::Equals([string]$alias.path, [string]$alternateAlias.path, [StringComparison]::OrdinalIgnoreCase)
                if ($keepAlternate) {
                    try {
                        $alternate = $shell.CreateShortcut($alias.path)
                        $alternate.TargetPath = $customLauncher
                        $alternate.Arguments = if ($alternateAlias.proxyMode) { '--proxy' } else { '' }
                        $alternate.WorkingDirectory = $StableRoot
                        $alternate.Description = 'ChatGPT Remote Enabler compatibility entry point.'
                        $alternate.IconLocation = "$customLauncher,0"
                        $alternate.WindowStyle = 1
                        $alternate.Save()
                        $results.Add([pscustomobject][ordered]@{ path = $alias.path; migrated = $true; retained = $true; reason = 'alternate-mode-shortcut-retained' })
                    } catch {
                        $results.Add([pscustomobject][ordered]@{ path = $alias.path; migrated = $false; retained = $true; reason = 'alternate-mode-shortcut-migration-failed' })
                    }
                    continue
                }
                try {
                    Remove-Item -LiteralPath $alias.path -Force -ErrorAction Stop
                    $results.Add([pscustomobject][ordered]@{ path = $alias.path; migrated = $true; removed = $true; reason = 'owned-legacy-shortcut-consolidated' })
                } catch {
                    $results.Add([pscustomobject][ordered]@{ path = $alias.path; migrated = $false; removed = $false; reason = 'owned-legacy-shortcut-remove-failed' })
                }
            }
        } catch {
            $results.Add([pscustomobject][ordered]@{ path = $folder.canonical; migrated = $false; reason = 'shortcut-migration-failed' })
        }
    }

    # Sign-in aliases must result in one effective launcher. An enabled,
    # validated logon task is the primary entry; otherwise keep one canonical
    # Startup shortcut. Disabled tasks remain disabled and foreign files remain
    # untouched.
    $startupPaths = @(
        (Join-Path $StartupPath 'ChatGPT Remote Enabler Startup.lnk'),
        (Join-Path $StartupPath 'ChatGPT Custom Startup.lnk'),
        (Join-Path $StartupPath 'ChatGPT Custom.lnk'),
        (Join-Path $StartupPath 'ChatGPT Remote Enabler.lnk')
    )
    $startupRecords = @($startupPaths | ForEach-Object {
        $record = Get-StableShortcutRecord -Shell $shell -Path $_ -StableRoot $StableRoot
        if ($record) { $record }
    })
    foreach ($record in @($startupRecords | Where-Object { -not $_.owned })) {
        $results.Add([pscustomobject][ordered]@{ path = $record.path; migrated = $false; reason = 'foreign-startup-shortcut-retained' })
    }
    $ownedStartup = @($startupRecords | Where-Object owned)
    if ($ownedStartup.Count -gt 0) {
        if ($TaskPrimary) {
            foreach ($record in $ownedStartup) {
                try {
                    Remove-Item -LiteralPath $record.path -Force -ErrorAction Stop
                    $results.Add([pscustomobject][ordered]@{ path = $record.path; migrated = $true; removed = $true; reason = 'startup-task-primary' })
                } catch {
                    $results.Add([pscustomobject][ordered]@{ path = $record.path; migrated = $false; removed = $false; reason = 'startup-shortcut-remove-failed' })
                }
            }
        } else {
            $canonicalPath = $startupPaths[0]
            $canonicalRecord = @($ownedStartup | Where-Object { [string]::Equals([string]$_.path, $canonicalPath, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
            $canonicalForeign = @($startupRecords | Where-Object {
                [string]::Equals([string]$_.path, $canonicalPath, [StringComparison]::OrdinalIgnoreCase) -and -not $_.owned
            }).Count -gt 0
            $survivorPath = if ($canonicalForeign) { [string]$ownedStartup[0].path } else { $canonicalPath }
            # Any active owned startup alias using proxy protects that mode
            # during consolidation, even when the canonical alias was direct.
            $proxy = @($ownedStartup | Where-Object proxyMode).Count -gt 0
            $survivorCommitted = $false
            try {
                $shortcut = $shell.CreateShortcut($survivorPath)
                $shortcut.TargetPath = $customLauncher
                $shortcut.Arguments = if ($proxy) { '--proxy --startup' } else { '--startup' }
                $shortcut.WorkingDirectory = $StableRoot
                $shortcut.Description = if ($proxy) {
                    'Start ChatGPT/Codex with the capability-tested injection and Remote-control proxy after sign-in.'
                } else {
                    'Start ChatGPT/Codex with the capability-tested injection after sign-in.'
                }
                $shortcut.IconLocation = "$customLauncher,0"
                $shortcut.WindowStyle = 1
                $shortcut.Save()
                $written = Get-StableShortcutRecord -Shell $shell -Path $survivorPath -StableRoot $StableRoot
                $expectedArguments = if ($proxy) { '--proxy --startup' } else { '--startup' }
                if (-not $written -or -not $written.owned -or
                    -not [string]::Equals([IO.Path]::GetFullPath([string]$written.targetPath), [IO.Path]::GetFullPath($customLauncher), [StringComparison]::OrdinalIgnoreCase) -or
                    ([string]$written.arguments).Trim() -cne $expectedArguments -or
                    -not [string]::Equals([IO.Path]::GetFullPath([string]$written.workingDirectory).TrimEnd('\'), [IO.Path]::GetFullPath($StableRoot), [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'canonical startup shortcut commit probe failed'
                }
                $survivorCommitted = $true
                $results.Add([pscustomobject][ordered]@{ path = $survivorPath; migrated = $true; targetPath = $customLauncher; arguments = $shortcut.Arguments; startup = $true; consolidated = $true })
            } catch {
                $results.Add([pscustomobject][ordered]@{ path = $survivorPath; migrated = $false; reason = 'shortcut-migration-failed' })
            }
            if (-not $survivorCommitted) { return @($results) }
            foreach ($record in $ownedStartup) {
                if ([string]::Equals([string]$record.path, $survivorPath, [StringComparison]::OrdinalIgnoreCase)) { continue }
                try {
                    Remove-Item -LiteralPath $record.path -Force -ErrorAction Stop
                    $results.Add([pscustomobject][ordered]@{ path = $record.path; migrated = $true; removed = $true; reason = 'owned-startup-shortcut-consolidated' })
                } catch {
                    $results.Add([pscustomobject][ordered]@{ path = $record.path; migrated = $false; removed = $false; reason = 'startup-shortcut-remove-failed' })
                }
            }
        }
    }
    return @($results)
}

function Invoke-StableTaskMigration {
    param(
        [Parameter(Mandatory)][string]$StableRoot,
        [string[]]$StartupShortcutPaths = @()
    )
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
        $startupLauncher = Join-Path $StableRoot 'CodexRemoteMobileProject\ChatGPT Custom.exe'
        if (-not (Test-Path -LiteralPath $startupLauncher -PathType Leaf)) { throw 'The windowless startup launcher is missing.' }
        $startupProxy = $false
        if ($StartupShortcutPaths.Count -gt 0) {
            try {
                $shortcutShell = New-Object -ComObject WScript.Shell
                foreach ($startupPath in $StartupShortcutPaths) {
                    $startupRecord = Get-StableShortcutRecord -Shell $shortcutShell -Path $startupPath -StableRoot $StableRoot
                    if ($startupRecord -and $startupRecord.owned -and $startupRecord.proxyMode) { $startupProxy = $true }
                }
            } catch { $startupProxy = $false }
        }
        $taskProxy = $false
        $matchedAction = $false
        foreach ($action in @($definition.Actions)) {
            if ([string]$action.Arguments -match '(?i)(?:MobileProjectStartup\.ps1|Enable-ChatGPTRemote\.ps1)' -or
                [string]::Equals([string]$action.Path, $startupLauncher, [StringComparison]::OrdinalIgnoreCase)) {
                $matchedAction = $true
                $proxy = $startupProxy -or ([string]$action.Arguments -match '(?:^|\s)-UseProxy(?:\s|$)|(?:^|\s)--proxy(?:\s|$)')
                $taskProxy = $proxy
                $action.Path = $startupLauncher
                $action.Arguments = if ($proxy) { '--proxy --startup' } else { '--startup' }
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
        $registeredActions = @($registered.Actions)
        if ($registeredActions.Count -ne 1) { throw 'The migrated logon task does not have exactly one canonical action.' }
        $registeredAction = $registeredActions[0]
        $registeredExecute = [string]$registeredAction.Path
        if ([string]::IsNullOrWhiteSpace($registeredExecute)) { $registeredExecute = [string]$registeredAction.Execute }
        $expectedTaskArguments = if ($taskProxy) { '--proxy --startup' } else { '--startup' }
        if (-not [string]::Equals([IO.Path]::GetFullPath($registeredExecute), [IO.Path]::GetFullPath($startupLauncher), [StringComparison]::OrdinalIgnoreCase) -or
            ([string]$registeredAction.Arguments).Trim() -cne $expectedTaskArguments -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$registeredAction.WorkingDirectory).TrimEnd('\'), (Join-Path $StableRoot 'CodexRemoteMobileProject'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The logon task read-back did not match the canonical windowless launcher action.'
        }
        $results.Add([pscustomobject][ordered]@{ taskName = [string]$task.TaskName; migrated = $true; valid = $true; enabled = $beforeEnabled; proxyMode = $taskProxy })
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

function Invoke-StableEntryPointMigration {
    param(
        [Parameter(Mandatory)][string]$StableRoot,
        [string]$DesktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
        [string]$StartMenuPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs),
        [string]$StartupPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    )
    $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
    $canonicalStableRoot = Get-StableInstallRoot
    $isCanonicalStableRoot = [string]::Equals($StableRoot, $canonicalStableRoot, [StringComparison]::OrdinalIgnoreCase)
    if (-not $isCanonicalStableRoot) {
        foreach ($folderParameter in @('DesktopPath', 'StartMenuPath', 'StartupPath')) {
            if (-not $PSBoundParameters.ContainsKey($folderParameter)) {
                return [pscustomobject][ordered]@{ migrated = $false; valid = $false; reason = 'noncanonical-root-requires-explicit-shortcut-folders'; taskPrimary = $false; tasks = @(); shortcuts = @() }
            }
        }
    }

    $known = Get-StableKnownEntryPoints -DesktopPath $DesktopPath -StartMenuPath $StartMenuPath -StartupPath $StartupPath
    if (Test-StableEntryPointsMigrated -StableRoot $StableRoot -ShortcutPaths $known.ShortcutPaths -TaskNames $known.TaskNames -StartupPath $StartupPath -RequiredStartMenuPath $StartMenuPath) {
        return [pscustomobject][ordered]@{ migrated = $false; valid = $true; reason = 'already-migrated'; taskPrimary = $false; tasks = @(); shortcuts = @() }
    }

    $startupPaths = @($known.ShortcutPaths | Where-Object {
        $_ -and [string]::Equals(
            [IO.Path]::GetFullPath((Split-Path -Parent $_)).TrimEnd('\'),
            [IO.Path]::GetFullPath($StartupPath).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase)
    })
    # The task must commit first so an enabled canonical task can become the
    # sole startup entry before owned Startup-folder duplicates are removed.
    $taskMigrations = @(Invoke-StableTaskMigration -StableRoot $StableRoot -StartupShortcutPaths $startupPaths)
    $taskPrimary = @($taskMigrations | Where-Object { $_.migrated -and $_.valid -and $_.enabled }).Count -eq 1
    $shortcutMigrations = @(Invoke-StableShortcutMigration -StableRoot $StableRoot -DesktopPath $DesktopPath -StartMenuPath $StartMenuPath -StartupPath $StartupPath -TaskPrimary:$taskPrimary)
    $valid = Test-StableEntryPointsMigrated -StableRoot $StableRoot -ShortcutPaths $known.ShortcutPaths -TaskNames $known.TaskNames -StartupPath $StartupPath -RequiredStartMenuPath $StartMenuPath
    return [pscustomobject][ordered]@{
        migrated = @($taskMigrations + $shortcutMigrations | Where-Object migrated).Count -gt 0
        valid = [bool]$valid
        reason = $(if ($valid) { 'migration-complete' } else { 'migration-incomplete' })
        taskPrimary = [bool]$taskPrimary
        tasks = $taskMigrations
        shortcuts = $shortcutMigrations
    }
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
        [string[]]$ApprovedLegacyParents = @(),
        [string]$DesktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
        [string]$StartMenuPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs),
        [string]$StartupPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
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
        $known = Get-StableKnownEntryPoints -ShortcutPaths $ShortcutPaths -TaskNames $TaskNames -DesktopPath $DesktopPath -StartMenuPath $StartMenuPath -StartupPath $StartupPath
        $startupPaths = @($known.ShortcutPaths | Where-Object {
            $_ -and ((Split-Path -Parent $_).EndsWith('\Startup', [StringComparison]::OrdinalIgnoreCase) -or
                ([IO.Path]::GetFileName($_) -match '(?i)Startup'))
        })
        $taskMigrations = @(Invoke-StableTaskMigration -StableRoot $StableRoot -StartupShortcutPaths $startupPaths)
        $taskPrimary = @($taskMigrations | Where-Object { $_.migrated -and $_.valid -and $_.enabled }).Count -gt 0
        [void](Invoke-StableShortcutMigration -StableRoot $StableRoot -DesktopPath $DesktopPath -StartMenuPath $StartMenuPath -StartupPath $StartupPath -TaskPrimary:$taskPrimary)
        $ShortcutPaths = $known.ShortcutPaths
        $TaskNames = $known.TaskNames
    }
    $requiredStartMenu = if ($isCanonicalStableRoot -or $PSBoundParameters.ContainsKey('StartMenuPath')) { $StartMenuPath } else { $null }
    $entryPointsMigrated = -not $MigrateEntryPoints -or (Test-StableEntryPointsMigrated -StableRoot $StableRoot -ShortcutPaths $ShortcutPaths -TaskNames $TaskNames -StartupPath $StartupPath -RequiredStartMenuPath $requiredStartMenu)
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
            (Join-Path $localData 'CodexRemoteFeatures\releases'),
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

function Invoke-StableAuxiliaryRollbackCleanup {
    param(
        [Parameter(Mandatory)][string]$StableRoot,
        [Parameter(Mandatory)][string]$UpdaterStateRoot,
        [scriptblock]$ProcessEnumerator
    )
    $StableRoot = [IO.Path]::GetFullPath($StableRoot).TrimEnd('\')
    $UpdaterStateRoot = [IO.Path]::GetFullPath($UpdaterStateRoot).TrimEnd('\')
    $stateParent = [IO.Path]::GetFullPath((Split-Path -Parent $UpdaterStateRoot)).TrimEnd('\')
    $results = [Collections.Generic.List[object]]::new()
    foreach ($target in @(
        [pscustomobject]@{ Category = 'stable-root-rollback'; Path = (Join-Path $StableRoot 'rollback'); StopAt = $StableRoot },
        [pscustomobject]@{ Category = 'mobile-project-rollback'; Path = (Join-Path $StableRoot 'CodexRemoteMobileProject\rollback'); StopAt = $StableRoot },
        [pscustomobject]@{ Category = 'shortcut-rollback'; Path = (Join-Path $stateParent 'shortcut-rollback'); StopAt = $stateParent },
        [pscustomobject]@{ Category = 'startup-task-rollback'; Path = (Join-Path $stateParent 'rollback'); StopAt = $stateParent }
    )) {
        if (-not (Test-Path -LiteralPath $target.Path -PathType Container)) { continue }
        $entry = [ordered]@{ category = $target.Category; path = $target.Path; removed = $false; reason = $null }
        try {
            $resolved = [IO.Path]::GetFullPath($target.Path).TrimEnd('\')
            Assert-StableNoReparsePath -Path $resolved -StopAt $target.StopAt
            Assert-StableNoReparseTree -Root $resolved
            foreach ($journal in @((Join-Path $UpdaterStateRoot 'transaction.json'), (Join-Path $UpdaterStateRoot 'git-transaction.json'))) {
                if (Test-StableTextReferencesRoot -Path $journal -Root $resolved) { throw 'auxiliary-rollback-referenced-by-recovery-journal' }
            }
            if (-not (Test-StableNoLiveRootReference -Root $resolved -ProcessEnumerator $ProcessEnumerator)) {
                throw 'auxiliary-rollback-referenced-by-live-process'
            }
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
        [ValidateRange(0, 50)][int]$RollbackRetainCount = 1,
        [ValidateRange(0, 50)][int]$LegacyRecoveryRetainCount = 0,
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
