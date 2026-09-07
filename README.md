# ChatGPT Remote Enabler

Unofficial per-user helpers for ChatGPT/Codex Remote on Windows 11 x64 and
macOS Apple Silicon. The helper uses the desktop app's existing loopback
debugger session and private renderer interfaces. Windows also exposes the
native **Control other devices** surface on desktop builds that hide it.

Both platforms add **Device projects**: a device-aware project sidebar with
device filters, native project grouping and ordering, empty remote projects,
project-hover new-chat actions, and working/unread indicators. The original
**Native sidebar** remains available, with its grouping preference preserved.

v1.5.51 adds Git-based updates and a compact refresh icon beside Settings,
with fixes for update recovery and task activation. Background discovery stays
quiet. See the [feature guide](FEATURES.md) for behavior and validation limits.

## Install when hosted ZIP downloads are blocked

Clone the public source into a new user-owned folder with Git, then run the
platform setup from that checkout. Git must already be available. This also
bootstraps older installations whose updater still downloads release assets.
Finish existing work before switching launchers; setup should target the new
checkout, and Settings should show the newly loaded version after launch.

Windows PowerShell:

```powershell
git clone https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler.git "$env:USERPROFILE\ChatGPTRemoteEnabler-Git"
& "$env:USERPROFILE\ChatGPTRemoteEnabler-Git\windows\Setup-ChatGPTRemote.ps1"
```

macOS Terminal:

```sh
git clone https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler.git "$HOME/ChatGPTRemoteEnabler-Git"
"$HOME/ChatGPTRemoteEnabler-Git/macos/Setup.command"
```

Use a new destination if that folder already exists; keep any local changes in
an existing checkout. Future updates use the pinned release tag on clean `main`.

## What it looks like

These images are from the v1.5.49 renderer in a synthetic browser fixture with
synthetic demo data. They show the interface and responsive states; they are
not native Windows or macOS screenshots and do not prove a particular desktop
app build is compatible.

| Device projects | Settings and update status |
| --- | --- |
| ![Device projects](assets/screenshots/device-projects-v1.5.49.png) | ![Settings and update status](assets/screenshots/settings-v1.5.49.png) |

See the [complete feature guide](FEATURES.md) for defaults, limits, privacy,
and recovery behavior.

## Install v1.5.51 without administrator access

Prerequisites are a supported ChatGPT/Codex desktop app signed in with Remote
available on the account, Node.js 22 or newer, and a writable per-user package
folder. Organization policy, account access, MFA, or desktop-app policy can
still block Remote independently of this helper.

- **[Download Windows 11 x64](https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler/releases/download/v1.5.51/ChatGPT-Remote-Enabler-Windows-x64-v1.5.51.zip)** and follow the [Windows installation guide](windows/README.md).
- **[Download macOS Apple Silicon](https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler/releases/download/v1.5.51/ChatGPT-Remote-Enabler-macOS-arm64-v1.5.51.zip)** and follow the [macOS installation guide](macos/README.md).
- Use the [v1.5.51 release page](https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler/releases/tag/v1.5.51) to inspect release notes and published checksums.

Both are per-user installs and do not require administrator access. Keep the
complete package in a writable user-owned folder. Run the platform launcher
after quitting the ordinary desktop app; it opens the app with Device projects
and Native sidebar available. Optional shortcut and sign-in startup setup is
documented separately in each platform guide.

## Remote connection roles

The helper does not create account authorization. Native Remote still decides
which devices may connect.

- **Authorize the outgoing/controller side.** In ChatGPT/Codex, open
  **Settings â†’ Connections â†’ Control other devices** and complete the native
  authorization flow for this computer. If authorization, sign-in, or account
  access is missing, project synchronization pauses and the helper explains the
  next native step. A remembered device name or cached project list is not
  authorization proof.
- **Run the incoming/publisher side.** On every device whose projects should be
  visible, launch the helper-enabled desktop app and keep its native Remote
  connection available. The publisher exposes active user-facing projects,
  tasks, empty projects, and working/unread state through the existing
  authenticated Remote channel.
- **Auto-connect/reconnect belongs to native Remote.** If the native
  connection UI exposes an Auto-connect or automatic reconnect option, enable
  or disable it there. The helper reads native connection state; it does not
  toggle authorization or native connection preferences. After a native
  reconnect it retries discovery and inventory, and queued alias transfers
  retry with bounded backoff.

Launch the helper on every participating device, and optionally configure its
sign-in startup. Keep the app open and signed in on a publisher device when its
projects need to be available. Direct reads, inventory freshness, and native
connection state are shown separately in **Settings â†’ Device health**; cached
inventory alone never marks a device online.

The connection panel is intentionally evidence-based. Its light and dark
troubleshooting states use the same synthetic demo data and illustrate how
authorization, disconnection, stale inventory, and refresh guidance are shown.

| Light theme | Dark theme |
| --- | --- |
| ![Connection troubleshooting in light theme](assets/screenshots/connection-light-v1.5.49.png) | ![Connection troubleshooting in dark theme](assets/screenshots/connection-dark-v1.5.49.png) |

## Everyday features

- Device filters show **All**, **This device**, and other known devices in
  display-name order. Verified names and aliases are remembered; an unknown
  peer is shown as **Remote device**, never as an internal environment ID.
