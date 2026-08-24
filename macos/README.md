# macOS Apple Silicon

Mobile Projects mirrors the native task-state indicators: a spinner while a task is working and a blue dot after it finishes until that task is viewed.

In Mobile Projects, **Auto-register: on/off** locally enables or pauses automatic remote-project registration. **Remove auto projects (N)** removes only projects created by that automation—never chats or folders—and suppresses immediate recreation; it stays visible but disabled at `(0)`. Right-click a suppressed project and choose **Allow auto-registration** to permit it again.

macOS already exposes native ChatGPT remote connections. This package adds the optional Mobile projects view.

Renderer version 35 preserves the original folder states and adds native-backed drag ordering for projects and chats.

```zsh
chmod 755 ./MobileProjectView-macOS-arm64.sh
./MobileProjectView-macOS-arm64.sh enable
./MobileProjectView-macOS-arm64.sh probe
./MobileProjectView-macOS-arm64.sh enable-auto-registration
```

Use `disable-auto-registration` to pause new registrations, or `remove-auto-registrations` to remove only automation-created registrations.

The launcher checks for a verified GitHub release on every start. Manage it with:

```zsh
/bin/zsh ./Update-ChatGPTRemote.sh probe
/bin/zsh ./Update-ChatGPTRemote.sh disable-auto-update
/bin/zsh ./Update-ChatGPTRemote.sh enable-auto-update
/bin/zsh ./Update-ChatGPTRemote.sh update
```

Set `CHATGPT_REMOTE_UPDATE_REPOSITORY=owner/repo`, `CHATGPT_REMOTE_UPDATE_API_BASE`, or `CHATGPT_REMOTE_UPDATE_LATEST_URL` for a fork or GitHub mirror. `CHATGPT_REMOTE_AUTO_UPDATE=0` skips one automatic check. Set a positive `CHATGPT_REMOTE_UPDATE_INTERVAL_HOURS` only if you want throttling. Failed downloads or verification keep the installed version.

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
