# Windows

Mobile Projects mirrors the native task-state indicators: a spinner while a task is working and a blue dot after it finishes until that task is viewed. Opening a remote task acknowledges that completion locally until its owning device reports the next state transition.

In Mobile Projects, **Auto-register: on/off** locally enables or pauses remote-project mirroring. It adds registrations and removes only automation-created registrations after a fresh, complete direct inventory confirms the source project was removed. It never deletes chats or folders. **Remove auto projects (N)** removes those registrations now and suppresses immediate recreation; it stays visible but disabled at `(0)`. Right-click a suppressed project and choose **Allow auto-registration** to permit it again.

Run `ChatGPT Remote Enabler.exe`, or open PowerShell here and run:

```powershell
.\Enable-ChatGPTRemote.ps1
```

The compatibility check runs first. Renderer v62 preserves the user's
**By project**/**By connection** Native views preference and every folder's
open/closed state. It automatically paginates the authoritative active task
list for the app-server's interactive CLI/VS Code sources used by the desktop UI. Internal exec and subagent
runs remain available to maintenance safety checks but are not published as
project chats. Only native or persisted chat titles are published; preview and
first-message text is never treated as a title. The renderer publishes complete active projects, tasks, and working/unread state
into this device's Codex home. Other devices use direct peer reads plus local
per-device cache files if a request stalls. No folder opening, **Show more**
click, shared catalogue, or central storage is required. Empty active projects
appear while archived/removed projects and stale native rows do not.
When a connected device is still running an older publisher, its direct
user-facing task list takes precedence over that cached inventory so internal
child runs stay hidden during a staggered upgrade.
Verified user-facing task IDs are retained locally for seven days so renderer
reinjection and background refreshes keep the last correct list on screen.
An unverified device contributes no chat rows until its filtered
task query succeeds, preventing internal rows from flashing temporarily.
Device dots use current Remote runtime presence plus successful direct probes.
Cached peer inventory alone cannot mark an offline device as online; an online
device can remain green while its inventory service retries independently.
Renderer requests are time-bounded and retry after transient bridge failures;
cached projects remain visible with an offline dot while the owning device is unavailable.
Synchronization continues automatically when **Native views** is selected.
Controllers read their complete registered-project state directly and verify
new registrations before recording success. Remote chats match projects by
device and normalized path, so they remain under the registered project.
The inventory refreshes on startup and every 30 seconds without opening the
grouping menu or changing its value. Hovering a
Mobile Projects folder opens the exact native project composer when available;
registered projects retain a native global-composer fallback when their folder
row is not mounted by the selected grouping.

The launcher checks for an update on every start by default. It first hands
launch ownership to a mutex-protected PowerShell worker and exits, allowing the
verified updater to replace the launcher executable before that same worker
continues injection exactly once. Direct/proxy and manual/startup arguments are
preserved. A clean `main` Git checkout fast-forwards to the latest release tag
through its configured origin; an extracted release still uses the verified
archive updater. Manage it with:

```powershell
.\Update-ChatGPTRemote.ps1 -Action Probe
.\Update-ChatGPTRemote.ps1 -Action DisableAutoUpdate
.\Update-ChatGPTRemote.ps1 -Action EnableAutoUpdate
.\Update-ChatGPTRemote.ps1 -Action Update
```

Set `CHATGPT_REMOTE_UPDATE_REPOSITORY=owner/repo`, `CHATGPT_REMOTE_UPDATE_API_BASE`, or `CHATGPT_REMOTE_UPDATE_LATEST_URL` for a fork or GitHub mirror. `CHATGPT_REMOTE_AUTO_UPDATE=0` skips one automatic check. Set `CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS` to a positive number only when you want to throttle checks. Failed downloads, Cisco/security block pages, dirty Git checkouts, and verification failures never replace installed files.

For a persistent local shortcut, keep the extracted folder in place and run:

```powershell
.\CodexRemoteMobileProject\DesktopShortcut.ps1 -Action Install
```

This creates one **ChatGPT Custom** shortcut on the Desktop and one in the
Start menu. It always runs the sibling stable and Mobile Projects bundles, so
future clicks load the injected view rather than the normal app. Use
`-UseProxy` only when this device needs proxy mode; it configures those same
shortcuts with `--proxy`. The installer never creates a separate proxy
shortcut and recoverably removes obsolete proxy entries. First import the
existing User-scope proxy into DPAPI-protected local storage:

```powershell
.\CodexRemoteMobileProject\ProxyConfiguration.ps1 -Action Install -ImportUserEnvironment
.\CodexRemoteMobileProject\ProxyConfiguration.ps1 -Action Probe
```

The import copies the proxy into protected storage; it never removes or changes
User- or Machine-scope environment variables needed by other software. The
custom launcher clears only its own process-local inherited proxy variables
before starting ChatGPT, then uses an HTTP CONNECT tunnel only for the ChatGPT
Remote control WebSocket. Other applications retain their normal proxy
environment. TLS verification stays
enabled and includes certificates trusted by Windows. Proxy URLs containing
credentials are rejected, and probe output never exposes the proxy host. An
environment-variable fallback remains for older installations. Without `-UseProxy`, the shortcut uses direct
networking. If injection fails, the launcher restores ordinary ChatGPT startup
without the targeted proxy shim.

```powershell
.\CodexRemoteMobileProject\DesktopShortcut.ps1 -Action Install -UseProxy
```

For automatic injected startup after sign-in, install a per-user startup
shortcut. This does not require elevation. Use `-UseProxy` on a VPN or network
where Remote requires the configured proxy; omit it for direct networking.

```powershell
.\CodexRemoteMobileProject\StartupShortcut.ps1 -Action Install -UseProxy
.\CodexRemoteMobileProject\StartupShortcut.ps1 -Action Probe
```

The installer replaces a disabled legacy startup shortcut after preserving a
rollback copy. Use `-Action Remove` to remove the active shortcut. The target is
the versioned `ChatGPT Custom.exe` in this folder; its worker handoff releases
the executable before a verified in-place update and then continues startup.
A manual **ChatGPT Custom** click is explicit
permission to replace an ordinary running ChatGPT session. Unattended startup
uses `--startup`, never terminates an active ordinary session, and records the
reason in `%LOCALAPPDATA%\CodexRemoteFeatures\startup.log`.

An elevated scheduled-task alternative remains available and now supports the
same proxy mode:

```powershell
.\CodexRemoteMobileProject\MobileProjectStartup.ps1 -Action Install -UseProxy -Confirm:$false
```

The task and shortcut both use the signed-in account and built-in Windows
PowerShell. They retry the stable bridge once when needed. Windows GUI startup
occurs at interactive sign-in, not before a user session exists.

Install the injected startup on both the controller and every controlled device.
After Remote first reports **Connected**, projects and chats can take several
seconds to populate. A fresh host inventory expires after three minutes; when
it is missing or stale, automatic project changes pause instead of using path
history. With mirroring enabled, controller registrations absent from the
host's active list are removed without deleting chats or folders.

Rollback:

```powershell
.\Disable-ChatGPTRemote.ps1
```

Automation controls are also available from PowerShell:

```powershell
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action EnableAutoRegistration
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action DisableAutoRegistration
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action RemoveAutoRegistrations
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action EnableAutoMaintenance
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action DisableAutoMaintenance
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action PreviewAutoMaintenance
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action RunAutoMaintenance
```

**Auto-cleanup** is off by default. When enabled, it uses the local Codex
app-server to archive unpinned, inactive local chats after seven days and to
permanently delete them after a tracked seven-day recovery window in Archived
chats. Existing archived chats receive a new seven-day window when first seen.
Disabling cleanup clears its timers. Selected, working, pinned, remote, and
insufficiently dated chats are skipped.
`PreviewAutoMaintenance` reports archive/delete eligibility without changing
anything. Before launching ChatGPT, the packaged launcher also prunes diagnostic
logs older than seven days (96 MiB cap), checkpoints WAL files, optimizes, and
vacuums materially fragmented SQLite databases. It skips physical maintenance
when any ChatGPT/Codex process is already running.

Node.js 22 or newer is required. The launchers do not modify WindowsApps, the
registry, firewall rules, or services. `ChatGPT Remote Enabler.exe` and
`CodexRemoteMobileProject\ChatGPT Custom.exe` are unsigned and compiled from
their included C# source files.
