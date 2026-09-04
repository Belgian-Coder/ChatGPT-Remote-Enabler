# ChatGPT Remote Enabler

Unofficial Windows and macOS helpers for ChatGPT/Codex Remote. Windows exposes hidden native remote controls in affected desktop builds; both platforms add a **Mobile projects** sidebar with device filters, project grouping, drag ordering, empty remote projects, project-hover new-chat actions, and synchronized working/unread indicators. Mobile Projects preserves the user's Native views grouping preference.

| Native views | Mobile projects |
|---|---|
| ![Native views](assets/screenshots/native-views.png) | ![Mobile projects](assets/screenshots/mobile-projects.png) |

## Install

Download your platform archive from [Releases](https://github.com/belgian-coder/ChatGPT-Remote-Enabler/releases) and extract it to a permanent local folder.

**Windows:** run `ChatGPT Remote Enabler.exe`. Install the injected Desktop/Start-menu and sign-in shortcuts with:

```powershell
.\CodexRemoteMobileProject\DesktopShortcut.ps1 -Action Install
.\CodexRemoteMobileProject\StartupShortcut.ps1 -Action Install
```

If the device requires a configured HTTP(S) proxy, add `-UseProxy` while installing those same shortcuts. No separate proxy shortcut is created.
Copy an existing User-scope proxy into the launcher's protected storage with
`ProxyConfiguration.ps1 -Action Install -ImportUserEnvironment`; the importer
preserves all shared User- and Machine-scope environment variables. Proxy
isolation applies only inside the custom launcher's child process. Native-key
Windows builds keep the signed API and enrollment flow on canonical
`https://chatgpt.com` and route only the Remote-control WebSocket through a
temporary localhost bridge. A version-matched private runtime makes that
single URL override without modifying the installed WindowsApps package. The
bridge uses the configured proxy, preserves TLS verification, and exits with
ChatGPT.

**macOS Apple Silicon:**

```zsh
chmod 755 ./*.sh
./MobileProjectView-macOS-arm64.sh enable
./MobileProjectView-macOS-arm64.sh install-startup
./MacOSShortcut.sh install
```

Install the injected startup on every participating computer. Each device automatically publishes its complete active project/task inventory through ChatGPT Remote's existing authenticated connection. Direct peer reads and local per-device cache files keep clients converged without opening folders or clicking **Show more**; there is no central storage or shared catalogue. Device dots use fresh direct connectivity—not cached inventory—while Native grouping and folder expansion are never changed.

## Mobile-project buttons

- **Auto-register: on/off** mirrors active remote projects on this client, including empty projects. Enabling it only adds registrations; removal is always explicit.
- **Remove auto projects (N)** removes only registrations created by that automation. It never deletes chats or folders.
- **Auto-cleanup: on/off** optionally archives this device's inactive, unpinned local chats after seven days, then permanently deletes them after a tracked seven-day recovery window in **Archived chats**. It skips selected, working, pinned, remote, and insufficiently dated chats and defaults to off. Disabling it clears the timers, so re-enabling grants a new recovery window.
- A suppressed project's **Allow auto-registration** action permits automatic registration again.

PowerShell and macOS command equivalents:

```powershell
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action EnableAutoRegistration
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action EnableAutoMaintenance
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action DisableAutoMaintenance
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action PreviewAutoMaintenance
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action RunAutoMaintenance
```

```zsh
./MobileProjectView-macOS-arm64.sh enable-auto-registration
./MobileProjectView-macOS-arm64.sh enable-auto-maintenance
./MobileProjectView-macOS-arm64.sh disable-auto-maintenance
./MobileProjectView-macOS-arm64.sh preview-auto-maintenance
./MobileProjectView-macOS-arm64.sh run-auto-maintenance
```

## Updates and rollback

Launchers check for updates on every start by default. On Windows, launch
ownership first moves to a mutex-protected worker so the launcher executable
can exit before verified replacement; the worker then continues the same
direct/proxy and manual/startup launch exactly once. A completed update remains
installed and is logged even if the later injection step fails. A clean Windows Git
checkout fast-forwards through Git; packaged installs accept only a platform
archive whose published SHA-256 and internal manifest pass. Disable automatic
updates with `Update-ChatGPTRemote.ps1 -Action DisableAutoUpdate` or
`./Update-ChatGPTRemote.sh disable-auto-update`. Forks and mirrors can set
`CHATGPT_REMOTE_UPDATE_REPOSITORY`, `CHATGPT_REMOTE_UPDATE_API_BASE`, or
`CHATGPT_REMOTE_UPDATE_LATEST_URL`.

Before starting ChatGPT, the packaged launcher prunes diagnostic logs older than seven days (96 MiB cap), checkpoints WAL files, runs SQLite optimization, and vacuums materially fragmented databases. It always skips this physical maintenance when ChatGPT/Codex is already running.

Restore normal Windows ChatGPT with `Disable-ChatGPTRemote.ps1`; on macOS run `./MobileProjectView-macOS-arm64.sh disable`. See [Windows details](windows/README.md) and [macOS details](macos/README.md).

This project uses loopback Electron debugging and private renderer internals. It does not bypass account authorization, MFA, workspace policy, or server permissions. Examples, screenshots, packages, commits, and release notes must not contain real hostnames, usernames, environment IDs, network addresses, or private paths.
