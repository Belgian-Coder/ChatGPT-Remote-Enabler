# Changelog

## v1.5.99 — 2026-09-24

- Reconnect a lost local update bridge automatically; probe renderer health instead
  of treating a live helper process as a working connection. Clear failed check
  promises so future checks can retry. Report a disconnected local service
  separately from release availability, and distinguish installed from loaded versions.
- Repair an eligible idle legacy updater after repeated exact-session failure
  proofs without closing ChatGPT. Cooperatively retire an owned legacy publisher
  before starting its replacement, preserving one active owner.
- Isolate renderer callback ownership across reconnections and remove owned
  bindings on cleanup, preventing stale callbacks and accumulating bridge functions.

- Keep native project membership when merging task inventories, and publish that
  membership to other devices so grouped chats do not fall into Recent chats.
  Treat ambiguous null membership as unknown for chats without a rendered row;
  preserve explicit projectless chats and current project-path matching.
- Defer Windows desktop updates rejected with package-resources-in-use
  (`0x80073D02`) when the installed package remains unchanged and healthy.
  Reuse the existing bounded candidate cache to avoid repeated downloads.
- Attach and inject into an already-running Windows ChatGPT instance at sign-in
  or manual launch, including ordinary instances with a registered runtime
  inspector hook. Preserve the process and active work; reuse compatible managed
  sessions. Separate renderer sessions carry publisher and updater events.
  Wait within the attachment timeout for a cold app's renderer to become ready.
  Existing apps skip upgrades and maintenance while retaining interrupted-update
  recovery. Unsupported hooks or startup-only connection changes report a specific
  error without closing the app or bypassing a requested proxy.
  Preserve recoverable inspector-probe failures under Windows PowerShell 5.1
  instead of aborting before the attachment fallback can run.
  Reuse a healthy updater coordinator for the exact session instead of waiting
  for a duplicate worker to time out; report its retained dependency snapshot.
  Re-inject a lost native-renderer bridge into a verified managed session without
  closing ChatGPT, while refusing mismatched process identities or connection modes.
- Normal startup checks for interrupted-update journals under the updater lock.
  With no journal and a structurally complete package, it skips full installed-file hashing and heavy cleanup, while
  still migrating owned legacy startup entries to the windowless launcher;
  actual update recovery and failed-update validation retain their full checks.
  Report incomplete startup-entry migration and retry it on the next launch
  without blocking attachment to the running app.
- Consolidate duplicate owned shortcuts while preserving distinct proxy modes,
  repair recognized dangling entries, and retain one effective owned sign-in
  entry. Route logon tasks through the windowless GUI launcher. Keep the official
  ChatGPT entry and unrelated shortcuts intact.
- Promote a newer extracted helper package before calling installed controllers,
  so manual recovery does not pass new switches to an older installed copy.
- Start progress, recovery-continuation, heartbeat, proxy-worker and detached
  task-host cleanup helpers without allocating consoles, in addition to
  requesting hidden windows.
- Use the native timestamp index for log retention while retaining the seven-day and
  96 MiB limits. Startup database work still requires the app to be closed.

## v1.5.98 — 2026-09-24

- Preserve Codex's native project membership when its direct `thread/list`
  response reports a null project ID. Project chats stay in their native
  folders instead of being misclassified as projectless Recents.
- Publish that native membership in the device inventory so peers can group
  the same chats correctly. Explicit non-null IDs from `thread/list` still
  take precedence; ungrouped chats remain projectless.
- This renderer-only change can be loaded into a running injected session.

## v1.5.97 — 2026-09-24

- Defer Windows desktop-app updates when package resources are still in use
  (`0x80073D02`), allowing Remote Enabler to launch and inject the unchanged
  healthy installation. Reuse the existing bounded update deferral; do not
  force-close applications or bypass deployment policy. Recognize native,
  wrapped, and text-only deployment errors.
- No renderer or macOS runtime changes. An already running ordinary ChatGPT
  session still needs a user-approved restart through Remote Enabler to gain
  the debugger connection required for injection.

## v1.5.96 — 2026-09-23

- Fix Windows proxy Remote authentication for both controller layouts. Map the
  exact per-launch loopback transport back to its public WebSocket target for
  the native device-key challenge comparison; keep signed challenge data,
  enrollment, and account authorization unchanged. Prepare a new private
  runtime on the next app launch; this change requires reopening the app.
- Attach the publisher heartbeat and automatic updater immediately after
  renderer injection, before waiting for sidebar readiness, in both Windows
  launch paths. A slowly mounting sidebar no longer leaves a recovered app
  without its background update service.

## v1.5.95 — 2026-09-22

- Continue Windows startup after an unavailable helper update only when local
  recovery proves the installation intact. Preserve updater exit codes and
  reload changed files before launch; malformed success proof still stops.
  An unchanged, recovered installation continues without a launcher respawn.
- Give renderer readiness its full timeout after target discovery, and retry
  temporary probe failures without restarting ChatGPT.
- Keep automatic seven-day/96 MiB log retention at startup on both platforms.
  Run startup VACUUM only when at least 64 MiB and half the database are free,
  avoiding repeated full rewrites while still reclaiming substantial waste.
- Repair missing Windows helper files from a valid setup package through the
  existing transaction, including retirement of verified older files during
  cross-version repair, retaining downgrade protection and one rollback.
  Preserve recovery of older transaction journals when retired files were
  already absent before the update.

## v1.5.94 — 2026-09-21

- Keep cold sidebar enablement waiting for the exact Codex renderer target for
  30 seconds even when an older launcher or update continuation supplies the
  former five-second target wait. Default direct probes retain their five-second
  lookup, live-update commands include an explicit parent-timeout margin, and
  startup diagnostics record both requested and effective discovery windows.

## v1.5.93 — 2026-09-19

- Remove the exact ChatGPT build, UI-text, provider-layout, and minifier
  signature allowlists from Windows startup. Select the bridge from installed
  runtime capabilities, discover proxy patch points semantically, and require
  successful live renderer readiness instead of a version-dependent prelaunch
  signature. Release and private-copy hashes protect downloaded or copied
  files from corruption; no ChatGPT executable or ASAR hash decides whether a
  version is supported.
- Bind every controller lifecycle action to the helper-owned main process by
  PID, executable path, and process-start identity. An adopted session, reused
  PID, or unrelated ChatGPT process sharing the same executable path is left
  untouched instead of being stopped during replacement or failure recovery.
- Continue launching an unchanged healthy current-user ChatGPT Store package
  when Windows explicitly rejects its verified newer MSIX with deployment error
  `0x80073D28`; unrelated installer failures and changed package state still
  stop before injection, and no elevation or policy bypass is attempted. Cache
  that exact verified deferral so later launches do not download the same large
  package again; any candidate or installed-package change forces revalidation,
  the unchanged candidate is retried after 24 hours, cache-disabled results
  explain why, and an explicitly supplied local package always bypasses the
  automatic cache.
- Publish project-membership authority as renderer protocol 54 so it survives
  older relays. Current helpers keep projectless tasks in Recent chats even when
  their working directory is a registered project, while project tasks still
  fall back to their published path when helper catalogues have no native ID.
- Clear retained loading indicators only for stale empty projects on devices
  known to be offline, without hiding current local, online, or unknown activity.
- Close the Windows startup progress window as soon as renderer readiness is
  proven, before arming the background update-session monitor.
