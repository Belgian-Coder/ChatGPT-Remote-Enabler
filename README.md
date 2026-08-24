# ChatGPT Remote Enabler

Unofficial Windows and macOS helpers for ChatGPT/Codex Remote. Windows enables hidden native remote-device controls in affected desktop builds; both platforms can add a **Mobile projects** sidebar that groups chats by project and device, shows working/unread indicators, and can keep remote projects visible after their last chat is removed.

Why: some Windows builds contain the remote UI but do not expose it, and the native connection view flattens project organization. [OpenAI's Remote documentation](https://learn.chatgpt.com/docs/remote) covers Mac and Windows and notes that availability depends on rollout and workspace settings.

| Native views | Mobile projects |
|---|---|
| ![Native views](assets/screenshots/native-views.png) | ![Mobile projects](assets/screenshots/mobile-projects.png) |

## Install

Download the archive for your platform from [Releases](https://github.com/belgian-coder/ChatGPT-Remote-Enabler/releases).

**Windows:** extract the archive to a permanent local folder and run `ChatGPT Remote Enabler.exe`, or run `windows\Enable-ChatGPTRemote.ps1` in PowerShell. Use `Disable-ChatGPTRemote.ps1` to restore the normal app. The launchers are unsigned and built from the included C# source. Optional Start-menu, Desktop, and at-logon setup is documented in [Windows details](windows/README.md).

**macOS Apple Silicon:** extract the archive, then run:

```zsh
chmod 755 ./MobileProjectView-macOS-arm64.sh
./MobileProjectView-macOS-arm64.sh enable
```

Run `./MobileProjectView-macOS-arm64.sh disable` to roll back. Node.js 22+ is required. macOS already supplies the native remote capability; its package only adds Mobile projects.

## Auto-register remote projects

Mobile Projects can automatically register a remote project on a controller the first time that controller sees a chat from its folder. This is opt-in and uses ChatGPT's native create/remove commands. Each client stores only its own setting and managed/suppressed project paths in local app storage—there is no shared catalogue, server, NAS dependency, or central storage.

- **Auto-register: on/off** enables or pauses automatic registration on this client. Existing registrations stay intact when switched off.
- **Remove auto projects (N)** removes only registrations created by this automation on this client. It stays visible but disabled at `(0)`, never deletes chats or source folders, and suppresses immediate recreation.
- **Allow auto-registration** appears in a suppressed project's right-click menu. It clears that local suppression so the project can be registered again.

Windows PowerShell equivalents:

```powershell
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action EnableAutoRegistration
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action DisableAutoRegistration
.\CodexRemoteMobileProject\MobileProjectView.ps1 -Action RemoveAutoRegistrations
```

macOS equivalents:

```zsh
./MobileProjectView-macOS-arm64.sh enable-auto-registration
./MobileProjectView-macOS-arm64.sh disable-auto-registration
./MobileProjectView-macOS-arm64.sh remove-auto-registrations
```

The feature can discover a project only after at least one chat from that remote folder becomes visible. It cannot invent never-seen empty folders.

Renderer version 35 also lets you drag projects within one device and chats within their current project. It delegates the saved order to ChatGPT instead of keeping a separate catalogue.

## Updates

From v1.4.0, normal and automatic launches check GitHub Releases at most once every 24 hours. A matching archive is installed only after its published SHA-256 and internal manifest pass. Failure keeps the installed version.

Opt out persistently with `Update-ChatGPTRemote.ps1 -Action DisableAutoUpdate` on Windows or `/bin/zsh ./Update-ChatGPTRemote.sh disable-auto-update` on macOS. Use `EnableAutoUpdate` / `enable-auto-update` to resume. Forks and mirrors can set `CHATGPT_REMOTE_UPDATE_REPOSITORY=owner/repo`, `CHATGPT_REMOTE_UPDATE_API_BASE`, or the complete `CHATGPT_REMOTE_UPDATE_LATEST_URL`; set `CHATGPT_REMOTE_AUTO_UPDATE=0` for one launch only.

This uses a loopback-only Electron debugging session and private renderer internals, so app updates can break it. It does not bypass account authorization, MFA, workspace policy, or server permissions.

## Privacy

Repository examples and screenshots use synthetic device, project, and chat names. Do not publish real hostnames, usernames, environment IDs, network addresses, local paths, or validation-machine names in issues, commits, release notes, screenshots, or packages.

See [Windows details](windows/README.md), [macOS details](macos/README.md), and [upstream attribution](windows/CodexRemoteSimple/UPSTREAM-NOTICE.md).
