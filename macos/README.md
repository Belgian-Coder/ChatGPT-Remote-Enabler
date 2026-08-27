# macOS Apple Silicon

Mobile Projects mirrors the native task-state indicators: a spinner while a task is working and a blue dot after it finishes until that task is viewed. Opening a remote task acknowledges that completion locally until its owning device reports the next state transition.

In Mobile Projects, **Auto-register: on/off** locally enables or pauses remote-project mirroring. It adds registrations and removes only automation-created registrations after a fresh, complete direct inventory confirms the source project was removed. It never deletes chats or folders. **Remove auto projects (N)** removes those registrations now and suppresses immediate recreation; it stays visible but disabled at `(0)`. Right-click a suppressed project and choose **Allow auto-registration** to permit it again.

macOS already exposes native ChatGPT remote connections. This package adds the optional Mobile projects view.

Renderer version 51 preserves the original folder states, native-backed drag
ordering, and the user's **By project**/**By connection** preference. It
automatically paginates the authoritative active task list for user-facing CLI,
VS Code, and desktop chats. Internal exec and subagent runs remain available to
maintenance safety checks but are not published as project chats. It publishes
this Mac's complete active projects, tasks, and working/unread state into its Codex
home. Other devices use direct peer reads plus local per-device cache files if
a request stalls. No folder opening, **Show more** click, shared catalogue, or
central storage is required. Empty active projects appear while archived or
removed projects and stale native rows do not.
When a connected device is still running an older publisher, its direct
user-facing task list takes precedence over that cached inventory so internal
child runs stay hidden during a staggered upgrade.
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

Install the injected startup on both the controller and every controlled
device. Inventories expire after three minutes; missing or stale inventories
pause automatic project changes instead of falling back to historical paths.
The launcher refuses to create a second app instance when ChatGPT/Codex is
already running without its loopback renderer endpoint.

```zsh
chmod 755 ./MobileProjectView-macOS-arm64.sh
./MobileProjectView-macOS-arm64.sh enable
./MobileProjectView-macOS-arm64.sh probe
./MobileProjectView-macOS-arm64.sh enable-auto-registration
./MobileProjectView-macOS-arm64.sh enable-auto-maintenance
```

Use `disable-auto-registration` to pause mirroring, `reconcile-auto-registrations` to synchronize immediately, or `remove-auto-registrations` to remove only automation-created registrations. Synchronization never deletes chats or source folders.

**Auto-cleanup** is off by default. `enable-auto-maintenance` archives unpinned,
inactive local chats after seven days, then permanently deletes them after a
tracked seven-day recovery window in Archived chats. Existing archived chats
receive a new seven-day window when first seen; disabling cleanup clears the
timers. Selected, working, pinned, remote, and insufficiently dated chats are
skipped. Use `disable-auto-maintenance`, `preview-auto-maintenance`, or
`run-auto-maintenance` to control it.

Before starting ChatGPT, the packaged launcher prunes diagnostic logs older than
seven days (96 MiB cap), checkpoints WAL files, optimizes, and vacuums materially
fragmented SQLite databases. It skips physical maintenance while ChatGPT/Codex
is running.

The launcher checks for a verified GitHub release on every start. Manage it with:

```zsh
/bin/zsh ./Update-ChatGPTRemote.sh probe
/bin/zsh ./Update-ChatGPTRemote.sh disable-auto-update
/bin/zsh ./Update-ChatGPTRemote.sh enable-auto-update
/bin/zsh ./Update-ChatGPTRemote.sh update
```

Set `CHATGPT_REMOTE_UPDATE_REPOSITORY=owner/repo`, `CHATGPT_REMOTE_UPDATE_API_BASE`, or `CHATGPT_REMOTE_UPDATE_LATEST_URL` for a fork or GitHub mirror. `CHATGPT_REMOTE_AUTO_UPDATE=0` skips one automatic check. Set a positive `CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS` only if you want throttling. Failed downloads or verification keep the installed version.

## Automatic injected startup

For an update-safe login launcher and Dock shortcut, keep the extracted
package in a permanent local folder, then run from that folder:

```zsh
CODEX_STARTUP_DELAY_SECONDS=60 ./MobileProjectView-macOS-arm64.sh install-startup
chmod 755 ./MacOSShortcut.sh
./MacOSShortcut.sh install
./MacOSShortcut.sh reveal
```

Drag the revealed app to the Dock. The startup launcher waits 60 seconds by default, retries renderer discovery for up to 30 seconds, and accepts an optional `CODEX_STARTUP_REQUIRED_PATH` folder gate. Roll back with:

```zsh
./MobileProjectView-macOS-arm64.sh remove-startup
./MobileProjectView-macOS-arm64.sh disable
./MacOSShortcut.sh remove
```

Requires Apple Silicon and Node.js 22 or newer with built-in WebSocket support. The current renderer was live-validated on Apple Silicon macOS; a future ChatGPT update can still break the private renderer integration.