- Cover the Windows startup decision under PowerShell 5.1 and 7, plus direct
  project attribution, staggered-version interoperability, and stale remote
  status behavior on both platform renderers.

## v1.5.92 — 2026-09-17

- Mount Device projects from the stable sidebar scroll capability while a new
  ChatGPT build is still loading and has not rendered project, recent-task, or
  section rows yet, so runtime discovery and inventory publication no longer
  remain blocked behind an empty native sidebar.
- Reanchor automatically to the exact native list when it appears without ever
  hiding the sidebar shell or global navigation, preserving live update support
  across staggered desktop versions and renderer rebuilds.
- Apply the same capability-based startup and recovery behavior on Windows and
  macOS, with regression coverage for empty-start and late-list transitions.

## v1.5.91 — 2026-09-17

- Accept the current platform-neutral Windows device-key provider only when one
  shared exact parser proves its signing flow, native loader bindings,
  controller capability, and native PE module, instead of depending on a
  removed platform-specific error sentence.
- Keep both guarded and platform-neutral compatibility fail-closed for
  incomplete, duplicated, mixed-generation, decoy, mismatched-loader, or
  non-Windows provider signatures.
- Patch the same audited platform-neutral provider when an existing protected
  enrollment needs the private compatibility runtime, preventing a later
  startup failure after the initial compatibility check succeeds.
- Exercise the controller compatibility result and rejection path under both
  Windows PowerShell 5.1 and PowerShell 7.

## v1.5.90 — 2026-09-16

- Keep fresh direct Codex task and project metadata authoritative when an older
  helper snapshot fails, preventing chats from moving back to stale project
  paths during staggered upgrades.
- Suppress the misleading project-sync warning when direct device inventory is
  current, while retaining helper failure details in diagnostics.
- Provide a direct app-server archive action for authoritative path-titled
  threads that have no mounted native action rail, so they can be removed from
  Device projects without manual database or filesystem changes. The action is
  single-flight, survives safe runtime-wrapper refreshes, reconciles uncertain
  outcomes, restores definitive rejections immediately, and reports failures
  visibly without permanently hiding sync health or depending on unrelated peers.
- Exclude local runtime aliases from peer inventory writes and cache normalized
  loaded-search text, reducing duplicate sharing work and repeated filtering
  cost for large task lists.
- Exercise locked executable recovery with a changing package payload so the
  Windows startup regression proves journal retention and automatic recovery.

## v1.5.89 — 2026-09-16

- Treat a fresh native project catalog plus complete direct task inventory as
  authoritative even when an older helper cannot publish its optional peer
  inventory, preventing connected devices from appearing out of date.
- Separate the 15-second native refresh cadence from the three-minute
  authority window, and report the older required evidence age in diagnostics
  so long-running sessions do not flicker or understate staleness.
- Hide locally archived chats immediately and reconcile them against fresh
  post-action inventory with a bounded rollback that remains timely even when
  a shared device refresh stalls.

## v1.5.88 — 2026-09-16

- Give the Windows cold-start renderer target the same bounded 30-second
  discovery window already used on macOS, sharing the existing overall mobile
  readiness deadline instead of failing after the five-second command default.
- Report the full renderer-target retry budget when the final discovery slice
  expires, rather than presenting the last one-millisecond sub-attempt as the
  complete wait.
- Keep pre-DOM renderer reinjection single-owner so a superseded payload cannot
  reactivate after its replacement handles `DOMContentLoaded`.
- Skip transaction copies whose installed destination already has the pinned
  hash, allowing long-running proxy sessions to update without replacing their
  unchanged, locked process launcher.

## v1.5.87 — 2026-09-16

- Repair the native macOS startup window's JavaScript for Automation runtime,
  keep its run loop alive, acknowledge startup, and close it automatically
  after renderer readiness is proven.
- Launch the exact ChatGPT executable directly without Apple Events, preserve
  stable Dock-wrapper identities, and retain actionable startup logs.
- Reinstall after renderer replacement, defer DOM attachment until available,
  bound renderer requests, and force the injector CLI to exit after completion.
- Prefer a standalone Git installation over the Xcode command-line-tools shim
  so prelaunch updates are not blocked by an unaccepted Xcode license.

## v1.5.86 — 2026-09-15

- Add a native AppKit startup-progress window to the macOS Dock shortcut. It
  opens before update recovery and reports update recovery/check, maintenance,
  launch, renderer readiness, and completion; failures remain visible with a
  clean corrective message and the window closes only after readiness proof.
- Replace macOS TCC-sensitive `NSRunningApplication` termination with an exact
  PID/start-token/executable/bundle/UID guard, an exact renderer `quit-app`
  request, and one permission-free POSIX `SIGTERM` fallback. The close path
  never force-kills and rejects changed or ambiguous identities.
- Keep Windows `native-renderer-quit`, `WM_CLOSE`, and concurrent-exit behavior
  unchanged while method-whitelisting both platform adapters; suppress only the
  expected ad-hoc codesign replacement diagnostic from macOS shortcut setup.
- Add focused AppKit/progress, close-identity, TCC-avoidance, Windows-parity,
  archive, privacy, and source-regression coverage.

## v1.5.85 — 2026-09-15

- Detect running ChatGPT, Codex, and the configured macOS application by exact
  executable path instead of basename-only `pgrep`, preventing a second app
  instance when Electron exposes a different process name.
- Share that fail-closed detector across the launcher, generated Dock shortcut,
  exact renderer-process capture, proxy verification, and maintenance safety.
- Regenerate an existing legacy **ChatGPT Mobile Projects** compatibility
  wrapper after a successful update so it follows the fixed stable install root
  and receives the same exact process guard as the current shortcut.
- Cover ChatGPT, Codex, names containing spaces, the legacy-name miss, and
  rejection of helper and unrelated command lines with real-zsh fixtures.

## v1.5.84 — 2026-09-15

- Use one automatic graceful ChatGPT restart for the v1.5.83-to-v1.5.84
  handoff-protocol migration. Later compatible updates transfer the coordinator
  dynamically without closing ChatGPT.
- Run the signed Remote Enabler prelaunch update before the optional ChatGPT
  desktop-app update, so a desktop-updater proxy DNS outage cannot prevent
  installed self-repair logic from running on future releases.
- Transfer compatible live updates through an armed, exact-identity coordinator
  handoff. The predecessor removes its CDP binding before releasing its owned
  lock, retires only after the successor publishes an active heartbeat, and
  reclaims the lock, binding, and status if replacement startup fails.
- Enforce the same ChatGPT PID, creation token, executable, renderer port, and
  macOS application identity throughout handoff. Stop an unsuccessful candidate
  automatically and keep the original ChatGPT process open.
- Keep every retained coordinator session with its referenced immutable bundle,
  so retention consistently preserves the current and one previous generation
  instead of allowing a newer orphan bundle to displace rollback support.
- Accept the exact legacy startup-shortcut rollback filename produced by the
  Windows launcher in both stable-root and transaction integrity checks, while
  continuing to reject malformed or arbitrary rollback files.
- Treat temporary HTTPS proxy name-resolution failures as transient in the
  PowerShell 5.1 curl path, matching PowerShell 7 retry and offline-startup
  behavior.

## v1.5.83 — 2026-09-15

