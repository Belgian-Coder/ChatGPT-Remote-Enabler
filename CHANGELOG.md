# Changelog

## v1.5.20

- Record the renderer version actually proven by the injected runtime instead
  of the obsolete hard-coded v55 session value.
- Give normal renderer probes ten seconds to complete. This prevents a healthy
  busy renderer from being reported as failed during inventory or maintenance
  activity; Windows and macOS use the same proof and timeout contract.

## v1.5.19

- Keep fresh or in-progress direct inventories authoritative over newer peer
  gossip and disk caches. Renderer v58 also removes proven orphan aliases of
  the local runtime, including zero-task raw environment chips, while
  preserving distinct and directly connected devices.
- Bound user-visible task pagination to 200 pages, fail maintenance pagination
  closed at that limit, back off failed remote hydration, and always clear its
  pending state. This prevents changing-cursor responses from holding the UI
  in a multi-thousand-page refresh.
- Make Windows and macOS release replacement recover the current file after a
  failed copy, verify the installed manifest before success, defer check stamps
  until success, and harden macOS cwd, LaunchAgent, and Dock-shortcut swaps.
- Preserve Windows special-session state across versioned installs, require
  durable proof before reusing a proxy/non-proxy session, release the launcher
  mutex before error UI, and check for updates on every start by default.
- Reject maintenance test-path lookalikes and links, and make release builds
  fail on real device labels. Windows/macOS renderer and maintenance sources
  remain byte-identical with focused PowerShell 5.1 and zsh regression tests.

## v1.5.18

- Remove every derived remote-state entry for a transitive inventory only
  after its thread/project fingerprint proves it is a local self-echo. This
  prevents an orphan connectivity record from rendering the local machine as
  a red, zero-task raw environment ID.
- Preserve peers that already have direct connectivity or a live request
  client, plus genuinely distinct same-named devices. Renderer v57 is
  byte-identical on Windows and macOS with transition and cleanup regressions.
- Make packaged Windows release detection quiet under Windows PowerShell 5.1:
  non-Git layouts are rejected before Git runs, while genuine clean checkout
  fast-forward behavior remains unchanged. A packaged Probe/Auto regression
  covers the exact controller capture path.

## v1.5.17

- Publish each device's validated display name with its project and chat
  inventory, and preserve that name when the inventory is relayed through a
  connected peer.
- Use the relayed name for device filters without treating peer gossip as
  proof that the device is online. This replaces raw offline `Remote env_...`
  labels with the correct device name while preserving accurate red/green
  connectivity state. Windows and macOS use renderer v56.

## v1.5.16

- Fix the macOS same-version integrity check so it no longer shadows zsh's
  special `path` parameter and temporarily clears `PATH` while validating an
  installed release.
- Use absolute system tools for the integrity digest pipeline and add a
  regression contract preventing the special-variable collision from
  returning. This stops every-launch update checks from needlessly
  reinstalling an already valid release. The Mobile Projects renderer remains
  v55 on Windows and macOS.

## v1.5.15

- Make the Windows Node.js capability probe safe for Windows PowerShell 5.1 native argument handling, preventing the injected shortcut from failing at `[eval]:1` before proxy loading and injection.
- Add a regression test that executes the exact quote-free capability check through Windows PowerShell 5.1. Windows launchers are version 1.5.15.0; the Mobile Projects renderer remains v55 on Windows and macOS.

## v1.5.14

- Preserve shared User- and Machine-scope proxy environment variables when importing the Windows Remote-control proxy into DPAPI-protected storage.
- Remove the proxy importer's environment-removal option and add a regression contract that rejects future User-scope environment mutation; proxy isolation remains limited to the custom launcher's child process.
- Windows launchers are version 1.5.14.0; the Mobile Projects renderer remains v55 on Windows and macOS.

## v1.5.13

- Store the Windows Remote-control proxy in a per-user DPAPI-protected file and clear inherited proxy variables before starting ChatGPT, so only the injected Remote WebSocket receives the proxy URL.
- Let an explicit **ChatGPT Custom** click replace an ordinary running ChatGPT session, while unattended startup still preserves active sessions; manual launcher failures now show an actionable message instead of disappearing silently.
- Update Git checkouts through a clean `main` fast-forward, check packaged releases once per day by default, and identify Cisco/security-gateway HTML substitutions before checksum processing.
- Add protected-proxy and network-block regression tests. Windows launchers are version 1.5.13.0; the Mobile Projects renderer remains v55 on Windows and macOS.

## v1.5.12

- Stop completed remote chats from retaining a working spinner: direct app-server thread status now outranks remote thread snapshots, and remote thread status outranks DOM-derived task state.
- Publish app-server status instead of stale native DOM status when both describe the same local chat, and expire orphaned remote loading snapshots after 30 seconds. Windows and macOS use renderer v55.

## v1.5.11

- Let every fresh authoritative v53+ peer task list replace the local verified-ID fallback, so a remotely archived conversation disappears on the next inventory refresh instead of lingering as a visible but non-openable row.
- Add a focused regression test proving that an archived remote task is removed even when the seven-day fallback cache still contains its ID. Windows and macOS use renderer v54.

## v1.5.10

- Publish only authoritative native or persisted chat titles with explicit provenance; previews and first-message text can no longer become shared titles.
- Harden user-facing thread filtering across startup, empty results, refresh failures, peer caches, and gossip. Verified ID expiry is enforced continuously, future or pre-v53 caches are rejected, selected internal rows no longer bypass filtering, scoped authority requires a v53 publisher, and its original freshness timestamp survives peer relays.
- Follow the app-server's interactive `cli`/`vscode` source contract while retaining internal sources only for maintenance safety checks. Windows and macOS use renderer v53 with behavioral title and visibility tests.

## v1.5.9

- Prevent internal task rows from flashing during startup, reinjection, and inventory refresh by retaining only verified user-facing thread IDs, refusing unverified non-selected rows, and marking peer inventories with their filtered thread scope.

## v1.5.8

- Filter Mobile Projects inventory to user-facing CLI, VS Code, and desktop chats so internal exec/subagent runs no longer appear as repeated project rows; retain the complete source inventory for maintenance safety, deduplicate paginated results by thread ID, and prefer a connected device's filtered direct task list over legacy cached inventory during staggered upgrades.

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
