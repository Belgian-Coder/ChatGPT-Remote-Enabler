# Windows

Mobile Projects mirrors the native task-state indicators: a spinner while a task is working and a blue dot after it finishes until that task is viewed.

In Mobile Projects, **Auto-register: on/off** locally enables or pauses automatic remote-project registration. **Remove auto projects (N)** removes only projects created by that automation—never chats or folders—and suppresses immediate recreation; it stays visible but disabled at `(0)`. Right-click a suppressed project and choose **Allow auto-registration** to permit it again.

Run `ChatGPT Remote Enabler.exe`, or open PowerShell here and run:

```powershell
.\Enable-ChatGPTRemote.ps1
```

The compatibility check runs first. Mobile projects then selects the complete
native connection inventory in the background, expands every **Show more**
page, and automatically registers discovered remote project folders. No manual
native grouping change is required.

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

This creates **ChatGPT Custom** on the Desktop and Start menu. It always runs
the sibling stable and Mobile Projects bundles, so future clicks load the
injected view rather than the normal app. It also creates **ChatGPT Custom
(Proxy)** in the Start menu. When `HTTPS_PROXY` or `HTTP_PROXY` is set,
that opt-in shortcut uses an HTTP CONNECT tunnel only for the ChatGPT Remote
control WebSocket; other ChatGPT traffic is unchanged. TLS verification stays
enabled and includes certificates trusted by Windows. Proxy URLs containing
credentials are rejected. The standard shortcut does not enable this proxy
mode. If injection fails, the launcher restores ordinary ChatGPT startup
without the targeted proxy shim.

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

After Remote first reports **Connected**, projects and chats can take several
seconds to populate. Renderer v36 automatically switches its hidden source to
**By connection**, expands all native pages, and registers each discovered
remote folder. Registered projects remain visible without a current chat. A
folder never supplied by Remote as a project or chat path cannot be guessed.

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
