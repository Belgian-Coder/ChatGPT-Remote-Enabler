# macOS Apple Silicon: install for your user without sudo

You need an Apple Silicon Mac (arm64), the ChatGPT/Codex desktop app installed and signed in with Remote available on your account, and Node.js 22 or newer. This helper does not install the app or unlock account features.

**Testing status:** native macOS installation, startup, and update/relaunch acceptance remains pending. Shared JavaScript and static checks pass. v1.5.35 is a normal release.

## 1. Download and extract

1. Download **ChatGPT-Remote-Enabler-macOS-arm64-v1.5.35.zip** from [v1.5.35 downloads](https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler/releases/tag/v1.5.35).
2. Double-click the ZIP in Finder. Create **ChatGPTRemoteEnabler** in your home folder and move the extracted package contents into it.
3. `MobileProjectView-macOS-arm64.sh` must be directly inside that folder. Keep the complete package together in this writable per-user location.

## 2. Node.js, if needed

Try step 3 first: the helper detects a suitable desktop-app cached runtime or Node on PATH. If Node is missing, visit [the official Node.js download page](https://nodejs.org/en/download), choose a supported LTS version, **macOS**, **ARM64**, and **Standalone Binary (.tar.gz)**. You do not need the `.pkg` installer or Homebrew.

Double-click that archive. In Finder, choose **Go > Go to Folder** and enter `~/Library/Application Support`. Create **ChatGPTRemoteEnabler** there if absent. Copy the extracted Node folder into it and rename that folder **node**. The result must contain `~/Library/Application Support/ChatGPTRemoteEnabler/node/bin/node`, together with the other Node files.

The helper detects this portable location automatically, including at sign-in. No shell-profile or system PATH change is needed.

## 3. First launch

Finish active tasks and quit the ordinary ChatGPT/Codex app. Open **Terminal** from **Applications > Utilities** and paste:

```zsh
cd "$HOME/ChatGPTRemoteEnabler"
/bin/zsh ./MobileProjectView-macOS-arm64.sh enable
```

If you used a different folder, type `cd `, drag that folder from Finder into Terminal, and press Return before the second command.

The app should open with **Device projects** and **Native sidebar**. Set up each participating device and use the app's normal Remote controls to connect it. Review any per-user consent prompt to control the app. Do not use sudo or disable Gatekeeper. Organization policies may require IT approval independently of this helper.

## 4. Setup assistant: Dock shortcut and sign-in startup

In Terminal, still in the extracted package folder, run:

```zsh
/bin/zsh ./Setup.command
```

The native setup dialog shows separate app, Node, folder, integration-file, shortcut, and startup checks. Choose **Create Dock shortcut** or **Enable sign-in startup** only if wanted. New shortcuts are called **ChatGPT Remote Enabler** and live in `~/Applications`; drag the revealed app to your Dock. Existing **ChatGPT Mobile Projects** shortcuts are preserved.

Use **Recheck**, **Open installation guide**, or **Copy diagnostic summary** as needed. Setup does not launch or quit the desktop app. Checks establish package readiness; live injection is checked on launch. Startup installation does not prove next-sign-in execution. Native macOS execution of this assistant remains pending validation.

## 5. Updates and removal

**Update available** appears in both views. Click to prepare the verified release and queue it until work finishes. Unknown activity keeps it queued. **Cancel** is available until shutdown starts. The helper requests a normal quit of the exact app instance and restores saved settings on relaunch. See [the feature guide](FEATURES.md) for the controls and optional cleanup, which is off by default.

To remove startup/shortcut integration and stop the helper:

```zsh
cd "$HOME/ChatGPTRemoteEnabler"
/bin/zsh ./MobileProjectView-macOS-arm64.sh remove-startup
/bin/zsh ./MacOSShortcut.sh remove
/bin/zsh ./MobileProjectView-macOS-arm64.sh disable
```

Once stopped, you can remove the package folder. Your conversations and projects are not deleted.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| Node.js missing | Check the full `node/bin/node` path in step 2. |
| Ordinary app already running | Finish work and quit it before the first enhanced launch. |
| Permission denied for a script | Invoke it with `/bin/zsh ./script-name.sh` as shown above. |
| Update cannot write | Keep the complete package in your home folder; recreate its shortcut after moving it. |
| Startup does nothing | Allow the initial delay and check that the original package folder still exists. |
| Update stays queued | Finish tasks or Cancel; unknown activity intentionally blocks shutdown. |
| macOS blocks a binary | Review its origin and macOS's explanation; a managed-device policy may require IT. |

Logs/state live under `~/Library/Application Support/CodexRemoteFeatures` and `~/Library/Application Support/ChatGPTRemoteEnabler`. Check for private information before sharing logs.

## Advanced reference

Device Projects mirrors the native task-state indicators: a spinner while a task is working and a blue dot after it finishes until that task is viewed. Opening a remote task acknowledges that completion locally until its owning device reports the next state transition.

In Device Projects, **Auto-register: on/off** locally enables or pauses remote-project mirroring. It adds registrations and removes only automation-created registrations after a fresh, complete direct inventory confirms the source project was removed. It never deletes chats or folders. **Remove auto projects (N)** removes those registrations now and suppresses immediate recreation; it stays visible but disabled at `(0)`. Right-click a suppressed project and choose **Allow auto-registration** to permit it again.

macOS already exposes native ChatGPT remote connections. This package adds the optional Device projects view.

Renderer version 66 preserves the original folder states, native-backed drag
ordering, and the user's **By project**/**By connection** preference. It
automatically paginates the authoritative active task list for the app-server's
interactive CLI/VS Code sources used by the desktop UI. Internal exec and subagent runs remain available to
maintenance safety checks but are not published as project chats. It publishes
only native or persisted chat titles, never preview or first-message text. It
publishes this Mac's complete active projects, tasks, and working/unread state into its Codex
home. Other devices use direct peer reads plus local per-device cache files if
a request stalls. No folder opening, **Show more** click, shared catalogue, or
central storage is required. Empty active projects appear while archived or
removed projects and stale native rows do not. On app builds that no longer
expose the project-state bridge, the publisher uses the current native local
project catalogue and refuses a false empty inventory while that catalogue is
unavailable. Inventory-only remote folders use the same aligned folder geometry
without an extra decorative marker.
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
Synchronization continues automatically when **Native sidebar** is selected.
Controllers read their complete registered-project state directly and verify
new registrations before recording success. Remote chats match projects by
device and normalized path, so they remain under the registered project.
The complete task inventory refreshes on startup and every 60 seconds, with
debounced refreshes after native task rows change. Working/unread status is
published separately at the existing fast cadence. Refresh does not open the
grouping menu or change its value. Hovering a
Device Projects folder opens the exact native project composer when available;
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
is running. Maintenance failures are reported separately; the launcher's
best-effort maintenance does not prevent startup. Direct maintenance commands
return a failing exit status on database errors. Permanent chat deletion
requires a known managed archive path and an exclusive cross-window lock.

The launcher checks asynchronously on every start and every 30 minutes while
open. **Update available · vX.Y.Z** appears beside the view controls in both
views. Click to download and verify that exact release, wait for active work
to finish, quit ChatGPT normally, install, and relaunch with the saved options.
Unknown activity keeps the request queued; **Cancel** remains available until
shutdown begins. A refused quit aborts the update without force-killing the app.

The detached helper runs from per-user application-support storage, outside
the installation folder. It uses the existing debugger connection and creates
no additional listener, service, or LaunchAgent. It exits with ChatGPT except
during an explicitly requested restart. Interrupted updates recover from a
durable journal before another injected launch; non-writable folders require
manual administration. Explicit command-line updates remain available:

```zsh
/bin/zsh ./Update-ChatGPTRemote.sh probe
/bin/zsh ./Update-ChatGPTRemote.sh disable-auto-update
/bin/zsh ./Update-ChatGPTRemote.sh enable-auto-update
/bin/zsh ./Update-ChatGPTRemote.sh update
```

Set `CHATGPT_REMOTE_UPDATE_REPOSITORY=owner/repo`, `CHATGPT_REMOTE_UPDATE_API_BASE`, or `CHATGPT_REMOTE_UPDATE_LATEST_URL` for a fork or GitHub mirror. `CHATGPT_REMOTE_AUTO_UPDATE=0` disables automatic checks for that launch. Failed downloads or verification keep the installed version.

Device names resolve automatically from verified metadata and are remembered
per normalized host identity across restarts. Native placeholders cannot
replace a verified name. Unknown or older peers display **Remote device**
instead of an internal environment ID.

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

Requires Apple Silicon and Node.js 22 or newer with built-in WebSocket support.
The v1.5.35 candidate shares the Windows renderer and automated fixtures.
Native macOS startup, graceful quit, and update/relaunch validation remains a
separate acceptance step on an available Mac; a future ChatGPT update can
still break the private renderer integration.

## Revised sidebar

These screenshots show the shared renderer in a browser fixture; they are not native macOS acceptance evidence.

![Device projects](screenshots/device-projects-v1.5.35.png)

![Settings and update status](screenshots/settings-v1.5.35.png)

## Health, history, and diagnostics

Settings now includes cleanup preview/history, update details/history, and an explicit diagnostic export preview. Device health includes refresh, reported helper versions, and aliases that stay on this client. See the [feature guide](FEATURES.md) for retention and privacy boundaries.

## Connection troubleshooting and transfer

Settings now provides per-device connection findings, next steps, explicit evidence refresh, and session transfer statistics. Inventory exchange avoids recipient echoes, coalesces slow-peer writes, and retries with backoff. A 1,000-task-per-client fixture measured a 64% smaller push payload; live network speed is not yet measured. See the [feature guide](FEATURES.md) for scope and compatibility.

## Version or update icon missing

Fully quit the app when your work is safe and launch through Remote Enabler in the latest extracted folder. An older Dock launcher can still reference another folder. The top sidebar strip shows the loaded helper version even with Settings closed; a missing updater has recovery instructions. v1.5.35 is a normal release available to the existing updater.
