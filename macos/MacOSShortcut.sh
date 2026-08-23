#!/bin/zsh
set -euo pipefail

action="${1:-probe}"
action="${action:l}"
script_path="${0:A}"
launcher="${script_path:h}/MobileProjectView-macOS-arm64.sh"
source_root="$HOME/Library/Application Support/CodexRemoteFeatures/launchers"
source_file="$source_root/ChatGPT Mobile Projects.applescript"
app_root="$HOME/Applications"
app_path="$app_root/ChatGPT Mobile Projects.app"
rollback_root="$source_root/rollback"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  print -u2 "This shortcut manager is restricted to macOS on Apple Silicon (arm64)."
  exit 2
fi
if [[ "$EUID" -eq 0 ]]; then
  print -u2 "Run this as the signed-in macOS user, not root."
  exit 2
fi

probe_shortcut() {
  [[ -x "$launcher" ]] || { print -u2 "Installed launcher is missing or not executable: $launcher"; return 1; }
  [[ -f "$source_file" ]] || { print -u2 "AppleScript source is missing: $source_file"; return 1; }
  [[ -d "$app_path" ]] || { print -u2 "Application wrapper is missing: $app_path"; return 1; }
  /usr/bin/codesign --verify --deep --strict "$app_path"
  /usr/bin/osadecompile "$app_path" | /usr/bin/grep -F "MobileProjectView-macOS-arm64.sh" >/dev/null
  print "Shortcut is valid: $app_path"
}

install_shortcut() {
  [[ -x "$launcher" ]] || { print -u2 "Installed launcher is missing or not executable: $launcher"; return 1; }
  mkdir -p "$source_root" "$app_root" "$rollback_root"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -f "$source_file" ]]; then
    cp -p "$source_file" "$rollback_root/ChatGPT Mobile Projects-$stamp.applescript"
  fi
  if [[ -e "$app_path" ]]; then
    mv "$app_path" "$rollback_root/ChatGPT Mobile Projects-$stamp.app"
  fi
  local escaped_launcher
  escaped_launcher="${launcher//\\/\\\\}"
  escaped_launcher="${escaped_launcher//\"/\\\"}"
  /bin/cat > "$source_file" <<APPLESCRIPT
on run
    set launcherPath to "$escaped_launcher"
    try
        set runningCount to do shell script "/usr/bin/pgrep -x ChatGPT | /usr/bin/wc -l | /usr/bin/tr -d ' '"
        if runningCount is not "0" then
            display alert "ChatGPT is already running" message "Quit ChatGPT with Command-Q when no task is active, then click ChatGPT Mobile Projects again. The launcher will not terminate it automatically." as warning
            return
        end if
        do shell script "/bin/zsh " & quoted form of launcherPath & " enable"
    on error errorMessage number errorNumber
        display alert "ChatGPT Mobile Projects failed to start" message (errorMessage & " (error " & (errorNumber as text) & ")") as critical
    end try
end run
APPLESCRIPT
  /usr/bin/osacompile -o "$app_path" "$source_file"
  /usr/bin/codesign --force --deep --sign - "$app_path"
  probe_shortcut
}

remove_shortcut() {
  mkdir -p "$rollback_root"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ -e "$app_path" ]]; then
    mv "$app_path" "$rollback_root/ChatGPT Mobile Projects-removed-$stamp.app"
  fi
  if [[ -f "$source_file" ]]; then
    mv "$source_file" "$rollback_root/ChatGPT Mobile Projects-removed-$stamp.applescript"
  fi
  print "Shortcut files were preserved under $rollback_root. Remove the stale Dock icon manually if present."
}

case "$action" in
  install) install_shortcut ;;
  probe) probe_shortcut ;;
  remove) remove_shortcut ;;
  reveal) probe_shortcut; /usr/bin/open -R "$app_path" ;;
  *) print -u2 "Usage: $0 {install|probe|reveal|remove}"; exit 2 ;;
esac
