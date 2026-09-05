#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 && "$EUID" -ne 0 ]] || { print -u2 'Run setup on an Apple Silicon Mac as your normal user.'; exit 2; }

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
      if /bin/zsh "$root/MacOSShortcut.sh" install; then
        /bin/zsh "$root/MacOSShortcut.sh" reveal
        /usr/bin/osascript -e 'display dialog "Shortcut created in your Applications folder. Drag ChatGPT Remote Enabler to the Dock. Finish active tasks and quit the ordinary app before launching it." with title "Setup complete" buttons {"OK"} default button "OK"'
      else
        /usr/bin/osascript -e 'display alert "Shortcut setup failed" message "Choose Recheck and open the installation guide. Existing shortcuts are preserved."'
      fi ;;
    'Enable sign-in startup')
      if /bin/zsh "$root/MobileProjectView-macOS-arm64.sh" install-startup; then
        /usr/bin/osascript -e 'display dialog "Sign-in startup is installed for your user with a 60-second delay. Actual sign-in execution still needs to be checked after your next sign-in." with title "Setup complete" buttons {"OK"} default button "OK"'
      else
        /usr/bin/osascript -e 'display alert "Startup setup failed" message "Choose Recheck and open the installation guide."'
      fi ;;
    'Open installation guide') /usr/bin/open 'https://github.com/Belgian-Coder/ChatGPT-Remote-Enabler/blob/main/macos/README.md' ;;
    'Copy diagnostic summary') print -rn -- "$summary" | /usr/bin/pbcopy ;;
    *) exit 0 ;;
  esac
done