- Project rows preserve native folder styling and order, include active empty
  projects, and offer a native project-hover new-chat action when the installed
  app exposes it. Working spinners and unread dots are synchronized separately
  and aggregate on collapsed projects.
- **Auto-register** mirrors active remote project registrations on this client.
  **Remove auto projects** removes only registrations created by that automation
  and suppresses immediate recreation. It never deletes chats or source
  folders; **Allow auto-registration** reverses a suppression.
- Settings includes Device health, shared aliases, cleanup preview/history,
  update details/history, diagnostic export preview, connection
  troubleshooting, and session-transfer statistics.
- Aliases change display labels only. They are shared through the existing
  authenticated peer connection, converge across updated clients, and queue
  while an offline device reconnects. They never replace identity, connection
  settings, paths, or cache keys.

![Shared device alias](assets/screenshots/shared-alias-v1.5.49.png)

<details>
<summary>Preview, history, and diagnostic panels</summary>

The Settings panels cover cleanup preview/history, update details/history,
diagnostic export preview, device health, and connection findings. Preview is
read-only until an explicit cleanup action. Diagnostic JSON is allowlisted and
must be reviewed before copying or saving.

![Feature panels](assets/screenshots/features-v1.5.49.png)

</details>

## Updates, rollback, and optional cleanup

The launcher checks asynchronously at startup and every 30 minutes while the
app is open. The loaded helper version and **Update available** state are in
Settings. An update is installed only after you click: the helper pins and
verifies the selected release and SHA-256, waits for authoritative idle state,
requests a graceful close of the exact app instance, applies the package, and
relaunches with the saved direct/proxy and startup options. Unknown activity
keeps it queued, **Cancel** remains available until shutdown starts, and a
refused close is never force-killed.

Updates use Git tag discovery and shallow fetch by default, including extracted
installations. Git must be installed and able to reach the repository. No GitHub
API or hosted ZIP download is used: the helper builds a deterministic local
package, pins its commit and SHA-256, and verifies every file before apply.
Corporate Git proxy and certificate settings remain in effect.

Interrupted package replacement uses a durable journal and verified recovery. A
failed package update restores the previous verified installation. Clean source
checkouts on `main` instead fast-forward to the verified tag; dirty checkouts,
other branches, and unexpected origins are refused. Recovery accepts only the
recorded original or completed commit and never resets local work. Protected or
administrator-owned folders show an unavailable action; the helper never
self-elevates. Automatic checks can be disabled with the platform command in
the installation guide, and explicit `Update`/`update` commands remain
available. The [feature guide](FEATURES.md) documents update history and
rollback details.

![Loaded helper version and update control](assets/screenshots/version-v1.5.49.png)

**Auto-cleanup is off by default.** When enabled, eligible inactive, unpinned
local chats are archived after seven days and permanently deleted only after a
tracked seven-day recovery window in **Archived chats**. Selected, working,
pinned, remote, and insufficiently dated chats are skipped; missing evidence
fails closed. Disabling cleanup clears timers, and re-enabling starts a new
recovery window. Preview and history are local and read-only until an actual
cleanup action is run. Removing project registrations never deletes chats.

The launcher also performs best-effort local maintenance before startup:
diagnostic logs older than seven days are pruned within a 96 MiB cap, SQLite
WAL files are checkpointed, databases are optimized, and materially fragmented
databases may be vacuumed. It skips physical maintenance while ChatGPT/Codex
is already running and reports maintenance errors separately.

## Privacy and boundaries

The helper publishes only native or persisted user-facing chat titles and
active project/task state. Internal exec and subagent runs are used for local
update-safety checks but are excluded from project chats. Diagnostic export is
an allowlisted JSON preview that you review before copying or saving; nothing
is uploaded automatically. The export excludes real device names and aliases,
device/task IDs, titles, paths, raw logs/errors, and credentials.

The package does not bypass account authorization, MFA, workspace policy,
server permissions, or native Remote enrollment. It adds no central catalogue
or entitlement and does not modify the installed WindowsApps payload. It uses
private desktop internals, so a future ChatGPT/Codex update may require a
compatibility update. Do not publish real hostnames, usernames, environment
IDs, network addresses, private paths, or credentials in examples, screenshots,
issues, packages, or logs.

## Validation scope

Source self-tests, renderer fixtures, real Chromium/CDP integration,
transaction interruption/recovery, update-session checks, privacy checks, and
shared-source parity are covered by `tools/Test-Source.ps1` and the other
commands in the [validation section](FEATURES.md). Current v1.5.49 acceptance
also includes an ordinary Windows close/apply/recover/relaunch update flow,
an ordinary macOS restart flow on the preceding installed build followed by a
manual v1.5.49 installation, and live v1.5.49 renderer readiness on the
participating test devices. Shared alias synchronization converged across
three clients.

With Node.js 22 and Playwright available through `NODE_PATH`, the minimal
browser checks are:

```powershell
pwsh ./tools/Test-Source.ps1
node tools/Test-RendererBrowser.cjs
node tools/Test-RendererBrowser.cjs --screenshot "$env:TEMP\remote-enabler-preview.png"
```

These checks establish the documented behavior under the tested app/account
conditions. They do not certify every desktop-app build, account policy,
sign-in trigger, screen reader, or future release. Release publication is not
proof that a package is installed or that native Remote authorization exists.

For platform-specific commands and troubleshooting, use the [Windows guide](windows/README.md) or [macOS guide](macos/README.md).
