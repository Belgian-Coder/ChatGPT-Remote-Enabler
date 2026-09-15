#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 && "$EUID" -ne 0 ]] || { print -u2 'Run setup on an Apple Silicon Mac as your normal user.'; exit 2; }
requested_proxy=0
[[ $# -le 1 && ( $# -eq 0 || "${1:-}" == --proxy ) ]] || { print -u2 "Usage: $0 [--proxy]"; exit 2; }
[[ "${1:-}" == --proxy ]] && requested_proxy=1
proxy_config="$HOME/Library/Application Support/CodexRemoteFeatures/remote-proxy"
shortcut_source="$HOME/Library/Application Support/CodexRemoteFeatures/launchers/ChatGPT Remote Enabler.applescript"
startup_plist="$HOME/Library/LaunchAgents/com.local.codex-mobile-project-view.plist"

shortcut_uses_proxy() {
  (( requested_proxy )) && return 0
  if [[ -f "$shortcut_source" ]]; then
    /usr/bin/grep -F 'quoted form of launcherPath & " enable --proxy"' "$shortcut_source" >/dev/null 2>&1
    return
  fi
  [[ -f "$proxy_config" ]]
}

startup_uses_proxy() {
  (( requested_proxy )) && return 0
  if [[ -f "$startup_plist" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:CODEX_REMOTE_USE_PROXY' "$startup_plist" 2>/dev/null || true)" == 1 ]]
    return
  fi
  [[ -f "$proxy_config" ]]
}

while true; do
  summary="$(/bin/zsh "$root/MobileProjectView-macOS-arm64.sh" setup-check 2>/dev/null)" || summary='Setup checks could not complete. Open the installation guide and verify the complete package.'
  choice="$(/usr/bin/osascript - "$summary" <<'APPLESCRIPT'
on run argv
    set setupActions to {"Recheck", "Create Dock shortcut", "Enable sign-in startup", "Open installation guide", "Copy diagnostic summary", "Close"}
    set picked to choose from list setupActions with title "ChatGPT Remote Enabler - Setup" with prompt ((item 1 of argv) & return & return & "Choose one action. Existing settings and legacy shortcuts are preserved.") default items {"Recheck"} OK button name "Continue" cancel button name "Close"
    if picked is false then return "Close"
    return item 1 of picked
end run
APPLESCRIPT
)"
  case "$choice" in
    Recheck) ;;
    'Create Dock shortcut')
      shortcut_arguments=(install)
      shortcut_uses_proxy && shortcut_arguments+=(--proxy)
      if /bin/zsh "$root/MacOSShortcut.sh" "${shortcut_arguments[@]}"; then
        shortcut_arguments[1]=reveal
        /bin/zsh "$root/MacOSShortcut.sh" "${shortcut_arguments[@]}"
        /usr/bin/osascript -e 'display dialog "Shortcut created in your Applications folder. Drag ChatGPT Remote Enabler to the Dock. Finish active tasks and quit the ordinary app before launching it." with title "Setup complete" buttons {"OK"} default button "OK"'
      else
        /usr/bin/osascript -e 'display alert "Shortcut setup failed" message "Choose Recheck and open the installation guide. Existing shortcuts are preserved."'
      fi ;;
    'Enable sign-in startup')
      startup_arguments=(install-startup)
      startup_uses_proxy && startup_arguments+=(--proxy)
      if /bin/zsh "$root/MobileProjectView-macOS-arm64.sh" "${startup_arguments[@]}"; then
        /usr/bin/osascript -e 'display dialog "Sign-in startup is installed for your user with a 60-second delay. Actual sign-in execution still needs to be checked after your next sign-in." with title "Setup complete" buttons {"OK"} default button "OK"'
      else
        /usr/bin/osascript -e 'display alert "Startup setup failed" message "Choose Recheck and open the installation guide."'
      fi ;;
    'Open installation guide') /usr/bin/open 'https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler/blob/main/macos/README.md' ;;
    'Copy diagnostic summary') print -rn -- "$summary" | /usr/bin/pbcopy ;;
    *) exit 0 ;;
  esac
done