- Keep installed packages valid when runtime-owned rollback files or Finder
  metadata coexist with the manifest, while retaining exact inventory checks
  for downloaded and staged release payloads.
- Tolerate bounded transient parent-process identity lookup failures so a busy
  machine does not permanently stop the publisher heartbeat.
- Verify the exact matched macOS ChatGPT process command line and preserve the
  existing LaunchAgent proxy mode during stable-root migration.
- Retry desktop package metadata requests canceled by an HttpClient timeout,
  and resolve only static Windows proxy settings while rejecting PAC and WPAD.
- Support HTTPS proxies in mandatory Windows PowerShell 5.1 prelaunch requests
  through bounded curl transport while retaining native HttpClient behavior in
  PowerShell 7, safe redirect checks, TLS validation, and body-read deadlines.
- Resolve the exact ChatGPT process with bounded retries after package-context
  proxy launch so the publisher heartbeat never receives the transient worker
  process identity.
- Start the newly installed coordinator through a detached handoff and verify
  its active heartbeat on both platforms while ChatGPT stays open; retain only
  the current and immediately previous coordinator sessions and bundles.
- Reject arbitrary unmanifested installed files while allowing only exact
  platform runtime metadata, and require clean committed release sources by
  default. Use progress-based body timeouts so slow active downloads can finish.

## v1.5.82 — 2026-09-15

- Route every helper-controlled external connection through the selected fixed,
  credential-free HTTP(S) proxy on Windows and macOS. This includes the
  ChatGPT Chromium and Node runtimes, Remote transport, desktop-app metadata
  and downloads, Git release checks, checkout fetches, and update handoffs;
  loopback debugger and bridge traffic remains direct.
- Resolve protected proxy mode before mandatory prelaunch updates, preserve it
  through shortcuts, startup registration, hot updates, and relaunches, and
  reject SSH or rewritten Git origins that could bypass an HTTP proxy.
- Bind Windows live-session reuse to a SHA-256 proxy-endpoint fingerprint and
  route URL, string, options-object, and `https.get` calls through the legacy
  main-process proxy shim with an absolute CONNECT/TLS deadline.
- Validate every updater redirect before the next request, constrain ChatGPT
  MSIX downloads to the official stable endpoint, and scope Git's proxy on the
  command line so user configuration cannot override explicit proxy mode.
- Reject unlisted files and linked entries in release payloads, copy only
  manifest-listed package files, and require clean committed platform sources
  when building release archives.
- Load renderer v88, transfer offline peer caches through collision-resistant
  device identities, serialize unsettled remote reads, scan beyond 200 pages
  when checking update activity, and keep the proven coordinator active after
  a compatible hot update without closing ChatGPT.
- Retain one stable rollback, no legacy recovery generations, one macOS startup
  rollback, two immutable coordinator bundles, and twenty bounded session
  histories. Release output retains only the current and previous version.
- Make publisher-heartbeat locks session-specific, recheck the exact parent
  process start identity, and stop a retiring helper when a successor owns the
  lock.

## v1.5.81 — 2026-09-15

- Treat an already-exited prelaunch updater parent as a completed continuation
  handoff instead of failing after a successful verified update.
- Preserve the desktop shortcut's protected proxy mode through the root GUI
  launcher, update continuations, stable runtime launch, and later in-session
  update relaunches.
- Retry transient renderer-target replacement between debugger discovery and
  WebSocket connection instead of failing an otherwise healthy startup.
- Give cold renderer debugger discovery the full readiness window and close the
  startup progress window before showing a modal launch failure.
- Retry atomic update-journal replacement for up to 15 seconds when Windows
  endpoint scanning temporarily holds the just-written journal file.
- Accept the current signed ChatGPT desktop minifier signature in the audited,
  length-preserving Remote-control proxy patch while retaining fail-closed
  matching for unknown builds.

## v1.5.80 — 2026-09-14

- Detect when Codex React independently removes the mobile project panel, then
  remount it directly before the still-connected native sidebar list. This
  prevents a successful launch from showing a false readiness timeout.
- Validate the final release-response URI through both Windows PowerShell and
  PowerShell 7 response shapes, retaining the HTTPS redirect boundary.

## v1.5.79 — 2026-09-14

- Prune the content-addressed Git release archive cache automatically after
  every successful resolution. Each machine now retains at most the current
  archive and one previous archive, while unsafe or unrecognized entries remain
  untouched for fail-closed handling.

## v1.5.78 — 2026-09-14

- Make live updates recover the exact installed renderer when candidate
  activation succeeds but its readiness or process proof later fails.
- Keep distinct native devices that share a display name, and bind cached peer
  inventories to their publisher identity so slug collisions and duplicate
  names cannot show one device's projects under another device.
- Preserve case-sensitive POSIX project paths while retaining Windows drive and
  UNC case folding. Hidden renderer instances also stop making periodic native
  catalogue refresh requests.
- Make macOS shortcut removal transactional and discard successful-operation
  scratch rollback files. A live update now keeps its proven coordinator until
  the current ChatGPT process ends; stable-root adoption, failed prepared-update
  cleanup, and hot-reload local/remote identity match a cold launch.
- Correct Windows source-checkout detection inside unrelated Git repositories
  and let disable remove stale registrations left by older ephemeral ports.
- Advance the shared Windows/macOS renderer to v86 and add regression coverage
  for these update, identity, path, cleanup, and performance boundaries.

## v1.5.77 — 2026-09-14

- Remove a peer-relayed echo of the current device when its reported name and
  project paths match even if the local ChatGPT account currently has no chats.
  A zero-chat PC-Marc exposed that the former duplicate detector unnecessarily
  required matching non-empty thread ids.
- Advance the shared Windows/macOS renderer to v85 and add a zero-chat local
  inventory regression while retaining the two-of-three identity safeguard.

## v1.5.76 — 2026-09-14

- Treat the current machine's native Remote host id as a local runtime alias,
  removing stale projects, tasks, connectivity, and remembered discovery data
  for that id. This closes the cached-inventory path that could keep a duplicate
  disconnected self row visible after v1.5.75 filtered the native catalogue.
- Advance the shared Windows/macOS renderer to v84 and extend the regression to
  seed the same stale inventory and connectivity state observed on PC-Marc.

## v1.5.75 — 2026-09-14

- Exclude the current machine from ChatGPT's refreshed native Remote device
  catalogue by its normalized reported name. The permanent **This device** row
  remains authoritative, while the same machine can no longer reappear as a
  second disconnected remote entry after an automatic catalogue refresh.
- Advance the shared Windows/macOS renderer to v83 and add regression coverage
  for case-insensitive names with the optional macOS `.local` suffix.

## v1.5.74 — 2026-09-14

- Refresh ChatGPT's native Remote device catalogue automatically at renderer
  startup and every 15 seconds through the app's own read-only connection
  method. A controller now recovers a peer that came online after its cached
  catalogue went stale without opening Settings, running a command, or
  restarting ChatGPT.
- Make **Refresh devices** and **Force refresh** update the native catalogue
  before direct project and task inventory discovery. Requests are singleflight,
  time bounded, and cadence limited; authorization and connection preferences
  remain native ChatGPT responsibilities.
- Add Windows and macOS source parity plus regression coverage for automatic
  recovery, bounded polling, and the allowlisted native refresh operation.

## v1.5.73 — 2026-09-14

