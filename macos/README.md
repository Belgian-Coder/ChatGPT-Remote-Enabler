# macOS Apple Silicon

Mobile Projects mirrors the native task-state indicators: a spinner while a task is working and a blue dot after it finishes until that task is viewed. Opening a remote task acknowledges that completion locally until its owning device reports the next state transition.

In Mobile Projects, **Auto-register: on/off** locally enables or pauses remote-project mirroring. **Remove auto projects (N)** removes only projects created by that automation—never chats or folders—and suppresses immediate recreation; it stays visible but disabled at `(0)`. Right-click a suppressed project and choose **Allow auto-registration** to permit it again.

macOS already exposes native ChatGPT remote connections. This package adds the optional Mobile projects view.

Renderer version 44 preserves the original folder states and native-backed drag
ordering, selects the complete connection inventory, and expands truncated task
lists through Codex's native callbacks. It also publishes this Mac's active saved projects and active working/unread task states into its
Codex home. Controllers running v44 read that fresh inventory through ChatGPT
Remote, including projects with no chats and excluding archived/removed ones.
Remote task indicators refresh every five seconds.
Synchronization continues automatically when **Native views** is selected.
Controllers read their complete registered-project state directly and verify
new registrations before recording success. Remote chats match projects by
device and normalized path, so they remain under the registered project.
The native **By connection** lists are rehydrated on startup, sidebar changes,
and every 30 seconds. Mutation-driven grouping recovery keeps working when
Chromium throttles background timers, so older chats keep native actions.

Install the injected startup on both the controller and every controlled
device. Inventories expire after three minutes; missing or stale inventories
pause automatic project changes instead of falling back to historical paths.

```zsh
chmod 755 ./MobileProjectView-macOS-arm64.sh
./MobileProjectView-macOS-arm64.sh enable
./MobileProjectView-macOS-arm64.sh probe
./MobileProjectView-macOS-arm64.sh enable-auto-registration
./MobileProjectView-macOS-arm64.sh enable-auto-archive
```

Use `disable-auto-registration` to pause mirroring, `reconcile-auto-registrations` to synchronize immediately, or `remove-auto-registrations` to remove only automation-created registrations. Synchronization never deletes chats or source folders.

**Auto-archive >7d** is off by default. `enable-auto-archive` archives only
unpinned, inactive local chats whose latest activity is older than seven days;
selected, working, pinned, and remote chats are skipped. Use
`disable-auto-archive` to stop future runs, `preview-auto-archive` for a
read-only count, or `run-auto-archive` for an immediate enabled-policy run.
Archived chats remain restorable in ChatGPT.

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
