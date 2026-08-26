# Changelog

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