- Normalize the detached Windows handoff helper's `PSModulePath` to the native
  Windows PowerShell module roots before it invokes the coordinator launcher.
  This prevents a PowerShell 7 parent environment from hiding standard
  Windows PowerShell 5.1 commands during the live coordinator replacement.

## v1.5.72 — 2026-09-14

- Keep the stable-install cleanup test's deliberately newer legacy fixture at
  v9.9.9 so routine package version bumps cannot turn it into an equal-version
  fixture and produce a false regression failure. Include the coordinator
  handoff helper in bundle-root fixtures and require it in both release packages.
  Runtime behavior is unchanged from v1.5.71.

## v1.5.71 — 2026-09-14

- After a compatible no-close update, schedule a detached handoff to the
  coordinator from the newly installed package. The replacement waits for the
  old exact coordinator and its session lock to exit before it attaches, so
  ChatGPT remains open and only one updater owns the renderer.
- Keep the old coordinator running when replacement scheduling fails. Windows
  uses the stable coordinator-only launcher; macOS adds an internal
  coordinator-only action that does not reinject, relaunch, or duplicate the
  publisher heartbeat.
- Add controller and launcher-schedule regression coverage and ship the same
  bounded handoff helper in both platform packages.

## v1.5.70 — 2026-09-14

- Read the production injector's nested renderer readiness proof during a live update so a healthy dynamically loaded renderer can proceed to transactional installation.
- Add a platform-adapter regression test using the exact production readiness shape.

## v1.5.69 — 2026-09-14

- Treat CRLF/LF-only conversion in protected Windows PowerShell files as the same running runtime, while still validating both manifests and both files before a live update.
- Keep semantic protected-runtime changes fail-closed so they continue to require a normal app restart.
- Add regression coverage for line-ending-only Git/release packaging differences that previously misclassified a compatible update and attempted the restart path.

## v1.5.68 — 2026-09-14

- Load compatible verified updates into the current renderer without closing or
  restarting ChatGPT. The coordinator compares protected runtime hashes, proves
  the prepared renderer and full Device projects readiness before replacing
  files, verifies the exact app identity afterward, and records a distinct live
  reload confirmation.
- Keep the existing idle gate and graceful restart path for releases that change
  the Windows compatibility bridge or platform publisher. A prepared renderer
  failure leaves installed files untouched; a failed apply uses journal recovery
  and reloads the prior renderer while ChatGPT remains open.
- Apply the same live update contract on Windows and macOS. Both packages use
  renderer v81 and retain one immediate package rollback.

## v1.5.67 — 2026-09-14

- Retry transient failures from the official ChatGPT MSIX metadata endpoint
  with bounded backoff. If the endpoint remains temporarily unavailable, the
  launcher may continue with the already validated current-user ChatGPT
  package; publisher, identity, architecture, health, and installation
  failures remain fail-closed.
- Show a temporary startup-progress window during recovery, desktop-app and
  Remote Enabler update checks, protected-proxy preparation, launch, and Device
  projects readiness. The window closes automatically when startup completes
  or fails.
- Immediately suppress a remotely archived task, perform two bounded
  authoritative membership checks, and block cached native-row navigation
  until remote membership is confirmed. A failed archive or refresh restores
  the last-known row instead of hiding it indefinitely.
- Publish task-status changes as soon as the native sidebar presentation
  changes, including one coalesced follow-up when a publication is already in
  flight. This keeps working, unread, error, and attention icons aligned across
  connected devices. Per-task observation timestamps prevent inventory
  heartbeats from renewing stale spinners, bounded attention flags survive peer
  relay, and an independent 5/15-second activity timer keeps remote status reads
  moving even when the controller is idle. Windows and macOS use renderer v80.

## v1.5.66 — 2026-09-12

- Remove every package-created Windows shortcut, startup-task, and package-local
  rollback after a successful update or current-version cleanup. The updater
  retains only its one immediate package rollback.
- Treat shortcut backups as transaction-local files: exact post-write probes
  must pass before they are removed, while failures retain them for diagnosis.
  Test callers now use an isolated rollback root and prove that successful
  shortcut install and removal leave no auxiliary recovery files.

## v1.5.65 — 2026-09-12

- Validate the signed Windows desktop updater's explicit `VersionText` fields.
  Windows PowerShell serializes `System.Version` values as JSON objects, so the
  former string cast rejected valid downgrade-refusal proof and stopped the
  stable shortcut before ChatGPT launched. Both Windows launch paths and their
  Windows PowerShell 5.1 regression fixture now cover that exact proof shape.

## v1.5.64 — 2026-09-12

- Keep the atomic macOS shortcut candidate's filename ending in `.app`, which
  makes `osacompile` create an application bundle that can be signed, probed,
  and committed. The native macOS support test now performs a real temporary
  shortcut install and probe so this packaging contract cannot regress.

## v1.5.63 — 2026-09-12

- Correct updater retention to the owner-defined invariant: one immediate
  rollback generation and zero legacy-recovery generations. Active journal or
  live-process references still fail closed until the next successful cleanup.
- Give macOS the same unversioned per-user installation model as Windows.
  Recognized version-named installs migrate to the fixed Application Support
  root; existing LaunchAgent and app-shortcut targets are rebuilt against that
  root before obsolete install folders are removed.
- Remove package-created macOS LaunchAgent and shortcut rollback copies after a
  successful migration or update. Native fixtures cover stable-root migration,
  one updater rollback, zero auxiliary rollback copies, and removal of the
  version-named source root.

## v1.5.62 — 2026-09-12

- Bound per-user Windows updater history to the five newest rollback
  generations and two newest legacy-recovery generations. Successful updates
  and checks remove older direct children only after path, reparse, active
  journal, and live-process safety checks; unsafe or referenced recovery data
  remains retained with an explicit reason.
- Parse JSON recovery journals when checking path references so escaped Windows
  paths retain their rollback or legacy root until recovery no longer needs it.
- Keep the signed desktop prelaunch guard fail-closed on Windows PowerShell 5.1
  when exactly one ChatGPT process is running by preserving the enumerator
  result as an array on both Windows launch paths.
- Capture expected native helper failures without allowing Windows PowerShell
  5.1 to replace their structured error details with `NativeCommandError`.
- Pass transaction fixture arguments as an explicit array and remove its stray
  temporary debug file so the Windows PowerShell gate exercises every helper
  action with the intended argument boundaries.
- Refuse durable shortcut, logon-task, and global legacy-root migration when a
  test or caller supplies a noncanonical stable root. Fixture-scoped installer
  checks can still exercise their explicit paths without touching the signed-in
  user's real entry points or scanning real install directories.

## v1.5.61 — 2026-09-12

- Move the permanent Windows installation to the current user's unversioned
  `%LOCALAPPDATA%\CodexRemoteFeatures\ChatGPT-Remote-Enabler-Windows-x64`
  root. This keeps automatic replacement under the same limited user that owns
  the shortcuts and updater state, so an administrator-created ProgramData ACL
  cannot allow new files while denying replacement of existing payload files.
- Recognize the v1.5.60 ProgramData stable root as an exact legacy source.
  Migrate its verified package, Desktop, Start-menu, Startup, and logon-task
  entry points to the per-user root, then apply the existing manifest,
  live-process, coordinator, journal, rollback, and reparse checks before
  removing it. Version-named legacy roots remain covered by the same cleanup.
