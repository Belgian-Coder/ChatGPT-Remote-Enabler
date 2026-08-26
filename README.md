# ChatGPT Remote Enabler

Unofficial Windows and macOS helpers for ChatGPT/Codex Remote. Windows exposes hidden native remote controls in affected desktop builds; both platforms add a **Mobile projects** sidebar with device filters, project grouping, drag ordering, empty remote projects, and synchronized working/unread indicators.

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

**macOS Apple Silicon:**

```zsh
chmod 755 ./*.sh
./MobileProjectView-macOS-arm64.sh enable
./MobileProjectView-macOS-arm64.sh install-startup
./MacOSShortcut.sh install
```

Install the injected startup on every participating computer. Each device keeps and publishes its own short-lived project/status inventory through ChatGPT Remote's existing authenticated connection; there is no central storage or shared catalogue.

## Mobile-project buttons

- **Auto-register: on/off** mirrors active remote projects on this client, including empty projects.
- **Remove auto projects (N)** removes only registrations created by that automation. It never deletes chats or folders.
- **Auto-archive >7d: on/off** optionally archives this device's inactive, unpinned local chats after seven days without activity. It skips selected, working, pinned, and remote chats and defaults to off. Archived chats remain available under **Archived chats**; any separate permanent-cleanup policy is independent.
- A suppressed project's **Allow auto-registration** action permits automatic registration again.

PowerShell and macOS command equivalents:

```powershell
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action EnableAutoRegistration
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action EnableAutoArchive
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action DisableAutoArchive
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action PreviewAutoArchive
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action RunAutoArchive
```

```zsh
./MobileProjectView-macOS-arm64.sh enable-auto-registration
./MobileProjectView-macOS-arm64.sh enable-auto-archive
./MobileProjectView-macOS-arm64.sh disable-auto-archive
./MobileProjectView-macOS-arm64.sh preview-auto-archive
./MobileProjectView-macOS-arm64.sh run-auto-archive
```

## Updates and rollback

Every launcher start checks GitHub Releases and installs only a platform archive whose published SHA-256 and internal manifest pass. Disable automatic updates with `Update-ChatGPTRemote.ps1 -Action DisableAutoUpdate` or `./Update-ChatGPTRemote.sh disable-auto-update`. Forks and mirrors can set `CHATGPT_REMOTE_UPDATE_REPOSITORY`, `CHATGPT_REMOTE_UPDATE_API_BASE`, or `CHATGPT_REMOTE_UPDATE_LATEST_URL`.

Restore normal Windows ChatGPT with `Disable-ChatGPTRemote.ps1`; on macOS run `./MobileProjectView-macOS-arm64.sh disable`. See [Windows details](windows/README.md) and [macOS details](macos/README.md).

This project uses loopback Electron debugging and private renderer internals. It does not bypass account authorization, MFA, workspace policy, or server permissions. Examples, screenshots, packages, commits, and release notes must not contain real hostnames, usernames, environment IDs, network addresses, or private paths.
