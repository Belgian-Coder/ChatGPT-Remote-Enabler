# Feature guide

## Everyday controls

| Feature | Behavior | Default or limit |
| --- | --- | --- |
| Device projects / Native sidebar | Switch between device-aware project grouping and native views. | Preserves native grouping and expansion; synchronization continues in both views. |
| Device filters | Show all devices or one selected device. | A cached inventory does not prove a device is online. |
| Device names | Remember verified names across reloads/restarts. | Unknown peers say **Remote device**; internal environment IDs are never the fallback. |
| Project rows | Include active empty projects, native folder styling/order and new-chat actions. | New-chat requires a usable command in the installed app. |
| Task indicators | Spinner while working; blue dot after completion until viewed. | Aggregate on collapsed projects; opening a remote task acknowledges it locally. |
| Auto-register | Mirror active remote project registrations locally. | Only fresh complete inventory can drive changes; no chat or source-folder deletion. |
| Remove auto projects | Remove registrations made by Auto-register and suppress immediate recreation. | Keeps manual registrations/chats/folders; **Allow auto-registration** reverses suppression. |

## Settings and device information

**Settings** is available in both views. It contains Auto-register, removal of automation-created registrations, Auto-cleanup, its permanent-deletion schedule, and update checks. Moving these controls does not change stored preferences. Cleanup stays active in Native sidebar if previously enabled.

**Device health** shows reported device names, connection availability, and inventory freshness separately. Device filter buttons also expose their connection state to assistive technology. Empty projects distinguish loading, disconnected devices, stale inventory, and verified empty results.

Keyboard focus and sidebar scroll position are retained during refreshes. Update announcements use a persistent polite status region. Controls have larger targets and support reduced motion. Browser fixtures cover light/dark themes and 200% scaling; this is not a claim of complete screen-reader or WCAG certification.

## Updates

Checks run asynchronously at launch and every 30 minutes while open. **Update available** appears in its own status row in both views. Queued updates explain the wait directly; technical errors have a details disclosure and a **Check again** action. Installation requires a click.

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


## Device health and local aliases

Open **Device health** to see the reported name, connection-check time, inventory age/source, publisher protocol, and helper version when supplied by the peer. **Refresh devices** coalesces requests and is limited to once every ten seconds; cached inventory is not proof of connectivity.

Set or reset a device alias in that panel. Aliases are stored only in this client's local storage, survive renderer reloads, and change display labels only. They never replace device identity, reported names, cache keys, or published inventory. Clearing the app's local storage removes them.

## Cleanup preview and history

In Settings, expand **Cleanup preview and history** and select **Refresh cleanup preview**. It lists archive and permanent-deletion counts, up to 100 candidate titles per action, and a snapshot time. Preview does not enable cleanup, archive/delete tasks, or start recovery timers. Complete task and pinned-task information is required; missing information makes preview unavailable. Actual cleanup always checks eligibility again.

Local history begins with this version and retains up to 100 operations from the last 90 days, including incomplete runs. Entries contain a title, action, and time, without task IDs or paths. A recorded operation follows a native command acknowledgement. Storage failure is shown and does not block cleanup. Restore archived tasks through native **Archived chats**; permanently deleted tasks cannot be restored here.

## Update details and history

In Settings, **Update details and history** shows installed/available helper versions, the last successful check, release-note links, and persistent update stages. **Refresh update history** rereads history without checking for updates or changing the queue. Older helpers that do not supply history show that limitation.

History contains up to 100 events from the latest 20 recorded sessions within 90 days. It stores only stage, version, and timestamp. A stage such as file replacement or restart requested is not success; relaunch confirmation is recorded only after the launcher acknowledges readiness. Corrupt records are ignored, and a history-write failure does not prevent an update.

## Diagnostic export preview

In Settings, expand **Diagnostic export preview** and generate a snapshot. Review the JSON before choosing Copy or Save; both use exactly the displayed snapshot. Nothing is uploaded automatically. Regenerate explicitly to refresh it.

The allowlist includes helper/renderer versions, pseudonymous device labels, connection and inventory age/counts, cleanup settings/history count, and update status/version/event count. It excludes real device names and aliases, device/task IDs, task titles, paths, raw logs/errors, and credentials. This deliberately limited report is not a complete support log.

## Validation status

Automated Windows native fixtures, real Chromium renderer/CDP integration, transaction interruption/recovery and source checks pass. Native macOS execution and full real-app update/relaunch acceptance remain pending. The prerelease label does not imply those tests are complete. See the release notes for exact tested boundaries.

![Settings feature panels in a browser fixture](assets/screenshots/features-v1.5.34.png)

Screenshots use synthetic browser fixtures; they are not native macOS acceptance evidence.