- Add regression coverage for the per-user default and exact machine-root
  legacy classification. Windows and macOS package versions remain synchronized;
  the install-root correction changes Windows only.

## v1.5.60 — 2026-09-12

- Make the Windows installation root permanent and version-independent at
  `C:\ProgramData\CodexRemoteFeatures\ChatGPT-Remote-Enabler-Windows-x64`.
  Desktop, Start-menu, Startup, and logon-task entry points now converge on
  that root, including every ChatGPT Custom and legacy Remote Enabler alias,
  while preserving proxy and startup arguments.
- Keep verified update journals and rollback material under per-user updater
  state. Long-lived `UpdateSessionTaskHost.exe` workers run from hash-verified
  detached per-session copies outside the stable root, so a running worker
  cannot block stable-root replacement and no ChatGPT process is terminated.
- Validate VERSION, release-manifest hashes, and launcher ProductVersion before
  migration or update. After successful recovery or update, remove superseded
  version-named roots only when shortcuts, tasks, live processes, live
  coordinator configurations, journals, and recovery material no longer
  reference them. Externalize
  both root and mobile rollback trees before cleanup, and return removed or
  retained roots and updater artifacts with explicit reasons.
- Add deterministic Windows regression coverage for detached-host locking,
  manifest-gated replacement, legacy alias migration, proxy/startup argument
  preservation, interrupted recovery, rollback retention, reparse and
  process-inventory failure, newer-root retention, and no ChatGPT lifecycle
  calls.

## v1.5.59 — 2026-09-12

- Make both Windows shortcut/startup entry points fail closed through one
  ordered launch gate: recover and verify Remote Enabler integrity, complete
  the official signed x64 ChatGPT MSIX update without stopping a running app,
  complete a required verified-Git Remote Enabler update, reload any replaced
  coordinator, and only then probe compatibility or inject. Missing helpers,
  network failures, opt-out/check-interval skips, malformed or duplicate JSON
  proof, unsupported package identity, and repeated recovery all stop launch.
  Rollback recovery remains compatible with the previous entry point.
- Run the macOS verified Git automatic update under the existing launch guard
  before debug-endpoint discovery, compatibility checks or renderer injection.
  Validate the updater's final result, recover and verify installed integrity,
  and hand an updated launch back to the replaced script without replaying the
  prelaunch check or startup delay. The sole JSON proof must be the final
  nonblank record, and current as well as updated results require an exact
  verified-Git method; malformed, duplicate or non-Git proof fails closed. A
  best-effort network failure may continue only after installed integrity is
  proven. Recovery now validates its boolean, version and mode contract and
  also hands off when complete-forward, rollback or unchanged recovery changed
  the on-disk launcher before a current Git result.
- Make the native connection snapshot's explicit online state authoritative for
  device availability. Offline devices retain cached rows but no longer receive
  remote inventory, outbound publisher transfers, or native thread requests and
  are excluded from refresh completeness, error and resume-staleness decisions.
  Transient missing native snapshots preserve the last authoritative state;
  reconnection forces a fresh request and resumes only the newest publisher
  snapshot. Require the native catalog and status cache to arrive as one
  coherent snapshot so either one-sided gap preserves the prior offline state;
  treat a refresh with only known offline peers as complete and non-actionable.
- Preserve remote runtime cache and its retry timestamp after an ordinary
  inventory read failure instead of discarding usable runtime evidence. Add
  deterministic lifecycle coverage for offline suppression, cached-row
  retention, native-status precedence, failure preservation and reconnect.
- Ship renderer v79 on Windows and macOS. Source, browser/search, native macOS
  prelaunch, archive-layout and privacy validation are release gates; package
  publication remains distinct from installation and native runtime acceptance.
- Retain current Windows native-renderer support when the official package
  already has embedded-ASAR integrity disabled. Add an exact no-proxy,
  existing-protected-key regression so older installed helpers that reject this
  valid fuse state recover by updating to v1.5.59 before launch.
- Return `method=verified-git` from packaged Git transactions and cover the
  strict Windows recovery, desktop-package, current/newer-package, Git proof,
  handoff, rollback-compatibility and failure contracts deterministically.

## v1.5.58 — 2026-09-11

- Add an explicit Windows `Update-ChatGPTDesktop.ps1` Probe/Check/Update path
  for the official Store-signed x64 package at
  `persistent.oaistatic.com`. It uses HTTPS metadata checks, per-user temp
  staging, manifest and Windows-native signature validation, exact identity and
  version comparisons, current-user `Add-AppxPackage`, and cleanup. It refuses
  downgrades, ambiguous `OpenAI.Codex`/legacy `OpenAI.ChatGPT-Desktop` states,
  running `ChatGPT.exe`, elevation, provisioning and corporate AppX policy
  bypasses. The base-app updater is manual only; no standalone MSI or
  Store-independent EXE exists, and offline license/MDM requirements remain
  environment-specific.
- Add deterministic local MSIX fixture coverage for current and legacy package
  discovery, no-package and ambiguous states, manifest identity/publisher/
  architecture checks, signature rejection, process refusal, `-WhatIf`,
  current-user install verification, and temp cleanup.
- Run a verified Git automatic prelaunch update from both Windows startup entry
  points, including unattended mobile-project startup, before compatibility
  probing or injection. The existing automatic-update opt-out and check
  interval remain honored. Successful replacement verifies recovery and hands
  off to the updated script without replaying the consumed GUI-launcher
  handshake; recoverable Git or network failures continue only after
  installed-file integrity is proven.

## v1.5.57 — 2026-09-11

- Support both the previous ChatGPT Windows proxy-runtime layout and the controller/challenge signatures shipped in direct ChatGPT build `26.903.8094.0`. Variant selection remains exact and fail-closed for unknown or ambiguous builds.
- Accept both audited Electron ASAR-integrity fuse states: change enabled (`1`) to disabled (`0`) only in the private runtime, or preserve an official runtime that already ships disabled. Unexpected fuse layouts and values remain rejected.
- Add deterministic coverage for both controller/challenge variants and both fuse states. Live Windows validation launched `26.903.8094.0` in scoped proxy mode, reached renderer v78 readiness, published a fresh local inventory, and discovered the connected Windows11-VM.

## v1.5.56 — 2026-09-10

- Keep project inventory fresh when the desktop app freezes both animation frames and renderer timers while hidden. A parent-bound, per-renderer helper now wakes the exact `app://-/index.html` target through its existing loopback debugger every 10 seconds; it exits with the app and uses a process lock to prevent duplicates.
- Make an external wake discard any dormant renderer timer before publishing immediately. Retain the v1.5.55 direct timer path for foreground and normally backgrounded renderers, and re-arm publication after a transient inventory-refresh gap.
- Start the publisher heartbeat independently of the update session on Windows and macOS. Add deterministic helper and renderer regressions, including proof that an armed-but-frozen timer is bypassed. Ship renderer v78 in release v1.5.56.
- Live Windows validation held publication age to 3–5 seconds over a 22-second hidden-renderer interval while publishing 19 projects/tasks. Native macOS execution remains a separate acceptance check.

## v1.5.55 — 2026-09-08

