# Changelog

## v1.5.7

- Keep a currently discovered native Remote runtime online when only its inventory service is retrying, while hosts with no runtime remain explicitly offline.

## v1.5.6

- Fixed stale online dots, reconnect discovery, and remote inventories that could remain pending after a bridge error.
- Fixed remote unread acknowledgements, duplicate/multi-root project grouping, stale automatic registrations, and empty-project startup retries.
- Prevented overlay render loops, duplicate model scans, unbounded empty-runtime scans, and persistent CDP script leaks after failed injection.
- Hardened optional auto-cleanup with a cross-window lease, pinned/selected/working and descendant protection, disable-generation cancellation, complete source-kind pagination, and final state checks before each operation.
- Added bounded updater networking, safer log-cap pruning, macOS duplicate-instance protection, and matching renderer v50 behavior on Windows and macOS.
- Fixed inventory-only task names by reading the app-server v2 `name` field, with a bounded preview fallback for genuinely unnamed chats.
- Rebuilt both Windows launchers as v1.5.6, repaired every-start updater defaults and same-version integrity checks, and blocked unsafe launcher restarts and macOS update redirects/symlink targets.

## v1.5.1

- Stopped Mobile Projects from opening the Native views options menu or changing the user's **By project**/**By connection** preference during background hydration.
- Restored the project-row hover action by invoking the exact native project's **Start new chat** control first, then falling back to the native state dispatcher or the global native composer plus exact project selection when that grouping does not mount project rows.

## v1.5.0

- Added optional, client-local automatic archiving for inactive, unpinned local chats older than seven days. It defaults off and skips selected, working, pinned, and remote chats.
- Fixed remote unread acknowledgements so opening a remote chat clears its blue dot until the owning device reports a later state transition.
- Expire and prune cached peer inventories after three minutes, reject future timestamps, and prevent stale data from driving project reconciliation.
- Expand bounded native **Show more** pages so older chats can enter Mobile Projects and status publication.
- Publish/read active task state every five seconds while needed, with a 60-second idle heartbeat and cached remote Codex-home discovery to reduce steady-state I/O.
- Clear reconciliation/archive/hydration timers and guard retired async work during renderer reinjection.
- Accept flat or rooted update archives and both common SHA-256 checksum formats, clean manifest-removed files with rollback, and add a deterministic local release builder. No GitHub Actions or CI/CD was added.

## v1.4.4

- Fixed missing remote working and completed-but-unread indicators in Mobile Projects. Each injected device now publishes only its active task states in its existing short-lived peer inventory, and connected clients refresh those states every five seconds without central storage.

## v1.4.3

- Create only the primary **ChatGPT Custom** Desktop and Start-menu shortcuts. `-UseProxy` now configures those shortcuts in place, while direct installs recoverably remove obsolete separate proxy entries.

## v1.4.2

- Added `DesktopShortcut.ps1 -UseProxy` to consolidate Desktop and Start menu launchers into one proxy-enabled **ChatGPT Custom** entry and recoverably remove the separate proxy shortcut.
- Fixed renderer v42 project mirroring so publication, inventory refresh, registration, and reconciliation continue automatically while Native views is selected.
- Rehydrate native By connection lists on startup, sidebar changes, and every 30 seconds through their existing expansion callbacks. The grouping recovery is mutation-driven, so background timer throttling cannot leave older remote chats hidden.
- Read the controller's complete registered-project state instead of relying on currently rendered React rows, and verify persistence before recording an automatic registration as successful.
- Grouped remote chats into the matching project by host and normalized path before considering the source device's project ID, preventing duplicate empty/occupied project groups.
- Added a Windows opt-in HTTP CONNECT agent scoped to ChatGPT Remote-control WebSockets, with Windows trusted-root support and no disabled TLS checks.
- Added renderer v38 active-project mirroring on Windows and macOS. Each injected host publishes a short-lived local inventory that controllers read through the existing Remote channel, including empty active projects while excluding archived projects and historical trusted paths.
- Added automatic reconciliation, stale-inventory fail-closed behavior, and direct cleanup of automation-created registrations without deleting chats or source folders.
- Added a non-administrator Windows startup-shortcut manager, proxy-capable scheduled startup, legacy-startup cleanup, and complete Windows/macOS injected-startup procedures.
- Added packaged Windows activation with a package-context fallback and ordinary ChatGPT recovery when injection cannot be enabled.

## v1.4.1

- Changed automatic update checks from once per day to every launcher start.
- Retained persistent and per-launch opt-outs, configurable GitHub endpoints, and optional interval throttling.

## v1.4.0

- Added native-backed project and chat drag ordering in Mobile Projects v35.
- Added recoverable Windows and macOS release updaters with automatic daily checks, SHA-256 plus release-manifest verification, and fail-open startup behavior.
- Added persistent and per-launch opt-outs plus configurable GitHub repository, API base, or complete latest-release URL overrides for forks and mirrors.
- Kept update state and rollback copies local to each client; no shared catalogue, central storage, GitHub Actions, or CI/CD was added.

## v1.3.1

- Made fresh Windows launches reliable when current Electron builds initially expose partial Node crypto shims.
- Made the macOS Dock helper follow the extracted release folder instead of an old fixed bundle path.
- Includes every renderer v34, startup, shortcut, project-state, status-indicator, offline-device, empty-project, and modal fix from v1.3.0.

## v1.3.0

- Updated Mobile Projects to renderer v34 on Windows and macOS.
- Preserved the original plain project-folder design while fixing open/closed state.
- Added empty registered projects, working/unread indicators, and local auto-registration controls.
- Fixed offline-device mapping, startup readiness, and the stuck automatic-registration dialog.
- Added current Electron main-process compatibility and clearer sanitized bridge errors.
- Added portable Windows Desktop, Start-menu, and at-logon launch helpers.
- Added a bounded Windows stable-bridge retry and complete Node-module fallback loading for reliable fresh-process startup.
- Kept all registration state client-local; no shared catalogue or central storage was added.

## v1.2.2

- Recreated the public repository and release from a privacy-audited baseline.
