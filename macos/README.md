# macOS Apple Silicon

Mobile Projects mirrors the native task-state indicators: a spinner while a task is working and a blue dot after it finishes until that task is viewed.

In Mobile Projects, **Auto-register: on/off** locally enables or pauses automatic remote-project registration. **Remove auto projects (N)** removes only projects created by that automation—never chats or folders—and suppresses immediate recreation; it stays visible but disabled at `(0)`. Right-click a suppressed project and choose **Allow auto-registration** to permit it again.

macOS already exposes native ChatGPT remote connections. This package adds the optional Mobile projects view.

Renderer version 34 preserves the original plain folder design and changes
only its open/closed state, including projects without a native icon template.
It also retains empty registered projects, working/unread indicators, and the
startup/modal fixes included in the Windows package.

```zsh
chmod 755 ./MobileProjectView-macOS-arm64.sh
./MobileProjectView-macOS-arm64.sh enable
./MobileProjectView-macOS-arm64.sh probe
./MobileProjectView-macOS-arm64.sh enable-auto-registration
```

Use `disable-auto-registration` to pause new registrations, or `remove-auto-registrations` to remove only automation-created registrations.

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