- Keep the cross-device inventory heartbeat independent of renderer animation frames. Hidden/background Electron windows can suspend `requestAnimationFrame` while ordinary timers and app-server requests remain available; the publisher now writes directly from its 5/15-second timer so peer inventories and shared aliases do not expire after three minutes.
- Treat a local publication older than the remote validity window as unready, and report its age in probes and diagnostic exports. This prevents a stale file from being described as a healthy local publisher.
- Add a deterministic regression that holds every animation frame indefinitely and proves the publisher still advances its file heartbeat. The reliability fixture also proves stale publisher readiness fails closed. Ship renderer v77 in release v1.5.55.

## v1.5.54 — 2026-09-08

- Add loaded-content search to Device projects. Search project names and chat titles within device filters, reveal matching chats, and restore the original project expansion when cleared. Keep queries in memory, support literal Unicode text and IME input, and disable reordering while results are filtered.
- Shorten sync messages and open the relevant Device health section directly from a stale or incomplete status. Put device health and connection help before cleanup; group cleanup controls and consequences under Automatic cleanup and remove the duplicate update-check button.
- Debounce search for 120 ms and reuse the loaded model without scheduling remote discovery per keystroke. Cancel search timers on teardown and protect composition, focus, caret, drafts, and scroll.
- Fix opening known remote projects when the local project-state bridge is unavailable. An already expanded native project can use the navigation bridge immediately instead of waiting for hydration it cannot trigger. Cancel delayed task navigation after a newer activation or renderer teardown.
- Ship renderer v76 in release v1.5.54. Native macOS acceptance and live cross-device timing remain separate validation.
- Validation: all 15 renderer self-tests and both isolated Chromium suites passed, including direct/publisher task navigation, late bridge discovery, 10,000-chat search, IME/caret preservation, 280/320/400-pixel sidebars, both themes, 1x/2x scaling, minimum control sizes and teardown. Windows/macOS renderer and feature-guide parity, source harness parsing, and diff checks passed. New preview images use synthetic data.

## v1.5.53 — 2026-09-07

- Open inventory-only remote chats by registering and expanding their native remote project on demand, including projects beyond the native five-project collapsed limit. Confirm current task membership before synthetic navigation and retain a recently activated task until a newer authoritative inventory arrives.
- Recover a remote message left permanently on **Steer** after an outcome-unknown `turn/steer` transport failure. Recovery is intentionally narrow: it runs when the user reopens the task and clears the stale marker only after both the local manager and a newly fetched authoritative remote inventory report that exact task idle. Unknown starts, mixed pending submissions, active tasks, and incomplete inventories fail closed to avoid duplicate work.
- Add task-navigation regression coverage and include it in the complete source suite. Live Windows acceptance opened both previously unavailable remote tasks, recovered the stale Steer lock, and completed a new submission without restarting ChatGPT.

## v1.5.52 — 2026-09-07

- Include both Git update helpers in the immutable detached controller bundle on Windows and macOS. Their contents now participate in bundle identity and copy verification, so the updater can resolve Git dependencies after restart.
- Discovered during predeployment inspection of v1.5.51. No managed installation was updated before correction.
- Validation: full source suite passed, including actual Windows detached-bundle creation, helper-only fingerprint changes, and execution of the real Git helper through the detached updater. macOS bundle contracts, package build/privacy checks, and diff validation passed.

## v1.5.51 — 2026-09-07

- Use stable Git tags and shallow fetch for update checks and preparation by default on both platforms. Generate and verify a deterministic local archive, manifest, and pinned commit without GitHub API or hosted ZIP downloads. Require Git, honor its proxy/certificate configuration, bound command time, and retain the hosted-release transport only as an explicit option.
- Fast-forward clean source checkouts on main to the pinned tag. Preserve dirty, diverged, non-main, and unexpected-origin checkouts; keep an external journal and recover only the original or completed commit without reset.
- Replace repeated Windows PowerShell File.Replace subprocesses with bounded adjacent native renames. Verify and resume completed journal operations; rewind durably if the completed prefix no longer matches. The existing transaction fixture fell from about 160 seconds to 31 seconds on the test host. This proves a source performance defect, not the exact cause of the reported work-device timeout.
- Allow bounded Git preparation before closing the app and shorten update-session lock waits. Preserve graceful close, idle checks, process containment, manifest verification, and relaunch readiness requirements.
- Put the compact refresh icon immediately after Settings, with accessible busy/queued state. Retry runtime/manager discovery when activating a synthetic task before the navigation bridge was available.
- Validation: Git transport and Windows default-Git Check/Prepare/ApplyPrepared/Recover fixtures passed, including hash mismatch rejection and unreachable HTTP endpoints. Source checkout and interrupted transaction tests passed, as did the update-session fixture.
- Full `tools/Test-Source.ps1` passed in the isolated standalone checkout, including the new Git integration and source-preservation cases. Legacy Windows updater compatibility, archive layout/privacy, platform parity, and diff checks passed. Expected failing probes now clear their exit code after their assertions pass so the suite reports their actual outcome.
- Browser verification passed in Chromium with synthetic runtimes: direct and publisher task activation, refresh placement/accessibility, retained cached rows and drafts, both themes, 280/320/400-pixel sidebars, and 1x/2x scaling. The rendered fixture was visually inspected.
- Reproduced green connection indicators together with an incomplete-inventory warning: config and task-list reads succeeded while the published inventory read failed. These indicators represent different facts; cached rows remain. This does not identify the actual remote-device failure, and no warning suppression was added.
- Native work-device installation, actual cross-device task opening, and native macOS execution of these changes remain unverified.

## v1.5.50 — 2026-09-07

- Stop background project discovery from opening native Add project dialogs, including on clients that previously enabled automatic registration. Preserve discovered rows, existing registrations, and explicit project actions.
- Add Force refresh and a shared sidebar refresh coordinator with cache invalidation, bounded follow-up requests, and stale-result protection. Retain cached rows on failed or incomplete reads and show sync freshness inline.
- Refresh stale chat membership when returning to the app and retain the periodic membership refresh. Add regression coverage for quiet discovery, stale runtime recovery, refresh races, and draft/sidebar preservation.
- Baseline reproduction: the discovery fixture against the original renderer observes one unwanted native navigation call; the isolated forced-refresh case performs zero chat-list reads while a retry gate is active. These reproduce source defects, not the already-recovered live two-desktop incident.
- Validation: full `tools/Test-Source.ps1` passed in an isolated standalone checkout (the canonical Infrastructure package is a source mirror); the final four additional discovery-race regressions also passed separately. Both package archive checks and privacy gates passed, and Windows/macOS renderers plus all three feature guides are byte-identical. `git diff --check` passed.
- Independent final review resolved reconnect, replaced-runtime, local project-read, and scheduled-refresh races. Legacy background reconciliation is also retired so refresh cannot remove registrations or clear the selected project.
- Browser validation passed in Chromium with synthetic runtimes: fresh membership without registration dialogs, retained failed/incomplete inventories, focus throttling, teardown/reinstall races, and preservation of the open route, typed draft, caret, focus, filters, collapsed state, and sidebar scroll. Checked both themes at 280/320/400-pixel sidebar widths and 1x/2x scaling; inspected the rendered fixture screenshot.
- The optional, older `EmptySidebarDiscovery.SelfTest.js` still references removed `nativeSidebarMountContainer`; it fails identically on the unchanged baseline and is not part of `Test-Source.ps1`. Current empty/native connection behavior is covered by the maintained lifecycle and browser fixtures.
- Published package validation does not imply installation or actual two-Windows-client acceptance; those live checks remain pending.

