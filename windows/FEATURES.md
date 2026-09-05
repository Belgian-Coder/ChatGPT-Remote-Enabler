# Feature guide

## Everyday controls

| Feature | Behavior | Default or limit |
| --- | --- | --- |
| Mobile projects / Native views | Switch between device-aware project grouping and native views. | Preserves native grouping and expansion; synchronization continues in both views. |
| Device filters | Show all devices or one selected device. | A cached inventory does not prove a device is online. |
| Device names | Remember verified names across reloads/restarts. | Unknown peers say **Remote device**; internal environment IDs are never the fallback. |
| Project rows | Include active empty projects, native folder styling/order and new-chat actions. | New-chat requires a usable command in the installed app. |
| Task indicators | Spinner while working; blue dot after completion until viewed. | Aggregate on collapsed projects; opening a remote task acknowledges it locally. |
| Auto-register | Mirror active remote project registrations locally. | Only fresh complete inventory can drive changes; no chat or source-folder deletion. |
| Remove auto projects | Remove registrations made by Auto-register and suppress immediate recreation. | Keeps manual registrations/chats/folders; **Allow auto-registration** reverses suppression. |

## Updates

Checks run asynchronously at launch and every 30 minutes while open. **Update available** appears beside the view controls in both views. Installation requires a click.

Clicking pins the selected release/checksum and prepares it while the app remains open. The helper waits for authoritative idle activity, including internal tasks. Unknown activity keeps it queued. **Cancel** is available until shutdown starts. Resumed work makes it continue waiting.

The helper rechecks write access and activity, requests a graceful close of the exact recorded process, applies verified files, and relaunches with saved direct/proxy and startup settings. Protected proxy configuration is reloaded; restart descriptors contain no proxy credentials. The initial startup delay and update check are skipped once on this relaunch. A different app instance appearing during the update is not replaced.

A refused close does not trigger force termination. Interrupted replacement uses a durable journal and verified recovery before another injection. A surviving file writer blocks competing recovery; unknown journal/lock ownership blocks the action. Failures appear in update status or a native notification and logs. A protected package folder must be moved to a writable per-user location or handled separately by its administrator; the helper never elevates itself.

## Optional cleanup: read before enabling

**Auto-cleanup is off by default.** When enabled, eligible inactive local chats are archived after seven days, then permanently deleted after a tracked seven-day recovery window in Archived chats. Selected, working, pinned, remote, and insufficiently dated chats are skipped. Permanent deletion also requires a known managed archive path and exclusive cross-window ownership. Missing evidence means skip.

Disabling cleanup clears its timers. Re-enabling starts a new recovery window. Preview commands in the platform guide show eligibility without changing chats. Removing project registrations is separate and never deletes conversations.

Physical startup maintenance prunes old diagnostic logs, checkpoints/optimizes SQLite and vacuums fragmented databases. It skips while the desktop app is running. Maintenance errors are reported without preventing ordinary launch.

## Synchronization and prerequisites

Participating devices publish active inventory through the app's authenticated Remote connection. Full inventory refreshes every 60 seconds and after detected task membership changes. Working/unread updates remain faster. Failed refreshes do not renew old authority; it expires after three minutes. Internal exec/subagent work is checked for update safety but excluded from user-facing project chats.

The helper requires a supported desktop app, a signed-in account with Remote, Node.js 22+, and a writable package folder. It adds no central catalogue, account entitlement or firewall exception. It uses the special-session loopback debugger connection and private desktop internals, which can change between app versions.

## Validation status

Automated Windows native fixtures, real Chromium renderer/CDP integration, transaction interruption/recovery and source checks pass. Native macOS execution and full real-app update/relaunch acceptance remain pending. The prerelease label does not imply those tests are complete. See the release notes for exact tested boundaries.
