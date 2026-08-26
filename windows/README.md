# Windows

Mobile Projects mirrors the native task-state indicators: a spinner while a task is working and a blue dot after it finishes until that task is viewed.

In Mobile Projects, **Auto-register: on/off** locally enables or pauses remote-project mirroring. **Remove auto projects (N)** removes only projects created by that automation—never chats or folders—and suppresses immediate recreation; it stays visible but disabled at `(0)`. Right-click a suppressed project and choose **Allow auto-registration** to permit it again.

Run `ChatGPT Remote Enabler.exe`, or open PowerShell here and run:

```powershell
.\Enable-ChatGPTRemote.ps1
```

The compatibility check runs first. Mobile projects selects the complete native
connection inventory in the background and expands every truncated task list
through Codex's own native expansion callbacks.
Renderer v42 also publishes this device's active saved projects into its Codex
home. Controllers running v42 read that fresh inventory through ChatGPT Remote,
so empty active projects appear while archived/removed projects do not.
Synchronization continues automatically when **Native views** is selected.
Controllers read their complete registered-project state directly and verify
new registrations before recording success. Remote chats match projects by
device and normalized path, so they remain under the registered project.
The native **By connection** lists are rehydrated on startup, sidebar changes,
and every 30 seconds. Mutation-driven grouping recovery keeps working when
Chromium throttles background timers, so older chats keep native actions.

The launcher checks for a verified GitHub release on every start. Manage it with:

```powershell
.\Update-ChatGPTRemote.ps1 -Action Probe
.\Update-ChatGPTRemote.ps1 -Action DisableAutoUpdate
.\Update-ChatGPTRemote.ps1 -Action EnableAutoUpdate
.\Update-ChatGPTRemote.ps1 -Action Update
```

Set `CHATGPT_REMOTE_UPDATE_REPOSITORY=owner/repo`, `CHATGPT_REMOTE_UPDATE_API_BASE`, or `CHATGPT_REMOTE_UPDATE_LATEST_URL` for a fork or GitHub mirror. `CHATGPT_REMOTE_AUTO_UPDATE=0` skips one automatic check. Set a positive `CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS` only if you want throttling. Failed downloads or verification never replace the installed files.

For a persistent local shortcut, keep the extracted folder in place and run:

```powershell
.\CodexRemoteMobileProject\DesktopShortcut.ps1 -Action Install
```

This creates one **ChatGPT Custom** shortcut on the Desktop and one in the
Start menu. It always runs the sibling stable and Mobile Projects bundles, so
future clicks load the injected view rather than the normal app. Use
`-UseProxy` only when this device needs proxy mode; it configures those same
shortcuts with `--proxy`. The installer never creates a separate proxy
shortcut and recoverably removes obsolete proxy entries. When
`HTTPS_PROXY` or `HTTP_PROXY` is set, proxy mode uses an HTTP CONNECT tunnel only for the ChatGPT Remote
control WebSocket; other ChatGPT traffic is unchanged. TLS verification stays
enabled and includes certificates trusted by Windows. Proxy URLs containing
credentials are rejected. Without `-UseProxy`, the shortcut uses direct
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
the versioned `ChatGPT Custom.exe` in this folder, so verified in-place updates
are used at the next sign-in.

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
```

Node.js 22 or newer is required. The launchers do not modify WindowsApps, the
registry, firewall rules, or services. `ChatGPT Remote Enabler.exe` and
`CodexRemoteMobileProject\ChatGPT Custom.exe` are unsigned and compiled from
their included C# source files.