## Unreleased documentation

- Expand the README into a complete feature overview with refreshed v1.5.49 renderer screenshots using synthetic demo data, connection authorization guidance, and current validation scope. Include a reproducible screenshot capture in the browser fixture.

## v1.5.49

- Keep authoritative empty task lists stable during background local and remote inventory refreshes. Initial, stale, failed, disconnected and incomplete inventories still show their distinct status instead of being presented as current empty results.

## v1.5.48

- Give Windows startup workers and update coordinators a stable per-user temporary directory. This lets the native close helper compile when a scheduled task inherits Windows TEMP under a normal user.
- Apply the same process-only environment setup to direct startup scripts before recovery. Child updater and relaunch processes inherit it; user and machine environment settings remain unchanged.

## v1.5.47

- Complete Windows update preparation when a normal user's temporary folder is Windows TEMP. Use the same scoped cleanup for checks, preparation staging and completed update staging.
- Preserve read-only file cleanup without following directory links, and retain cleanup failures. Cover full pinned preparation with a failing PowerShell cleanup provider.
## v1.5.46

- Share saved device aliases and resets automatically through the existing authenticated peer inventory connection. Keep aliases separate from device identity, connection settings and cache paths.
- Retain existing local aliases, resolve concurrent edits consistently, and preserve reset records so reconnecting or newly upgraded clients cannot restore older cleared names.
## v1.5.45

- Run the Windows post-update startup script without the detached-process flag that caused PowerShell to exit 0 before executing the script. Keep the already independent update coordinator alive until the readiness handoff; retain hidden windows and descendant survival.
- Cover the real Windows relaunch workload after the initiating process job terminates, successful child survival after coordinator exit, and rejection of a launcher that exits without readiness.
- Show device filters as All, This device, then other devices alphabetically by their displayed names, including saved aliases.
- Preserve unchanged sidebar elements during background refreshes instead of repeatedly replacing the complete panel. Refresh changed controls and task targets, and build settings from current state when opened.
## v1.5.44

- Put the current device first in the filter row and identify it with a visible and accessible `this device` label. Keep the All filter beside it for compact wrapping.
- Use authoritative task membership and independently known activity/unread state for folder indicators. Empty projects clear stale busy state, completed work changes from a spinner to the native unread indicator, and reading it clears that indicator without guessing unknown state.
- Clean the version-check scratch directory directly instead of through the PowerShell filesystem provider. This fixes successful checks being reported as Access denied under a normal user whose temporary directory is Windows TEMP; cleanup failures are not suppressed.
- Ask the Windows app to quit through its native command during an update. Closing its window alone leaves the tray process running. Bind the request to the exact process and loopback debugger, retain graceful-close fallback, and never force-terminate the app.

## v1.5.43

- Match the native sidebar's `No chats` empty state, child-row indentation, and status placement. A collapsed Device project can show child activity when the underlying native project is expanded; an explicitly idle collapsed native project still clears stale status.
- Recognize the verified native device-key provider structure across minifier identifier changes. Existing protected keys continue through the same compatibility adapter, with matching require/module bindings and platform/resource guards retained.
- Store executable Unix modes in macOS release ZIPs and normalize the five launcher/setup entry points during preparation and apply. This preserves direct shortcut and LaunchAgent execution after an update.
- Cover current/previous device-key loader layouts, rejected binding mismatches, native status and layout behavior, archive creator/mode metadata, and native executable-mode preservation through apply and rollback.

## v1.5.42

- Launch Windows startup workers and update coordinators through a transient task running as the interactive user. A GUI helper starts their processes without a console, so closing the originating app or its process job no longer kills the update/relaunch sequence.
- Verify the detached coordinator with hashes and a nonce-bound process identity and readiness receipt; remove transient tasks after handoff. Preserve launched app descendants when the startup worker exits.
- Fix macOS prepared-update application under zsh `set -u`: initialize rollback paths sequentially and propagate unsafe prepared-directory rejection. This fixes an update that restarted the old version after returning non-JSON output.
- Add native Windows process-job, descendant-survival, and visible-console checks, plus an isolated native macOS apply/rollback fixture. Log the close, apply, recovery, and relaunch stages separately for live diagnosis.

## v1.5.41

- Replace an existing Windows session record atomically with a valid same-volume backup path. Windows PowerShell otherwise bound the absent backup argument as an empty path, falsely failed a healthy launch, and could tear it down during the guarded retry.
- Discover the React root from stable app/sidebar anchors and mount Device projects from the native Projects/Recents section markers even when a fresh sidebar has no task or project rows. This removes the empty-sidebar readiness dependency while retaining the guard against hiding global navigation.
- Accept additional device-name fields only when they accompany a real environment host ID, and cover existing-state replacement, empty-sidebar mounting, and row-free React-root discovery in deterministic regressions.

## v1.5.40

- Accept the renderer's current nested `report.readiness` envelope in both Windows startup coordinators while retaining the former flat-report format for compatibility. This fixes the live v1.5.39 launch failure that reported incomplete readiness proof even though the same renderer later became ready.
- Apply the same envelope correction on macOS, retry transient not-ready states until the bounded deadline, and include the final readiness flags and reason when the deadline expires.
- Exercise the actual nested renderer envelope, the legacy flat envelope, transient retry behavior, and cross-platform launcher contracts in deterministic tests.

## v1.5.39

- Keep polling a well-formed mobile-project readiness report while its renderer reports a transient not-ready reason. On timeout, retain the final readiness flags and error instead of failing on the first explanatory message.
- Persist trusted device labels as soon as native discovery or remote inventory observes them, including normalized long and short host identities. Retain the labels after a renderer restart even when Codex authorization is temporarily absent, without treating saved names as connection or authorization proof.
- Record the first stable-bridge failure before the guarded retry so repeated app activation can be diagnosed from the startup log.
- Reuse an intact same-session update controller after a transient debugger reconnect, preserving pending renderer requests and avoiding a brief false unavailable/replaced state.
- Add deterministic regression coverage for both Windows readiness entry points and for pre-render device-name persistence across a renderer restart.

## v1.5.38

- Retry a transient Windows path-provider lookup failure while validating a prepared update directory. Keep the existing fail-closed rejection of reparse points and fail immediately for permission or other non-transient errors.
- Add deterministic regression coverage for a one-time missing-path result and for rejection of a real directory junction during prepared-directory validation.

## v1.5.37

- Preserve existing Windows Remote Enabler enrollment keys when the installed Codex build switches to its native Windows key provider. Normal startup detects a matching protected key and prepares a version-matched private runtime with a native-first fallback to the existing DPAPI store. New keys remain native, and direct connections retain the original network URLs and challenge validation.
- Verify compatibility helper hashes before reusing a session; launch the selected private executable through its package context instead of activating the ordinary installed executable. The installed app files and existing enrollment store are preserved.
- Read device labels from the native connection catalog even when a device has no sidebar rows, retain those labels across renderer restarts, and prevent placeholders or inventory hostnames from replacing them.
- Observe native authorization and connection changes independently of sidebar mutations, invalidate stale runtime discovery, and retry project inventory after reconnect. Report authorization/sign-in/access blocks explicitly instead of silently waiting.
- Add regression coverage for existing protected-key signing across fresh processes, native-provider preference, startup selection, private runtime reuse/tamper detection, empty-folder transfer and modeling, and browser document reloads. Live signed peer reconnection and native macOS acceptance remain pending; no release was injected into running apps.

