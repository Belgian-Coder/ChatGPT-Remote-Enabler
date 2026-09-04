# Changelog

## v1.5.29

- Fix native Windows Remote-control enrollment behind an HTTP(S) proxy by
  preserving the canonical `https://chatgpt.com` API base and redirecting only
  the Remote-control WebSocket through the per-launch localhost CONNECT bridge.
  This removes the enrollment origin mismatch introduced by v1.5.28.
- Generate a version- and hash-matched private copy of the installed ChatGPT
  runtime under the current user's local app data. Only that private copy gets
  the audited WebSocket URL override and Electron ASAR-integrity fuse change;
  the signed WindowsApps package remains untouched. Inactive older private
  runtimes are removed after their processes stop.
- Build the supervising package-context helper as a background Windows
  executable, so proxy-enabled ChatGPT no longer leaves a console window open.
  Child-only inherited proxy variables are cleared without modifying User- or
  Machine-scope environment variables, and any failed launch still restores
  ordinary ChatGPT.

## v1.5.28

> Superseded: do not install this version. Its broad API-base override can make
> native Remote-control enrollment reject an otherwise valid device challenge.

- Route native-key Windows Remote-control API and WebSocket traffic through a
  per-launch localhost bridge when `-UseProxy` is enabled. This fixes repeated
  `Opening handshake has timed out` errors on networks where direct TLS is
  blocked but the configured corporate HTTP(S) proxy is available.
- Scope `CODEX_API_BASE_URL` to the custom ChatGPT child, preserve authorization
  headers and TLS verification, bind the bridge to loopback behind a random
  per-launch path, and stop it with ChatGPT. User- and Machine-scope proxy
  environment variables remain unchanged.
- Add launcher regression coverage for the scoped API base and loopback access
  boundary. Direct launch, ordinary fallback, renderer v62, and macOS behavior
  are unchanged.

## v1.5.27

- Allow the Windows package-context proxy launcher to finish dispatching before
  ChatGPT opens its requested loopback debugging port. Current ChatGPT builds
  detach the full-trust helper from the short-lived PowerShell dispatcher, so
  the dispatcher exit is no longer mistaken for an application launch failure.
- Record the detached ChatGPT process rather than the completed dispatcher in
  runtime state when it can be identified unambiguously. Proxy scoping, normal
  startup fallback, renderer v62, and macOS behavior are unchanged.

## v1.5.26

- Start the hidden Windows PowerShell workers with a clean `PSModulePath` so
  launching **ChatGPT Custom** from PowerShell 7 cannot hide Windows' inbox
  hashing and DPAPI modules. Desktop, Start-menu, and startup-folder launches
  retain the same per-user, non-administrator behavior.
- Extend the real launcher handoff regression to require both `Get-FileHash`
  and `Microsoft.PowerShell.Security` inside the worker. Renderer v62, scoped
  native proxying, and macOS runtime behavior are unchanged.

## v1.5.25

- Restore `-UseProxy` on native-key Windows ChatGPT builds whose Remote-control
  WebSocket moved from Electron networking to Node networking. The packaged
  launcher enables Node's environment-proxy support only in the custom
  ChatGPT child process and keeps loopback traffic direct.
- Preserve the existing User- and Machine-scope proxy environment exactly as
  configured. Legacy builds retain the Remote-WebSocket-only Inspector shim;
  direct startup and ordinary ChatGPT recovery remain unchanged.
- Add a compiled package-context launcher and a regression that proves its
  child receives the four proxy aliases, Node opt-in, and loopback bypass while
  credential-bearing proxy URLs remain rejected. Renderer v62 and macOS
  runtime behavior are unchanged.

## v1.5.24

- Detect newer ChatGPT Windows packages that provide native Windows
  remote-control device keys, and use a renderer-only compatibility bridge
  when Electron disables main-process inspection. Legacy packages retain the
  audited main-process shim.
- Fix the compatibility signature that mistook the new "macOS and Windows"
  capability message for the former macOS-only build and then waited for a
  debugger target that could never exist.
- Persist and discover renderer-only sessions with an explicit bridge mode.
  Direct startup no longer passes `--inspect`; scoped proxy mode fails safely
  on native-key builds because its legacy main-process shim is unavailable.
- Prove that automatic update runs before injection on both Windows launch
  paths and remains installed even if that launch's injection later fails.
  Add native/legacy package, renderer-only probe, and session-discovery
  regressions. Renderer v62 and macOS runtime behavior are unchanged.

## v1.5.23

- Hand Windows launch ownership to a PowerShell worker and exit the launcher
  before the verified updater replaces package files. This removes the
  running-executable `Access is denied` failure without weakening checksum,
  manifest, rollback, or success-only check-stamp validation.
- Hold one cross-entry launch mutex in the worker, wait for the exact launcher
  process to exit, and preserve direct/proxy plus manual/startup arguments.
  Concurrent manual, shortcut, and sign-in launches still resolve to exactly
  one update-and-injection run.
- Cover both Windows launcher entry points with a real locked-executable
  replacement regression under Windows PowerShell 5.1. Renderer v62 and the
  macOS runtime are unchanged.

## v1.5.22

- Quarantine a local app-server request client when a raw `thread/list` call
  outlives its deadline instead of leaving every later hydration queued behind
  an orphaned gate. A distinct client can recover immediately without ever
  overlapping the unresolved request.
- Preserve request gates and quarantines across renderer reinjection. Busy
  v61 upgrades, including an idle renderer with prior timeout evidence, fail
  closed by retaining cached inventory with an explicit recovery state until
  a distinct client completes an authoritative listing.
- Keep late legacy clients from replacing a healthy recovered runtime, expose
  bounded recovery state in probes, and retain Windows/macOS renderer parity
  at v62.

## v1.5.21

- Serialize local task listings across hydration, preview, and optional
  auto-cleanup so one app-server client never receives overlapping pagination
  streams. A timed-out raw request keeps the gate until it settles, preventing
  retry storms and hidden overlap.
- Read maintenance inventory directly from the authoritative state database,
  include desktop `appServer` chats, capture one runtime client per cleanup
  run, and apply the remaining hard deadline to every list and mutation call.
- Replace per-chat full active/archived re-listing with one bounded fresh
  snapshot while retaining pinned, selected, loading, parent/child, lease, and
  generation protections.
- Skip reported rollout paths outside the current Codex home's managed session
  roots instead of repeatedly sending app-server mutations that must fail.
  Preview and run results expose only safe skipped counts and sanitized errors.
  Renderer v61 is identical on Windows and macOS.
- Build ZIP entries with portable forward-slash names under Windows PowerShell
  5.1 and reject archives without exactly one top-level release directory.

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