## v1.5.36

- Put update controls, device health, cleanup, diagnostics, and connection troubleshooting behind Settings in both views. Keep only navigation and device filters before projects, with a small update-attention indicator on Settings.
- Replace the unsupported blob-download action with the native Save As service. Save the exact preview, prevent duplicate dialogs, and report saved, cancelled, and failed outcomes.
- Recover the local state bridge from the app's own loaded module exports when React-based discovery misses it. Verify a read before use, exclude RPC proxies, share discovery, and dispose pending requests. This restores pin-aware cleanup preview and local project-state access on the current desktop build.
- Explain specific cleanup failures, clear stale failed previews, and distinguish earlier incomplete history from current state. Record only allowlisted failure reasons.
- Report when a connection refresh cannot start because a listed device has no exposed runtime.
- Verify native bridge discovery, read-only preview recovery, Unicode save payloads, cancellation/error handling, and compact Settings layouts in browser fixtures. Native macOS and full live-app quit/update/relaunch remain pending.

## v1.5.35

- Publish as a normal release discoverable by existing automatic updaters. Earlier prerelease flags had blocked v1.5.31 clients. Verify the legacy Auto action and bootstrap the new Windows update helper during that first upgrade, preserving the recorded proxy mode.

- Keep the update icon and loaded helper version visible in both views with Settings closed. Show explicit recovery and a release link when the update sidecar is absent; document the loaded version and legacy shortcut targets.

- Add guided connection troubleshooting in both views, with explicit evidence refresh and privacy-conscious session transfer statistics.
- Remove recipient inventory echoes and redundant nullable fields while retaining schema-v1 compatibility and third-peer forwarding.
- Suppress timestamp-only publication echoes and use idle heartbeat timing for idle task rows. Keep direct-read cadence and original task-membership authority timestamps.
- Serialize peer writes, retain only the newest pending snapshot, share configuration discovery, and add bounded exponential retry. Keep unresolved write ownership across renderer reinjection; expire old jobs and retain direct-read fallback.
- Verify a 64% smaller push JSON in the documented two-client, 1,000-task fixture, plus timeout/reinjection, retry, stale-authority, browser guidance, and diagnostic privacy checks. This is not a live network speed benchmark.
- Native macOS, assistive technology, real sign-in, and full live-app update acceptance remain pending.

## v1.5.34 (prerelease)

- Add device health with timestamped connection/inventory evidence, optional peer helper version, and coalesced refresh.
- Add local device aliases without changing identity, reported names, cache keys, or publication.
- Add read-only cleanup previews that fail closed on incomplete task/pin information, plus bounded local operation history.
- Add persistent update details/history, validated release-note links, and a read-only history refresh that can pick up late relaunch results.
- Add allowlisted diagnostic JSON preview with explicit copy/save and no automatic upload.
- Cover alias reload/caret retention, preview safety, history retention/privacy, real browser exports, and CDP metadata/history requests.
- Keep native macOS, assistive technology, real sign-in, and full live-app update acceptance pending.

## v1.5.33 (prerelease)

- Rename the enhanced view to Device projects and preserve stored view preferences.
- Move automation into Settings in both views, with readable cleanup consequences and update checks.
- Add visible update wait reasons, technical error details, stable status announcements, device details, and evidence-based empty states.
- Increase control/text sizes and preserve focus/scroll through refreshes; add light/dark, narrow-layout, and scaling coverage.
- Add per-user Windows and macOS setup assistants. New shortcuts share the Remote Enabler name; installation retains legacy shortcuts.
- Keep native macOS and assistive-technology acceptance explicitly pending. Potential feature ideas are tracked separately in UX-ROADMAP.md.


## v1.5.32 (prerelease)

- Add step-by-step per-user Windows 11 and Apple Silicon installation guides,
  portable Node.js discovery, removal/troubleshooting instructions, and a
  complete feature guide included in both archives. Validate Windows extraction,
  write access and shortcut lifecycle under a real non-elevated user token.
- Replace automatic installation during launch with asynchronous release
  checks and an Update available control in both sidebar views. A session
  helper prepares the selected verified release, waits for active work,
  gracefully closes ChatGPT, updates, and restores the saved launch mode.
  Queued updates can be cancelled before shutdown; refused shutdown never
  triggers a forced termination.
- Make replacement recoverable after process interruption with an exclusive
  update lock, durable journal, atomic file replacement, and validation before
  another injected launch. Write session records atomically and quarantine
  damaged records before safe rediscovery.
- Fix debugger discovery hanging on truncated responses and proxy connection
  deadlines ending before target TLS negotiation. Apply bounded renderer
  retries consistently and clean up failed persistent registrations.
- Resolve peer names through the normal discovery, merge, publication, and
  restart flow. Native placeholders cannot overwrite verified names; an
  unknown peer displays Remote device rather than its environment ID.
- Refresh complete task lists every 60 seconds and after detected membership
  changes while preserving fast status updates. Preserve the true acquisition
  timestamp so status publication cannot keep old membership authoritative.
- Reduce unrelated sidebar rescans, production diagnostic work, and steady
  gate discovery. Expose readiness stages and privacy-conscious timing/counters.
- Require known managed archive paths and exclusive cross-window ownership
  for permanent cleanup. Report physical-maintenance errors explicitly while
  allowing best-effort startup maintenance to continue.
- Windows and macOS share renderer v65. Native macOS startup, quit, and
  update/relaunch acceptance is deferred until a Mac is available; candidate
  validation records distinguish automated coverage from native runtime tests.

## v1.5.31

- Match native project row spacing, headings, open/closed folder icons, and
  expanded empty-project placeholders. Mount Projects and Recents together,
  and omit the artificial folder layer for single-device Recents.
- Preserve confirmed device names across renderer reinjection and temporary
  metadata gaps. Unknown connectivity is neutral rather than reported offline.
- Honor native task indicators and collapsed-project aggregation, including
  working, unread, and waiting states, with reduced-motion support.
- Preserve keyboard focus during sidebar refreshes and support keyboard
  navigation and dismissal of custom menus. Unavailable native actions remain
  disabled instead of appearing actionable.
- Add focused host-name, layout, status, and keyboard regression suites.
  Windows and macOS share renderer v64; existing remote authorization,
  inventory filtering, and maintenance safeguards remain unchanged.

## v1.5.30

- Publish the fully validated native-proxy and complete-project-sync build as a
  strict successor to pre-release v1.5.29 installations. This ensures automatic
  update replaces candidate packages that already identify as v1.5.29.

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
- Retry renderer installation when Electron replaces its initial page and
  closes the first DevTools WebSocket. This prevents a slow first launch of the
  private runtime from being mistaken for an application crash.
- Restore complete project publication on current ChatGPT builds that expose
  the local app-server request client without the former project-state bridge.
  A fresh native sidebar catalogue is merged with saved project state, so empty
  projects are included without falling back to stale or archived inventories.
- Align Mobile Projects folder icons and row spacing with the native sidebar,
  and mark inventory-only remote folders consistently. Renderer v63 keeps the
  existing v53 publisher contract for safe staggered upgrades on Windows and
  macOS.

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
